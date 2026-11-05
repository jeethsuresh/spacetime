import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spacetime/gravitas_navigation.dart';

class NavigationFixture extends StatefulWidget {
  const NavigationFixture({super.key});
  @override
  State<NavigationFixture> createState() => NavigationFixtureState();
}

class NavigationFixtureState extends State<NavigationFixture> {
  final history = GravitasNavigationObserver();
  final navigator = GlobalKey<NavigatorState>();
  int destination = 0;
  void visit(int value) => setState(() => destination = value);
  void page(String title) => navigator.currentState!.push<void>(
    HistoryPageRoute(builder: (_) => Scaffold(body: Text(title))),
  );
  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: navigator,
    navigatorObservers: [history],
    builder: (_, child) => GravitasNavigation(observer: history, child: child!),
    home: HistoryBoundary(
      value: destination,
      restore: (value) => setState(() => destination = value),
      child: Scaffold(body: Text('Destination $destination')),
    ),
  );
}

Future<void> forward(WidgetTester tester) async {
  tester.binding.channelBuffers.push(
    'cool.gravitas/navigation',
    const StandardMethodCodec().encodeMethodCall(const MethodCall('forward')),
    (_) {},
  );
  await tester.pumpAndSettle();
}

Future<void> back(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'native Forward restores a route and preserves a nested forward chain',
    (tester) async {
      final key = GlobalKey<NavigationFixtureState>();
      await tester.pumpWidget(NavigationFixture(key: key));
      key.currentState!.page('First');
      await tester.pumpAndSettle();
      key.currentState!.page('Second');
      await tester.pumpAndSettle();
      await back(tester);
      await back(tester);
      await forward(tester);
      expect(find.text('First'), findsOneWidget);
      await forward(tester);
      expect(find.text('Second'), findsOneWidget);
    },
  );
  testWidgets('root and route history have one chronological forward order', (
    tester,
  ) async {
    final key = GlobalKey<NavigationFixtureState>();
    await tester.pumpWidget(NavigationFixture(key: key));
    key.currentState!.visit(1);
    await tester.pumpAndSettle();
    key.currentState!.page('Details');
    await tester.pumpAndSettle();
    await back(tester);
    await back(tester);
    expect(find.text('Destination 0'), findsOneWidget);
    await forward(tester);
    expect(find.text('Destination 1'), findsOneWidget);
    await forward(tester);
    expect(find.text('Details'), findsOneWidget);
  });
  testWidgets(
    'new destination drops future visits and empty Forward does nothing',
    (tester) async {
      final key = GlobalKey<NavigationFixtureState>();
      await tester.pumpWidget(NavigationFixture(key: key));
      await forward(tester);
      expect(find.text('Destination 0'), findsOneWidget);
      key.currentState!.page('Old');
      await tester.pumpAndSettle();
      await back(tester);
      key.currentState!.visit(2);
      await tester.pumpAndSettle();
      await forward(tester);
      expect(find.text('Destination 2'), findsOneWidget);
      expect(find.text('Old'), findsNothing);
    },
  );
  testWidgets('dialogs block Forward and are never reopened as history', (
    tester,
  ) async {
    final key = GlobalKey<NavigationFixtureState>();
    await tester.pumpWidget(NavigationFixture(key: key));
    key.currentState!.page('Details');
    await tester.pumpAndSettle();
    await back(tester);
    showDialog<void>(
      context: key.currentState!.navigator.currentContext!,
      builder: (_) => const AlertDialog(content: Text('Confirm action')),
    );
    await tester.pumpAndSettle();
    await forward(tester);
    expect(find.text('Confirm action'), findsOneWidget);
    await back(tester);
    await forward(tester);
    expect(find.text('Details'), findsOneWidget);
  });
  testWidgets('account history clear prevents replaying prior destinations', (
    tester,
  ) async {
    final key = GlobalKey<NavigationFixtureState>();
    await tester.pumpWidget(NavigationFixture(key: key));
    key.currentState!.page('Private');
    await tester.pumpAndSettle();
    await back(tester);
    key.currentState!.history.clear();
    await forward(tester);
    expect(find.text('Private'), findsNothing);
  });
}
