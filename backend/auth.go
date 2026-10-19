package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"github.com/emersion/go-webdav"
	"io"
	"net"
	"net/http"
	"regexp"
	"strings"
	"sync"
	"time"

	bolt "go.etcd.io/bbolt"
	"golang.org/x/crypto/bcrypt"
)

type userKey struct{}

func currentUser(ctx context.Context) string { u, _ := ctx.Value(userKey{}).(string); return u }
func tokenKey(token string) string {
	h := sha256.Sum256([]byte(token))
	return hex.EncodeToString(h[:])
}

var usernamePattern = regexp.MustCompile(`^[a-z][a-z0-9_]{2,31}$`)
var dummyHash, _ = bcrypt.GenerateFromPassword([]byte("dummy-password-for-timing"), bcrypt.DefaultCost)

type attempt struct {
	Count int
	Until time.Time
}
type limiter struct {
	sync.Mutex
	attempts map[string]attempt
}

func (l *limiter) allow(r *http.Request, limit int) bool {
	l.Lock()
	defer l.Unlock()
	host, _, _ := net.SplitHostPort(r.RemoteAddr)
	key := host + ":" + strings.Split(r.URL.Path, "/")[1]
	now := time.Now()
	for k, a := range l.attempts {
		if now.After(a.Until) {
			delete(l.attempts, k)
		}
	}
	a := l.attempts[key]
	if a.Until.IsZero() {
		a.Until = now.Add(time.Minute)
	}
	a.Count++
	l.attempts[key] = a
	return a.Count <= limit
}
func requestToken(r *http.Request) string {
	if a := r.Header.Get("Authorization"); strings.HasPrefix(a, "Bearer ") {
		return strings.TrimPrefix(a, "Bearer ")
	}
	if c, err := r.Cookie("spacetime_session"); err == nil {
		return c.Value
	}
	if c, err := r.Cookie("daybook_session"); err == nil {
		return c.Value
	}
	return ""
}
func (a *App) auth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var session Session
		err := a.store.db.View(func(tx *bolt.Tx) error { return getJSON(tx, "sessions", tokenKey(requestToken(r)), &session) })
		if err != nil || time.Now().After(session.Expires) {
			fail(w, 401, "Please sign in to continue.")
			return
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), userKey{}, session.Username)))
	})
}
func (a *App) basic(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !a.limiter.allow(r, 240) {
			fail(w, 429, "Too many requests. Try again in a minute.")
			return
		}
		name, password, ok := r.BasicAuth()
		u, err := a.store.user(strings.ToLower(name))
		hash := u.PasswordHash
		if err != nil {
			hash = dummyHash
		}
		valid := bcrypt.CompareHashAndPassword(hash, []byte(password)) == nil
		if !ok || err != nil || !valid {
			w.Header().Set("WWW-Authenticate", `Basic realm="Spacetime", charset="UTF-8"`)
			http.Error(w, "Invalid credentials", 401)
			return
		}
		ctx := context.WithValue(r.Context(), userKey{}, u.Username)
		ctx = context.WithValue(ctx, davHeadersKey{}, davHeaders{webdav.ConditionalMatch(r.Header.Get("If-Match")), webdav.ConditionalMatch(r.Header.Get("If-None-Match"))})
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}
func decode(w http.ResponseWriter, r *http.Request, v any) bool {
	d := json.NewDecoder(r.Body)
	if err := d.Decode(v); err != nil {
		fail(w, 400, "Invalid request body.")
		return false
	}
	var extra any
	if d.Decode(&extra) != io.EOF {
		fail(w, 400, "Expected one JSON object.")
		return false
	}
	return true
}
func (a *App) credentials(w http.ResponseWriter, r *http.Request) {
	if !a.limiter.allow(r, 20) {
		fail(w, 429, "Too many attempts. Try again in a minute.")
		return
	}
	var body struct{ Username, Password, Name string }
	if !decode(w, r, &body) {
		return
	}
	body.Username = strings.ToLower(strings.TrimSpace(body.Username))
	var u User
	if r.URL.Path == "/api/register" {
		if !usernamePattern.MatchString(body.Username) || len(body.Password) < 10 || len(body.Password) > 72 || len(body.Name) > 80 {
			fail(w, 400, "Use a 3–32 character username (letters, numbers, underscores) and a 10–72 byte password.")
			return
		}
		hash, err := bcrypt.GenerateFromPassword([]byte(body.Password), bcrypt.DefaultCost)
		if err != nil {
			fail(w, 500, "Could not create account.")
			return
		}
		name := strings.TrimSpace(body.Name)
		if name == "" {
			name = body.Username
		}
		u = User{body.Username, name, hash}
		err = a.store.db.Update(func(tx *bolt.Tx) error {
			if _, err := userTx(tx, u.Username); err == nil {
				return statusError(409, "That username is already taken.")
			}
			return putJSON(tx, "users", u.Username, storedUser{u.Username, u.Name, hash})
		})
		if err != nil {
			serveError(w, err)
			return
		}
	} else {
		var err error
		u, err = a.store.user(body.Username)
		hash := u.PasswordHash
		if err != nil {
			hash = dummyHash
		}
		valid := bcrypt.CompareHashAndPassword(hash, []byte(body.Password)) == nil
		if err != nil || !valid {
			fail(w, 401, "Username or password is incorrect.")
			return
		}
	}
	token := randomID()
	expires := time.Now().Add(7 * 24 * time.Hour)
	err := a.store.db.Update(func(tx *bolt.Tx) error {
		b := tx.Bucket([]byte("sessions"))
		c := b.Cursor()
		for k, v := c.First(); k != nil; k, v = c.Next() {
			var s Session
			if json.Unmarshal(v, &s) != nil || time.Now().After(s.Expires) {
				if err := c.Delete(); err != nil {
					return err
				}
			}
		}
		return putJSON(tx, "sessions", tokenKey(token), Session{u.Username, expires})
	})
	if err != nil {
		serveError(w, err)
		return
	}
	http.SetCookie(w, &http.Cookie{Name: "spacetime_session", Value: token, Path: "/", HttpOnly: true, Secure: a.secureCookie || r.TLS != nil, SameSite: http.SameSiteLaxMode, Expires: expires})
	writeJSON(w, 200, map[string]any{"user": u, "token": token})
}
func (a *App) logout(w http.ResponseWriter, r *http.Request) {
	err := a.store.db.Update(func(tx *bolt.Tx) error {
		return tx.Bucket([]byte("sessions")).Delete([]byte(tokenKey(requestToken(r))))
	})
	if err != nil {
		serveError(w, err)
		return
	}
	http.SetCookie(w, &http.Cookie{Name: "spacetime_session", Path: "/", HttpOnly: true, Secure: a.secureCookie || r.TLS != nil, SameSite: http.SameSiteLaxMode, MaxAge: -1})
	http.SetCookie(w, &http.Cookie{Name: "daybook_session", Path: "/", HttpOnly: true, SameSite: http.SameSiteLaxMode, MaxAge: -1})
	w.WriteHeader(204)
}
