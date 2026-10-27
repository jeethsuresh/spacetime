package main

import (
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	bolt "go.etcd.io/bbolt"
)

func TestProtocolNotificationUsesIAMContractAndRetriesWithoutStoreDetails(t *testing.T) {
	x := setupNotificationApp(t)
	x.app.notificationProtocol = true
	x.app.notificationStore = ""
	provider := strings.Repeat("d", 64)
	body := map[string]any{"issuer": "https://gravitas.cool", "subject": "sam-sub", "protocol": "appstore/1.0.0", "callback": "", "enabled": true}
	x.expect(x.req("PUT", "/api/notifications/providers/"+provider, "", body, map[string]string{"Authorization": "Bearer " + x.app.notificationKey}), 204)
	event := example("event")
	event["attendees"] = map[string]string{"sam": "pending"}
	x.expect(x.req("POST", "/api/events", "alex", event, nil), 201)
	calls := 0
	x.app.notificationHTTP = &http.Client{Transport: notificationTransport(func(r *http.Request) (*http.Response, error) {
		if r.Method == "GET" {
			return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{"protocols":[{"protocol":"appstore","version":"1.0.0","capabilities":[{"id":"push.send"}]}]}`))}, nil
		}
		calls++
		if r.URL.String() != "https://gravitas.cool/protocols/v1/users/sam-sub/invoke" || bearerToken(r) != x.app.notificationKey {
			t.Fatal(r.URL)
		}
		var envelope struct {
			ID, Protocol, Version, Capability string
			Input                             struct {
				App, Device string
				Payload     notificationPayload
			}
		}
		if err := json.NewDecoder(r.Body).Decode(&envelope); err != nil {
			t.Fatal(err)
		}
		if envelope.Protocol != "appstore" || envelope.Version != "1.0.0" || envelope.Capability != "push.send" || envelope.Input.App != "spacetime" || envelope.Input.Device != provider || envelope.Input.Payload.Kind != "event.invited" {
			t.Fatalf("wrong envelope: %+v", envelope)
		}
		status := 503
		if calls > 1 {
			status = 202
		}
		return &http.Response{StatusCode: status, Body: io.NopCloser(strings.NewReader(`{"status":"accepted"}`))}, nil
	})}
	x.app.sendNotifications(t.Context())
	if calls != 1 || len(outbox(t, x)) != 1 {
		t.Fatal("failed delivery was not retained")
	}
	records := outbox(t, x)
	if err := x.app.store.db.Update(func(tx *bolt.Tx) error {
		for _, n := range records {
			n.Next = time.Now().Add(-time.Second)
			if err := putJSON(tx, "notification_outbox", n.Message.ID, n); err != nil {
				return err
			}
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	x.app.sendNotifications(t.Context())
	if calls != 2 || len(outbox(t, x)) != 0 {
		t.Fatal("accepted delivery was not removed")
	}
}

func TestMissingProtocolSubscriptionKeepsNotificationQueued(t *testing.T) {
	x := setupNotificationApp(t)
	x.app.notificationProtocol = true
	provider := strings.Repeat("e", 64)
	registerNotificationProvider(t, x, provider, true)
	event := example("event")
	event["attendees"] = map[string]string{"sam": "pending"}
	x.expect(x.req("POST", "/api/events", "alex", event, nil), 201)
	x.app.notificationHTTP = &http.Client{Transport: notificationTransport(func(r *http.Request) (*http.Response, error) {
		if r.Method != "GET" {
			t.Fatal("sent data before protocol was available")
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{"protocols":[]}`))}, nil
	})}
	x.app.sendNotifications(t.Context())
	records := outbox(t, x)
	if len(records) != 1 || records[0].Attempts != 1 || !records[0].Next.After(time.Now()) {
		t.Fatal("missing subscription discarded the notification", records)
	}
}
