import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spacetime/calendar_storage.dart';
import 'package:spacetime/foreground_sync.dart';
import 'package:spacetime/models.dart';
import 'package:spacetime/native_platform.dart';
import 'package:spacetime/preference_storage.dart';

void main() {
  setUp(() async {
    nativePreferences.clear();
    await writePreference('spacetime.server', 'https://calendar.example.com');
  });

  testWidgets('Only connected foreground accounts sync at hourly boundaries', (
    tester,
  ) async {
    var requests = 0;
    final state = calendar((request) async {
      requests++;
      return response(request);
    });
    final sync = ForegroundSync(state, now: () => tester.binding.clock.now());
    addTearDown(sync.dispose);
    sync.setForeground(true);
    await tester.pump(const Duration(hours: 2));
    expect(requests, 0);
    await connect(state);
    await tester.pump(const Duration(minutes: 59, seconds: 59));
    expect(requests, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(requests, 4); // Identity, event upload check, events, invitations.
    expect(state.lastSync, isNotNull);
    await tester.pump(const Duration(minutes: 59));
    expect(requests, 4);
    await tester.pump(const Duration(minutes: 1));
    expect(requests, 8);
    await state.signOut();
    await tester.pump(const Duration(hours: 2));
    expect(requests, 8);
  });

  testWidgets(
    'Hidden time causes no requests and only one catch-up on return',
    (tester) async {
      var requests = 0;
      final state = calendar((request) async {
        requests++;
        return response(request);
      });
      final sync = ForegroundSync(state, now: () => tester.binding.clock.now());
      addTearDown(sync.dispose);
      await connect(state);
      sync.setForeground(true);
      await tester.pump(const Duration(minutes: 30));
      sync.setForeground(false);
      await tester.pump(const Duration(hours: 10));
      expect(requests, 0);
      sync.setForeground(true);
      await tester.pump(const Duration(milliseconds: 1));
      expect(requests, 4);
      await tester.pump(const Duration(minutes: 59));
      expect(requests, 4);
      await tester.pump(const Duration(minutes: 1));
      expect(requests, 8);
      sync.dispose();
    },
  );

  testWidgets(
    'Manual sync resets the interval and never overlaps a timed sync',
    (tester) async {
      var requests = 0;
      final gate = Completer<void>();
      final state = calendar((request) async {
        requests++;
        if (request.url.path == '/api/me') await gate.future;
        return response(request);
      });
      final sync = ForegroundSync(state, now: () => tester.binding.clock.now());
      addTearDown(sync.dispose);
      await connect(state);
      sync.setForeground(true);
      await tester.pump(const Duration(minutes: 59, seconds: 55));
      final manual = state.sync();
      await tester.pump(const Duration(seconds: 10));
      expect(requests, 1);
      gate.complete();
      await tester.pump();
      await manual;
      expect(requests, 4);
      await tester.pump(const Duration(minutes: 59));
      expect(requests, 4);
      await tester.pump(const Duration(minutes: 1));
      expect(requests, 8);
      sync.dispose();
    },
  );

  testWidgets('Offline failures preserve edits and retry only after an hour', (
    tester,
  ) async {
    var requests = 0;
    final state = calendar((request) async {
      requests++;
      throw StateError('offline');
    });
    final sync = ForegroundSync(state, now: () => tester.binding.clock.now());
    addTearDown(sync.dispose);
    await connect(state);
    await state.save({
      'title': 'Keep this offline edit',
      'kind': 'event',
      'all_day': true,
      'start_local': '2026-10-21',
      'end_local': '2026-10-22',
    });
    sync.setForeground(true);
    await tester.pump(const Duration(hours: 1));
    expect(requests, 1);
    expect(state.error, contains('Cannot reach Spacetime'));
    expect(state.pendingChanges, 1);
    expect(state.entries.single.title, 'Keep this offline edit');
    await tester.pump(const Duration(minutes: 59));
    expect(requests, 1);
    await tester.pump(const Duration(minutes: 1));
    expect(requests, 2);
    expect(tester.takeException(), isNull);
    sync.dispose();
  });

  testWidgets(
    'Restored overdue accounts sync once; disposal stops scheduling',
    (tester) async {
      var requests = 0;
      final state = calendar((request) async {
        requests++;
        return response(request);
      });
      await connect(state);
      state.lastSync =
          tester.binding.clock
              .now()
              .subtract(const Duration(hours: 3))
              .toIso8601String();
      final sync = ForegroundSync(state, now: () => tester.binding.clock.now());
      sync.setForeground(true);
      await tester.pump(const Duration(milliseconds: 1));
      expect(requests, 4);
      sync.dispose();
      await tester.pump(const Duration(hours: 3));
      expect(requests, 4);
    },
  );
}

CalendarState calendar(Future<http.Response> Function(http.Request) handler) =>
    CalendarState(
      Api(client: MockClient(handler)),
      storage: MemoryCalendarStorage(),
    );

Future<void> connect(CalendarState state) async {
  state.user = {'username': 'alex', 'name': 'Alex'};
  await state.refresh();
}

http.Response response(http.Request request) => http.Response(
  jsonEncode(
    request.url.path == '/api/me' ? {'username': 'alex', 'name': 'Alex'} : [],
  ),
  200,
);
