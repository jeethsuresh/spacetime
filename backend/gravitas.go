package main

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	bolt "go.etcd.io/bbolt"
)

func gravitasFlowCookie(state string) string {
	return "__Host-spacetime_gravitas_" + tokenKey(state)[:24]
}

type gravitasAuth struct {
	federationMu   sync.Mutex
	federated      map[string]*gravitasAuth
	federatedOrder []string
	issuer, origin string
	client         *http.Client
	sessionChecks  bool
	sessionKey     []byte
}

type gravitasMetadata struct {
	Issuer  string   `json:"issuer"`
	Domain  string   `json:"identity_domain"`
	Browser string   `json:"browser_initiation_endpoint"`
	Token   string   `json:"token_endpoint"`
	Profile string   `json:"userinfo_endpoint"`
	Session string   `json:"session_check_endpoint,omitempty"`
	Broker  string   `json:"native_broker_authorization_endpoint,omitempty"`
	Scopes  []string `json:"scopes_supported,omitempty"`
}

type gravitasFlow struct {
	Verifier, BrowserHash, RedirectURI string
	Expires                            time.Time
	Metadata                           gravitasMetadata
	Silent                             bool
	NativeChallenge, NativeState       string
	NativeReturnURI                    string
	Register                           bool
	Groups                             bool
	Username                           string
}

type gravitasIdentity struct {
	Issuer, Subject, Username string
}

func httpsOrigin(raw string) (string, error) {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || (u.Path != "" && u.Path != "/") || u.Opaque != "" {
		return "", errors.New("invalid HTTPS origin")
	}
	return u.Scheme + "://" + u.Host, nil
}

func newGravitasAuth(issuer, origin, gateway string) (*gravitasAuth, error) {
	if issuer == "" {
		return nil, nil
	}
	issuer, err := httpsOrigin(issuer)
	if err != nil {
		return nil, err
	}
	origin, err = httpsOrigin(origin)
	if err != nil {
		return nil, err
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil
	if gateway != "" {
		if _, _, err := net.SplitHostPort(gateway); err != nil {
			return nil, err
		}
		dialer := &net.Dialer{Timeout: 5 * time.Second}
		transport.DialContext = func(ctx context.Context, network, _ string) (net.Conn, error) {
			// Only pinned-issuer endpoints use this client. TLS still verifies the issuer hostname.
			return dialer.DialContext(ctx, network, gateway)
		}
	}
	return &gravitasAuth{issuer: issuer, origin: origin, client: &http.Client{
		Transport: transport, Timeout: 10 * time.Second,
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse },
	}}, nil
}

func (g *gravitasAuth) endpoint(raw string) bool {
	u, err := url.Parse(raw)
	return err == nil && u.Scheme+"://"+u.Host == g.issuer && u.User == nil && u.RawQuery == "" && u.Fragment == "" && strings.HasPrefix(u.Path, "/") && u.Opaque == ""
}

func (g *gravitasAuth) json(ctx context.Context, method, endpoint string, form url.Values, token string, target any) error {
	if !g.endpoint(endpoint) {
		return errors.New("untrusted IAM endpoint")
	}
	var body io.Reader
	if form != nil {
		body = strings.NewReader(form.Encode())
	}
	r, err := http.NewRequestWithContext(ctx, method, endpoint, body)
	if err != nil {
		return err
	}
	r.Header.Set("Accept", "application/json")
	if form != nil {
		r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	response, err := g.client.Do(r)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return iamRequestError{response.StatusCode}
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, 65537))
	if err != nil || len(data) > 65536 {
		return errors.New("invalid IAM response")
	}
	return json.Unmarshal(data, target)
}

func (g *gravitasAuth) metadata(ctx context.Context) (gravitasMetadata, error) {
	var m gravitasMetadata
	err := g.json(ctx, "GET", g.issuer+"/.well-known/iam-configuration", nil, "", &m)
	if err != nil {
		return m, err
	}
	issuer, _ := url.Parse(g.issuer)
	if m.Issuer != g.issuer || m.Domain != issuer.Hostname() || !g.endpoint(m.Browser) || !g.endpoint(m.Token) || !g.endpoint(m.Profile) || (g.sessionChecks && !g.endpoint(m.Session)) {
		return m, errors.New("invalid IAM discovery")
	}
	return m, nil
}

