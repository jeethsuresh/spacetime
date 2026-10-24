package main

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	bolt "go.etcd.io/bbolt"
	"net/http"
	"net/url"
	"regexp"
	"time"
)

const nativeCallback = "cool.gravitas.spacetime:/auth/callback"

var nativeStatePattern = regexp.MustCompile(`^[A-Za-z0-9_-]{43,128}$`)
var nativeVerifierPattern = regexp.MustCompile(`^[A-Za-z0-9._~-]{43,128}$`)

func validNativeChallenge(v string) bool {
	b, err := base64.RawURLEncoding.DecodeString(v)
	return err == nil && len(b) == 32 && base64.RawURLEncoding.EncodeToString(b) == v
}

type nativeHandoff struct {
	Username, Challenge string
	Expires             time.Time
	Gravitas            *gravitasSession
}

func redirectGravitasResult(w http.ResponseWriter, r *http.Request, flow gravitasFlow, result, code string) {
	target := "/?gravitas=" + result
	if flow.NativeState != "" {
		q := url.Values{"state": {flow.NativeState}, "result": {result}}
		if code != "" {
			q.Set("code", code)
		}
		target = nativeCallback + "?" + q.Encode()
	}
	http.Redirect(w, r, target, http.StatusSeeOther)
}

// The callback contains only a one-use handoff, never a bearer or IAM token.
// Intercepting a private-use URI is insufficient: exchange requires the S256 verifier.
func (a *App) gravitasAndroidExchange(w http.ResponseWriter, r *http.Request) {
	if a.gravitas == nil {
		fail(w, 404, "Gravitas login is not configured.")
		return
	}
	if !a.limiter.allow(r, 30) {
		fail(w, 429, "Too many attempts. Try again in a minute.")
		return
	}
	var body struct {
		Code     string `json:"code"`
		Verifier string `json:"code_verifier"`
	}
	if !decode(w, r, &body) {
		return
	}
	if !nativeVerifierPattern.MatchString(body.Verifier) || len(body.Code) != 48 {
		fail(w, 400, "Invalid Android login.")
		return
	}
	sum := sha256.Sum256([]byte(body.Verifier))
	challenge := base64.RawURLEncoding.EncodeToString(sum[:])
	token := randomID()
	var user User
	var binding *gravitasSession
	if a.gravitas.sessionChecks {
		var pending nativeHandoff
		err := a.store.db.View(func(tx *bolt.Tx) error { return getJSON(tx, "native_handoffs", tokenKey(body.Code), &pending) })
		if err != nil || time.Now().After(pending.Expires) || subtle.ConstantTimeCompare([]byte(challenge), []byte(pending.Challenge)) != 1 {
			fail(w, 401, "Android login expired. Please try again.")
			return
		}
		if status := a.gravitas.checkSession(r.Context(), pending.Gravitas); status != 200 {
			fail(w, status, "Could not verify Gravitas login. Please try again.")
			return
		}
	}
	err := a.store.db.Update(func(tx *bolt.Tx) error {
		var handoff nativeHandoff
		if err := getJSON(tx, "native_handoffs", tokenKey(body.Code), &handoff); err != nil {
			return err
		}
		if time.Now().After(handoff.Expires) || subtle.ConstantTimeCompare([]byte(challenge), []byte(handoff.Challenge)) != 1 {
			return errors.New("invalid handoff")
		}
		var err error
		binding = handoff.Gravitas
		user, err = userTx(tx, handoff.Username)
		if err != nil {
			return err
		}
		if err := putJSON(tx, "sessions", tokenKey(token), Session{Username: user.Username, Expires: time.Now().Add(7 * 24 * time.Hour), Gravitas: handoff.Gravitas}); err != nil {
			return err
		}
		return tx.Bucket([]byte("native_handoffs")).Delete([]byte(tokenKey(body.Code)))
	})
	if err != nil {
		fail(w, 401, "Android login expired. Please try again.")
		return
	}
	writeJSON(w, 200, map[string]any{"user": publicAccount(user, binding), "token": token})
}
