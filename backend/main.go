package main

import (
	"context"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/emersion/go-webdav/caldav"
)

type App struct {
	store          *Store
	limiter        limiter
	secureCookie   bool
	allowedOrigins map[string]bool
	static         string
}

func env(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}
func newApp(store *Store) *App {
	a := &App{store: store, limiter: limiter{attempts: map[string]attempt{}}, secureCookie: os.Getenv("COOKIE_SECURE") == "1", allowedOrigins: map[string]bool{}, static: env("STATIC_DIR", "../frontend/build/web")}
	for _, origin := range strings.Split(os.Getenv("ALLOWED_ORIGINS"), ",") {
		if origin != "" {
			a.allowedOrigins[origin] = true
		}
	}
	return a
}
func (a *App) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) { writeJSON(w, 200, map[string]string{"status": "ok"}) })
	mux.HandleFunc("POST /api/register", a.credentials)
	mux.HandleFunc("POST /api/login", a.credentials)
	protected := func(pattern string, fn http.HandlerFunc) { mux.Handle(pattern, a.auth(fn)) }
	protected("POST /api/logout", a.logout)
	protected("GET /api/me", func(w http.ResponseWriter, r *http.Request) {
		u, err := a.store.user(currentUser(r.Context()))
		if err != nil {
			serveError(w, err)
			return
		}
		writeJSON(w, 200, u)
	})
	protected("GET /api/events", a.listEvents)
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
	dav := a.basic(davBackend.serve(&caldav.Handler{Backend: davBackend, Prefix: "/dav"}))
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
	server := &http.Server{Addr: env("ADDR", "127.0.0.1:8080"), Handler: newApp(store).handler(), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 20 * time.Second, WriteTimeout: 30 * time.Second, IdleTimeout: 60 * time.Second}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
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
