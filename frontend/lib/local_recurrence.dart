import 'local_icalendar.dart' show parseIcalDuration;
import 'package:rrule/rrule.dart';
import 'package:timezone/data/latest_all.dart' as database;
import 'package:timezone/timezone.dart' as tz;

bool _zonesReady = false;
void initializeCalendarZones() {
  if (_zonesReady) return;
  database.initializeTimeZones();
  _zonesReady = true;
}

DateTime wallTime(DateTime d) =>
    DateTime.utc(d.year, d.month, d.day, d.hour, d.minute, d.second);
DateTime parseWall(String value) {
  final m = RegExp(
    r'^(\d{4})-?(\d{2})-?(\d{2})(?:T(\d{2}):?(\d{2})(?::?(\d{2}))?(?:\.\d+)?)?Z?$',
  ).firstMatch(value);
  if (m == null) {
    throw const FormatException('Use an iCalendar date or local date-time.');
  }
  final y = int.parse(m[1]!), month = int.parse(m[2]!), d = int.parse(m[3]!);
  final h = int.tryParse(m[4] ?? '') ?? 0,
      minute = int.tryParse(m[5] ?? '') ?? 0;
  final second = int.tryParse(m[6] ?? '') ?? 0;
  final result = DateTime.utc(
    y,
    month,
    d,
    h,
    minute,
    second == 60 ? 59 : second,
  );
  if (result.year != y ||
      result.month != month ||
      result.day != d ||
      h > 23 ||
      minute > 59 ||
      second > 60) {
    throw const FormatException('Invalid calendar date or time.');
  }
  return result;
}

RecurrenceRule parseRecurrenceRule(String raw) {
  final parts = ruleParts(raw);
  final freq = parts['FREQ'];
  bool has(String key) => parts.containsKey(key);
  if (has('BYMONTHDAY') && freq == 'WEEKLY' ||
      has('BYYEARDAY') && ['DAILY', 'WEEKLY', 'MONTHLY'].contains(freq) ||
      has('BYWEEKNO') && freq != 'YEARLY' ||
      has('BYSETPOS') &&
          !parts.keys.any((k) => k.startsWith('BY') && k != 'BYSETPOS')) {
    throw const FormatException(
      'Invalid recurrence selector for this frequency.',
    );
  }
  for (final day in (parts['BYDAY'] ?? '').split(',')) {
    if (RegExp(r'^[+-]?\d').hasMatch(day) &&
        (!['MONTHLY', 'YEARLY'].contains(freq) ||
            freq == 'YEARLY' && has('BYWEEKNO'))) {
      throw const FormatException(
        'Ordinal weekdays require a monthly or yearly recurrence.',
      );
    }
  }
  for (final key in ['COUNT', 'INTERVAL']) {
    final n = int.tryParse(parts[key] ?? '');
    if (n != null && (n < 1 || n > 2147483647)) {
      throw const FormatException(
        'Use a positive 32-bit repeat count or interval.',
      );
    }
  }
  // RFC 5545 permits leap second 60; this clock uses the mandated 59 fallback.
  final adapted = raw
      .split(';')
      .map(
        (p) =>
            p.startsWith('BYSECOND=')
                ? 'BYSECOND=${p.substring(9).split(',').map((v) => v == '60' ? '59' : v).toSet().join(',')}'
                : p,
      )
      .join(';');
  return RecurrenceRule.fromString('RRULE:$adapted');
}

String wallString(DateTime d, bool allDay) =>
    d.toIso8601String().substring(0, allDay ? 10 : 19);
String compactStamp(DateTime d, bool allDay, {bool utc = false}) =>
    '${wallString(d, allDay).replaceAll('-', '').replaceAll(':', '')}${utc ? 'Z' : ''}';

class _ZoneTransition {
  final DateTime at;
  final int before, after;
  _ZoneTransition(this.at, this.before, this.after);
}

CalendarZone eventZone(Map<String, dynamic> event) => CalendarZone(
  event['all_day'] == true ? 'UTC' : event['timezone'] as String? ?? 'UTC',
  observations: (event['_timezones'] as Map?)?[event['timezone']] as List?,
);

