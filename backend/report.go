package main

import (
	"bytes"
	"context"
	"encoding/xml"
	"errors"
	"fmt"
	"github.com/emersion/go-webdav"
	"io"
	"mime"
	"net/http"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/emersion/go-ical"
	"github.com/emersion/go-webdav/caldav"
)

const davNS = "DAV:"
const calNS = "urn:ietf:params:xml:ns:caldav"

type xmlNode struct {
	XMLName  xml.Name
	Attrs    []xml.Attr `xml:",any,attr"`
	Text     string     `xml:",chardata"`
	Children []xmlNode  `xml:",any"`
}

func (n xmlNode) attr(name string) string {
	for _, a := range n.Attrs {
		if a.Name.Local == name {
			return a.Value
		}
	}
	return ""
}
func (n xmlNode) child(ns, name string) *xmlNode {
	for _, c := range n.Children {
		if c.XMLName.Space == ns && c.XMLName.Local == name {
			return &c
		}
	}
	return nil
}

type reportFailure struct {
	Code               int
	Condition, Message string
	Href               string
}

func (e *reportFailure) Error() string { return e.Message }
func reportFail(code int, condition, msg string) error {
	return &reportFailure{Code: code, Condition: condition, Message: msg}
}
func xmlEscape(s string) string {
	var b bytes.Buffer
	_ = xml.EscapeText(&b, []byte(s))
	return b.String()
}
func xmlTag(n xml.Name) string {
	switch n.Space {
	case davNS:
		return "D:" + n.Local
	case calNS:
		return "C:" + n.Local
	default:
		return n.Local
	}
}
func xmlProperty(n xml.Name, value string) string {
	tag := xmlTag(n)
	extra := ""
	if n.Space != davNS && n.Space != calNS {
		extra = ` xmlns="` + xmlEscape(n.Space) + `"`
	}
	return "<" + tag + extra + ">" + xmlEscape(value) + "</" + tag + ">"
}
func parseRange(n *xmlNode, closed bool) (time.Time, time.Time, error) {
	from := time.Date(1, 1, 1, 0, 0, 0, 0, time.UTC)
	to := time.Date(9999, 12, 31, 23, 59, 59, 0, time.UTC)
	if n == nil {
		return from, to, nil
	}
	s, e := n.attr("start"), n.attr("end")
	if s == "" && e == "" || closed && (s == "" || e == "") {
		return from, to, reportFail(400, "valid-filter", "A valid time range is required")
	}
	var err error
	if s != "" {
		from, err = time.Parse("20060102T150405Z", s)
		if err != nil {
			return from, to, reportFail(400, "valid-filter", "Invalid UTC range start")
		}
	}
	if e != "" {
		to, err = time.Parse("20060102T150405Z", e)
		if err != nil {
			return from, to, reportFail(400, "valid-filter", "Invalid UTC range end")
		}
	}
	if !to.After(from) {
		return from, to, reportFail(400, "valid-filter", "Range end must be after start")
	}
	return from, to, nil
}
func reportError(w http.ResponseWriter, err error) {
	code, condition := 500, "valid-calendar-data"
	var e *reportFailure
	if errors.As(err, &e) {
		code, condition = e.Code, e.Condition
	}
	if condition == "" {
		http.Error(w, err.Error(), code)
		return
	}
	w.Header().Set("Content-Type", "application/xml; charset=utf-8")
	w.WriteHeader(code)
	inner := ""
	if e != nil && e.Href != "" {
		inner = "<D:href>" + xmlEscape(e.Href) + "</D:href>"
	}
	fmt.Fprintf(w, `<?xml version="1.0"?><D:error xmlns:D="DAV:" xmlns:C="%s"><C:%s>%s</C:%s><D:responsedescription>%s</D:responsedescription></D:error>`, calNS, condition, inner, condition, xmlEscape(err.Error()))
}
func (d *davBackend) serve(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if _, base, err := davCalendarID(r.Context(), r.URL.Path); err == nil {
			r = r.WithContext(context.WithValue(r.Context(), davCollectionKey{}, base))
		}
		if r.Method == "OPTIONS" {
			capture := &davCapture{header: make(http.Header)}
			next.ServeHTTP(capture, r)
			for k, v := range capture.header {
				w.Header()[k] = v
			}
			w.Header().Set("Allow", strings.Trim(capture.header.Get("Allow")+", MKCALENDAR", ", "))
			status := capture.status
			if status == 0 {
				status = 200
			}
			w.WriteHeader(status)
			w.Write(capture.body.Bytes())
			return
		}
		if r.Method == "MKCALENDAR" {
			d.mkCalendar(w, r)
			return
		}
		if r.Method == "PROPFIND" {
			d.calendarProperties(w, r, next)
			return
		}
		if r.Method == "PUT" {
			if err := d.put(w, r); err != nil {
				reportError(w, err)
			}
			return
		}
		if r.Method == "GET" || r.Method == "HEAD" {
			if strings.HasSuffix(r.URL.Path, ".ics") {
				if err := d.get(w, r); err != nil {
					reportError(w, err)
				}
				return
			}
		}
		if r.Method != "REPORT" {
			next.ServeHTTP(w, r)
			return
		}
		if err := d.report(w, r); err != nil {
			reportError(w, err)
		}
	})
}
func (d *davBackend) report(w http.ResponseWriter, r *http.Request) error {
	r = r.WithContext(context.WithValue(r.Context(), caldavRangeKey{}, true))
	var req xmlNode
	if err := xml.NewDecoder(r.Body).Decode(&req); err != nil {
		return reportFail(400, "valid-filter", "Malformed REPORT XML")
	}
	if req.XMLName.Space != calNS || (req.XMLName.Local != "calendar-query" && req.XMLName.Local != "calendar-multiget" && req.XMLName.Local != "free-busy-query") {
		return reportFail(403, "supported-report", "Unsupported calendar report")
	}
	if req.XMLName.Local == "free-busy-query" {
		return d.freeBusy(w, r, req)
	}
	zone := utcZone()
	if tz := req.child(calNS, "timezone"); tz != nil {
		cal, err := ical.NewDecoder(strings.NewReader(tz.Text)).Decode()
		if err != nil {
			return reportFail(403, "valid-calendar-data", "Invalid query timezone")
		}
		zones, err := calendarZones(cal, 1900, 2102)
		if err != nil {
			return err
		}
		for _, c := range cal.Children {
			if c.Name == ical.CompTimezone {
				zone = zones[text(c, "TZID")]
				break
			}
		}
	}
	if req.XMLName.Local == "calendar-query" && r.URL.Path != calendarPath(r.Context()) {
		return reportFail(404, "valid-filter", "Calendar not found")
	}
	prop := req.child(davNS, "prop")
	namesOnly := req.child(davNS, "propname") != nil
	if prop == nil {
		prop = &xmlNode{XMLName: xml.Name{Space: davNS, Local: "prop"}}
		for _, name := range []string{"getetag", "getcontenttype", "getcontentlength", "getlastmodified", "resourcetype"} {
			prop.Children = append(prop.Children, xmlNode{XMLName: xml.Name{Space: davNS, Local: name}})
		}
	}
	objects := []caldav.CalendarObject{}
	missing := []string{}
	if req.XMLName.Local == "calendar-query" {
		if r.URL.Path != calendarPath(r.Context()) {
			return reportFail(404, "valid-filter", "Calendar not found")
		}
		filter := req.child(calNS, "filter")
		if filter == nil || filter.child(calNS, "comp-filter") == nil {
			return reportFail(400, "valid-filter", "calendar-query requires a component filter")
		}
		all, err := d.ListCalendarObjects(r.Context(), r.URL.Path, nil)
		if err != nil {
			return err
		}
		for _, co := range all {
			match, err := matchCalendar(r.Context(), co.Data, *filter.child(calNS, "comp-filter"), zone)
			if err != nil {
				return err
			}
			if match {
				objects = append(objects, co)
			}
		}
	} else {
		for _, node := range req.Children {
			if node.XMLName.Space != davNS || node.XMLName.Local != "href" {
				continue
			}
			co, err := d.GetCalendarObject(r.Context(), node.Text, nil)
			if err != nil {
				missing = append(missing, node.Text)
			} else {
				objects = append(objects, *co)
			}
		}
	}
	var b strings.Builder
	b.WriteString(`<?xml version="1.0" encoding="utf-8"?><D:multistatus xmlns:D="DAV:" xmlns:C="` + calNS + `">`)
	for _, co := range objects {
		good, bad := "", ""
		for _, p := range prop.Children {
			value := ""
			known := true
			switch p.XMLName {
			case xml.Name{Space: davNS, Local: "getetag"}:
				value = `"` + co.ETag + `"`
			case xml.Name{Space: davNS, Local: "getcontenttype"}:
				value = "text/calendar; charset=utf-8"
			case xml.Name{Space: davNS, Local: "getcontentlength"}:
				value = fmt.Sprint(co.ContentLength)
			case xml.Name{Space: davNS, Local: "getlastmodified"}:
				value = co.ModTime.UTC().Format(http.TimeFormat)
			case xml.Name{Space: davNS, Local: "resourcetype"}:
				value = ""
			case xml.Name{Space: calNS, Local: "calendar-data"}:
				if ct := p.attr("content-type"); ct != "" && ct != "text/calendar" {
					return reportFail(403, "supported-calendar-data", "Only text/calendar is supported")
				}
				if version := p.attr("version"); version != "" && version != "2.0" {
					return reportFail(403, "supported-calendar-data", "Only iCalendar 2.0 is supported")
				}
				cal, err := calendarData(r.Context(), co.Data, p, zone)
				if err != nil {
					return err
				}
				value, err = calendarString(cal)
				if err != nil {
					return err
				}
			default:
				known = false
			}
			if namesOnly {
				value = ""
			}
			if known {
				good += xmlProperty(p.XMLName, value)
			} else {
				bad += xmlProperty(p.XMLName, "")
			}
		}
		b.WriteString("<D:response><D:href>" + xmlEscape(co.Path) + "</D:href>")
		for _, item := range []struct{ props, status string }{{good, "200 OK"}, {bad, "404 Not Found"}} {
			if item.props != "" {
				b.WriteString("<D:propstat><D:prop>" + item.props + "</D:prop><D:status>HTTP/1.1 " + item.status + "</D:status></D:propstat>")
			}
		}
		b.WriteString("</D:response>")
	}
	for _, p := range missing {
		b.WriteString("<D:response><D:href>" + xmlEscape(p) + "</D:href><D:status>HTTP/1.1 404 Not Found</D:status></D:response>")
	}
	b.WriteString("</D:multistatus>")
	w.Header().Set("Content-Type", "application/xml; charset=utf-8")
	w.WriteHeader(207)
	_, err := w.Write([]byte(b.String()))
	return err
}
func matchCalendar(ctx context.Context, cal *ical.Calendar, filter xmlNode, zone *calendarZone) (bool, error) {
	if filter.attr("name") != "VCALENDAR" {
		return false, reportFail(403, "valid-filter", "The root filter must select VCALENDAR")
	}
	return matchComponent(ctx, cal, cal.Component, filter, zone, nil)
}
func matchComponent(ctx context.Context, cal *ical.Calendar, c *ical.Component, f xmlNode, zone *calendarZone, inst *instance) (bool, error) {
	if c.Name != f.attr("name") {
		return false, nil
	}
	if f.child(calNS, "is-not-defined") != nil {
		return false, nil
	}
	if inst == nil && (c.Name == ical.CompEvent || c.Name == ical.CompToDo) && f.child(calNS, "time-range") == nil {
		if from, to, has, err := nestedRange(f); err != nil {
			return false, err
		} else if has {
			zones, err := calendarZones(cal, from.Year()-2, to.Year()+2)
			if err != nil {
				return false, err
			}
			s, e, due, err := componentDates(c, zones, zone)
			if err != nil {
				return false, err
			}
			margin := 48 * time.Hour
			for _, alarm := range c.Children {
				if alarm.Name != ical.CompAlarm {
					continue
				}
				if trigger := alarm.Props.Get("TRIGGER"); trigger != nil && trigger.ValueType() == ical.ValueDuration {
					t, err := addDuration(s, trigger.Value)
					if err != nil {
						return false, err
					}
					delta := t.instant().Sub(s.instant())
					if delta < 0 {
						delta = -delta
					}
					if end := e; end != nil {
						delta += end.instant().Sub(s.instant())
					}
					if due != nil {
						delta += due.instant().Sub(s.instant())
					}
					if delta > margin {
						margin = delta
					}
					if dur := alarm.Props.Get("DURATION"); dur != nil {
						repeat := 0
						if p := alarm.Props.Get("REPEAT"); p != nil {
							fmt.Sscan(p.Value, &repeat)
						}
						if repeat > maxInstances {
							return false, reportFail(507, "number-of-matches-within-limits", "Alarm repeat limit exceeded")
						}
						t, err := addDuration(s, dur.Value)
						if err != nil {
							return false, err
						}
						delta = t.instant().Sub(s.instant()) * time.Duration(repeat)
						if delta < 0 {
							delta = -delta
						}
						margin += delta
					}
				}
			}
			items, err := expandCalendar(ctx, cal, from.Add(-margin), to.Add(margin), zone)
			if err != nil {
				return false, reportFail(507, "number-of-matches-within-limits", err.Error())
			}
			for _, alarm := range c.Children {
				if p := alarm.Props.Get("TRIGGER"); alarm.Name == ical.CompAlarm && p != nil && p.ValueType() != ical.ValueDuration {
					items = append(items, instance{c, s, e, due, s, false})
					break
				}
			}
			for _, i := range items {
				if i.Component.Name != c.Name {
					continue
				}
				virtual := instanceComponent(i)
				ok, err := matchComponent(ctx, cal, virtual, f, zone, &i)
				if err != nil {
					return false, err
				}
				if ok {
					return true, nil
				}
			}
			return false, nil
		}
	}
	if tr := f.child(calNS, "time-range"); tr != nil {
		from, to, err := parseRange(tr, false)
		if err != nil {
			return false, err
		}
		if c.Name == ical.CompEvent || c.Name == ical.CompToDo {
			if inst == nil {
				items, err := expandCalendar(ctx, cal, from, to, zone)
				if err != nil {
					return false, reportFail(507, "number-of-matches-within-limits", err.Error())
				}
				for _, i := range items {
					if i.Component.Name != c.Name {
						continue
					}
					copy := f
					copy.Children = nil
					for _, n := range f.Children {
						if n.XMLName.Local != "time-range" {
							copy.Children = append(copy.Children, n)
						}
					}
					ok, err := matchComponent(ctx, cal, instanceComponent(i), copy, zone, &i)
					if err != nil {
						return false, err
					}
					if ok {
						return true, nil
					}
				}
				return false, nil
			}
			if !overlaps(inst.Start, inst.End, from, to) {
				return false, nil
			}
		} else if c.Name == ical.CompAlarm {
			if inst == nil {
				return false, nil
			}
			ok, err := alarmMatches(c, *inst, from, to)
			if err != nil {
				return false, err
			}
			if !ok {
				return false, nil
			}
		} else {
			return false, reportFail(403, "supported-filter", "Time ranges are supported on events, todos, and alarms")
		}
	}
	for _, p := range f.Children {
		if p.XMLName.Space != calNS {
			continue
		}
		switch p.XMLName.Local {
		case "prop-filter":
			ok, err := matchProperty(c, p, zone)
			if err != nil || !ok {
				return false, err
			}
		case "comp-filter":
			found, matched := false, false
			for _, child := range c.Children {
				if child.Name != p.attr("name") {
					continue
				}
				found = true
				ok, err := matchComponent(ctx, cal, child, p, zone, inst)
				if err != nil {
					return false, err
				}
				matched = matched || ok
			}
			if p.child(calNS, "is-not-defined") != nil {
				if found {
					return false, nil
				}
			} else if !matched {
				return false, nil
			}
		}
	}
	return true, nil
}
func matchText(value string, n xmlNode) (bool, error) {
	collation := n.attr("collation")
	if collation == "" {
		collation = "i;ascii-casemap"
	}
	needle := n.Text
	switch collation {
	case "i;ascii-casemap":
		lower := func(s string) string {
			b := []byte(s)
			for i, c := range b {
				if c >= 'A' && c <= 'Z' {
					b[i] = c + 32
				}
			}
			return string(b)
		}
		value = lower(value)
		needle = lower(needle)
	case "i;octet":
	default:
		return false, reportFail(403, "supported-collation", "Unsupported text collation")
	}
	ok := strings.Contains(value, needle)
	if n.attr("negate-condition") == "yes" {
		ok = !ok
	}
	return ok, nil
}
func matchProperty(c *ical.Component, f xmlNode, zone *calendarZone) (bool, error) {
	props := c.Props[strings.ToUpper(f.attr("name"))]
	if f.child(calNS, "is-not-defined") != nil {
		return len(props) == 0, nil
	}
	for _, p := range props {
		ok := true
		if match := f.child(calNS, "text-match"); match != nil {
			value, err := p.Text()
			if err != nil {
				value = p.Value
			}
			ok, err = matchText(value, *match)
			if err != nil {
				return false, err
			}
		}
		if tr := f.child(calNS, "time-range"); tr != nil {
			from, to, err := parseRange(tr, false)
			if err != nil {
				return false, err
			}
			d, err := parseStamp(&p, map[string]*calendarZone{}, zone)
			if err != nil {
				return false, err
			}
			ok = ok && overlaps(d, nil, from, to)
		}
		for _, param := range f.Children {
			if param.XMLName.Local != "param-filter" {
				continue
			}
			values := p.Params.Values(param.attr("name"))
			if param.child(calNS, "is-not-defined") != nil {
				ok = ok && len(values) == 0
				continue
			}
			matched := len(values) > 0
			if match := param.child(calNS, "text-match"); match != nil {
				matched = false
				for _, value := range values {
					v, err := matchText(value, *match)
					if err != nil {
						return false, err
					}
					matched = matched || v
				}
			}
			ok = ok && matched
		}
		if ok {
			return true, nil
		}
	}
	return false, nil
}
func alarmMatches(c *ical.Component, i instance, from, to time.Time) (bool, error) {
	p := c.Props.Get("TRIGGER")
	if p == nil {
		return false, nil
	}
	var trigger stamp
	var err error
	if p.ValueType() == ical.ValueDuration {
		base := i.Start
		if p.Params.Get("RELATED") == "END" {
			if i.End != nil {
				base = *i.End
			} else if i.Due != nil {
				base = *i.Due
			} else {
				return false, nil
			}
		}
		trigger, err = addDuration(base, p.Value)
	} else {
		trigger, err = parseStamp(p, map[string]*calendarZone{}, i.Start.Zone)
	}
	if err != nil {
		return false, err
	}
	if overlaps(trigger, nil, from, to) {
		return true, nil
	}
	repeat := 0
	if p := c.Props.Get("REPEAT"); p != nil {
		fmt.Sscan(p.Value, &repeat)
	}
	if repeat > maxInstances {
		return false, reportFail(507, "number-of-matches-within-limits", "Alarm repeat limit exceeded")
	}
	for n := 0; n < repeat; n++ {
		p := c.Props.Get("DURATION")
		if p == nil {
			return false, fmt.Errorf("repeating alarm requires DURATION")
		}
		trigger, err = addDuration(trigger, p.Value)
		if err != nil {
			return false, err
		}
		if overlaps(trigger, nil, from, to) {
			return true, nil
		}
	}
	return false, nil
}
func calendarData(ctx context.Context, cal *ical.Calendar, req xmlNode, zone *calendarZone) (*ical.Calendar, error) {
	out := &ical.Calendar{Component: cloneComponent(cal.Component)}
	if expand := req.child(calNS, "expand"); expand != nil {
		if req.child(calNS, "limit-recurrence-set") != nil {
			return nil, reportFail(400, "valid-filter", "expand and limit-recurrence-set are mutually exclusive")
		}
		from, to, err := parseRange(expand, true)
		if err != nil {
			return nil, err
		}
		items, err := expandCalendar(ctx, cal, from, to, zone)
		if err != nil {
			return nil, reportFail(507, "number-of-matches-within-limits", err.Error())
		}
		out.Children = nil
		for _, i := range items {
			c := cloneComponent(i.Component)
			for _, name := range []string{"RRULE", "RDATE", "EXDATE", "DURATION", "RECURRENCE-ID"} {
				c.Props.Del(name)
			}
			set := func(name string, d stamp) {
				if !d.Date {
					d.Wall = d.instant()
					d.Floating = false
					d.Zone = utcZone()
				}
				c.Props.Set(d.prop(name))
			}
			if !i.Start.Wall.IsZero() {
				if i.Component.Props.Get("DTSTART") != nil {
					set("DTSTART", i.Start)
				}
				if i.End != nil {
					set("DTEND", *i.End)
				}
				if i.Due != nil {
					set("DUE", *i.Due)
				}
				if i.Recurring {
					set("RECURRENCE-ID", i.RID)
				}
			}
			zones, _ := calendarZones(cal, from.Year()-2, to.Year()+2)
			var convert func(*ical.Component)
			convert = func(n *ical.Component) {
				for name, props := range n.Props {
					for index, p := range props {
						if p.ValueType() == ical.ValueDateTime {
							d, err := parseStamp(&p, zones, zone)
							if err == nil {
								d.Wall = d.instant()
								d.Floating = false
								d.Zone = utcZone()
								q := d.prop(name)
								n.Props[name][index] = *q
							}
						}
					}
				}
				for _, child := range n.Children {
					convert(child)
				}
			}
			convert(c)
			out.Children = append(out.Children, c)
		}
	}
	if limit := req.child(calNS, "limit-recurrence-set"); limit != nil {
		from, to, err := parseRange(limit, true)
		if err != nil {
			return nil, err
		}
		zones, err := calendarZones(cal, from.Year()-2, to.Year()+2)
		if err != nil {
			return nil, err
		}
		children := []*ical.Component{}
		master := masterComponent(cal)
		var base stamp
		var end *stamp
		if master != nil {
			base, end, _, _ = componentDates(master, zones, zone)
		}
		for _, c := range out.Children {
			p := c.Props.Get("RECURRENCE-ID")
			if p == nil {
				children = append(children, c)
				continue
			}
			rid, err := parseStamp(p, zones, zone)
			if err != nil {
				return nil, err
			}
			s, e, _, err := componentDates(c, zones, zone)
			if err != nil {
				return nil, err
			}
			originalEnd := shiftEnd(base, end, rid, master)
			if overlaps(s, e, from, to) || overlaps(rid, originalEnd, from, to) {
				children = append(children, c)
			}
		}
		out.Children = children
	}
	if selectComp := req.child(calNS, "comp"); selectComp != nil {
		out.Component = selectCalendarComponent(out.Component, *selectComp)
	}
	return out, nil
}
func selectCalendarComponent(c *ical.Component, req xmlNode) *ical.Component {
	out := ical.NewComponent(c.Name)
	if req.child(calNS, "allprop") != nil {
		out.Props = cloneComponent(c).Props
	} else {
		for _, p := range req.Children {
			if p.XMLName.Local != "prop" {
				continue
			}
			name := strings.ToUpper(p.attr("name"))
			for _, v := range c.Props[name] {
				q := v
				if p.attr("novalue") == "yes" {
					q.Value = ""
				}
				out.Props.Add(&q)
			}
		}
	}
	if req.child(calNS, "allcomp") != nil {
		for _, child := range c.Children {
			out.Children = append(out.Children, cloneComponent(child))
		}
	} else {
		for _, filter := range req.Children {
			if filter.XMLName.Local != "comp" {
				continue
			}
			for _, child := range c.Children {
				if child.Name == filter.attr("name") {
					out.Children = append(out.Children, selectCalendarComponent(child, filter))
				}
			}
		}
	}
	return out
}

