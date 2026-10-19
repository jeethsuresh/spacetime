package main

import (
	"context"
	"encoding/json"
	"encoding/xml"
	"fmt"

	"strings"
	"testing"
	"time"

	"github.com/emersion/go-ical"
)

func parseCalendar(t *testing.T, body string) *ical.Calendar {
	t.Helper()
	cal, err := ical.NewDecoder(strings.NewReader(strings.ReplaceAll(strings.ReplaceAll(body, "\r\n", "\n"), "\n", "\r\n"))).Decode()
	if err != nil {
		t.Fatal(err)
	}
	return cal
}
func wrapEvent(props string) string {
	return "BEGIN:VCALENDAR\nVERSION:2.0\nPRODID:-//Conformance tests//EN\nBEGIN:VEVENT\nUID:series\nDTSTAMP:20260101T000000Z\nSUMMARY:Test\n" + props + "\nEND:VEVENT\nEND:VCALENDAR\n"
}
func expandTest(t *testing.T, raw, from, to, zone string) []instance {
	t.Helper()
	cal := parseCalendar(t, raw)
	z, err := ianaZone(zone)
	if err != nil {
		t.Fatal(err)
	}
	a, _ := time.Parse(time.RFC3339, from)
	b, _ := time.Parse(time.RFC3339, to)
	items, err := expandCalendar(context.Background(), cal, a, b, z)
	if err != nil {
		t.Fatal(err)
	}
	return items
}
func TestRFC5545Rules(t *testing.T) {
	cases := []struct {
		name, props, from, to string
		want                  []string
	}{
		{"daily count", "DTSTART:19970902T090000Z\nRRULE:FREQ=DAILY;COUNT=4", "1997-09-01T00:00:00Z", "1997-10-01T00:00:00Z", []string{"19970902T090000Z", "19970903T090000Z", "19970904T090000Z", "19970905T090000Z"}},
		{"two weeks RFC example", "DTSTART:19970902T090000Z\nRRULE:FREQ=WEEKLY;INTERVAL=2;COUNT=6;BYDAY=TU,TH;WKST=SU", "1997-09-01T00:00:00Z", "1997-11-01T00:00:00Z", []string{"19970902T090000Z", "19970904T090000Z", "19970916T090000Z", "19970918T090000Z", "19970930T090000Z", "19971002T090000Z"}},
		{"three months", "DTSTART:20260115T090000Z\nRRULE:FREQ=MONTHLY;INTERVAL=3;COUNT=4", "2026-01-01T00:00:00Z", "2027-01-01T00:00:00Z", []string{"20260115T090000Z", "20260415T090000Z", "20260715T090000Z", "20261015T090000Z"}},
		{"month 31 skips", "DTSTART:20260131T090000Z\nRRULE:FREQ=MONTHLY;COUNT=4", "2026-01-01T00:00:00Z", "2027-01-01T00:00:00Z", []string{"20260131T090000Z", "20260331T090000Z", "20260531T090000Z", "20260731T090000Z"}},
		{"last business day", "DTSTART:20260130T090000Z\nRRULE:FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1;COUNT=3", "2026-01-01T00:00:00Z", "2026-05-01T00:00:00Z", []string{"20260130T090000Z", "20260227T090000Z", "20260331T090000Z"}},
		{"second Tuesday", "DTSTART:20260113T090000Z\nRRULE:FREQ=MONTHLY;BYDAY=2TU;COUNT=3", "2026-01-01T00:00:00Z", "2026-05-01T00:00:00Z", []string{"20260113T090000Z", "20260210T090000Z", "20260310T090000Z"}},
		{"weekdays", "DTSTART:20261016T090000Z\nRRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;COUNT=4", "2026-10-01T00:00:00Z", "2026-11-01T00:00:00Z", []string{"20261016T090000Z", "20261019T090000Z", "20261020T090000Z", "20261021T090000Z"}},
		{"weekends", "DTSTART:20261017T090000Z\nRRULE:FREQ=WEEKLY;BYDAY=SA,SU;COUNT=4", "2026-10-01T00:00:00Z", "2026-11-01T00:00:00Z", []string{"20261017T090000Z", "20261018T090000Z", "20261024T090000Z", "20261025T090000Z"}},
		{"leap birthdays", "DTSTART;VALUE=DATE:20240229\nRRULE:FREQ=YEARLY;COUNT=3", "2024-01-01T00:00:00Z", "2033-01-01T00:00:00Z", []string{"20240229", "20280229", "20320229"}},
		{"inclusive date until", "DTSTART;VALUE=DATE:20260101\nRRULE:FREQ=DAILY;UNTIL=20260103", "2026-01-01T00:00:00Z", "2026-02-01T00:00:00Z", []string{"20260101", "20260102", "20260103"}},
		{"inclusive datetime until", "DTSTART:20260101T090000Z\nRRULE:FREQ=DAILY;UNTIL=20260103T090000Z", "2026-01-01T00:00:00Z", "2026-02-01T00:00:00Z", []string{"20260101T090000Z", "20260102T090000Z", "20260103T090000Z"}},
		{"inclusion exclusion duplicate", "DTSTART:20260101T090000Z\nRRULE:FREQ=DAILY;COUNT=3\nRDATE:20260103T090000Z,20260105T090000Z\nEXDATE:20260101T090000Z,20260102T090000Z", "2026-01-01T00:00:00Z", "2026-02-01T00:00:00Z", []string{"20260103T090000Z", "20260105T090000Z"}},
		{"hourly interval", "DTSTART:20260101T090000Z\nRRULE:FREQ=HOURLY;INTERVAL=3;COUNT=3", "2026-01-01T00:00:00Z", "2026-01-02T00:00:00Z", []string{"20260101T090000Z", "20260101T120000Z", "20260101T150000Z"}},
		{"far future unbounded", "DTSTART:20260101T090000Z\nRRULE:FREQ=YEARLY", "2426-01-01T00:00:00Z", "2427-01-01T00:00:00Z", []string{"24260101T090000Z"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			items := expandTest(t, wrapEvent(tc.props), tc.from, tc.to, "UTC")
			got := []string{}
			for _, i := range items {
				got = append(got, i.Start.key())
			}
			if fmt.Sprint(got) != fmt.Sprint(tc.want) {
				t.Fatalf("got %v want %v", got, tc.want)
			}
		})
	}
}
func TestDSTAndFloating(t *testing.T) {
	t.Run("gap not counted", func(t *testing.T) {
		items := expandTest(t, wrapEvent("DTSTART;TZID=America/New_York:20260307T023000\nRRULE:FREQ=DAILY;COUNT=3"), "2026-03-06T00:00:00Z", "2026-03-12T00:00:00Z", "UTC")
		got := []string{}
		for _, i := range items {
			got = append(got, i.Start.instant().Format(time.RFC3339))
		}
		want := []string{"2026-03-07T07:30:00Z", "2026-03-09T06:30:00Z", "2026-03-10T06:30:00Z"}
		if fmt.Sprint(got) != fmt.Sprint(want) {
			t.Fatalf("%v", got)
		}
	})
	t.Run("wall clock preserved", func(t *testing.T) {
		items := expandTest(t, wrapEvent("DTSTART;TZID=America/New_York:20261031T090000\nDTEND;TZID=America/New_York:20261031T100000\nRRULE:FREQ=DAILY;COUNT=3"), "2026-10-30T00:00:00Z", "2026-11-05T00:00:00Z", "UTC")
		want := []string{"2026-10-31T13:00:00Z", "2026-11-01T14:00:00Z", "2026-11-02T14:00:00Z"}
		for n, i := range items {
			if i.Start.instant().Format(time.RFC3339) != want[n] || i.End.instant().Sub(i.Start.instant()) != time.Hour {
				t.Fatalf("bad DST instance %+v", i)
			}
		}
	})
	t.Run("fold selects first", func(t *testing.T) {
		items := expandTest(t, wrapEvent("DTSTART;TZID=America/New_York:20261101T013000\nRRULE:FREQ=DAILY;COUNT=1"), "2026-11-01T00:00:00Z", "2026-11-02T00:00:00Z", "UTC")
		if len(items) != 1 || items[0].Start.instant().Format(time.RFC3339) != "2026-11-01T05:30:00Z" {
			t.Fatalf("bad ambiguous time: %+v", items)
		}
	})
	t.Run("floating follows viewer", func(t *testing.T) {
		raw := wrapEvent("DTSTART:20260101T090000\nRRULE:FREQ=DAILY;COUNT=2")
		items := expandTest(t, raw, "2026-01-01T00:00:00Z", "2026-01-03T00:00:00Z", "America/Toronto")
		if items[0].Start.instant().Format(time.RFC3339) != "2026-01-01T14:00:00Z" || items[0].Start.key() != "20260101T090000" {
			t.Fatal("floating time was treated as UTC")
		}
	})
	t.Run("nominal duration differs from exact end", func(t *testing.T) {
		for _, tc := range []struct {
			duration string
			hours    time.Duration
		}{{"DURATION:P1D", 23}, {"DTEND;TZID=America/New_York:20260308T090000", 23}, {"DURATION:PT24H", 24}} {
			items := expandTest(t, wrapEvent("DTSTART;TZID=America/New_York:20260307T090000\n"+tc.duration+"\nRRULE:FREQ=DAILY;COUNT=2"), "2026-03-07T00:00:00Z", "2026-03-10T00:00:00Z", "UTC")
			if items[0].End.instant().Sub(items[0].Start.instant()) != tc.hours*time.Hour {
				t.Fatalf("%s bad duration", tc.duration)
			}
			if strings.HasPrefix(tc.duration, "DTEND") && items[1].End.instant().Sub(items[1].Start.instant()) != 23*time.Hour {
				t.Fatal("DTEND duration must be exact across instances")
			}
		}
	})
}
func TestOverridesPeriodsAndBoundaries(t *testing.T) {
	raw := strings.ReplaceAll(wrapEvent("DTSTART:20260101T090000Z\nDTEND:20260101T100000Z\nRRULE:FREQ=DAILY;COUNT=5"), "END:VCALENDAR", `BEGIN:VEVENT
UID:series
DTSTAMP:20260101T000000Z
RECURRENCE-ID:20260102T090000Z
DTSTART:20260210T120000Z
DTEND:20260210T140000Z
SUMMARY:Moved far away
END:VEVENT
BEGIN:VEVENT
UID:series
DTSTAMP:20260101T000000Z
RECURRENCE-ID;RANGE=THISANDFUTURE:20260103T090000Z
DTSTART:20260103T110000Z
DTEND:20260103T123000Z
SUMMARY:Later now
END:VEVENT
END:VCALENDAR`)
	items := expandTest(t, raw, "2026-01-01T00:00:00Z", "2026-01-07T00:00:00Z", "UTC")
	if len(items) != 4 || items[2].Start.instant().Hour() != 11 || items[2].End.instant().Sub(items[2].Start.instant()) != 90*time.Minute {
		t.Fatalf("bad range override: %+v", items)
	}
	items = expandTest(t, raw, "2026-02-10T00:00:00Z", "2026-02-11T00:00:00Z", "UTC")
	if len(items) != 1 || text(items[0].Component, "SUMMARY") != "Moved far away" {
		t.Fatal("moved exception outside original window missing")
	}
	t.Run("overlap and exclusive end", func(t *testing.T) {
		raw := wrapEvent("DTSTART:20260101T230000Z\nDTEND:20260102T010000Z\nRRULE:FREQ=DAILY;COUNT=3")
		if len(expandTest(t, raw, "2026-01-02T00:00:00Z", "2026-01-02T00:30:00Z", "UTC")) != 1 {
			t.Fatal("overlapping start before window missing")
		}
		if len(expandTest(t, raw, "2026-01-02T01:00:00Z", "2026-01-02T02:00:00Z", "UTC")) != 0 {
			t.Fatal("exclusive end included")
		}
	})
	t.Run("RDATE PERIOD duration and no mutation", func(t *testing.T) {
		cal := parseCalendar(t, wrapEvent("DTSTART:20260101T090000Z\nDTEND:20260101T100000Z\nRDATE;VALUE=PERIOD:20260103T090000Z/PT4H"))
		before, _ := calendarString(cal)
		a, _ := time.Parse(time.RFC3339, "2026-01-03T12:00:00Z")
		items, err := expandCalendar(context.Background(), cal, a, a.Add(time.Hour), utcZone())
		after, _ := calendarString(cal)
		if err != nil || len(items) != 1 || items[0].End.instant().Hour() != 13 {
			t.Fatalf("bad RDATE PERIOD: %v %+v", err, items)
		}
		if before != after {
			t.Fatal("expansion mutated stored calendar")
		}
	})
}
func TestInvalidRuleValidation(t *testing.T) {
	d := stamp{Wall: time.Date(2026, 1, 1, 9, 0, 0, 0, time.UTC), Zone: utcZone()}
	for _, raw := range []string{"COUNT=3", "FREQ=DAILY;COUNT=0", "FREQ=DAILY;INTERVAL=0", "FREQ=DAILY;COUNT=2;UNTIL=20260103T090000Z", "FREQ=WEEKLY;BYMONTHDAY=2", "FREQ=DAILY;BYDAY=2MO", "FREQ=YEARLY;BYWEEKNO=1;BYDAY=1MO", "FREQ=DAILY;BYYEARDAY=2", "FREQ=MONTHLY;BYSETPOS=1", "FREQ=DAILY;FREQ=WEEKLY", "FREQ=DAILY;UNTIL=20260103", "FREQ=DAILY;BYDAY=0MO", "FREQ=WEEKLY;WKST=2TU", "FREQ=DAILY;INTERVAL=2147483648"} {
		t.Run(raw, func(t *testing.T) {
			if _, err := parseRule(raw, d); err == nil {
				t.Fatal("invalid RRULE accepted")
			}
		})
	}
}
func TestSelfContainedTimezone(t *testing.T) {
	tz, err := timezoneComponent("America/Toronto")
	if err != nil {
		t.Fatal(err)
	}
	cal := parseCalendar(t, wrapEvent("DTSTART;TZID=America/Toronto:20260307T090000\nRRULE:FREQ=DAILY;COUNT=3"))
	cal.Children = append(cal.Children, tz)
	zones, err := calendarZones(cal, 2024, 2428)
	if err != nil {
		t.Fatal(err)
	}
	want, _ := ianaZone("America/Toronto")
	for _, date := range []time.Time{time.Date(2026, 3, 9, 9, 0, 0, 0, time.UTC), time.Date(2426, 7, 1, 9, 0, 0, 0, time.UTC), time.Date(2426, 12, 1, 9, 0, 0, 0, time.UTC)} {
		a, _ := zones["America/Toronto"].resolve(date, true)
		b, _ := want.resolve(date, true)
		if !a.Equal(b) {
			t.Fatalf("VTIMEZONE differs from IANA at %s: %s vs %s", date, a, b)
		}
	}
}
func TestRecurringAPIAndCalDAVExpansion(t *testing.T) {
	x := setup(t)
	x.register("alice")
	data := example("event")
	data["start"] = "2026-10-20T13:00:00Z"
	data["end"] = "2026-10-20T14:00:00Z"
	data["timezone"] = "America/Toronto"
	data["rrule"] = "FREQ=WEEKLY;INTERVAL=2;BYDAY=TU;COUNT=3"
	w := x.req("POST", "/api/events", "alice", data, nil)
	x.expect(w, 201)
	e := readEvent(t, w)
	query := "/api/occurrences?from=2026-10-01T00:00:00Z&to=2026-12-01T00:00:00Z&timezone=America%2FToronto"
	w = x.req("GET", query, "alice", nil, nil)
	x.expect(w, 200)
	var occurrences []occurrence
	if err := json.Unmarshal(w.Body.Bytes(), &occurrences); err != nil {
		t.Fatal(err)
	}
	if len(occurrences) != 3 || occurrences[1].Start.Hour() != 14 {
		t.Fatalf("bad API recurrence %s", w.Body.String())
	}
	x.expect(x.req("POST", "/api/events/"+e.ID+"/exceptions", "alice", map[string]any{"operation": "skip", "recurrence_id": occurrences[1].RecurrenceID, "version": e.Version}, nil), 204)
	w = x.req("GET", query, "alice", nil, nil)
	x.expect(w, 200)
	_ = json.Unmarshal(w.Body.Bytes(), &occurrences)
	if len(occurrences) != 2 {
		t.Fatal("skipped occurrence remains")
	}
	report := `<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop><d:getetag/><c:calendar-data><c:expand start="20261001T000000Z" end="20261201T000000Z"/></c:calendar-data></d:prop><c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VEVENT"><c:time-range start="20261001T000000Z" end="20261201T000000Z"/></c:comp-filter></c:comp-filter></c:filter></c:calendar-query>`
	w = x.req("REPORT", "/dav/alice/calendars/default/", "", report, map[string]string{"Authorization": "Basic YWxpY2U6Y29ycmVjdCBob3JzZSBiYXR0ZXJ5"})
	x.expect(w, 207)
	var root xmlNode
	if err := xml.Unmarshal(w.Body.Bytes(), &root); err != nil {
		t.Fatal(err)
	}
	node := root.Children[0].child(davNS, "propstat").child(davNS, "prop").child(calNS, "calendar-data")
	cal := parseCalendar(t, node.Text)
	if len(cal.Children) != 2 {
		t.Fatalf("wrong expanded components %s", node.Text)
	}
	for _, c := range cal.Children {
		if c.Props.Get("RRULE") != nil || c.Props.Get("RECURRENCE-ID") == nil || !strings.HasSuffix(c.Props.Get("DTSTART").Value, "Z") {
			t.Fatal("invalid expanded instance")
		}
	}
	// Entire resource is preserved, not expanded, on ordinary GET.
	w = x.req("GET", "/dav/alice/calendars/default/"+e.ID+".ics", "", nil, map[string]string{"Authorization": "Basic YWxpY2U6Y29ycmVjdCBob3JzZSBiYXR0ZXJ5"})
	x.expect(w, 200)
	if !strings.Contains(w.Body.String(), "BEGIN:VTIMEZONE") || !strings.Contains(w.Body.String(), "RRULE:FREQ=WEEKLY") {
		t.Fatal("raw calendar lost recurrence or timezone")
	}
	// Birthdays/holidays enforce their product invariant even outside Flutter.
	for _, kind := range []string{"birthday", "holiday"} {
		body := example(kind)
		body["location"] = "Forbidden"
		x.expect(x.req("POST", "/api/events", "alice", body, nil), 400)
		body["location"] = ""
		body["attendees"] = map[string]string{"alice": "pending"}
		x.expect(x.req("POST", "/api/events", "alice", body, nil), 400)
	}

}

