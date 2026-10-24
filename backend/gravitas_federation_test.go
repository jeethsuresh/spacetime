package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"
)

type federationTransport func(*http.Request) (*http.Response, error)

func (f federationTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestUsernameFederationBindsCallbackSessionAndDistinctAccounts(t *testing.T) {
	x := setup(t)
	g, err := newGravitasAuth("https://accounts.example", "https://spacetime.example", "")
	if err != nil {
		t.Fatal(err)
	}
	g.sessionChecks = true
	g.sessionKey = []byte(strings.Repeat("k", 32))
	x.app.gravitas, x.app.secureCookie = g, true
	challenge, name := "", "alice"
	revoked := false
	expires := time.Now().Add(time.Hour).Unix()
	g.client.Transport = federationTransport(func(r *http.Request) (*http.Response, error) {
		if r.URL.Host != "accounts.example" && r.URL.Host != "remote.example" {
			t.Fatalf("unbound issuer request: %s", r.URL)
		}
		issuer := "https://" + r.URL.Host
		var body any
		status := 200
		switch r.URL.Path {
		case "/.well-known/iam-configuration":
			body = gravitasMetadata{Issuer: issuer, Domain: r.URL.Host, Browser: issuer + "/oauth/start", Token: issuer + "/oauth/token", Profile: issuer + "/app/v1/me", Session: issuer + "/oauth/session"}
		case "/oauth/token":
			_ = r.ParseForm()
			hash := sha256.Sum256([]byte(r.Form.Get("code_verifier")))
			if base64.RawURLEncoding.EncodeToString(hash[:]) != challenge || r.Form.Get("redirect_uri") != g.origin+"/auth/gravitas/callback" {
				t.Fatal("lost PKCE binding")
			}
			body = map[string]any{"access_token": "private-access", "token_type": "Bearer", "session_check_token": strings.Repeat("p", 43), "session_id": "family", "session_check_expires_in": 3600}
		case "/app/v1/me":
			if r.Header.Get("Authorization") != "Bearer private-access" {
				t.Fatal("wrong issuer token")
			}
			body = map[string]string{"sub": "same-subject", "username": name, "name": name, "domain": r.URL.Host, "user_id": "@" + name + ":" + r.URL.Host}
		case "/oauth/session":
			if r.Header.Get("Authorization") != "Bearer "+strings.Repeat("p", 43) {
				t.Fatal("lost session binding")
			}
			if revoked {
				status = 401
			}
			body = map[string]any{"active": !revoked, "iss": issuer, "sub": "same-subject", "app_origin": g.origin, "session_id": "family", "exp": expires}
		default:
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
		raw, _ := json.Marshal(body)
		return &http.Response{StatusCode: status, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(string(raw)))}, nil
	})
	login := func(input string) *http.Response {
		w := x.req("GET", "/auth/gravitas/start?username="+url.QueryEscape(input), "", nil, nil)
		x.expect(w, 303)
		target, _ := url.Parse(w.Header().Get("Location"))
		challenge = target.Query().Get("codeChallenge")
		if target.Query().Get("login_hint") == "" {
			t.Fatal("missing username hint")
		}
		result := finishGravitas(x, target.Query(), w.Result().Cookies()[0], url.Values{"code": {"code"}})
		return result.Result()
	}
	remote := login("alice@remote.example")
	if remote.Header.Get("Location") != "/?gravitas=connected" {
		t.Fatal("remote login failed")
	}
	var remoteCookie *http.Cookie
	for _, cookie := range remote.Cookies() {
		if cookie.Name == "__Host-spacetime_session" {
			remoteCookie = cookie
		}
	}
	if remoteCookie == nil {
		t.Fatal("remote app session missing")
	}
	getUser := func(cookie *http.Cookie) User {
		w := x.req("GET", "/api/me", "", nil, map[string]string{"Cookie": cookie.String()})
		x.expect(w, 200)
		var account map[string]any
		_ = json.Unmarshal(w.Body.Bytes(), &account)
		if !strings.HasPrefix(account["gravitas_user_id"].(string), "@alice:") {
			t.Fatal("public identity missing for reauthorization")
		}
		var user User
		_ = json.Unmarshal(w.Body.Bytes(), &user)
		return user
	}
	remoteUser := getUser(remoteCookie)
	local := login("alice")
	var localCookie *http.Cookie
	for _, cookie := range local.Cookies() {
		if cookie.Name == "__Host-spacetime_session" {
			localCookie = cookie
		}
	}
	if localCookie == nil || getUser(localCookie).Username == remoteUser.Username {
		t.Fatal("same subjects on different issuers merged accounts")
	}
	name = "bob"
	if wrong := login("alice@remote.example"); wrong.Header.Get("Location") != "/?gravitas=failed" {
		t.Fatal("accepted the wrong account")
	}
	revoked = true
	x.expect(x.req("GET", "/api/me", "", nil, map[string]string{"Cookie": remoteCookie.String()}), 401)
	w := x.req("GET", "/auth/gravitas/start?screen=register&username=alice%40remote.example", "", nil, nil)
	x.expect(w, 303)
	registration, _ := url.Parse(w.Header().Get("Location"))
	if registration.Host != "accounts.example" || registration.Query().Get("screen") != "register" || registration.Query().Get("login_hint") != "" || g.DefaultDomain() != "accounts.example" {
		t.Fatal("registration and bare-name defaults differ")
	}
}