class CalendarZone {
  final String name;
  final List? observations;
  tz.Location? location;
  final Map<int, List<_ZoneTransition>> _cache = {};
  CalendarZone(this.name, {this.observations}) {
    initializeCalendarZones();
    if (observations == null || observations!.isEmpty) {
      location = tz.getLocation(name == 'floating' ? 'UTC' : name);
    }
  }
  List<_ZoneTransition> _transitions(int year) => _cache.putIfAbsent(year, () {
    final result = <_ZoneTransition>[];
    for (final raw in observations!) {
      final o = raw as Map;
      final start = parseWall(o['start'] as String);
      final before = o['from'] as int, after = o['to'] as int;
      final points = <DateTime>{
        start,
        ...(o['rdates'] as List).map((d) => parseWall(d as String)),
      };
      if ((o['rrule'] as String).isNotEmpty) {
        final parts = ruleParts(o['rrule'] as String);
        final until = parts.remove('UNTIL');
        for (final w in RecurrenceRule.fromString(
          'RRULE:${parts.entries.map((p) => '${p.key}=${p.value}').join(';')}',
        ).getInstances(
          start: start,
          before: DateTime.utc((year + 2).clamp(start.year + 1, 10000)),
          includeBefore: true,
        )) {
          if (until != null &&
              w
                  .subtract(Duration(seconds: before))
                  .isAfter(DateTime.parse(until).toUtc())) {
            break;
          }
          points.add(w);
        }
      }
      for (final w in points) {
        result.add(
          _ZoneTransition(w.subtract(Duration(seconds: before)), before, after),
        );
      }
    }
    result.sort((a, b) => a.at.compareTo(b.at));
    return result;
  });
  DateTime wall(DateTime instant) {
    if (location != null) {
      return wallTime(tz.TZDateTime.from(instant, location!));
    }
    final transitions = _transitions(instant.year);
    var offset = transitions.first.before;
    for (final t in transitions) {
      if (t.at.isAfter(instant)) break;
      offset = t.after;
    }
    return wallTime(instant.toUtc().add(Duration(seconds: offset)));
  }

  // RFC 5545: folds select the first instant. Generated gaps are not counted.
  DateTime? resolve(DateTime value, {bool generated = false}) {
    final offsets =
        location != null
            ? location!.zones.map((z) => z.offset).toSet()
            : observations!
                .expand(
                  (o) => [
                    ((o as Map)['from'] as int) * 1000,
                    (o['to'] as int) * 1000,
                  ],
                )
                .toSet();
    final matches = <DateTime>[];
    for (final offset in offsets) {
      final candidate = DateTime.fromMillisecondsSinceEpoch(
        value.millisecondsSinceEpoch - offset,
        isUtc: true,
      );
      if (wall(candidate) == value) matches.add(candidate);
    }
    if (matches.isNotEmpty) {
      matches.sort();
      return matches.first;
    }
    if (generated) return null;
    if (location != null) {
      return tz.TZDateTime(
        location!,
        value.year,
        value.month,
        value.day,
        value.hour,
        value.minute,
        value.second,
      ).toUtc();
    }
    for (final t in _transitions(value.year)) {
      final first = t.at.add(Duration(seconds: t.before)),
          last = t.at.add(Duration(seconds: t.after));
      if (!value.isBefore(first) && value.isBefore(last)) {
        return value.subtract(Duration(seconds: t.before));
      }
    }
    throw FormatException('Cannot resolve time zone $name.');
  }
}

Map<String, String> ruleParts(String rule) => {
  for (final part in rule.split(';').where((s) => s.isNotEmpty))
    part.split('=')[0].toUpperCase():
        part.split('=').skip(1).join('=').toUpperCase(),
};