func TestRecurringTodoCompletionAndUndatedTasks(t *testing.T) {
	x := setup(t)
	x.register("alice")
	data := example("todo")
	data["start"] = "2026-10-20T09:00:00Z"
	data["due"] = "2026-10-20T17:00:00Z"
	data["rrule"] = "FREQ=DAILY;COUNT=3"
	w := x.req("POST", "/api/events", "alice", data, nil)
	x.expect(w, 201)
	e := readEvent(t, w)
	path := "/api/occurrences?from=2026-10-19T00:00:00Z&to=2026-10-25T00:00:00Z"
	w = x.req("GET", path, "alice", nil, nil)
	x.expect(w, 200)
	var items []occurrence
	_ = json.Unmarshal(w.Body.Bytes(), &items)
	if len(items) != 3 {
		t.Fatal("missing todo occurrences")
	}
	x.expect(x.req("POST", "/api/events/"+e.ID+"/exceptions", "alice", map[string]any{"recurrence_id": items[0].RecurrenceID, "operation": "complete", "completed": true, "version": e.Version}, nil), 204)
	w = x.req("GET", path, "alice", nil, nil)
	x.expect(w, 200)
	_ = json.Unmarshal(w.Body.Bytes(), &items)
	if !items[0].Completed || items[1].Completed || items[2].Completed {
		t.Fatal("completion must affect only one todo")
	}
	raw := "BEGIN:VCALENDAR\nVERSION:2.0\nPRODID:-//Test//EN\nBEGIN:VTODO\nUID:undated\nDTSTAMP:20260101T000000Z\nSUMMARY:Someday\nEND:VTODO\nEND:VCALENDAR"
	x.expect(x.req("PUT", "/dav/alice/calendars/default/undated.ics", "", strings.ReplaceAll(raw, "\n", "\r\n"), map[string]string{"Authorization": "Basic YWxpY2U6Y29ycmVjdCBob3JzZSBiYXR0ZXJ5", "Content-Type": "text/calendar"}), 201)
	w = x.req("GET", path, "alice", nil, nil)
	x.expect(w, 200)
	if !strings.Contains(w.Body.String(), "Someday") {
		t.Fatal("undated task missing")
	}
}
func TestEditPreservesImportedDataAndUID(t *testing.T) {
	x := setup(t)
	x.register("alice")
	raw := wrapEvent("DTSTART:20260101T090000Z\nDURATION:P1D\nRRULE:FREQ=DAILY;COUNT=3\nRDATE;VALUE=PERIOD:20260110T090000Z/PT5H\nX-EXTERNAL:preserve-this\nBEGIN:VALARM\nACTION:DISPLAY\nDESCRIPTION:Reminder\nTRIGGER:-PT15M\nEND:VALARM")
	x.expect(x.req("PUT", "/dav/alice/calendars/default/imported.ics", "", strings.ReplaceAll(raw, "\n", "\r\n"), map[string]string{"Authorization": "Basic YWxpY2U6Y29ycmVjdCBob3JzZSBiYXR0ZXJ5", "Content-Type": "text/calendar"}), 201)
	w := x.req("GET", "/api/events", "alice", nil, nil)
	x.expect(w, 200)
	var items []Event
	_ = json.Unmarshal(w.Body.Bytes(), &items)
	e := items[0]
	e.Title = "Renamed, same series"
	x.expect(x.req("PUT", "/api/events/"+e.ID, "alice", e, nil), 200)
	w = x.req("GET", "/dav/alice/calendars/default/imported.ics", "", nil, map[string]string{"Authorization": "Basic YWxpY2U6Y29ycmVjdCBob3JzZSBiYXR0ZXJ5"})
	x.expect(w, 200)
	for _, want := range []string{"DURATION:P1D", "VALUE=PERIOD", "X-EXTERNAL:preserve-this", "BEGIN:VALARM", "UID:series"} {
		if !strings.Contains(w.Body.String(), want) {
			t.Fatalf("lost %s after app edit:\n%s", want, w.Body.String())
		}
	}
}
func TestRFC4791TodoTimeRangeBoundaries(t *testing.T) {
	for _, tc := range []struct {
		props, from, to string
		want            bool
	}{
		{"DUE:20260102T090000Z", "2026-01-02T08:00:00Z", "2026-01-02T09:00:00Z", true},
		{"DUE:20260102T090000Z", "2026-01-02T09:00:00Z", "2026-01-02T10:00:00Z", false},
		{"DTSTART:20260101T090000Z\nDUE:20260103T090000Z", "2026-01-02T00:00:00Z", "2026-01-02T01:00:00Z", true},
		{"CREATED:20260101T090000Z", "2026-02-01T00:00:00Z", "2026-02-02T00:00:00Z", true},
		{"COMPLETED:20260101T090000Z", "2026-02-01T00:00:00Z", "2026-02-02T00:00:00Z", false},
		{"", "2026-02-01T00:00:00Z", "2026-02-02T00:00:00Z", true},
	} {
		raw := strings.ReplaceAll(wrapEvent(tc.props), "VEVENT", "VTODO")
		cal := parseCalendar(t, raw)
		a, _ := time.Parse(time.RFC3339, tc.from)
		b, _ := time.Parse(time.RFC3339, tc.to)
		ctx := context.WithValue(context.Background(), caldavRangeKey{}, true)
		items, err := expandCalendar(ctx, cal, a, b, utcZone())
		if err != nil {
			t.Fatal(err)
		}
		if (len(items) > 0) != tc.want {
			t.Fatalf("wrong VTODO time-range for %s: %+v", tc.props, items)
		}
	}
}

