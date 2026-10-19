package main

import (
	"context"
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	_ "time/tzdata"

	"github.com/emersion/go-ical"
	"github.com/teambition/rrule-go"
)

const maxInstances = 10000
const maxCandidates = 250000

var ordinalDay = regexp.MustCompile(`^([+-]?[0-9]+)?(MO|TU|WE|TH|FR|SA|SU)$`)

// Civil timestamps use UTC only as a container for wall-clock fields. Recurrences
// are generated in this space, then resolved through their timezone. This avoids
// normalizing nonexistent local times or counting them toward COUNT (5545 §3.3.10).
func civil(t time.Time) time.Time {
	return time.Date(t.Year(), t.Month(), t.Day(), t.Hour(), t.Minute(), t.Second(), 0, time.UTC)
}
func civilDay(t time.Time) time.Time {
	return time.Date(t.Year(), t.Month(), t.Day(), 0, 0, 0, 0, time.UTC)
}

type stamp struct {
	Wall           time.Time
	Zone           *calendarZone
	Date, Floating bool
}

func (d stamp) instant() time.Time {
	if d.Zone == nil {
		return time.Time{}
	}
	t, _ := d.Zone.resolve(d.Wall, false)
	return t
}
func (d stamp) key() string {
	if d.Wall.IsZero() {
		return ""
	}
	if d.Date {
		return d.Wall.Format("20060102")
	}
	if d.Floating {
		return d.Wall.Format("20060102T150405")
	}
	return d.instant().UTC().Format("20060102T150405Z")
}
func (d stamp) output() time.Time {
	if d.Date || d.Floating {
		return d.Wall
	}
	return d.instant().UTC()
}
func (d stamp) at(w time.Time) stamp { d.Wall = w; return d }
func (d stamp) prop(name string) *ical.Prop {
	p := ical.NewProp(name)
	if d.Date {
		p.SetDate(d.Wall)
	} else if d.Floating {
		p.Value = d.Wall.Format("20060102T150405")
	} else if d.Zone.ID == "UTC" {
		p.SetDateTime(d.instant().UTC())
	} else {
		p.Value = d.Wall.Format("20060102T150405")
		p.Params.Set("TZID", d.Zone.ID)
	}
	return p
}
func parseStamp(p *ical.Prop, zones map[string]*calendarZone, fallback *calendarZone) (stamp, error) {
	if p == nil {
		return stamp{}, fmt.Errorf("missing date property")
	}
	d := stamp{Zone: fallback}
	value := p.Value
	format := "20060102T150405"
	if p.ValueType() == ical.ValueDate {
		d.Date = true
		format = "20060102"
		if p.Params.Get("TZID") != "" {
			return d, fmt.Errorf("TZID is forbidden on DATE values")
		}
	} else if strings.HasSuffix(value, "Z") {
		format = "20060102T150405Z"
		d.Zone = utcZone()
		if p.Params.Get("TZID") != "" {
			return d, fmt.Errorf("TZID is forbidden on UTC values")
		}
	} else if id := p.Params.Get("TZID"); id != "" {
		z, ok := zones[id]
		if !ok {
			var err error
			z, err = ianaZone(id)
			if err != nil {
				return d, err
			}
			zones[id] = z
		}
		d.Zone = z
	} else {
		d.Floating = true
	}
	// RFC 5545 §3.3.5 permits implementations without leap seconds to treat 60 as 59.
	if len(value) >= 15 && value[13:15] == "60" {
		value = value[:13] + "59" + value[15:]
	}
	w, err := time.Parse(format, value)
	if err != nil {
		return d, fmt.Errorf("invalid %s: %w", p.Name, err)
	}
	d.Wall = civil(w)
	return d, nil
}

type ruleSpec struct {
	Raw    string
	Option rrule.ROption
	Count  int
	Until  *stamp
}

