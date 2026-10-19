package main

import (
	"bytes"
	"fmt"
	"reflect"
	"strconv"
	"strings"
	"time"

	"github.com/emersion/go-ical"
	"github.com/emersion/go-webdav/caldav"
)

func special(e Event) bool {
	return e.Kind == "occasion" || e.Kind == "birthday" || e.Kind == "holiday"
}
func calendarString(cal *ical.Calendar) (string, error) {
	var b bytes.Buffer
	err := ical.NewEncoder(&b).Encode(cal)
	return b.String(), err
}
func eventStamp(e Event, t time.Time) (stamp, error) {
	d := stamp{Wall: civil(t), Zone: utcZone(), Date: e.AllDay, Floating: e.Timezone == "floating"}
	if e.AllDay {
		d.Wall = civilDay(t)
		return d, nil
	}
	if e.Timezone != "" && e.Timezone != "UTC" && e.Timezone != "floating" {
		z, err := eventZone(e)
		if err != nil {
			return d, err
		}
		d.Zone = z
		d.Wall = z.wall(t)
	}
	return d, nil
}
func setEventDate(c *ical.Component, e Event, name string, t *time.Time) error {
	c.Props.Del(name)
	if t == nil {
		return nil
	}
	d, err := eventStamp(e, *t)
	if err != nil {
		return err
	}
	c.Props.Set(d.prop(name))
	return nil
}
func listDateProperty(c *ical.Component, e Event, name string, values []string) error {
	c.Props.Del(name)
	for _, v := range values {
		var t time.Time
		var err error
		if e.AllDay {
			t, err = time.Parse("2006-01-02", v)
		} else if e.Timezone == "floating" {
			t, err = time.Parse("2006-01-02T15:04:05", strings.TrimSuffix(v, "Z"))
		} else {
			t, err = time.Parse(time.RFC3339, v)
		}
		if err != nil && !e.AllDay && e.Timezone != "floating" {
			if wall, parseErr := time.Parse("2006-01-02T15:04:05", v); parseErr == nil {
				z, zerr := eventZone(e)
				if zerr != nil {
					return zerr
				}
				t, _ = z.resolve(wall, false)
				err = nil
			}
		}
		if err != nil {
			return fmt.Errorf("%s needs %s dates", name, map[bool]string{true: "YYYY-MM-DD", false: "ISO 8601"}[e.AllDay])
		}
		d, err := eventStamp(e, t)
		if err != nil {
			return err
		}
		c.Props.Add(d.prop(name))
	}
	return nil
}
func encodeEvent(e Event) (string, error) {
	cal := ical.NewCalendar()
	cal.Props.SetText(ical.PropVersion, "2.0")
	cal.Props.SetText(ical.PropProductID, "-//Spacetime//Calendar 2.0//EN")
	var old Event
	if e.Raw != "" {
		var err error
		cal, err = ical.NewDecoder(strings.NewReader(e.Raw)).Decode()
		if err != nil {
			return "", err
		}
		old, _ = projectCalendar(cal)
	}
	var oldDuration *ical.Prop
	oldMaster := masterComponent(cal)
	if oldMaster != nil {
		oldDuration = oldMaster.Props.Get(ical.PropDuration)
	}
	name := ical.CompEvent
	if e.Kind == "todo" {
		name = ical.CompToDo
	}
	c := masterComponent(cal)
	if c == nil {
		c = ical.NewComponent(name)
		cal.Children = append(cal.Children, c)
	}
	c.Name = name
	uid := e.UID
	if uid == "" {
		uid = text(c, ical.PropUID)
	}
	if uid == "" {
		uid = e.ID + "@spacetime"
	}
	c.Props.SetText(ical.PropUID, uid)
	c.Props.SetText(ical.PropSummary, e.Title)
	c.Props.SetText(ical.PropDescription, e.Description)
	c.Props.Del("X-DAYBOOK-KIND")
	c.Props.SetText("X-SPACETIME-KIND", e.Kind)
	c.Props.Del(ical.PropLocation)
	if !special(e) && e.Location != "" {
		c.Props.SetText(ical.PropLocation, e.Location)
	}
	for prop, t := range map[string]*time.Time{ical.PropDateTimeStart: e.Start, ical.PropDateTimeEnd: e.End, ical.PropDue: e.Due} {
		if err := setEventDate(c, e, prop, t); err != nil {
			return "", err
		}
	}
	c.Props.Del(ical.PropDuration)
	sameDate := func(a, b *time.Time) bool { return a == nil && b == nil || a != nil && b != nil && a.Equal(*b) }
	if oldDuration != nil && e.Timezone == old.Timezone && sameDate(e.Start, old.Start) && sameDate(e.End, old.End) && sameDate(e.Due, old.Due) {
		c.Props.Set(oldDuration)
		if name == ical.CompEvent {
			c.Props.Del(ical.PropDateTimeEnd)
		} else {
			c.Props.Del(ical.PropDue)
		}
	}
	c.Props.Del(ical.PropRecurrenceRule)
	raw := e.RRule
	if raw == "" && e.Yearly {
		raw = "FREQ=YEARLY"
	}
	if raw != "" {
		p := ical.NewProp(ical.PropRecurrenceRule)
		p.Value = raw
		c.Props.Set(p)
	}
	// Preserve PERIOD values and property parameters when extra/exception dates did not change.
	if e.Raw == "" || !reflect.DeepEqual(e.RDates, old.RDates) {
		if err := listDateProperty(c, e, ical.PropRecurrenceDates, e.RDates); err != nil {
			return "", err
		}
	}
	if e.Raw == "" || !reflect.DeepEqual(e.ExDates, old.ExDates) {
		if err := listDateProperty(c, e, ical.PropExceptionDates, e.ExDates); err != nil {
			return "", err
		}
	}
	if e.Kind == "todo" {
		status := "NEEDS-ACTION"
		if e.Completed {
			status = "COMPLETED"
			c.Props.SetDateTime(ical.PropCompleted, e.Updated)
		} else {
			c.Props.Del(ical.PropCompleted)
		}
		c.Props.SetText(ical.PropStatus, status)
	}
	c.Props.SetDateTime(ical.PropDateTimeStamp, e.Updated.UTC())
	c.Props.SetDateTime(ical.PropLastModified, e.Updated.UTC())
	p := ical.NewProp(ical.PropSequence)
	p.Value = fmt.Sprint(nextSequence(c, e.Version))
	c.Props.Set(p)
	if special(e) {
		for _, child := range cal.Children {
			if child.Name == name {
				child.Props.Del(ical.PropLocation)
				child.Props.Del(ical.PropOrganizer)
				child.Props.Del(ical.PropAttendee)
			}
		}
	} else {
		if existing := c.Props.Get(ical.PropOrganizer); existing == nil || strings.HasPrefix(existing.Value, "urn:daybook:user:") || strings.HasPrefix(existing.Value, "urn:spacetime:user:") {
			p := ical.NewProp(ical.PropOrganizer)
			p.Value = "urn:spacetime:user:" + e.Owner
			c.Props.Set(p)
		}
		// Keep external attendees; app attendees remain governed by server-side RSVP state.
		existing := c.Props[ical.PropAttendee]
		delete(c.Props, ical.PropAttendee)
		for _, att := range existing {
			if !strings.HasPrefix(att.Value, "urn:spacetime:user:") && !strings.HasPrefix(att.Value, "urn:daybook:user:") {
				q := att
				c.Props.Add(&q)
			}
		}
		for name, status := range e.Attendees {
			p := ical.NewProp(ical.PropAttendee)
			p.Value = "urn:spacetime:user:" + name
			p.Params.Set("PARTSTAT", map[string]string{"pending": "NEEDS-ACTION", "accepted": "ACCEPTED", "declined": "DECLINED"}[status])
			p.Params.Set("RSVP", "TRUE")
			c.Props.Add(p)
		}
	}
	if !e.AllDay && e.Timezone != "" && e.Timezone != "UTC" && e.Timezone != "floating" {
		found := false
		for _, tz := range cal.Children {
			if tz.Name == ical.CompTimezone && text(tz, "TZID") == e.Timezone {
				found = true
			}
		}
		if !found {
			tz, err := timezoneComponent(e.Timezone)
			if err != nil {
				return "", err
			}
			cal.Children = append(cal.Children, tz)
		}
	}
	return calendarString(cal)
}
func projectCalendar(cal *ical.Calendar) (Event, error) {
	c := masterComponent(cal)
	if c == nil {
		for _, child := range cal.Children {
			if child.Name == ical.CompEvent || child.Name == ical.CompToDo {
				c = child
				break
			}
		}
	}
	if c == nil {
		return Event{}, fmt.Errorf("no event or todo component")
	}
	e := Event{Kind: "event", Imported: true, Timezone: "UTC", RDates: []string{}, ExDates: []string{}, Attendees: map[string]string{}}
	if c.Name == ical.CompToDo {
		e.Kind = "todo"
	} else {
		k := text(c, "X-SPACETIME-KIND")
		if k == "" {
			k = text(c, "X-DAYBOOK-KIND")
		}
		if k == "occasion" || k == "birthday" || k == "holiday" {
			e.Kind = "occasion"
		}
	}
	e.Title = text(c, ical.PropSummary)
	e.Description = text(c, ical.PropDescription)
	e.Location = text(c, ical.PropLocation)
	e.UID = text(c, ical.PropUID)
	zones, err := calendarZones(cal, 1900, calendarYear(cal)+2)
	if err != nil {
		return e, err
	}
	var first *stamp
	for prop, target := range map[string]**time.Time{ical.PropDateTimeStart: &e.Start, ical.PropDateTimeEnd: &e.End, ical.PropDue: &e.Due} {
		if p := c.Props.Get(prop); p != nil {
			d, err := parseStamp(p, zones, utcZone())
			if err != nil {
				return e, err
			}
			v := d.output()
			*target = &v
			local := d.Wall.Format("2006-01-02T15:04:05")
			if d.Date {
				local = d.Wall.Format("2006-01-02")
			}
			switch prop {
			case ical.PropDateTimeStart:
				e.LocalStart = local
			case ical.PropDateTimeEnd:
				e.LocalEnd = local
			case ical.PropDue:
				e.LocalDue = local
			}
			if prop == ical.PropDateTimeStart || first == nil {
				copy := d
				first = &copy
			}
			if d.Date {
				e.AllDay = true
			}
		}
	}
	if first != nil {
		e.Timezone = first.Zone.ID
		if first.Floating {
			e.Timezone = "floating"
		}
		if first.Date {
			e.Timezone = "UTC"
		}
	}
	if e.Start != nil && e.End == nil && c.Name == ical.CompEvent {
		start, _, _, err := componentDates(c, zones, utcZone())
		if err != nil {
			return e, err
		}
		var d stamp
		if p := c.Props.Get(ical.PropDuration); p != nil {
			d, err = addDuration(start, p.Value)
			if err != nil {
				return e, err
			}
		} else {
			d = start
			if d.Date {
				d.Wall = d.Wall.AddDate(0, 0, 1)
			}
		}
		v := d.output()
		e.End = &v
		e.LocalEnd = d.Wall.Format("2006-01-02T15:04:05")
		if d.Date {
			e.LocalEnd = d.Wall.Format("2006-01-02")
		}
	}
	if c.Name == ical.CompToDo && e.Due == nil && c.Props.Get(ical.PropDuration) != nil {
		_, _, due, err := componentDates(c, zones, utcZone())
		if err != nil {
			return e, err
		}
		v := due.output()
		e.Due = &v
		e.LocalDue = due.Wall.Format("2006-01-02T15:04:05")
		if due.Date {
			e.LocalDue = due.Wall.Format("2006-01-02")
		}
	}
	if p := c.Props.Get(ical.PropRecurrenceRule); p != nil {
		e.RRule = p.Value
		e.Yearly = p.Value == "FREQ=YEARLY"
		if first != nil {
			if spec, err := parseRule(p.Value, *first); err == nil && spec.Until != nil {
				e.UntilDate = first.Zone.wall(spec.Until.instant()).Format("2006-01-02")
			}
		}
	}
	for name, target := range map[string]*[]string{ical.PropRecurrenceDates: &e.RDates, ical.PropExceptionDates: &e.ExDates} {
		for _, p := range c.Props[name] {
			for _, v := range strings.Split(p.Value, ",") {
				q := p
				q.Value = v
				if p.ValueType() == ical.ValuePeriod {
					*target = append(*target, v)
					continue
				}
				d, err := parseStamp(&q, zones, utcZone())
				if err != nil {
					return e, err
				}
				s := d.output().Format(time.RFC3339)
				if d.Date {
					s = d.Wall.Format("2006-01-02")
				} else if d.Floating {
					s = d.Wall.Format("2006-01-02T15:04:05")
				}
				*target = append(*target, s)
			}
		}
	}
	e.Completed = text(c, ical.PropStatus) == "COMPLETED"
	e.Raw, err = calendarString(cal)
	return e, err
}
func decodeEvent(cal *ical.Calendar) (Event, error) {
	if text(cal.Component, "VERSION") != "2.0" || text(cal.Component, "PRODID") == "" {
		return Event{}, fmt.Errorf("VCALENDAR requires VERSION:2.0 and PRODID")
	}
	typ, uid, err := caldav.ValidateCalendarObject(cal)
	if err != nil || uid == "" || (typ != ical.CompEvent && typ != ical.CompToDo) {
		return Event{}, fmt.Errorf("a calendar resource must contain VEVENT or VTODO components with one UID")
	}
	e, err := projectCalendar(cal)
	if err != nil {
		return e, err
	}
	zones, err := calendarZones(cal, 1900, calendarYear(cal)+2)
	if err != nil {
		return e, err
	}
	masters := 0
	ids := map[string]bool{}
	for _, c := range cal.Children {
		if c.Name != typ {
			continue
		}
		for _, name := range []string{"UID", "DTSTAMP", "DTSTART", "DTEND", "DUE", "RECURRENCE-ID", "DURATION", "SUMMARY", "DESCRIPTION", "LOCATION", "STATUS", "SEQUENCE", "CREATED", "LAST-MODIFIED"} {
			if len(c.Props[name]) > 1 {
				return e, fmt.Errorf("duplicate %s property", name)
			}
		}
		if c.Props.Get("DTSTAMP") == nil || !strings.HasSuffix(c.Props.Get("DTSTAMP").Value, "Z") {
			return e, fmt.Errorf("components require a UTC DTSTAMP")
		}
		for _, props := range c.Props {
			for _, p := range props {
				if id := p.Params.Get("TZID"); id != "" {
					if zones[id] == nil {
						return e, fmt.Errorf("TZID %s requires a matching VTIMEZONE", id)
					}
				}
			}
		}
		if len(c.Props["RRULE"]) > 1 {
			return e, fmt.Errorf("only one RRULE is allowed per component")
		}
		p := c.Props.Get(ical.PropRecurrenceID)
		if p == nil {
			masters++
		} else {
			d, err := parseStamp(p, zones, utcZone())
			if err != nil {
				return e, err
			}
			if ids[d.key()] {
				return e, fmt.Errorf("duplicate RECURRENCE-ID")
			}
			ids[d.key()] = true
			if r := p.Params.Get("RANGE"); r != "" && r != "THISANDFUTURE" {
				return e, fmt.Errorf("invalid RECURRENCE-ID RANGE")
			}
		}
		s, en, du, err := componentDates(c, zones, utcZone())
		if err != nil {
			if typ == ical.CompToDo && c.Props.Get("RRULE") == nil {
				continue
			}
			return e, err
		}
		if p := c.Props.Get("RRULE"); p != nil {
			if c.Props.Get("DTSTART") == nil {
				return e, fmt.Errorf("recurring components require DTSTART")
			}
			if _, err := parseRule(p.Value, s); err != nil {
				return e, err
			}
		}
		if c.Props.Get("DURATION") != nil && (c.Props.Get("DTEND") != nil || c.Props.Get("DUE") != nil) {
			return e, fmt.Errorf("DURATION cannot coexist with DTEND or DUE")
		}
		for _, name := range []string{"RDATE", "EXDATE"} {
			for _, p := range c.Props[name] {
				for _, value := range strings.Split(p.Value, ",") {
					q := p
					q.Value = strings.SplitN(value, "/", 2)[0]
					q.Params = ical.Params{}
					for k, v := range p.Params {
						q.Params[k] = append([]string(nil), v...)
					}
					if q.ValueType() == ical.ValuePeriod {
						if name == "EXDATE" {
							return e, fmt.Errorf("EXDATE cannot contain PERIOD")
						}
						q.SetValueType(ical.ValueDateTime)
					}
					d, err := parseStamp(&q, zones, utcZone())
					if err != nil {
						return e, err
					}
					if d.Date != s.Date {
						return e, fmt.Errorf("%s must match DTSTART value type", name)
					}
				}
			}
		}
		if p := c.Props.Get("RECURRENCE-ID"); p != nil {
			rid, err := parseStamp(p, zones, utcZone())
			if err != nil {
				return e, err
			}
			master := masterComponent(cal)
			if master != nil {
				base, _, _, err := componentDates(master, zones, utcZone())
				if err != nil {
					return e, err
				}
				if rid.Date != base.Date || rid.Floating != base.Floating {
					return e, fmt.Errorf("RECURRENCE-ID must match the master DTSTART type")
				}
			}
		}
		if special(e) && !s.Date {
			return e, fmt.Errorf("occasions require DATE values")
		}
		if en != nil && c.Props.Get("DTEND") != nil && (en.Date != s.Date || !en.instant().After(s.instant())) {
			return e, fmt.Errorf("DTEND must have the DTSTART type and be later")
		}
		if du != nil && c.Props.Get("DTSTART") != nil && (du.Date != s.Date || !du.instant().After(s.instant())) {
			return e, fmt.Errorf("DUE must have the DTSTART type and be later")
		}
		if special(e) && (c.Props.Get("LOCATION") != nil || c.Props.Get("ATTENDEE") != nil || c.Props.Get("ORGANIZER") != nil) {
			return e, fmt.Errorf("occasions cannot have locations, organizers, or invitees")
		}
	}
	if masters > 1 {
		return e, fmt.Errorf("multiple master components for the same UID")
	}
	return e, nil
}

