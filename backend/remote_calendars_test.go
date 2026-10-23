package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	bolt "go.etcd.io/bbolt"
)

func sourceICS(uid, title, kind string) string {
	dates := "DTSTART:20261020T090000Z\r\nDTEND:20261020T100000Z\r\n"
	if kind == "VTODO" {
		dates = "DUE:20261020T180000Z\r\n"
	}
	return "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Independent source fixture//EN\r\nBEGIN:" + kind + "\r\nUID:" + uid + "\r\nDTSTAMP:20261001T000000Z\r\nSUMMARY:" + title + "\r\nX-SOURCE-EXTRA:keep me\r\n" + dates + "END:" + kind + "\r\nEND:VCALENDAR\r\n"
}

type sourceFixture struct {
	sync.Mutex
	server                    *httptest.Server
	data                      map[string]string
	versions                  map[string]int
	readOnly, race, canonical bool
	puts, deletes             int
}

func newSourceFixture(t *testing.T) *sourceFixture {
	s := &sourceFixture{data: map[string]string{"/source/event.ics": sourceICS("remote-event", "From source", "VEVENT"), "/source/task.ics": sourceICS("remote-task", "Source task", "VTODO")}, versions: map[string]int{"/source/event.ics": 1, "/source/task.ics": 1}}
	s.server = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s.Lock()
		defer s.Unlock()
		user, password, ok := r.BasicAuth()
		if !ok || user != "source-user" || password != "source-secret" {
			w.WriteHeader(401)
			return
		}
		etag := func(p string) string { return fmt.Sprintf(`"r%d"`, s.versions[p]) }
		response := func(p, props string) string {
			return `<D:response><D:href>` + xmlEscape(p) + `</D:href><D:propstat><D:prop>` + props + `</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>`
		}
		switch r.Method {
		case "OPTIONS":
			allow := "GET, HEAD, OPTIONS"
			if !s.readOnly {
				allow += ", PUT, DELETE"
			}
			w.Header().Set("Allow", allow)
			w.WriteHeader(200)
		case "PROPFIND":
			priv := `<D:privilege><D:read/></D:privilege>`
			if !s.readOnly {
				priv += `<D:privilege><D:write/></D:privilege>`
			}
			props := `<D:resourcetype><D:collection/><C:calendar/></D:resourcetype><D:displayname>Source calendar</D:displayname><D:current-user-privilege-set>` + priv + `</D:current-user-privilege-set>`
			body := response("/source/", props)
			if r.Header.Get("Depth") == "1" {
				for p := range s.data {
					body += response(p, `<D:getetag>`+xmlEscape(etag(p))+`</D:getetag><D:getcontenttype>text/calendar</D:getcontenttype><D:resourcetype/>`)
				}
			}
			w.Header().Set("Content-Type", "application/xml")
			w.WriteHeader(207)
			fmt.Fprint(w, `<D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">`+body+`</D:multistatus>`)
		case "REPORT":
			body := ""
			for p, data := range s.data {
				body += response(p, `<D:getetag>`+xmlEscape(etag(p))+`</D:getetag><C:calendar-data>`+xmlEscape(data)+`</C:calendar-data>`)
			}
			if s.race {
				s.race = false
				s.data["/source/event.ics"] = sourceICS("remote-event", "Concurrent source edit", "VEVENT")
				s.versions["/source/event.ics"]++
			}
			w.Header().Set("Content-Type", "application/xml")
			w.WriteHeader(207)
			fmt.Fprint(w, `<D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">`+body+`</D:multistatus>`)
		case "GET", "HEAD":
			data, ok := s.data[r.URL.Path]
			if !ok {
				w.WriteHeader(404)
				return
			}
			w.Header().Set("Content-Type", "text/calendar")
			w.Header().Set("ETag", etag(r.URL.Path))
			if r.Method == "GET" {
				fmt.Fprint(w, data)
			}
		case "PUT":
			if s.readOnly {
				w.WriteHeader(403)
				return
			}
			_, exists := s.data[r.URL.Path]
			if exists && r.Header.Get("If-Match") != etag(r.URL.Path) || !exists && r.Header.Get("If-None-Match") != "*" {
				w.WriteHeader(412)
				return
			}
			raw, _ := io.ReadAll(r.Body)
			data := string(raw)
			if s.canonical {
				data = strings.ReplaceAll(data, "SUMMARY:Changed by app", "SUMMARY:Canonical title")
			}
			s.data[r.URL.Path] = data
			s.versions[r.URL.Path]++
			s.puts++
			w.WriteHeader(204)
		case "DELETE":
			if s.readOnly {
				w.WriteHeader(403)
				return
			}
			if r.Header.Get("If-Match") != etag(r.URL.Path) {
				w.WriteHeader(412)
				return
			}
			delete(s.data, r.URL.Path)
			s.deletes++
			w.WriteHeader(204)
		default:
			w.WriteHeader(405)
		}
	}))
	t.Cleanup(s.server.Close)
	return s
}
func connectFixture(t *testing.T, x *testApp, s *sourceFixture, kind, url string) Calendar {
	t.Helper()
	x.app.remoteHTTP = s.server.Client()
	w := x.req("POST", "/api/calendars/connect", "alice", map[string]string{"name": "Source", "color": "#426EB4", "kind": kind, "url": s.server.URL + url, "username": "source-user", "password": "source-secret"}, nil)
	x.expect(w, 201)
	var c Calendar
	if err := json.Unmarshal(w.Body.Bytes(), &c); err != nil {
		t.Fatal(err)
	}
	return c
}
func listedSourceEvent(t *testing.T, x *testApp, c Calendar, kind string) Event {
	t.Helper()
	w := x.req("GET", "/api/events", "alice", nil, nil)
	x.expect(w, 200)
	var events []Event
	if err := json.Unmarshal(w.Body.Bytes(), &events); err != nil {
		t.Fatal(err)
	}
	for _, e := range events {
		if e.CalendarID == c.ID && e.Kind == kind {
			return e
		}
	}
	t.Fatal("source entry not found", w.Body.String())
	return Event{}
}