func (d *davBackend) put(w http.ResponseWriter, r *http.Request) error {
	media, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || media != "text/calendar" {
		return reportFail(403, "supported-calendar-data", "Content-Type must be text/calendar")
	}
	raw, err := io.ReadAll(r.Body)
	if err != nil {
		return reportFail(413, "max-resource-size", "Calendar resource is too large")
	}
	if !utf8.Valid(raw) {
		return reportFail(403, "valid-calendar-data", "Calendar data must be UTF-8")
	}
	cal, err := ical.NewDecoder(bytes.NewReader(raw)).Decode()
	if err != nil {
		return reportFail(403, "valid-calendar-data", err.Error())
	}
	result := &putResult{}
	ctx := context.WithValue(r.Context(), putResultKey{}, result)
	co, err := d.PutCalendarObject(ctx, r.URL.Path, cal, &caldav.PutCalendarObjectOptions{IfMatch: webdav.ConditionalMatch(r.Header.Get("If-Match")), IfNoneMatch: webdav.ConditionalMatch(r.Header.Get("If-None-Match"))})
	if err != nil {
		return err
	}
	canonical, err := calendarString(co.Data)
	if err != nil {
		return err
	}
	// RFC 4791 §5.3.4: a transformed PUT representation must not return an ETag.
	if canonical == string(raw) {
		w.Header().Set("ETag", `"`+co.ETag+`"`)
	}
	w.Header().Set("Location", co.Path)
	w.Header().Set("Last-Modified", co.ModTime.UTC().Format(http.TimeFormat))
	code := 201
	if result.Existing {
		code = 204
	}
	w.WriteHeader(code)
	return nil
}
func (d *davBackend) get(w http.ResponseWriter, r *http.Request) error {
	co, err := d.GetCalendarObject(r.Context(), r.URL.Path, nil)
	if err != nil {
		return err
	}
	if match := r.Header.Get("If-Match"); match != "" {
		if err := checkMatchETag(co.ETag, webdav.ConditionalMatch(match), ""); err != nil {
			return err
		}
	}
	if none := r.Header.Get("If-None-Match"); none != "" {
		matched, err := matchHTTPETags(none, co.ETag, true)
		if err != nil {
			return davError(400, err.Error())
		}
		if matched {
			w.Header().Set("ETag", `"`+co.ETag+`"`)
			w.WriteHeader(304)
			return nil
		}
	}
	raw, err := calendarString(co.Data)
	if err != nil {
		return err
	}
	w.Header().Set("Content-Type", "text/calendar; charset=utf-8")
	w.Header().Set("ETag", `"`+co.ETag+`"`)
	w.Header().Set("Last-Modified", co.ModTime.UTC().Format(http.TimeFormat))
	w.Header().Set("Content-Length", fmt.Sprint(len(raw)))
	if r.Method != "HEAD" {
		_, err = w.Write([]byte(raw))
	}
	return err
}
func (d *davBackend) freeBusy(w http.ResponseWriter, r *http.Request, req xmlNode) error {
	if r.URL.Path != calendarPath(r.Context()) {
		return reportFail(404, "valid-filter", "Calendar not found")
	}
	from, to, err := parseRange(req.child(calNS, "time-range"), true)
	if err != nil {
		return err
	}
	objects, err := d.ListCalendarObjects(r.Context(), r.URL.Path, nil)
	if err != nil {
		return err
	}
	type span struct {
		start, end time.Time
		kind       string
	}
	spans := []span{}
	bounds := []time.Time{}
	for _, co := range objects {
		items, err := expandCalendar(r.Context(), co.Data, from, to, utcZone())
		if err != nil {
			return reportFail(507, "number-of-matches-within-limits", err.Error())
		}
		for _, i := range items {
			if i.Component.Name != ical.CompEvent || i.End == nil || text(i.Component, "TRANSP") == "TRANSPARENT" || text(i.Component, "STATUS") == "CANCELLED" {
				continue
			}
			s, e := i.Start.instant(), i.End.instant()
			if s.Before(from) {
				s = from
			}
			if e.After(to) {
				e = to
			}
			if !e.After(s) {
				continue
			}
			kind := "BUSY"
			if text(i.Component, "STATUS") == "TENTATIVE" {
				kind = "BUSY-TENTATIVE"
			}
			spans = append(spans, span{s, e, kind})
			if len(spans) > maxInstances {
				return reportFail(507, "number-of-matches-within-limits", "Too many busy periods")
			}
			bounds = append(bounds, s, e)
		}
	}
	sort.Slice(bounds, func(i, j int) bool { return bounds[i].Before(bounds[j]) })
	merged := []span{}
	for i := 1; i < len(bounds); i++ {
		a, b := bounds[i-1], bounds[i]
		if !b.After(a) {
			continue
		}
		kind := ""
		for _, s := range spans {
			if s.start.Before(b) && s.end.After(a) {
				if kind == "" || s.kind == "BUSY" {
					kind = s.kind
				}
			}
		}
		if kind == "" {
			continue
		}
		if len(merged) > 0 && merged[len(merged)-1].end.Equal(a) && merged[len(merged)-1].kind == kind {
			merged[len(merged)-1].end = b
		} else {
			merged = append(merged, span{a, b, kind})
		}
	}
	cal := ical.NewCalendar()
	cal.Props.SetText("VERSION", "2.0")
	cal.Props.SetText("PRODID", "-//Spacetime//Calendar 2.0//EN")
	c := ical.NewComponent("VFREEBUSY")
	c.Props.SetText("UID", randomID()+"@spacetime")
	c.Props.SetDateTime("DTSTAMP", time.Now().UTC())
	c.Props.SetDateTime("DTSTART", from)
	c.Props.SetDateTime("DTEND", to)
	for _, s := range merged {
		p := ical.NewProp("FREEBUSY")
		p.Value = s.start.Format("20060102T150405Z") + "/" + s.end.Format("20060102T150405Z")
		p.Params.Set("FBTYPE", s.kind)
		c.Props.Add(p)
	}
	cal.Children = append(cal.Children, c)
	raw, err := calendarString(cal)
	if err != nil {
		return err
	}
	w.Header().Set("Content-Type", "text/calendar; charset=utf-8")
	_, err = w.Write([]byte(raw))
	return err
}

