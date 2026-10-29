import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spacetime/calendar_panel.dart';
import 'package:spacetime/calendar_storage.dart';
import 'package:spacetime/main.dart';
import 'package:spacetime/models.dart';
import 'package:spacetime/native_platform.dart';
import 'package:spacetime/preference_storage.dart';

class SharingServer {
  final requests = <http.Request>[];
  bool failMembership = false;
  final group = <String, dynamic>{
    'id': 'household',
    'name': 'Household',
    'membership': 'join',
    'owner': true,
  };
  late final state = CalendarState(
    Api(
      client: MockClient((request) async {
        requests.add(request);
        dynamic value;
        if (request.url.path == '/api/groups') {
          value =
              request.method == 'POST'
                  ? group
                  : {
                    'enabled': true,
                    'groups': [group],
                  };
        } else if (request.url.path == '/api/calendars' &&
            request.method == 'POST') {
          value = {
            ...jsonDecode(request.body) as Map,
            'owner': 'alice',
            'version': 1,
          };
        } else if (request.url.path.endsWith('/membership')) {
          if (failMembership) {
            return http.Response('{"error":"Group service unavailable"}', 503);
          }
          value = {'membership': jsonDecode(request.body)['action']};
        } else {
          throw StateError('Unexpected ${request.method} ${request.url.path}');
        }
        return http.Response(jsonEncode(value), 200);
      }),
    ),
    storage: MemoryCalendarStorage(),
  )..user = {'username': 'alice'};

