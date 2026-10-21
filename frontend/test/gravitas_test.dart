import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spacetime/browser_account.dart';
import 'package:spacetime/calendar_storage.dart';
import 'package:spacetime/main.dart';
import 'package:spacetime/models.dart';
import 'package:spacetime/native_platform.dart';
import 'package:spacetime/preference_storage.dart';

class FakeBrowser extends BrowserAccount {
  String? result;
  int silent = 0, interactive = 0, registrations = 0;
  FakeBrowser({this.result});
  @override
  bool get enabled => true;
  @override
  String? takeResult() {
    final value = result;
    result = null;
    return value;
  }

  @override
  void login({bool silent = false}) {
    if (silent) {
      this.silent++;
    } else {
      interactive++;
    }
  }

  @override
  void register() {
    registrations++;
  }
}

CalendarState accountState(
  FakeBrowser browser, {
  bool signedIn = false,
  bool offline = false,
  List<String>? paths,
}) => CalendarState(
  Api(
    client: MockClient((request) async {
      paths?.add(request.url.path);
      if (offline) throw StateError('offline');
      if (request.url.path == '/api/auth/config') {
        return http.Response('{"gravitas_enabled":true}', 200);
      }
      if (request.url.path == '/api/me' && signedIn) {
        return http.Response('{"username":"jeeth","name":"Jeeth"}', 200);
      }
      if (request.url.path == '/api/logout') return http.Response('', 204);
      return http.Response('{"error":"Please sign in"}', 401);
    }),
  ),
  browserAccount: browser,
  storage: MemoryCalendarStorage(),
);

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final loader = FontLoader('Spacetime');
    loader.addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'));
    await loader.load();
  });
  setUp(() async {
    nativePreferences.clear();
    await writePreference(
      'spacetime.server',
      'https://spacetime.gravitas.cool',
    );
  });
  test(
    'A valid browser session connects without syncing or redirecting',
    () async {
      final browser = FakeBrowser(result: 'connected');
      final paths = <String>[];
      final state = accountState(browser, signedIn: true, paths: paths);
      expect(await state.initializeGravitas(), false);
      expect(state.username, 'jeeth');
      expect(browser.silent, 0);
      expect(paths, ['/api/auth/config', '/api/me']);
      expect(
        jsonDecode(
          (state.storage as MemoryCalendarStorage).value!,
        )['user']['username'],
        'jeeth',
      );
    },
  );
  test(
    'A signed-out visit attempts passive login once and then offers the modal',
    () async {
      final browser = FakeBrowser();
      final state = accountState(browser);
      expect(await state.initializeGravitas(), false);
      expect(browser.silent, 1);
      browser.result = 'login_required';
      expect(await state.initializeGravitas(), true);
      expect(browser.silent, 1);
      await state.loginLater();
      browser.result = 'login_required';
      expect(await state.initializeGravitas(), false);
    },
  );
  test(
    'Offline startup preserves a cached account and never redirects',
    () async {
      final browser = FakeBrowser();
      final state = accountState(browser, offline: true);
      state.user = {'username': 'jeeth', 'name': 'Jeeth'};
      expect(await state.initializeGravitas(), false);
      expect(state.connected, true);
      expect(browser.silent, 0);
    },
  );
  test(
    'Explicit disconnect prevents automatic reconnection until login is requested',
    () async {
      final browser = FakeBrowser();
      final paths = <String>[];
      final state = accountState(browser, signedIn: true, paths: paths);
      await state.initializeGravitas();
      await state.disconnectGravitas();
      expect(state.connected, false);
      final before = paths.length;
      expect(await state.initializeGravitas(), false);
      expect(paths.length, before);
      await state.loginWithGravitas();
      expect(browser.interactive, 1);
      expect(readPreference('spacetime.gravitas.disconnected'), '0');
    },
  );
  for (final width in [320.0, 1280.0]) {
    testWidgets('First-open modal and settings actions fit at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final browser = FakeBrowser(result: 'login_required');
      final state = accountState(browser);
      await tester.pumpWidget(SpacetimeApp(state: state));
      await tester.pumpAndSettle();
      expect(find.text('Log in to Spacetime'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('gravitas-register')));
      expect(browser.registrations, 1);
      await tester.tap(find.byKey(const ValueKey('gravitas-login')));
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
