import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spacetime/main.dart';
import 'package:spacetime/models.dart';
import 'package:spacetime/editor.dart';
import 'package:spacetime/recurrence.dart';
import 'package:spacetime/preference_storage.dart';
import 'package:spacetime/native_platform.dart';

Entry entry({
  String kind = 'event',
  bool allDay = false,
  bool yearly = false,
  String start = '2026-10-18T09:00:00Z',
  String end = '2026-10-18T10:00:00Z',
}) => Entry({
  'id': 'test',
  'owner': 'alex',
  'title': 'A thoughtful plan',
  'kind': kind,
  'all_day': allDay,
  'yearly': yearly,
  'start': start,
  'end': end,
  'version': 1,
  'attendees': <String, String>{},
});
CalendarState sample() {
  final state = CalendarState(
    Api(client: MockClient((req) async => http.Response(jsonEncode([]), 200))),
  );
  state.user = {'username': 'alex', 'name': 'Alex Morgan'};
  state.entries = [entry()];
  return state;
}

Future<void> chooseView(WidgetTester tester, String mode) async {
  await tester.tap(find.byKey(const ValueKey('view-selector')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey('view-$mode')));
  await tester.pumpAndSettle();
}

CalendarState visibilitySample() {
  final today = day(DateTime.now());
  final fixtures = [
    for (final item in [
      ('event', 'Work event'),
      ('occasion', 'An occasion'),
      ('todo', 'A task'),
    ])
      {
        'id': item.$1,
        'owner': 'alex',
        'title': item.$2,
        'kind': item.$1,
        'all_day': true,
        'version': 1,
        'start': today.toIso8601String(),
        'end': today.add(const Duration(days: 1)).toIso8601String(),
        if (item.$1 == 'todo') 'due': today.toIso8601String(),
      },
  ];
  final state = CalendarState(
    Api(
      client: MockClient(
        (req) async => http.Response(
          jsonEncode(req.url.path == '/api/invitations' ? [] : fixtures),
          200,
        ),
      ),
    ),
  );
  state.user = {'username': 'alex', 'name': 'Alex'};
  state.entries = fixtures.map(Entry.new).toList();
  return state;
}

