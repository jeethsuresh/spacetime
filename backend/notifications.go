package main

import (
	"bytes"
	"context"
	"crypto/hmac"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"time"

	bolt "go.etcd.io/bbolt"
)

// The gateway changes only the TCP destination. The HTTPS URL still controls
// the Host header, SNI and certificate verification, and redirects stay disabled.
func newNotificationHTTP(gateway string) (*http.Client, error) {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil
	if gateway != "" {
		if _, _, err := net.SplitHostPort(gateway); err != nil {
			return nil, err
		}
		dialer := &net.Dialer{Timeout: 5 * time.Second}
		transport.DialContext = func(ctx context.Context, network, _ string) (net.Conn, error) {
			return dialer.DialContext(ctx, network, gateway)
		}
	}
	return &http.Client{Transport: transport, Timeout: 10 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}, nil
}

type notificationProvider struct{ ID, Issuer, Subject string }
type notificationPayload struct {
	Kind     string     `json:"kind"`
	EventID  string     `json:"event_id"`
	Version  int        `json:"version"`
	Username string     `json:"username"`
	Title    string     `json:"title"`
	Start    *time.Time `json:"start,omitempty"`
}
type queuedNotification struct {
	ID       string              `json:"id"`
	Provider string              `json:"provider"`
	Payload  notificationPayload `json:"payload"`
}

// Storage fields must survive restarts; the wire envelope contains only the
// public fields above. Never store credentials or a phone-supplied callback.
type notificationRecord struct {
	Message       queuedNotification
	Created, Next time.Time
	Attempts      int
}

func (a *App) notificationProvider(w http.ResponseWriter, r *http.Request) {
	if len(a.notificationKey) < 32 || a.notificationStore == "" || !hmac.Equal([]byte(tokenKey(bearerToken(r))), []byte(tokenKey(a.notificationKey))) {
		fail(w, 401, "Unauthorized provider.")
		return
	}
	id := r.PathValue("id")
	if len(id) != 64 {
		fail(w, 400, "Invalid provider.")
		return
	}
	var in struct {
		Issuer   string `json:"issuer"`
		Subject  string `json:"subject"`
		Callback string `json:"callback"`
		Enabled  bool   `json:"enabled"`
	}
	if !decode(w, r, &in) {
		return
	}
	if in.Callback != a.notificationStore+"/v1/notifications/spacetime" || a.gravitas == nil || in.Issuer != a.gravitas.issuer || in.Subject == "" || len(in.Subject) > 200 {
		fail(w, 400, "Untrusted provider identity or callback.")
		return
	}
	err := a.store.db.Update(func(tx *bolt.Tx) error {
		if !in.Enabled {
			if err := tx.Bucket([]byte("notification_providers")).Delete([]byte(id)); err != nil {
				return err
			}
			return removeProviderNotifications(tx, id)
		}
		var prior notificationProvider
		if getJSON(tx, "notification_providers", id, &prior) == nil && (prior.Issuer != in.Issuer || prior.Subject != in.Subject) {
			if err := removeProviderNotifications(tx, id); err != nil {
				return err
			}
		}
		return putJSON(tx, "notification_providers", id, notificationProvider{id, in.Issuer, in.Subject})
	})
	if err != nil {
		serveError(w, err)
		return
	}
	w.WriteHeader(204)
}
func bearerToken(r *http.Request) string {
	v := r.Header.Get("Authorization")
	if len(v) > 7 && v[:7] == "Bearer " {
		return v[7:]
	}
	return ""
}
func removeProviderNotifications(tx *bolt.Tx, id string) error {
	c := tx.Bucket([]byte("notification_outbox")).Cursor()
	for k, v := c.First(); k != nil; k, v = c.Next() {
		var n notificationRecord
		if json.Unmarshal(v, &n) != nil {
			return statusError(500, "Invalid outbox record.")
		}
		if n.Message.Provider == id {
			if err := c.Delete(); err != nil {
				return err
			}
		}
	}
	return nil
}

