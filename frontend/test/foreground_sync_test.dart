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
  testWidgets(
    'Sync starts on connection, refreshes hourly and stops on logout',
    (tester) async {
      final server = SyncServer();
      final state = server.state();
      final sync = scheduler(state, tester)..setForeground(true);
      await tester.pump(const Duration(hours: 2));
      expect(server.calls, isEmpty);
      await connect(state);
      await flushSync(tester);
      expect(server.calls.length, 4);
      await tester.pump(const Duration(minutes: 59));
      expect(server.calls.length, 4);
      await tester.pump(const Duration(minutes: 1));
      expect(server.calls.length, 8);
      await state.signOut();
      await tester.pump(const Duration(hours: 2));
      expect(server.calls.length, 8);
      sync.dispose();
    },
  );
  testWidgets(
    'A confirmed 401 invokes one foreground recovery without rapid retry',
    (tester) async {
      final state = CalendarState(
        Api(
          client: MockClient(
            (_) async => http.Response('{"error":"Expired"}', 401),
          ),
        ),
        storage: MemoryCalendarStorage(),
      );
      await connect(state);
      var recoveries = 0;
      final sync = ForegroundSync(
        state,
        now: () => tester.binding.clock.now(),
        onUnauthorized: () async {
          recoveries++;
        },
      );
      sync.setForeground(true);
      await flushSync(tester);
      expect(recoveries, 1);
      await tester.pump(const Duration(minutes: 5));
      expect(recoveries, 1);
      sync.dispose();
    },
  );
  testWidgets(
    'A renewed bearer resumes queued sync without an edit or resume',
    (tester) async {
      final server = SyncServer();
      var expiredRequests = 0;
      final state = CalendarState(
        Api(
          client: MockClient((request) async {
            if (request.headers['Authorization'] != 'Bearer renewed') {
              expiredRequests++;
              return http.Response('{"error":"Expired"}', 401);
            }
            return server.request(request);
          }),
        ),
        storage: MemoryCalendarStorage(),
      );
      state.api.token = 'old';
      await connect(state);
      await state.save(event('Queued after expiry'));
      final generation = state.localChangeGeneration;
      final sync = ForegroundSync(
        state,
        now: () => tester.binding.clock.now(),
        onUnauthorized: () async {
          state.api.token = 'renewed';
          await state.refresh();
        },
      );
      addTearDown(sync.dispose);
      sync.setForeground(true);
      await flushSync(tester);
      expect(expiredRequests, 1);
      expect(server.calls, isEmpty);
      await flushSync(tester);
      expect(server.calls, isNotEmpty);
      expect(state.lastSync, isNotNull);
      expect(state.localChangeGeneration, generation);
      expect(server.remote.single['title'], 'Queued after expiry');
      expect(state.pendingChanges, 0);
      expect(
        server.calls.every(
          (request) => request.headers['Authorization'] == 'Bearer renewed',
        ),
        true,
      );
      sync.dispose();
    },
  );

  testWidgets('Hidden apps queue changes and catch up once on return', (
    tester,
  ) async {
    final server = SyncServer();
    final state = server.state();
    final sync = scheduler(state, tester);
    await connect(state);
    await state.save(event('Hidden'));
    await tester.pump(const Duration(hours: 10));
    expect(server.calls, isEmpty);
    sync.setForeground(true);
    await flushSync(tester);
    expect(server.remote.single['title'], 'Hidden');
    expect(state.pendingChanges, 0);
    final count = server.calls.length;
    sync.setForeground(false);
    await tester.pump(const Duration(hours: 10));
    expect(server.calls.length, count);
    sync.setForeground(true);
    await flushSync(tester);
    expect(server.calls.length, count + 4);
    sync.dispose();
  });
  testWidgets(
    'CRUD, todo completion, recurrence exceptions and RSVPs autosync',
    (tester) async {
      final server = SyncServer();
      final state = server.state();
      final sync = scheduler(state, tester);
      await connect(state);
      sync.setForeground(true);
      await flushSync(tester);
      await state.save(event('Created'));
      await flushSync(tester);
      expect(server.remote.single['title'], 'Created');
      await state.save({
        ...state.entries.single.data,
        'title': 'Edited',
      }, id: state.entries.single.id);
      await flushSync(tester);
      expect(server.remote.single['title'], 'Edited');
      await state.remove(state.entries.single);
      await flushSync(tester);
      expect(server.remote, isEmpty);
      expect(state.tombstones, isEmpty);
      await state.save({
        ...event('Task'),
        'kind': 'todo',
        'due_local': '2026-10-22',
      });
      await flushSync(tester);
      await state.complete(state.entries.single, true);
      await flushSync(tester);
      expect(server.remote.single['completed'], true);
      await state.save({...event('Recurring'), 'rrule': 'FREQ=DAILY;COUNT=3'});
      await flushSync(tester);
      await state.setRange(
        DateTime.utc(2026, 10, 21),
        DateTime.utc(2026, 10, 25),
      );
      await state.occurrenceAction(
        state.occurrences.firstWhere((e) => e.title == 'Recurring'),
        'skip',
      );
      await flushSync(tester);
      expect(
        server.calls.where((c) => c.url.path.endsWith('/exceptions')).length,
        1,
      );
      server.invites = [
        {...event('Invitation'), 'id': 'invite', 'owner': 'sam', 'version': 1},
      ];
      await state.sync();
      await state.respond(state.invitations.single, 'accepted');
      await flushSync(tester);
      expect(server.responses, ['accepted']);
      expect(state.pendingChanges, 0);
      final count = server.calls.length;
      await tester.pump(const Duration(seconds: 5));
      expect(server.calls.length, count);
      sync.dispose();
    },
  );
  testWidgets(
    'Bursts combine and edits during uploads sync next without loss',
    (tester) async {
      final server = SyncServer();
      final state = server.state();
      final sync = scheduler(state, tester);
      await connect(state);
      sync.setForeground(true);
      await flushSync(tester);
      await state.save(event('First'));
      await state.save({
        ...state.entries.single.data,
        'title': 'Burst',
      }, id: state.entries.single.id);
      final gate = Completer<void>();
      server.uploadGate = gate;
      await flushSync(tester);
      expect(server.calls.where((c) => c.method == 'POST').length, 1);
      await state.save({
        ...state.entries.single.data,
        'title': 'While uploading',
      }, id: state.entries.single.id);
      gate.complete();
      server.uploadGate = null;
      await tester.pump();
      await flushSync(tester);
      expect(server.remote.single['title'], 'While uploading');
      expect(state.entries.single.title, 'While uploading');
      expect(state.pendingChanges, 0);
      expect(server.calls.where((c) => c.method == 'PUT').length, 1);
      sync.dispose();
    },
  );
  testWidgets(
    'Changing an RSVP during delivery preserves the latest response',
    (tester) async {
      final server =
          SyncServer()
            ..invites = [
              {
                ...event('Invite'),
                'id': 'invite',
                'owner': 'sam',
                'version': 1,
              },
            ];
      final state = server.state();
      final sync = scheduler(state, tester);
      await connect(state);
      sync.setForeground(true);
      await flushSync(tester);
      final gate = Completer<void>();
      server.responseGate = gate;
      await state.respond(state.invitations.single, 'accepted');
      await flushSync(tester);
      await state.respond(state.invitations.single, 'declined');
      gate.complete();
      server.responseGate = null;
      await tester.pump();
      await flushSync(tester);
      expect(server.responses, ['accepted', 'declined']);
      expect(state.invitations, isEmpty);
      expect(state.pendingChanges, 0);
      sync.dispose();
    },
  );
  testWidgets('Manual sync consumes queued work without redundant autosync', (
    tester,
  ) async {
    final server = SyncServer();
    final state = server.state();
    final sync = scheduler(state, tester);
    await connect(state);
    sync.setForeground(true);
    await state.save(event('Manual'));
    await state.sync();
    final count = server.calls.length;
    await tester.pump(const Duration(minutes: 59));
    expect(server.calls.length, count);
    await tester.pump(const Duration(minutes: 1));
    expect(server.calls.length, count + 4);
    sync.dispose();
  });
  testWidgets(
    'Offline edits survive and retry with bounded foreground backoff',
    (tester) async {
      final server = SyncServer()..offline = true;
      final state = server.state();
      final sync = scheduler(state, tester);
      await connect(state);
      await state.save(event('Keep offline'));
      sync.setForeground(true);
      await flushSync(tester);
      expect(server.calls.length, 1);
      expect(state.pendingChanges, 1);
      await tester.pump(const Duration(seconds: 29));
      expect(server.calls.length, 1);
      await tester.pump(const Duration(seconds: 1));
      expect(server.calls.length, 2);
      sync.setForeground(false);
      server.offline = false;
      await tester.pump(const Duration(hours: 1));
      expect(server.calls.length, 2);
      sync.setForeground(true);
      await flushSync(tester);
      expect(server.remote.single['title'], 'Keep offline');
      expect(state.pendingChanges, 0);
      sync.dispose();
    },
  );
  testWidgets(
    'Display changes and failed local writes never trigger autosync',
    (tester) async {
      final server = SyncServer();
      final disk = TestStorage();
      final state = server.state(storage: disk);
      final sync = scheduler(state, tester);
      await connect(state);
      sync.setForeground(true);
      await flushSync(tester);
      final count = server.calls.length;
      await state.setMonth(DateTime(2027));
      await state.savePreferences(use24Hour: false);
      disk.fail = true;
      await expectLater(state.save(event('Not persisted')), throwsStateError);
      await flushSync(tester);
      expect(server.calls.length, count);
      expect(state.entries, isEmpty);
      sync.dispose();
      disk.fail = false;
      await state.save(event('After disposal'));
      await tester.pump(const Duration(hours: 2));
      expect(server.calls.length, count);
    },
  );
}

