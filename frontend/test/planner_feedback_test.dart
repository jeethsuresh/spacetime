import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spacetime/calendar_storage.dart';
import 'package:spacetime/models.dart';
import 'package:spacetime/planner_feedback.dart';
import 'package:spacetime/interaction_juice.dart';
import 'package:spacetime/main.dart';
import 'offline_test.dart' show event;

class DelayedStorage extends MemoryCalendarStorage {
  final barrier = Completer<void>();
  bool fail = false;
  @override
  Future<void> write(String value) async {
    await barrier.future;
    if (fail) throw StateError('disk unavailable');
    await super.write(value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'save feedback receives the exact entry only after persistence succeeds',
    () async {
      final storage = DelayedStorage();
      final state = CalendarState(Api(), storage: storage);
      addTearDown(state.dispose);
      var completed = false;
      final operation = state.saveEntry(event()).then((entry) {
        completed = true;
        return entry;
      });
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      storage.barrier.complete();
      final saved = await operation;
      expect(saved.id, state.entries.single.id);
      expect(saved.title, 'Offline');
      expect(storage.value, contains(saved.id));
      expect(state.pendingChanges, 1);
    },
  );

  test(
    'failed persistence cannot return a successful feedback identity',
    () async {
      final storage = DelayedStorage()..fail = true;
      final state = CalendarState(Api(), storage: storage);
      addTearDown(state.dispose);
      final operation = state.saveEntry(event());
      storage.barrier.complete();
      await expectLater(operation, throwsStateError);
      expect(state.entries, isEmpty);
      expect(state.pendingChanges, 0);
      storage.fail = false;
      expect((await state.saveEntry(event())).id, state.entries.single.id);
    },
  );

  testWidgets('changing reduced motion during entry feedback settles safely', (
    tester,
  ) async {
    Widget scene(bool reduced) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: const PlannerEntryFeedback(
          signal: 1,
          color: Colors.green,
          child: Text('Saved on this device'),
        ),
      ),
    );
    await tester.pumpWidget(scene(false));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.pumpWidget(scene(true));
    await tester.pumpAndSettle();
    expect(find.text('Saved on this device'), findsOneWidget);
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('completing and reversing a task preserves its row position', (
    tester,
  ) async {
    final state = CalendarState(Api(), storage: MemoryCalendarStorage());
    addTearDown(state.dispose);
    final first = await state.saveEntry({
      ...event(kind: 'todo'),
      'title': 'First task',
    });
    await state.saveEntry({
      ...event(kind: 'todo', start: '2026-01-02T09:00:00'),
      'title': 'Second task',
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(),
        home: ListenableBuilder(
          listenable: state,
          builder: (context, _) => HomePage(state: state),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Todos'));
    await tester.pumpAndSettle();
    final before = tester.getTopLeft(find.text('First task'));
    final control = find.descendant(
      of: find.byKey(ValueKey('todo-${first.id}:')),
      matching: find.byType(Checkbox),
    );
    await tester.tap(control);
    await tester.pumpAndSettle();
    expect(state.entries.firstWhere((e) => e.id == first.id).completed, isTrue);
    expect(find.text('1 of 2 tasks complete'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('First task')).dy,
      closeTo(before.dy, .1),
    );
    await tester.tap(control);
    await tester.pumpAndSettle();
    expect(
      state.entries.firstWhere((e) => e.id == first.id).completed,
      isFalse,
    );
    expect(
      tester.getTopLeft(find.text('First task')).dy,
      closeTo(before.dy, .1),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'confirmed completion pulse continues from saving into the saved checkbox',
    (tester) async {
      Widget scene(bool busy, int signal) => MaterialApp(
        home: Scaffold(
          body: PlannerTaskControl(
            value: !busy,
            busy: busy,
            signal: signal,
            onChanged: (_) {},
          ),
        ),
      );
      await tester.pumpWidget(scene(true, 0));
      expect(find.byType(Checkbox), findsNothing);
      await tester.pumpWidget(scene(true, 1));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pumpWidget(scene(false, 1));
      expect(find.byType(Checkbox), findsOneWidget);
      final art =
          find
              .descendant(
                of: find.byType(ElasticPulse),
                matching: find.byType(Transform),
              )
              .first;
      expect(tester.widget<Transform>(art).transform.isIdentity(), isFalse);
      await tester.pumpAndSettle();
      expect(tester.widget<Transform>(art).transform.isIdentity(), isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
