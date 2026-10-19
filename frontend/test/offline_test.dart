import 'dart:convert';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spacetime/calendar_storage.dart';
import 'package:spacetime/local_recurrence.dart';
import 'package:spacetime/local_icalendar.dart';
import 'package:spacetime/models.dart';
import 'package:spacetime/native_platform.dart';
import 'package:spacetime/preference_storage.dart';

Map<String, dynamic> event({
  String start = '2026-01-01T09:00:00',
  String? end,
  String rule = '',
  String zone = 'UTC',
  bool allDay = false,
  String kind = 'event',
}) => normalizeLocalEvent({
  'id': 'test',
  'owner': 'local',
  'version': 1,
  'title': 'Offline',
  'kind': kind,
  'all_day': allDay,
  'timezone': zone,
  'rrule': rule,
  'start_local': start,
  if (kind != 'todo')
    'end_local':
        end ??
        wallString(
          parseWall(
            start,
          ).add(allDay ? const Duration(days: 1) : const Duration(hours: 1)),
          allDay,
        ),
  if (kind == 'todo')
    'due_local':
        end ??
        wallString(parseWall(start).add(const Duration(hours: 1)), allDay),
});
List<Map<String, dynamic>> expand(
  Map<String, dynamic> e, {
  String from = '2026-01-01',
  String to = '2027-01-01',
}) => expandLocalEvent(
  e,
  DateTime.parse('${from}T00:00:00Z'),
  DateTime.parse('${to}T00:00:00Z'),
);
List<String> dates(List<Map<String, dynamic>> instances) =>
    instances
        .map((e) => (e['start_local'] as String).substring(0, 10))
        .toList();
