part of 'models.dart';

extension CalendarWidget on CalendarState {
  Future<void> publishCalendarWidget() async {
    if (!iosCalendarWidgets || !nativePlatformReady) return;
    try {
      await calendarWidgetChannel.invokeMethod<void>(
        'publish',
        jsonEncode(calendarWidgetSnapshot(DateTime.now())),
      );
    } catch (error) {
      debugPrint('Could not update calendar widgets: $error');
    }
  }

  Map<String, dynamic> calendarWidgetSnapshot(DateTime now) {
    final firstDay = day(now);
    final lastDay = DateTime.utc(now.year, now.month, now.day + 28);
    final days = <String, List<_WidgetOccurrence>>{};
    final appointments = <_WidgetOccurrence>[];
    final accountBindings = {
      for (final entry in entries) entry.id: entry.data['_account'],
    };
    final records = [
      ...authoritativeEntries.where((entry) {
        final binding = accountBindings[entry.id] ?? calendarFor(entry).account;
        return (binding == null || (connected && binding == account)) &&
            isCalendarVisible(entry) &&
            (showInvites || !isInvite(entry));
      }),
      if (showInvites)
        ...pendingCalendarInvites.where(
          (entry) => connected || entry.data['_account'] == null,
        ),
    ];
    _WidgetOccurrence? nextBeyondWindow;
    for (final entry in records) {
      if (entry.completed || entry.data['_cancelled'] == true) continue;
      try {
        final hydrated = Entry(hydrateCalendarData(entry.data));
        final data = {...hydrated.data, 'rrule': hydrated.rrule};
        for (final occurrence in _widgetOccurrences(
          data,
          firstDay,
          lastDay,
          timezone,
        )) {
          if (occurrence.kind == 'event' && occurrence.end.isAfter(now)) {
            appointments.add(occurrence);
          }
          // Clip multi-day events to the projection window and treat DTEND
          // as exclusive, including at midnight and on DST transitions.
          final start = day(occurrence.start);
          for (
            var date = start.isBefore(firstDay) ? firstDay : start;
            date.isBefore(lastDay) &&
                (date == start ||
                    occurrence.end.isAfter(
                      DateTime(date.year, date.month, date.day),
                    ));
            date = date.add(const Duration(days: 1))
          ) {
            (days[wallString(date, true)] ??= []).add(occurrence);
          }
        }
        if (entry.kind == 'event') {
          final next = _widgetAppointmentAfter(data, lastDay, timezone);
          if (next != null &&
              (nextBeyondWindow == null ||
                  next.start.isBefore(nextBeyondWindow.start))) {
            nextBeyondWindow = next;
          }
        }
      } on FormatException catch (error) {
        debugPrint(
          'Could not project a calendar widget event: ${error.message}',
        );
      } on ArgumentError {
        // A legacy event can refer to a missing timezone. Keep the other rows.
      }
    }
    if (nextBeyondWindow != null) appointments.add(nextBeyondWindow);
    appointments.sort(_WidgetOccurrence.compareStart);
    return {
      'use24Hour': use24Hour,
      'expiresAt':
          DateTime(
            lastDay.year,
            lastDay.month,
            lastDay.day,
          ).millisecondsSinceEpoch,
      'days': {
        for (final entry in days.entries)
          entry.key:
              (entry.value..sort(_WidgetOccurrence.compareDay))
                  .take(4)
                  .map((e) => e.toJson())
                  .toList(),
      },
      'appointments': appointments.map((e) => e.toJson()).toList(),
    };
  }
}

Iterable<_WidgetOccurrence> _widgetOccurrences(
  Map<String, dynamic> data,
  DateTime from,
  DateTime to,
  String timezone, {
  int? limit,
}) sync* {
  for (final value in expandLocalEvent(
    data,
    from,
    to,
    limit: limit,
    viewTimezone: timezone,
  )) {
    final entry = Entry(value);
    final start = entry.when;
    if (entry.completed || start == null) continue;
    DateTime local(DateTime date) =>
        entry.allDay
            ? DateTime(date.year, date.month, date.day)
            : date.toLocal();
    final beginning = local(start);
    final end = local(entry.kind == 'todo' ? start : entry.end ?? start);
    yield _WidgetOccurrence(
      entry.title,
      entry.kind,
      entry.allDay,
      beginning,
      end.isAfter(beginning) ? end : beginning.add(const Duration(seconds: 1)),
    );
  }
}

_WidgetOccurrence? _widgetAppointmentAfter(
  Map<String, dynamic> data,
  DateTime windowEnd,
  String timezone,
) {
  final localEnd = DateTime(windowEnd.year, windowEnd.month, windowEnd.day);
  final entry = Entry(data);
  final base = entry.start;
  if (base == null) return null;
  // Concrete dates and detached overrides may be arbitrarily far away.
  final anchors = <DateTime>{
    day(base),
    for (final raw in data['rdates'] as List? ?? [])
      if (DateTime.tryParse((raw as String).split('/').first) case final date?)
        day(date.toLocal()),
    for (final raw in (data['_overrides'] as Map? ?? {}).values)
      if (Entry(Map<String, dynamic>.from(raw as Map)).start case final date?)
        day(date),
  }.where(
    (date) => !date.isBefore(windowEnd.subtract(const Duration(days: 1))),
  );
  _WidgetOccurrence? next;
  void search(DateTime from, DateTime to) {
    for (final occurrence in _widgetOccurrences(
      data,
      from,
      to,
      timezone,
      limit: 8,
    )) {
      if (!occurrence.start.isBefore(localEnd) &&
          (next == null || occurrence.start.isBefore(next!.start))) {
        next = occurrence;
      }
    }
  }

  for (final date in anchors) {
    search(
      date.subtract(const Duration(days: 1)),
      date.add(const Duration(days: 2)),
    );
  }
  if (entry.rrule.isEmpty || day(base).isAfter(windowEnd)) return next;

  // Look for the next rule occurrence without expanding a long series at once.
  final parts = ruleParts(entry.rrule);
  final interval = int.tryParse(parts['INTERVAL'] ?? '') ?? 1;
  final months = switch (parts['FREQ']) {
    'YEARLY' => interval * 48,
    'MONTHLY' => interval * 4,
    'WEEKLY' => interval * 2,
    _ => 12,
  };
  final last = DateTime.utc(
    windowEnd.year,
    windowEnd.month + months.clamp(1, 1200),
    windowEnd.day,
  );
  var from = windowEnd;
  var span = 14;
  while (from.isBefore(last) &&
      (next == null ||
          from.isBefore(day(next!.start).add(const Duration(days: 1))))) {
    final until = from.add(Duration(days: span));
    search(from, until.isAfter(last) ? last : until);
    if (next != null && day(next!.start).isBefore(until)) break;
    from = until;
    span *= 2;
  }
  return next;
}

class _WidgetOccurrence {
  final String title, kind;
  final bool allDay;
  final DateTime start, end;
  const _WidgetOccurrence(
    this.title,
    this.kind,
    this.allDay,
    this.start,
    this.end,
  );

  static int compareStart(_WidgetOccurrence a, _WidgetOccurrence b) {
    final order = a.start.compareTo(b.start);
    return order == 0 ? a.title.compareTo(b.title) : order;
  }

  static int compareDay(_WidgetOccurrence a, _WidgetOccurrence b) =>
      a.allDay == b.allDay ? compareStart(a, b) : (a.allDay ? -1 : 1);

  Map<String, dynamic> toJson() => {
    'title': title,
    'kind': kind,
    'allDay': allDay,
    'start': start.millisecondsSinceEpoch,
    'end': end.millisecondsSinceEpoch,
  };
}
