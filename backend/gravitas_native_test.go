package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	bolt "go.etcd.io/bbolt"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"
)

func nativeGrant(t *testing.T, x *testApp, iam *mockIAM, verifier string, desktopCallback ...string) string {
	t.Helper()
	sum := sha256.Sum256([]byte(verifier))
	query := url.Values{"native_state": {strings.Repeat("s", 43)}, "native_challenge": {base64.RawURLEncoding.EncodeToString(sum[:])}}
	if len(desktopCallback) != 0 {
		query.Set("native_return_uri", desktopCallback[0])
	}
	response := x.req("GET", "/auth/gravitas/start?"+query.Encode(), "", nil, nil)
	x.expect(response, 303)
	location, _ := url.Parse(response.Header().Get("Location"))
	q := location.Query()
	iam.challenge = q.Get("codeChallenge")
	cookie := response.Result().Cookies()[0]
	result := finishGravitas(x, q, cookie, url.Values{"code": {"one-use-code"}})
	x.expect(result, 303)
	redirect, _ := url.Parse(result.Header().Get("Location"))
	expectedScheme := "cool.gravitas.spacetime"
	if len(desktopCallback) != 0 {
		expectedScheme = "http"
		if redirect.Host != "127.0.0.1:54321" {
			t.Fatal("desktop callback escaped loopback")
		}
	}
	if redirect.Scheme != expectedScheme || redirect.Path != "/auth/callback" || redirect.Query().Get("state") != strings.Repeat("s", 43) || redirect.Query().Get("result") != "connected" {
		t.Fatalf("bad native redirect %s", redirect)
	}
	for _, c := range result.Result().Cookies() {
		if c.Name == "__Host-spacetime_session" {
			t.Fatal("native flow issued browser bearer")
		}
	}
	code := redirect.Query().Get("code")
	if len(code) != 48 {
		t.Fatal("missing one-use handoff")
	}
	return code
}
func TestNativeGravitasProofAndReplay(t *testing.T) {
	x, iam := setupGravitas(t)
	verifier := strings.Repeat("v", 43)
	code := nativeGrant(t, x, iam, verifier)
	exchange := func(v string) *http.Response {
		w := x.req("POST", "/api/auth/gravitas/android", "", map[string]string{"code": code, "code_verifier": v}, nil)
		return w.Result()
	}
	if exchange(strings.Repeat("w", 43)).StatusCode != 401 {
		t.Fatal("intercepted code accepted without verifier")
	}
	response := exchange(verifier)
	if response.StatusCode != 200 {
		t.Fatal("valid native login failed")
	}
	var payload struct {
		Token string
		User  User
	}
	if json.NewDecoder(response.Body).Decode(&payload) != nil || payload.User.Username == "" {
		t.Fatal("invalid token response")
	}
	response.Body.Close()
	x.expect(x.req("GET", "/api/me", "", nil, map[string]string{"Authorization": "Bearer " + payload.Token}), 200)
	if exchange(verifier).StatusCode != 401 {
		t.Fatal("native code replay accepted")
	}
}
func TestNativeGravitasExpiredAndInvalidRequests(t *testing.T) {
	x, iam := setupGravitas(t)
	for _, q := range []string{"native_challenge=x", "native_state=x", "native_state=" + strings.Repeat("s", 43) + "&native_challenge=" + strings.Repeat("x", 43)} {
		x.expect(x.req("GET", "/auth/gravitas/start?"+q, "", nil, nil), 400)
	}
	code := nativeGrant(t, x, iam, strings.Repeat("v", 43))
	if err := x.app.store.db.Update(func(tx *bolt.Tx) error {
		var h nativeHandoff
		if err := getJSON(tx, "native_handoffs", tokenKey(code), &h); err != nil {
			return err
		}
		h.Expires = time.Now().Add(-time.Second)
		return putJSON(tx, "native_handoffs", tokenKey(code), h)
	}); err != nil {
		t.Fatal(err)
	}
	x.expect(x.req("POST", "/api/auth/gravitas/android", "", map[string]string{"code": code, "code_verifier": strings.Repeat("v", 43)}, nil), 401)
}
func TestGravitasSessionRevocationAndOutage(t *testing.T) {
	x, iam := setupGravitas(t)
	x.app.gravitas.sessionChecks = true
	x.app.gravitas.sessionKey = []byte(strings.Repeat("k", 32))
	q, cookie := beginGravitas(t, x, iam, false)
	result := finishGravitas(x, q, cookie, url.Values{"code": {"one-use-code"}})
	gravitasUser(t, x, result)
	var authCookie *http.Cookie
	for _, c := range result.Result().Cookies() {
		if c.Name == "__Host-spacetime_session" {
			authCookie = c
		}
	}
	headers := map[string]string{"Cookie": authCookie.Name + "=" + authCookie.Value}
	before := iam.checks
	x.expect(x.req("GET", "/api/me", "", nil, headers), 200)
	x.expect(x.req("GET", "/api/events", "", nil, headers), 200)
	if iam.checks != before+2 {
		t.Fatal("positive session result was cached")
	}
	var raw []byte
	x.app.store.db.View(func(tx *bolt.Tx) error {
		raw = append([]byte(nil), tx.Bucket([]byte("sessions")).Get([]byte(tokenKey(authCookie.Value)))...)
		return nil
	})
	if strings.Contains(string(raw), strings.Repeat("p", 43)) {
		t.Fatal("plaintext status credential persisted")
	}
	iam.sessionStatus = 503
	x.expect(x.req("GET", "/api/me", "", nil, headers), 503)
	iam.sessionStatus = 0
	x.expect(x.req("GET", "/api/me", "", nil, headers), 200)
	for _, field := range []string{"iss", "sub", "app_origin", "session_id"} {
		iam.sessionMismatch = field
		x.expect(x.req("GET", "/api/me", "", nil, headers), 401)
	}
	iam.sessionMismatch = ""
	iam.sessionStatus = 401
	x.expect(x.req("GET", "/api/events", "", nil, headers), 401)
}
func TestLegacyFederatedSessionRequiresFreshHandshake(t *testing.T) {
	x, iam := setupGravitas(t)
	q, c := beginGravitas(t, x, iam, false)
	result := finishGravitas(x, q, c, url.Values{"code": {"one-use-code"}})
	gravitasUser(t, x, result)
	x.app.gravitas.sessionChecks = true
	x.app.gravitas.sessionKey = []byte(strings.Repeat("k", 32))
	for _, cookie := range result.Result().Cookies() {
		if cookie.Name == "__Host-spacetime_session" {
			x.expect(x.req("GET", "/api/me", "", nil, map[string]string{"Cookie": cookie.Name + "=" + cookie.Value}), 401)
		}
	}
}