func TestCalDAVFreeBusyAlarmsAndConditionalRequests(t *testing.T) {
	x := setup(t)
	x.register("alice")
	auth := map[string]string{"Authorization": "Basic YWxpY2U6Y29ycmVjdCBob3JzZSBiYXR0ZXJ5", "Content-Type": "text/calendar"}
	raw := wrapEvent("DTSTART:20260101T090000Z\nDTEND:20260101T100000Z\nRRULE:FREQ=DAILY;COUNT=3\nBEGIN:VALARM\nACTION:DISPLAY\nDESCRIPTION:Reminder\nTRIGGER:-PT30M\nEND:VALARM")
	put := x.req("PUT", "/dav/alice/calendars/default/alarm.ics", "", strings.ReplaceAll(raw, "\n", "\r\n"), auth)
	x.expect(put, 201)
	if put.Header().Get("ETag") != "" {
		t.Fatal("transformed PUT must not return an ETag")
	}
	w := x.req("GET", "/dav/alice/calendars/default/alarm.ics", "", nil, auth)
	x.expect(w, 200)
	etag := w.Header().Get("ETag")
	x.expect(x.req("GET", "/dav/alice/calendars/default/alarm.ics", "", nil, map[string]string{"Authorization": auth["Authorization"], "If-None-Match": "W/" + etag}), 304)
	x.expect(x.req("PUT", "/dav/alice/calendars/default/alarm.ics", "", strings.ReplaceAll(raw, "\n", "\r\n"), map[string]string{"Authorization": auth["Authorization"], "Content-Type": "text/calendar", "If-Match": `"stale", ` + etag}), 204)
	alarm := `<c:calendar-query xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:d="DAV:"><d:prop><d:getetag/></d:prop><c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VEVENT"><c:comp-filter name="VALARM"><c:time-range start="20260103T082900Z" end="20260103T083100Z"/></c:comp-filter></c:comp-filter></c:comp-filter></c:filter></c:calendar-query>`
	w = x.req("REPORT", "/dav/alice/calendars/default/", "", alarm, auth)
	x.expect(w, 207)
	if !strings.Contains(w.Body.String(), "alarm.ics") {
		t.Fatalf("recurring relative alarm query failed: %s", w.Body.String())
	}
	busy := `<c:free-busy-query xmlns:c="urn:ietf:params:xml:ns:caldav"><c:time-range start="20260101T000000Z" end="20260104T000000Z"/></c:free-busy-query>`
	w = x.req("REPORT", "/dav/alice/calendars/default/", "", busy, auth)
	x.expect(w, 200)
	if strings.Count(w.Body.String(), "FREEBUSY;") != 3 {
		t.Fatalf("free-busy omitted recurrences: %s", w.Body.String())
	}
	allprop := `<c:calendar-query xmlns:c="urn:ietf:params:xml:ns:caldav"><c:filter><c:comp-filter name="VCALENDAR"/></c:filter></c:calendar-query>`
	x.expect(x.req("REPORT", "/dav/alice/calendars/default/", "", allprop, auth), 207)
}
func TestLocalAuthoringInclusiveUntilAndGapInterpretation(t *testing.T) {
	x := setup(t)
	x.register("alice")
	e := example("event")
	e["start_local"] = "2026-10-30T23:30:00"
	e["end_local"] = "2026-10-31T00:30:00"
	e["timezone"] = "America/Toronto"
	e["rrule"] = "FREQ=DAILY"
	e["until_date"] = "2026-11-01"
	w := x.req("POST", "/api/events", "alice", e, nil)
	x.expect(w, 201)
	w = x.req("GET", "/api/occurrences?from=2026-10-30T00:00:00Z&to=2026-11-05T00:00:00Z", "alice", nil, nil)
	x.expect(w, 200)
	var items []occurrence
	_ = json.Unmarshal(w.Body.Bytes(), &items)
	if len(items) != 3 || items[2].LocalStart != "2026-11-01T23:30:00" {
		t.Fatalf("inclusive local UNTIL mishandled: %s", w.Body.String())
	}
	z, _ := ianaZone("America/New_York")
	d := stamp{Wall: time.Date(2026, 3, 8, 2, 30, 0, 0, time.UTC), Zone: z}
	if d.instant().Format(time.RFC3339) != "2026-03-08T07:30:00Z" {
		t.Fatal("explicit gap must use pre-gap offset")
	}
	items2 := expandTest(t, wrapEvent("DTSTART:20260101T090060Z\nRRULE:FREQ=DAILY;COUNT=1"), "2026-01-01T00:00:00Z", "2026-01-02T00:00:00Z", "UTC")
	if len(items2) != 1 || items2[0].Start.Wall.Second() != 59 {
		t.Fatal("permitted leap-second fallback failed")
	}
}
func TestRangeAnchorSkipPreservesFutureSchedule(t *testing.T) {
	x := setup(t)
	x.register("alice")
	raw := strings.ReplaceAll(wrapEvent("DTSTART:20260101T090000Z\nDTEND:20260101T100000Z\nRRULE:FREQ=DAILY;COUNT=4"), "END:VCALENDAR", `BEGIN:VEVENT
UID:series
DTSTAMP:20260101T000000Z
RECURRENCE-ID;RANGE=THISANDFUTURE:20260102T090000Z
DTSTART:20260102T110000Z
DTEND:20260102T120000Z
SUMMARY:Later
END:VEVENT
END:VCALENDAR`)
	auth := map[string]string{"Authorization": "Basic YWxpY2U6Y29ycmVjdCBob3JzZSBiYXR0ZXJ5", "Content-Type": "text/calendar"}
	x.expect(x.req("PUT", "/dav/alice/calendars/default/range.ics", "", strings.ReplaceAll(raw, "\n", "\r\n"), auth), 201)
	w := x.req("GET", "/api/events", "alice", nil, nil)
	var events []Event
	_ = json.Unmarshal(w.Body.Bytes(), &events)
	e := events[0]
	x.expect(x.req("POST", "/api/events/"+e.ID+"/exceptions", "alice", map[string]any{"version": e.Version, "operation": "skip", "recurrence_id": "20260102T090000Z"}, nil), 204)
	w = x.req("GET", "/api/occurrences?from=2026-01-01T00:00:00Z&to=2026-01-06T00:00:00Z", "alice", nil, nil)
	x.expect(w, 200)
	var items []occurrence
	_ = json.Unmarshal(w.Body.Bytes(), &items)
	if len(items) != 3 || items[1].Start.Hour() != 11 || items[2].Start.Hour() != 11 {
		t.Fatalf("skip destroyed future range: %s", w.Body.String())
	}
}

