import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spacetime/models.dart';
import 'package:spacetime/time_grid.dart';

Entry timed(String id, int hour, int minute, int duration, {DateTime? date}) {
  final day = date ?? DateTime(2026, 10, 19);
  final start = DateTime(day.year, day.month, day.day, hour, minute);
  return Entry({
    'id': id,
    'owner': 'local',
    'title': id,
    'kind': 'event',
    'version': 1,
    'all_day': false,
    'timezone': 'UTC',
    'start': start.toUtc().toIso8601String(),
    'end': start.add(Duration(minutes: duration)).toUtc().toIso8601String(),
  });
}

void main() {
  test(
    'Overlaps share columns, touching events reuse them, and separate clusters fill the width',
    () {
      final events = [
        timed('Long', 9, 0, 180),
        timed('First', 9, 30, 60),
        timed('Second', 10, 30, 60),
        timed('Later', 13, 0, 60),
      ];
      final rows = placeEvents(daySegments(events, DateTime(2026, 10, 19)));
      EventPlacement p(String id) =>
          rows.firstWhere((p) => p.segment.entry.id == id);
      expect(p('Long').columns, 2);
      expect(p('First').column, p('Second').column);
      expect(p('Later').columns, 1);
      expect(p('Later').span, 1);
    },
  );
  test(
    'Triple overlaps allocate three lanes and expand into available space',
    () {
      final rows = placeEvents(
        daySegments([
          timed('A', 9, 0, 60),
          timed('B', 9, 0, 120),
          timed('C', 9, 0, 60),
          timed('D', 10, 0, 60),
        ], DateTime(2026, 10, 19)),
      );
      expect(
        rows.where((p) => p.segment.start == 540).every((p) => p.columns == 3),
        true,
      );
      final d = rows.firstWhere((p) => p.segment.entry.id == 'D');
      expect(d.columns, 3);
      expect(d.span, 2);
    },
  );
  test(
    'Overnight events clip to the right days with an exclusive midnight end',
    () {
      final e = timed('Overnight', 23, 0, 120);
      final first = daySegments([e], DateTime(2026, 10, 19)).single;
      final next = daySegments([e], DateTime(2026, 10, 20)).single;
      expect(first.start, 1380);
      expect(first.end, 1440);
      expect(first.continuesAfter, true);
      expect(next.start, 0);
      expect(next.end, 60);
      expect(next.continuesBefore, true);
      final midnight = timed('Midnight', 23, 0, 60);
      expect(daySegments([midnight], DateTime(2026, 10, 20)), isEmpty);
    },
  );
  testWidgets(
    'Daily event blocks show duration and keep overlapping appointments beside each other',
    (tester) async {
      tester.view.physicalSize = const Size(500, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final date = DateTime(2026, 10, 19);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TimeGrid(
              dates: [date],
              selected: date,
              entries: [
                timed('One hour', 9, 0, 60),
                timed('Two hours', 9, 0, 120),
              ],
              use24Hour: true,
              onEntry: (_) {},
              onSelect: (_) {},
              onOpenDay: (_) {},
              onCreate: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final a = tester.getRect(
        find.byWidgetPredicate(
          (w) => w is Positioned && w.key.toString().contains('One hour'),
        ),
      );
      final b = tester.getRect(
        find.byWidgetPredicate(
          (w) => w is Positioned && w.key.toString().contains('Two hours'),
        ),
      );
      expect((a.height - 63).abs(), lessThan(1));
      expect((b.height - 127).abs(), lessThan(1));
      expect(a.overlaps(b), false);
      expect(a.top, b.top);
      expect(find.text('09:00–10:00'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
