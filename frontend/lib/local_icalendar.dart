import 'local_recurrence.dart';

class IcalProperty {
  final String name, value;
  final Map<String, String> params;
  IcalProperty(this.name, this.value, this.params);
}

class IcalComponent {
  final String name;
  final List<IcalProperty> properties = [];
  final List<IcalComponent> children = [];
  IcalComponent(this.name);
  IcalProperty? property(String name) =>
      properties.where((p) => p.name == name).firstOrNull;
  String text(String name) => (property(name)?.value ?? '')
      .replaceAll(r'\n', '\n')
      .replaceAll(r'\N', '\n')
      .replaceAll(r'\,', ',')
      .replaceAll(r'\;', ';')
      .replaceAll(r'\\', r'\');
}

IcalComponent parseCalendar(String raw) {
  final root = IcalComponent('ROOT'), stack = <IcalComponent>[];
  stack.add(root);
  final unfolded = raw
      .replaceAll('\r\n', '\n')
      .replaceAll(RegExp(r'\n[ \t]'), '');
  for (final line in unfolded.split('\n').where((s) => s.isNotEmpty)) {
    var quoted = false, colon = -1;
    for (var i = 0; i < line.length; i++) {
      if (line[i] == '"') quoted = !quoted;
      if (line[i] == ':' && !quoted) {
        colon = i;
        break;
      }
    }
    if (colon < 0) throw const FormatException('Invalid iCalendar property.');
    final header = line.substring(0, colon).split(';'),
        value = line.substring(colon + 1);
    final name = header.first.toUpperCase();
    if (name == 'BEGIN') {
      final c = IcalComponent(value.toUpperCase());
      stack.last.children.add(c);
      stack.add(c);
    } else if (name == 'END') {
      if (stack.length <= 1 || stack.last.name != value.toUpperCase()) {
        throw const FormatException('Unbalanced iCalendar component.');
      }
      stack.removeLast();
    } else {
      stack.last.properties.add(
        IcalProperty(name, value, {
          for (final part in header.skip(1))
            part.split('=').first.toUpperCase(): part
                .split('=')
                .skip(1)
                .join('=')
                .replaceAll('"', ''),
        }),
      );
    }
  }
  if (stack.length != 1) {
    throw const FormatException('Incomplete iCalendar data.');
  }
  return root.children.firstWhere((c) => c.name == 'VCALENDAR');
}

int _offset(String value) {
  final sign = value.startsWith('-') ? -1 : 1;
  return sign *
      (int.parse(value.substring(1, 3)) * 3600 +
          int.parse(value.substring(3, 5)) * 60 +
          (value.length >= 7 ? int.parse(value.substring(5, 7)) : 0));
}

Map<String, dynamic> _zones(IcalComponent calendar) => {
  for (final zone in calendar.children.where((c) => c.name == 'VTIMEZONE'))
    zone.property('TZID')!.value: [
      for (final observation in zone.children)
        {
          'start': observation.property('DTSTART')!.value,
          'from': _offset(observation.property('TZOFFSETFROM')!.value),
          'to': _offset(observation.property('TZOFFSETTO')!.value),
          'rrule': observation.property('RRULE')?.value ?? '',
          'rdates': [
            for (final p in observation.properties.where(
              (p) => p.name == 'RDATE',
            ))
              ...p.value.split(','),
          ],
        },
    ],
};
Map<String, dynamic> componentEvent(
  IcalComponent component,
  Map<String, dynamic> base,
) {
  final result = Map<String, dynamic>.from(base);
  if (component.property('SUMMARY') != null) {
    result['title'] = component.text('SUMMARY');
  }
  result['description'] = component.text('DESCRIPTION');
  result['location'] = component.text('LOCATION');
  result['completed'] = component.text('STATUS') == 'COMPLETED';
  result['_cancelled'] = component.text('STATUS') == 'CANCELLED';
  final p = component.property('DTSTART') ?? component.property('DUE');
  if (p != null) {
    result['all_day'] = p.params['VALUE'] == 'DATE' || p.value.length == 8;
    result['timezone'] =
        p.params['TZID'] ?? (p.value.endsWith('Z') ? 'UTC' : 'floating');
  }
  final zone = eventZone(result);
  for (final pair
      in {'DTSTART': 'start', 'DTEND': 'end', 'DUE': 'due'}.entries) {
    final date = component.property(pair.key);
    if (date == null) {
      result.remove(pair.value);
      result.remove('${pair.value}_local');
      continue;
    }
    final w = parseWall(date.value);
    result['${pair.value}_local'] = wallString(w, result['all_day'] == true);
    result[pair.value] =
        (date.value.endsWith('Z')
                ? DateTime.parse(date.value).toUtc()
                : zone.resolve(w)!)
            .toIso8601String();
  }
  final duration = component.property('DURATION')?.value;
  if (duration != null && result['start'] != null) {
    final span = parseIcalDuration(duration);
    final end = DateTime.parse(result['start'] as String).add(span);
    final field = component.name == 'VTODO' ? 'due' : 'end';
    result[field] = end.toIso8601String();
    result['${field}_local'] = wallString(
      zone.wall(end),
      result['all_day'] == true,
    );
    result['_nominal_duration'] = duration;
  }
  if (component.name == 'VEVENT' &&
      result['end'] == null &&
      result['start'] != null) {
    final start = DateTime.parse(result['start'] as String);
    final end = start.add(
      result['all_day'] == true ? const Duration(days: 1) : Duration.zero,
    );
    result['end'] = end.toIso8601String();
    result['end_local'] = wallString(zone.wall(end), result['all_day'] == true);
  }
  return result;
}

Duration parseIcalDuration(String value) {
  final m = RegExp(
    r'^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$',
  ).firstMatch(value);
  if (m == null) throw const FormatException('Invalid iCalendar duration.');
  final d = Duration(
    days: (int.tryParse(m[2] ?? '') ?? 0) * 7 + (int.tryParse(m[3] ?? '') ?? 0),
    hours: int.tryParse(m[4] ?? '') ?? 0,
    minutes: int.tryParse(m[5] ?? '') ?? 0,
    seconds: int.tryParse(m[6] ?? '') ?? 0,
  );
  return m[1] == '-' ? -d : d;
}

/// Preserve the complete calendar and project recurrence metadata for offline use.
Map<String, dynamic> hydrateCalendarData(Map<String, dynamic> input) {
  final raw = input['calendar_data'] as String?;
  if (raw == null || raw.isEmpty) return input;
  final calendar = parseCalendar(raw);
  final components =
      calendar.children
          .where((c) => ['VEVENT', 'VTODO'].contains(c.name))
          .toList();
  final master = components.firstWhere(
    (c) => c.property('RECURRENCE-ID') == null,
  );
  final data = Map<String, dynamic>.from(input)
    ..['_timezones'] = _zones(calendar);
  data['_nominal_duration'] = master.property('DURATION')?.value;
  data['_exrules'] = [
    for (final p in master.properties.where((p) => p.name == 'EXRULE')) p.value,
  ];
  final zone = eventZone(data);
  final overrides = <String, dynamic>{};
  final ranges = <Map<String, dynamic>>[];
  for (final c in components.where(
    (c) => c.property('RECURRENCE-ID') != null,
  )) {
    final p = c.property('RECURRENCE-ID')!;
    final w = parseWall(p.value);
    final key =
        data['all_day'] == true
            ? compactStamp(w, true)
            : p.value.endsWith('Z')
            ? p.value
            : data['timezone'] == 'floating'
            ? compactStamp(w, false)
            : compactStamp(zone.resolve(w)!, false, utc: true);
    final projected = componentEvent(c, data);
    projected.remove('_exceptions');
    projected.remove('_overrides');
    projected.remove('_ranges');
    if (p.params['RANGE'] == 'THISANDFUTURE') {
      ranges.add({
        'rid': key,
        'wall': wallString(
          p.value.endsWith('Z') ? zone.wall(DateTime.parse(p.value)) : w,
          false,
        ),
        'event': projected,
      });
    } else {
      overrides[key] = projected;
    }
  }
  data['_overrides'] = overrides;
  data['_ranges'] = ranges;
  final periods = <String, dynamic>{};
  for (final p in master.properties.where(
    (p) => p.name == 'RDATE' && p.params['VALUE'] == 'PERIOD',
  )) {
    for (final value in p.value.split(',')) {
      final pair = value.split('/');
      final first = parseWall(pair[0]);
      final key =
          pair[0].endsWith('Z')
              ? compactStamp(zone.wall(DateTime.parse(pair[0])), false)
              : compactStamp(first, false);
      final end =
          pair[1].startsWith('P')
              ? zone.resolve(first)!.add(parseIcalDuration(pair[1]))
              : pair[1].endsWith('Z')
              ? DateTime.parse(pair[1]).toUtc()
              : zone.resolve(parseWall(pair[1]))!;
      periods[key] = end.toIso8601String();
    }
  }
  data['_period_ends'] = periods;
  return data;
}
