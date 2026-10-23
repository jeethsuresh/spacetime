package main

import (
	"context"
	"encoding/json"
	"net/http"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	bolt "go.etcd.io/bbolt"
)

// Calendar membership is independent of event authorship. Group membership
// permits creation, while the immutable event owner controls every mutation.
type Calendar struct {
	ID          string     `json:"id"`
	Owner       string     `json:"owner"`
	Name        string     `json:"name"`
	Description string     `json:"description,omitempty"`
	Color       string     `json:"color"`
	Kind        string     `json:"kind"`
	GroupID     string     `json:"group_id,omitempty"`
	Issuer      string     `json:"issuer,omitempty"`
	ReadOnly    bool       `json:"read_only"`
	Version     int        `json:"version"`
	Updated     time.Time  `json:"updated"`
	SourceURL   string     `json:"source_url,omitempty"`
	SourceKind  string     `json:"source_kind,omitempty"`
	SourceRef   string     `json:"source_ref,omitempty"`
	SyncError   string     `json:"sync_error,omitempty"`
	LastSync    *time.Time `json:"last_sync,omitempty"`
}

type calendarAccessKey struct{}
type calendarAccess struct {
	Calendars     map[string]Calendar
	Groups        map[string]gravitasGroup
	GroupsEnabled bool
	SharedIDs     map[string]bool
}
type sessionContextKey struct{}

var calendarIDPattern = regexp.MustCompile(`^[a-zA-Z0-9_-]{1,100}$`)
var colorPattern = regexp.MustCompile(`^#[0-9a-fA-F]{6}$`)

func defaultCalendarID(user string) string { return "default-" + user }
func defaultCalendar(user string) Calendar {
	return Calendar{ID: defaultCalendarID(user), Owner: user, Name: "Personal", Color: "#376B51", Kind: "personal", Version: 1}
}
func calendarTx(tx *bolt.Tx, id string) (Calendar, error) {
	var c Calendar
	if err := getJSON(tx, "calendars", id, &c); err == nil {
		return c, nil
	} else if err != errNotFound {
		return c, err
	}
	if strings.HasPrefix(id, "default-") {
		if _, err := userTx(tx, strings.TrimPrefix(id, "default-")); err == nil {
			return defaultCalendar(strings.TrimPrefix(id, "default-")), nil
		}
	}
	return c, errNotFound
}
func eventCalendar(e Event) string {
	if e.CalendarID != "" {
		return e.CalendarID
	}
	return defaultCalendarID(e.Owner)
}
func accessFor(ctx context.Context) calendarAccess {
	a, ok := ctx.Value(calendarAccessKey{}).(calendarAccess)
	if !ok {
		a.Calendars = map[string]Calendar{defaultCalendarID(currentUser(ctx)): defaultCalendar(currentUser(ctx))}
	}
	return a
}
func calendarReadable(ctx context.Context, id string) bool {
	_, ok := accessFor(ctx).Calendars[id]
	return ok
}
func calendarWritable(ctx context.Context, id string) bool {
	c, ok := accessFor(ctx).Calendars[id]
	return ok && !c.ReadOnly
}
func eventVisible(ctx context.Context, e Event) bool {
	if c, ok := accessFor(ctx).Calendars[eventCalendar(e)]; ok {
		return c.Kind == "shared" || c.Owner == currentUser(ctx)
	}
	if accessFor(ctx).SharedIDs[eventCalendar(e)] {
		return false
	}
	// Individual invitations remain in the recipient's personal collection.
	return e.Attendees[currentUser(ctx)] == "accepted"
}
func canMutateEvent(ctx context.Context, e Event) bool {
	return e.Owner == currentUser(ctx) && calendarWritable(ctx, eventCalendar(e))
}

func (a *App) calendarContext(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 90*time.Second)
		defer cancel()
		r = r.WithContext(ctx)
		access := calendarAccess{Calendars: map[string]Calendar{}, Groups: map[string]gravitasGroup{}, SharedIDs: map[string]bool{}}
		access.Calendars[defaultCalendarID(currentUser(r.Context()))] = defaultCalendar(currentUser(r.Context()))
		groups, enabled, err := a.currentGroups(r.Context())
		if err != nil {
			serveError(w, err)
			return
		}
		access.GroupsEnabled = enabled
		for _, g := range groups {
			access.Groups[g.ID] = g
		}
		err = a.store.db.View(func(tx *bolt.Tx) error {
			return tx.Bucket([]byte("calendars")).ForEach(func(_, v []byte) error {
				var c Calendar
				if err := json.Unmarshal(v, &c); err != nil {
					return err
				}
				if c.Kind == "shared" {
					access.SharedIDs[c.ID] = true
					if g, ok := access.Groups[c.GroupID]; ok && g.Membership == "join" && a.gravitas != nil && c.Issuer == a.gravitas.issuer {
						access.Calendars[c.ID] = c
					}
				} else if c.Owner == currentUser(r.Context()) {
					access.Calendars[c.ID] = c
				}
				return nil
			})
		})
		if err != nil {
			serveError(w, err)
			return
		}
		remote := strings.HasPrefix(r.URL.Path, "/api/calendars/discover") || strings.HasPrefix(r.URL.Path, "/api/calendars/connect")
		for _, c := range access.Calendars {
			if c.Kind == "source" {
				remote = true
			}
		}
		if remote {
			a.remoteMu.Lock()
			defer a.remoteMu.Unlock()
		}
		ctx = context.WithValue(r.Context(), calendarAccessKey{}, access)
		ctx = context.WithValue(ctx, calendarAppKey{}, a)
		if (r.Method == "PUT" || r.Method == "DELETE") && strings.HasPrefix(r.URL.Path, "/dav/") {
			if id, _, err := davCalendarID(ctx, r.URL.Path); err == nil && access.Calendars[id].Kind == "source" {
				if err := a.pullSource(ctx, id); err != nil {
					serveError(w, err)
					return
				}
			}
		}
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

