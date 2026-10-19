package main

import (
	"context"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/emersion/go-ical"
)

type transition struct {
	At       time.Time
	From, To int
}
type calendarZone struct {
	ID          string
	Loc         *time.Location
	Transitions []transition
	Offsets     []int
}

func utcZone() *calendarZone { return &calendarZone{ID: "UTC", Loc: time.UTC} }
func ianaZone(id string) (*calendarZone, error) {
	loc, err := time.LoadLocation(id)
	if err != nil {
		return nil, fmt.Errorf("unknown time zone %q", id)
	}
	return &calendarZone{ID: id, Loc: loc}, nil
}
func (z *calendarZone) custom() bool { return z.Loc == nil }
func (z *calendarZone) location() *time.Location {
	if z.Loc != nil {
		return z.Loc
	}
	return time.UTC
}
func (z *calendarZone) offset(t time.Time) int {
	if z.Loc != nil {
		_, off := t.In(z.Loc).Zone()
		return off
	}
	if len(z.Transitions) == 0 {
		return z.Offsets[0]
	}
	i := sort.Search(len(z.Transitions), func(i int) bool { return z.Transitions[i].At.After(t) })
	if i == 0 {
		return z.Transitions[0].From
	}
	return z.Transitions[i-1].To
}
func (z *calendarZone) wall(t time.Time) time.Time {
	return civil(t.UTC().Add(time.Duration(z.offset(t)) * time.Second))
}
func (z *calendarZone) resolve(w time.Time, skipGap bool) (time.Time, bool) {
	offsets := map[int]bool{}
	if z.Loc != nil {
		for h := -72; h <= 72; h += 3 {
			offsets[z.offset(w.Add(time.Duration(h)*time.Hour))] = true
		}
	} else {
		for _, off := range z.Offsets {
			offsets[off] = true
		}
	}
	var matches []time.Time
	for off := range offsets {
		candidate := w.Add(-time.Duration(off) * time.Second)
		if z.wall(candidate).Equal(w) {
			matches = append(matches, candidate)
		}
	}
	if len(matches) > 0 {
		sort.Slice(matches, func(i, j int) bool { return matches[i].Before(matches[j]) })
		return matches[0], true
	}
	if skipGap {
		return time.Time{}, false
	}
	// Explicit DTSTART/RDATE in a gap uses the offset before the gap (§3.3.5).
	transitions := z.Transitions
	if z.Loc != nil {
		transitions = nil
		for h := -72; h <= 72; h += 3 {
			sample := w.Add(time.Duration(h) * time.Hour)
			begin, _ := sample.In(z.Loc).ZoneBounds()
			if begin.IsZero() {
				continue
			}
			_, before := begin.Add(-time.Second).In(z.Loc).Zone()
			_, after := begin.In(z.Loc).Zone()
			transitions = append(transitions, transition{begin, before, after})
		}
	}
	for _, tr := range transitions {
		if tr.To <= tr.From {
			continue
		}
		before := tr.At.Add(time.Duration(tr.From) * time.Second)
		after := tr.At.Add(time.Duration(tr.To) * time.Second)
		if !w.Before(before) && w.Before(after) {
			return w.Add(-time.Duration(tr.From) * time.Second), true
		}
	}

	return time.Time{}, false
}
func parseOffset(raw string) (int, error) {
	if (len(raw) != 5 && len(raw) != 7) || (raw[0] != '+' && raw[0] != '-') {
		return 0, fmt.Errorf("invalid UTC offset")
	}
	h, e := strconv.Atoi(raw[1:3])
	if e != nil || h > 23 {
		return 0, fmt.Errorf("invalid UTC offset")
	}
	m, e := strconv.Atoi(raw[3:5])
	if e != nil || m > 59 {
		return 0, fmt.Errorf("invalid UTC offset")
	}
	s := 0
	if len(raw) == 7 {
		s, e = strconv.Atoi(raw[5:])
		if e != nil || s > 59 {
			return 0, fmt.Errorf("invalid UTC offset")
		}
	}
	n := h*3600 + m*60 + s
	if raw[0] == '-' {
		n = -n
	}
	return n, nil
}
func formatOffset(n int) string {
	sign := "+"
	if n < 0 {
		sign = "-"
		n = -n
	}
	s := fmt.Sprintf("%s%02d%02d", sign, n/3600, (n%3600)/60)
	if n%60 != 0 {
		s += fmt.Sprintf("%02d", n%60)
	}
	return s
}
func calendarZones(cal *ical.Calendar, fromYear, toYear int) (map[string]*calendarZone, error) {
	result := map[string]*calendarZone{"UTC": utcZone()}
	for _, c := range cal.Children {
		if c.Name != ical.CompTimezone {
			continue
		}
		id := text(c, "TZID")
		if id == "" {
			return nil, fmt.Errorf("VTIMEZONE requires TZID")
		}
		if _, exists := result[id]; exists {
			return nil, fmt.Errorf("duplicate VTIMEZONE %s", id)
		}
		z := &calendarZone{ID: id}
		offsets := map[int]bool{}
		for _, obs := range c.Children {
			if obs.Name != "STANDARD" && obs.Name != "DAYLIGHT" {
				continue
			}
			f, err := parseOffset(rawProperty(obs, "TZOFFSETFROM"))
			if err != nil {
				return nil, err
			}
			t, err := parseOffset(rawProperty(obs, "TZOFFSETTO"))
			if err != nil {
				return nil, err
			}
			offsets[f] = true
			offsets[t] = true
			s, err := parseStamp(obs.Props.Get("DTSTART"), map[string]*calendarZone{}, utcZone())
			if err != nil {
				return nil, err
			}
			onsets := []stamp{s}
			if p := obs.Props.Get("RRULE"); p != nil {
				// Observance UNTIL is UTC even though its DTSTART is local wall time.
				raw := p.Value
				pieces := []string{}
				var until time.Time
				for _, piece := range strings.Split(raw, ";") {
					if strings.HasPrefix(piece, "UNTIL=") {
						until, err = time.Parse("20060102T150405Z", strings.TrimPrefix(piece, "UNTIL="))
						if err != nil {
							return nil, err
						}
					} else {
						pieces = append(pieces, piece)
					}
				}
				spec, err := parseRule(strings.Join(pieces, ";"), s)
				if err != nil {
					return nil, err
				}
				dates, err := ruleDates(context.Background(), spec, s, s.Wall, time.Date(toYear+1, 1, 1, 0, 0, 0, 0, time.UTC), maxInstances)
				if err != nil {
					return nil, err
				}
				for _, d := range dates {
					if until.IsZero() || !d.Wall.Add(-time.Duration(f)*time.Second).After(until) {
						onsets = append(onsets, d)
					}
				}
			}
			for _, p := range obs.Props["RDATE"] {
				for _, value := range strings.Split(p.Value, ",") {
					q := p
					q.Value = value
					d, err := parseStamp(&q, map[string]*calendarZone{}, utcZone())
					if err != nil {
						return nil, err
					}
					onsets = append(onsets, d)
				}
			}
			for _, d := range onsets {
				z.Transitions = append(z.Transitions, transition{d.Wall.Add(-time.Duration(f) * time.Second), f, t})
			}
		}
		if len(z.Transitions) == 0 {
			return nil, fmt.Errorf("VTIMEZONE needs a STANDARD or DAYLIGHT observance")
		}
		for off := range offsets {
			z.Offsets = append(z.Offsets, off)
		}
		sort.SliceStable(z.Transitions, func(i, j int) bool { return z.Transitions[i].At.Before(z.Transitions[j].At) })
		result[id] = z
	}
	return result, nil
}

