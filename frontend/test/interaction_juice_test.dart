import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spacetime/interaction_juice.dart';

void main() {
  testWidgets(
    'windup preserves target and volume; activation is immediate and single',
    (tester) async {
      var actions = 0;
      final focus = FocusNode();
      addTearDown(focus.dispose);
      Widget scene({bool reduced = false, bool enabled = true}) => MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: Scaffold(
            body: Center(
              child: ElasticInteraction(
                enabled: enabled,
                builder:
                    (context, pose) => IconButton(
                      key: const ValueKey('target'),
                      focusNode: focus,
                      onPressed: enabled ? () => actions++ : null,
                      icon: pose.deform(
                        const Icon(Icons.check),
                        key: const ValueKey('art'),
                      ),
                    ),
              ),
            ),
          ),
        ),
      );
      double scaleY() => tester
          .widget<Transform>(find.byKey(const ValueKey('art')))
          .transform
          .entry(1, 1);
      final target = find.byKey(const ValueKey('target'));
      await tester.pumpWidget(scene());
      final bounds = tester.getRect(target);
      final gesture = await tester.startGesture(bounds.center);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(scaleY(), lessThan(1));
      final matrix =
          tester.widget<Transform>(find.byKey(const ValueKey('art'))).transform;
      expect(
        matrix.entry(0, 0) * matrix.entry(1, 1) -
            matrix.entry(0, 1) * matrix.entry(1, 0),
        closeTo(1, .00001),
      );
      expect(tester.getRect(target), bounds);
      expect(actions, 0);
      await gesture.up();
      await tester.pump();
      expect(actions, 1);
      await tester.pump(const Duration(milliseconds: 110));
      expect(scaleY(), greaterThan(1));
      // Repeated input retargets the current pose; it never queues activations.
      await tester.tap(target);
      await tester.tap(target);
      expect(actions, 3);
      await tester.pumpAndSettle();
      expect(scaleY(), 1);
      focus.requestFocus();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(scaleY(), lessThan(1));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(actions, 4);
      final held = await tester.startGesture(bounds.center);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      await tester.pumpWidget(scene(reduced: true));
      expect(scaleY(), 1);
      await held.up();
      await tester.pumpAndSettle();
      expect(actions, 5);
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'scroll, cancellation and disabled changes do not activate or rebound',
    (tester) async {
      var actions = 0;
      Widget scene(bool enabled) => MaterialApp(
        home: Scaffold(
          body: ElasticInteraction(
            enabled: enabled,
            builder:
                (context, pose) => TextButton(
                  onPressed: enabled ? () => actions++ : null,
                  child: pose.deform(
                    const Icon(Icons.check),
                    key: const ValueKey('art'),
                  ),
                ),
          ),
        ),
      );
      await tester.pumpWidget(scene(true));
      final target = find.byType(TextButton);
      var held = await tester.startGesture(tester.getCenter(target));
      await tester.pump(const Duration(milliseconds: 90));
      await held.moveBy(const Offset(100, 100));
      await held.up();
      await tester.pumpAndSettle();
      expect(actions, 0);
      held = await tester.startGesture(tester.getCenter(target));
      await tester.pump(const Duration(milliseconds: 90));
      await held.cancel();
      await tester.pumpAndSettle();
      expect(actions, 0);
      held = await tester.startGesture(tester.getCenter(target));
      await tester.pump(const Duration(milliseconds: 90));
      await tester.pumpWidget(scene(false));
      await held.up();
      await tester.pumpAndSettle();
      expect(actions, 0);
      expect(
        tester
            .widget<Transform>(find.byKey(const ValueKey('art')))
            .transform
            .isIdentity(),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'secondary pointers preserve the held pose; lost focus cannot replay activation',
    (tester) async {
      var actions = 0;
      final first = FocusNode(), second = FocusNode();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                ElasticInteraction(
                  builder:
                      (context, pose) => IconButton(
                        focusNode: first,
                        onPressed: () => actions++,
                        icon: pose.deform(
                          const Icon(Icons.check),
                          key: const ValueKey('art'),
                        ),
                      ),
                ),
                IconButton(
                  focusNode: second,
                  onPressed: () {},
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
        ),
      );
      final target = find.widgetWithIcon(IconButton, Icons.check);
      final held = await tester.startGesture(
        tester.getCenter(target),
        pointer: 51,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));
      final other = await tester.startGesture(
        tester.getCenter(target),
        pointer: 52,
      );
      await other.cancel();
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        tester
            .widget<Transform>(find.byKey(const ValueKey('art')))
            .transform
            .entry(1, 1),
        lessThan(1),
      );
      await held.cancel();
      await tester.pumpAndSettle();
      expect(actions, 0);
      first.requestFocus();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));
      // Material activates Space on key-down. Losing focus must not replay it.
      expect(actions, 1);
      second.requestFocus();
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(actions, 1);
      expect(
        tester
            .widget<Transform>(find.byKey(const ValueKey('art')))
            .transform
            .isIdentity(),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}