void main() {
  setUp(() {
    nativePreferences.clear();
  });
  test(
    'Startup, CRUD, views, exceptions, todo completion and disconnect never make a network request',
    () async {
      var requests = 0;
      final api = Api(
        client: MockClient((_) async {
          requests++;
          throw StateError('Network forbidden');
        }),
      );
      final disk = MemoryCalendarStorage();
      final state = CalendarState(api, storage: disk);
      await state.restore();
      expect(state.user, isNull);
      await state.save(event(rule: 'FREQ=DAILY;COUNT=3'));
      await state.setRange(DateTime.utc(2026, 1, 1), DateTime.utc(2026, 2, 1));
      expect(state.occurrences.length, 3);
      await state.occurrenceAction(state.occurrences[1], 'skip');
      expect(state.occurrences.length, 2);
      final id = state.entries.single.id;
      await state.save({
        ...state.entries.single.data,
        'title': 'Edited offline',
      }, id: id);
      final todo = event(kind: 'todo', start: '2026-01-02T10:00:00');
      await state.save(todo);
      await state.complete(state.entries.last, true);
      expect(state.entries.last.completed, true);
      final restored = CalendarState(api, storage: disk);
      await restored.restore();
      await restored.setRange(
        DateTime.utc(2026, 1, 1),
        DateTime.utc(2026, 2, 1),
      );
      expect(restored.entries.first.title, 'Edited offline');
      expect(restored.occurrences.where((e) => e.kind == 'event').length, 2);
      expect(restored.entries.last.completed, true);
      await restored.signOut();
      expect(restored.entries.length, 2);
      await restored.remove(restored.entries.first);
      expect(restored.entries.length, 1);
      expect(requests, 0);
    },
  );
  test(
    'A failed disk write rolls back the mutation and keeps the previous database',
    () async {
      final storage = FailingStorage();
      final state = CalendarState(Api(), storage: storage);
      await state.save(event());
      storage.fail = true;
      await expectLater(
        state.save(event(start: '2026-01-02T09:00:00')),
        throwsA(isA<StateError>()),
      );
      expect(state.entries.length, 1);
      final restored = CalendarState(Api(), storage: storage);
      await restored.restore();
      expect(restored.entries.length, 1);
    },
  );
  test(
    'Concurrent offline saves are serialized without losing entries',
    () async {
      final state = CalendarState(Api(), storage: MemoryCalendarStorage());
      await Future.wait(
        List.generate(20, (i) => state.save({...event(), 'title': 'Event $i'})),
      );
      expect(state.entries.length, 20);
      expect(state.entries.map((e) => e.id).toSet().length, 20);
    },
  );
  test('Every two weeks honors WKST Sunday and Monday', () {
    final monday = event(
      start: '1997-08-05T09:00:00',
      rule: 'FREQ=WEEKLY;INTERVAL=2;COUNT=4;BYDAY=TU,SU;WKST=MO',
    );
    final sunday = event(
      start: '1997-08-05T09:00:00',
      rule: 'FREQ=WEEKLY;INTERVAL=2;COUNT=4;BYDAY=TU,SU;WKST=SU',
    );
    expect(dates(expand(monday, from: '1997-08-01', to: '1997-09-01')), [
      '1997-08-05',
      '1997-08-10',
      '1997-08-19',
      '1997-08-24',
    ]);
    expect(dates(expand(sunday, from: '1997-08-01', to: '1997-09-01')), [
      '1997-08-05',
      '1997-08-17',
      '1997-08-19',
      '1997-08-31',
    ]);
  });
  test('Month-end recurrence skips invalid dates without consuming COUNT', () {
    expect(
      dates(
        expand(
          event(start: '2026-01-31T09:00:00', rule: 'FREQ=MONTHLY;COUNT=4'),
        ),
      ),
      ['2026-01-31', '2026-03-31', '2026-05-31', '2026-07-31'],
    );
  });
  test(
    'Every three months and last weekday BYSETPOS preserve period boundaries',
    () {
      expect(
        dates(
          expand(
            event(
              start: '2026-01-30T09:00:00',
              rule:
                  'FREQ=MONTHLY;INTERVAL=3;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1;COUNT=4',
            ),
          ),
        ),
        ['2026-01-30', '2026-04-30', '2026-07-31', '2026-10-30'],
      );
      expect(
        dates(
          expand(
            event(
              start: '2026-01-30T09:00:00',
              rule: 'FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1',
            ),
            from: '2026-04-15',
            to: '2026-05-01',
          ),
        ),
        ['2026-04-30'],
      );
    },
  );
  test('Leap-day occasions recur only on February 29', () {
    final e = event(
      start: '2024-02-29',
      rule: 'FREQ=YEARLY;COUNT=3',
      allDay: true,
      kind: 'occasion',
    );
    expect(dates(expand(e, from: '2024-01-01', to: '2034-01-01')), [
      '2024-02-29',
      '2028-02-29',
      '2032-02-29',
    ]);
    expect(e['attendees'], isEmpty);
    expect(e['location'], '');
  });
  test(
    'DST spring gaps are omitted before COUNT and folds use first instant',
    () {
      final e = event(
        start: '2026-03-07T02:30:00',
        rule: 'FREQ=DAILY;COUNT=3',
        zone: 'America/New_York',
      );
      final instances = expand(e, from: '2026-03-06', to: '2026-03-12');
      expect(dates(instances), ['2026-03-07', '2026-03-09', '2026-03-10']);
      expect(instances.map((e) => e['start']), [
        '2026-03-07T07:30:00.000Z',
        '2026-03-09T06:30:00.000Z',
        '2026-03-10T06:30:00.000Z',
      ]);
      final fold = expand(
        event(
          start: '2026-10-31T01:30:00',
          rule: 'FREQ=DAILY;COUNT=3',
          zone: 'America/New_York',
        ),
        from: '2026-10-30',
        to: '2026-11-04',
      );
      expect(fold[1]['start'], '2026-11-01T05:30:00.000Z');
      expect(fold[2]['start'], '2026-11-02T06:30:00.000Z');
    },
  );
  test('UTC UNTIL is inclusive across a DST change', () {
    expect(
      dates(
        expand(
          event(
            start: '2026-03-07T09:00:00',
            zone: 'America/New_York',
            rule: 'FREQ=DAILY;UNTIL=20260309T130000Z',
          ),
          from: '2026-03-01',
          to: '2026-04-01',
        ),
      ),
      ['2026-03-07', '2026-03-08', '2026-03-09'],
    );
  });
  test('All-day dates and floating times retain their civil fields', () {
    final e = event(
      start: '2011-12-29',
      allDay: true,
      rule: 'FREQ=DAILY;COUNT=3',
    );
    expect(dates(expand(e, from: '2011-12-28', to: '2012-01-02')), [
      '2011-12-29',
      '2011-12-30',
      '2011-12-31',
    ]);
    final f = event(
      start: '2026-03-07T09:00:00',
      zone: 'floating',
      rule: 'FREQ=DAILY;COUNT=3',
    );
    expect(
      expand(
        f,
        from: '2026-03-01',
        to: '2026-04-01',
      ).map((e) => e['start_local']),
      ['2026-03-07T09:00:00', '2026-03-08T09:00:00', '2026-03-09T09:00:00'],
    );
  });
  test('Recurrence set unions RDATE, deduplicates, then applies EXDATE', () {
    final e = {
      ...event(rule: 'FREQ=DAILY;COUNT=3'),
      'rdates': ['2026-01-02T09:00:00', '2026-01-10T09:00:00'],
      'exdates': ['2026-01-01T09:00:00', '2026-01-02T09:00:00'],
    };
    expect(dates(expand(e)), ['2026-01-03', '2026-01-10']);
  });
  test(
    'Invalid or incompatible UNTIL and COUNT combinations are rejected offline',
    () {
      for (final rule in [
        'FREQ=DAILY;COUNT=3;UNTIL=20260103T090000Z',
        'FREQ=WEEKLY;INTERVAL=0',
        'FREQ=DAILY;UNTIL=20260103',
      ]) {
        expect(() => event(rule: rule), throwsA(anything));
      }
    },
  );
  test(
    'Imported moved and THISANDFUTURE exceptions work outside their original window',
    () {
      final raw = calendar(
        'DTSTART:20260101T090000Z\nDTEND:20260101T100000Z\nRRULE:FREQ=DAILY;COUNT=4',
        extra:
            'BEGIN:VEVENT\nUID:sample\nRECURRENCE-ID:20260102T090000Z\nDTSTART:20260201T090000Z\nDTEND:20260201T100000Z\nSUMMARY:Moved\nEND:VEVENT\n'
            'BEGIN:VEVENT\nUID:sample\nRECURRENCE-ID;RANGE=THISANDFUTURE:20260103T090000Z\nDTSTART:20260103T110000Z\nDTEND:20260103T120000Z\nSUMMARY:Later\nEND:VEVENT\n',
      );
      final e = hydrateCalendarData({
        ...event(rule: 'FREQ=DAILY;COUNT=4'),
        'calendar_data': raw,
      });
      final january = expand(e, from: '2026-01-01', to: '2026-01-06');
      expect(january.length, 3);
      expect(january.last['start_local'], '2026-01-04T11:00:00');
      final february = expand(e, from: '2026-02-01', to: '2026-02-02');
      expect(february.single['title'], 'Moved');
      expect(february.single['recurrence_id'], '20260102T090000Z');
      expect(e['calendar_data'], raw);
    },
  );
  test('Embedded VTIMEZONE works without IANA or a server', () {
    final raw =
        'BEGIN:VCALENDAR\nVERSION:2.0\nBEGIN:VTIMEZONE\nTZID:Custom/Zone\nBEGIN:STANDARD\nDTSTART:19700101T000000\nTZOFFSETFROM:+0530\nTZOFFSETTO:+0530\nEND:STANDARD\nEND:VTIMEZONE\nBEGIN:VEVENT\nUID:sample\nDTSTART;TZID=Custom/Zone:20260101T090000\nDTEND;TZID=Custom/Zone:20260101T100000\nRRULE:FREQ=DAILY;COUNT=2\nEND:VEVENT\nEND:VCALENDAR';
    final e = hydrateCalendarData({
      ...event(rule: 'FREQ=DAILY;COUNT=2'),
      'timezone': 'Custom/Zone',
      'calendar_data': raw,
    });
    final instances = expand(e);
    expect(instances.first['start'], '2026-01-01T03:30:00.000Z');
    expect(instances.length, 2);
  });
  test(
    'Manual sync uploads changes once, downloads invites, and resumes offline',
    () async {
      await writePreference('spacetime.server', 'https://sync.test');
      var calls = 0;
      final remote = <Map<String, dynamic>>[];
      final api = Api(
        client: MockClient((r) async {
          calls++;
          if (r.url.path == '/api/login') {
            return http.Response(
              jsonEncode({
                'token': 'token',
                'user': {'username': 'alex', 'name': 'Alex'},
              }),
              200,
            );
          }
          if (r.url.path == '/api/me') {
            return http.Response('{"username":"alex"}', 200);
          }
          if (r.url.path == '/api/invitations') return http.Response('[]', 200);
          if (r.method == 'POST') {
            final item =
                Map<String, dynamic>.from(jsonDecode(r.body) as Map)
                  ..['id'] = 'server-id'
                  ..['version'] = 1
                  ..['owner'] = 'alex';
            remote.add(item);
            return http.Response(jsonEncode(item), 201);
          }
          return http.Response(jsonEncode(remote), 200);
        }),
      );
      final disk = MemoryCalendarStorage();
      final state = CalendarState(api, storage: disk);
      await state.save(event());
      expect(calls, 0);
      await state.signIn('alex', 'password');
      expect(calls, 1);
      expect(state.entries.length, 1);
      await state.sync();
      expect(remote.length, 1);
      expect(state.pendingChanges, 0);
      final before = calls;
      await state.setRange(DateTime.utc(2026), DateTime.utc(2027));
      final restored = CalendarState(api, storage: disk);
      await restored.restore();
      await restored.signOut();
      expect(calls, before);
      expect(restored.entries.length, 1);
    },
  );
  test('Sync conflicts preserve edits until an explicit resolution', () async {
    await writePreference('spacetime.server', 'https://sync.test');
    final remote = {
      ...event(),
      'id': 'remote',
      'version': 3,
      'owner': 'alex',
      'title': 'Server edit',
    };
    final state = CalendarState(
      Api(
        client: MockClient(
          (r) async => http.Response(
            jsonEncode(
              r.url.path == '/api/me' ? {'username': 'alex'} : [remote],
            ),
            200,
          ),
        ),
      ),
      storage: MemoryCalendarStorage(),
    );
    state.user = {'username': 'alex'};
    state.entries = [
      Entry({
        ...event(),
        'title': 'Device edit',
        '_account': state.account,
        '_remote_id': 'remote',
        '_remote_version': 2,
        '_dirty': true,
      }),
    ];
    await expectLater(state.sync(), throwsA(isA<ApiException>()));
    expect(state.conflicts.length, 1);
    expect(state.entries.single.title, 'Device edit');
    await state.resolveConflict(state.conflicts.single, keepDevice: false);
    expect(state.entries.single.title, 'Server edit');
    expect(state.entries.single.data['_dirty'], false);
  });
  test(
    'A deletion conflict can keep the server copy without losing it',
    () async {
      await writePreference('spacetime.server', 'https://sync.test');
      final remote = {
        ...event(),
        'id': 'remote',
        'version': 3,
        'owner': 'alex',
      };
      final state = CalendarState(
        Api(
          client: MockClient(
            (r) async => http.Response(
              jsonEncode(
                r.url.path == '/api/me' ? {'username': 'alex'} : [remote],
              ),
              200,
            ),
          ),
        ),
        storage: MemoryCalendarStorage(),
      )..user = {'username': 'alex'};
      state.tombstones = [
        {
          ...event(),
          '_account': state.account,
          '_remote_id': 'remote',
          '_remote_version': 2,
        },
      ];
      await expectLater(state.sync(), throwsA(isA<ApiException>()));
      expect(state.conflicts.length, 1);
      await state.resolveConflict(state.conflicts.single, keepDevice: false);
      expect(state.tombstones, isEmpty);
      expect(state.entries.length, 1);
    },
  );
  test(
    'A create that succeeds before a failed download is not uploaded twice',
    () async {
      await writePreference('spacetime.server', 'https://sync.test');
      var posts = 0, reads = 0, fail = true;
      final remote = <Map<String, dynamic>>[];
      final state = CalendarState(
        Api(
          client: MockClient((r) async {
            if (r.url.path == '/api/me') {
              return http.Response('{"username":"alex"}', 200);
            }
            if (r.url.path == '/api/invitations') {
              return http.Response('[]', 200);
            }
            if (r.method == 'POST') {
              posts++;
              final value =
                  Map<String, dynamic>.from(jsonDecode(r.body) as Map)
                    ..['id'] = 'remote'
                    ..['version'] = 1
                    ..['owner'] = 'alex';
              remote.add(value);
              return http.Response(jsonEncode(value), 201);
            }
            reads++;
            if (reads == 2 && fail) throw StateError('Offline again');
            return http.Response(jsonEncode(remote), 200);
          }),
        ),
        storage: MemoryCalendarStorage(),
      )..user = {'username': 'alex'};
      await state.save(event());
      await expectLater(state.sync(), throwsA(isA<ApiException>()));
      expect(posts, 1);
      expect(state.entries.single.data['_remote_id'], 'remote');
      fail = false;
      await state.sync();
      expect(posts, 1);
      expect(state.entries.length, 1);
    },
  );
  test(
    'Edits made during upload stay dirty and retain the server mapping',
    () async {
      await writePreference('spacetime.server', 'https://sync.test');
      final started = Completer<void>(), release = Completer<void>();
      final remote = <Map<String, dynamic>>[];
      final state = CalendarState(
        Api(
          client: MockClient((r) async {
            if (r.url.path == '/api/me') {
              return http.Response('{"username":"alex"}', 200);
            }
            if (r.url.path == '/api/invitations') {
              return http.Response('[]', 200);
            }
            if (r.method == 'POST') {
              started.complete();
              await release.future;
              final value =
                  Map<String, dynamic>.from(jsonDecode(r.body) as Map)
                    ..['id'] = 'remote'
                    ..['version'] = 1
                    ..['owner'] = 'alex';
              remote.add(value);
              return http.Response(jsonEncode(value), 201);
            }
            return http.Response(jsonEncode(remote), 200);
          }),
        ),
        storage: MemoryCalendarStorage(),
      )..user = {'username': 'alex'};
      await state.save(event());
      final syncing = state.sync();
      await started.future;
      await state.save({
        ...state.entries.single.data,
        'title': 'Edited during sync',
      }, id: state.entries.single.id);
      release.complete();
      await syncing;
      expect(state.entries.single.title, 'Edited during sync');
      expect(state.entries.single.data['_dirty'], true);
      expect(state.entries.single.data['_remote_id'], 'remote');
    },
  );
  test(
    'Timed day views use device midnight while date-only days stay civil',
    () {
      final e = event(start: '2026-10-19T03:30:00');
      final rows = expandLocalEvent(
        e,
        DateTime.utc(2026, 10, 18),
        DateTime.utc(2026, 10, 19),
        viewTimezone: 'America/Toronto',
      );
      expect(rows.length, 1);
      final all = event(start: '2011-12-30', allDay: true);
      expect(
        expandLocalEvent(
          all,
          DateTime.utc(2011, 12, 30),
          DateTime.utc(2011, 12, 31),
          viewTimezone: 'Pacific/Apia',
        ).length,
        1,
      );
    },
  );
  test('Synced skips are not sent again on a later series edit', () async {
    await writePreference('spacetime.server', 'https://sync.test');
    Map<String, dynamic>? remote;
    var exceptionPosts = 0;
    final state = CalendarState(
      Api(
        client: MockClient((r) async {
          if (r.url.path == '/api/me') {
            return http.Response('{"username":"alex"}', 200);
          }
          if (r.url.path == '/api/invitations') return http.Response('[]', 200);
          if (r.url.path.endsWith('/exceptions')) {
            exceptionPosts++;
            final body = jsonDecode(r.body) as Map;
            remote!['exdates'] = [
              DateTime.parse(body['recurrence_id'] as String).toIso8601String(),
            ];
            remote!['version'] = (remote!['version'] as int) + 1;
            return http.Response('', 204);
          }
          if (r.method == 'POST' || r.method == 'PUT') {
            final body = Map<String, dynamic>.from(jsonDecode(r.body) as Map);
            remote = {
              ...body,
              'id': 'remote',
              'owner': 'alex',
              'version': (remote?['version'] as int? ?? 0) + 1,
            };
            return http.Response(jsonEncode(remote), 200);
          }
          return http.Response(jsonEncode(remote == null ? [] : [remote]), 200);
        }),
      ),
      storage: MemoryCalendarStorage(),
    )..user = {'username': 'alex'};
    await state.save(event(rule: 'FREQ=DAILY;COUNT=3'));
    await state.setRange(DateTime.utc(2026), DateTime.utc(2027));
    await state.occurrenceAction(state.occurrences[1], 'skip');
    await state.sync();
    expect(exceptionPosts, 1);
    expect(state.occurrences.length, 2);
    await state.save({
      ...state.entries.single.data,
      'title': 'Renamed',
    }, id: state.entries.single.id);
    await state.sync();
    expect(exceptionPosts, 1);
    expect(state.entries.single.title, 'Renamed');
    expect(state.occurrences.length, 2);
  });
}

String calendar(String body, {String extra = ''}) =>
    'BEGIN:VCALENDAR\nVERSION:2.0\nBEGIN:VEVENT\nUID:sample\n$body\nEND:VEVENT\n${extra}END:VCALENDAR';

class FailingStorage extends MemoryCalendarStorage {
  bool fail = false;
  @override
  Future<void> write(String value) async {
    if (fail) throw StateError('Disk full');
    await super.write(value);
  }
}