  Future<CalendarCollection> create() => state.createSharedCalendar(
    'Household',
    '#376B51',
    requestId: 'stable-request',
  );
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final loader = FontLoader('Spacetime');
    loader.addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'));
    await loader.load();
  });
  setUp(() async {
    nativePreferences.clear();
    await writePreference('spacetime.server', 'https://calendar.example');
  });

  test(
    'Creation validates before creating a group and immediately permits invites',
    () async {
      final server = SharingServer();
      await expectLater(
        server.state.createSharedCalendar('  ', '#376B51', requestId: 'blank'),
        throwsA(isA<ApiException>()),
      );
      expect(server.requests, isEmpty);
      final calendar = await server.create();
      expect(server.state.canInviteToCalendar(calendar), true);
      expect(server.state.selectedCalendarId, calendar.id);
      await server.state.inviteToSharedCalendar(calendar, ' @bobby ');
      final body = jsonDecode(server.requests.last.body);
      expect(body, {'action': 'invite', 'user_id': 'bobby'});
      expect(server.requests.where((r) => r.url.path == '/api/me'), isEmpty);
      expect(
        jsonDecode(server.requests.first.body)['txn_id'],
        'stable-request',
      );
    },
  );

  test(
    'Reusing a group creates no duplicate and members cannot invite',
    () async {
      final server = SharingServer();
      server.state.groups = [
        {...server.group, 'owner': false},
      ];
      final calendar = await server.state.createSharedCalendar(
        'Trips',
        '#376B51',
        groupId: 'household',
        requestId: 'existing',
      );
      expect(server.requests.length, 1);
      expect(server.state.canInviteToCalendar(calendar), false);
      await expectLater(
        server.state.inviteToSharedCalendar(calendar, 'bobby'),
        throwsA(isA<ApiException>()),
      );
      expect(server.requests.length, 1);
    },
  );

  test(
    'Leaving clears only this account’s group caches and preserves server entries',
    () async {
      final server = SharingServer();
      final c = await server.create();
      final state = server.state;
      final other = CalendarCollection({
        ...c.data,
        'id': 'other-group',
        'group_id': 'other',
      });
      final sibling = CalendarCollection({...c.data, 'id': 'sibling'});
      final otherAccount = CalendarCollection({
        ...c.data,
        'id': 'other-account',
        '_account': 'https://other.example#alice',
      });
      state.calendars.addAll([other, sibling, otherAccount]);
      state.entries = [
        for (final id in [c.id, sibling.id, other.id, otherAccount.id])
          Entry({
            'id': 'entry-$id',
            'calendar_id': id,
            'title': id,
            'kind': 'todo',
            '_dirty': true,
          }),
      ];
      state.tombstones = [for (final e in state.entries) e.data];
      state.hiddenCalendars = {c.id, sibling.id, other.id};
      state.hiddenTodoCalendars = {c.id, sibling.id};
      await state.leaveSharedCalendar(c);
      expect(
        state.calendars.map((c) => c.id),
        containsAll(['device', other.id, otherAccount.id]),
      );
      expect(state.calendars.map((c) => c.id), isNot(contains(sibling.id)));
      expect(state.entries.map((e) => e.calendarId), [
        other.id,
        otherAccount.id,
      ]);
      expect(state.tombstones.length, 2);
      expect(state.hiddenCalendars, {other.id});
      expect(state.hiddenTodoCalendars, isEmpty);
      expect(state.selectedCalendarId, 'device');
      expect(state.groups.single['membership'], 'leave');
      expect(server.requests.last.method, 'POST');
      expect(jsonDecode(server.requests.last.body), {'action': 'leave'});
      expect(server.requests.any((r) => r.method == 'DELETE'), false);
      final snapshot = jsonDecode(
        (state.storage as MemoryCalendarStorage).value!,
      );
      expect(
        (snapshot['calendars'] as List).any((v) => v['id'] == c.id),
        false,
      );
    },
  );

  test('Failed leave and leaving during sync preserve the calendar', () async {
    final server = SharingServer();
    final c = await server.create();
    server.failMembership = true;
    await expectLater(
      server.state.leaveSharedCalendar(c),
      throwsA(isA<ApiException>()),
    );
    expect(server.state.calendars, contains(c));
    expect(server.state.groups.single['membership'], 'join');
    server.state.loading = true;
    final before = server.requests.length;
    await expectLater(
      server.state.leaveSharedCalendar(c),
      throwsA(isA<ApiException>()),
    );
    expect(server.requests.length, before);
  });

  Future<void> panel(WidgetTester tester, CalendarState state) async {
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: CalendarPanel(state: state))),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Create, invite, cancel leaving, and leave are available in the panel',
    (tester) async {
      final server = SharingServer();
      server.state.groupsEnabled = true;
      await panel(tester, server.state);
      await tester.tap(find.byKey(const ValueKey('create-shared-calendar')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('calendar-name')),
        'Household',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.byType(CalendarDialog), findsNothing);
      final c = server.state.calendars.last;
      await tester.tap(find.byTooltip('Household settings').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Invite to calendar'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '@bobby:remote.example');
      server.failMembership = true;
      await tester.tap(find.text('Invite'));
      await tester.pumpAndSettle();
      expect(find.text('Group service unavailable'), findsOneWidget);
      server.failMembership = false;
      await tester.tap(find.text('Invite'));
      await tester.pumpAndSettle();
      expect(find.byType(CalendarInviteDialog), findsNothing);
      expect(
        jsonDecode(server.requests.last.body)['user_id'],
        '@bobby:remote.example',
      );
      await tester.tap(find.byTooltip('Household settings').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Leave calendar'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(server.state.calendars, contains(c));
      await tester.tap(find.byTooltip('Household settings').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Leave calendar'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Leave calendar'));
      await tester.pumpAndSettle();
      expect(server.state.calendars, isNot(contains(c)));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Consent completion rebuilds an open shared calendar dialog', (
    tester,
  ) async {
    final server = SharingServer();
    await panel(tester, server.state);
    await tester.tap(find.byKey(const ValueKey('create-shared-calendar')));
    await tester.pumpAndSettle();
    server.state.groupsEnabled = true;
    server.state.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('Enable shared calendars with Gravitas'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('Members have a leave action without owner permissions', (
    tester,
  ) async {
    final server = SharingServer();
    await server.create();
    server.state.groups.single['owner'] = false;
    await panel(tester, server.state);
    await tester.tap(find.byTooltip('Household settings').first);
    await tester.pumpAndSettle();
    expect(find.text('Invite to calendar'), findsNothing);
    expect(find.text('Leave calendar'), findsOneWidget);
  });

  for (final size in [const Size(320, 640), const Size(1200, 900)]) {
    testWidgets('Calendar management is visible from the header at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = CalendarState(Api(), storage: MemoryCalendarStorage());
      await tester.pumpWidget(SpacetimeApp(state: state));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Calendars & todos'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('create-shared-calendar')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('create-shared-calendar')));
      await tester.pumpAndSettle();
      expect(find.byType(CalendarDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
