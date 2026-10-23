package main

import (
	"io"
	"strings"
	"unicode/utf8"

	"github.com/emersion/go-ical"
)

func sourceCalendarStream(raw string) ([]*ical.Calendar, error) {
	if !utf8.ValidString(raw) {
		return nil, statusError(502, "The source calendar is not valid UTF-8.")
	}
	d := ical.NewDecoder(strings.NewReader(raw))
	calendars := []*ical.Calendar{}
	for len(calendars) < 128 {
		cal, err := d.Decode()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, statusError(502, "The source returned invalid iCalendar data.")
		}
		if text(cal.Component, "VERSION") != "2.0" || text(cal.Component, "PRODID") == "" {
			return nil, statusError(502, "Source calendars require VERSION:2.0 and PRODID.")
		}
		calendars = append(calendars, cal)
	}
	if len(calendars) == 0 || len(calendars) == 128 {
		return nil, statusError(502, "The source calendar stream is empty or exceeds its limit.")
	}
	return calendars, nil
}
func parseSourceEvents(raw string, general bool) (map[string]Event, error) {
	calendars, err := sourceCalendarStream(raw)
	if err != nil {
		return nil, err
	}
	if !general && len(calendars) != 1 {
		return nil, statusError(502, "A CalDAV resource must contain one VCALENDAR object.")
	}
	result := map[string]Event{}
	for _, cal := range calendars {
		groups := map[string][]*ical.Component{}
		for _, c := range cal.Children {
			if c.Name == ical.CompEvent || c.Name == ical.CompToDo {
				uid := text(c, ical.PropUID)
				if uid == "" {
					return nil, statusError(502, "A source entry is missing its UID.")
				}
				groups[uid] = append(groups[uid], c)
			}
		}
		for uid, children := range groups {
			if _, exists := result[uid]; exists {
				return nil, statusError(502, "The source stream contains the same UID in separate calendar objects.")
			}
			single := ical.NewCalendar()
			single.Props = make(ical.Props)
			for name, props := range cal.Props {
				if name != ical.PropMethod || !general {
					single.Props[name] = props
				}
			}
			for _, c := range cal.Children {
				if c.Name == ical.CompTimezone {
					single.Children = append(single.Children, c)
				}
			}
			single.Children = append(single.Children, children...)
			e, err := decodeEvent(single)
			if err != nil {
				return nil, statusError(502, "The source returned an invalid event or todo: "+err.Error())
			}
			result[uid] = e
			if len(result) > 10000 {
				return nil, statusError(413, "A connected calendar may contain at most 10,000 series.")
			}
		}
	}
	return result, nil
}
func rewriteSourceBundle(raw string, e *Event, remove bool) (string, error) {
	calendars, err := sourceCalendarStream(raw)
	if err != nil {
		return "", err
	}
	index := -1
	for i, cal := range calendars {
		for _, c := range cal.Children {
			if (c.Name == ical.CompEvent || c.Name == ical.CompToDo) && text(c, ical.PropUID) == e.UID {
				if index >= 0 && index != i {
					return "", statusError(409, "The source has ambiguous calendar UIDs.")
				}
				index = i
			}
		}
	}
	if index < 0 {
		if remove {
			return "", statusError(409, "The source entry changed. Sync first.")
		}
		index = 0
	}
	cal := calendars[index]
	children := []*ical.Component{}
	zones := map[string]bool{}
	for _, c := range cal.Children {
		if (c.Name == ical.CompEvent || c.Name == ical.CompToDo) && text(c, ical.PropUID) == e.UID {
			continue
		}
		children = append(children, c)
		if c.Name == ical.CompTimezone {
			zones[text(c, "TZID")] = true
		}
	}
	if !remove {
		entry, err := ical.NewDecoder(strings.NewReader(e.Raw)).Decode()
		if err != nil {
			return "", err
		}
		for _, c := range entry.Children {
			if c.Name == ical.CompEvent || c.Name == ical.CompToDo {
				children = append(children, c)
			} else if c.Name == ical.CompTimezone && !zones[text(c, "TZID")] {
				children = append(children, c)
				zones[text(c, "TZID")] = true
			}
		}
	}
	if len(children) == 0 {
		// RFC 5545 permits timezone-only calendars, but requires a component.
		// Keep an empty writable calendar file valid without inventing an event.
		zone := ical.NewComponent(ical.CompTimezone)
		zone.Props.SetText("TZID", "Etc/UTC")
		standard := ical.NewComponent("STANDARD")
		standard.Props.SetText("DTSTART", "19700101T000000")
		standard.Props.SetText("TZOFFSETFROM", "+0000")
		standard.Props.SetText("TZOFFSETTO", "+0000")
		zone.Children = append(zone.Children, standard)
		children = append(children, zone)
	}
	cal.Children = children
	var output strings.Builder
	encoder := ical.NewEncoder(&output)
	for _, calendar := range calendars {
		if err := encoder.Encode(calendar); err != nil {
			return "", err
		}
	}
	return output.String(), nil
}
