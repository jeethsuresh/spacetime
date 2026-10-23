package main

import (
	"context"
	"encoding/json"
	bolt "go.etcd.io/bbolt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestSharedCalendarConsentIsExplicitAndPinned(t *testing.T) {
	x, iam := setupGravitas(t)
	x.expect(x.req("GET", "/auth/gravitas/start?groups=1&prompt=none", "", nil, nil), 400)
	w := x.req("GET", "/auth/gravitas/start?groups=1", "", nil, nil)
	x.expect(w, 303)
	if strings.Contains(w.Header().Get("Location"), "scope=") {
		t.Fatal("requested unsupported scopes")
	}
	iam.sharedScopes = true
	x.app.gravitas.sessionChecks = true
	x.app.gravitas.sessionKey = []byte(strings.Repeat("k", 32))
	w = x.req("GET", "/auth/gravitas/start?groups=1", "", nil, nil)
	x.expect(w, 303)
	u, _ := url.Parse(w.Header().Get("Location"))
	q := u.Query()
	if q.Get("scope") != sharedCalendarScopes || q.Get("prompt") == "none" || q.Get("all_rooms") != "" {
		t.Fatal("consent scope or room selection mismatch", q)
	}
	iam.challenge = q.Get("codeChallenge")
	var browser *http.Cookie
	for _, c := range w.Result().Cookies() {
		if c.Name == gravitasFlowCookie(q.Get("state")) {
			browser = c
		}
	}
	if browser == nil {
		t.Fatal("missing browser binding")
	}
	response := finishGravitas(x, q, browser, url.Values{"code": {"one-use-code"}})
	x.expect(response, 303)
	found := false
	x.app.store.db.View(func(tx *bolt.Tx) error {
		return tx.Bucket([]byte("sessions")).ForEach(func(_, v []byte) error {
			if strings.Contains(string(v), "private-access-token") || strings.Contains(string(v), "private-refresh-token") {
				t.Fatal("plaintext IAM credential")
			}
			var s Session
			if json.Unmarshal(v, &s) == nil && s.Gravitas != nil && s.Gravitas.GroupCredentials != "" {
				found = true
			}
			return nil
		})
	})
	if !found {
		t.Fatal("explicit consent did not persist bound credentials", response.Header().Get("Location"))
	}
	// Even a token response containing broader scopes cannot upgrade ordinary login.
	q, browser = beginGravitas(t, x, iam, false)
	response = finishGravitas(x, q, browser, url.Values{"code": {"one-use-code"}})
	x.expect(response, 303)
	for _, c := range response.Result().Cookies() {
		if c.Name == "__Host-spacetime_session" {
			x.app.store.db.View(func(tx *bolt.Tx) error {
				var s Session
				err := getJSON(tx, "sessions", tokenKey(c.Value), &s)
				if err == nil && s.Gravitas.GroupCredentials != "" {
					t.Fatal("ordinary login silently gained group scopes")
				}
				return err
			})
		}
	}
}

func TestGroupRefreshIsSerializedAndPersistedBeforeUse(t *testing.T) {
	x := setup(t)
	x.register("alice")
	var rotations atomic.Int32
	var server *httptest.Server
	server = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/oauth/token" {
			r.ParseForm()
			if r.Form.Get("refresh_token") != "old-refresh" || rotations.Add(1) != 1 {
				http.Error(w, "invalid", 400)
				return
			}
			writeJSON(w, 200, map[string]any{"access_token": "new-access", "refresh_token": "new-refresh", "scope": sharedCalendarScopes, "session_id": "family", "token_type": "Bearer", "expires_in": 3600})
			return
		}
		if r.URL.Path == "/app/v1/groups" && r.Header.Get("Authorization") == "Bearer new-access" {
			writeJSON(w, 200, map[string]any{"groups": []gravitasGroup{}})
			return
		}
		http.Error(w, "invalid", 401)
	}))
	defer server.Close()
	g, err := newGravitasAuth(server.URL, "https://spacetime.example", "")
	if err != nil {
		t.Fatal(err)
	}
	g.client.Transport = server.Client().Transport
	g.sessionKey = []byte(strings.Repeat("k", 32))
	x.app.gravitas = g
	binding := &gravitasSession{Issuer: server.URL, Subject: "alice", Origin: g.origin, SessionID: "family"}
	binding.GroupCredentials, err = g.sealGroups(binding, groupCredentials{Access: "old-access", Refresh: "old-refresh", Scope: sharedCalendarScopes, TokenEndpoint: server.URL + "/oauth/token", Expires: time.Now().Add(-time.Minute)})
	if err != nil {
		t.Fatal(err)
	}
	var session Session
	key := tokenKey(x.tokens["alice"])
	x.app.store.db.Update(func(tx *bolt.Tx) error {
		if err := getJSON(tx, "sessions", key, &session); err != nil {
			return err
		}
		session.Gravitas = binding
		return putJSON(tx, "sessions", key, session)
	})
	ctx := context.WithValue(context.WithValue(t.Context(), sessionContextKey{}, session), sessionStorageKey{}, key)
	var wg sync.WaitGroup
	for i := 0; i < 5; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, enabled, err := x.app.currentGroups(ctx)
			if err != nil || !enabled {
				t.Errorf("refresh: %v", err)
			}
		}()
	}
	wg.Wait()
	if rotations.Load() != 1 {
		t.Fatal("refresh credential rotated more than once")
	}
	x.app.store.db.View(func(tx *bolt.Tx) error {
		getJSON(tx, "sessions", key, &session)
		c, err := g.openGroups(session.Gravitas)
		if err != nil || c.Refresh != "new-refresh" {
			t.Fatal("new credential not persisted", err)
		}
		return nil
	})
}