/// A recurrence set is evaluated in civil coordinates, then resolved to instants.
/// COUNT applies after discarding DST gaps, before EXDATE removes instances.
Iterable<DateTime> recurrenceDates(
  Map<String, dynamic> event,
  DateTime before, {
  DateTime? after,
  int? limit,
}) sync* {
  final allDay = event['all_day'] == true;
  final zone = eventZone(event);
  final rawStart =
      event['start_local'] as String? ?? event['due_local'] as String?;
  final rawInstant = event['start'] as String? ?? event['due'] as String?;
  if (rawStart == null && rawInstant == null) return;
  final start =
      rawStart != null
          ? parseWall(rawStart)
          : zone.wall(DateTime.parse(rawInstant!));
  final rawRule = event['rrule'] as String? ?? '';
  final parts = ruleParts(rawRule);
  final count = int.tryParse(parts.remove('COUNT') ?? '');
  final untilRaw = parts.remove('UNTIL');
  DateTime? until;
  if (untilRaw != null) {
    final d = DateTime.parse(untilRaw);
    until =
        untilRaw.endsWith('Z') || allDay
            ? d.toUtc()
            : zone.resolve(wallTime(d));
  }
  final generated =
      rawRule.isEmpty
          ? <DateTime>[]
          : parseRecurrenceRule(
            parts.entries.map((e) => '${e.key}=${e.value}').join(';'),
          ).getInstances(
            start: start,
            after:
                count == null && after != null && after.isAfter(start)
                    ? after
                    : null,
            includeAfter: true,
            before: before.isBefore(start) ? start : before,
            includeBefore: true,
          );
  var accepted = 0, emitted = 0;
  final dates = <int, DateTime>{};
  // DTSTART belongs to the set even without RRULE; EXDATE can remove it.
  if (rawRule.isEmpty) dates[start.millisecondsSinceEpoch] = start;
  for (final w in generated) {
    final instant = zone.resolve(
      w,
      generated: !allDay && zone.name != 'floating',
    );
    if (instant == null) continue;
    if (until != null && instant.isAfter(until)) break;
    accepted++;
    if (count != null && accepted > count) break;
    dates[w.millisecondsSinceEpoch] = w;
    if (limit != null && dates.length >= limit) break;
  }
  for (final raw in event['rdates'] as List? ?? []) {
    final value = (raw as String).split('/').first;
    final d = DateTime.parse(value);
    final w = value.endsWith('Z') && !allDay ? zone.wall(d) : wallTime(d);
    dates[w.millisecondsSinceEpoch] = w;
  }
  final excluded = <int>{};
  for (final raw in event['exdates'] as List? ?? []) {
    final value = raw as String;
    final d = DateTime.parse(value);
    final w = value.endsWith('Z') && !allDay ? zone.wall(d) : wallTime(d);
    excluded.add(w.millisecondsSinceEpoch);
  }
  final sorted = dates.values.toList()..sort();
  for (final w in sorted) {
    if (w.isAfter(before) ||
        (after != null && w.isBefore(after)) ||
        excluded.contains(w.millisecondsSinceEpoch)) {
      continue;
    }
    yield w;
    if (limit != null && ++emitted >= limit) return;
  }
}

Map<String, dynamic> normalizeLocalEvent(Map<String, dynamic> input) {
  final data = Map<String, dynamic>.from(input);
  final kind = data['kind'] as String? ?? 'event';
  final allDay = kind == 'occasion' || data['all_day'] == true;
  data['all_day'] = allDay;
  final zone = eventZone(data);
  data['timezone'] = zone.name;
  if ((data['title'] as String? ?? '').trim().isEmpty) {
    throw const FormatException('Enter a title.');
  }
  if (!['event', 'todo', 'occasion'].contains(kind)) {
    throw const FormatException('Invalid event type.');
  }
  if (kind == 'occasion') {
    data['location'] = '';
    data['attendees'] = <String, String>{};
  }
  for (final field in ['start', 'end', 'due']) {
    final local = data['${field}_local'] as String?;
    final instant = data[field] as String?;
    if ((local == null || local.isEmpty) &&
        (instant == null || instant.isEmpty)) {
      data.remove(field);
      data.remove('${field}_local');
      continue;
    }
    var w =
        local != null && local.isNotEmpty
            ? parseWall(local)
            : allDay || zone.name == 'floating'
            ? wallTime(DateTime.parse(instant!))
            : zone.wall(DateTime.parse(instant!));
    if (allDay) w = DateTime.utc(w.year, w.month, w.day);
    data['${field}_local'] = wallString(w, allDay);
    data[field] =
        (allDay || zone.name == 'floating' ? w : zone.resolve(w)!)
            .toIso8601String();
  }
  if (kind == 'todo' && data['due'] == null) {
    throw const FormatException('Choose a due date.');
  }
  if (kind != 'todo' &&
      (data['start'] == null ||
          data['end'] == null ||
          !DateTime.parse(
            data['end'] as String,
          ).isAfter(DateTime.parse(data['start'] as String)))) {
    throw const FormatException('Choose an end after the start.');
  }
  var rule = (data['rrule'] as String? ?? '').trim().toUpperCase();
  if (rule.startsWith('RRULE:')) rule = rule.substring(6);
  if (rule.isEmpty && data['yearly'] == true) rule = 'FREQ=YEARLY';
  final parts = ruleParts(rule);
  final untilDate = data['until_date'] as String? ?? '';
  if (rule.isNotEmpty && untilDate.isNotEmpty) {
    if (parts.containsKey('COUNT')) {
      throw const FormatException(
        'Choose either a repeat count or an end date.',
      );
    }
    final last = parseWall(untilDate).add(
      allDay
          ? Duration.zero
          : const Duration(hours: 23, minutes: 59, seconds: 59),
    );
    parts['UNTIL'] = compactStamp(
      allDay || zone.name == 'floating' ? last : zone.resolve(last)!,
      allDay,
      utc: !allDay && zone.name != 'floating',
    );
    rule = parts.entries.map((e) => '${e.key}=${e.value}').join(';');
  }
  if (rule.isNotEmpty) {
    // The parser rejects invalid ranges, duplicate parts and forbidden combinations.
    parseRecurrenceRule(rule);
    final until = ruleParts(rule)['UNTIL'];
    if (until != null) parseWall(until);
    if (until != null &&
        (allDay
            ? until.length != 8
            : zone.name == 'floating'
            ? until.endsWith('Z') || until.length != 15
            : !until.endsWith('Z') || until.length != 16)) {
      throw const FormatException(
        'UNTIL must match the date type: date for all-day, local for floating, UTC for a time zone.',
      );
    }
    if (kind == 'todo' &&
        data['start'] != null &&
        !DateTime.parse(
          data['due'] as String,
        ).isAfter(DateTime.parse(data['start'] as String))) {
      throw const FormatException(
        'A repeating todo needs a start before its due date.',
      );
    }
    if (data['start'] == null) {
      throw const FormatException('A repeating todo needs a start date.');
    }
  }
  data['rrule'] = rule;
  data['yearly'] = false;
  return data;
}