func TestFarFutureTimezoneProjectionAndDuplicateSelectors(t *testing.T) {
	tz, err := timezoneComponent("America/Toronto")
	if err != nil {
		t.Fatal(err)
	}
	tz.Props.SetText("TZID", "Custom/Canadian")
	cal := parseCalendar(t, wrapEvent("DTSTART;TZID=Custom/Canadian:24260701T090000\nDTEND;TZID=Custom/Canadian:24260701T100000\nRRULE:FREQ=YEARLY"))
	cal.Children = append(cal.Children, tz)
	e, err := decodeEvent(cal)
	if err != nil {
		t.Fatal(err)
	}
	if e.Start.Format(time.RFC3339) != "2426-07-01T13:00:00Z" {
		t.Fatalf("far-future custom timezone was truncated: %s", e.Start)
	}
	items := expandTest(t, wrapEvent("DTSTART:20260101T090059Z\nRRULE:FREQ=MINUTELY;BYSECOND=59,60,59;COUNT=3"), "2026-01-01T00:00:00Z", "2026-01-02T00:00:00Z", "UTC")
	if len(items) != 3 || items[2].Start.Wall.Minute() != 2 {
		t.Fatal("duplicate selectors consumed COUNT")
	}
}
func TestAppEditPreservesExternalOrganizerAndSequence(t *testing.T) {
	x := setup(t)
	x.register("alice")
	raw := wrapEvent("DTSTART:20260101T090000Z\nDTEND:20260101T100000Z\nSEQUENCE:42\nORGANIZER:mailto:organizer@example.test\nATTENDEE:mailto:guest@example.test")
	auth := map[string]string{"Authorization": "Basic YWxpY2U6Y29ycmVjdCBob3JzZSBiYXR0ZXJ5", "Content-Type": "text/calendar"}
	x.expect(x.req("PUT", "/dav/alice/calendars/default/external.ics", "", strings.ReplaceAll(raw, "\n", "\r\n"), auth), 201)
	w := x.req("GET", "/api/events", "alice", nil, nil)
	var entries []Event
	_ = json.Unmarshal(w.Body.Bytes(), &entries)
	e := entries[0]
	e.Title = "Updated locally"
	x.expect(x.req("PUT", "/api/events/"+e.ID, "alice", e, nil), 200)
	w = x.req("GET", "/dav/alice/calendars/default/external.ics", "", nil, auth)
	x.expect(w, 200)
	for _, want := range []string{"SEQUENCE:43", "ORGANIZER:mailto:organizer@example.test", "ATTENDEE:mailto:guest@example.test", "UID:series"} {
		if !strings.Contains(w.Body.String(), want) {
			t.Fatalf("missing %s: %s", want, w.Body.String())
		}
	}
}