func parseRule(raw string, start stamp) (ruleSpec, error) {
	spec := ruleSpec{Raw: strings.ToUpper(strings.TrimSpace(raw))}
	if spec.Raw == "" {
		return spec, nil
	}
	parts := map[string]string{}
	for _, piece := range strings.Split(spec.Raw, ";") {
		pair := strings.SplitN(piece, "=", 2)
		if len(pair) != 2 || pair[1] == "" {
			return spec, fmt.Errorf("malformed RRULE part %q", piece)
		}
		if _, exists := parts[pair[0]]; exists {
			return spec, fmt.Errorf("duplicate RRULE part %s", pair[0])
		}
		parts[pair[0]] = pair[1]
	}
	freq, err := rrule.StrToFreq(parts["FREQ"])
	if err != nil {
		return spec, fmt.Errorf("RRULE requires a valid FREQ")
	}
	if parts["COUNT"] != "" && parts["UNTIL"] != "" {
		return spec, fmt.Errorf("COUNT and UNTIL cannot appear together")
	}
	for k, v := range parts {
		switch k {
		case "FREQ", "UNTIL", "BYDAY", "WKST":
		case "INTERVAL", "COUNT":
			n, e := strconv.ParseInt(v, 10, 32)
			if e != nil || n < 1 {
				return spec, fmt.Errorf("%s must be a positive 32-bit integer", k)
			}
		case "BYSECOND", "BYMINUTE", "BYHOUR", "BYMONTHDAY", "BYYEARDAY", "BYWEEKNO", "BYMONTH", "BYSETPOS":
			bounds := map[string][2]int{"BYSECOND": {0, 60}, "BYMINUTE": {0, 59}, "BYHOUR": {0, 23}, "BYMONTHDAY": {-31, 31}, "BYYEARDAY": {-366, 366}, "BYWEEKNO": {-53, 53}, "BYMONTH": {1, 12}, "BYSETPOS": {-366, 366}}
			for _, s := range strings.Split(v, ",") {
				n, e := strconv.ParseInt(s, 10, 32)
				b := bounds[k]
				if e != nil || n < int64(b[0]) || n > int64(b[1]) || (n == 0 && (k == "BYMONTHDAY" || k == "BYYEARDAY" || k == "BYWEEKNO" || k == "BYSETPOS")) {
					return spec, fmt.Errorf("invalid %s value %q", k, s)
				}
			}
		default:
			return spec, fmt.Errorf("unsupported RRULE part %s", k)
		}
	}
	if start.Date && (parts["BYHOUR"] != "" || parts["BYMINUTE"] != "" || parts["BYSECOND"] != "" || freq >= rrule.HOURLY) {
		return spec, fmt.Errorf("DATE recurrences cannot use clock-time rule parts")
	}
	if parts["BYMONTHDAY"] != "" && freq == rrule.WEEKLY {
		return spec, fmt.Errorf("BYMONTHDAY is not valid with WEEKLY")
	}
	if parts["BYYEARDAY"] != "" && (freq == rrule.DAILY || freq == rrule.WEEKLY || freq == rrule.MONTHLY) {
		return spec, fmt.Errorf("BYYEARDAY is not valid at this frequency")
	}
	if parts["BYWEEKNO"] != "" && freq != rrule.YEARLY {
		return spec, fmt.Errorf("BYWEEKNO requires YEARLY")
	}
	if parts["BYSETPOS"] != "" {
		has := false
		for k := range parts {
			if strings.HasPrefix(k, "BY") && k != "BYSETPOS" {
				has = true
			}
		}
		if !has {
			return spec, fmt.Errorf("BYSETPOS requires another BY part")
		}
	}
	if v := parts["BYDAY"]; v != "" {
		for _, s := range strings.Split(v, ",") {
			m := ordinalDay.FindStringSubmatch(s)
			if m == nil {
				return spec, fmt.Errorf("invalid BYDAY %s", s)
			}
			if m[1] != "" {
				n, e := strconv.Atoi(m[1])
				if e != nil || n == 0 || n > 53 || n < -53 || (freq != rrule.MONTHLY && freq != rrule.YEARLY) || (freq == rrule.YEARLY && parts["BYWEEKNO"] != "") {
					return spec, fmt.Errorf("ordinal BYDAY is invalid for this rule")
				}
			}
		}
	}
	if v := parts["WKST"]; v != "" && !regexp.MustCompile(`^(MO|TU|WE|TH|FR|SA|SU)$`).MatchString(v) {
		return spec, fmt.Errorf("invalid week start")
	}
	generator := []string{}
	for _, piece := range strings.Split(spec.Raw, ";") {
		k := strings.SplitN(piece, "=", 2)[0]
		if k == "COUNT" {
			spec.Count, _ = strconv.Atoi(parts[k])
			continue
		}
		if k == "UNTIL" {
			p := ical.NewProp("UNTIL")
			p.Value = parts[k]
			if start.Date {
				p.SetValueType(ical.ValueDate)
				if len(p.Value) != 8 {
					return spec, fmt.Errorf("DATE DTSTART requires a DATE UNTIL")
				}
			} else if start.Floating {
				if len(p.Value) != 15 {
					return spec, fmt.Errorf("floating DTSTART requires a floating UNTIL")
				}
			} else if len(p.Value) != 16 || !strings.HasSuffix(p.Value, "Z") {
				return spec, fmt.Errorf("zoned DTSTART requires a UTC UNTIL")
			}
			u, e := parseStamp(p, map[string]*calendarZone{}, start.Zone)
			if e != nil {
				return spec, e
			}
			spec.Until = &u
			continue
		}
		if k == "BYSECOND" {
			values := strings.Split(parts[k], ",")
			for i, v := range values {
				if v == "60" {
					values[i] = "59"
				}
			}
			piece = k + "=" + strings.Join(values, ",")
		}
		generator = append(generator, piece)
	}
	opt, err := rrule.StrToROption(strings.Join(generator, ";"))
	if err != nil {
		return spec, err
	}
	opt.Dtstart = start.Wall
	unique := func(values []int) []int {
		seen := map[int]bool{}
		out := []int{}
		for _, v := range values {
			if !seen[v] {
				out = append(out, v)
				seen[v] = true
			}
		}
		sort.Ints(out)
		return out
	}
	opt.Byhour = unique(opt.Byhour)
	opt.Byminute = unique(opt.Byminute)
	opt.Bysecond = unique(opt.Bysecond)
	opt.Bymonth = unique(opt.Bymonth)
	opt.Bymonthday = unique(opt.Bymonthday)
	opt.Byyearday = unique(opt.Byyearday)
	opt.Byweekno = unique(opt.Byweekno)
	opt.Bysetpos = unique(opt.Bysetpos)
	spec.Option = *opt
	if _, err = rrule.NewRRule(*opt); err != nil {
		return spec, err
	}
	return spec, nil
}

