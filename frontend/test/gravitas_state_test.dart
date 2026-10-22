import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spacetime/calendar_storage.dart';
import 'package:spacetime/models.dart';
import 'package:spacetime/native_platform.dart';
import 'package:spacetime/preference_storage.dart';
import 'support/gravitas_fakes.dart';

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
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
  test(
    'An existing base session continues directly to first-connection consent',
    () async {
      final browser = FakeBrowser(result: 'consent_required');
      final state = accountState(browser);
      expect(await state.initializeGravitas(), false);
      expect(browser.interactive, 1);
      await state.loginLater();
      browser.result = 'consent_required';
      expect(await state.initializeGravitas(), false);
      expect(browser.interactive, 1);
    },
  );

  test(
    'Passive recovery needs a confirmed 401, a marker hint and foreground',
    () async {
      final browser = FakeBrowser();
      final paths = <String>[];
      final state = accountState(browser, signedInHint: true, paths: paths)
        ..user = {'username': 'jeeth'};
      await state.recoverGravitasSession(isForeground: () => false);
      expect(paths, isEmpty);
      await writePreference('spacetime.gravitas.prompt_dismissed', '1');
      await state.recoverGravitasSession(isForeground: () => true);
      expect(paths, ['/api/auth/config', '/api/me']);
      expect(browser.silent, 1);
      expect(browser.interactive, 0);
      expect(state.connected, false);
      // The redirect timestamp persists across a fresh app instance or reload.
      final reloaded = accountState(browser, signedInHint: true);
      await reloaded.recoverGravitasSession(isForeground: () => true);
      expect(browser.silent, 1);
      expect(await reloaded.initializeGravitas(), false);
      expect(browser.silent, 1);
    },
  );
  test(
    'Valid sessions and marker-free expired sessions never redirect',
    () async {
      final browser = FakeBrowser();
      final state = accountState(browser, signedIn: true, signedInHint: true);
      await state.recoverGravitasSession(isForeground: () => true);
      expect(state.username, 'jeeth');
      expect(browser.silent, 0);
      final expired = accountState(browser)..user = {'username': 'jeeth'};
      await expired.recoverGravitasSession(isForeground: () => true);
      expect(expired.connected, false);
      expect(browser.silent, 0);
    },
  );
  test(
    'Disconnected and offline accounts keep their saved choices and calendar',
    () async {
      final browser = FakeBrowser();
      final paths = <String>[];
      final state = accountState(browser, signedInHint: true, paths: paths)
        ..user = {'username': 'jeeth'};
      await writePreference('spacetime.gravitas.disconnected', '1');
      await state.recoverGravitasSession(isForeground: () => true);
      expect(paths, isEmpty);
      await writePreference('spacetime.gravitas.disconnected', '0');
      final offline = accountState(browser, offline: true)
        ..user = {'username': 'jeeth'};
      await offline.recoverGravitasSession(isForeground: () => true);
      expect(offline.connected, true);
      expect(browser.silent, 0);
    },
  );
  test(
    'Expiry preserves unsent invite responses across disconnect and other accounts',
    () async {
      final browser = FakeBrowser(result: 'login_required');
      final state = accountState(browser)..user = {'username': 'jeeth'};
      state.invitations = [
        Entry({
          'id': 'invite',
          'title': 'Pending response',
          'owner': 'sam',
          '_account': state.account,
          '_response': 'accepted',
        }),
      ];
      final binding = state.account;
      await writePreference('spacetime.gravitas.prompt_dismissed', '1');
      expect(await state.initializeGravitas(), false);
      expect(state.invitations.single.data['_response'], 'accepted');
      expect(state.currentInvitations, isEmpty);
      state.user = {'username': 'other'};
      expect(state.currentInvitations, isEmpty);
      await state.signOut();
      expect(state.invitations.single.data['_account'], binding);
      state.user = {'username': 'jeeth'};
      expect(state.currentInvitations.single.title, 'Pending response');
    },
  );

  test(
    'Recovery stops if the app becomes hidden while checking the marker',
    () async {
      final browser = FakeBrowser();
      final gate = Completer<void>();
      var foreground = true;
      final state = CalendarState(
        Api(
          client: MockClient((request) async {
            await gate.future;
            return http.Response(
              '{"gravitas_enabled":true,"gravitas_signed_in":true}',
              200,
            );
          }),
        ),
        browserAccount: browser,
        storage: MemoryCalendarStorage(),
      )..user = {'username': 'jeeth'};
      final pending = state.recoverGravitasSession(
        isForeground: () => foreground,
      );
      foreground = false;
      gate.complete();
      await pending;
      expect(browser.silent, 0);
      expect(state.connected, true);
    },
  );
  test(
    'Same-event responses stay isolated across accounts and remote downloads',
    () async {
      final statuses = <String>[];
      final state = CalendarState(
        Api(
          client: MockClient((request) async {
            if (request.url.path == '/api/me') {
              return http.Response('{"username":"other"}', 200);
            }
            if (request.method == 'POST') {
              statuses.add(jsonDecode(request.body)['status'] as String);
              return http.Response('', 204);
            }
            return http.Response('[]', 200);
          }),
        ),
        storage: MemoryCalendarStorage(),
      )..user = {'username': 'other'};
      state.invitations = [
        Entry({
          'id': 'same',
          'title': 'First account',
          '_account': '${state.api.base}#jeeth',
          '_response': 'accepted',
        }),
        Entry({
          'id': 'same',
          'title': 'Other account',
          '_account': state.account,
        }),
      ];
      await state.respond(state.invitations.last, 'declined');
      expect(state.invitations.first.data['_response'], 'accepted');
      await state.sync();
      expect(statuses, ['declined']);
      expect(state.invitations.single.title, 'First account');
      expect(state.currentInvitations, isEmpty);
    },
  );
}
