import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spacetime/calendar_storage.dart';
import 'package:spacetime/models.dart';
import 'package:spacetime/local_recurrence.dart';
import 'package:spacetime/native_platform.dart';
import 'package:spacetime/preference_storage.dart';

Map<String, dynamic> item(String title, {String kind = 'event'}) => {
  'title': title,
  'kind': kind,
  'all_day': true,
  if (kind == 'todo') 'due_local': '2026-10-23',
  if (kind != 'todo') ...{
    'start_local': '2026-10-23',
    'end_local': '2026-10-24',
  },
};
void main() {
  setUp(() async {
    nativePreferences.clear();
    await writePreference('spacetime.server', 'https://calendar.example');
  });
  test(
    'Multiple calendars and independent todo visibility survive offline restart',
    () async {
      var requests = 0;
      final storage = MemoryCalendarStorage();
      final state = CalendarState(
        Api(
          client: MockClient((_) async {
            requests++;
            throw StateError('offline');
          }),
        ),
        storage: storage,
      );
      final work = await state.createCalendar('Work', '#426EB4');
      await state.save(item('Work appointment'));
      await state.selectCalendar('device');
      await state.save(item('Personal task', kind: 'todo'));
      await state.setCalendarVisible(work.id, false);
      await state.setCalendarVisible('device', false, todos: true);
      final restored = CalendarState(Api(), storage: storage);
      await restored.restore();
      expect(requests, 0);
      expect(restored.calendars.map((c) => c.name), ['Personal', 'Work']);
      expect(restored.entries.first.calendarId, work.id);
      expect(restored.entries.last.calendarId, 'device');
      expect(restored.calendarEntries, isEmpty);
      expect(restored.todos, isEmpty);
      await restored.setCalendarVisible('device', true, todos: true);
      expect(restored.todos.single.title, 'Personal task');
      expect(restored.hiddenCalendars, {work.id});
      expect(jsonDecode((await storage.read())!)['schema'], 2);
    },
  );
  test(
    'Legacy device databases retain UIDs, entries and reminders in Personal',
    () async {
      final state = CalendarState(Api(), storage: MemoryCalendarStorage());
      await state.save({...item('Legacy'), 'reminder_minutes': 15});
      final raw =
          jsonDecode((await state.storage.read())!) as Map<String, dynamic>;
      raw['schema'] = 1;
      raw.remove('calendars');
      (raw['entries'] as List).single.remove('calendar_id');
      final uid = state.entries.single.data['uid'];
      await state.storage.write(jsonEncode(raw));
      final restored = CalendarState(Api(), storage: state.storage);
      await restored.restore();
      expect(restored.entries.single.data['uid'], uid);
      expect(restored.entries.single.calendarId, 'device');
      expect(restored.entries.single.data['reminder_minutes'], 15);
      expect(restored.calendars.single.name, 'Personal');
    },
  );
  test(
    'A shared member can create and edit only their own cached entries',
    () async {
      final state = CalendarState(Api(), storage: MemoryCalendarStorage())
        ..user = {'username': 'alice'};
      state.calendars.add(
        CalendarCollection({
          'id': 'shared',
          'name': 'Household',
          'kind': 'shared',
          '_account': state.account,
          '_remote_id': 'group-calendar',
        }),
      );
      await state.selectCalendar('shared');
      await state.save(item('My task', kind: 'todo'));
      final own = state.entries.single;
      expect(state.canEdit(own), true);
      final other = Entry({
        ...own.data,
        'id': 'other',
        'owner': 'bobby',
        '_editable': false,
      });
      state.entries.add(other);
      expect(state.canEdit(other), false);
      expect(state.isInvite(other), false);
      state.showInvites = false;
      await state.refresh();
      expect(state.calendarEntries.map((e) => e.id), contains('other'));
      await expectLater(
        state.save({...other.data, 'title': 'Unauthorized'}, id: other.id),
        throwsA(isA<ApiException>()),
      );
      expect(state.entries.last.title, 'My task');
    },
  );
  test(
    'Calendar metadata syncs before entries and same UID matching stays scoped',
    () async {
      final server = CalendarServer();
      final state = server.state();
      final work = await state.createCalendar('Work', '#426EB4');
      await state.save(item('Work event'));
      await state.selectCalendar('device');
      await state.save(item('Personal event'));
      state.user = {'username': 'alice'};
      await state.sync();
      expect(server.calendars.length, 2);
      expect(server.events.length, 2);
      final workRemote =
          state.calendars.firstWhere((c) => c.id == work.id).remoteId;
      expect(server.events.first['calendar_id'], workRemote);
      expect(server.events.last['calendar_id'], 'default-alice');
      expect(state.pendingChanges, 0);
      final same =
          Map<String, dynamic>.from(server.events.first)
            ..['id'] = 'different-calendar-id'
            ..['calendar_id'] = 'default-alice'
            ..['title'] = 'Same UID in Personal';
      server.events.add(same);
      await state.sync();
      expect(state.entries.length, 3);
      expect(state.entries.where((e) => e.calendarId == work.id).length, 1);
    },
  );
  test(
    'Known removal of shared membership hides cached entries and prevents writes',
    () async {
      final server = CalendarServer();
      final state = server.state()..user = {'username': 'alice'};
      server.calendars.add({
        'id': 'shared',
        'name': 'Shared',
        'color': '#9163B3',
        'kind': 'shared',
        'owner': 'bobby',
        'version': 1,
      });
      server.events.add(
        normalizeLocalEvent({
          ...item('Group event'),
          'id': 'shared-event',
          'owner': 'bobby',
          'calendar_id': 'shared',
          'version': 1,
        }),
      );
      await state.sync();
      final entry = state.entries.single;
      expect(state.canEdit(entry), false);
      expect(state.calendarEntries.single.title, 'Group event');
      server.calendars.removeWhere((c) => c['id'] == 'shared');
      server.events.clear();
      await state.sync();
      expect(state.calendarEntries, isEmpty);
      expect(
        state.calendars.firstWhere((c) => c.remoteId == 'shared').readOnly,
        true,
      );
    },
  );
  test(
    'Server conflicts are displayed authoritatively while the offline edit stays recoverable',
    () async {
      final server = CalendarServer();
      final state = server.state()..user = {'username': 'alice'};
      await state.save({...item('Original'), 'reminder_minutes': 15});
      await state.sync();
      final e = state.entries.single;
      await state.save({...e.data, 'title': 'Offline draft'}, id: e.id);
      server.events.single['title'] = 'Server truth';
      server.events.single['version'] = 2;
      await expectLater(state.sync(), throwsA(isA<ApiException>()));
      expect(state.conflicts.single.title, 'Offline draft');
      expect(state.calendarEntries.single.title, 'Server truth');
      expect(state.calendarEntries.single.data['reminder_minutes'], 15);
      expect(state.canEdit(state.calendarEntries.single), false);
      await state.resolveConflict(state.conflicts.single, keepDevice: false);
      expect(state.entries.single.title, 'Server truth');
      expect(state.entries.single.calendarId, 'device');
    },
  );
  test(
    'Other members can change their own colour without overwriting calendar metadata',
    () async {
      final server = CalendarServer();
      final state = server.state()..user = {'username': 'alice'};
      server.calendars.add({
        'id': 'shared',
        'name': 'Household',
        'color': '#9163B3',
        'kind': 'shared',
        'owner': 'bobby',
        'version': 1,
      });
      await state.sync();
      final shared = state.calendars.firstWhere((c) => c.remoteId == 'shared');
      await state.updateCalendar(shared, shared.name, '#426EB4');
      await state.sync();
      final updated = state.calendars.firstWhere((c) => c.id == shared.id);
      expect(updated.color, '#426EB4');
      expect(updated.dirty, false);
      expect(server.calendars.last['color'], '#9163B3');
      await expectLater(
        state.updateCalendar(updated, 'Rename', '#426EB4'),
        throwsA(isA<ApiException>()),
      );
    },
  );
  test(
    'Changed server calendar settings win over stale offline metadata',
    () async {
      final server = CalendarServer();
      final state = server.state()..user = {'username': 'alice'};
      await state.sync();
      final c = state.calendars.single;
      await state.updateCalendar(c, 'Offline name', '#426EB4');
      server.calendars.single['name'] = 'Server name';
      server.calendars.single['version'] = 2;
      await state.sync();
      expect(state.calendars.single.name, 'Server name');
      expect(state.calendars.single.dirty, false);
    },
  );
  test(
    'Read-only source entries do not become invitations or editable tasks',
    () async {
      final state = CalendarState(Api(), storage: MemoryCalendarStorage())
        ..user = {'username': 'alice'};
      state.calendars.add(
        CalendarCollection({
          'id': 'source',
          'kind': 'source',
          'name': 'Subscribed',
          'read_only': true,
          '_account': state.account,
        }),
      );
      final entry = Entry(
        normalizeLocalEvent({
          ...item('Read only'),
          'id': 'external',
          'owner': 'alice',
          'calendar_id': 'source',
          '_editable': false,
        }),
      );
      state.entries = [entry];
      state.showInvites = false;
      await state.refresh();
      expect(state.calendarEntries.single.title, 'Read only');
      expect(state.isInvite(entry), false);
      expect(state.canEdit(entry), false);
      await state.selectCalendar('source');
      await expectLater(
        state.save(item('Blocked')),
        throwsA(isA<ApiException>()),
      );
    },
  );
}