func nestedRange(f xmlNode) (time.Time, time.Time, bool, error) {
	var from, to time.Time
	has := false
	for _, child := range f.Children {
		if child.XMLName.Space == calNS && child.XMLName.Local == "time-range" {
			a, b, err := parseRange(&child, false)
			if err != nil {
				return from, to, false, err
			}
			if !has || a.Before(from) {
				from = a
			}
			if !has || b.After(to) {
				to = b
			}
			has = true
		} else {
			a, b, found, err := nestedRange(child)
			if err != nil {
				return from, to, false, err
			}
			if found {
				if !has || a.Before(from) {
					from = a
				}
				if !has || b.After(to) {
					to = b
				}
				has = true
			}
		}
	}
	return from, to, has, nil
}
func instanceComponent(i instance) *ical.Component {
	c := cloneComponent(i.Component)
	if !i.Start.Wall.IsZero() && c.Props.Get("DTSTART") != nil {
		c.Props.Set(i.Start.prop("DTSTART"))
	}
	if i.End != nil {
		c.Props.Set(i.End.prop("DTEND"))
	}
	if i.Due != nil {
		c.Props.Set(i.Due.prop("DUE"))
	}
	return c
}

func componentFilterNode(f caldav.CompFilter) xmlNode {
	n := xmlNode{XMLName: xml.Name{Space: calNS, Local: "comp-filter"}, Attrs: []xml.Attr{{Name: xml.Name{Local: "name"}, Value: f.Name}}}
	addRange := func(start, end time.Time) *xmlNode {
		if start.IsZero() && end.IsZero() {
			return nil
		}
		r := &xmlNode{XMLName: xml.Name{Space: calNS, Local: "time-range"}}
		if !start.IsZero() {
			r.Attrs = append(r.Attrs, xml.Attr{Name: xml.Name{Local: "start"}, Value: start.UTC().Format("20060102T150405Z")})
		}
		if !end.IsZero() {
			r.Attrs = append(r.Attrs, xml.Attr{Name: xml.Name{Local: "end"}, Value: end.UTC().Format("20060102T150405Z")})
		}
		return r
	}
	if f.IsNotDefined {
		n.Children = append(n.Children, xmlNode{XMLName: xml.Name{Space: calNS, Local: "is-not-defined"}})
	}
	if r := addRange(f.Start, f.End); r != nil {
		n.Children = append(n.Children, *r)
	}
	for _, child := range f.Comps {
		n.Children = append(n.Children, componentFilterNode(child))
	}
	for _, p := range f.Props {
		node := xmlNode{XMLName: xml.Name{Space: calNS, Local: "prop-filter"}, Attrs: []xml.Attr{{Name: xml.Name{Local: "name"}, Value: p.Name}}}
		if p.IsNotDefined {
			node.Children = append(node.Children, xmlNode{XMLName: xml.Name{Space: calNS, Local: "is-not-defined"}})
		}
		if r := addRange(p.Start, p.End); r != nil {
			node.Children = append(node.Children, *r)
		}
		if p.TextMatch != nil {
			match := xmlNode{XMLName: xml.Name{Space: calNS, Local: "text-match"}, Text: p.TextMatch.Text}
			if p.TextMatch.NegateCondition {
				match.Attrs = append(match.Attrs, xml.Attr{Name: xml.Name{Local: "negate-condition"}, Value: "yes"})
			}
			node.Children = append(node.Children, match)
		}
		for _, param := range p.ParamFilter {
			q := xmlNode{XMLName: xml.Name{Space: calNS, Local: "param-filter"}, Attrs: []xml.Attr{{Name: xml.Name{Local: "name"}, Value: param.Name}}}
			if param.IsNotDefined {
				q.Children = append(q.Children, xmlNode{XMLName: xml.Name{Space: calNS, Local: "is-not-defined"}})
			}
			if param.TextMatch != nil {
				m := xmlNode{XMLName: xml.Name{Space: calNS, Local: "text-match"}, Text: param.TextMatch.Text}
				if param.TextMatch.NegateCondition {
					m.Attrs = append(m.Attrs, xml.Attr{Name: xml.Name{Local: "negate-condition"}, Value: "yes"})
				}
				q.Children = append(q.Children, m)
			}
			node.Children = append(node.Children, q)
		}
		n.Children = append(n.Children, node)
	}
	return n
}