func TestServerSyncsCalDAVEventsAndTodosAndReadsCanonicalWrites(t *testing.T) {
	x := setup(t)
	x.register("alice")
	s := newSourceFixture(t)
	c := connectFixture(t, x, s, "caldav", "/source/")
	e := listedSourceEvent(t, x, c, "event")
	todo := listedSourceEvent(t, x, c, "todo")
	if todo.UID != "remote-task" || e.UID != "remote-event" {
		t.Fatal("UID or todo import lost")
	}
	s.canonical = true
	e.Title = "Changed by app"
	w := x.req("PUT", "/api/events/"+e.ID, "alice", e, nil)
	x.expect(w, 200)
	updated := readEvent(t, w)
	if updated.Title != "Canonical title" {
		t.Fatal("server failed to defer to source representation", w.Body.String())
	}
	if !strings.Contains(s.data["/source/event.ics"], "X-SOURCE-EXTRA:keep me") {
		t.Fatal("source extension property was lost")
	}
	w = x.req("POST", "/api/events/"+todo.ID+"/completion", "alice", map[string]any{"version": todo.Version, "completed": true}, nil)
	x.expect(w, 204)
	if !strings.Contains(s.data["/source/task.ics"], "STATUS:COMPLETED") {
		t.Fatal("todo completion was not written to source")
	}
	x.expect(x.req("DELETE", "/api/events/"+e.ID, "alice", nil, map[string]string{"If-Match": fmt.Sprintf(`"%d"`, updated.Version)}), 204)
	if _, ok := s.data["/source/event.ics"]; ok {
		t.Fatal("event deletion stayed local")
	}
	var stored remoteSource
	x.app.store.db.View(func(tx *bolt.Tx) error {
		raw := tx.Bucket([]byte("remote_calendars")).Get([]byte(c.ID))
		if strings.Contains(string(raw), "source-secret") || strings.Contains(string(raw), "source-user") {
			t.Fatal("source credentials stored in plaintext")
		}
		var err error
		stored, err = x.app.loadRemoteSource(tx, c.ID)
		return err
	})
	if _, err := newApp(x.app.store).openSource(stored); err != nil {
		t.Fatal("source credential did not survive restart", err)
	}
	stored.Owner = "another-owner"
	if _, err := x.app.openSource(stored); err == nil {
		t.Fatal("source credential binding was mutable")
	}
}
func TestSourceReadOnlyAndConcurrentETagChangesAreAuthoritative(t *testing.T) {
	x := setup(t)
	x.register("alice")
	s := newSourceFixture(t)
	s.readOnly = true
	c := connectFixture(t, x, s, "caldav", "/source/")
	if !c.ReadOnly {
		t.Fatal("read-only source imported as writable")
	}
	e := listedSourceEvent(t, x, c, "event")
	e.Title = "Should not write"
	x.expect(x.req("PUT", "/api/events/"+e.ID, "alice", e, nil), 403)
	if s.puts != 0 {
		t.Fatal("read-only source received write")
	}
	s.readOnly = false
	e = listedSourceEvent(t, x, c, "event")
	s.race = true
	e.Title = "Stale app edit"
	x.expect(x.req("PUT", "/api/events/"+e.ID, "alice", e, nil), 409)
	if s.puts != 0 {
		t.Fatal("a stale edit overwrote the source")
	}
	canonical := listedSourceEvent(t, x, c, "event")
	if canonical.Title != "Concurrent source edit" {
		t.Fatal("source did not win conflict")
	}
}
func TestWebDAVCollectionAndReconnectDoNotDuplicateCalendars(t *testing.T) {
	x := setup(t)
	x.register("alice")
	s := newSourceFixture(t)
	c := connectFixture(t, x, s, "webdav", "/source/")
	again := connectFixture(t, x, s, "webdav", "/source/")
	if c.ID != again.ID {
		t.Fatal("reconnect duplicated source")
	}
	if listedSourceEvent(t, x, c, "todo").UID != "remote-task" {
		t.Fatal("WebDAV todo not imported")
	}
	x.register("bobby")
	if strings.Contains(x.req("GET", "/api/events", "bobby", nil, nil).Body.String(), "remote-task") {
		t.Fatal("source connection leaked to another account")
	}
}
func TestRemoteURLsAndCredentialRedirectsRejectSSRF(t *testing.T) {
	for _, raw := range []string{"file:///etc/passwd", "https://user:secret@example.com/cal/", "http://example.com/cal/", "https://example.com/cal/#fragment"} {
		if _, err := normalizeRemoteURL(raw); err == nil {
			t.Fatalf("accepted unsafe URL %s", raw)
		}
	}
	for _, ip := range []string{"127.0.0.1", "10.0.0.1", "169.254.169.254", "100.64.1.1", "::1", "fd00::1", "2002:7f00:1::"} {
		if remoteIPAllowed(net.ParseIP(ip)) {
			t.Fatalf("accepted private/reserved source %s", ip)
		}
	}
	base, _ := normalizeRemoteURL("https://calendar.example/collection/")
	if _, err := sourceHref(base, "https://attacker.example/steal"); err == nil {
		t.Fatal("cross-origin source href accepted")
	}
	x := setup(t)
	s := newSourceFixture(t)
	_, _, _, err := x.app.sourceRequest(t.Context(), remoteSource{URL: s.server.URL, Kind: "caldav"}, remoteCredentials{"source-user", "source-secret"}, "GET", s.server.URL, "", nil)
	if err == nil {
		t.Fatal("private-address source reached through default client")
	}
}