// Fast-forward only rules without COUNT; preserve every default inherited from
// DTSTART and the phase of INTERVAL/WKST. COUNT rules must count from their origin.
func seekRule(opt rrule.ROption, lower time.Time) rrule.ROption {
	original := opt.Dtstart
	if !lower.After(original) {
		return opt
	}
	built, _ := rrule.NewRRule(opt)
	defaults := built.Options
	opt.Bymonth = defaults.Bymonth
	opt.Bymonthday = defaults.Bymonthday
	opt.Byweekday = defaults.Byweekday
	opt.Byhour = defaults.Byhour
	opt.Byminute = defaults.Byminute
	opt.Bysecond = defaults.Bysecond
	step := opt.Interval
	if step == 0 {
		step = 1
	}
	n := 0
	switch opt.Freq {
	case rrule.YEARLY:
		n = (lower.Year()-original.Year())/step - 1
		if n > 0 {
			opt.Dtstart = original.AddDate(n*step, 0, 0)
		}
	case rrule.MONTHLY:
		n = ((lower.Year()-original.Year())*12+int(lower.Month()-original.Month()))/step - 1
		if n > 0 {
			base := time.Date(original.Year(), original.Month(), 1, original.Hour(), original.Minute(), original.Second(), 0, time.UTC)
			opt.Dtstart = base.AddDate(0, n*step, 0)
		}
	case rrule.WEEKLY, rrule.DAILY:
		days := int(lower.Sub(original).Hours() / 24)
		scale := 1
		if opt.Freq == rrule.WEEKLY {
			scale = 7
		}
		n = days/(step*scale) - 1
		if n > 0 {
			opt.Dtstart = original.AddDate(0, 0, n*step*scale)
		}
	default:
		unit := time.Second
		if opt.Freq == rrule.MINUTELY {
			unit = time.Minute
		}
		if opt.Freq == rrule.HOURLY {
			unit = time.Hour
		}
		interval := unit * time.Duration(step)
		n = int(lower.Sub(original)/interval) - 1
		if n > 0 {
			opt.Dtstart = original.Add(time.Duration(n) * interval)
		}
	}
	return opt
}
func ruleDates(ctx context.Context, spec ruleSpec, start stamp, lower, upper time.Time, limit int) ([]stamp, error) {
	if spec.Raw == "" {
		return nil, nil
	}
	opt := spec.Option
	opt.Count = 0
	// Upper bound is deliberately explicit: rrule-go otherwise silently stops at ~290 years.
	opt.Until = civil(upper.In(start.Zone.location())).AddDate(0, 0, 3)
	if start.Zone.custom() {
		opt.Until = civil(upper).AddDate(0, 0, 3)
	}
	if spec.Count == 0 {
		opt = seekRule(opt, civil(lower.In(start.Zone.location())).AddDate(0, 0, -3))
	}
	r, err := rrule.NewRRule(opt)
	if err != nil {
		return nil, err
	}
	next := r.Iterator()
	out := []stamp{}
	count := 0
	if _, valid := start.Zone.resolve(start.Wall, true); !valid {
		count = 1
	}
	for i := 0; ; i++ {
		if i > maxCandidates {
			return nil, fmt.Errorf("recurrence candidate limit exceeded; narrow the requested time range")
		}
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		wall, ok := next()
		if !ok {
			break
		}
		d := start.at(wall)
		instant, valid := start.Zone.resolve(wall, true)
		if !valid {
			continue
		}
		if spec.Until != nil && instant.After(spec.Until.instant()) {
			break
		}
		count++
		if spec.Count > 0 && count > spec.Count {
			break
		}
		if !instant.Before(lower) && instant.Before(upper) {
			out = append(out, d)
			if len(out) > limit {
				return nil, fmt.Errorf("recurrence result limit exceeded; narrow the requested time range")
			}
		}
	}
	return out, nil
}

