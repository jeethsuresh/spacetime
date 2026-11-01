package main

import (
	"context"
	"errors"
	"fmt"
	bolt "go.etcd.io/bbolt"
	"net/http"
	"net/url"
	"strings"
	"time"
)

type iamRequestError struct{ status int }

func (e iamRequestError) Error() string { return "IAM request failed" }

type expectedIdentityKey struct{}

type brokerIdentity struct{ Subject, SessionID string }

// Browser and broker login share the same pinned exchange, identity mapping,
// and encrypted family-proof checks. Broker assertions never create a user.
func (a *App) exchangeGravitasCode(ctx context.Context, m gravitasMetadata, code, verifier, redirect string, expected *brokerIdentity) (User, *gravitasSession, error) {
	g, selectErr := a.gravitas.ForIssuer(m.Issuer)
	if selectErr != nil {
		return User{}, nil, selectErr
	}
	var tokens struct {
		AccessToken           string `json:"access_token"`
		RefreshToken          string `json:"refresh_token"`
		Scope                 string `json:"scope"`
		ExpiresIn             int64  `json:"expires_in"`
		TokenType             string `json:"token_type"`
		SessionCheckToken     string `json:"session_check_token"`
		SessionID             string `json:"session_id"`
		SessionCheckExpiresIn int64  `json:"session_check_expires_in"`
	}
	err := g.json(ctx, "POST", m.Token, url.Values{"grant_type": {"authorization_code"}, "code": {code}, "code_verifier": {verifier}, "redirect_uri": {redirect}}, "", &tokens)
	if err != nil {
		return User{}, nil, err
	}
	if tokens.AccessToken == "" || !strings.EqualFold(tokens.TokenType, "Bearer") {
		return User{}, nil, iamRequestError{401}
	}
	var profile struct {
		Sub, Username, Domain, Name string
		UserID                      string `json:"user_id"`
	}
	err = g.json(ctx, "GET", m.Profile, nil, tokens.AccessToken, &profile)
	if err != nil {
		return User{}, nil, err
	}
	if profile.Sub == "" || len(profile.Sub) > 200 || len(profile.Username) > 80 || profile.Domain != m.Domain || (profile.UserID != "" && profile.UserID != "@"+profile.Username+":"+profile.Domain) || len(profile.Name) > 480 {
		return User{}, nil, iamRequestError{401}
	}
	if username, _ := ctx.Value(expectedIdentityKey{}).(string); username != "" && profile.UserID != "" && profile.UserID != username {
		return User{}, nil, iamRequestError{401}
	}
	if expected != nil && (profile.Sub != expected.Subject || tokens.SessionID != expected.SessionID) {
		return User{}, nil, iamRequestError{401}
	}
	var binding *gravitasSession
	if g.sessionChecks {
		binding, err = g.bindSession(ctx, m.Session, profile.Sub, tokens.SessionID, tokens.SessionCheckToken, tokens.SessionCheckExpiresIn)
		if err != nil {
			return User{}, nil, err
		}
	}
	if binding != nil {
		binding.UserID = profile.UserID
	}
	if consent, _ := ctx.Value(groupConsentKey{}).(bool); consent {
		if binding == nil || !hasGroupScopes(tokens.Scope) || tokens.RefreshToken == "" || tokens.ExpiresIn <= 0 || tokens.ExpiresIn > 3600 {
			return User{}, nil, iamRequestError{403}
		}
		binding.GroupCredentials, err = g.sealGroups(binding, groupCredentials{Access: tokens.AccessToken, Refresh: tokens.RefreshToken, Scope: tokens.Scope, TokenEndpoint: m.Token, Expires: time.Now().Add(time.Duration(tokens.ExpiresIn) * time.Second)})
		if err != nil {
			return User{}, nil, err
		}
	}
	var user User
	err = a.store.db.Update(func(tx *bolt.Tx) error {
		key := tokenKey(g.issuer + "\x00" + profile.Sub)
		var identity gravitasIdentity
		if err := getJSON(tx, "gravitas_identities", key, &identity); err == nil {
			if identity.Issuer != g.issuer || identity.Subject != profile.Sub {
				return errors.New("identity mismatch")
			}
			var err error
			user, err = userTx(tx, identity.Username)
			return err
		} else if !errors.Is(err, errNotFound) {
			return err
		}
		username := profile.Username
		for i := 0; i < 100; i++ {
			if !usernamePattern.MatchString(username) || tx.Bucket([]byte("users")).Get([]byte(username)) != nil {
				username = "g_" + tokenKey(fmt.Sprintf("%s:%d", key, i))[:28]
				continue
			}
			name := profile.Name
			if name == "" {
				name = "Gravitas account"
			}
			user = User{Username: username, Name: name}
			if err := putJSON(tx, "users", username, storedUser{Username: username, Name: name}); err != nil {
				return err
			}
			return putJSON(tx, "gravitas_identities", key, gravitasIdentity{g.issuer, profile.Sub, username})
		}
		return errors.New("could not allocate account")
	})
	return user, binding, err
}