void main() {
  setUp(() {
    nativePreferences.remove('spacetime.preferences.device');
  });
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await writePreference('spacetime.server', 'https://spacetime.test');
    final loader = FontLoader('Spacetime');
    loader.addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'));
    await loader.load();
  });
  test('All-day dates keep their calendar date and use exclusive ends', () {
    final e = entry(
      allDay: true,
      start: '2026-10-18T00:00:00Z',
      end: '2026-10-20T00:00:00Z',
    );
    expect(e.occursOn(DateTime(2026, 10, 18)), true);
    expect(e.occursOn(DateTime(2026, 10, 19)), true);
    expect(e.occursOn(DateTime(2026, 10, 20)), false);
  });
  test(
    'Flutter displays server-expanded instances without inventing dates',
    () {
      final birthday = entry(
        kind: 'birthday',
        allDay: true,
        yearly: true,
        start: '2028-02-29T00:00:00Z',
        end: '2028-03-01T00:00:00Z',
      );
      expect(birthday.occursOn(DateTime(2028, 2, 29)), true);
      expect(birthday.occursOn(DateTime(2032, 2, 29)), false);
    },
  );
  test(
    'Repeat builder produces RFC rules with interval, weekdays, and count',
    () {
      final draft = RepeatDraft.from(
        'FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH;COUNT=6;WKST=MO',
        DateTime(2026, 10, 20),
      );
      expect(
        draft.rule(DateTime(2026, 10, 20)),
        'FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH;WKST=MO;COUNT=6',
      );
      draft.preset = 'monthly';
      draft.interval = 3;
      draft.monthly = 'lastweekday';
      expect(
        draft.rule(DateTime(2026, 10, 20)),
        'FREQ=MONTHLY;INTERVAL=3;BYDAY=-1TU;COUNT=6',
      );
      draft.preset = 'weekdays';
      draft.interval = 1;
      draft.ending = 'never';
      expect(draft.align(DateTime(2026, 10, 18)), DateTime(2026, 10, 19));
      expect(
        draft.rule(DateTime(2026, 10, 19)),
        'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;WKST=MO',
      );
    },
  );
  test('Advanced imported rules survive the builder unchanged', () {
    const raw = 'FREQ=YEARLY;BYMONTH=11;BYDAY=TH;BYSETPOS=4;COUNT=10';
    final draft = RepeatDraft.from(raw, DateTime(2026, 11, 26));
    expect(draft.preset, 'custom');
    expect(draft.rule(DateTime(2026, 11, 26)), raw);
  });
  testWidgets('Login and registration are usable on a narrow phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(home: AuthPage(state: CalendarState(Api()))),
    );
    await tester.pumpAndSettle();
    expect(find.text('Sign in'), findsNWidgets(2));
    await tester.ensureVisible(find.text('New here? Create an account'));
    await tester.tap(find.text('New here? Create an account'));
    await tester.pumpAndSettle();
    expect(find.text('Create an account'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  for (final size in [
    const Size(1600, 1000),
    const Size(1024, 700),
    const Size(390, 844),
    const Size(320, 640),
  ]) {
    testWidgets('Calendar and navigation fit ${size.width} × ${size.height}', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(SpacetimeApp(state: sample()));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('month-calendar')), findsOneWidget);
      final grid = tester.getRect(find.byKey(const ValueKey('month-calendar')));
      final desktop = size.width >= 900;
      expect(grid.left, desktop ? 196 : 0);
      expect(
        find.byKey(const ValueKey('desktop-sidebar')),
        desktop ? findsOneWidget : findsNothing,
      );
      expect(
        find.byKey(const ValueKey('mobile-navigation')),
        desktop ? findsNothing : findsOneWidget,
      );
      expect(grid.right, size.width);
      expect(
        grid.bottom,
        desktop
            ? size.height
            : tester
                .getRect(find.byKey(const ValueKey('mobile-navigation')))
                .top,
      );
      expect(tester.takeException(), isNull);
      final add = tester.getRect(
        find.byKey(const ValueKey('header-add-event')),
      );
      final header = tester.getRect(find.byKey(const ValueKey('header-bar')));
      expect(add.right, lessThanOrEqualTo(size.width));
      expect(add.top, greaterThanOrEqualTo(header.top));
      expect(add.bottom, lessThanOrEqualTo(header.bottom));
      final narrow = header.width < 760;
      expect(
        find.byKey(const ValueKey('search-button')),
        narrow ? findsOneWidget : findsNothing,
      );
      expect(
        find.byKey(const ValueKey('search-input')),
        narrow ? findsNothing : findsOneWidget,
      );
      final search = tester.getRect(
        find.byKey(ValueKey(narrow ? 'search-button' : 'search-input')),
      );
      expect(add.left, greaterThan(search.right));
      for (final mode in ['Daily', 'Weekly', 'Yearly', 'Month']) {
        await chooseView(tester, mode);
        expect(
          find.byKey(
            ValueKey(
              {
                'Daily':
                    'daily-calendar-${day(DateTime.now()).toIso8601String()}',
                'Weekly': 'weekly-calendar',
                'Yearly': 'year-calendar',
                'Month': 'month-calendar',
              }[mode]!,
            ),
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      }
      final navigation = find.byKey(
        ValueKey(desktop ? 'desktop-sidebar' : 'mobile-navigation'),
      );
      Finder destination(String label) =>
          find.descendant(of: navigation, matching: find.text(label));
      await tester.tap(destination('Todos'));
      await tester.pumpAndSettle();
      expect(find.text('No todos'), findsOneWidget);
      await tester.tap(destination('Invites'));
      await tester.pumpAndSettle();
      expect(find.text('No invitations'), findsOneWidget);
      expect(
        find.descendant(of: navigation, matching: find.text('Add event')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('header-add-event')));
      await tester.pumpAndSettle();
      expect(find.byType(EntryEditor), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Event'), findsOneWidget);
      await tester.tap(find.byTooltip('Close editor'));
      await tester.pumpAndSettle();
      expect(find.text('No invitations'), findsOneWidget);
      await tester.tap(destination('Settings'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-screen')), findsOneWidget);
      expect(find.text('Calendar preferences'), findsOneWidget);
      await tester.ensureVisible(find.text('CalDAV'));
      expect(find.text('CalDAV'), findsOneWidget);
      expect(find.text('Copy calendar URL'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  for (final width in [390.0, 1200.0]) {
    testWidgets('Invites long press toggles calendar visibility at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = visibilitySample();
      final invite = Entry({
        ...state.entries.first.data,
        'id': 'invited',
        'owner': 'sam',
        'title': 'Invited appointment',
        '_account': 'alex',
      });
      state.invitations = [invite];
      await tester.pumpWidget(SpacetimeApp(state: state));
      await tester.pumpAndSettle();
      final nav = find.byKey(
        ValueKey(width >= 900 ? 'desktop-sidebar' : 'mobile-navigation'),
      );
      final invites = find.descendant(of: nav, matching: find.text('Invites'));
      expect(find.text('Invited appointment'), findsOneWidget);
      await tester.longPress(invites);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('month-calendar')), findsOneWidget);
      expect(
        tester
            .widget<CheckedPopupMenuItem<String>>(
              find.byKey(const ValueKey('visibility-invite')),
            )
            .checked,
        true,
      );
      await tester.tap(find.byKey(const ValueKey('visibility-invite')));
      await tester.pumpAndSettle();
      expect(find.text('Invited appointment'), findsNothing);
      expect(find.text('Work event'), findsOneWidget);
      expect(state.showInvites, false);
      final restored = sample()..loadPreferences();
      expect(restored.showInvites, false);
      await tester.tap(invites);
      await tester.pumpAndSettle();
      expect(find.text('Invited appointment'), findsOneWidget);
      await tester.longPress(invites);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('visibility-invite')));
      await tester.pumpAndSettle();
      expect(state.showInvites, true);
      expect(state.invitations.length, 1);
      expect(tester.takeException(), isNull);
    });
    testWidgets(
      'Navigation long press controls calendar visibility at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(SpacetimeApp(state: visibilitySample()));
        await tester.pumpAndSettle();
        final nav = find.byKey(
          ValueKey(width >= 900 ? 'desktop-sidebar' : 'mobile-navigation'),
        );
        Finder destination(String label) =>
            find.descendant(of: nav, matching: find.text(label));
        expect(find.text('Work event'), findsOneWidget);
        expect(find.text('An occasion'), findsOneWidget);
        expect(find.text('A task'), findsOneWidget);
        await tester.longPress(destination('Calendar'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<CheckedPopupMenuItem<String>>(
                find.byKey(const ValueKey('visibility-event')),
              )
              .checked,
          true,
        );
        await tester.tap(find.byKey(const ValueKey('visibility-event')));
        await tester.pumpAndSettle();
        expect(find.text('Work event'), findsNothing);
        expect(find.text('An occasion'), findsOneWidget);
        await tester.longPress(destination('Calendar'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('visibility-occasion')));
        await tester.pumpAndSettle();
        expect(find.text('An occasion'), findsNothing);
        expect(find.text('A task'), findsOneWidget);
        await tester.longPress(destination('Todos'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('month-calendar')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('visibility-todo')));
        await tester.pumpAndSettle();
        expect(find.text('A task'), findsNothing);
        await tester.tap(destination('Todos'));
        await tester.pumpAndSettle();
        expect(find.text('A task'), findsOneWidget);
        await tester.longPress(destination('Calendar'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<CheckedPopupMenuItem<String>>(
                find.byKey(const ValueKey('visibility-event')),
              )
              .checked,
          false,
        );
        await tester.tap(find.byKey(const ValueKey('visibility-event')));
        await tester.pumpAndSettle();
        expect(find.text('A task'), findsOneWidget);
        expect(find.byKey(const ValueKey('month-calendar')), findsNothing);
        await tester.tap(destination('Calendar'));
        await tester.pumpAndSettle();
        expect(find.text('Work event'), findsOneWidget);
        expect(find.text('A task'), findsNothing);
        await tester.longPress(destination('Todos'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('visibility-todo')));
        await tester.pumpAndSettle();
        expect(find.text('A task'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'Narrow search expands, filters, and clears without losing the query',
    (tester) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(SpacetimeApp(state: visibilitySample()));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('search-input')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('search-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('search-input')),
        'Work',
      );
      await tester.pumpAndSettle();
      expect(find.text('Work event'), findsOneWidget);
      expect(find.text('An occasion'), findsNothing);
      tester.view.viewInsets = const FakeViewPadding(bottom: 420);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('search-input')), findsNothing);
      expect(find.text('Work event'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('search-button')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('search-input')))
            .controller!
            .text,
        'Work',
      );
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      expect(find.text('An occasion'), findsOneWidget);
      expect(find.text('A task'), findsOneWidget);
      await tester.tap(find.byTooltip('Close search'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('view-selector')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Daily shows one day and Yearly shows twelve months without event titles',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final today = day(DateTime.now()),
          tomorrow = day(DateTime.now()).add(const Duration(days: 1));
      final fixtures = [
        for (final item in [(today, 'Today only'), (tomorrow, 'Tomorrow only')])
          {
            'id': item.$2,
            'owner': 'alex',
            'title': item.$2,
            'kind': 'event',
            'all_day': true,
            'start': item.$1.toIso8601String(),
            'end': item.$1.add(const Duration(days: 1)).toIso8601String(),
            'version': 1,
          },
      ];
      final state = CalendarState(
        Api(
          client: MockClient(
            (req) async => http.Response(
              jsonEncode(req.url.path == '/api/invitations' ? [] : fixtures),
              200,
            ),
          ),
        ),
      );
      state.user = {'username': 'alex', 'name': 'Alex'};
      state.entries = fixtures.map(Entry.new).toList();
      await tester.pumpWidget(SpacetimeApp(state: state));
      await tester.pumpAndSettle();
      await chooseView(tester, 'Daily');
      expect(find.text('Today only'), findsOneWidget);
      expect(find.text('Tomorrow only'), findsNothing);
      await tester.tap(find.byTooltip('Next'));
      await tester.pumpAndSettle();
      expect(find.text('Today only'), findsNothing);
      expect(find.text('Tomorrow only'), findsOneWidget);
      await chooseView(tester, 'Yearly');
      for (final name in [
        'January',
        'February',
        'March',
        'April',
        'May',
        'June',
        'July',
        'August',
        'September',
        'October',
        'November',
        'December',
      ]) {
        expect(find.widgetWithText(TextButton, name), findsOneWidget);
      }
      expect(find.text('Today only'), findsNothing);
      expect(find.text('Tomorrow only'), findsNothing);
      expect(day(state.rangeStart!), DateTime.utc(tomorrow.year));
      expect(day(state.rangeEnd!), DateTime.utc(tomorrow.year + 1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Todo editor switches fields and remains scrollable on a phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(),
        home: Scaffold(
          body: EntryEditor(
            state: sample(),
            date: DateTime(2026, 10, 18),
            initialKind: 'todo',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('DUE'), findsOneWidget);
    expect(find.text('START'), findsNothing);
    await tester.ensureVisible(find.text('Create entry'));
    expect(tester.takeException(), isNull);
  });
  for (final kind in ['occasion']) {
    testWidgets('$kind editor omits locations and invitees', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: Scaffold(
            body: EntryEditor(
              state: sample(),
              date: DateTime(2026, 10, 18),
              initialKind: kind,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(TextFormField, 'Location (optional)'),
        findsNothing,
      );
      expect(
        find.widgetWithText(TextFormField, 'Invite people (optional)'),
        findsNothing,
      );
      await tester.ensureVisible(find.text('Create entry'));
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('Monthly recurrence controls fit a narrow phone', (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final draft = RepeatDraft.from(
      'FREQ=MONTHLY;INTERVAL=3;COUNT=5',
      DateTime(2026, 10, 31),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: RepeatEditor(
                draft: draft,
                start: DateTime(2026, 10, 31),
                onChanged: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Months without this date are skipped.'), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    expect(find.text('Last day'), findsOneWidget);
    expect(find.text('Never'), findsOneWidget);
    expect(find.text('After count'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  for (final month in [3, 11]) {
    test(
      'Calendar cells keep every date exactly once across DST, month $month',
      () {
        final cells = monthCellDates(DateTime(2026, month));
        final days =
            cells.where((d) => d.month == month).map((d) => d.day).toList();
        expect(
          days,
          List.generate(DateTime(2026, month + 1, 0).day, (i) => i + 1),
        );
        expect(
          cells.map((d) => '${d.year}-${d.month}-${d.day}').toSet().length,
          cells.length,
        );
        expect(cells.every((d) => d.hour == 0 && d.minute == 0), true);
      },
    );
  }
  testWidgets('All-day editor keeps the inclusive last date over spring DST', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final event = entry(
      allDay: true,
      start: '2026-03-08T00:00:00Z',
      end: '2026-03-09T00:00:00Z',
    );
    event.data['start_local'] = '2026-03-08';
    event.data['end_local'] = '2026-03-09';
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(),
        home: Scaffold(
          body: EntryEditor(
            state: sample(),
            date: DateTime(2026, 3, 8),
            entry: event,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Mar 8, 2026'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
  test(
    'Calendar preferences belong to the device and survive disconnect',
    () async {
      final first =
          sample()..user = {'username': 'settings-owner', 'name': 'Owner'};
      await first.savePreferences(
        defaultView: 'Weekly',
        weekStartsOn: 1,
        use24Hour: false,
      );
      final restored =
          sample()..user = {'username': 'settings-owner', 'name': 'Owner'};
      restored.loadPreferences();
      expect(restored.defaultView, 'Weekly');
      expect(restored.weekStartsOn, 1);
      expect(restored.use24Hour, false);
      final other =
          sample()..user = {'username': 'another-account', 'name': 'Other'};
      other.loadPreferences();
      expect(other.defaultView, 'Weekly');
      expect(other.weekStartsOn, 1);
      expect(other.use24Hour, false);
      restored.rangeStart = DateTime.utc(2030);
      restored.rangeEnd = DateTime.utc(2031);
      await restored.signOut();
      expect(restored.rangeStart, DateTime.utc(2030));
      expect(restored.rangeEnd, DateTime.utc(2031));
    },
  );
  test('Legacy Agenda preference opens the new Daily view', () async {
    await writePreference(
      'spacetime.preferences.device',
      jsonEncode({'default_view': 'Agenda'}),
    );
    final state = sample()..loadPreferences();
    expect(state.defaultView, 'Daily');
    expect(state.showInvites, true);
  });
  testWidgets(
    'Widget navigation opens the requested date on launch and while running',
    (tester) async {
      receiveCalendarNavigation({'date': '2026-12-07', 'view': 'Daily'});
      await tester.pumpWidget(SpacetimeApp(state: sample()));
      await tester.pumpAndSettle();
      expect(
        find.byKey(
          ValueKey(
            'daily-calendar-${DateTime.utc(2026, 12, 7).toIso8601String()}',
          ),
        ),
        findsOneWidget,
      );
      receiveCalendarNavigation({'date': '2027-01-04', 'view': 'Weekly'});
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('weekly-calendar')), findsOneWidget);
      expect(find.text('Mon 4'), findsOneWidget);
      expect(calendarNavigation.value, isNull);
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'Invite projection expands recurrence, deduplicates saved invitations, and hides declined responses',
    () async {
      final state = sample();
      state.entries = [
        entry()
          ..data.addAll({
            'id': 'saved',
            '_remote_id': 'accepted',
            '_account': 'alex',
            '_editable': false,
            'owner': 'sam',
          }),
      ];
      state.invitations = [
        for (final id in ['accepted', 'pending', 'declined'])
          Entry({
            ...entry().data,
            'id': id,
            'owner': 'sam',
            '_account': 'alex',
            if (id == 'pending') 'rrule': 'FREQ=DAILY;COUNT=3',
            if (id == 'declined') '_response': 'declined',
          }),
      ];
      await state.setRange(DateTime(2026, 10, 1), DateTime(2026, 11, 1));
      expect(state.pendingCalendarInvites.map((e) => e.id), ['pending']);
      expect(state.calendarEntries.length, 4);
      await state.savePreferences(showInvites: false);
      expect(state.calendarEntries, isEmpty);
      expect(state.invitations.length, 3);
      await state.savePreferences(showInvites: true);
      expect(state.calendarEntries.length, 4);
    },
  );
  test('Monday-first calendar grids preserve civil dates across DST', () {
    for (final month in [3, 11]) {
      final cells = monthCellDates(DateTime.utc(2026, month), weekStartsOn: 1);
      expect(cells.first.weekday, DateTime.monday);
      expect(
        cells.where((d) => d.month == month).map((d) => d.day).toList(),
        List.generate(DateTime.utc(2026, month + 1, 0).day, (i) => i + 1),
      );
    }
  });
  testWidgets(
    'Saved preferences set the default view and calendar week layout',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = sample();
      state.defaultView = 'Weekly';
      state.weekStartsOn = 1;
      state.use24Hour = false;
      await tester.pumpWidget(SpacetimeApp(state: state));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('weekly-calendar')), findsOneWidget);
      final labels =
          tester
              .widgetList<Text>(
                find.descendant(
                  of: find.byKey(const ValueKey('weekly-calendar')),
                  matching: find.byType(Text),
                ),
              )
              .map((w) => w.data)
              .toList();
      expect(
        labels
            .whereType<String>()
            .where(
              (s) => RegExp(r'^(Mon|Tue|Wed|Thu|Fri|Sat|Sun) \d+$').hasMatch(s),
            )
            .first
            .split(' ')
            .first,
        'Mon',
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('Calendar event times honor the 12-hour preference', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final now = DateTime.now();
    final state = sample()..use24Hour = false;
    state.entries = [
      entry(
        start:
            DateTime(
              now.year,
              now.month,
              now.day,
              13,
            ).toUtc().toIso8601String(),
        end:
            DateTime(
              now.year,
              now.month,
              now.day,
              14,
            ).toUtc().toIso8601String(),
      ),
    ];
    await tester.pumpWidget(SpacetimeApp(state: state));
    await tester.pumpAndSettle();
    expect(find.textContaining('1:00 PM'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Settings controls update persisted preferences', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state =
        sample()..user = {'username': 'settings-ui', 'name': 'Settings test'};
    await tester.pumpWidget(SpacetimeApp(state: state));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('mobile-navigation')),
        matching: find.text('Settings'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('default-Daily')));
    await tester.tap(find.byKey(const ValueKey('week-start-monday')));
    await tester.tap(find.byKey(const ValueKey('settings-24-hour')));
    await tester.pumpAndSettle();
    expect(state.defaultView, 'Daily');
    expect(state.weekStartsOn, 1);
    expect(state.use24Hour, false);
    final restored = sample()..user = state.user;
    restored.loadPreferences();
    expect(restored.defaultView, 'Daily');
    expect(restored.weekStartsOn, 1);
    expect(restored.use24Hour, false);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('mobile-navigation')),
        matching: find.text('Calendar'),
      ),
    );
    await tester.pumpAndSettle();
    final labels =
        tester
            .widgetList<Text>(
              find.descendant(
                of: find.byKey(const ValueKey('month-calendar')),
                matching: find.byType(Text),
              ),
            )
            .map((w) => w.data)
            .toList();
    expect(labels.take(7), ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']);
    expect(tester.takeException(), isNull);
  });
  test('Daily query remains nonempty across a skipped civil date', () async {
    final state = sample();
    await state.setRange(
      DateTime.utc(2011, 12, 30),
      DateTime.utc(2011, 12, 31),
    );
    expect(state.rangeStart, DateTime.utc(2011, 12, 30));
    expect(state.rangeEnd, DateTime.utc(2011, 12, 31));
  });
  test('Date-only calendars retain Samoa’s historically skipped date', () {
    final cells = monthCellDates(DateTime.utc(2011, 12));
    expect(
      cells.where((d) => d.month == 12).map((d) => d.day).toList(),
      List.generate(31, (i) => i + 1),
    );
    final e = entry(
      allDay: true,
      start: '2011-12-30T00:00:00Z',
      end: '2011-12-31T00:00:00Z',
    );
    expect(e.when!.day, 30);
    expect(e.occursOn(DateTime.utc(2011, 12, 30)), true);
  });
}
