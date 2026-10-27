package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"testing"

	bolt "go.etcd.io/bbolt"
)

// This fixture exists only in the Go test binary. It runs the real API and
// worker with isolated data; no test routes or credentials enter a release.
func TestNotificationInteropFixture(t *testing.T) {
	ready := os.Getenv("NOTIFICATION_INTEROP_READY")
	destination := os.Getenv("NOTIFICATION_INTEROP_STORE")
	if ready == "" || destination == "" {
		t.Skip("started by the cross-repository notification test")
	}
	x := setupNotificationApp(t)
	subject := os.Getenv("NOTIFICATION_INTEROP_SUBJECT")
	if subject == "" {
		subject = "stable-user"
	}
	if iam := os.Getenv("PROTOCOL_INTEROP_IAM"); iam != "" {
		destination = iam
		x.app.notificationProtocol = true
	}
	if err := x.app.store.db.Update(func(tx *bolt.Tx) error {
		return putJSON(tx, "gravitas_identities", tokenKey("https://gravitas.cool\x00"+subject), gravitasIdentity{"https://gravitas.cool", subject, "sam"})
	}); err != nil {
		t.Fatal(err)
	}
	target, err := url.Parse(destination)
	if err != nil {
		t.Fatal(err)
	}
	x.app.notificationHTTP = &http.Client{Transport: notificationTransport(func(r *http.Request) (*http.Response, error) {
		clone := r.Clone(r.Context())
		u := *r.URL
		u.Scheme = target.Scheme
		u.Host = target.Host
		clone.URL = &u
		return http.DefaultTransport.RoundTrip(clone)
	})}
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	done := make(chan struct{})
	mux := http.NewServeMux()
	mux.HandleFunc("POST /fixture/stop", func(w http.ResponseWriter, r *http.Request) { close(done); w.WriteHeader(204) })
	mux.Handle("/", x.handler)
	server := httptest.NewServer(mux)
	defer server.Close()
	go x.app.runNotifications(ctx)
	data, _ := json.Marshal(map[string]string{"url": server.URL, "token": x.tokens["alex"]})
	if err := os.WriteFile(ready, data, 0600); err != nil {
		t.Fatal(err)
	}
	select {
	case <-done:
	case <-ctx.Done():
	}
}
