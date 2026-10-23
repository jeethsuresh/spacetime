package main

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	bolt "go.etcd.io/bbolt"
)

func TestSourceStreamsPreserveOtherUIDsMethodsAndComponents(t *testing.T) {
	first := strings.Replace(sourceICS("one", "One", "VEVENT"), "BEGIN:VEVENT", "METHOD:PUBLISH\r\nX-SOURCE-CALENDAR:preserve\r\nBEGIN:VJOURNAL\r\nUID:journal\r\nDTSTAMP:20261001T000000Z\r\nEND:VJOURNAL\r\nBEGIN:VEVENT", 1)
	stream := first + sourceICS("two", "Two", "VTODO")
	events, err := parseSourceEvents(stream, true)
	if err != nil || len(events) != 2 {
		t.Fatal("stream import", err)
	}
	if _, err := parseSourceEvents(stream, false); err == nil {
		t.Fatal("CalDAV accepted multiple VCALENDAR objects")
	}
	if _, err := parseSourceEvents(first, false); err == nil {
		t.Fatal("CalDAV accepted METHOD")
	}
	e := events["one"]
	e.Title = "Changed"
	// The ordinary event writer preserves the source's unknown properties.
	e.Raw, err = encodeEvent(e)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := rewriteSourceBundle(stream, &e, false)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"METHOD:PUBLISH", "X-SOURCE-CALENDAR:preserve", "BEGIN:VJOURNAL", "UID:two", "X-SOURCE-EXTRA:keep me"} {
		if !strings.Contains(raw, want) {
			t.Fatal("lost", want)
		}
	}
	raw, err = rewriteSourceBundle(raw, &e, true)
	if err != nil {
		t.Fatal(err)
	}
	remaining, err := parseSourceEvents(raw, true)
	if err != nil || len(remaining) != 1 || remaining["two"].UID != "two" {
		t.Fatal("remove affected another UID", err)
	}
	single, _ := parseSourceEvents(sourceICS("last", "Last", "VEVENT"), true)
	last := single["last"]
	empty, err := rewriteSourceBundle(sourceICS("last", "Last", "VEVENT"), &last, true)
	if err != nil || !strings.Contains(empty, "BEGIN:VTIMEZONE") || strings.Contains(empty, "BEGIN:VEVENT") {
		t.Fatal("empty file invalid", err)
	}
	if remaining, err = parseSourceEvents(empty, true); err != nil || len(remaining) != 0 {
		t.Fatal("empty source import", err)
	}
}

func TestSourceSecretURLReconnectAndDisconnectAreBoundAndPrivate(t *testing.T) {
	x := setup(t)
	x.register("alice")
	x.register("bobby")
	s := newSourceFixture(t)
	c := connectFixture(t, x, s, "caldav", "/source/?private-token=never-expose-this")
	if strings.Contains(c.SourceURL, "private-token") || strings.Contains(c.SourceURL, "/source/") || c.SourceRef != "" {
		t.Fatal("URL token leaked")
	}
	x.app.store.db.View(func(tx *bolt.Tx) error {
		raw := tx.Bucket([]byte("remote_calendars")).Get([]byte(c.ID))
		if strings.Contains(string(raw), "never-expose-this") || strings.Contains(string(raw), "/source/") {
			t.Fatal("source details stored in plaintext")
		}
		return nil
	})
	input := map[string]string{"id": c.ID, "name": "Reconnected", "color": "#376B51", "url": c.SourceURL, "kind": "caldav"}
	x.expect(x.req("POST", "/api/calendars/connect", "bobby", input, nil), 403)
	w := x.req("POST", "/api/calendars/connect", "alice", input, nil)
	x.expect(w, 201)
	var again Calendar
	json.Unmarshal(w.Body.Bytes(), &again)
	if again.ID != c.ID {
		t.Fatal("reconnect duplicated calendar")
	}
	var stored remoteSource
	x.app.store.db.View(func(tx *bolt.Tx) error { var err error; stored, err = x.app.loadRemoteSource(tx, c.ID); return err })
	if !strings.Contains(stored.URL, "never-expose-this") {
		t.Fatal("reconnect lost signed query")
	}
	input["url"] = s.server.URL + "/other/"
	x.expect(x.req("POST", "/api/calendars/connect", "alice", input, nil), 400)
	x.expect(x.req("DELETE", "/api/calendars/"+c.ID, "alice", nil, map[string]string{"If-Match": fmt.Sprintf(`"%d"`, again.Version)}), 204)
	if len(s.data) != 2 || s.deletes != 0 {
		t.Fatal("disconnect deleted original source")
	}
	if strings.Contains(x.req("GET", "/api/events", "alice", nil, nil).Body.String(), "remote-event") {
		t.Fatal("disconnected cache stayed visible")
	}
}

func TestWritableCalendarFileKeepsOtherEntriesAndInvalidPullIsAtomic(t *testing.T) {
	x := setup(t)
	x.register("alice")
	s := newSourceFixture(t)
	c := connectFixture(t, x, s, "ics", "/source/event.ics")
	data := example("todo")
	data["calendar_id"] = c.ID
	data["uid"] = "added-task"
	w := x.req("POST", "/api/events", "alice", data, nil)
	x.expect(w, 201)
	task := readEvent(t, w)
	imported := listedSourceEvent(t, x, c, "event")
	if !strings.Contains(s.data["/source/event.ics"], "UID:remote-event") || !strings.Contains(s.data["/source/event.ics"], "UID:added-task") {
		t.Fatal("file write replaced another entry")
	}
	x.expect(x.req("DELETE", "/api/events/"+task.ID, "alice", nil, map[string]string{"If-Match": fmt.Sprintf(`"%d"`, task.Version)}), 204)
	if !strings.Contains(s.data["/source/event.ics"], "UID:remote-event") || strings.Contains(s.data["/source/event.ics"], "UID:added-task") {
		t.Fatal("file deletion affected another entry")
	}
	s.data["/source/event.ics"] = "invalid source body"
	s.versions["/source/event.ics"]++
	got := listedSourceEvent(t, x, c, "event")
	if got.ID != imported.ID || got.Title != imported.Title {
		t.Fatal("failed source snapshot discarded cache")
	}
	var calendar Calendar
	json.Unmarshal(x.req("GET", "/api/calendars", "alice", nil, nil).Body.Bytes(), &calendar)
	// Connection replacement must also fail atomically.
	w = x.req("POST", "/api/calendars/connect", "alice", map[string]string{"id": c.ID, "name": "Changed", "url": c.SourceURL, "kind": "ics"}, nil)
	x.expect(w, 502)
	if listedSourceEvent(t, x, c, "event").ID != imported.ID {
		t.Fatal("failed reconnect discarded cache")
	}
}
