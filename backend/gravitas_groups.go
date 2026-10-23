package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	bolt "go.etcd.io/bbolt"
)

const sharedCalendarScopes = "profile.name chats.list groups.create groups.manage groups.join"

type groupConsentKey struct{}
type sessionStorageKey struct{}
type gravitasGroup struct {
	ID         string           `json:"id"`
	RoomID     string           `json:"room_id"`
	Name       string           `json:"name"`
	Membership string           `json:"membership"`
	Owner      bool             `json:"owner"`
	Members    []map[string]any `json:"members"`
}
type groupCredentials struct {
	Access, Refresh, Scope, TokenEndpoint string
	Expires                               time.Time
}

func hasGroupScopes(scope string) bool {
	s := " " + strings.Join(strings.Fields(scope), " ") + " "
	for _, v := range []string{"chats.list", "groups.create", "groups.manage", "groups.join"} {
		if !strings.Contains(s, " "+v+" ") {
			return false
		}
	}
	return true
}
func (s *gravitasSession) groupAAD() []byte {
	return []byte("spacetime:groups:v1\x00" + s.Issuer + "\x00" + s.Subject + "\x00" + s.Origin + "\x00" + s.SessionID)
}
func (g *gravitasAuth) sealGroups(s *gravitasSession, c groupCredentials) (string, error) {
	aead, err := g.crypt()
	if err != nil {
		return "", err
	}
	raw, err := json.Marshal(c)
	if err != nil {
		return "", err
	}
	nonce := make([]byte, aead.NonceSize())
	if _, err = rand.Read(nonce); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(aead.Seal(nonce, nonce, raw, s.groupAAD())), nil
}
func (g *gravitasAuth) openGroups(s *gravitasSession) (groupCredentials, error) {
	var c groupCredentials
	aead, err := g.crypt()
	if err != nil {
		return c, err
	}
	raw, err := base64.RawURLEncoding.DecodeString(s.GroupCredentials)
	if err != nil || len(raw) < aead.NonceSize() {
		return c, errors.New("invalid group credential")
	}
	plain, err := aead.Open(nil, raw[:aead.NonceSize()], raw[aead.NonceSize():], s.groupAAD())
	if err != nil {
		return c, err
	}
	err = json.Unmarshal(plain, &c)
	if err == nil && (!hasGroupScopes(c.Scope) || !g.endpoint(c.TokenEndpoint)) {
		err = errors.New("invalid group scope")
	}
	return c, err
}