// Called in the SAME write transaction as every event save (JSON, CalDAV,
// recurrence edits and source imports). A failed/rolled-back edit sends nothing.
func queueEventNotifications(tx *bolt.Tx, old, e Event) error {
	if old.ID != "" && old.Version >= e.Version {
		return nil
	}
	recipients := map[string]string{}
	for name, status := range e.Attendees {
		if status != "pending" && status != "accepted" {
			continue
		}
		if old.Attendees[name] == "" {
			recipients[name] = "event.invited"
		} else if old.ID != "" {
			recipients[name] = "event.updated"
		}
	}
	if old.ID != "" {
		recipients[e.Owner] = "event.updated"
	}
	if len(recipients) == 0 {
		return nil
	}
	return tx.Bucket([]byte("notification_providers")).ForEach(func(_, v []byte) error {
		var p notificationProvider
		if err := json.Unmarshal(v, &p); err != nil {
			return err
		}
		var identity gravitasIdentity
		if getJSON(tx, "gravitas_identities", tokenKey(p.Issuer+"\x00"+p.Subject), &identity) != nil || identity.Issuer != p.Issuer || identity.Subject != p.Subject {
			return nil
		}
		kind := recipients[identity.Username]
		if kind == "" {
			return nil
		}
		// One stable delivery per mutation and recipient/device registration.
		id := tokenKey(e.ID + "\x00" + p.ID + "\x00" + timeKey(e.Version))
		if tx.Bucket([]byte("notification_outbox")).Get([]byte(id)) != nil {
			return nil
		}
		payload := notificationPayload{kind, e.ID, e.Version, identity.Username, e.Title, e.Start}
		now := time.Now().UTC()
		return putJSON(tx, "notification_outbox", id, notificationRecord{Message: queuedNotification{ID: id, Provider: p.ID, Payload: payload}, Created: now, Next: now})
	})
}
func timeKey(version int) string { b, _ := json.Marshal(version); return string(b) }
func (a *App) runNotifications(ctx context.Context) {
	timer := time.NewTicker(30 * time.Second)
	defer timer.Stop()
	for {
		a.sendNotifications(ctx)
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
		case <-a.store.notificationWake:
		}
	}
}
func (a *App) sendNotifications(ctx context.Context) {
	if len(a.notificationKey) < 32 || a.notificationStore == "" {
		return
	}
	var pending []notificationRecord
	_ = a.store.db.Update(func(tx *bolt.Tx) error {
		c := tx.Bucket([]byte("notification_outbox")).Cursor()
		now := time.Now()
		for k, v := c.First(); k != nil; k, v = c.Next() {
			var n notificationRecord
			if err := json.Unmarshal(v, &n); err != nil {
				return err
			}
			if now.Sub(n.Created) > 7*24*time.Hour {
				if err := c.Delete(); err != nil {
					return err
				}
				continue
			}
			if !n.Next.After(now) && len(pending) < 256 {
				pending = append(pending, n)
			}
		}
		return nil
	})
	client := a.notificationHTTP
	if client == nil {
		client = &http.Client{Timeout: 10 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	}
	for _, n := range pending {
		if ctx.Err() != nil {
			return
		}
		data, _ := json.Marshal(n.Message)
		request, err := http.NewRequestWithContext(ctx, "POST", a.notificationStore+"/v1/notifications/spacetime", bytes.NewReader(data))
		if err != nil {
			return
		}
		request.Header.Set("Content-Type", "application/json")
		request.Header.Set("Authorization", "Bearer "+a.notificationKey)
		response, err := client.Do(request)
		status := 0
		if err == nil {
			status = response.StatusCode
			io.Copy(io.Discard, io.LimitReader(response.Body, 4096))
			response.Body.Close()
		}
		_ = a.store.db.Update(func(tx *bolt.Tx) error {
			// Provider removal or account switching may have won the race.
			if tx.Bucket([]byte("notification_outbox")).Get([]byte(n.Message.ID)) == nil {
				return nil
			}
			if status == 204 {
				return tx.Bucket([]byte("notification_outbox")).Delete([]byte(n.Message.ID))
			}
			if status == 410 {
				if err := tx.Bucket([]byte("notification_providers")).Delete([]byte(n.Message.Provider)); err != nil {
					return err
				}
				return removeProviderNotifications(tx, n.Message.Provider)
			}
			n.Attempts++
			shift := n.Attempts
			if shift > 6 {
				shift = 6
			}
			n.Next = time.Now().Add(time.Duration(1<<shift) * 30 * time.Second)
			return putJSON(tx, "notification_outbox", n.Message.ID, n)
		})
	}
}
