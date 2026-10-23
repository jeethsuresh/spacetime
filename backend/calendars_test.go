package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	bolt "go.etcd.io/bbolt"
)

func TestCalendarCollectionsKeepUIDsAndResourcesSeparate(t *testing.T) {
	x := setup(t)
	x.register("alice")
	x.register("bobby")
	w := x.req("POST", "/api/calendars", "alice", Calendar{ID: "work", Name: "Work", Color: "#426EB4", Kind: "personal"}, nil)
	x.expect(w, 201)
	data := example("event")
	data["uid"] = "same-uid"
	data["title"] = "Personal only"
	personal := readEvent(t, x.req("POST", "/api/events", "alice", data, nil))
	data["calendar_id"] = "work"
	data["title"] = "Work only"
	w = x.req("POST", "/api/events", "alice", data, nil)
	x.expect(w, 201)
	work := readEvent(t, w)
	if personal.ID == work.ID || work.CalendarID != "work" || personal.CalendarID != defaultCalendarID("alice") {
		t.Fatal("calendar/UID isolation failed")
	}
	x.expect(x.req("POST", "/api/events", "bobby", data, nil), 403)
	x.expect(x.req("PUT", "/api/events/"+work.ID, "bobby", work, nil), 403)
	w = x.req("PROPFIND", "/dav/alice/calendars/", "alice", `<D:propfind xmlns:D="DAV:"><D:prop><D:displayname/></D:prop></D:propfind>`, map[string]string{"Depth": "1"})
	x.expect(w, 207)
	if !strings.Contains(w.Body.String(), "/calendars/work/") || !strings.Contains(w.Body.String(), "/calendars/default/") {
		t.Fatal("missing calendar discovery", w.Body.String())
	}
	w = x.req("REPORT", "/dav/alice/calendars/work/", "alice", `<C:calendar-query xmlns:C="urn:ietf:params:xml:ns:caldav" xmlns:D="DAV:"><D:prop><C:calendar-data/></D:prop><C:filter><C:comp-filter name="VCALENDAR"/></C:filter></C:calendar-query>`, nil)
	x.expect(w, 207)
	if !strings.Contains(w.Body.String(), "Work only") || strings.Contains(w.Body.String(), "Personal only") {
		t.Fatal("collection query crossed calendar boundary")
	}
	x.expect(x.req("GET", "/dav/alice/calendars/work/"+work.Resource, "bobby", nil, nil), 404)
	x.expect(x.req("DELETE", "/api/calendars/work", "alice", nil, map[string]string{"If-Match": `"1"`}), 409)
}