// Export self-contained VTIMEZONE data. Historical transitions use RDATE; the
// stable POSIX tail in Go's IANA database is expressed as an unbounded yearly rule.
// This avoids silently truncating zones at an arbitrary year.
func timezoneComponent(id string) (*ical.Component, error) {
	loc, err := time.LoadLocation(id)
	if err != nil {
		return nil, err
	}
	root := ical.NewComponent(ical.CompTimezone)
	root.Props.SetText("TZID", id)
	type item struct {
		wall     time.Time
		from, to int
		name     string
		dst      bool
	}
	items := []item{}
	t := time.Date(1600, 1, 1, 0, 0, 0, 0, time.UTC)
	cutoff := time.Date(2100, 1, 1, 0, 0, 0, 0, time.UTC)
	initialName, initialOff := t.In(loc).Zone()
	for i := 0; i < 5000; i++ {
		_, end := t.In(loc).ZoneBounds()
		if end.IsZero() || !end.Before(cutoff) {
			break
		}
		if !end.After(t) {
			t = t.Add(24 * time.Hour)
			continue
		}
		_, before := end.Add(-time.Second).In(loc).Zone()
		name, after := end.In(loc).Zone()
		if before != after {
			items = append(items, item{civil(end.UTC().Add(time.Duration(before) * time.Second)), before, after, name, end.In(loc).IsDST()})
		}
		t = end
	}
	makeObs := func(it item) *ical.Component {
		name := "STANDARD"
		if it.dst {
			name = "DAYLIGHT"
		}
		c := ical.NewComponent(name)
		p := ical.NewProp("DTSTART")
		p.Value = it.wall.Format("20060102T150405")
		c.Props.Set(p)
		p = ical.NewProp("TZOFFSETFROM")
		p.Value = formatOffset(it.from)
		c.Props.Set(p)
		p = ical.NewProp("TZOFFSETTO")
		p.Value = formatOffset(it.to)
		c.Props.Set(p)
		c.Props.SetText("TZNAME", it.name)
		return c
	}
	root.Children = append(root.Children, makeObs(item{time.Date(1600, 1, 1, 0, 0, 0, 0, time.UTC), initialOff, initialOff, initialName, false}))
	groups := map[string]*ical.Component{}
	for _, it := range items {
		if it.wall.Year() == 2099 {
			c := makeObs(it)
			nth := (it.wall.Day()-1)/7 + 1
			if it.wall.AddDate(0, 0, 7).Month() != it.wall.Month() {
				nth = -1
			}
			days := []string{"SU", "MO", "TU", "WE", "TH", "FR", "SA"}
			p := ical.NewProp("RRULE")
			p.Value = fmt.Sprintf("FREQ=YEARLY;BYMONTH=%d;BYDAY=%d%s", it.wall.Month(), nth, days[it.wall.Weekday()])
			c.Props.Set(p)
			root.Children = append(root.Children, c)
			continue
		}
		key := fmt.Sprintf("%d/%d/%s/%t", it.from, it.to, it.name, it.dst)
		c := groups[key]
		if c == nil {
			c = makeObs(it)
			groups[key] = c
			root.Children = append(root.Children, c)
		} else {
			p := c.Props.Get("RDATE")
			if p == nil {
				p = ical.NewProp("RDATE")
				p.Value = it.wall.Format("20060102T150405")
			} else {
				p.Value += "," + it.wall.Format("20060102T150405")
			}
			c.Props.Set(p)
		}
	}
	return root, nil
}

func rawProperty(c *ical.Component, name string) string {
	if p := c.Props.Get(name); p != nil {
		return p.Value
	}
	return ""
}
