package main

import (
	"encoding/json"
	bolt "go.etcd.io/bbolt"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

type notificationTransport func(*http.Request) (*http.Response, error)

func (f notificationTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func setupNotificationApp(t *testing.T) *testApp {
	x := setup(t)
	x.register("alex")
	x.register("sam")
	x.register("other")
	x.app.notificationKey = strings.Repeat("n", 48)
	x.app.notificationStore = "https://apps.gravitas.cool"
	x.app.gravitas = &gravitasAuth{issuer: "https://gravitas.cool"}
	if err := x.app.store.db.Update(func(tx *bolt.Tx) error {
		return putJSON(tx, "gravitas_identities", tokenKey("https://gravitas.cool\x00sam-sub"), gravitasIdentity{"https://gravitas.cool", "sam-sub", "sam"})
	}); err != nil {
		t.Fatal(err)
	}
	return x
}
func registerNotificationProvider(t *testing.T, x *testApp, id string, enabled bool) {
	t.Helper()
	x.expect(x.req("PUT", "/api/notifications/providers/"+id, "", map[string]any{"issuer": "https://gravitas.cool", "subject": "sam-sub", "callback": "https://apps.gravitas.cool/v1/notifications/spacetime", "enabled": enabled}, map[string]string{"Authorization": "Bearer " + x.app.notificationKey}), 204)
}
func outbox(t *testing.T, x *testApp) []notificationRecord {
	t.Helper()
	var all []notificationRecord
	if err := x.app.store.db.View(func(tx *bolt.Tx) error {
		return tx.Bucket([]byte("notification_outbox")).ForEach(func(_, v []byte) error {
			var n notificationRecord
			if err := json.Unmarshal(v, &n); err != nil {
				return err
			}
			all = append(all, n)
			return nil
		})
	}); err != nil {
		t.Fatal(err)
	}
	return all
}
func TestNotificationsInvitationUpdateAndTransactionalFailure(t *testing.T) {
	x := setupNotificationApp(t)
	provider := strings.Repeat("a", 64)
	registerNotificationProvider(t, x, provider, true)
	data := example("event")
	data["attendees"] = map[string]string{"sam": "pending"}
	w := x.req("POST", "/api/events", "alex", data, nil)
	x.expect(w, 201)
	e := readEvent(t, w)
	records := outbox(t, x)
	if len(records) != 1 || records[0].Message.Payload.Kind != "event.invited" || records[0].Message.Payload.Username != "sam" || records[0].Message.Payload.EventID != e.ID {
		t.Fatal("wrong invitation", records)
	}
	e.Title = "Updated dinner"
	w = x.req("PUT", "/api/events/"+e.ID, "alex", e, nil)
	x.expect(w, 200)
	records = outbox(t, x)
	if len(records) != 2 {
		t.Fatal("update not queued", records)
	}
	found := false
	for _, n := range records {
		if n.Message.Payload.Kind == "event.updated" && n.Message.Payload.Title == e.Title && n.Message.Payload.Version == 2 {
			found = true
		}
	}
	if !found {
		t.Fatal("missing updated event payload")
	}
	x.expect(x.req("PUT", "/api/events/"+e.ID, "alex", e, nil), 409)
	if len(outbox(t, x)) != 2 {
		t.Fatal("conflicting save sent notification")
	}
	e = readEvent(t, w)
	e.Title = "No permission"
	x.expect(x.req("PUT", "/api/events/"+e.ID, "other", e, nil), 403)
	if len(outbox(t, x)) != 2 {
		t.Fatal("unauthorized save sent notification")
	}
	registerNotificationProvider(t, x, provider, false)
	if len(outbox(t, x)) != 0 {
		t.Fatal("unregistered provider kept pending content")
	}
}
func TestNotificationsServiceAuthenticationCallbackPinAndIdentity(t *testing.T) {
	x := setupNotificationApp(t)
	id := strings.Repeat("b", 64)
	body := map[string]any{"issuer": "https://gravitas.cool", "subject": "sam-sub", "callback": "https://apps.gravitas.cool/v1/notifications/spacetime", "enabled": true}
	x.expect(x.req("PUT", "/api/notifications/providers/"+id, "sam", body, nil), 401)
	body["callback"] = "http://127.0.0.1/admin"
	x.expect(x.req("PUT", "/api/notifications/providers/"+id, "", body, map[string]string{"Authorization": "Bearer " + x.app.notificationKey}), 400)
	body["callback"] = "https://apps.gravitas.cool/v1/notifications/spacetime"
	body["issuer"] = "https://evil.example"
	x.expect(x.req("PUT", "/api/notifications/providers/"+id, "", body, map[string]string{"Authorization": "Bearer " + x.app.notificationKey}), 400)
	registerNotificationProvider(t, x, id, true)
	// Equal usernames on another issuer must never resolve to this recipient.
	_ = x.app.store.db.Update(func(tx *bolt.Tx) error {
		return putJSON(tx, "gravitas_identities", tokenKey("https://gravitas.cool\x00sam-sub"), gravitasIdentity{"https://evil.example", "sam-sub", "sam"})
	})
	data := example("event")
	data["attendees"] = map[string]string{"sam": "pending"}
	x.expect(x.req("POST", "/api/events", "alex", data, nil), 201)
	if len(outbox(t, x)) != 0 {
		t.Fatal("issuer mismatch sent notification")
	}
}
func TestNotificationsDurableRetryStableEnvelopeAndGone(t *testing.T) {
	x := setupNotificationApp(t)
	id := strings.Repeat("c", 64)
	registerNotificationProvider(t, x, id, true)
	data := example("event")
	data["attendees"] = map[string]string{"sam": "pending"}
	x.expect(x.req("POST", "/api/events", "alex", data, nil), 201)
	var attempts int
	var messageID string
	x.app.notificationHTTP = &http.Client{Transport: notificationTransport(func(r *http.Request) (*http.Response, error) {
		attempts++
		if r.URL.String() != "https://apps.gravitas.cool/v1/notifications/spacetime" || bearerToken(r) != x.app.notificationKey {
			t.Fatal("wrong callback")
		}
		var n queuedNotification
		if json.NewDecoder(r.Body).Decode(&n) != nil || n.Payload.Kind != "event.invited" || n.Provider != id {
			t.Fatal("bad envelope", n)
		}
		if messageID != "" && messageID != n.ID {
			t.Fatal("retry changed id")
		}
		messageID = n.ID
		status := 503
		if attempts == 2 {
			status = 204
		}
		return &http.Response{StatusCode: status, Body: io.NopCloser(strings.NewReader(""))}, nil
	})}
	x.app.sendNotifications(t.Context())
	records := outbox(t, x)
	if len(records) != 1 || records[0].Attempts != 1 || !records[0].Next.After(time.Now()) {
		t.Fatal("retry not persisted", records)
	}
	x.app.sendNotifications(t.Context())
	if attempts != 1 {
		t.Fatal("retry ignored backoff")
	}
	_ = x.app.store.db.Update(func(tx *bolt.Tx) error {
		n := records[0]
		n.Next = time.Now().Add(-time.Second)
		return putJSON(tx, "notification_outbox", n.Message.ID, n)
	})
	x.app.sendNotifications(t.Context())
	if attempts != 2 || len(outbox(t, x)) != 0 {
		t.Fatal("successful callback not acknowledged")
	}
	// Another event followed by 410 removes the dead registration and its queue.
	x.expect(x.req("POST", "/api/events", "alex", data, nil), 201)
	x.app.notificationHTTP = &http.Client{Transport: notificationTransport(func(*http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 410, Body: io.NopCloser(strings.NewReader(""))}, nil
	})}
	x.app.sendNotifications(t.Context())
	if len(outbox(t, x)) != 0 {
		t.Fatal("gone provider kept queue")
	}
	_ = x.app.store.db.View(func(tx *bolt.Tx) error {
		if tx.Bucket([]byte("notification_providers")).Get([]byte(id)) != nil {
			t.Fatal("gone provider retained")
		}
		return nil
	})
}
