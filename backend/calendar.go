package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"path"
	"strings"
	"time"

	"github.com/emersion/go-ical"
	"github.com/emersion/go-webdav"
	"github.com/emersion/go-webdav/caldav"
	bolt "go.etcd.io/bbolt"
)

type davBackend struct{ store *Store }

func davError(code int, message string) error {
	return webdav.NewHTTPError(code, &reportFailure{Code: code, Message: message})
}
func davPrecondition(code int, condition, message string) error {
	return webdav.NewHTTPError(code, &reportFailure{Code: code, Condition: condition, Message: message})
}

type putResultKey struct{}
type putResult struct{ Existing bool }

func principal(ctx context.Context) string    { return "/dav/" + currentUser(ctx) + "/" }
func calendarPath(ctx context.Context) string { return principal(ctx) + "calendars/default/" }
func (b *davBackend) CurrentUserPrincipal(ctx context.Context) (string, error) {
	return principal(ctx), nil
}
func (b *davBackend) CalendarHomeSetPath(ctx context.Context) (string, error) {
	return principal(ctx) + "calendars/", nil
}
func (b *davBackend) CreateCalendar(ctx context.Context, c *caldav.Calendar) error {
	return davError(403, "This version provides one default calendar per user")
}
func (b *davBackend) GetCalendar(ctx context.Context, p string) (*caldav.Calendar, error) {
	if p != calendarPath(ctx) {
		return nil, davError(404, "Calendar not found")
	}
	return &caldav.Calendar{Path: p, Name: "Spacetime", Description: "Events, todos, and occasions", MaxResourceSize: 1024 * 1024, SupportedComponentSet: []string{ical.CompEvent, ical.CompToDo}}, nil
}
func (b *davBackend) ListCalendars(ctx context.Context) ([]caldav.Calendar, error) {
	c, _ := b.GetCalendar(ctx, calendarPath(ctx))
	return []caldav.Calendar{*c}, nil
}
func objectName(ctx context.Context, p string) (string, error) {
	base := calendarPath(ctx)
	if !strings.HasPrefix(p, base) {
		return "", davError(404, "Resource not found")
	}
	name := strings.TrimPrefix(p, base)
	if name == "" || strings.Contains(name, "/") || name == "." || name == ".." || !strings.HasSuffix(name, ".ics") || len(name) > 200 {
		return "", davError(400, "Expected an .ics resource in your calendar")
	}
	return name, nil
}
func findResource(tx *bolt.Tx, owner, resource string) (Event, error) {
	events, err := eventsTx(tx)
	if err != nil {
		return Event{}, err
	}
	for _, e := range events {
		if e.Owner == owner && e.Resource == resource {
			return e, nil
		}
	}
	return Event{}, errNotFound
}
func calendarObject(ctx context.Context, e Event) (*caldav.CalendarObject, error) {
	cal, err := ical.NewDecoder(strings.NewReader(e.Raw)).Decode()
	if err != nil {
		return nil, err
	}
	h := sha256.Sum256([]byte(e.Raw))
	if e.Owner != currentUser(ctx) {
		e.Resource = "invited-" + e.ID + ".ics"
	}
	return &caldav.CalendarObject{Path: calendarPath(ctx) + e.Resource, ModTime: e.Updated, ContentLength: int64(len(e.Raw)), ETag: hex.EncodeToString(h[:]), Data: cal}, nil
}
func (b *davBackend) GetCalendarObject(ctx context.Context, p string, req *caldav.CalendarCompRequest) (*caldav.CalendarObject, error) {
	name, err := objectName(ctx, p)
	if err != nil {
		return nil, err
	}
	var e Event
	err = b.store.db.View(func(tx *bolt.Tx) error {
		var err error
		e, err = findResource(tx, currentUser(ctx), name)
		if err == errNotFound && strings.HasPrefix(name, "invited-") {
			e, err = eventTx(tx, strings.TrimSuffix(strings.TrimPrefix(name, "invited-"), ".ics"))
			if err == nil && (e.Owner == currentUser(ctx) || e.Attendees[currentUser(ctx)] != "accepted") {
				return errNotFound
			}
		}
		return err
	})
	if err == errNotFound {
		return nil, davError(404, "Resource not found")
	}
	if err != nil {
		return nil, err
	}
	return calendarObject(ctx, e)
}
func (b *davBackend) ListCalendarObjects(ctx context.Context, p string, req *caldav.CalendarCompRequest) ([]caldav.CalendarObject, error) {
	if _, err := b.GetCalendar(ctx, p); err != nil {
		return nil, err
	}
	result := []caldav.CalendarObject{}
	err := b.store.db.View(func(tx *bolt.Tx) error {
		events, err := eventsTx(tx)
		if err != nil {
			return err
		}
		for _, e := range events {
			if visible(e, currentUser(ctx)) {
				co, err := calendarObject(ctx, e)
				if err != nil {
					return err
				}
				result = append(result, *co)
			}
		}
		return nil
	})
	return result, err
}
func (b *davBackend) QueryCalendarObjects(ctx context.Context, p string, query *caldav.CalendarQuery) ([]caldav.CalendarObject, error) {
	if query == nil {
		return b.ListCalendarObjects(ctx, p, nil)
	}
	objects, err := b.ListCalendarObjects(ctx, p, &query.CompRequest)
	if err != nil {
		return nil, err
	}
	if query == nil {
		return objects, nil
	}
	result := []caldav.CalendarObject{}
	ctx = context.WithValue(ctx, caldavRangeKey{}, true)
	for _, co := range objects {
		ok, err := matchCalendar(ctx, co.Data, componentFilterNode(query.CompFilter), utcZone())
		if err != nil {
			return nil, err
		}
		if ok {
			result = append(result, co)
		}
	}
	return result, nil
}
func checkMatch(e *Event, match, none webdav.ConditionalMatch) error {
	etag := ""
	if e != nil {
		h := sha256.Sum256([]byte(e.Raw))
		etag = hex.EncodeToString(h[:])
	}
	return checkMatchETag(etag, match, none)
}
func (b *davBackend) PutCalendarObject(ctx context.Context, p string, cal *ical.Calendar, opts *caldav.PutCalendarObjectOptions) (*caldav.CalendarObject, error) {
	name, err := objectName(ctx, p)
	if err != nil {
		return nil, err
	}
	if strings.HasPrefix(name, "invited-") {
		return nil, davError(403, "Invited plans are read-only; RSVP in Spacetime")
	}
	e, err := decodeEvent(cal)
	if err != nil {
		return nil, davPrecondition(403, "valid-calendar-data", err.Error())
	}
	err = b.store.db.Update(func(tx *bolt.Tx) error {
		old, lookup := findResource(tx, currentUser(ctx), name)
		if lookup != nil && lookup != errNotFound {
			return lookup
		}
		var existing *Event
		if lookup == nil {
			existing = &old
		}
		if result, ok := ctx.Value(putResultKey{}).(*putResult); ok {
			result.Existing = lookup == nil
		}
		if err := checkMatch(existing, opts.IfMatch, opts.IfNoneMatch); err != nil {
			return err
		}
		// RFC 4791: the same UID may not exist in two resources in a collection.
		_, uid, _ := caldav.ValidateCalendarObject(cal)
		events, err := eventsTx(tx)
		if err != nil {
			return err
		}
		for _, other := range events {
			if other.Owner != currentUser(ctx) || other.Resource == name {
				continue
			}
			co, err := calendarObject(ctx, other)
			if err != nil {
				return err
			}
			_, otherUID, _ := caldav.ValidateCalendarObject(co.Data)
			if uid == otherUID {
				return webdav.NewHTTPError(403, &reportFailure{Code: 403, Condition: "no-uid-conflict", Message: "UID already exists in this calendar", Href: calendarPath(ctx) + other.Resource})
			}
		}
		e.ID = old.ID
		if e.ID == "" {
			e.ID = randomID()
		}
		e.Owner, e.Resource, e.Updated, e.Version = currentUser(ctx), name, time.Now().UTC(), old.Version+1
		// CalDAV storage does not implement scheduling. Existing app invitations remain authoritative.
		if old.Attendees != nil {
			e.Attendees = old.Attendees
		}
		return saveEvent(tx, e)
	})
	if err != nil {
		return nil, err
	}
	return calendarObject(ctx, e)
}