func (a *App) authConfiguration(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if a.gravitas == nil {
		writeJSON(w, 200, map[string]any{"gravitas_enabled": false})
		return
	}
	// This shared cookie is only a navigation hint. It never authenticates an
	// app request or replaces the pinned, state-bound PKCE exchange.
	marker, err := r.Cookie("__Secure-gravitas_signed_in")
	signedInHint := err == nil && marker.Value == "1"
	writeJSON(w, 200, map[string]any{"gravitas_enabled": true, "gravitas_signed_in": signedInHint, "login_url": "/auth/gravitas/start", "register_url": "/auth/gravitas/start?screen=register", "default_domain": a.gravitas.DefaultDomain()})
}

func (a *App) gravitasStart(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if a.gravitas == nil {
		fail(w, 404, "Gravitas login is not configured.")
		return
	}
	if !a.limiter.allow(r, 30) {
		fail(w, 429, "Too many attempts. Try again in a minute.")
		return
	}
	prompt := r.URL.Query().Get("prompt")
	groups := r.URL.Query().Get("groups") != "0"
	if prompt != "" && prompt != "none" {
		fail(w, 400, "Invalid login prompt.")
		return
	}
	nativeChallenge, nativeState := r.URL.Query().Get("native_challenge"), r.URL.Query().Get("native_state")
	if (nativeChallenge != "" || nativeState != "") && (!validNativeChallenge(nativeChallenge) || !nativeStatePattern.MatchString(nativeState)) {
		fail(w, 400, "Invalid Android login request.")
		return
	}
	nativeReturn := r.URL.Query().Get("native_return_uri")
	if nativeReturn != "" && (nativeState == "" || !validDesktopCallback(nativeReturn)) {
		fail(w, 400, "Invalid desktop login callback.")
		return
	}
	raw := r.URL.Query().Get("username")
	if raw == "" {
		raw = r.URL.Query().Get("login_hint")
	}
	g, username, err := a.gravitas.ResolveLogin(raw, r.URL.Query().Get("screen") == "register")
	if err != nil {
		fail(w, 400, "Use a username or user@domain")
		return
	}
	metadata, err := g.metadata(r.Context())
	if err != nil {
		redirectGravitasResult(w, r, gravitasFlow{NativeState: nativeState, NativeReturnURI: nativeReturn}, "unavailable", "")
		return
	}
	if groups && (!g.sessionChecks || !hasGroupScopes(strings.Join(metadata.Scopes, " "))) {
		if r.URL.Query().Get("groups") == "1" {
			redirectGravitasResult(w, r, gravitasFlow{NativeState: nativeState, NativeReturnURI: nativeReturn}, "unavailable", "")
			return
		}
		// Compatible identity servers without group support keep profile login.
		groups = false
	}
	state, browser := randomID(), randomID()
	// 48 random octets give 384 bits of entropy within PKCE's 43–128 character limit.
	verifier := randomID() + randomID()
	flow := gravitasFlow{Verifier: verifier, BrowserHash: tokenKey(browser), RedirectURI: g.origin + "/auth/gravitas/callback", Expires: time.Now().Add(10 * time.Minute), Metadata: metadata, Silent: prompt == "none"}
	flow.NativeChallenge, flow.NativeState = nativeChallenge, nativeState
	flow.NativeReturnURI = nativeReturn
	flow.Register = r.URL.Query().Get("screen") == "register"
	flow.Groups = groups
	flow.Username = username
	err = a.store.db.Update(func(tx *bolt.Tx) error {
		b := tx.Bucket([]byte("gravitas_flows"))
		c := b.Cursor()
		for k, v := c.First(); k != nil; k, v = c.Next() {
			var old gravitasFlow
			if json.Unmarshal(v, &old) != nil || time.Now().After(old.Expires) {
				if err := c.Delete(); err != nil {
					return err
				}
			}
		}
		return putJSON(tx, "gravitas_flows", tokenKey(state), flow)
	})
	if err != nil {
		serveError(w, err)
		return
	}
	http.SetCookie(w, &http.Cookie{Name: gravitasFlowCookie(state), Value: browser, Path: "/", Secure: true, HttpOnly: true, SameSite: http.SameSiteLaxMode, MaxAge: 600})
	challenge := sha256.Sum256([]byte(verifier))
	query := url.Values{"callerURL": {g.origin + "/"}, "redirectURL": {flow.RedirectURI}, "codeChallenge": {base64.RawURLEncoding.EncodeToString(challenge[:])}, "codeChallengeMethod": {"S256"}, "scope": {"profile.name"}, "state": {state}}
	if username != "" {
		query.Set("login_hint", username)
	}
	if groups {
		query.Set("scope", sharedCalendarScopes)
	}
	if prompt == "none" {
		// IAM may reuse previously granted scopes, but must return
		// consent_required when this client still needs authorization.
		query.Set("prompt", prompt)
	}
	if flow.Register {
		query.Set("screen", "register")
	}
	http.Redirect(w, r, metadata.Browser+"?"+query.Encode(), http.StatusSeeOther)
}

