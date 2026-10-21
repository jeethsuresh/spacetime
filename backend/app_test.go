package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type testApp struct {
	*testing.T
	app     *App
	handler http.Handler
	tokens  map[string]string
}

const testInviteKey = "test-registration-invite"

func setup(t *testing.T) *testApp {
	s, err := openStore(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.db.Close() })
	a := newApp(s)
	a.registrationInviteKey = testInviteKey
	return &testApp{t, a, a.handler(), map[string]string{}}
}
func (t *testApp) req(method, url, user string, body any, headers map[string]string) *httptest.ResponseRecorder {
	var b []byte
	if raw, ok := body.(string); ok {
		b = []byte(raw)
	} else if body != nil {
		var err error
		b, err = json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}
	}
	r := httptest.NewRequest(method, url, bytes.NewReader(b))
	r.RemoteAddr = "127.0.0.1:1234"
	if token := t.tokens[user]; token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	for k, v := range headers {
		r.Header.Set(k, v)
	}
	if method == "PROPFIND" || method == "REPORT" {
		r.Header.Set("Content-Type", "application/xml; charset=utf-8")
	}
	w := httptest.NewRecorder()
	t.handler.ServeHTTP(w, r)
	return w
}
func (t *testApp) expect(w *httptest.ResponseRecorder, code int) {
	t.Helper()
	if w.Code != code {
		t.Fatalf("expected %d, got %d: %s", code, w.Code, w.Body.String())
	}
}
func (t *testApp) register(name string) {
	w := t.req("POST", "/api/register", "", map[string]string{"username": name, "password": "correct horse battery", "name": name, "invite_key": testInviteKey}, nil)
	t.expect(w, 200)
	var v struct{ Token string }
	if err := json.Unmarshal(w.Body.Bytes(), &v); err != nil {
		t.Fatal(err)
	}
	t.tokens[name] = v.Token
}
func example(kind string) map[string]any {
	e := map[string]any{"title": "A thoughtful plan", "kind": kind, "attendees": map[string]string{}}
	if kind == "todo" {
		e["due"] = "2026-10-20T18:00:00Z"
	} else {
		e["start"] = "2026-10-20T09:00:00Z"
		e["end"] = "2026-10-20T10:00:00Z"
	}
	return e
}
func readEvent(t *testing.T, w *httptest.ResponseRecorder) Event {
	t.Helper()
	var e Event
	if err := json.Unmarshal(w.Body.Bytes(), &e); err != nil {
		t.Fatal(err)
	}
	return e
}
func TestAuthAndSessions(t *testing.T) {
	x := setup(t)
	x.expect(x.req("GET", "/api/events", "", nil, nil), 401)
	x.expect(x.req("POST", "/api/register", "", map[string]string{"username": "abc", "password": "short", "invite_key": testInviteKey}, nil), 400)
	x.register("alice")
	x.expect(x.req("POST", "/api/register", "", map[string]string{"username": "alice", "password": "correct horse battery", "invite_key": testInviteKey}, nil), 409)
	x.expect(x.req("POST", "/api/login", "", map[string]string{"username": "alice", "password": "wrong"}, nil), 401)
	w := x.req("POST", "/api/login", "", map[string]string{"username": "alice", "password": "correct horse battery"}, nil)
	x.expect(w, 200)
	if len(w.Result().Cookies()) != 1 || !w.Result().Cookies()[0].HttpOnly {
		t.Fatal("missing HttpOnly session cookie")
	}
	x.expect(x.req("GET", "/api/me", "alice", nil, nil), 200)
	x.expect(x.req("POST", "/api/events", "alice", example("event"), map[string]string{"Origin": "https://attacker.invalid"}), 403)
	x.expect(x.req("POST", "/api/logout", "alice", nil, nil), 204)
	x.expect(x.req("GET", "/api/me", "alice", nil, nil), 401)
}
func TestInvitationsPermissionsAndConflicts(t *testing.T) {
	x := setup(t)
	for _, n := range []string{"alice", "bobby", "carol"} {
		x.register(n)
	}
	data := example("event")
	data["attendees"] = map[string]string{"bobby": "accepted"}
	w := x.req("POST", "/api/events", "alice", data, nil)
	x.expect(w, 201)
	e := readEvent(t, w)
	if e.Attendees["bobby"] != "pending" {
		t.Fatal("organizer must not forge an RSVP")
	}
	x.expect(x.req("PUT", "/api/events/"+e.ID, "bobby", e, nil), 403)
	x.expect(x.req("POST", "/api/events/"+e.ID+"/respond", "carol", map[string]string{"status": "accepted"}, nil), 404)
	w = x.req("GET", "/api/events", "bobby", nil, nil)
	if w.Body.String() != "[]\n" {
		t.Fatalf("pending event must not appear in calendar: %s", w.Body.String())
	}
	w = x.req("GET", "/api/invitations", "bobby", nil, nil)
	if !strings.Contains(w.Body.String(), e.ID) {
		t.Fatal("invitation missing")
	}
	x.expect(x.req("POST", "/api/events/"+e.ID+"/respond", "bobby", map[string]string{"status": "accepted"}, nil), 204)
	w = x.req("GET", "/api/events", "bobby", nil, nil)
	if !strings.Contains(w.Body.String(), e.ID) {
		t.Fatal("accepted invitation missing")
	}
	// Accepted plans also appear in CalDAV, but attendees cannot edit or delete them.
	bobbyAuth := "Basic Ym9iYnk6Y29ycmVjdCBob3JzZSBiYXR0ZXJ5"
	invitedURL := "/dav/bobby/calendars/default/invited-" + e.ID + ".ics"
	x.expect(x.req("GET", invitedURL, "", nil, map[string]string{"Authorization": bobbyAuth}), 200)
	x.expect(x.req("PUT", invitedURL, "", todoICS, map[string]string{"Authorization": bobbyAuth, "Content-Type": "text/calendar"}), 403)
	x.expect(x.req("DELETE", invitedURL, "", nil, map[string]string{"Authorization": bobbyAuth}), 403)
	x.expect(x.req("PUT", "/api/events/"+e.ID, "alice", e, nil), 409)
	x.expect(x.req("DELETE", "/api/events/"+e.ID, "carol", nil, nil), 403)
	x.expect(x.req("DELETE", "/api/events/"+e.ID, "alice", nil, map[string]string{"If-Match": "\"1\""}), 409)
	x.expect(x.req("DELETE", "/api/events/"+e.ID, "alice", nil, map[string]string{"If-Match": "\"2\""}), 204)
	w = x.req("GET", "/api/events", "bobby", nil, nil)
	if strings.Contains(w.Body.String(), e.ID) {
		t.Fatal("deleted event still visible")
	}
}
func TestTodosBirthdaysAndStorage(t *testing.T) {
	x := setup(t)
	x.register("alice")
	data := example("todo")
	delete(data, "due")
	x.expect(x.req("POST", "/api/events", "alice", data, nil), 400)
	w := x.req("POST", "/api/events", "alice", example("todo"), nil)
	x.expect(w, 201)
	e := readEvent(t, w)
	e.Completed = true
	w = x.req("PUT", "/api/events/"+e.ID, "alice", e, nil)
	x.expect(w, 200)
	e = readEvent(t, w)
	if !e.Completed || e.Due == nil || e.Start != nil {
		t.Fatal("todo projection incorrect")
	}
	data = example("birthday")
	data["start"] = "2026-10-23T00:00:00Z"
	data["end"] = "2026-10-24T00:00:00Z"
	w = x.req("POST", "/api/events", "alice", data, nil)
	x.expect(w, 201)
	birthday := readEvent(t, w)
	if !birthday.Yearly || !birthday.AllDay {
		t.Fatal("birthday should be all-day and yearly")
	}
	file := filepath.Join(t.TempDir(), "persist.db")
	s, err := openStore(file)
	if err != nil {
		t.Fatal(err)
	}
	if err = seedDemo(s); err != nil {
		t.Fatal(err)
	}
	s.db.Close()
	s, err = openStore(file)
	if err != nil {
		t.Fatal(err)
	}
	defer s.db.Close()
	if _, err = s.user("alex"); err != nil {
		t.Fatal("account did not survive restart")
	}
}

