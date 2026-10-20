import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'models.dart';

const _ink = Color(0xFF263C34), _line = Color(0xFFE6EAE1);
const _colors = {
  'event': Color(0xFF587F65),
  'todo': Color(0xFFB78C3C),
  'occasion': Color(0xFFB67888),
};

class DaySegment {
  final Entry entry;
  final double start, end;
  final bool continuesBefore, continuesAfter;
  const DaySegment(
    this.entry,
    this.start,
    this.end,
    this.continuesBefore,
    this.continuesAfter,
  );
  String get key => '${entry.id}:${entry.recurrenceId ?? ''}';
}

List<DaySegment> daySegments(List<Entry> entries, DateTime date) {
  final first = DateTime(date.year, date.month, date.day),
      next = DateTime(date.year, date.month, date.day + 1);
  if (!next.isAfter(first)) return [];
  final segments = <DaySegment>[];
  for (final e in entries) {
    if (e.allDay || e.when == null) continue;
    final start = e.kind == 'todo' ? e.when! : e.start ?? e.when!;
    final finish =
        e.kind == 'todo'
            ? start.add(const Duration(minutes: 15))
            : e.end ?? start.add(const Duration(minutes: 15));
    if (!start.isBefore(next) || !finish.isAfter(first)) continue;
    final before = start.isBefore(first), after = !finish.isBefore(next);
    final a =
        before ? 0.0 : start.hour * 60.0 + start.minute + start.second / 60;
    var b =
        after
            ? 1440.0
            : finish.hour * 60.0 + finish.minute + finish.second / 60;
    // A fall-back fold can reverse wall-clock fields while elapsed time is positive.
    if (b <= a) b = math.min(1440, a + finish.difference(start).inSeconds / 60);
    segments.add(DaySegment(e, a, b, before, after));
  }
  return segments;
}

class EventPlacement {
  final DaySegment segment;
  final int column, columns, span;
  const EventPlacement(this.segment, this.column, this.columns, this.span);
}

/// Interval partitioning, followed by expansion into unoccupied columns.
/// Touching end/start boundaries do not overlap. Tiny events reserve a readable
/// hit area while the duration rail retains the actual length.
List<EventPlacement> placeEvents(
  List<DaySegment> source, {
  double minMinutes = 17,
}) {
  double end(DaySegment e) => math.max(e.end, e.start + minMinutes);
  final sorted = [...source]..sort((a, b) {
    final start = a.start.compareTo(b.start);
    if (start != 0) return start;
    final duration = b.end.compareTo(a.end);
    return duration != 0 ? duration : a.key.compareTo(b.key);
  });
  final result = <EventPlacement>[];
  var cluster = <DaySegment>[], lastEnd = -1.0;
  void finish() {
    if (cluster.isEmpty) return;
    final lanes = <List<DaySegment>>[], assigned = <DaySegment, int>{};
    for (final item in cluster) {
      var index = lanes.indexWhere((lane) => end(lane.last) <= item.start);
      if (index < 0) {
        index = lanes.length;
        lanes.add([]);
      }
      lanes[index].add(item);
      assigned[item] = index;
    }
    for (final item in cluster) {
      final column = assigned[item]!;
      var span = 1;
      for (var c = column + 1; c < lanes.length; c++) {
        if (lanes[c].any(
          (other) => item.start < end(other) && other.start < end(item),
        )) {
          break;
        }
        span++;
      }
      result.add(EventPlacement(item, column, lanes.length, span));
    }
    cluster = [];
  }

  for (final item in sorted) {
    if (cluster.isNotEmpty && item.start >= lastEnd) {
      finish();
      lastEnd = -1;
    }
    cluster.add(item);
    lastEnd = math.max(lastEnd, end(item));
  }
  finish();
  return result;
}

class TimeGrid extends StatefulWidget {
  final List<DateTime> dates;
  final List<Entry> entries;
  final DateTime selected;
  final bool use24Hour;
  final void Function(Entry) onEntry;
  final void Function(DateTime) onSelect, onOpenDay, onCreate;
  const TimeGrid({
    super.key,
    required this.dates,
    required this.entries,
    required this.selected,
    required this.use24Hour,
    required this.onEntry,
    required this.onSelect,
    required this.onOpenDay,
    required this.onCreate,
  });
  @override
  State<TimeGrid> createState() => _TimeGridState();
}

class _TimeGridState extends State<TimeGrid> {
  static const hourHeight = 64.0, gutter = 48.0;
  final _header = ScrollController(), _body = ScrollController();
  late final ScrollController _vertical;
  bool _linking = false;
  @override
  void initState() {
    super.initState();
    final timed =
        widget.dates.expand((d) => daySegments(widget.entries, d)).toList();
    final first =
        timed.isEmpty
            ? 8.0
            : (timed.map((e) => e.start).reduce(math.min) / 60 - 0.5).clamp(
              0.0,
              20.0,
            );
    _vertical = ScrollController(initialScrollOffset: first * hourHeight);
    _header.addListener(() => _link(_header, _body));
    _body.addListener(() => _link(_body, _header));
  }

