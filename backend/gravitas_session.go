package main

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	bolt "go.etcd.io/bbolt"
	"io"
	"net/http"
	"time"
)

// Only a status credential is retained. It is encrypted at rest, cannot read
// profiles or calendar data, and is checked afresh on every protected request.
type gravitasSession struct {
	Issuer, Subject, Origin, SessionID, Endpoint, Proof string
	Expires                                             time.Time
}

func (s gravitasSession) aad() []byte {
	return []byte(s.Issuer + "\x00" + s.Subject + "\x00" + s.Origin + "\x00" + s.SessionID + "\x00" + s.Endpoint + "\x00" + s.Expires.UTC().Format(time.RFC3339Nano))
}
func (g *gravitasAuth) crypt() (cipher.AEAD, error) {
	if len(g.sessionKey) != 32 {
		return nil, errors.New("missing session encryption key")
	}
	block, err := aes.NewCipher(g.sessionKey)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}
func (g *gravitasAuth) bindSession(ctx context.Context, endpoint, sub, id, proof string, seconds int64) (*gravitasSession, error) {
	if !g.endpoint(endpoint) || sub == "" || id == "" || len(id) > 200 || len(proof) < 32 || len(proof) > 4096 || seconds <= 0 || seconds > 30*24*3600 {
		return nil, errors.New("invalid session binding")
	}
	s := &gravitasSession{Issuer: g.issuer, Subject: sub, Origin: g.origin, SessionID: id, Endpoint: endpoint, Expires: time.Now().Add(time.Duration(seconds) * time.Second)}
	aead, err := g.crypt()
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, aead.NonceSize())
	if _, err = rand.Read(nonce); err != nil {
		return nil, err
	}
	s.Proof = base64.RawURLEncoding.EncodeToString(aead.Seal(nonce, nonce, []byte(proof), s.aad()))
	if g.checkSession(ctx, s) != 200 {
		return nil, errors.New("inactive IAM session")
	}
	return s, nil
}
func (g *gravitasAuth) checkSession(ctx context.Context, s *gravitasSession) int {
	if s == nil || s.Issuer != g.issuer || s.Origin != g.origin || !g.endpoint(s.Endpoint) || !time.Now().Before(s.Expires) {
		return 401
	}
	aead, err := g.crypt()
	if err != nil {
		return 503
	}
	encoded, err := base64.RawURLEncoding.DecodeString(s.Proof)
	if err != nil || len(encoded) < aead.NonceSize() {
		return 401
	}
	proof, err := aead.Open(nil, encoded[:aead.NonceSize()], encoded[aead.NonceSize():], s.aad())
	if err != nil {
		return 401
	}
	request, err := http.NewRequestWithContext(ctx, "GET", s.Endpoint, nil)
	if err != nil {
		return 503
	}
	request.Header.Set("Authorization", "Bearer "+string(proof))
	request.Header.Set("Accept", "application/json")
	response, err := g.client.Do(request)
	if err != nil {
		return 503
	}
	defer response.Body.Close()
	if response.StatusCode == 401 {
		return 401
	}
	if response.StatusCode != 200 {
		return 503
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, 65537))
	if err != nil || len(data) > 65536 {
		return 503
	}
	var status struct {
		Active    bool   `json:"active"`
		Issuer    string `json:"iss"`
		Subject   string `json:"sub"`
		Origin    string `json:"app_origin"`
		SessionID string `json:"session_id"`
		Expiry    int64  `json:"exp"`
	}
	if json.Unmarshal(data, &status) != nil {
		return 503
	}
	if !status.Active || status.Issuer != s.Issuer || status.Subject != s.Subject || status.Origin != s.Origin || status.SessionID != s.SessionID || status.Expiry <= time.Now().Unix() {
		return 401
	}
	return 200
}
func (a *App) validateGravitasSession(ctx context.Context, s Session) int {
	if s.Gravitas != nil {
		return a.gravitas.checkSession(ctx, s.Gravitas)
	}
	// Existing federated sessions need a fresh handshake. Password accounts and
	// other devices remain independent of the browser family being logged out.
	federated := false
	err := a.store.db.View(func(tx *bolt.Tx) error {
		return tx.Bucket([]byte("gravitas_identities")).ForEach(func(_, v []byte) error {
			var identity gravitasIdentity
			if json.Unmarshal(v, &identity) == nil && identity.Username == s.Username {
				federated = true
			}
			return nil
		})
	})
	if err != nil {
		return 503
	}
	if federated {
		return 401
	}
	return 200
}
