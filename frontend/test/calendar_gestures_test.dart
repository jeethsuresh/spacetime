import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spacetime/calendar_storage.dart';
import 'package:spacetime/main.dart';
import 'package:spacetime/models.dart';
import 'package:spacetime/month_pager.dart';
import 'package:spacetime/native_platform.dart';
import 'package:spacetime/preference_storage.dart';

void main() {
  Future<void> setAppLifecycleState(AppLifecycleState lifecycle) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          SystemChannels.lifecycle.name,
          SystemChannels.lifecycle.codec.encodeMessage(lifecycle.toString()),
          (_) {},
        );
  }

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final loader = FontLoader('Spacetime');
    loader.addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'));
    await loader.load();
  });
  setUp(() async {
    await setAppLifecycleState(AppLifecycleState.resumed);
    nativePreferences.clear();
    await writePreference('spacetime.server', 'https://calendar.example');
  });

  Future<CalendarState> openCalendar(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = CalendarState(Api(), storage: MemoryCalendarStorage());
    calendarNavigation.value = {'date': '2026-12-15', 'view': 'Month'};
    await state.setRange(DateTime.utc(2026, 12), DateTime.utc(2027, 1));
    await tester.pumpWidget(SpacetimeApp(state: state));
    await tester.pumpAndSettle();
    return state;
  }

  String visibleMonth(WidgetTester tester) {
    final pager = tester.widget<MonthPager>(find.byType(MonthPager));
    return '${pager.month.year}-${pager.month.month}';
  }

  testWidgets('Month swipes snap, cross years, and stay aligned with arrows', (
    tester,
  ) async {
    final state = await openCalendar(tester, const Size(390, 844));
    await state.save({
      'title': 'Monthly plan',
      'kind': 'event',
      'all_day': true,
      'start_local': '2026-12-15',
      'end_local': '2026-12-16',
      'rrule': 'FREQ=MONTHLY',
    });
    await tester.pumpAndSettle();
    final pager = find.byKey(const ValueKey('month-pager'));
    final start = tester.getCenter(pager);
    // A slow drag under half a page returns to the current month.
    final drag = await tester.startGesture(start);
    await drag.moveBy(const Offset(-90, 0));
    await tester.pump(const Duration(milliseconds: 600));
    await drag.up();
    await tester.pumpAndSettle();
    expect(visibleMonth(tester), '2026-12');
    final scrollable =
        find.descendant(of: pager, matching: find.byType(Scrollable)).first;
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.pixels % position.viewportDimension, closeTo(0, 0.01));

    await tester.drag(pager, const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(visibleMonth(tester), '2027-1');
    expect(state.rangeStart, DateTime.utc(2026, 12, 27));
    expect(state.rangeEnd, DateTime.utc(2027, 2, 7));
    expect(state.occurrences.single.when, DateTime.utc(2027, 1, 15));
    expect(find.text('Monthly plan'), findsOneWidget);
    expect(position.pixels % position.viewportDimension, closeTo(0, 0.01));

    await tester.tap(find.byTooltip('Next'));
    await tester.pumpAndSettle();
    expect(visibleMonth(tester), '2027-2');
    await tester.drag(pager, const Offset(300, 0));
    await tester.pumpAndSettle();
    expect(visibleMonth(tester), '2027-1');
    await tester.drag(pager, const Offset(300, 0));
    await tester.pumpAndSettle();
    expect(visibleMonth(tester), '2026-12');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Horizontal wheel bursts snap once and vertical scroll stays put',
    (tester) async {
      await openCalendar(tester, const Size(1200, 900));
      final pager = find.byKey(const ValueKey('month-pager'));
      final pointer = tester.getCenter(pager);
      Future<void> scroll(Offset delta) async {
        await tester.sendEventToBinding(
          PointerScrollEvent(position: pointer, scrollDelta: delta),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }

      await scroll(const Offset(0, 120));
      await tester.pumpAndSettle();
      expect(visibleMonth(tester), '2026-12');
      for (var i = 0; i < 8; i++) {
        await scroll(const Offset(20, 0));
      }
      await tester.pumpAndSettle();
      expect(visibleMonth(tester), '2027-1');
      final scrollable =
          find.descendant(of: pager, matching: find.byType(Scrollable)).first;
      final position = tester.state<ScrollableState>(scrollable).position;
      expect(position.pixels % position.viewportDimension, closeTo(0, 0.01));
      await tester.pump(const Duration(milliseconds: 200));
      await scroll(const Offset(-120, 0));
      await tester.pumpAndSettle();
      expect(visibleMonth(tester), '2026-12');
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [const Size(320, 640), const Size(1200, 900)]) {
    testWidgets(
      'Bottom drawer replaces sidebar and filters shared lists at $size',
      (tester) async {
        final state = await openCalendar(tester, size);
        state.calendars.add(
          CalendarCollection({
            'id': 'shared',
            'name': 'Household',
            'kind': 'shared',
            'color': '#9163B3',
          }),
        );
        await state.selectCalendar('shared');
        await state.save({
          'title': 'Shared event',
          'kind': 'event',
          'all_day': true,
          'start_local': '2026-12-10',
          'end_local': '2026-12-11',
        });
        await state.save({
          'title': 'Shared task',
          'kind': 'todo',
          'all_day': true,
          'due_local': '2026-12-11',
        });
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('desktop-sidebar')), findsNothing);
        expect(find.byType(Drawer), findsNothing);
        expect(find.text('Shared event'), findsOneWidget);
        expect(find.text('Shared task'), findsOneWidget);
        final nav = find.byKey(const ValueKey('mobile-navigation'));
        await tester.drag(nav, const Offset(0, -180));
        await tester.pumpAndSettle();
        final drawer = find.byKey(const ValueKey('calendar-drawer'));
        expect(drawer, findsOneWidget);
        expect(tester.getRect(drawer).bottom, lessThanOrEqualTo(size.height));
        await tester.tap(find.byKey(const ValueKey('calendar-visible-shared')));
        await tester.pumpAndSettle();
        expect(state.hiddenCalendars, contains('shared'));
        expect(state.hiddenTodoCalendars, isEmpty);
        await tester.tap(find.byTooltip('Close calendars'));
        await tester.pumpAndSettle();
        expect(find.text('Shared event'), findsNothing);
        expect(find.text('Shared task'), findsOneWidget);

        // The handle can also open the drawer without a drag.
        await tester.tap(find.byKey(const ValueKey('calendar-drawer-handle')));
        await tester.pumpAndSettle();
        final todoToggle = find.byKey(const ValueKey('todos-visible-shared'));
        await tester.ensureVisible(todoToggle);
        await tester.tap(todoToggle);
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Close calendars'));
        await tester.pumpAndSettle();
        expect(find.text('Shared task'), findsNothing);
        final restored = CalendarState(Api(), storage: state.storage);
        await restored.restore();
        expect(restored.hiddenCalendars, contains('shared'));
        expect(restored.hiddenTodoCalendars, contains('shared'));
        expect(find.byKey(const ValueKey('month-calendar')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('Long drawer lists expand, scroll, and dismiss downward', (
    tester,
  ) async {
    final state = await openCalendar(tester, const Size(320, 640));
    for (var i = 0; i < 16; i++) {
      await state.createCalendar('Calendar $i', '#426EB4');
    }
    await tester.tap(find.byKey(const ValueKey('calendar-drawer-handle')));
    await tester.pumpAndSettle();
    final drawer = find.byKey(const ValueKey('calendar-drawer'));
    final top = tester.getTopLeft(drawer).dy;
    await tester.drag(drawer, const Offset(0, -220));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(drawer).dy, lessThan(top));
    final lastTodo = find.byKey(
      ValueKey('todos-visible-${state.calendars.last.id}'),
    );
    await tester.scrollUntilVisible(
      lastTodo,
      200,
      scrollable: find.descendant(
        of: drawer,
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    expect(lastTodo.hitTestable(), findsOneWidget);
    // The modal handle remains available even when the lists have scrolled.
    await tester.dragFrom(
      tester.getTopLeft(drawer) + const Offset(160, -24),
      const Offset(0, 600),
    );
    await tester.pumpAndSettle();
    expect(drawer, findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final lifecycle in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.detached,
  ]) {
    testWidgets('Calendar drawer dismisses on $lifecycle and can reopen', (
      tester,
    ) async {
      await openCalendar(tester, const Size(390, 844));
      final handle = find.byKey(const ValueKey('calendar-drawer-handle'));
      final drawer = find.byKey(const ValueKey('calendar-drawer'));
      await tester.tap(handle);
      await tester.pumpAndSettle();
      expect(drawer, findsOneWidget);

      final route = ModalRoute.of(tester.element(drawer))!;
      await setAppLifecycleState(lifecycle);
      expect(route.isActive, isFalse);
      await setAppLifecycleState(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(drawer, findsNothing);
      expect(visibleMonth(tester), '2026-12');

      await tester.tap(handle);
      await tester.pumpAndSettle();
      expect(drawer, findsOneWidget);
      await tester.tap(find.byTooltip('Close calendars'));
      await tester.pumpAndSettle();
      expect(drawer, findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Home screen round trip closes a drawer before its first frame', (
    tester,
  ) async {
    await openCalendar(tester, const Size(390, 844));
    await tester.tap(find.byKey(const ValueKey('calendar-drawer-handle')));
    for (final lifecycle in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      await setAppLifecycleState(lifecycle);
    }
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('calendar-drawer')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('calendar-drawer-handle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('calendar-drawer')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Losing foreground preserves a calendar dialog above the drawer',
    (tester) async {
      await openCalendar(tester, const Size(390, 844));
      await tester.tap(find.byKey(const ValueKey('calendar-drawer-handle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add-calendar')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);

      await setAppLifecycleState(AppLifecycleState.inactive);
      await setAppLifecycleState(AppLifecycleState.paused);
      await setAppLifecycleState(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('calendar-drawer')), findsNothing);
      expect(find.byKey(const ValueKey('month-calendar')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('A late drawer gesture is ignored while the app is inactive', (
    tester,
  ) async {
    await openCalendar(tester, const Size(390, 844));
    await setAppLifecycleState(AppLifecycleState.inactive);
    await tester.tap(find.byKey(const ValueKey('calendar-drawer-handle')));
    await setAppLifecycleState(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('calendar-drawer')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