func (a *App) gravitasBrokerExchange(w http.ResponseWriter, r *http.Request) {
	if a.gravitas == nil {
		fail(w, 404, "Gravitas login is not configured.")
		return
	}
	if !a.limiter.allow(r, 30) {
		fail(w, 429, "Too many attempts. Try again in a minute.")
		return
	}
	var body struct {
		Code      string `json:"code"`
		Verifier  string `json:"code_verifier"`
		SessionID string `json:"session_id"`
		Subject   string `json:"sub"`
		Recovery  bool   `json:"recovery"`
	}
	if !decode(w, r, &body) {
		return
	}
	if len(body.Code) < 1 || len(body.Code) > 4096 || !nativeVerifierPattern.MatchString(body.Verifier) || len(body.SessionID) < 1 || len(body.SessionID) > 200 || len(body.Subject) < 1 || len(body.Subject) > 200 {
		fail(w, 400, "Invalid Appstore login.")
		return
	}
	g := a.gravitas
	var prior Session
	priorKey := ""
	if body.Recovery {
		bearer := r.Header.Get("Authorization")
		if !strings.HasPrefix(bearer, "Bearer ") {
			fail(w, 401, "Please log in to reconnect this account.")
			return
		}
		priorKey = tokenKey(strings.TrimPrefix(bearer, "Bearer "))
		err := a.store.db.View(func(tx *bolt.Tx) error {
			if err := getJSON(tx, "sessions", priorKey, &prior); err != nil {
				return err
			}
			if !time.Now().After(prior.Expires) || prior.Gravitas == nil || prior.Gravitas.Issuer != g.issuer || prior.Gravitas.Origin != g.origin || prior.Gravitas.Subject != body.Subject || prior.Gravitas.SessionID != body.SessionID {
				return errors.New("recovery identity mismatch")
			}
			var identity gravitasIdentity
			if err := getJSON(tx, "gravitas_identities", tokenKey(g.issuer+"\x00"+body.Subject), &identity); err != nil {
				return err
			}
			if identity.Issuer != g.issuer || identity.Subject != body.Subject || identity.Username != prior.Username {
				return errors.New("recovery account mismatch")
			}
			return nil
		})
		if err != nil {
			fail(w, 401, "Please log in to reconnect this account.")
			return
		}
	}
	metadata, err := g.metadata(r.Context())
	if err != nil || !g.endpoint(metadata.Broker) || !g.sessionChecks {
		fail(w, 503, "Appstore login is temporarily unavailable.")
		return
	}
	user, binding, err := a.exchangeGravitasCode(r.Context(), metadata, body.Code, body.Verifier, g.origin+"/auth/gravitas/callback", &brokerIdentity{body.Subject, body.SessionID})
	if err != nil {
		status := 503
		var iamErr iamRequestError
		if errors.As(err, &iamErr) && (iamErr.status == 400 || iamErr.status == 401 || iamErr.status == 403) {
			status = 401
		}
		fail(w, status, "Could not complete Appstore login. Please try again.")
		return
	}
	token := randomID()
	err = a.store.db.Update(func(tx *bolt.Tx) error {
		if body.Recovery {
			var old Session
			if err := getJSON(tx, "sessions", priorKey, &old); err != nil {
				return iamRequestError{401}
			}
			if old.Username != user.Username || old.Username != prior.Username || !old.Expires.Equal(prior.Expires) {
				return iamRequestError{401}
			}
			if binding != nil && old.Gravitas != nil && binding.Issuer == old.Gravitas.Issuer && binding.Origin == old.Gravitas.Origin && binding.Subject == old.Gravitas.Subject && binding.SessionID == old.Gravitas.SessionID {
				binding.GroupCredentials = old.Gravitas.GroupCredentials
			}
			if err := tx.Bucket([]byte("sessions")).Delete([]byte(priorKey)); err != nil {
				return err
			}
		}
		return putJSON(tx, "sessions", tokenKey(token), Session{Username: user.Username, Expires: time.Now().Add(7 * 24 * time.Hour), Gravitas: binding})
	})
	if err != nil {
		var iamErr iamRequestError
		if errors.As(err, &iamErr) {
			fail(w, 401, "Please log in to reconnect this account.")
			return
		}
		serveError(w, err)
		return
	}
	writeJSON(w, 200, map[string]any{"token": token, "user": publicAccount(user, binding)})
}