// Exercise production family proof + encrypted delegated credentials, with the
// IAM HTTP contract supplied by an isolated test identity server.
func sharedTestApp(t *testing.T) (*testApp, map[string]string, *bool, *int) {
	x := setup(t)
	for _, name := range []string{"alice", "bobby", "carol"} {
		x.register(name)
	}
	membership := map[string]string{"alice": "join", "bobby": "join", "carol": "invite"}
	outage := false
	creates := 0
	var server *httptest.Server
	server = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/oauth/session" {
			actor := strings.TrimSuffix(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer proof-"), strings.Repeat("x", 32))
			writeJSON(w, 200, map[string]any{"active": true, "iss": server.URL, "sub": actor, "app_origin": "https://spacetime.example", "session_id": "family-" + actor, "exp": time.Now().Add(time.Hour).Unix()})
			return
		}
		actor := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer access-")
		if outage {
			http.Error(w, "unavailable", 503)
			return
		}
		if r.URL.Path == "/app/v1/groups" {
			g := gravitasGroup{ID: "group-existing", Name: "Existing group", Membership: membership[actor], Owner: actor == "alice"}
			if r.Method == "POST" {
				creates++
				writeJSON(w, 200, g)
			} else {
				writeJSON(w, 200, map[string]any{"groups": []gravitasGroup{g}})
			}
			return
		}
		http.NotFound(w, r)
	}))
	t.Cleanup(server.Close)
	g, err := newGravitasAuth(server.URL, "https://spacetime.example", "")
	if err != nil {
		t.Fatal(err)
	}
	g.client.Transport = server.Client().Transport
	g.sessionChecks = true
	g.sessionKey = []byte(strings.Repeat("k", 32))
	x.app.gravitas = g
	for _, name := range []string{"alice", "bobby", "carol"} {
		binding, err := g.bindSession(context.Background(), server.URL+"/oauth/session", name, "family-"+name, "proof-"+name+strings.Repeat("x", 32), 3600)
		if err != nil {
			t.Fatal(err)
		}
		binding.GroupCredentials, err = g.sealGroups(binding, groupCredentials{Access: "access-" + name, Refresh: "refresh-" + name, Scope: sharedCalendarScopes, TokenEndpoint: server.URL + "/oauth/token", Expires: time.Now().Add(time.Hour)})
		if err != nil {
			t.Fatal(err)
		}
		err = x.app.store.db.Update(func(tx *bolt.Tx) error {
			var s Session
			if err := getJSON(tx, "sessions", tokenKey(x.tokens[name]), &s); err != nil {
				return err
			}
			s.Gravitas = binding
			return putJSON(tx, "sessions", tokenKey(x.tokens[name]), s)
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	return x, membership, &outage, &creates
}

func TestSharedCalendarMembershipDoesNotGrantAuthorship(t *testing.T) {
	x, membership, outage, creates := sharedTestApp(t)
	w := x.req("POST", "/api/calendars", "alice", Calendar{ID: "shared", Kind: "shared", GroupID: "group-existing", Name: "Household", Color: "#9163B3"}, nil)
	x.expect(w, 201)
	if *creates != 0 {
		t.Fatal("selecting an existing group created another group")
	}
	data := example("todo")
	data["calendar_id"] = "shared"
	w = x.req("POST", "/api/events", "bobby", data, nil)
	x.expect(w, 201)
	e := readEvent(t, w)
	w = x.req("GET", "/api/events", "alice", nil, nil)
	x.expect(w, 200)
	if !strings.Contains(w.Body.String(), e.ID) {
		t.Fatal("member cannot see shared event")
	}
	x.expect(x.req("PUT", "/api/events/"+e.ID, "alice", e, nil), 403)
	x.expect(x.req("DELETE", "/api/events/"+e.ID, "alice", nil, map[string]string{"If-Match": fmt.Sprintf(`"%d"`, e.Version)}), 403)
	x.expect(x.req("POST", "/api/events/"+e.ID+"/completion", "alice", map[string]any{"version": e.Version, "completed": true}, nil), 403)
	x.expect(x.req("POST", "/api/events/"+e.ID+"/exceptions", "alice", map[string]any{"version": e.Version, "operation": "skip", "recurrence_id": "20261020"}, nil), 403)
	x.expect(x.req("POST", "/api/events", "carol", data, nil), 403)
	if strings.Contains(x.req("GET", "/api/events", "carol", nil, nil).Body.String(), e.ID) {
		t.Fatal("pending invitation leaked events")
	}
	membership["bobby"] = "leave"
	if strings.Contains(x.req("GET", "/api/events", "bobby", nil, nil).Body.String(), e.ID) {
		t.Fatal("removed author retained group read access")
	}
	x.expect(x.req("PUT", "/api/events/"+e.ID, "bobby", e, nil), 403)
	*outage = true
	x.expect(x.req("GET", "/api/events", "alice", nil, nil), 503)
	var retained Event
	if err := x.app.store.db.View(func(tx *bolt.Tx) error { var err error; retained, err = eventTx(tx, e.ID); return err }); err != nil || retained.ID != e.ID {
		t.Fatal("outage discarded shared data")
	}
}

func TestGroupCredentialIsBoundToOneFamilyAndNotPublic(t *testing.T) {
	x, _, _, _ := sharedTestApp(t)
	var s Session
	x.app.store.db.View(func(tx *bolt.Tx) error { return getJSON(tx, "sessions", tokenKey(x.tokens["alice"]), &s) })
	if _, err := x.app.gravitas.openGroups(s.Gravitas); err != nil {
		t.Fatal(err)
	}
	copy := *s.Gravitas
	copy.SessionID = "other-family"
	if _, err := x.app.gravitas.openGroups(&copy); err == nil {
		t.Fatal("group credential crossed session families")
	}
	for _, endpoint := range []string{"/api/me", "/api/groups", "/api/calendars"} {
		w := x.req("GET", endpoint, "alice", nil, nil)
		x.expect(w, 200)
		if strings.Contains(w.Body.String(), "access-alice") || strings.Contains(w.Body.String(), "refresh-alice") || strings.Contains(w.Body.String(), "GroupCredentials") {
			t.Fatal("delegated credential leaked")
		}
	}
	var value map[string]any
	json.Unmarshal(x.req("GET", "/api/groups", "alice", nil, nil).Body.Bytes(), &value)
	if value["enabled"] != true {
		t.Fatal("missing consent capability")
	}
}

func TestDAVProjectsCollectionColorAndAuthorPrivileges(t *testing.T) {
	x, _, _, _ := sharedTestApp(t)
	x.expect(x.req("POST", "/api/calendars", "alice", Calendar{ID: "shared", Name: "Shared", Color: "#9163B3", Kind: "shared", GroupID: "group-existing"}, nil), 201)
	data := example("event")
	data["calendar_id"] = "shared"
	w := x.req("POST", "/api/events", "bobby", data, nil)
	x.expect(w, 201)
	e := readEvent(t, w)
	e.Resource = e.ID + ".ics"
	body := `<D:propfind xmlns:D="DAV:" xmlns:I="http://apple.com/ns/ical/"><D:prop><D:current-user-privilege-set/><I:calendar-color/></D:prop></D:propfind>`
	w = x.req("PROPFIND", "/dav/alice/calendars/shared/", "alice", body, map[string]string{"Depth": "0"})
	x.expect(w, 207)
	if !strings.Contains(w.Body.String(), "#9163B3FF") || !strings.Contains(w.Body.String(), "bind") || strings.Contains(w.Body.String(), "unbind") {
		t.Fatal("shared collection privileges/colour", w.Body.String())
	}
	w = x.req("PROPFIND", "/dav/alice/calendars/shared/"+e.Resource, "alice", body, map[string]string{"Depth": "0"})
	x.expect(w, 207)
	if strings.Contains(w.Body.String(), "write-content") {
		t.Fatal("calendar owner can edit member's resource")
	}
	w = x.req("PROPFIND", "/dav/bobby/calendars/shared/"+e.Resource, "bobby", body, map[string]string{"Depth": "0"})
	x.expect(w, 207)
	if !strings.Contains(w.Body.String(), "write-content") {
		t.Fatal("author cannot edit own resource", w.Body.String())
	}
}

func TestMKCALENDARPropertiesAreAtomic(t *testing.T) {
	x := setup(t)
	x.register("alice")
	body := `<C:mkcalendar xmlns:C="urn:ietf:params:xml:ns:caldav" xmlns:D="DAV:" xmlns:I="http://apple.com/ns/ical/"><D:set><D:prop><D:displayname>Work</D:displayname><I:calendar-color>#426EB4FF</I:calendar-color></D:prop></D:set></C:mkcalendar>`
	x.expect(x.req("MKCALENDAR", "/dav/alice/calendars/work/", "alice", body, nil), 201)
	x.expect(x.req("MKCALENDAR", "/dav/alice/calendars/work/", "alice", body, nil), 405)
	body = strings.Replace(body, "</D:prop>", "<D:unrecognized/></D:prop>", 1)
	w := x.req("MKCALENDAR", "/dav/alice/calendars/partial/", "alice", body, nil)
	x.expect(w, 207)
	if !strings.Contains(w.Body.String(), "424 Failed Dependency") {
		t.Fatal("missing atomic property failure", w.Body.String())
	}
	x.expect(x.req("PROPFIND", "/dav/alice/calendars/partial/", "alice", `<D:propfind xmlns:D="DAV:"><D:allprop/></D:propfind>`, nil), 404)
}