func (a *App) gravitasCallback(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Referrer-Policy", "no-referrer")
	if a.gravitas == nil {
		fail(w, 404, "Gravitas login is not configured.")
		return
	}
	q := r.URL.Query()
	if len(q["state"]) != 1 || q.Get("state") == "" || len(q["code"]) > 1 || len(q["error"]) > 1 || (q.Get("code") != "" && q.Get("error") != "") {
		fail(w, 400, "Invalid login callback.")
		return
	}
	cookie, err := r.Cookie(gravitasFlowCookie(q.Get("state")))
	if err != nil {
		fail(w, 400, "Login expired. Please try again.")
		return
	}
	var flow gravitasFlow
	err = a.store.db.Update(func(tx *bolt.Tx) error {
		if err := getJSON(tx, "gravitas_flows", tokenKey(q.Get("state")), &flow); err != nil {
			return err
		}
		browserHash := tokenKey(cookie.Value)
		if time.Now().After(flow.Expires) || subtle.ConstantTimeCompare([]byte(browserHash), []byte(flow.BrowserHash)) != 1 || !a.gravitas.acceptsIssuer(flow.Metadata.Issuer) || flow.RedirectURI != a.gravitas.origin+"/auth/gravitas/callback" {
			return errors.New("invalid login flow")
		}
		return tx.Bucket([]byte("gravitas_flows")).Delete([]byte(tokenKey(q.Get("state"))))
	})
	if err != nil {
		fail(w, 400, "Login expired. Please try again.")
		return
	}
	http.SetCookie(w, &http.Cookie{Name: gravitasFlowCookie(q.Get("state")), Path: "/", Secure: true, HttpOnly: true, SameSite: http.SameSiteLaxMode, MaxAge: -1})
	finish := func(result string) { redirectGravitasResult(w, r, flow, result, "") }
	if outcome := q.Get("error"); outcome != "" {
		if outcome != "login_required" && outcome != "consent_required" && outcome != "access_denied" {
			outcome = "failed"
		}
		if !flow.Silent && (outcome == "login_required" || outcome == "consent_required") {
			outcome = "failed"
		}
		finish(outcome)
		return
	}
	if q.Get("code") == "" {
		finish("failed")
		return
	}
	ctx := context.WithValue(r.Context(), groupConsentKey{}, flow.Groups)
	ctx = context.WithValue(ctx, expectedIdentityKey{}, flow.Username)
	user, binding, err := a.exchangeGravitasCode(ctx, flow.Metadata, q.Get("code"), flow.Verifier, flow.RedirectURI, nil)
	if err != nil {
		finish("failed")
		return
	}
	if flow.NativeState != "" {
		code := randomID()
		err := a.store.db.Update(func(tx *bolt.Tx) error {
			b := tx.Bucket([]byte("native_handoffs"))
			c := b.Cursor()
			for k, v := c.First(); k != nil; k, v = c.Next() {
				var old nativeHandoff
				if json.Unmarshal(v, &old) != nil || time.Now().After(old.Expires) {
					if err := c.Delete(); err != nil {
						return err
					}
				}
			}
			return putJSON(tx, "native_handoffs", tokenKey(code), nativeHandoff{Username: user.Username, Challenge: flow.NativeChallenge, Expires: time.Now().Add(time.Minute), Gravitas: binding})
		})
		if err != nil {
			finish("failed")
			return
		}
		redirectGravitasResult(w, r, flow, "connected", code)
		return
	}
	if _, err := a.issueBoundSession(w, r, user, binding); err != nil {
		finish("failed")
		return
	}
	finish("connected")
}
