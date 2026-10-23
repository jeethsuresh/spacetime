package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	bolt "go.etcd.io/bbolt"
)

type mockIAM struct {
	server                               *httptest.Server
	challenge, subject, username, domain string
	badMetadata, badProfile              bool
	exchanges                            int
	sessionStatus, checks                int
	sessionMismatch                      string
	oneUseCode, missingBroker            bool
	tokenStatus                          int
	sharedScopes                         bool
}

func setupGravitas(t *testing.T) (*testApp, *mockIAM) {
	t.Helper()
	x := setup(t)
	iam := &mockIAM{subject: "stable-principal", username: "jeeth"}
	iam.server = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		base := iam.server.URL
		switch r.URL.Path {
		case "/.well-known/iam-configuration":
			profile := base + "/app/v1/me"
			if iam.badMetadata {
				profile = "https://untrusted.example/me"
			}
			broker := base + "/oauth/broker/authorize"
			if iam.missingBroker {
				broker = ""
			}
			writeJSON(w, 200, gravitasMetadata{Issuer: base, Domain: iam.domain, Browser: base + "/oauth/start", Token: base + "/oauth/token", Profile: profile, Session: base + "/oauth/session", Broker: broker, Scopes: func() []string {
				if iam.sharedScopes {
					return strings.Fields(sharedCalendarScopes)
				}
				return nil
			}()})
		case "/oauth/token":
			if iam.tokenStatus != 0 {
				http.Error(w, "unavailable", iam.tokenStatus)
				return
			}
			if iam.oneUseCode && iam.exchanges > 0 {
				http.Error(w, "invalid grant", 400)
				return
			}
			if r.Method != "POST" {
				t.Error("expected form POST")
			}
			_ = r.ParseForm()
			hash := sha256.Sum256([]byte(r.Form.Get("code_verifier")))
			if r.Form.Get("code") != "one-use-code" || r.Form.Get("redirect_uri") != "https://spacetime.example/auth/gravitas/callback" || r.Form.Get("grant_type") != "authorization_code" || base64.RawURLEncoding.EncodeToString(hash[:]) != iam.challenge {
				http.Error(w, "invalid grant", 400)
				return
			}
			iam.exchanges++
			writeJSON(w, 200, map[string]any{"access_token": "private-access-token", "token_type": "Bearer", "session_check_token": strings.Repeat("p", 43), "session_id": "test-family", "session_check_expires_in": 3600, "scope": sharedCalendarScopes, "refresh_token": "private-refresh-token", "expires_in": 3600})
		case "/oauth/session":
			iam.checks++
			if r.Header.Get("Authorization") != "Bearer "+strings.Repeat("p", 43) {
				http.Error(w, "invalid", 401)
				return
			}
			if iam.sessionStatus != 0 {
				http.Error(w, "unavailable", iam.sessionStatus)
				return
			}
			status := map[string]any{"active": true, "iss": base, "sub": iam.subject, "app_origin": "https://spacetime.example", "session_id": "test-family", "exp": time.Now().Add(time.Hour).Unix()}
			if iam.sessionMismatch != "" {
				status[iam.sessionMismatch] = "mismatch"
			}
			writeJSON(w, 200, status)
		case "/app/v1/me":
			if r.Header.Get("Authorization") != "Bearer private-access-token" {
				http.Error(w, "missing token", 401)
				return
			}
			domain := iam.domain
			if iam.badProfile {
				domain = "different.example"
			}
			writeJSON(w, 200, map[string]string{"sub": iam.subject, "username": iam.username, "name": "Jeeth", "domain": domain, "user_id": "@" + iam.username + ":" + domain})
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(iam.server.Close)
	u, _ := url.Parse(iam.server.URL)
	iam.domain = u.Hostname()
	g, err := newGravitasAuth(iam.server.URL, "https://spacetime.example", "")
	if err != nil {
		t.Fatal(err)
	}
	g.client.Transport = iam.server.Client().Transport
	x.app.gravitas = g
	x.app.secureCookie = true
	return x, iam
}

func beginGravitas(t *testing.T, x *testApp, iam *mockIAM, silent bool) (url.Values, *http.Cookie) {
	t.Helper()
	path := "/auth/gravitas/start"
	if silent {
		path += "?prompt=none"
	}
	w := x.req("GET", path, "", nil, nil)
	x.expect(w, http.StatusSeeOther)
	u, err := url.Parse(w.Header().Get("Location"))
	if err != nil {
		t.Fatal(err)
	}
	q := u.Query()
	if u.Scheme+"://"+u.Host != iam.server.URL || u.Path != "/oauth/start" || q.Get("scope") != "profile.name" || q.Get("codeChallengeMethod") != "S256" || q.Get("callerURL") != "https://spacetime.example/" || q.Get("username") != "" || q.Get("state") == "" || q.Get("redirectURL") != "https://spacetime.example/auth/gravitas/callback" {
		t.Fatalf("invalid initiation: %s", u)
	}
	if silent && q.Get("prompt") != "none" {
		t.Fatal("silent prompt missing")
	}
	iam.challenge = q.Get("codeChallenge")
	var cookie *http.Cookie
	for _, candidate := range w.Result().Cookies() {
		if candidate.Name == gravitasFlowCookie(q.Get("state")) {
			cookie = candidate
		}
	}
	if cookie == nil || !cookie.Secure || !cookie.HttpOnly || cookie.Domain != "" || cookie.Path != "/" || cookie.SameSite != http.SameSiteLaxMode {
		t.Fatal("missing secure browser binding")
	}
	return q, cookie
}

func finishGravitas(x *testApp, q url.Values, cookie *http.Cookie, result url.Values) *httptest.ResponseRecorder {
	result.Set("state", q.Get("state"))
	return x.req("GET", "/auth/gravitas/callback?"+result.Encode(), "", nil, map[string]string{"Cookie": cookie.Name + "=" + cookie.Value})
}

func gravitasUser(t *testing.T, x *testApp, response *httptest.ResponseRecorder) User {
	t.Helper()
	x.expect(response, http.StatusSeeOther)
	if response.Header().Get("Location") != "/?gravitas=connected" {
		t.Fatalf("login failed: %s", response.Header().Get("Location"))
	}
	var cookie *http.Cookie
	for _, c := range response.Result().Cookies() {
		if c.Name == "__Host-spacetime_session" {
			cookie = c
		}
	}
	if cookie == nil || !cookie.Secure || !cookie.HttpOnly || cookie.Domain != "" {
		t.Fatal("missing app session cookie")
	}
	me := x.req("GET", "/api/me", "", nil, map[string]string{"Cookie": cookie.Name + "=" + cookie.Value})
	x.expect(me, 200)
	var user User
	if err := json.Unmarshal(me.Body.Bytes(), &user); err != nil {
		t.Fatal(err)
	}
	return user
}

func TestGravitasPKCEIdentityAndRestart(t *testing.T) {
	x, iam := setupGravitas(t)
	q, cookie := beginGravitas(t, x, iam, true)
	// A restart preserves the pending flow; the verifier never enters the URL or cookie.
	g := x.app.gravitas
	x.app = newApp(x.app.store)
	x.app.gravitas, x.app.secureCookie = g, true
	x.handler = x.app.handler()
	response := finishGravitas(x, q, cookie, url.Values{"code": {"one-use-code"}})
	first := gravitasUser(t, x, response)
	if first.Username != "jeeth" || iam.exchanges != 1 {
		t.Fatal("wrong identity")
	}
	x.expect(finishGravitas(x, q, cookie, url.Values{"code": {"one-use-code"}}), 400)
	// A renamed profile with the same issuer/sub retains its calendar account.
	iam.username = "renamed"
	q, cookie = beginGravitas(t, x, iam, false)
	second := gravitasUser(t, x, finishGravitas(x, q, cookie, url.Values{"code": {"one-use-code"}}))
	if second.Username != first.Username {
		t.Fatal("identity was keyed by mutable username")
	}
}

func TestGravitasDoesNotTakeOverLocalAccounts(t *testing.T) {
	x, iam := setupGravitas(t)
	x.register("jeeth")
	q, cookie := beginGravitas(t, x, iam, false)
	user := gravitasUser(t, x, finishGravitas(x, q, cookie, url.Values{"code": {"one-use-code"}}))
	if user.Username == "jeeth" || !strings.HasPrefix(user.Username, "g_") {
		t.Fatal("federated identity inherited a password account")
	}
	x.expect(x.req("POST", "/api/login", "", map[string]string{"username": "jeeth", "password": "correct horse battery"}, nil), 200)
	x.expect(x.req("POST", "/api/login", "", map[string]string{"username": user.Username, "password": ""}, nil), 401)
}

func TestGravitasIgnoresLegacyDomainCookies(t *testing.T) {
	x, _ := setupGravitas(t)
	x.register("alice")
	token := x.tokens["alice"]
	x.expect(x.req("GET", "/api/me", "", nil, map[string]string{"Cookie": "spacetime_session=" + token}), 401)
	x.expect(x.req("GET", "/api/me", "", nil, map[string]string{"Cookie": "spacetime_session=" + token, "Authorization": "Basic invalid"}), 401)
	x.expect(x.req("GET", "/api/me", "", nil, map[string]string{"Cookie": "__Host-spacetime_session=" + token}), 200)
	x.expect(x.req("GET", "/api/me", "alice", nil, nil), 200)
}

func TestGravitasParallelTabsKeepIndependentBindings(t *testing.T) {
	x, iam := setupGravitas(t)
	first, firstCookie := beginGravitas(t, x, iam, true)
	second, secondCookie := beginGravitas(t, x, iam, true)
	if firstCookie.Name == secondCookie.Name {
		t.Fatal("parallel flows share a binding cookie")
	}
	cookies := firstCookie.Name + "=" + firstCookie.Value + "; " + secondCookie.Name + "=" + secondCookie.Value
	for _, flow := range []url.Values{first, second} {
		iam.challenge = flow.Get("codeChallenge")
		query := url.Values{"state": {flow.Get("state")}, "code": {"one-use-code"}}
		response := x.req("GET", "/auth/gravitas/callback?"+query.Encode(), "", nil, map[string]string{"Cookie": cookies})
		if gravitasUser(t, x, response).Username != "jeeth" {
			t.Fatal("wrong parallel identity")
		}
	}
}

func TestGravitasCallbackBindingAndErrors(t *testing.T) {
	for _, outcome := range []string{"login_required", "consent_required", "access_denied", "unexpected<script>"} {
		t.Run(outcome, func(t *testing.T) {
			x, iam := setupGravitas(t)
			q, cookie := beginGravitas(t, x, iam, true)
			bad := *cookie
			bad.Value = "different-browser"
			x.expect(finishGravitas(x, q, &bad, url.Values{"code": {"one-use-code"}}), 400)
			w := finishGravitas(x, q, cookie, url.Values{"error": {outcome}})
			x.expect(w, 303)
			expected := outcome
			if expected == "unexpected<script>" {
				expected = "failed"
			}
			if w.Header().Get("Location") != "/?gravitas="+expected || iam.exchanges != 0 {
				t.Fatal("unsafe error callback")
			}
			x.expect(finishGravitas(x, q, cookie, url.Values{"error": {outcome}}), 400)
		})
	}
}

func TestGravitasRejectsExpiryAndUntrustedDiscovery(t *testing.T) {
	x, iam := setupGravitas(t)
	q, cookie := beginGravitas(t, x, iam, false)
	err := x.app.store.db.Update(func(tx *bolt.Tx) error {
		var flow gravitasFlow
		if err := getJSON(tx, "gravitas_flows", tokenKey(q.Get("state")), &flow); err != nil {
			return err
		}
		flow.Expires = time.Now().Add(-time.Minute)
		return putJSON(tx, "gravitas_flows", tokenKey(q.Get("state")), flow)
	})
	if err != nil {
		t.Fatal(err)
	}
	x.expect(finishGravitas(x, q, cookie, url.Values{"code": {"one-use-code"}}), 400)
	iam.badMetadata = true
	w := x.req("GET", "/auth/gravitas/start", "", nil, nil)
	x.expect(w, 303)
	if w.Header().Get("Location") != "/?gravitas=unavailable" || len(w.Result().Cookies()) != 0 {
		t.Fatal("untrusted endpoints accepted")
	}
	iam.badMetadata, iam.badProfile = false, true
	q, cookie = beginGravitas(t, x, iam, false)
	w = finishGravitas(x, q, cookie, url.Values{"code": {"one-use-code"}})
	if w.Header().Get("Location") != "/?gravitas=failed" {
		t.Fatal("wrong identity domain accepted")
	}
	if _, err := x.app.store.user("jeeth"); err == nil {
		t.Fatal("invalid profile created an account")
	}
}

func TestGravitasInteractiveErrorCannotRestartPassiveLogin(t *testing.T) {
	x, iam := setupGravitas(t)
	q, cookie := beginGravitas(t, x, iam, false)
	w := finishGravitas(x, q, cookie, url.Values{"error": {"consent_required"}})
	x.expect(w, 303)
	if w.Header().Get("Location") != "/?gravitas=failed" {
		t.Fatal("interactive error could cause a redirect loop")
	}
}

func TestGravitasSharedMarkerIsOnlyAnUncachedHint(t *testing.T) {
	x, _ := setupGravitas(t)
	for _, test := range []struct {
		cookie string
		hint   bool
	}{
		{"", false}, {"__Secure-gravitas_signed_in=1", true},
		{"__Secure-gravitas_signed_in=0", false}, {"gravitas_signed_in=1", false},
	} {
		response := x.req("GET", "/api/auth/config", "", nil, map[string]string{"Cookie": test.cookie})
		x.expect(response, 200)
		var config map[string]any
		if err := json.Unmarshal(response.Body.Bytes(), &config); err != nil {
			t.Fatal(err)
		}
		if config["gravitas_signed_in"] != test.hint || response.Header().Get("Cache-Control") != "no-store" {
			t.Fatal("invalid navigation hint/cache policy")
		}
		x.expect(x.req("GET", "/api/me", "", nil, map[string]string{"Cookie": test.cookie}), 401)
		x.expect(x.req("GET", "/api/events", "", nil, map[string]string{"Cookie": test.cookie}), 401)
		if len(response.Result().Cookies()) != 0 {
			t.Fatal("config must not grant a session")
		}
	}
}
