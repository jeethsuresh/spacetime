package main

import (
	"context"
	"fmt"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/emersion/go-ical"
	"github.com/teambition/rrule-go"
	bolt "go.etcd.io/bbolt"
)

type occurrence struct {
	Event
	RecurrenceID string `json:"recurrence_id"`
	Series       Event  `json:"series"`
}

func occurrenceProjection(e Event, i instance) occurrence {
	o := e
	if title := text(i.Component, ical.PropSummary); title != "" {
		o.Title = title
	}
	o.Description = text(i.Component, ical.PropDescription)
	o.Location = text(i.Component, ical.PropLocation)
	if special(e) {
		o.Location = ""
		o.Attendees = map[string]string{}
	}
	o.Completed = text(i.Component, ical.PropStatus) == "COMPLETED"
	o.Start = nil
	o.End = nil
	o.Due = nil
	if !i.Start.Wall.IsZero() {
		v := i.Start.output()
		o.Start = &v
		o.LocalStart = i.Start.Wall.Format("2006-01-02T15:04:05")
	}
	if i.End != nil {
		v := i.End.output()
		o.End = &v
		o.LocalEnd = i.End.Wall.Format("2006-01-02T15:04:05")
	}
	if i.Due != nil {
		v := i.Due.output()
		o.Due = &v
		o.LocalDue = i.Due.Wall.Format("2006-01-02T15:04:05")
	}
	if e.Kind == "todo" && i.Component.Props.Get("DTSTART") == nil {
		o.Start = nil
	}
	return occurrence{o, i.RID.key(), e}
}
func (a *App) occurrences(w http.ResponseWriter, r *http.Request) {
	from, err := time.Parse(time.RFC3339, r.URL.Query().Get("from"))
	if err != nil {
		fail(w, 400, "from must be an RFC 3339 timestamp.")
		return
	}
	to, err := time.Parse(time.RFC3339, r.URL.Query().Get("to"))
	if err != nil || !to.After(from) || to.After(from.AddDate(10, 0, 0)) {
		fail(w, 400, "Request a nonempty occurrence range of at most 10 years.")
		return
	}
	zone, err := ianaZone(envQuery(r, "timezone", "UTC"))
	if err != nil {
		fail(w, 400, err.Error())
		return
	}
	events := []Event{}
	err = a.store.db.View(func(tx *bolt.Tx) error {
		all, err := eventsTx(tx)
		if err != nil {
			return err
		}
		for _, e := range all {
			if eventVisible(r.Context(), e) {
				events = append(events, e)
			}
		}
		return nil
	})
	if err != nil {
		serveError(w, err)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	result := []occurrence{}
	for _, e := range events {
		cal, err := ical.NewDecoder(strings.NewReader(e.Raw)).Decode()
		if err != nil {
			serveError(w, err)
			return
		}
		instances, err := expandCalendar(ctx, cal, from, to, zone)
		if err != nil {
			fail(w, 422, fmt.Sprintf("Cannot expand %q: %v", e.Title, err))
			return
		}
		for _, i := range instances {
			result = append(result, occurrenceProjection(e, i))
			if len(result) > maxInstances {
				fail(w, 422, "Too many occurrences. Narrow the requested time range.")
				return
			}
		}
	}
	sort.Slice(result, func(i, j int) bool { return eventWhen(result[i].Event).Before(eventWhen(result[j].Event)) })
	writeJSON(w, 200, result)
}
func eventWhen(e Event) time.Time {
	if e.Due != nil {
		return *e.Due
	}
	if e.Start != nil {
		return *e.Start
	}
	return time.Time{}
}
func envQuery(r *http.Request, key, fallback string) string {
	if s := r.URL.Query().Get(key); s != "" {
		return s
	}
	return fallback
}
func (a *App) previewRecurrence(w http.ResponseWriter, r *http.Request) {
	var e Event
	if !decode(w, r, &e) {
		return
	}
	if e.ID != "" {
		old, err := func() (Event, error) {
			var value Event
			err := a.store.db.View(func(tx *bolt.Tx) error { var err error; value, err = eventTx(tx, e.ID); return err })
			return value, err
		}()
		if err != nil {
			serveError(w, err)
			return
		}
		if !canMutateEvent(r.Context(), old) {
			fail(w, 403, "Only the organizer can preview changes to this series.")
			return
		}
		e.Raw = old.Raw
		e.UID = old.UID
	}
	if err := validateEvent(&e); err != nil {
		serveError(w, err)
		return
	}
	e.ID = "preview"
	e.Owner = currentUser(r.Context())
	e.Updated = time.Now().UTC()
	var err error
	e.Raw, err = encodeEvent(e)
	if err != nil {
		fail(w, 400, err.Error())
		return
	}
	cal, err := ical.NewDecoder(strings.NewReader(e.Raw)).Decode()
	if err != nil {
		serveError(w, err)
		return
	}
	from := eventWhen(e).AddDate(0, 0, -1)
	to := from.AddDate(2, 0, 0)
	if e.Start != nil && e.RRule != "" {
		d, err := eventStamp(e, *e.Start)
		if err != nil {
			fail(w, 400, err.Error())
			return
		}
		spec, err := parseRule(e.RRule, d)
		if err != nil {
			fail(w, 400, err.Error())
			return
		}
		interval := spec.Option.Interval
		if interval == 0 {
			interval = 1
		}
		n := interval * 9
		switch spec.Option.Freq {
		case rrule.YEARLY:
			to = from.AddDate(n, 0, 1)
		case rrule.MONTHLY:
			to = from.AddDate(0, n, 7)
		case rrule.WEEKLY:
			to = from.AddDate(0, 0, n*7+7)
		case rrule.DAILY:
			to = from.AddDate(0, 0, n+7)
		default:
			seconds := int64(n)
			if spec.Option.Freq == rrule.HOURLY {
				seconds *= 3600
			}
			if spec.Option.Freq == rrule.MINUTELY {
				seconds *= 60
			}
			to = time.Unix(from.Unix()+seconds+86400, 0).UTC()
		}
		if to.Year() > 9999 {
			to = time.Date(9999, 12, 31, 23, 59, 59, 0, time.UTC)
		}
	}

	zone, err := ianaZone(envQuery(r, "timezone", "UTC"))
	if err != nil {
		fail(w, 400, err.Error())
		return
	}
	items, err := expandCalendar(r.Context(), cal, from, to, zone)
	if err != nil {
		fail(w, 400, err.Error())
		return
	}
	result := []occurrence{}
	for _, i := range items {
		result = append(result, occurrenceProjection(e, i))
		if len(result) == 8 {
			break
		}
	}
	writeJSON(w, 200, result)
}
func (a *App) exception(w http.ResponseWriter, r *http.Request) {
	if err := a.prepareSourceEntry(r.Context(), r.PathValue("id")); err != nil {
		serveError(w, err)
		return
	}
	var body struct {
		RecurrenceID string `json:"recurrence_id"`
		Operation    string `json:"operation"`
		Completed    bool   `json:"completed"`
		Version      int    `json:"version"`
	}
	if !decode(w, r, &body) {
		return
	}
	if body.Operation != "skip" && body.Operation != "complete" {
		fail(w, 400, "Choose skip or complete.")
		return
	}
	err := a.store.db.Update(func(tx *bolt.Tx) error {
		e, err := eventTx(tx, r.PathValue("id"))
		if err != nil {
			return err
		}
		if !canMutateEvent(r.Context(), e) {
			return statusError(403, "Only the organizer can change an occurrence.")
		}
		if e.Version != body.Version {
			return statusError(409, "This series changed. Refresh and try again.")
		}
		cal, err := ical.NewDecoder(strings.NewReader(e.Raw)).Decode()
		if err != nil {
			return err
		}
		master := masterComponent(cal)
		if master == nil {
			return statusError(400, "A series master is required.")
		}
		year := calendarYear(cal)
		if len(body.RecurrenceID) >= 4 {
			n, _ := strconv.Atoi(body.RecurrenceID[:4])
			if n > year {
				year = n
			}
		}
		zones, err := calendarZones(cal, 1900, year+2)
		if err != nil {
			return err
		}
		start, _, _, err := componentDates(master, zones, utcZone())
		if err != nil {
			return err
		}
		p := ical.NewProp(ical.PropRecurrenceID)
		p.Value = body.RecurrenceID
		if len(p.Value) == 8 {
			p.SetValueType(ical.ValueDate)
		}
		rid, err := parseStamp(p, zones, start.Zone)
		if err != nil {
			return statusError(400, "Invalid recurrence identifier.")
		}
		if start.Date != rid.Date {
			return statusError(400, "Recurrence identifier type must match DTSTART.")
		}
		// Validate membership against the same engine used by Flutter and CalDAV.
		t := rid.instant()
		var selected *instance
		// Use an explicitly moved instance's current position for membership lookup.
		for _, c := range cal.Children {
			if p := c.Props.Get(ical.PropRecurrenceID); p != nil {
				key, err := parseStamp(p, zones, start.Zone)
				if err != nil {
					return err
				}
				if key.key() == rid.key() {
					s, en, due, err := componentDates(c, zones, start.Zone)
					if err != nil {
						return err
					}
					i := instance{c, s, en, due, key, true}
					selected = &i
					break
				}
				if p.Params.Get("RANGE") == "THISANDFUTURE" && !rid.instant().Before(key.instant()) {
					s, _, _, err := componentDates(c, zones, start.Zone)
					if err != nil {
						return err
					}
					adjusted := rid.at(time.Unix(rid.Wall.Unix()+s.Wall.Unix()-key.Wall.Unix(), 0).UTC())
					t = adjusted.instant()
				}
			}
		}
		if selected == nil {
			items, err := expandCalendar(r.Context(), cal, t.AddDate(0, 0, -2), t.AddDate(0, 0, 3), start.Zone)
			if err != nil {
				return err
			}
			for i := range items {
				if items[i].RID.key() == rid.key() {
					selected = &items[i]
					break
				}
			}
		}
		if selected == nil {
			return statusError(404, "Occurrence not found.")
		}
		if body.Operation == "skip" {
			master.Props.Add(selected.RID.prop(ical.PropExceptionDates))
			filtered := cal.Children[:0]
			for _, c := range cal.Children {
				if p := c.Props.Get(ical.PropRecurrenceID); p != nil {
					v, err := parseStamp(p, zones, start.Zone)
					if err != nil {
						return err
					}
					if v.key() == rid.key() && p.Params.Get("RANGE") != "THISANDFUTURE" {
						continue
					}
				}
				filtered = append(filtered, c)
			}
			cal.Children = filtered
		} else {
			if e.Kind != "todo" {
				return statusError(400, "Only todos can be completed.")
			}
			var continuation *ical.Component
			if p := selected.Component.Props.Get(ical.PropRecurrenceID); p != nil && p.Params.Get("RANGE") == "THISANDFUTURE" {
				originalRID, err := parseStamp(p, zones, start.Zone)
				if err != nil {
					return err
				}
				if originalRID.key() == rid.key() {
					next, err := nextRecurrenceID(r.Context(), master, start, rid, zones)
					if err != nil {
						return err
					}
					if next != nil {
						continuation = cloneComponent(selected.Component)
						q := next.prop(ical.PropRecurrenceID)
						q.Params.Set("RANGE", "THISANDFUTURE")
						continuation.Props.Set(q)
						s := next.at(time.Unix(next.Wall.Unix()+selected.Start.Wall.Unix()-rid.Wall.Unix(), 0).UTC())
						continuation.Props.Set(s.prop(ical.PropDateTimeStart))
						if selected.Due != nil {
							due := shiftEnd(selected.Start, selected.Due, s, selected.Component)
							continuation.Props.Set(due.prop(ical.PropDue))
						}
					}
				}
			}
			c := cloneComponent(selected.Component)
			for _, name := range []string{"RRULE", "RDATE", "EXDATE", "DURATION"} {
				c.Props.Del(name)
			}
			c.Props.Set(selected.RID.prop(ical.PropRecurrenceID))
			c.Props.Set(selected.Start.prop(ical.PropDateTimeStart))
			if selected.Due != nil {
				c.Props.Set(selected.Due.prop(ical.PropDue))
			}
			status := "NEEDS-ACTION"
			if body.Completed {
				status = "COMPLETED"
				c.Props.SetDateTime(ical.PropCompleted, time.Now().UTC())
			} else {
				c.Props.Del(ical.PropCompleted)
			}
			c.Props.SetText(ical.PropStatus, status)
			filtered := []*ical.Component{}
			for _, old := range cal.Children {
				if p := old.Props.Get(ical.PropRecurrenceID); p != nil {
					v, err := parseStamp(p, zones, start.Zone)
					if err != nil {
						return err
					}
					if v.key() == rid.key() {
						continue
					}
				}
				filtered = append(filtered, old)
			}
			cal.Children = append(filtered, c)
			if continuation != nil {
				cal.Children = append(cal.Children, continuation)
			}
		}
		e.Version++
		e.Updated = time.Now().UTC()
		master.Props.SetDateTime(ical.PropDateTimeStamp, e.Updated)
		master.Props.SetDateTime(ical.PropLastModified, e.Updated)
		seq := ical.NewProp(ical.PropSequence)
		seq.Value = fmt.Sprint(nextSequence(master, e.Version))
		master.Props.Set(seq)
		e.Raw, err = calendarString(cal)
		if err != nil {
			return err
		}
		projected, err := projectCalendar(cal)
		if err != nil {
			return err
		}
		e.ExDates = projected.ExDates
		return saveCalendarEvent(r.Context(), tx, &e)
	})
	if err != nil {
		serveError(w, err)
		return
	}
	w.WriteHeader(204)
}

func (a *App) completeTodo(w http.ResponseWriter, r *http.Request) {
	if err := a.prepareSourceEntry(r.Context(), r.PathValue("id")); err != nil {
		serveError(w, err)
		return
	}
	var body struct {
		Completed bool `json:"completed"`
		Version   int  `json:"version"`
	}
	if !decode(w, r, &body) {
		return
	}
	err := a.store.db.Update(func(tx *bolt.Tx) error {
		e, err := eventTx(tx, r.PathValue("id"))
		if err != nil {
			return err
		}
		if !canMutateEvent(r.Context(), e) {
			return statusError(403, "Only the organizer can change this todo.")
		}
		if e.Kind != "todo" {
			return statusError(400, "Only todos can be completed.")
		}
		if e.Version != body.Version {
			return statusError(409, "This todo changed. Refresh and try again.")
		}
		if e.RRule != "" || len(e.RDates) > 0 {
			return statusError(400, "Complete an individual occurrence of a repeating todo.")
		}
		cal, err := ical.NewDecoder(strings.NewReader(e.Raw)).Decode()
		if err != nil {
			return err
		}
		c := masterComponent(cal)
		if c == nil {
			return statusError(400, "A todo master is required.")
		}
		status := "NEEDS-ACTION"
		if body.Completed {
			status = "COMPLETED"
			c.Props.SetDateTime("COMPLETED", time.Now().UTC())
		} else {
			c.Props.Del("COMPLETED")
		}
		c.Props.SetText("STATUS", status)
		e.Completed = body.Completed
		e.Version++
		e.Updated = time.Now().UTC()
		c.Props.SetDateTime("DTSTAMP", e.Updated)
		c.Props.SetDateTime("LAST-MODIFIED", e.Updated)
		p := ical.NewProp("SEQUENCE")
		p.Value = fmt.Sprint(nextSequence(c, e.Version))
		c.Props.Set(p)
		e.Raw, err = calendarString(cal)
		if err != nil {
			return err
		}
		return saveCalendarEvent(r.Context(), tx, &e)
	})
	if err != nil {
		serveError(w, err)
		return
	}
	w.WriteHeader(204)
}