func eventZone(e Event) (*calendarZone, error) {
	if e.Raw != "" {
		cal, err := ical.NewDecoder(strings.NewReader(e.Raw)).Decode()
		if err == nil {
			zones, err := calendarZones(cal, 1900, calendarYear(cal)+2)
			if err != nil {
				return nil, err
			}
			if z := zones[e.Timezone]; z != nil {
				return z, nil
			}
		}
	}
	return ianaZone(e.Timezone)
}
func normalizeLocalDates(e *Event) error {
	e.RRule = strings.ToUpper(strings.TrimSpace(e.RRule))
	if e.Timezone == "" {
		e.Timezone = "UTC"
	}
	z := utcZone()
	var err error
	if !e.AllDay && e.Timezone != "floating" {
		z, err = eventZone(*e)
		if err != nil {
			return err
		}
	}
	for value, target := range map[string]**time.Time{e.LocalStart: &e.Start, e.LocalEnd: &e.End, e.LocalDue: &e.Due} {
		if value == "" {
			continue
		}
		format := "2006-01-02T15:04:05"
		if len(value) == 10 {
			format = "2006-01-02"
		}
		w, err := time.Parse(format, value)
		if err != nil {
			return fmt.Errorf("invalid local date")
		}
		t := w
		if !e.AllDay && e.Timezone != "floating" {
			t, _ = z.resolve(w, false)
		}
		*target = &t
	}
	if e.UntilDate != "" && e.RRule != "" {
		date, err := time.Parse("2006-01-02", e.UntilDate)
		if err != nil {
			return fmt.Errorf("invalid recurrence end date")
		}
		parts := []string{}
		for _, p := range strings.Split(e.RRule, ";") {
			if !strings.HasPrefix(p, "UNTIL=") {
				parts = append(parts, p)
			}
		}
		u := date.Format("20060102")
		if !e.AllDay {
			date = date.Add(23*time.Hour + 59*time.Minute + 59*time.Second)
			if e.Timezone == "floating" {
				u = date.Format("20060102T150405")
			} else {
				t, _ := z.resolve(date, false)
				u = t.Format("20060102T150405Z")
			}
		}
		e.RRule = strings.Join(append(parts, "UNTIL="+u), ";")
	}
	return nil
}