// The current session, not a username-wide cache, owns the explicitly consented
// credential. Profile-only logins from another family cannot acquire it.
func (a *App) groupCredential(ctx context.Context) (groupCredentials, bool, error) {
	var empty groupCredentials
	s, _ := ctx.Value(sessionContextKey{}).(Session)
	key, _ := ctx.Value(sessionStorageKey{}).(string)
	if a.gravitas == nil || s.Gravitas == nil || s.Gravitas.GroupCredentials == "" || key == "" {
		return empty, false, nil
	}
	// Reload after the caller took groupMu: a simultaneous request may already
	// have rotated the refresh credential and persisted its replacement.
	err := a.store.db.View(func(tx *bolt.Tx) error { return getJSON(tx, "sessions", key, &s) })
	if err != nil || s.Gravitas == nil {
		return empty, false, statusError(401, "Sign in again to use shared calendars.")
	}
	c, err := a.gravitas.openGroups(s.Gravitas)
	if err != nil {
		return empty, false, statusError(403, "Enable shared calendars again in Gravitas.")
	}
	if time.Now().Add(30 * time.Second).Before(c.Expires) {
		return c, true, nil
	}
	var fresh struct {
		Access    string `json:"access_token"`
		Refresh   string `json:"refresh_token"`
		Scope     string `json:"scope"`
		SessionID string `json:"session_id"`
		Type      string `json:"token_type"`
		Seconds   int64  `json:"expires_in"`
	}
	err = a.gravitas.json(ctx, "POST", c.TokenEndpoint, url.Values{"grant_type": {"refresh_token"}, "refresh_token": {c.Refresh}}, "", &fresh)
	if err != nil {
		var iam iamRequestError
		if errors.As(err, &iam) && (iam.status == 400 || iam.status == 401 || iam.status == 403) {
			return empty, false, statusError(403, "Enable shared calendars again in Gravitas.")
		}
		return empty, false, statusError(503, "Gravitas groups are unavailable. Offline changes are kept.")
	}
	if fresh.SessionID != s.Gravitas.SessionID || !strings.EqualFold(fresh.Type, "Bearer") || !hasGroupScopes(fresh.Scope) || fresh.Access == "" || fresh.Refresh == "" || fresh.Seconds <= 0 || fresh.Seconds > 3600 {
		return empty, false, statusError(403, "Gravitas group authorization changed. Reconnect shared calendars.")
	}
	c.Access, c.Refresh, c.Scope, c.Expires = fresh.Access, fresh.Refresh, fresh.Scope, time.Now().Add(time.Duration(fresh.Seconds)*time.Second)
	sealed, err := a.gravitas.sealGroups(s.Gravitas, c)
	if err != nil {
		return empty, false, err
	}
	err = a.store.db.Update(func(tx *bolt.Tx) error {
		var current Session
		if err := getJSON(tx, "sessions", key, &current); err != nil {
			return err
		}
		if current.Gravitas == nil || current.Gravitas.GroupCredentials != s.Gravitas.GroupCredentials {
			return statusError(409, "Group connection changed. Try again.")
		}
		current.Gravitas.GroupCredentials = sealed
		return putJSON(tx, "sessions", key, current)
	})
	return c, true, err
}
func (a *App) groupJSON(ctx context.Context, method, path string, body any, target any) error {
	c, enabled, err := a.groupCredential(ctx)
	if err != nil {
		return err
	}
	if !enabled {
		return statusError(403, "Enable shared calendars with Gravitas first.")
	}
	endpoint := a.gravitas.issuer + "/app/v1/groups" + path
	if !a.gravitas.endpoint(endpoint) {
		return statusError(400, "Invalid group identifier.")
	}
	var data []byte
	if body != nil {
		data, err = json.Marshal(body)
		if err != nil {
			return err
		}
	}
	req, err := http.NewRequestWithContext(ctx, method, endpoint, bytes.NewReader(data))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+c.Access)
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	res, err := a.gravitas.client.Do(req)
	if err != nil {
		return statusError(503, "Gravitas groups are unavailable. Offline changes are kept.")
	}
	defer res.Body.Close()
	if res.StatusCode == 401 || res.StatusCode == 403 {
		return statusError(403, "This Gravitas group action is not authorized. Check membership and consent.")
	}
	if res.StatusCode >= 500 {
		return statusError(503, "Gravitas groups are unavailable. Offline changes are kept.")
	}
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		return statusError(400, "Gravitas could not complete this group action.")
	}
	raw, err := io.ReadAll(io.LimitReader(res.Body, 1024*1024+1))
	if err != nil || len(raw) > 1024*1024 {
		return statusError(502, "Invalid Gravitas group response.")
	}
	if json.Unmarshal(raw, target) != nil {
		return statusError(502, "Invalid Gravitas group response.")
	}
	return nil
}
func (a *App) currentGroups(ctx context.Context) ([]gravitasGroup, bool, error) {
	a.groupMu.Lock()
	defer a.groupMu.Unlock()
	_, enabled, err := a.groupCredential(ctx)
	if err != nil || !enabled {
		return nil, enabled, err
	}
	var result struct {
		Groups []gravitasGroup `json:"groups"`
	}
	err = a.groupJSON(ctx, "GET", "", nil, &result)
	return result.Groups, true, err
}
func (a *App) listGroups(w http.ResponseWriter, r *http.Request) {
	groups := []gravitasGroup{}
	for _, g := range accessFor(r.Context()).Groups {
		groups = append(groups, g)
	}
	writeJSON(w, 200, map[string]any{"groups": groups, "enabled": accessFor(r.Context()).GroupsEnabled})
}
func (a *App) createGroup(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Name        string `json:"name"`
		Transaction string `json:"txn_id"`
	}
	if !decode(w, r, &body) {
		return
	}
	if strings.TrimSpace(body.Name) == "" || len(body.Name) > 80 || !calendarIDPattern.MatchString(body.Transaction) {
		fail(w, 400, "Enter a group name and stable request identifier.")
		return
	}
	a.groupMu.Lock()
	defer a.groupMu.Unlock()
	var result gravitasGroup
	err := a.groupJSON(r.Context(), "POST", "", map[string]string{"name": body.Name, "kind": "space", "txn_id": body.Transaction}, &result)
	if err != nil {
		serveError(w, err)
		return
	}
	writeJSON(w, 201, result)
}
func (a *App) groupMembership(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Action string `json:"action"`
		UserID string `json:"user_id"`
	}
	if !decode(w, r, &body) {
		return
	}
	if body.Action != "invite" && body.Action != "accept" && body.Action != "leave" && body.Action != "remove" {
		fail(w, 400, "Choose a group membership action.")
		return
	}
	id := r.PathValue("id")
	if _, ok := accessFor(r.Context()).Groups[id]; !ok {
		fail(w, 403, "Authorize this Gravitas group first.")
		return
	}
	if body.Action == "invite" || body.Action == "remove" {
		body.UserID = strings.TrimSpace(body.UserID)
		if !strings.HasPrefix(body.UserID, "@") {
			m, err := a.gravitas.metadata(r.Context())
			if err != nil {
				fail(w, 503, "Gravitas is unavailable.")
				return
			}
			body.UserID = "@" + strings.TrimPrefix(body.UserID, "@") + ":" + m.Domain
		}
	}
	a.groupMu.Lock()
	defer a.groupMu.Unlock()
	var result map[string]any
	err := a.groupJSON(r.Context(), "POST", "/"+url.PathEscape(id)+"/membership", map[string]string{"action": body.Action, "user_id": body.UserID}, &result)
	if err != nil {
		serveError(w, err)
		return
	}
	writeJSON(w, 200, result)
}
