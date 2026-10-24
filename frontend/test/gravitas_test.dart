import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spacetime/main.dart';
import 'package:spacetime/native_platform.dart';
import 'package:spacetime/preference_storage.dart';

import 'support/gravitas_fakes.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final loader = FontLoader('Spacetime');
    loader.addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'));
    await loader.load();
  });
  setUp(() async {
    nativePreferences.clear();
    for (final key in [
      'disconnected',
      'prompt_dismissed',
      'passive_attempt_at',
    ]) {
      await writePreference('spacetime.gravitas.$key', '0');
    }
    await writePreference(
      'spacetime.server',
      'https://spacetime.gravitas.cool',
    );
  });
  for (final width in [320.0, 1280.0]) {
    testWidgets('First-open modal and settings actions fit at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final browser = FakeBrowser(result: 'login_required');
      final state = accountState(browser, defaultDomain: 'accounts.example');
      await tester.pumpWidget(SpacetimeApp(state: state));
      await tester.pumpAndSettle();
      expect(find.text('Log in to Spacetime'), findsOneWidget);
      expect(find.text('Register at accounts.example'), findsOneWidget);
      expect(
        find.text('Without a domain, sign in at accounts.example.'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('gravitas-register')));
      expect(browser.registrations, 1);
      await tester.enterText(
        find.widgetWithText(TextField, 'Username'),
        'alice@other.example',
      );
      await tester.tap(find.byKey(const ValueKey('gravitas-login')));
      await tester.pumpAndSettle();
      expect(browser.username, 'alice@other.example');
      expect(browser.interactive, 1);
      await tester.tap(find.byKey(const ValueKey('gravitas-login-later')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byKey(const ValueKey('month-calendar')), findsOneWidget);
      await tester.tap(find.text('Settings').last);
      await tester.pumpAndSettle();
      final registration = find.byKey(
        const ValueKey('settings-gravitas-register'),
      );
      await tester.ensureVisible(registration);
      await tester.pumpAndSettle();
      await tester.tap(registration);
      expect(browser.registrations, 2);
      expect(tester.takeException(), isNull);
    });
  }
}