func encodeRSVP(e Event) (string, error) {
	cal, err := ical.NewDecoder(strings.NewReader(e.Raw)).Decode()
	if err != nil {
		return "", err
	}
	for _, c := range cal.Children {
		if c.Name != ical.CompEvent && c.Name != ical.CompToDo {
			continue
		}
		for idx, p := range c.Props[ical.PropAttendee] {
			name := strings.TrimPrefix(strings.TrimPrefix(p.Value, "urn:spacetime:user:"), "urn:daybook:user:")
			if status := e.Attendees[name]; status != "" {
				p.Params.Set("PARTSTAT", map[string]string{"pending": "NEEDS-ACTION", "accepted": "ACCEPTED", "declined": "DECLINED"}[status])
				c.Props[ical.PropAttendee][idx] = p
			}
		}
		c.Props.SetDateTime(ical.PropDateTimeStamp, e.Updated)
		c.Props.SetDateTime(ical.PropLastModified, e.Updated)
	}
	return calendarString(cal)
}

func nextSequence(c *ical.Component, minimum int) int {
	value := 0
	if p := c.Props.Get(ical.PropSequence); p != nil {
		value, _ = strconv.Atoi(p.Value)
		if value < 2147483647 {
			value++
		}
	}
	if value < minimum {
		value = minimum
	}
	return value
}

func calendarYear(cal *ical.Calendar) int {
	year := time.Now().Year()
	for _, c := range cal.Children {
		if c.Name != ical.CompEvent && c.Name != ical.CompToDo {
			continue
		}
		for _, name := range []string{"DTSTART", "DTEND", "DUE", "RECURRENCE-ID"} {
			if p := c.Props.Get(name); p != nil && len(p.Value) >= 4 {
				n, _ := strconv.Atoi(p.Value[:4])
				if n > year {
					year = n
				}
			}
		}
	}
	return year
}
