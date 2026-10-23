package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/emersion/go-ical"
	"github.com/teambition/rrule-go"
	bolt "go.etcd.io/bbolt"
)

type apiError struct {
	Code    int
	Message string
}

func (e *apiError) Error() string                { return e.Message }
func statusError(code int, message string) error { return &apiError{code, message} }
func fail(w http.ResponseWriter, code int, message string) {
	writeJSON(w, code, map[string]string{"error": message})
}
func writeJSON(w http.ResponseWriter, code int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(value)
}
func serveError(w http.ResponseWriter, err error) {
	var ae *apiError
	if errors.As(err, &ae) {
		fail(w, ae.Code, ae.Message)
	} else if errors.Is(err, errNotFound) {
		fail(w, 404, "Entry not found.")
	} else {
		log.Printf("request: %v", err)
		fail(w, 500, "Something went wrong. Please try again.")
	}
}
func validateEvent(e *Event) error {
	if e.Kind == "birthday" {
		if e.RRule == "" {
			e.Yearly = true
		}
		e.Kind = "occasion"
	} else if e.Kind == "holiday" {
		e.Kind = "occasion"
	}
	if special(*e) {
		e.AllDay = true
	}
	if err := normalizeLocalDates(e); err != nil {
		return statusError(400, err.Error())
	}
	e.Title = strings.TrimSpace(e.Title)
	if e.Title == "" || len(e.Title) > 200 || len(e.Description) > 10000 || len(e.Location) > 500 {
		return statusError(400, "Add a title of up to 200 characters. Keep notes under 10,000 characters.")
	}
	switch e.Kind {
	case "event", "occasion":
		if e.Start == nil || e.End == nil || !e.End.After(*e.Start) {
			return statusError(400, "End must be after start.")
		}
		e.Due = nil
		e.Completed = false
		if special(*e) {
			e.AllDay = true
		}
	case "todo":
		if e.Due == nil {
			return statusError(400, "Todos need a due date.")
		}
		e.End = nil
		if e.RRule == "" {
			e.Start = nil
		} else if e.Start == nil || !e.Due.After(*e.Start) {
			return statusError(400, "A recurring todo needs a start before its due date.")
		}
	default:
		return statusError(400, "Choose event, todo, or occasion.")
	}
	if e.AllDay {
		for _, t := range []*time.Time{e.Start, e.End, e.Due} {
			if t != nil {
				*t = time.Date(t.Year(), t.Month(), t.Day(), 0, 0, 0, 0, time.UTC)
			}
		}
		if e.Start != nil && e.End != nil && !e.End.After(*e.Start) {
			return statusError(400, "All-day end date is exclusive and must be after start date.")
		}
	}
	if special(*e) && (e.Location != "" || len(e.Attendees) != 0) {
		return statusError(400, "Occasions cannot have locations or invitees.")
	}
	if e.Timezone == "" {
		e.Timezone = "UTC"
	}
	if e.RRule == "" && e.Yearly {
		e.RRule = "FREQ=YEARLY"
	}
	e.RRule = strings.ToUpper(strings.TrimSpace(e.RRule))
	e.Yearly = e.RRule == "FREQ=YEARLY"
	if e.RRule != "" {
		if e.Start == nil {
			return statusError(400, "Recurring todos require a start before their due date.")
		}
		d, err := eventStamp(*e, *e.Start)
		if err != nil {
			return statusError(400, err.Error())
		}
		spec, err := parseRule(e.RRule, d)
		if err != nil {
			return statusError(400, err.Error())
		}
		if spec.Until != nil && spec.Until.instant().Before(d.instant()) {
			return statusError(400, "The recurrence end must be on or after its first occurrence.")
		}
		opt := spec.Option
		opt.Until = time.Date(9999, 12, 31, 23, 59, 59, 0, time.UTC)
		rule, _ := rrule.NewRRule(opt)
		first, ok := rule.Iterator()()
		if !ok || !first.Equal(d.Wall) {
			return statusError(400, "The start date must match the selected repeat days or monthly pattern.")
		}
	}
	if len(e.Attendees) > 50 {
		return statusError(400, "Invite up to 50 people per entry.")
	}
	return nil
}
func (a *App) listEvents(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == "/api/events" {
		if err := a.syncSources(r.Context()); err != nil {
			serveError(w, err)
			return
		}
	}
	username := currentUser(r.Context())
	result := []Event{}
	err := a.store.db.View(func(tx *bolt.Tx) error {
		events, err := eventsTx(tx)
		if err != nil {
			return err
		}
		for _, e := range events {
			if r.URL.Path == "/api/invitations" {
				if !accessFor(r.Context()).SharedIDs[eventCalendar(e)] && e.Attendees[username] == "pending" {
					result = append(result, e)
				}
			} else if eventVisible(r.Context(), e) {
				result = append(result, e)
			}
		}
		return nil
	})
	if err != nil {
		serveError(w, err)
		return
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Updated.After(result[j].Updated) })
	projected := make([]map[string]any, 0, len(result))
	for _, event := range result {
		encoded, err := json.Marshal(event)
		if err != nil {
			serveError(w, err)
			return
		}
		var value map[string]any
		if err := json.Unmarshal(encoded, &value); err != nil {
			serveError(w, err)
			return
		}
		value["calendar_data"] = event.Raw
		projected = append(projected, value)
	}
	writeJSON(w, 200, projected)
}
func (a *App) putEvent(w http.ResponseWriter, r *http.Request) {
	var e Event
	if !decode(w, r, &e) {
		return
	}
	username := currentUser(r.Context())
	creating := r.Method == "POST"
	if e.CalendarID == "" {
		e.CalendarID = defaultCalendarID(username)
	}
	if !calendarWritable(r.Context(), e.CalendarID) {
		fail(w, 403, "This calendar is read-only or no longer accessible.")
		return
	}
	if accessFor(r.Context()).Calendars[e.CalendarID].Kind == "source" {
		if err := a.pullSource(r.Context(), e.CalendarID); err != nil {
			serveError(w, err)
			return
		}
	}
	if accessFor(r.Context()).Calendars[e.CalendarID].Kind != "personal" && len(e.Attendees) > 0 {
		fail(w, 400, "Use group membership for shared calendars and the source's invitation tools for connected calendars.")
		return
	}
	err := a.store.db.Update(func(tx *bolt.Tx) error {
		var old Event
		if creating && e.UID != "" {
			if len(e.UID) > 1000 || strings.ContainsAny(e.UID, "\r\n") {
				return statusError(400, "Invalid calendar UID.")
			}
			existing, err := eventsTx(tx)
			if err != nil {
				return err
			}
			for _, previous := range existing {
				if eventCalendar(previous) == e.CalendarID && previous.UID == e.UID {
					if previous.Owner != username {
						return statusError(409, "This UID already exists in the calendar.")
					}
					e = previous
					return nil
				}
			}
		}
		if !creating {
			var err error
			old, err = eventTx(tx, r.PathValue("id"))
			if err != nil {
				return err
			}
			if !canMutateEvent(r.Context(), old) {
				return statusError(403, "Only the organizer can edit this entry.")
			}
			if e.Version != old.Version {
				return statusError(409, "This entry changed. Refresh before editing it again.")
			}
			if old.CalendarID != e.CalendarID {
				if accessFor(r.Context()).Calendars[old.CalendarID].Kind == "source" || accessFor(r.Context()).Calendars[e.CalendarID].Kind == "source" {
					return statusError(409, "Copy this entry to the destination calendar, then remove the original.")
				}
				all, err := eventsTx(tx)
				if err != nil {
					return err
				}
				for _, other := range all {
					if other.ID != old.ID && other.CalendarID == e.CalendarID && other.UID == old.UID {
						return statusError(409, "The destination already contains this UID.")
					}
				}
			}
			e.ID, e.Resource, e.Version = old.ID, old.Resource, old.Version+1
			e.Raw, e.UID = old.Raw, old.UID
		} else {
			e.ID = randomID()
			e.Resource = e.ID + ".ics"
			e.Version = 1
			if e.UID == "" {
				e.UID = e.ID + "@spacetime"
			}
		}
		if old.Raw != "" && ((old.Kind == "todo") != (e.Kind == "todo") || old.AllDay != e.AllDay) {
			cal, err := ical.NewDecoder(strings.NewReader(old.Raw)).Decode()
			if err != nil {
				return err
			}
			for _, c := range cal.Children {
				if c.Props.Get(ical.PropRecurrenceID) != nil {
					return statusError(409, "This series has individual exceptions. Its event/todo or date/time type cannot be changed without resolving those exceptions.")
				}
			}
		}
		if err := validateEvent(&e); err != nil {
			return err
		}
		e.Owner, e.Updated, e.Imported = username, time.Now().UTC(), old.Imported
		if e.UID == "" {
			if e.Raw != "" {
				cal, err := ical.NewDecoder(strings.NewReader(e.Raw)).Decode()
				if err != nil {
					return err
				}
				e.UID = text(masterComponent(cal), ical.PropUID)
			} else {
				e.UID = e.ID + "@spacetime"
			}
		}
		attendees := map[string]string{}
		for name := range e.Attendees {
			name = strings.ToLower(strings.TrimSpace(name))
			if name == username || name == "" {
				continue
			}
			if _, err := userTx(tx, name); err != nil {
				return statusError(400, fmt.Sprintf("@%s does not have an account yet.", name))
			}
			status := old.Attendees[name]
			if status == "" {
				status = "pending"
			}
			attendees[name] = status
		}
		e.Attendees = attendees
		var err error
		e.Raw, err = encodeEvent(e)
		if err != nil {
			return err
		}
		return saveCalendarEvent(r.Context(), tx, &e)
	})
	if err != nil {
		serveError(w, err)
		return
	}
	code := 200
	if creating {
		code = 201
	}
	writeJSON(w, code, e)
}
func (a *App) deleteEvent(w http.ResponseWriter, r *http.Request) {
	if err := a.prepareSourceEntry(r.Context(), r.PathValue("id")); err != nil {
		serveError(w, err)
		return
	}
	err := a.store.db.Update(func(tx *bolt.Tx) error {
		e, err := eventTx(tx, r.PathValue("id"))
		if err != nil {
			return err
		}
		if !canMutateEvent(r.Context(), e) {
			return statusError(403, "Only the organizer can delete this entry.")
		}
		if r.Header.Get("If-Match") != fmt.Sprintf(`"%d"`, e.Version) {
			return statusError(409, "This entry changed. Refresh before deleting it.")
		}
		return deleteCalendarEvent(r.Context(), tx, e)
	})
	if err != nil {
		serveError(w, err)
		return
	}
	w.WriteHeader(204)
}
func (a *App) respond(w http.ResponseWriter, r *http.Request) {
	var body struct{ Status string }
	if !decode(w, r, &body) {
		return
	}
	if body.Status != "accepted" && body.Status != "declined" {
		fail(w, 400, "Choose accepted or declined.")
		return
	}
	err := a.store.db.Update(func(tx *bolt.Tx) error {
		e, err := eventTx(tx, r.PathValue("id"))
		if err != nil {
			return err
		}
		name := currentUser(r.Context())
		if e.Attendees[name] == "" {
			return statusError(404, "Invitation not found.")
		}
		e.Attendees[name] = body.Status
		e.Version++
		e.Updated = time.Now().UTC()
		e.Raw, err = encodeRSVP(e)
		if err != nil {
			return err
		}
		return saveEvent(tx, e)
	})
	if err != nil {
		serveError(w, err)
		return
	}
	w.WriteHeader(204)
}