List<Map<String, dynamic>> expandLocalEvent(
  Map<String, dynamic> original,
  DateTime from,
  DateTime to, {
  int? limit,
  String viewTimezone = 'UTC',
}) {
  final event = Map<String, dynamic>.from(original);
  final allDay = event['all_day'] == true;
  final zone = eventZone(event);
  for (final field in ['start', 'end', 'due']) {
    if (event['${field}_local'] == null && event[field] != null) {
      final d = DateTime.parse(event[field] as String);
      event['${field}_local'] = wallString(
        allDay || zone.name == 'floating' ? wallTime(d) : zone.wall(d),
        allDay,
      );
    }
  }
  final startRaw =
      event['start_local'] as String? ?? event['due_local'] as String?;
  if (startRaw == null) return [];
  final start = parseWall(startRaw);
  final startInstant = zone.resolve(start)!;
  var maxSpan = Duration.zero;
  for (final field in ['end', 'due']) {
    if (event['${field}_local'] != null) {
      final span = zone
          .resolve(parseWall(event['${field}_local'] as String))!
          .difference(startInstant);
      if (span > maxSpan) maxSpan = span;
    }
  }
  final localExceptions = Map<String, dynamic>.from(
    event['_exceptions'] as Map? ?? {},
  );
  final overrides = Map<String, dynamic>.from(
    event['_overrides'] as Map? ?? {},
  );
  final ranges =
      (event['_ranges'] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList()
        ..sort((a, b) => (a['rid'] as String).compareTo(b['rid'] as String));
  var maxShift = Duration.zero;
  for (final r in ranges) {
    final e = r['event'] as Map;
    final shift =
        parseWall(
          e['start_local'] as String,
        ).difference(parseWall(r['wall'] as String)).abs();
    if (shift > maxShift) maxShift = shift;
  }
  final after = wallTime(
    from.subtract(maxSpan + maxShift + const Duration(days: 2)),
  );
  final before = wallTime(to.add(maxShift + const Duration(days: 2)));
  final recurring =
      (event['rrule'] as String? ?? '').isNotEmpty ||
      (event['rdates'] as List? ?? []).isNotEmpty;
  String key(DateTime w) =>
      allDay
          ? compactStamp(w, true)
          : zone.name == 'floating'
          ? compactStamp(w, false)
          : compactStamp(zone.resolve(w)!, false, utc: true);
  final excluded = <String>{
    for (final v in event['exdates'] as List? ?? [])
      key(
        (v as String).endsWith('Z') && !allDay
            ? zone.wall(DateTime.parse(v))
            : parseWall(v),
      ),
  };
  for (final rule in event['_exrules'] as List? ?? []) {
    for (final w in recurrenceDates(
      {...event, 'rrule': rule, 'rdates': [], 'exdates': []},
      before,
      after: after,
    )) {
      excluded.add(key(w));
    }
  }
  final result = <Map<String, dynamic>>[];
  void add(Map<String, dynamic> data, String rid) {
    if (data['_cancelled'] == true || excluded.contains(rid)) return;
    final exception = localExceptions[rid] as Map?;
    if (exception?['operation'] == 'skip') return;
    if (exception?['completed'] != null) {
      data['completed'] = exception!['completed'];
    }
    if (recurring) {
      data['recurrence_id'] = rid;
      data['series'] = original;
    }
    if (data['due'] == null && data['start'] == null) return;
    final first = DateTime.parse((data['due'] ?? data['start']) as String);
    final end = DateTime.parse(
      (data['kind'] == 'todo' ? data['due'] : data['end'] ?? data['start'])
          as String,
    );
    final f = allDay || zone.name == 'floating' ? wallTime(first) : first;
    final e = allDay || zone.name == 'floating' ? wallTime(end) : end;
    final a =
        allDay || zone.name == 'floating'
            ? wallTime(from)
            : CalendarZone(viewTimezone).resolve(wallTime(from))!;
    final b =
        allDay || zone.name == 'floating'
            ? wallTime(to)
            : CalendarZone(viewTimezone).resolve(wallTime(to))!;
    if (!f.isBefore(a) && f.isBefore(b) || f.isBefore(b) && e.isAfter(a)) {
      result.add(data);
    }
  }

  for (final w in recurrenceDates(event, before, after: after)) {
    final rid = key(w);
    if (overrides.containsKey(rid)) continue;
    var template = event, target = w;
    for (final r in ranges) {
      if ((r['rid'] as String).compareTo(rid) > 0) break;
      template = Map<String, dynamic>.from(r['event'] as Map);
      target = w.add(
        parseWall(
          template['start_local'] as String,
        ).difference(parseWall(r['wall'] as String)),
      );
    }
    final templateZone = eventZone(template);
    final originalStart = parseWall(
      (template['start_local'] ?? template['due_local']) as String,
    );
    final originalInstant = templateZone.resolve(originalStart)!;
    final instant = templateZone.resolve(target)!;
    final data = Map<String, dynamic>.from(template);
    data['start'] = instant.toIso8601String();
    data['start_local'] = wallString(target, allDay);
    if (template['start'] == null) {
      data.remove('start');
      data.remove('start_local');
    }
    for (final field in ['end', 'due']) {
      final local = template['${field}_local'] as String?;
      if (local == null) continue;
      final duration = templateZone
          .resolve(parseWall(local))!
          .difference(originalInstant);
      var d = instant.add(duration);
      final nominal = template['_nominal_duration'] as String?;
      if (nominal != null) {
        final days = RegExp(r'^P(?:(\d+)W)?(?:(\d+)D)?').firstMatch(nominal)!;
        final count =
            (int.tryParse(days[1] ?? '') ?? 0) * 7 +
            (int.tryParse(days[2] ?? '') ?? 0);
        d = templateZone
            .resolve(target.add(Duration(days: count)))!
            .add(parseIcalDuration(nominal) - Duration(days: count));
      }
      data[field] = d.toIso8601String();
      data['${field}_local'] = wallString(templateZone.wall(d), allDay);
    }
    final period =
        (event['_period_ends'] as Map?)?[compactStamp(w, false)] as String?;
    if (period != null) {
      data['end'] = period;
      data['end_local'] = wallString(zone.wall(DateTime.parse(period)), allDay);
    }
    add(data, rid);
    // Preview only: full calendar ranges are never truncated silently.
    if (limit != null && result.length >= limit && overrides.isEmpty) break;
  }
  // Moved instances can enter the range from an original RID outside it.
  for (final override in overrides.entries) {
    add(Map<String, dynamic>.from(override.value as Map), override.key);
  }
  result.sort(
    (a, b) => ((a['due'] ?? a['start']) as String).compareTo(
      (b['due'] ?? b['start']) as String,
    ),
  );
  return limit == null ? result : result.take(limit).toList();
}
