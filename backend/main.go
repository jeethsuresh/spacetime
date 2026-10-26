package main

import (
	"context"
	"encoding/base64"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/emersion/go-webdav/caldav"
)

type App struct {
	store                              *Store
	limiter                            limiter
	secureCookie                       bool
	allowedOrigins                     map[string]bool
	static                             string
	registrationInviteKey              string
	gravitas                           *gravitasAuth
	groupMu                            sync.Mutex
	remoteMu                           sync.Mutex
	remoteHTTP                         *http.Client
	notificationKey, notificationStore string
	notificationProtocol               bool
	notificationHTTP                   *http.Client
}

func env(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}
func newApp(store *Store) *App {
	a := &App{store: store, limiter: limiter{attempts: map[string]attempt{}}, secureCookie: os.Getenv("COOKIE_SECURE") == "1", allowedOrigins: map[string]bool{}, static: env("STATIC_DIR", "../frontend/build/web"), registrationInviteKey: os.Getenv("REGISTRATION_INVITE_KEY")}
	a.gravitas, _ = newGravitasAuth(os.Getenv("GRAVITAS_ISSUER"), os.Getenv("PUBLIC_URL"), os.Getenv("GRAVITAS_GATEWAY_ADDR"))
	if a.gravitas != nil {
		a.secureCookie = true
		a.gravitas.sessionChecks = true
		a.gravitas.sessionKey, _ = base64.StdEncoding.DecodeString(os.Getenv("GRAVITAS_SESSION_KEY"))
	}
	a.notificationKey = os.Getenv("NOTIFICATION_PROVIDER_KEY")
	a.notificationProtocol = os.Getenv("NOTIFICATION_PROTOCOL") == "appstore/1.0.0"
	if client, err := newNotificationHTTP(os.Getenv("NOTIFICATION_GATEWAY_ADDR")); err == nil {
		a.notificationHTTP = client
	} else {
		log.Print("Notifications disabled: invalid NOTIFICATION_GATEWAY_ADDR")
		a.notificationKey = ""
	}
	if origin, err := httpsOrigin(os.Getenv("NOTIFICATION_STORE_URL")); err == nil {
		a.notificationStore = origin
	}
	for _, origin := range strings.Split(os.Getenv("ALLOWED_ORIGINS"), ",") {
		if origin != "" {
			a.allowedOrigins[origin] = true
		}
	}
	return a
}
func (a *App) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("PUT /api/notifications/providers/{id}", a.notificationProvider)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) { writeJSON(w, 200, map[string]string{"status": "ok"}) })
	mux.HandleFunc("POST /api/register", a.credentials)
	mux.HandleFunc("POST /api/login", a.credentials)
	mux.HandleFunc("GET /api/auth/config", a.authConfiguration)
	mux.HandleFunc("GET /auth/gravitas/start", a.gravitasStart)
	mux.HandleFunc("GET /auth/gravitas/callback", a.gravitasCallback)
	mux.HandleFunc("POST /api/auth/gravitas/android", a.gravitasAndroidExchange)
	mux.HandleFunc("POST /api/auth/gravitas/broker", a.gravitasBrokerExchange)
	protected := func(pattern string, fn http.HandlerFunc) {
		var handler http.Handler = fn
		if strings.Contains(pattern, "/api/events") || strings.Contains(pattern, "/api/calendars") || strings.Contains(pattern, "/api/groups") || strings.Contains(pattern, "/api/occurrences") || strings.Contains(pattern, "/api/invitations") || strings.Contains(pattern, "/api/recurrence") {
			handler = a.calendarContext(handler)
		}
		mux.Handle(pattern, a.auth(handler))
	}
	protected("POST /api/logout", a.logout)
	protected("GET /api/me", func(w http.ResponseWriter, r *http.Request) {
		u, err := a.store.user(currentUser(r.Context()))
		if err != nil {
			serveError(w, err)
			return
		}
		session, _ := r.Context().Value(sessionContextKey{}).(Session)
		writeJSON(w, 200, publicAccount(u, session.Gravitas))
	})
	protected("GET /api/events", a.listEvents)
	protected("GET /api/calendars", a.listCalendars)
	protected("GET /api/groups", a.listGroups)
	protected("POST /api/groups", a.createGroup)
	protected("POST /api/groups/{id}/membership", a.groupMembership)
	protected("POST /api/calendars", a.putCalendar)
	protected("PUT /api/calendars/{id}", a.putCalendar)
	protected("DELETE /api/calendars/{id}", a.deleteCalendar)
	protected("POST /api/calendars/discover", a.discoverRemote)
	protected("POST /api/calendars/connect", a.connectRemote)
	protected("GET /api/occurrences", a.occurrences)
	protected("POST /api/recurrence/preview", a.previewRecurrence)
	protected("POST /api/events/{id}/exceptions", a.exception)
	protected("POST /api/events/{id}/completion", a.completeTodo)
	protected("GET /api/invitations", a.listEvents)
	protected("POST /api/events", a.putEvent)
	protected("PUT /api/events/{id}", a.putEvent)
	protected("DELETE /api/events/{id}", a.deleteEvent)
	protected("POST /api/events/{id}/respond", a.respond)
	davBackend := &davBackend{a.store}
	davHandler := a.calendarContext(davBackend.serve(&caldav.Handler{Backend: davBackend, Prefix: "/dav"}))
	dav := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.Header.Get("Authorization"), "Bearer ") || a.sessionToken(r) != "" {
			a.auth(davHandler).ServeHTTP(w, r)
		} else {
			a.basic(davHandler).ServeHTTP(w, r)
		}
	})
	mux.Handle("/dav/", dav)
	mux.Handle("/.well-known/caldav", dav)
	mux.HandleFunc("/api/", func(w http.ResponseWriter, r *http.Request) { fail(w, 404, "Endpoint not found.") })
	files := http.FileServer(http.Dir(a.static))
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			http.Error(w, "Method not allowed", 405)
			return
		}
		if _, err := os.Stat(filepath.Join(a.static, "index.html")); err != nil {
			http.Error(w, "Build the Flutter frontend first. See README.md.", 503)
			return
		}
		files.ServeHTTP(w, r)
	})
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "same-origin")
		w.Header().Set("X-Frame-Options", "DENY")
		if strings.HasPrefix(r.URL.Path, "/api/") || strings.HasPrefix(r.URL.Path, "/dav/") {
			w.Header().Set("Cache-Control", "no-store")
		}
		if origin := r.Header.Get("Origin"); origin != "" {
			scheme := "http"
			if r.TLS != nil || a.secureCookie {
				scheme = "https"
			}
			if origin != scheme+"://"+r.Host && !a.allowedOrigins[origin] {
				fail(w, 403, "Origin is not allowed.")
				return
			}
			w.Header().Set("Access-Control-Allow-Origin", origin)
			w.Header().Set("Vary", "Origin")
			w.Header().Set("Access-Control-Allow-Credentials", "true")
			w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization, If-Match")
			w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
			if r.Method == "OPTIONS" && strings.HasPrefix(r.URL.Path, "/api/") {
				w.WriteHeader(204)
				return
			}
		}
		r.Body = http.MaxBytesReader(w, r.Body, 1024*1024)
		mux.ServeHTTP(w, r)
		if r.Method == "POST" || r.Method == "PUT" {
			select {
			case a.store.notificationWake <- struct{}{}:
			default:
			}
		}
	})
}
func main() {
	demo := flag.Bool("seed-demo", false, "Create local demo accounts and sample events")
	flag.Parse()
	dataFile := env("DATA_FILE", "../data/spacetime.db")
	if os.Getenv("DATA_FILE") == "" {
		if _, err := os.Stat(dataFile); os.IsNotExist(err) {
			if _, err := os.Stat("../data/daybook.db"); err == nil {
				dataFile = "../data/daybook.db"
			}
		}
	}
	store, err := openStore(dataFile)
	if err != nil {
		log.Fatal(err)
	}
	defer store.db.Close()
	if err := migrateStore(store); err != nil {
		log.Fatal(err)
	}
	if *demo {
		if err := seedDemo(store); err != nil {
			log.Fatal(err)
		}
	}
	app := newApp(store)
	if os.Getenv("GRAVITAS_ISSUER") != "" && app.gravitas == nil {
		log.Fatal("GRAVITAS_ISSUER and PUBLIC_URL must be HTTPS origins without paths or credentials")
	}
	if app.gravitas != nil && app.gravitas.sessionChecks && len(app.gravitas.sessionKey) != 32 {
		log.Fatal("GRAVITAS_SESSION_KEY must be a base64 encoded 32-byte key when session checks are enabled")
	}
	server := &http.Server{Addr: env("ADDR", "127.0.0.1:8080"), Handler: app.handler(), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 20 * time.Second, WriteTimeout: 150 * time.Second, IdleTimeout: 60 * time.Second}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go app.runNotifications(ctx)
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdown)
	}()
	log.Printf("Spacetime listening on http://%s", server.Addr)
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
}