type instance struct {
	Component *ical.Component
	Start     stamp
	End       *stamp
	Due       *stamp
	RID       stamp
	Recurring bool
}

func cloneComponent(c *ical.Component) *ical.Component {
	n := ical.NewComponent(c.Name)
	for k, props := range c.Props {
		for _, p := range props {
			q := ical.NewProp(k)
			q.Value = p.Value
			for key, v := range p.Params {
				q.Params[key] = append([]string(nil), v...)
			}
			n.Props.Add(q)
		}
	}
	for _, child := range c.Children {
		n.Children = append(n.Children, cloneComponent(child))
	}
	return n
}
func text(c *ical.Component, name string) string { s, _ := c.Props.Text(name); return s }
func masterComponent(cal *ical.Calendar) *ical.Component {
	for _, c := range cal.Children {
		if (c.Name == ical.CompEvent || c.Name == ical.CompToDo) && c.Props.Get(ical.PropRecurrenceID) == nil {
			return c
		}
	}
	return nil
}
func componentDates(c *ical.Component, zones map[string]*calendarZone, zone *calendarZone) (stamp, *stamp, *stamp, error) {
	p := c.Props.Get(ical.PropDateTimeStart)
	if p == nil {
		p = c.Props.Get(ical.PropDue)
	}
	if p == nil {
		return stamp{}, nil, nil, fmt.Errorf("component has no DTSTART or DUE")
	}
	start, err := parseStamp(p, zones, zone)
	if err != nil {
		return start, nil, nil, err
	}
	var end, due *stamp
	for name, target := range map[string]**stamp{ical.PropDateTimeEnd: &end, ical.PropDue: &due} {
		if p := c.Props.Get(name); p != nil {
			d, e := parseStamp(p, zones, zone)
			if e != nil {
				return start, nil, nil, e
			}
			*target = &d
		}
	}
	if c.Name == ical.CompToDo && due == nil && c.Props.Get(ical.PropDuration) != nil {
		d, err := addDuration(start, c.Props.Get(ical.PropDuration).Value)
		if err != nil {
			return start, nil, nil, err
		}
		due = &d
	}
	if end == nil && c.Name == ical.CompEvent {
		d := start
		if p := c.Props.Get(ical.PropDuration); p != nil {
			w, err := addDuration(start, p.Value)
			if err != nil {
				return start, nil, nil, err
			}
			d = w
		} else if start.Date {
			d.Wall = d.Wall.AddDate(0, 0, 1)
		}
		end = &d
	}
	return start, end, due, nil
}

// RFC duration days/weeks are nominal calendar units; hours/minutes/seconds are
// exact elapsed units. DTEND/DUE, in contrast, define an exact repeated duration.
var durationRE = regexp.MustCompile(`^([+-])?P(?:(\d+)W|(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?)$`)

