import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spacetime/main.dart';
import 'package:spacetime/preference_storage.dart';

import 'support/gravitas_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    await writePreference('spacetime.gravitas.disconnected', '0');
    await writePreference('spacetime.gravitas.prompt_dismissed', '0');
    await writePreference(
      'spacetime.server',
      'https://spacetime.gravitas.cool',
    );
  });
  for (final native in [false, true]) {
    testWidgets(
      'Onboarding connection form on ${native ? "native" : "web"}',
      (tester) async {
        final browser = FakeBrowser(result: 'consent_required', native: native);
        final state = accountState(browser);
        expect(await state.initializeGravitas(), true);
        await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: GravitasLogin(state: state))),
        );
        expect(find.byType(TextField), findsNothing);
        expect(browser.interactive + browser.browserOpens, 0);
        await tester.tap(
          find.text(native ? 'Continue with Gravitas' : 'Grant access'),
        );
        await tester.pumpAndSettle();
        expect(browser.interactive, native ? 0 : 1);
        expect(browser.browserOpens, native ? 1 : 0);
        expect(browser.username, isNull);
        await tester.tap(find.text('Use another account'));
        await tester.pumpAndSettle();
        expect(find.widgetWithText(TextField, 'Username'), findsOneWidget);
      },
      skip: native && kIsWeb,
    );
  }
}