func TestDAVSourceReadsRefreshExternalChangesAndPrivileges(t *testing.T) {
	x := setup(t)
	x.register("alice")
	s := newSourceFixture(t)
	c := connectFixture(t, x, s, "caldav", "/source/")
	s.Lock()
	s.data["/source/event.ics"] = sourceICS("remote-event", "Changed outside Spacetime", "VEVENT")
	s.versions["/source/event.ics"]++
	s.readOnly = true
	s.Unlock()
	body := `<C:calendar-query xmlns:C="urn:ietf:params:xml:ns:caldav" xmlns:D="DAV:"><D:prop><C:calendar-data/></D:prop><C:filter><C:comp-filter name="VCALENDAR"/></C:filter></C:calendar-query>`
	w := x.req("REPORT", "/dav/alice/calendars/"+c.ID+"/", "alice", body, nil)
	x.expect(w, 207)
	if !strings.Contains(w.Body.String(), "Changed outside Spacetime") {
		t.Fatal("DAV client received stale source data", w.Body.String())
	}
	w = x.req("PROPFIND", "/dav/alice/calendars/"+c.ID+"/", "alice", `<D:propfind xmlns:D="DAV:"><D:prop><D:current-user-privilege-set/></D:prop></D:propfind>`, map[string]string{"Depth": "0"})
	x.expect(w, 207)
	if strings.Contains(w.Body.String(), "<bind") || strings.Contains(w.Body.String(), "write-content") {
		t.Fatal("source permission changes were stale", w.Body.String())
	}
}
