import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spacetime/calendar_panel.dart';
import 'package:spacetime/calendar_storage.dart';
import 'package:spacetime/invitation_panel.dart';
import 'package:spacetime/main.dart';
import 'package:spacetime/models.dart';
import 'package:spacetime/native_platform.dart';
import 'package:spacetime/preference_storage.dart';

CalendarState sample() {
  late CalendarState state;
  state =
      CalendarState(
          Api(
            client: MockClient((request) async {
              if (request.url.path != '/api/groups') {
                throw StateError('Unexpected request: ${request.url.path}');
              }
              return http.Response(
                jsonEncode({'enabled': true, 'groups': state.groups}),
                200,
              );
            }),
          ),
          storage: MemoryCalendarStorage(),
        )
        ..user = {'username': 'alice'}
        ..groupsEnabled = true;
  state.calendars.addAll([
    CalendarCollection({
      'id': 'family',
      '_remote_id': 'server-family',
      '_account': state.account,
      'kind': 'shared',
      'group_id': 'family-group',
      'name': 'Family',
      'color': '#426EB4',
      '_color_override': '#9163B3',
      'owner': 'alice',
    }),
    CalendarCollection({
      'id': 'trips',
      '_remote_id': 'server-trips',
      '_account': state.account,
      'kind': 'shared',
      'name': 'Trips',
      'color': '#BE6946',
    }),
    CalendarCollection({
      'id': 'old',
      '_remote_id': 'foreign',
      '_account': 'https://elsewhere.example#alice',
      'kind': 'shared',
      'name': 'Private old account',
      'color': '#426EB4',
    }),
  ]);
  state.groups = [
    {'id': 'pending', 'name': 'Neighbours', 'membership': 'invite'},
  ];
  state.invitations = [
    for (final item in [
      ('a', 'server-family', 'Dinner'),
      ('b', 'server-trips', 'Walk'),
      ('c', 'server-family', 'Lunch'),
      ('d', 'foreign', 'Unmapped event'),
    ])
      Entry({
        'id': item.$1,
        'calendar_id': item.$2,
        'title': item.$3,
        'kind': 'event',
        'owner': 'bob',
        '_account': state.account,
      }),
    Entry({
      'id': 'old-invite',
      'title': 'Other account invitation',
      'kind': 'event',
      '_account': 'https://elsewhere.example#alice',
    }),
  ];
  return state;
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

  Future<void> open(
    WidgetTester tester,
    CalendarState state, {
    String query = '',
    void Function(CalendarCollection)? onOpen,
    Size size = const Size(900, 2200),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(),
        home: Scaffold(
          body: InvitationsPanel(
            state: state,
            query: query,
            onAction: (operation) => operation(),
            onDetails: (_) {},
            onOpenCalendar: onOpen ?? (_) {},
            onSignIn: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Shared list uses account-bound colours and remote event IDs group together',
    (tester) async {
      final state = sample();
      await open(tester, state);
      final family = find.byKey(const ValueKey('invitation-section-family'));
      await tester.ensureVisible(family);
      expect(
        find.descendant(of: family, matching: find.text('Dinner')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: family, matching: find.text('Lunch')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: family, matching: find.text('Walk')),
        findsNothing,
      );
      final decoration =
          tester.widget<Container>(family).decoration as BoxDecoration;
      expect(
        (decoration.border! as Border).left.color,
        const Color(0xFF9163B3),
      );
      expect(
        find.byKey(const ValueKey('invitation-section-trips')),
        findsOneWidget,
      );
      final other = find.byKey(const ValueKey('invitation-section-other'));
      expect(
        find.descendant(of: other, matching: find.text('Unmapped event')),
        findsOneWidget,
      );
      expect(find.text('Private old account'), findsNothing);
      expect(find.text('Other account invitation'), findsNothing);
      expect(state.invitationCount, 5);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Calendar-name search finds that calendar’s invitations', (
    tester,
  ) async {
    await open(tester, sample(), query: 'FAMILY');
    expect(
      find.byKey(const ValueKey('shared-calendar-card-family')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('invitation-section-family')),
      findsOneWidget,
    );
    expect(find.text('Dinner'), findsOneWidget);
    expect(find.text('Lunch'), findsOneWidget);
    expect(find.text('Walk'), findsNothing);
    expect(find.text('Neighbours'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'A shared calendar stays listed with no pending invitations and opens directly',
    (tester) async {
      final state =
          sample()
            ..invitations = []
            ..groups = [];
      CalendarCollection? opened;
      await open(tester, state, onOpen: (c) => opened = c);
      await tester.tap(find.byKey(const ValueKey('invites-open-family')));
      expect(opened?.id, 'family');
      expect(find.text('No invitations'), findsOneWidget);
      expect(find.text('Shared calendars · 2'), findsOneWidget);
    },
  );

  testWidgets(
    'Accepting a grouped event keeps the correct invitation and queued response',
    (tester) async {
      final state = sample();
      await open(tester, state, query: 'Family');
      final accept = find.byKey(const ValueKey('accept-invite-c'));
      await tester.ensureVisible(accept);
      await tester.tap(accept);
      await tester.pumpAndSettle();
      expect(
        state.invitations.firstWhere((e) => e.id == 'c').data['_response'],
        'accepted',
      );
      expect(
        state.invitations.firstWhere((e) => e.id == 'a').data['_response'],
        isNull,
      );
      expect(find.text('Response queued: accepted'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Narrow cards wrap long names and actions without overflow', (
    tester,
  ) async {
    final state = sample();
    state.groups.single['name'] =
        'The neighbourhood’s very long shared calendar name';
    await open(tester, state, size: const Size(320, 900));
    await tester.ensureVisible(
      find.text('The neighbourhood’s very long shared calendar name'),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    state.user = null;
    state.notifyListeners();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('shared-calendar-card-family')),
      findsNothing,
    );
    expect(state.invitationCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'New shared calendars suggest an unused colour and editing preserves overrides',
    (tester) async {
      final state = sample();
      expect(suggestedCalendarColor(state), '#426EB4');
      state.calendars.add(
        CalendarCollection({'id': 'blue', 'color': '#426EB4'}),
      );
      expect(suggestedCalendarColor(state), '#B88A2C');
      await open(tester, state);
      Finder colour(String name) => find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.label == '$name calendar colour',
      );
      await tester.tap(
        find.byKey(const ValueKey('invites-create-shared-calendar')),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<Semantics>(colour('Gold')).properties.selected,
        true,
      );
      await tester.tap(colour('Green'));
      await tester.tap(find.widgetWithText(ChoiceChip, 'Personal'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Shared'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Semantics>(colour('Green')).properties.selected,
        true,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('invites-settings-family')));
      await tester.pumpAndSettle();
      final purple = find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.label == 'Purple calendar colour',
      );
      expect(tester.widget<Semantics>(purple).properties.selected, true);
      expect(tester.takeException(), isNull);
    },
  );
}
