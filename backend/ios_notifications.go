package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"regexp"
	"strings"

	bolt "go.etcd.io/bbolt"
)

var iosInstallationID = regexp.MustCompile(`^[a-f0-9]{64}$`)

type iosProvider struct {
	Handle     string
	Generation int64
}

func (a *App) iosNotifications(w http.ResponseWriter, r *http.Request) {
	session, _ := r.Context().Value(sessionContextKey{}).(Session)
	binding := session.Gravitas
	if binding == nil || a.gravitas == nil || binding.Issuer != a.gravitas.issuer ||
		!strings.HasPrefix(r.Header.Get("Authorization"), "Bearer ") {
		fail(w, 403, "Sign in with Gravitas to enable notifications.")
		return
	}
	if a.notificationStore == "" || !a.notificationProtocol || len(a.notificationKey) < 32 || a.notificationHTTP == nil {
		fail(w, 503, "iOS notifications are unavailable.")
		return
	}
	var in struct {
		Installation string `json:"installation"`
		Generation   int64  `json:"generation"`
		Token        string `json:"token"`
		Environment  string `json:"environment"`
	}
	if !decode(w, r, &in) {
		return
	}
	if !iosInstallationID.MatchString(in.Installation) || in.Generation <= 0 {
		fail(w, 400, "Invalid notification installation.")
		return
	}
	installation := tokenKey(binding.Subject + "\x00" + in.Installation)
	body := map[string]any{"generation": in.Generation}
	if r.Method == http.MethodPut {
		if in.Token == "" || len(in.Token) > 1024 || (in.Environment != "sandbox" && in.Environment != "production") {
			fail(w, 400, "Invalid APNs registration.")
			return
		}
		proof, err := a.gravitas.openSessionProof(binding)
		if err != nil {
			fail(w, 403, "Sign in again to enable notifications.")
			return
		}
		body["platform"], body["token"], body["environment"], body["session_proof"] = "ios", in.Token, in.Environment, string(proof)
	}
	data, _ := json.Marshal(body)
	req, err := http.NewRequestWithContext(r.Context(), r.Method, a.notificationStore+"/v1/notification-installations/spacetime/"+installation, bytes.NewReader(data))
	if err != nil {
		fail(w, 503, "iOS notifications are unavailable.")
		return
	}
	req.Header.Set("Authorization", "Bearer "+a.notificationKey)
	req.Header.Set("Content-Type", "application/json")
	response, err := a.notificationHTTP.Do(req)
	if err != nil {
		fail(w, 503, "iOS notifications are unavailable.")
		return
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK && response.StatusCode != http.StatusNoContent {
		status := response.StatusCode
		if status != 400 && status != 403 && status != 409 {
			status = 503
		}
		fail(w, status, "Unable to update iOS notifications.")
		return
	}
	var provider string
	if r.Method == http.MethodPut {
		var registered struct {
			Device string `json:"device"`
		}
		if response.StatusCode != http.StatusOK ||
			json.NewDecoder(io.LimitReader(response.Body, 4096)).Decode(&registered) != nil ||
			!iosInstallationID.MatchString(registered.Device) {
			fail(w, 503, "Invalid notification registration response.")
			return
		}
		provider = registered.Device
	}
	err = a.store.db.Update(func(tx *bolt.Tx) error {
		var prior iosProvider
		bucket := tx.Bucket([]byte("ios_notification_providers"))
		if raw := bucket.Get([]byte(installation)); raw != nil {
			if err := json.Unmarshal(raw, &prior); err != nil {
				return err
			}
		}
		if prior.Generation >= in.Generation {
			return nil
		}
		if prior.Handle != "" && prior.Handle != provider {
			if err := tx.Bucket([]byte("notification_providers")).Delete([]byte(prior.Handle)); err != nil {
				return err
			}
			if err := removeProviderNotifications(tx, prior.Handle); err != nil {
				return err
			}
		}
		if provider != "" {
			if err := putJSON(tx, "notification_providers", provider, notificationProvider{provider, binding.Issuer, binding.Subject}); err != nil {
				return err
			}
		}
		return putJSON(tx, "ios_notification_providers", installation, iosProvider{provider, in.Generation})
	})
	if err != nil {
		serveError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