func TestDesktopGravitasLoopbackHandoff(t *testing.T) {
	x, iam := setupGravitas(t)
	verifier := strings.Repeat("v", 43)
	code := nativeGrant(t, x, iam, verifier, "http://127.0.0.1:54321/auth/callback")
	body := map[string]string{"code": code, "code_verifier": verifier}
	x.expect(x.req("POST", "/api/auth/gravitas/android", "", body, nil), 200)
	x.expect(x.req("POST", "/api/auth/gravitas/android", "", body, nil), 401)
}
func TestDesktopGravitasRejectsUntrustedCallbacks(t *testing.T) {
	x, _ := setupGravitas(t)
	sum := sha256.Sum256([]byte(strings.Repeat("v", 43)))
	for _, callback := range []string{"https://evil.example/auth/callback", "http://127.0.0.1.evil.example:54321/auth/callback", "http://localhost:54321/auth/callback", "http://127.0.0.1:80/auth/callback", "http://127.0.0.1:54321/wrong", "http://user@127.0.0.1:54321/auth/callback", "http://127.0.0.1:54321/auth/callback?forward=evil", "http://127.0.0.1:54321/auth/callback#fragment", "http://[::1]:54321/auth/callback"} {
		q := url.Values{"native_state": {strings.Repeat("s", 43)}, "native_challenge": {base64.RawURLEncoding.EncodeToString(sum[:])}, "native_return_uri": {callback}}
		x.expect(x.req("GET", "/auth/gravitas/start?"+q.Encode(), "", nil, nil), 400)
	}
	x.expect(x.req("GET", "/auth/gravitas/start?native_return_uri=http%3A%2F%2F127.0.0.1%3A54321%2Fauth%2Fcallback", "", nil, nil), 400)
}
