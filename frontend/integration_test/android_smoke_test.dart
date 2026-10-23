import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spacetime/main.dart';
import 'package:spacetime/models.dart';
import 'package:spacetime/native_platform.dart';
import 'package:spacetime/preference_storage.dart';
import 'package:spacetime/calendar_storage.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android opens offline, persists entries across restart, schedules local alarms and connects only for sync',
    (tester) async {
      await initializeNativePlatform();
      expect(nativePlatformReady, true);
      var requests = 0;
      const server = 'https://android-smoke.invalid';
      const token = 'integration-test-token';
      Api api() => Api(
        client: MockClient((req) async {
          requests++;
          if (req.url.path == '/api/login') {
            return http.Response(
              jsonEncode({
                'token': token,
                'user': {'username': 'android-smoke', 'name': 'Android smoke'},
              }),
              200,
            );
          }
          throw StateError('Network not allowed');
        }),
      );
      // This test runs in the .dev package; it never touches the release database.
      await nativeChannel.invokeMethod<void>('writeCalendar', {
        'value': jsonEncode({
          'schema': 1,
          'entries': [],
          'deleted': [],
          'invitations': [],
        }),
      });
      await writePreference('spacetime.server', '');
      await writePreference('spacetime.preferences.device', '{}');
      final state = CalendarState(api());
      await state.restore();
      await tester.pumpWidget(SpacetimeApp(state: state));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('month-calendar')), findsOneWidget);
      expect(find.text('Sign in'), findsNothing);
      expect(requests, 0);
      final work = await state.createCalendar('Work', '#426EB4');
      await state.setCalendarVisible(work.id, false, todos: true);
      final tomorrow = DateTime.now().add(const Duration(days: 1));
      final date =
          '${tomorrow.year}-${tomorrow.month.toString().padLeft(2, '0')}-${tomorrow.day.toString().padLeft(2, '0')}';
      await state.save({
        'title': 'Offline Android event',
        'kind': 'event',
        'all_day': true,
        'timezone': 'UTC',
        'start_local': date,
        'end_local': tomorrow
            .add(const Duration(days: 1))
            .toIso8601String()
            .substring(0, 10),
        'rrule': 'FREQ=DAILY;COUNT=3',
        'reminder_minutes': 15,
      });
      await state.savePreferences(
        defaultView: 'Weekly',
        weekStartsOn: 1,
        use24Hour: false,
      );
      nativePreferences.clear();
      await initializeNativePlatform();
      final restored = CalendarState(api());
      await restored.restore();
      expect(restored.entries.single.title, 'Offline Android event');
      expect(restored.calendars.map((c) => c.name), ['Personal', 'Work']);
      expect(restored.entries.single.calendarId, work.id);
      expect(restored.hiddenTodoCalendars, {work.id});
      expect(restored.entries.single.data['reminder_minutes'], 15);
      expect(restored.defaultView, 'Weekly');
      expect(restored.weekStartsOn, 1);
      expect(restored.use24Hour, false);
      await restored.setRange(
        DateTime.utc(tomorrow.year, tomorrow.month, tomorrow.day),
        DateTime.utc(tomorrow.year, tomorrow.month, tomorrow.day + 7),
      );
      expect(restored.occurrences.length, 3);
      await restored.occurrenceAction(restored.occurrences[1], 'skip');
      expect(restored.occurrences.length, 2);
      expect(requests, 0);
      await nativeChannel.invokeMethod<void>('scheduleReminders', {
        'enabled': true,
        'events': restored.entries.map((e) => e.data).toList(),
      });
      final diagnostics = await nativeChannel.invokeMapMethod<String, dynamic>(
        'reminderDiagnostics',
      );
      expect(diagnostics?['enabled'], true);
      expect(diagnostics?['events'], 1);
      expect(
        diagnostics?['next'],
        greaterThan(DateTime.now().millisecondsSinceEpoch),
      );
      // Account connection is the first network call. No implicit initial sync.
      await restored.configureServer(server);
      await restored.signIn('android-smoke', 'integration-test-password');
      expect(requests, 1);
      expect(await readNativeSession(server), token);
      expect(await readNativeSession('https://other.invalid'), isNull);
      final reopened = CalendarState(api());
      await reopened.restore();
      expect(requests, 1);
      expect(reopened.username, 'android-smoke');
      expect(reopened.entries.length, 1);
      await reopened.signOut();
      expect(requests, 1);
      expect(reopened.entries.length, 1);
      expect(await readNativeSession(server), isNull);
      expect(
        (await DeviceCalendarStorage().read())!,
        contains('Offline Android event'),
      );
      await nativeChannel.invokeMethod<void>('scheduleReminders', {
        'enabled': false,
        'events': [],
      });
      expect(tester.takeException(), isNull);
    },
  );
}