class CalendarServer {
  final calendars = <Map<String, dynamic>>[
    {
      'id': 'default-alice',
      'owner': 'alice',
      'name': 'Personal',
      'color': '#376B51',
      'kind': 'personal',
      'version': 1,
    },
  ];
  final events = <Map<String, dynamic>>[];
  int next = 0;
  CalendarState state() => CalendarState(
    Api(client: MockClient(request)),
    storage: MemoryCalendarStorage(),
  );
  Future<http.Response> request(http.Request req) async {
    dynamic value;
    final path = req.url.path;
    if (path == '/api/me') {
      value = {'username': 'alice'};
    } else if (path == '/api/calendars' && req.method == 'GET') {
      value = {'calendars': calendars, 'groups': [], 'groups_enabled': false};
    } else if (path == '/api/calendars' && req.method == 'POST') {
      value = Map<String, dynamic>.from(jsonDecode(req.body) as Map)
        ..['owner'] = 'alice';
      calendars.add(value as Map<String, dynamic>);
    } else if (path == '/api/events' && req.method == 'GET') {
      value = events;
    } else if (path == '/api/invitations') {
      value = [];
    } else if (path.startsWith('/api/events') &&
        (req.method == 'POST' || req.method == 'PUT')) {
      final body = Map<String, dynamic>.from(jsonDecode(req.body) as Map);
      value = {
        ...body,
        'id': req.method == 'POST' ? 'remote-${next++}' : body['id'],
        'owner': 'alice',
        'version': (body['version'] as int) + 1,
      };
      events.removeWhere((e) => e['id'] == (value as Map)['id']);
      events.add(value as Map<String, dynamic>);
    } else {
      return http.Response('{"error":"Unexpected request"}', 404);
    }
    return http.Response(jsonEncode(value), 200);
  }
}