const todoICS = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Test//EN\r\nBEGIN:VTODO\r\nUID:task-123\r\nDTSTAMP:20261018T120000Z\r\nDUE;VALUE=DATE:20261020\r\nSUMMARY:Buy coffee\r\nSTATUS:NEEDS-ACTION\r\nX-CUSTOM:keep-me\r\nEND:VTODO\r\nEND:VCALENDAR\r\n"

func TestCalDAVDiscoveryRoundtripQueriesAndIsolation(t *testing.T) {
	x := setup(t)
	x.register("alice")
	x.register("bobby")
	basic := "Basic YWxpY2U6Y29ycmVjdCBob3JzZSBiYXR0ZXJ5" // alice:correct horse battery
	headers := map[string]string{"Authorization": basic, "Content-Type": "text/calendar"}
	base := "/dav/alice/calendars/default/"
	url := base + "task.ics"
	x.expect(x.req("PROPFIND", base, "", nil, nil), 401)
	w := x.req("GET", "/.well-known/caldav", "", nil, headers)
	x.expect(w, 308)
	if w.Header().Get("Location") != "/dav/alice/" {
		t.Fatal("bad principal redirect")
	}
	w = x.req("PROPFIND", base, "", `<d:propfind xmlns:d="DAV:"><d:allprop/></d:propfind>`, map[string]string{"Authorization": basic, "Depth": "1"})
	x.expect(w, 207)
	w = x.req("PUT", url, "", todoICS, map[string]string{"Authorization": basic, "Content-Type": "text/calendar", "If-None-Match": "*"})
	x.expect(w, 201)
	etag := x.req("GET", url, "", nil, headers).Header().Get("ETag")
	if etag == "" {
		t.Fatal("missing ETag")
	}
	x.expect(x.req("PUT", url, "", todoICS, map[string]string{"Authorization": basic, "Content-Type": "text/calendar", "If-None-Match": "*"}), 412)
	x.expect(x.req("PUT", base+"duplicate.ics", "", todoICS, headers), 403)
	w = x.req("GET", url, "", nil, headers)
	x.expect(w, 200)
	if !strings.Contains(w.Body.String(), "X-CUSTOM:keep-me") {
		t.Fatal("unknown property lost")
	}
	x.expect(x.req("GET", "/dav/bobby/calendars/default/task.ics", "", nil, headers), 404)
	x.expect(x.req("REPORT", "/dav/bobby/calendars/default/", "", `<c:calendar-query xmlns:c="urn:ietf:params:xml:ns:caldav"><c:filter><c:comp-filter name="VCALENDAR"/></c:filter></c:calendar-query>`, headers), 404)
	query := `<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop><d:getetag/><c:calendar-data/></d:prop><c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="%s"/></c:comp-filter></c:filter></c:calendar-query>`
	w = x.req("REPORT", base, "", fmt.Sprintf(query, "VTODO"), headers)
	x.expect(w, 207)
	if !strings.Contains(w.Body.String(), "Buy coffee") {
		t.Fatal("VTODO query missing task")
	}
	w = x.req("REPORT", base, "", fmt.Sprintf(query, "VEVENT"), headers)
	x.expect(w, 207)
	if strings.Contains(w.Body.String(), "Buy coffee") {
		t.Fatal("VEVENT query returned VTODO")
	}
	w = x.req("GET", "/api/events", "alice", nil, nil)
	if !strings.Contains(w.Body.String(), `"kind":"todo"`) {
		t.Fatal("CalDAV task missing from API")
	}
	x.expect(x.req("PUT", url, "", strings.ReplaceAll(todoICS, "Buy coffee", "Buy tea"), map[string]string{"Authorization": basic, "Content-Type": "text/calendar", "If-Match": "\"stale\""}), 412)
	x.expect(x.req("PUT", url, "", strings.ReplaceAll(todoICS, "Buy coffee", "Buy tea"), map[string]string{"Authorization": basic, "Content-Type": "text/calendar", "If-Match": etag}), 204)
	x.expect(x.req("DELETE", url, "", nil, map[string]string{"Authorization": basic, "If-Match": etag}), 412)
	x.expect(x.req("DELETE", url, "", nil, headers), 204)
	x.expect(x.req("GET", url, "", nil, headers), 404)
}
func TestCalendarEncoding(t *testing.T) {
	when := time.Date(2026, 10, 23, 0, 0, 0, 0, time.UTC)
	end := when.AddDate(0, 0, 1)
	e := Event{ID: "birthday", Owner: "alice", Title: "Comma, semicolon; newline\nBirthday", Kind: "birthday", Start: &when, End: &end, AllDay: true, Yearly: true, Updated: time.Now(), Version: 1, Attendees: map[string]string{}}
	raw, err := encodeEvent(e)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"BEGIN:VEVENT", "RRULE:FREQ=YEARLY", "DTSTART;VALUE=DATE:20261023", "DTEND;VALUE=DATE:20261024", "X-SPACETIME-KIND;VALUE=TEXT:birthday"} {
		if !strings.Contains(raw, want) {
			t.Errorf("missing %s in %s", want, raw)
		}
	}
}
