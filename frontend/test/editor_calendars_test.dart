import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spacetime/calendar_storage.dart';
import 'package:spacetime/editor.dart';
import 'package:spacetime/models.dart';

CalendarState withSource({required bool readOnly}) =>
    CalendarState(Api(), storage: MemoryCalendarStorage())
      ..selectedCalendarId = 'source'
      ..calendars.add(
        CalendarCollection({
          'id': 'source',
          'name': 'Subscribed',
          'kind': 'source',
          'read_only': readOnly,
        }),
      );
Future<void> openEditor(WidgetTester tester, CalendarState state) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder:
            (context) => FilledButton(
              onPressed:
                  () => showDialog<void>(
                    context: context,
                    builder:
                        (_) => ListenableBuilder(
                          listenable: state,
                          builder:
                              (_, _) => EntryEditor(
                                state: state,
                                date: DateTime(2026, 10, 23),
                              ),
                        ),
                  ),
              child: const Text('Open'),
            ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'Add event falls back from a read-only selected calendar and saves to Personal',
    (tester) async {
      final state = withSource(readOnly: true);
      await openEditor(tester, state);
      expect(tester.takeException(), isNull);
      final field = tester.widget<DropdownButtonFormField<String>>(
        find.byKey(const ValueKey('entry-calendar')),
      );
      expect(field.initialValue, 'device');
      await tester.enterText(
        find.widgetWithText(TextField, 'Title'),
        'Writable appointment',
      );
      await tester.ensureVisible(find.text('Create entry'));
      await tester.tap(find.text('Create entry'));
      await tester.pumpAndSettle();
      expect(state.entries.single.calendarId, 'device');
      expect(state.entries.single.title, 'Writable appointment');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'An editor retains its current calendar when source permissions change',
    (tester) async {
      final state = withSource(readOnly: false);
      await openEditor(tester, state);
      state.calendars =
          state.calendars
              .map(
                (c) =>
                    c.id == 'source'
                        ? CalendarCollection({...c.data, 'read_only': true})
                        : c,
              )
              .toList();
      state.notifyListeners();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester
            .widget<DropdownButtonFormField<String>>(
              find.byKey(const ValueKey('entry-calendar')),
            )
            .initialValue,
        'source',
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    },
  );
}
