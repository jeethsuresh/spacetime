package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestOfflineSyncUIDRetryAndCompleteCalendarSnapshot(t *testing.T) {
	x := setup(t)
	x.register("alice")
	body := example("event")
	body["uid"] = "device-event@spacetime.local"
	first := x.req("POST", "/api/events", "alice", body, nil)
	x.expect(first, 201)
	created := readEvent(t, first)
	if created.UID != body["uid"] {
		t.Fatal("device UID was changed")
	}
	retry := x.req("POST", "/api/events", "alice", body, nil)
	x.expect(retry, 201)
	if readEvent(t, retry).ID != created.ID {
		t.Fatal("retried offline create duplicated the event")
	}
	snapshot := x.req("GET", "/api/events", "alice", nil, nil)
	x.expect(snapshot, 200)
	var entries []map[string]any
	if err := json.Unmarshal(snapshot.Body.Bytes(), &entries); err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || !strings.Contains(entries[0]["calendar_data"].(string), "UID:device-event@spacetime.local") {
		t.Fatal("offline snapshot lost complete iCalendar data")
	}
	x.expect(x.req("GET", "/api/events", "", nil, nil), 401)
}