func (a *App) listCalendars(w http.ResponseWriter, r *http.Request) {
	items := []Calendar{}
	for _, c := range accessFor(r.Context()).Calendars {
		c.SourceRef = ""
		items = append(items, c)
	}
	sort.Slice(items, func(i, j int) bool { return items[i].Name < items[j].Name })
	groups := []gravitasGroup{}
	for _, g := range accessFor(r.Context()).Groups {
		groups = append(groups, g)
	}
	writeJSON(w, 200, map[string]any{"calendars": items, "groups_enabled": accessFor(r.Context()).GroupsEnabled, "groups": groups})
}
func (a *App) putCalendar(w http.ResponseWriter, r *http.Request) {
	var c Calendar
	if !decode(w, r, &c) {
		return
	}
	c.Name = strings.TrimSpace(c.Name)
	if c.Name == "" || len(c.Name) > 120 || !colorPattern.MatchString(c.Color) {
		fail(w, 400, "Enter a calendar name and a six-digit colour.")
		return
	}
	creating := r.Method == "POST"
	if c.Kind == "" {
		c.Kind = "personal"
	}
	if c.Kind != "personal" && c.Kind != "shared" && (creating || c.Kind != "source") {
		fail(w, 400, "Choose a personal or shared calendar.")
		return
	}
	if creating && c.Kind == "shared" {
		g, ok := accessFor(r.Context()).Groups[c.GroupID]
		if !ok || g.Membership != "join" {
			fail(w, 403, "Join and authorize this Gravitas group first.")
			return
		}
		c.Issuer = a.gravitas.issuer
	}
	err := a.store.db.Update(func(tx *bolt.Tx) error {
		if creating {
			if c.ID == "" {
				c.ID = randomID()
			}
			if !calendarIDPattern.MatchString(c.ID) || strings.HasPrefix(c.ID, "default-") {
				return statusError(400, "Invalid calendar identifier.")
			}
			if old, err := calendarTx(tx, c.ID); err == nil {
				if old.Owner == currentUser(r.Context()) && old.Name == c.Name && old.Kind == c.Kind && old.GroupID == c.GroupID {
					c = old
					return nil
				}
				return statusError(409, "Calendar identifier already exists.")
			}
			c.Owner = currentUser(r.Context())
			c.Version = 1
			if c.Kind == "personal" {
				c.GroupID = ""
				c.Issuer = ""
				c.SourceURL = ""
				c.SourceKind = ""
				c.SourceRef = ""
				c.LastSync = nil
				c.SyncError = ""
			}
			c.ReadOnly = false
		} else {
			old, err := calendarTx(tx, r.PathValue("id"))
			if err != nil {
				return err
			}
			if old.Owner != currentUser(r.Context()) || !calendarReadable(r.Context(), old.ID) {
				return statusError(403, "Only the calendar owner can change its settings.")
			}
			if old.Version != c.Version {
				return statusError(409, "Calendar settings changed. Refresh first.")
			}
			// Rebinding to a different group is never an ordinary rename.
			old.Name, old.Color, old.Version = c.Name, strings.ToUpper(c.Color), old.Version+1
			c = old
		}
		c.Color = strings.ToUpper(c.Color)
		c.Updated = time.Now().UTC()
		return putJSON(tx, "calendars", c.ID, c)
	})
	if err != nil {
		serveError(w, err)
		return
	}
	code := 200
	if creating {
		code = 201
	}
	c.SourceRef = ""
	writeJSON(w, code, c)
}

func (a *App) deleteCalendar(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if strings.HasPrefix(id, "default-") {
		fail(w, 400, "The personal calendar cannot be removed.")
		return
	}
	err := a.store.db.Update(func(tx *bolt.Tx) error {
		c, err := calendarTx(tx, id)
		if err != nil {
			return err
		}
		if c.Owner != currentUser(r.Context()) || !calendarReadable(r.Context(), id) {
			return statusError(403, "Only the calendar owner can remove this calendar.")
		}
		if r.Header.Get("If-Match") != `"`+strconv.Itoa(c.Version)+`"` {
			return statusError(409, "Calendar settings changed. Refresh first.")
		}
		events, err := eventsTx(tx)
		if err != nil {
			return err
		}
		for _, e := range events {
			if eventCalendar(e) == id {
				if c.Kind != "source" {
					return statusError(409, "Move or remove this calendar's entries first.")
				}
				if err := tx.Bucket([]byte("events")).Delete([]byte(e.ID)); err != nil {
					return err
				}
			}
		}
		if err := tx.Bucket([]byte("remote_calendars")).Delete([]byte(id)); err != nil {
			return err
		}
		return tx.Bucket([]byte("calendars")).Delete([]byte(id))
	})
	if err != nil {
		serveError(w, err)
		return
	}
	w.WriteHeader(204)
}