  void _link(ScrollController from, ScrollController to) {
    if (_linking || !from.hasClients || !to.hasClients) return;
    _linking = true;
    to.jumpTo(from.offset.clamp(0.0, to.position.maxScrollExtent));
    _linking = false;
  }

  @override
  void dispose() {
    _header.dispose();
    _body.dispose();
    _vertical.dispose();
    super.dispose();
  }

  String clock(DateTime d) =>
      (widget.use24Hour ? DateFormat.Hm() : DateFormat.jm()).format(d);
  List<Entry> allDay(DateTime d) =>
      widget.entries.where((e) => e.allDay && e.occursOn(d)).toList();
  Widget chip(Entry e) => Tooltip(
    message: e.title,
    child: InkWell(
      onTap: () => widget.onEntry(e),
      child: Container(
        height: 22,
        margin: const EdgeInsets.fromLTRB(2, 1, 2, 1),
        padding: const EdgeInsets.symmetric(horizontal: 5),
        decoration: BoxDecoration(
          color: (_colors[e.kind] ?? _ink).withValues(alpha: .15),
          borderRadius: BorderRadius.circular(4),
        ),
        alignment: Alignment.centerLeft,
        child: Text(
          e.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11, color: _ink),
        ),
      ),
    ),
  );
  Future<void> showAllDay(DateTime date) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder:
        (context) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(DateFormat.yMMMMEEEEd().format(date)),
              ),
              for (final e in allDay(date))
                ListTile(
                  title: Text(e.title),
                  onTap: () {
                    Navigator.pop(context);
                    widget.onEntry(e);
                  },
                ),
            ],
          ),
        ),
  );
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final count = widget.dates.length;
      final width =
          count == 1
              ? (box.maxWidth - gutter).clamp(1.0, double.infinity)
              : math.max(110.0, (box.maxWidth - gutter) / count);
      final total = width * count;
      final allDayCount = widget.dates
          .map((d) => allDay(d).length)
          .fold<int>(0, math.max);
      final allDayRows = allDayCount.clamp(1, 4);
      final headHeight = 44.0 + allDayRows * 24;
      return Column(
        children: [
          SizedBox(
            height: headHeight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: gutter,
                  child: Column(
                    children: [
                      const SizedBox(height: 44),
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          'All day',
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 9,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    controller: _header,
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: total,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final date in widget.dates)
                            SizedBox(
                              width: width,
                              child: DecoratedBox(
                                decoration: const BoxDecoration(
                                  border: Border(
                                    left: BorderSide(color: _line),
                                  ),
                                ),
                                child: Column(
                                  children: [
                                    SizedBox(
                                      height: 44,
                                      child: InkWell(
                                        onTap: () => widget.onSelect(date),
                                        onDoubleTap:
                                            () => widget.onOpenDay(date),
                                        child: Container(
                                          width: double.infinity,
                                          alignment: Alignment.center,
                                          color:
                                              day(date) == day(widget.selected)
                                                  ? const Color(0xFFF0F4EE)
                                                  : Colors.white,
                                          child: Text(
                                            count == 1
                                                ? DateFormat(
                                                  'EEEE, MMM d',
                                                ).format(date)
                                                : DateFormat(
                                                  'E d',
                                                ).format(date),
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600,
                                              color:
                                                  day(date) ==
                                                          day(DateTime.now())
                                                      ? const Color(0xFF244F3F)
                                                      : _ink,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    for (final e in allDay(
                                      date,
                                    ).take(allDay(date).length > 4 ? 3 : 4))
                                      SizedBox(
                                        width: double.infinity,
                                        child: chip(e),
                                      ),
                                    if (allDay(date).length > 4)
                                      SizedBox(
                                        height: 24,
                                        child: TextButton(
                                          style: TextButton.styleFrom(
                                            padding: EdgeInsets.zero,
                                          ),
                                          onPressed: () => showAllDay(date),
                                          child: Text(
                                            '+${allDay(date).length - 3} more',
                                            style: const TextStyle(
                                              fontSize: 10,
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: _line),
          Expanded(
            child: SingleChildScrollView(
              controller: _vertical,
              key: const ValueKey('time-grid-scroll'),
              child: SizedBox(
                height: 24 * hourHeight + 1,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: gutter,
                      height: 24 * hourHeight + 1,
                      child: Stack(
                        children: [
                          for (var h = 0; h < 24; h++)
                            Positioned(
                              top: h * hourHeight + 3,
                              left: 0,
                              right: 7,
                              child: Text(
                                widget.use24Hour
                                    ? '${h.toString().padLeft(2, '0')}:00'
                                    : DateFormat(
                                      'ha',
                                    ).format(DateTime(2000, 1, 1, h)),
                                textAlign: TextAlign.right,
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: Color(0xFF788279),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Scrollbar(
                        controller: _body,
                        notificationPredicate:
                            (n) => n.metrics.axis == Axis.horizontal,
                        child: SingleChildScrollView(
                          controller: _body,
                          scrollDirection: Axis.horizontal,
                          child: SizedBox(
                            width: total,
                            height: 24 * hourHeight + 1,
                            child: Row(
                              children: [
                                for (final date in widget.dates)
                                  SizedBox(
                                    width: width,
                                    height: 24 * hourHeight + 1,
                                    child: dayColumn(date, width),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
  Widget dayColumn(DateTime date, double width) {
    final placements = placeEvents(daySegments(widget.entries, date));
    final now = DateTime.now();
    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onDoubleTapDown: (d) {
              final minutes =
                  ((d.localPosition.dy / hourHeight * 60) / 15).floor() * 15;
              widget.onCreate(
                DateTime(
                  date.year,
                  date.month,
                  date.day,
                  minutes ~/ 60,
                  minutes % 60,
                ),
              );
            },
            child: CustomPaint(painter: _HourLines(hourHeight)),
          ),
        ),
        for (final p in placements)
          Positioned(
            key: ValueKey(
              'event-position-${date.toIso8601String()}-${p.segment.key}',
            ),
            top: p.segment.start / 60 * hourHeight,
            left: width * p.column / p.columns + 2,
            width: math.max(1, width * p.span / p.columns - 4),
            height: math.max(
              18,
              (p.segment.end - p.segment.start) / 60 * hourHeight - 1,
            ),
            child: eventBlock(p.segment, date),
          ),
        if (day(date) == day(now))
          Positioned(
            top: (now.hour + now.minute / 60) * hourHeight,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Container(height: 1, color: const Color(0xFFB34343)),
            ),
          ),
      ],
    );
  }

  Widget eventBlock(DaySegment s, DateTime date) {
    final e = s.entry, color = _colors[e.kind] ?? _ink;
    final start = e.kind == 'todo' ? e.when! : e.start ?? e.when!;
    final end = e.kind == 'todo' ? null : e.end;
    final label =
        '${e.title}, ${e.kind == 'todo' ? 'Due ' : ''}${clock(start)}${end == null ? '' : '–${clock(end)}'}${s.continuesBefore ? ', continues from previous day' : ''}${s.continuesAfter ? ', continues next day' : ''}';
    return Semantics(
      button: true,
      excludeSemantics: true,
      label: label,
      onTap: () => widget.onEntry(e),
      child: Tooltip(
        message: label,
        child: Material(
          color: color.withValues(alpha: e.completed ? .10 : .20),
          borderRadius: BorderRadius.circular(4),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => widget.onEntry(e),
            child: LayoutBuilder(
              builder:
                  (context, box) => Stack(
                    children: [
                      Align(
                        alignment: Alignment.topLeft,
                        child: Container(
                          width: 3,
                          height: math.min(
                            box.maxHeight,
                            (s.end - s.start) / 60 * hourHeight,
                          ),
                          color: color,
                        ),
                      ),
                      Positioned.fill(
                        left: 6,
                        right: 3,
                        top: 2,
                        bottom: 1,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                e.title,
                                maxLines: box.maxHeight >= 52 ? 3 : 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  height: 1.15,
                                  color: _ink,
                                  decoration:
                                      e.completed
                                          ? TextDecoration.lineThrough
                                          : null,
                                ),
                              ),
                            ),
                            if (box.maxHeight >= 40)
                              Text(
                                '${s.continuesBefore ? '← ' : ''}${clock(start)}${end == null ? '' : '–${clock(end)}'}${s.continuesAfter ? ' →' : ''}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: _ink,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HourLines extends CustomPainter {
  final double hourHeight;
  _HourLines(this.hourHeight);
  @override
  void paint(Canvas canvas, Size size) {
    final paint =
        Paint()
          ..color = _line
          ..strokeWidth = 1;
    canvas.drawLine(Offset.zero, Offset(0, size.height), paint);
    for (var h = 0; h <= 24; h++) {
      canvas.drawLine(
        Offset(0, h * hourHeight),
        Offset(size.width, h * hourHeight),
        paint,
      );
    }
    paint.color = _line.withValues(alpha: .45);
    for (var h = 0; h < 24; h++) {
      canvas.drawLine(
        Offset(0, (h + .5) * hourHeight),
        Offset(size.width, (h + .5) * hourHeight),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _HourLines old) => old.hourHeight != hourHeight;
}
