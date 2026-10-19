package main

import (
	"strings"
	"testing"
	"time"

	"github.com/emersion/go-ical"
	bolt "go.etcd.io/bbolt"
)

func TestOccasionMigrationPreservesCalendarIdentityAndRecurrence(t *testing.T) {
	for _, kind := range []string{"birthday", "holiday"} {
		t.Run(kind, func(t *testing.T) {
			x := setup(t)
			start := time.Date(2028, 2, 29, 0, 0, 0, 0, time.UTC)
			end := start.AddDate(0, 0, 1)
			e := Event{ID: kind, UID: "external-" + kind + "@example.org", Resource: "original.ics", Owner: "alice", Title: "Occasion", Kind: kind, AllDay: true, Start: &start, End: &end, Timezone: "UTC", RRule: "FREQ=YEARLY;INTERVAL=4;COUNT=8", RDates: []string{"2029-03-01"}, ExDates: []string{"2032-02-29"}, Version: 7, Updated: start, Attendees: map[string]string{}}
			raw, err := encodeEvent(e)
			if err != nil {
				t.Fatal(err)
			}
			cal := parseCalendar(t, raw)
			masterComponent(cal).Props.SetText("X-EXTERNAL", "keep me")
			override := ical.NewComponent(ical.CompEvent)
			for name, value := range map[string]string{"UID": e.UID, "SUMMARY": "Moved occasion", "DTSTAMP": "20280229T000000Z", "RECURRENCE-ID;VALUE=DATE": "20360229", "DTSTART;VALUE=DATE": "20360301", "DTEND;VALUE=DATE": "20360302", "LOCATION": "Old venue"} {
				parts := strings.Split(name, ";")
				p := ical.NewProp(parts[0])
				p.Value = value
				if len(parts) > 1 {
					p.Params.Set("VALUE", "DATE")
				}
				override.Props.Set(p)
			}
			cal.Children = append(cal.Children, override)
			e.Raw, err = calendarString(cal)
			if err != nil {
				t.Fatal(err)
			}
			if err := x.app.store.db.Update(func(tx *bolt.Tx) error { return saveEvent(tx, e) }); err != nil {
				t.Fatal(err)
			}
			if err := migrateStore(x.app.store); err != nil {
				t.Fatal(err)
			}
			var got Event
			if err := x.app.store.db.View(func(tx *bolt.Tx) error { var err error; got, err = eventTx(tx, e.ID); return err }); err != nil {
				t.Fatal(err)
			}
			if got.Kind != "occasion" || got.UID != e.UID || got.Resource != e.Resource || got.Version != 8 || got.RRule != e.RRule || got.RDates[0] != e.RDates[0] || got.ExDates[0] != e.ExDates[0] {
				t.Fatalf("migration changed identity/schedule: %+v", got)
			}
			migrated := parseCalendar(t, got.Raw)
			if len(migrated.Children) != 2 || text(masterComponent(migrated), "X-EXTERNAL") != "keep me" || text(masterComponent(migrated), "X-SPACETIME-KIND") != "occasion" {
				t.Fatal("lost components or metadata")
			}
			for _, c := range migrated.Children {
				if c.Props.Get("LOCATION") != nil || c.Props.Get("ATTENDEE") != nil || c.Props.Get("ORGANIZER") != nil {
					t.Fatal("occasion retained restricted fields")
				}
			}
			if err := migrateStore(x.app.store); err != nil {
				t.Fatal(err)
			}
			if err := x.app.store.db.View(func(tx *bolt.Tx) error {
				again, err := eventTx(tx, e.ID)
				if err == nil && (again.Version != got.Version || again.Raw != got.Raw) {
					t.Fatal("migration is not idempotent")
				}
				return err
			}); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestOccasionAPIAndLegacyKinds(t *testing.T) {
	x := setup(t)
	x.register("alice")
	for _, kind := range []string{"occasion", "birthday", "holiday"} {
		body := example(kind)
		body["all_day"] = true
		body["start"] = "2026-10-20T00:00:00Z"
		body["end"] = "2026-10-21T00:00:00Z"
		body["rrule"] = "FREQ=MONTHLY;INTERVAL=3;COUNT=4"
		w := x.req("POST", "/api/events", "alice", body, nil)
		x.expect(w, 201)
		e := readEvent(t, w)
		if e.Kind != "occasion" || !e.AllDay || e.RRule != "FREQ=MONTHLY;INTERVAL=3;COUNT=4" {
			t.Fatalf("wrong occasion: %+v", e)
		}
		body["location"] = "Venue"
		x.expect(x.req("POST", "/api/events", "alice", body, nil), 400)
		body["location"] = ""
		body["attendees"] = map[string]string{"alice": "pending"}
		x.expect(x.req("POST", "/api/events", "alice", body, nil), 400)
	}
	body := example("occasion")
	body["start"] = "2026-10-20T00:00:00Z"
	body["end"] = "2026-10-21T00:00:00Z"
	w := x.req("POST", "/api/events", "alice", body, nil)
	x.expect(w, 201)
	if readEvent(t, w).RRule != "" {
		t.Fatal("non-repeating occasion forced to repeat")
	}
}
