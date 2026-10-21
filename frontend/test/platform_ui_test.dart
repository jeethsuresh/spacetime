import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spacetime/calendar_storage.dart';
import 'package:spacetime/main.dart';
import 'package:spacetime/models.dart';

void main() {
  testWidgets('Only native login asks for a server address', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AuthPage(
          state: CalendarState(Api(), storage: MemoryCalendarStorage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('server-address')),
      kIsWeb ? findsNothing : findsOneWidget,
    );
  });

  testWidgets('Web settings hide addresses and retain sync and CalDAV controls', (
    tester,
  ) async {
    final state = CalendarState(Api(), storage: MemoryCalendarStorage())
      ..user = {'username': 'alex', 'name': 'Alex'};
    await tester.pumpWidget(MaterialApp(home: HomePage(state: state)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings').last);
    await tester.pumpAndSettle();
    final settings = find.byKey(const ValueKey('settings-screen'));
    // Build the bottom section too, so an off-screen address cannot evade this.
    await tester.drag(settings, const Offset(0, -900));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('account-server-address')),
      kIsWeb ? findsNothing : findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('caldav-address')),
      kIsWeb ? findsNothing : findsOneWidget,
    );
    expect(find.text('Copy calendar URL'), findsOneWidget);
    expect(find.byKey(const ValueKey('sync-now')), findsOneWidget);
    expect(find.textContaining('sync runs every hour'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