func addDuration(start stamp, raw string) (stamp, error) {
	m := durationRE.FindStringSubmatch(raw)
	if m == nil || raw == "P" || raw == "PT" {
		return start, fmt.Errorf("invalid DURATION")
	}
	nums := []int{}
	for _, v := range m[2:] {
		n, _ := strconv.Atoi(v)
		nums = append(nums, n)
	}
	sign := 1
	if m[1] == "-" {
		sign = -1
	}
	d := start
	d.Wall = d.Wall.AddDate(0, 0, sign*(nums[0]*7+nums[1]))
	seconds := sign * (nums[2]*3600 + nums[3]*60 + nums[4])
	if start.Date || start.Floating {
		d.Wall = d.Wall.Add(time.Duration(seconds) * time.Second)
	} else {
		t := d.instant().Add(time.Duration(seconds) * time.Second)
		d.Wall = d.Zone.wall(t)
	}
	return d, nil
}
func shiftEnd(original stamp, end *stamp, target stamp, c *ical.Component) *stamp {
	if end == nil {
		return nil
	}
	d := *end
	if p := c.Props.Get(ical.PropDuration); p != nil {
		v, _ := addDuration(target, p.Value)
		return &v
	}
	if original.Date || original.Floating {
		d.Wall = target.Wall.Add(end.Wall.Sub(original.Wall))
	} else {
		d.Wall = d.Zone.wall(target.instant().Add(end.instant().Sub(original.instant())))
	}
	return &d
}
func overlaps(start stamp, end *stamp, from, to time.Time) bool {
	s := start.instant()
	if end == nil || end.instant().Equal(s) {
		return !s.Before(from) && s.Before(to)
	}
	return s.Before(to) && end.instant().After(from)
}
func expandCalendar(ctx context.Context, cal *ical.Calendar, from, to time.Time, viewZone *calendarZone) ([]instance, error) {
	zones, err := calendarZones(cal, from.Year()-2, to.Year()+2)
	if err != nil {
		return nil, err
	}
	master := masterComponent(cal)
	out := []instance{}
	if master == nil {
		for _, c := range cal.Children {
			if c.Name != ical.CompEvent && c.Name != ical.CompToDo {
				continue
			}
			s, e, d, err := componentDates(c, zones, viewZone)
			if err != nil {
				return nil, err
			}
			rid := s
			if p := c.Props.Get(ical.PropRecurrenceID); p != nil {
				rid, err = parseStamp(p, zones, viewZone)
				if err != nil {
					return nil, err
				}
			}
			if text(c, ical.PropStatus) != "CANCELLED" && overlaps(s, e, from, to) {
				out = append(out, instance{c, s, e, d, rid, true})
			}
		}
		return out, nil
	}
	start, end, due, err := componentDates(master, zones, viewZone)
	if err != nil {
		// An undated VTODO is legal and matches every CalDAV time range (4791 §9.9).
		if master.Name == ical.CompToDo && master.Props.Get(ical.PropDateTimeStart) == nil && master.Props.Get(ical.PropDue) == nil {
			i := instance{Component: master}
			if ctx.Value(caldavRangeKey{}) == true && !todoOverlaps(i, from, to, viewZone) {
				return []instance{}, nil
			}
			return []instance{i}, nil
		}
		return nil, err
	}
	rule := master.Props.Get(ical.PropRecurrenceRule)
	raw := ""
	if rule != nil {
		raw = rule.Value
	}
	spec, err := parseRule(raw, start)
	if err != nil {
		return nil, err
	}
	recurring := rule != nil || len(master.Props[ical.PropRecurrenceDates]) > 0 || len(master.Props[ical.PropExceptionDates]) > 0
	dates := map[string]stamp{start.key(): start}
	periodEnds := map[string]stamp{}
	// Include starts before the window when their event or task duration overlaps it.
	lookback := time.Duration(0)
	for _, v := range []*stamp{end, due} {
		if v != nil {
			d := v.instant().Sub(start.instant())
			if d > lookback {
				lookback = d
			}
		}
	}
	lower := from.Add(-lookback).AddDate(0, 0, -2)
	upper := to.AddDate(0, 0, 2)
	// A detached THISANDFUTURE exception can shift instances across the query edges.
	overrides := map[string]*ical.Component{}
	ranges := []instance{}
	for _, c := range cal.Children {
		p := c.Props.Get(ical.PropRecurrenceID)
		if c.Name != master.Name || p == nil {
			continue
		}
		rid, err := parseStamp(p, zones, viewZone)
		if err != nil {
			return nil, err
		}
		overrides[rid.key()] = c
		if p.Params.Get("RANGE") == "THISANDFUTURE" {
			s, e, d, err := componentDates(c, zones, viewZone)
			if err != nil {
				return nil, err
			}
			ranges = append(ranges, instance{c, s, e, d, rid, true})
			shift := s.instant().Sub(rid.instant())
			if shift > 0 {
				lower = lower.Add(-shift)
			} else {
				upper = upper.Add(-shift)
			}
		}
	}
	generated, err := ruleDates(ctx, spec, start, lower, upper, maxInstances)
	if err != nil {
		return nil, err
	}
	for _, d := range generated {
		dates[d.key()] = d
	}
	for _, p := range master.Props[ical.PropRecurrenceDates] {
		for _, value := range strings.Split(p.Value, ",") {
			q := p
			q.Params = ical.Params{}
			for k, v := range p.Params {
				q.Params[k] = append([]string(nil), v...)
			}
			q.Value = value
			if p.ValueType() == ical.ValuePeriod {
				pair := strings.SplitN(value, "/", 2)
				if len(pair) != 2 {
					return nil, fmt.Errorf("invalid RDATE PERIOD")
				}
				q.Value = pair[0]
				q.SetValueType(ical.ValueDateTime)
				s, err := parseStamp(&q, zones, viewZone)
				if err != nil {
					return nil, err
				}
				var e stamp
				if strings.HasPrefix(pair[1], "P") {
					e, err = addDuration(s, pair[1])
				} else {
					q.Value = pair[1]
					e, err = parseStamp(&q, zones, viewZone)
				}
				if err != nil || !e.instant().After(s.instant()) {
					return nil, fmt.Errorf("invalid RDATE period end")
				}
				dates[s.key()] = s
				periodEnds[s.key()] = e
			} else {
				d, err := parseStamp(&q, zones, viewZone)
				if err != nil {
					return nil, err
				}
				if d.Date != start.Date {
					return nil, fmt.Errorf("RDATE and DTSTART types must match")
				}
				dates[d.key()] = d
			}
		}
	}
	excluded := map[string]bool{}
	// EXRULE is obsolete in RFC 5545, but imported RFC 2445 resources retain its meaning.
	for _, p := range master.Props["EXRULE"] {
		spec, err := parseRule(p.Value, start)
		if err != nil {
			return nil, err
		}
		dates, err := ruleDates(ctx, spec, start, lower, upper, maxInstances)
		if err != nil {
			return nil, err
		}
		for _, d := range dates {
			excluded[d.key()] = true
		}
	}
	for _, p := range master.Props[ical.PropExceptionDates] {
		for _, value := range strings.Split(p.Value, ",") {
			q := p
			q.Value = value
			d, err := parseStamp(&q, zones, viewZone)
			if err != nil {
				return nil, err
			}
			if d.Date != start.Date {
				return nil, fmt.Errorf("EXDATE and DTSTART types must match")
			}
			excluded[d.key()] = true
		}
	}
	sort.Slice(ranges, func(i, j int) bool { return ranges[i].RID.instant().Before(ranges[j].RID.instant()) })
	// Detached components are independently considered, including moved instances
	// whose original RECURRENCE-ID is outside the requested window.
	for key, c := range overrides {
		if excluded[key] {
			delete(dates, key)
			continue
		}
		rid, err := parseStamp(c.Props.Get(ical.PropRecurrenceID), zones, viewZone)
		if err != nil {
			return nil, err
		}
		if text(c, ical.PropStatus) == "CANCELLED" && ctx.Value(caldavRangeKey{}) != true {
			delete(dates, key)
			continue
		}
		s, e, d, err := componentDates(c, zones, viewZone)
		if err != nil {
			return nil, err
		}
		if overlaps(s, e, from, to) || (c.Name == ical.CompToDo && d != nil && overlaps(*d, nil, from, to)) {
			out = append(out, instance{c, s, e, d, rid, true})
		}
		delete(dates, key)
	}
	for key, d := range dates {
		if excluded[key] {
			continue
		}
		c := master
		s := d
		e := shiftEnd(start, end, d, master)
		dueAt := shiftEnd(start, due, d, master)
		if p, ok := periodEnds[key]; ok {
			e = &p
		}
		for _, r := range ranges {
			if !d.instant().Before(r.RID.instant()) {
				c = r.Component
				shift := r.Start.Wall.Sub(r.RID.Wall)
				s = d.at(d.Wall.Add(shift))
				e = shiftEnd(r.Start, r.End, s, r.Component)
				dueAt = shiftEnd(r.Start, r.Due, s, r.Component)
			}
		}
		if text(c, ical.PropStatus) == "CANCELLED" && ctx.Value(caldavRangeKey{}) != true {
			continue
		}
		matches := overlaps(s, e, from, to)
		if c.Name == ical.CompToDo && dueAt != nil {
			matches = overlaps(*dueAt, nil, from, to)
		}
		if c.Name == ical.CompToDo && ctx.Value(caldavRangeKey{}) == true {
			matches = todoOverlaps(instance{c, s, e, dueAt, d, recurring}, from, to, viewZone)
		}
		if matches {
			out = append(out, instance{c, s, e, dueAt, d, recurring})
			if len(out) > maxInstances {
				return nil, fmt.Errorf("recurrence result limit exceeded")
			}
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Start.instant().Before(out[j].Start.instant()) })
	return out, nil
}