ForegroundSync scheduler(CalendarState state, WidgetTester tester) {
  final sync = ForegroundSync(state, now: () => tester.binding.clock.now());
  addTearDown(sync.dispose);
  return sync;
}

Future<void> flushSync(WidgetTester tester) =>
    tester.pump(ForegroundSync.operationDelay);
Future<void> connect(CalendarState state) async {
  state.user = {'username': 'alex', 'name': 'Alex'};
  await state.refresh();
}

Map<String, dynamic> event(String title) => {
  'title': title,
  'kind': 'event',
  'all_day': true,
  'start_local': '2026-10-21',
  'end_local': '2026-10-22',
};

class TestStorage extends MemoryCalendarStorage {
  bool fail = false;
  @override
  Future<void> write(String data) async {
    if (fail) throw StateError('disk full');
    await super.write(data);
  }
}

class SyncServer {
  final calls = <http.Request>[];
  final remote = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> invites = [];
  final responses = <String>[];
  Completer<void>? uploadGate, responseGate;
  bool offline = false;
  CalendarState state({CalendarStorage? storage}) => CalendarState(
    Api(client: MockClient(request)),
    storage: storage ?? MemoryCalendarStorage(),
  );
  Future<http.Response> request(http.Request req) async {
    calls.add(req);
    if (offline) throw StateError('offline');
    dynamic result;
    if (req.url.path == '/api/me') {
      result = {'username': 'alex', 'name': 'Alex'};
    } else if (req.url.path == '/api/invitations') {
      result = invites;
    } else if (req.url.path.endsWith('/respond')) {
      final status = jsonDecode(req.body)['status'] as String;
      await responseGate?.future;
      responses.add(status);
      invites = [];
      result = null;
    } else if (req.url.path.endsWith('/exceptions')) {
      final item = remote.firstWhere(
        (e) => req.url.path.contains(e['id'] as String),
      );
      item['version'] = (item['version'] as int) + 1;
      result = item;
    } else if (req.method == 'POST' || req.method == 'PUT') {
      final item = Map<String, dynamic>.from(jsonDecode(req.body) as Map)
        ..['owner'] = 'alex';
      item['version'] = (item['version'] as int) + 1;
      await uploadGate?.future;
      remote.removeWhere((e) => e['id'] == item['id']);
      remote.add(item);
      result = item;
    } else if (req.method == 'DELETE') {
      remote.removeWhere((e) => req.url.path.endsWith(e['id'] as String));
      result = null;
    } else {
      result = remote;
    }
    return http.Response(
      result == null ? '' : jsonEncode(result),
      result == null ? 204 : 200,
    );
  }
}