type davHeadersKey struct{}
type davHeaders struct{ Match, None webdav.ConditionalMatch }

func (b *davBackend) DeleteCalendarObject(ctx context.Context, p string) error {
	name, err := objectName(ctx, path.Clean(p))
	if err != nil {
		return err
	}
	if strings.HasPrefix(name, "invited-") {
		return davError(403, "Invited plans are read-only; RSVP in Spacetime")
	}
	return b.store.db.Update(func(tx *bolt.Tx) error {
		e, err := findResource(tx, currentUser(ctx), name)
		if err == errNotFound {
			return davError(404, "Resource not found")
		}
		if err != nil {
			return err
		}
		h, _ := ctx.Value(davHeadersKey{}).(davHeaders)
		if err := checkMatch(&e, h.Match, h.None); err != nil {
			return err
		}
		return tx.Bucket([]byte("events")).Delete([]byte(e.ID))
	})
}

var _ caldav.Backend = (*davBackend)(nil)

func matchHTTPETags(raw, etag string, weak bool) (bool, error) {
	raw = strings.TrimSpace(raw)
	if raw == "*" {
		return etag != "", nil
	}
	matched := false
	for len(raw) > 0 {
		isWeak := false
		if strings.HasPrefix(raw, "W/") {
			isWeak = true
			raw = raw[2:]
		}
		if !strings.HasPrefix(raw, `"`) {
			return false, fmt.Errorf("malformed entity tag")
		}
		end := strings.Index(raw[1:], `"`)
		if end < 0 {
			return false, fmt.Errorf("malformed entity tag")
		}
		value := raw[1 : 1+end]
		if etag != "" && value == etag && (weak || !isWeak) {
			matched = true
		}
		raw = strings.TrimSpace(raw[end+2:])
		if raw == "" {
			break
		}
		if raw[0] != ',' {
			return false, fmt.Errorf("malformed entity-tag list")
		}
		raw = strings.TrimSpace(raw[1:])
		if raw == "" {
			return false, fmt.Errorf("malformed entity-tag list")
		}
	}
	return matched, nil
}
func checkMatchETag(etag string, match, none webdav.ConditionalMatch) error {
	if match.IsSet() {
		ok, err := matchHTTPETags(string(match), etag, false)
		if err != nil {
			return davError(400, err.Error())
		}
		if !ok {
			return davError(412, "Resource changed; refresh its ETag")
		}
	}
	if none.IsSet() {
		ok, err := matchHTTPETags(string(none), etag, true)
		if err != nil {
			return davError(400, err.Error())
		}
		if ok {
			return davError(412, "Resource changed; refresh its ETag")
		}
	}
	return nil
}