type caldavRangeKey struct{}

func todoOverlaps(i instance, from, to time.Time, zone *calendarZone) bool {
	c := i.Component
	s := i.Start.instant()
	if c.Props.Get("DTSTART") != nil {
		if c.Props.Get("DURATION") != nil && i.Due != nil {
			end := i.Due.instant()
			return !from.After(end) && (to.After(s) || !to.Before(end))
		}
		if i.Due != nil {
			due := i.Due.instant()
			return (from.Before(due) || !from.After(s)) && (to.After(s) || !to.Before(due))
		}
		return !from.After(s) && to.After(s)
	}
	if i.Due != nil {
		due := i.Due.instant()
		return from.Before(due) && !to.Before(due)
	}
	get := func(name string) *time.Time {
		p := c.Props.Get(name)
		if p == nil {
			return nil
		}
		d, err := parseStamp(p, map[string]*calendarZone{}, zone)
		if err != nil {
			return nil
		}
		v := d.instant()
		return &v
	}
	completed, created := get("COMPLETED"), get("CREATED")
	if completed != nil && created != nil {
		return (!from.After(*created) || !from.After(*completed)) && (!to.Before(*created) || !to.Before(*completed))
	}
	if completed != nil {
		return !from.After(*completed) && !to.Before(*completed)
	}
	if created != nil {
		return to.After(*created)
	}
	return true
}

// nextRecurrenceID is used when an individual edit splits an existing
// THISANDFUTURE range. Its replacement range begins at the next original RID.
func nextRecurrenceID(ctx context.Context, master *ical.Component, start, after stamp, zones map[string]*calendarZone) (*stamp, error) {
	var best *stamp
	choose := func(d stamp) {
		if d.instant().After(after.instant()) && (best == nil || d.instant().Before(best.instant())) {
			copy := d
			best = &copy
		}
	}
	if p := master.Props.Get("RRULE"); p != nil {
		spec, err := parseRule(p.Value, start)
		if err != nil {
			return nil, err
		}
		opt := spec.Option
		opt.Until = time.Date(9999, 12, 31, 23, 59, 59, 0, time.UTC)
		if spec.Count == 0 {
			opt = seekRule(opt, after.Wall)
		}
		r, err := rrule.NewRRule(opt)
		if err != nil {
			return nil, err
		}
		next := r.Iterator()
		count := 0
		for n := 0; n < maxCandidates; n++ {
			if err := ctx.Err(); err != nil {
				return nil, err
			}
			w, ok := next()
			if !ok {
				break
			}
			d := start.at(w)
			t, valid := d.Zone.resolve(w, true)
			if !valid {
				continue
			}
			if spec.Until != nil && t.After(spec.Until.instant()) {
				break
			}
			count++
			if spec.Count > 0 && count > spec.Count {
				break
			}
			if t.After(after.instant()) {
				choose(d)
				break
			}
		}
	}
	for _, p := range master.Props["RDATE"] {
		for _, value := range strings.Split(p.Value, ",") {
			q := p
			q.Value = strings.SplitN(value, "/", 2)[0]
			q.Params = ical.Params{}
			for k, v := range p.Params {
				q.Params[k] = append([]string(nil), v...)
			}
			if p.ValueType() == ical.ValuePeriod {
				q.SetValueType(ical.ValueDateTime)
			}
			d, err := parseStamp(&q, zones, start.Zone)
			if err != nil {
				return nil, err
			}
			choose(d)
		}
	}
	return best, nil
}
