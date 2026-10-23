import 'dart:convert';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spacetime/calendar_storage.dart';
import 'package:spacetime/models.dart';
import 'package:spacetime/native_platform.dart';
import 'package:spacetime/preference_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secrets = <String, String>{};
  var requests = 0;
  var recoveries = 0, browserStarts = 0;
  CalendarState state() => CalendarState(
    Api(
      client: MockClient((_) async {
        requests++;
        throw StateError('offline');
      }),
    ),
    storage: MemoryCalendarStorage(),
  );
  CalendarState expired(String reason) {
    final app = CalendarState(
      Api(
        client: MockClient((request) async {
          requests++;
          if (request.url.path == '/api/auth/config') {
            return http.Response('{"gravitas_enabled":true}', 200);
          }
          return http.Response(
            jsonEncode({'error': 'Please sign in', 'error_code': reason}),
            401,
          );
        }),
      ),
      storage: MemoryCalendarStorage(),
    )..user = {'username': 'native'};
    app.api.token = 'old';
    return app;
  }

  setUp(() {
    nativePlatformReady = true;
    nativePreferences.clear();
    secrets.clear();
    requests = 0;
    recoveries = 0;
    browserStarts = 0;
    nativeLoginResult.value = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeChannel, (call) async {
          if (call.method == 'readSession') {
            return secrets[call.arguments['server']];
          }
          if (call.method == 'recoverGravitasLogin') {
            recoveries++;
            return true;
          }
          if (call.method == 'startGravitasLogin') browserStarts++;
          return null;
        });
  });
  tearDown(() {
    nativePlatformReady = false;
    nativePreferences.clear();
    nativeLoginResult.value = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeChannel, null);
  });
  test(
    'Expired linked native session renews once in flight without browser',
    () async {
      final app = expired('session_expired');
      await app.recoverGravitasSession(isForeground: () => true);
      await app.recoverGravitasSession(isForeground: () => true);
      expect(recoveries, 1);
      expect(requests, 2);
      expect(app.connected, true);
      expect(app.api.token, 'old');
      expect(browserStarts, 0);
      secrets[gravitasOrigin] = 'new';
      secrets['$gravitasOrigin/user'] = '{"username":"native"}';
      nativeLoginResult.value = 'recovery_connected';
      await app.completeNativeLogin();
      expect(app.api.token, 'new');
      expect(app.username, 'native');
      expect(browserStarts, 0);
    },
  );
  test('Explicit browser login supersedes a delayed silent recovery', () async {
    final app = expired('session_expired');
    await app.recoverGravitasSession(isForeground: () => true);
    await app.loginWithBrowser();
    secrets[gravitasOrigin] = 'late';
    secrets['$gravitasOrigin/user'] = '{"username":"native"}';
    nativeLoginResult.value = 'recovery_connected';
    await app.completeNativeLogin();
    expect(app.api.token, 'old');
    expect(nativeLoginResult.value, isNull);
    expect(browserStarts, 1);
  });
  test(
    'Revocation and explicit Disconnect cannot trigger automatic broker reentry',
    () async {
      for (final reason in ['gravitas_session_revoked', 'session_invalid']) {
        final app = expired(reason);
        await app.recoverGravitasSession(isForeground: () => true);
        expect(app.connected, false);
        expect(app.api.token, isNull);
        expect(recoveries, 0);
        final count = requests;
        await app.recoverGravitasSession(isForeground: () => true);
        expect(requests, count);
      }
      nativePreferences['spacetime.gravitas.disconnected'] = '1';
      final count = requests;
      await expired(
        'session_expired',
      ).recoverGravitasSession(isForeground: () => true);
      expect(requests, count);
      expect(recoveries, 0);
      expect(browserStarts, 0);
    },
  );
  test(
    'Transient recovery failure retains credentials and offline work',
    () async {
      final app = expired('session_expired');
      await app.save({
        'kind': 'todo',
        'title': 'Queued',
        'due_local': '2026-10-25',
        'all_day': true,
      });
      await app.recoverGravitasSession(isForeground: () => true);
      nativeLoginResult.value = 'recovery_unavailable';
      await app.completeNativeLogin();
      expect(app.connected, true);
      expect(app.api.token, 'old');
      expect(app.entries.single.title, 'Queued');
      expect(app.pendingChanges, 1);
      expect(browserStarts, 0);
    },
  );
  test(
    'Definitive recovery refusal signs out while preserving queued RSVP',
    () async {
      final app = expired('session_expired');
      app.invitations = [
        Entry({
          'id': 'invite',
          'owner': 'other',
          '_account': app.account,
          '_response': 'accepted',
        }),
      ];
      await app.recoverGravitasSession(isForeground: () => true);
      nativeLoginResult.value = 'recovery_login_required';
      await app.completeNativeLogin();
      expect(app.connected, false);
      expect(app.api.token, isNull);
      expect(app.invitations.single.data['_response'], 'accepted');
      final count = requests;
      await app.recoverGravitasSession(isForeground: () => true);
      expect(requests, count);
      expect(browserStarts, 0);
    },
  );
  test(
    'Signed-out native resume and hidden apps do not check cloud auth',
    () async {
      await state().recoverGravitasSession(isForeground: () => true);
      await expired(
        'session_expired',
      ).recoverGravitasSession(isForeground: () => false);
      expect(requests, 0);
      expect(recoveries, 0);
      expect(browserStarts, 0);
    },
  );
  test(
    'A persisted Disconnect wins over a cached native session on restart',
    () async {
      final app = state();
      await app.save({
        'kind': 'todo',
        'title': 'Kept offline',
        'due_local': '2026-10-25',
        'all_day': true,
      });
      final storage = app.storage as MemoryCalendarStorage;
      final cached = jsonDecode(storage.value!) as Map<String, dynamic>;
      cached['user'] = {'username': 'native'};
      cached['server'] = gravitasOrigin;
      storage.value = jsonEncode(cached);
      secrets[gravitasOrigin] = 'cached';
      nativePreferences['spacetime.gravitas.disconnected'] = '1';
      await app.restore();
      expect(app.connected, false);
      expect(app.api.token, isNull);
      expect(app.entries.single.title, 'Kept offline');
      expect(requests, 0);
    },
  );
  test(
    'Disconnect cancels a pending native login before awaiting storage',
    () async {
      final app = state()..user = {'username': 'native'};
      final cancel = Completer<void>();
      secrets[gravitasOrigin] = 'late';
      secrets['$gravitasOrigin/user'] = '{"username":"native"}';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativeChannel, (call) async {
            if (call.method == 'cancelGravitasLogin') await cancel.future;
            if (call.method == 'readSession') {
              return secrets[call.arguments['server']];
            }
            return null;
          });
      final pending = app.disconnectGravitas();
      expect(app.connected, false);
      nativeLoginResult.value = 'connected';
      await app.completeNativeLogin();
      expect(app.connected, false);
      expect(nativeLoginResult.value, isNull);
      cancel.complete();
      await pending;
      expect(app.user, isNull);
      expect(app.api.token, isNull);
    },
  );
  test(
    'Broker cancellation and outage retain an existing offline account',
    () async {
      final app = state()..user = {'username': 'native'};
      app.api.token = 'existing';
      nativeLoginResult.value = 'canceled';
      await app.completeNativeLogin();
      expect(app.connected, true);
      expect(app.api.token, 'existing');
      expect(app.loginError, isNull);
      nativeLoginResult.value = 'unavailable';
      await app.completeNativeLogin();
      expect(app.connected, true);
      expect(app.api.token, 'existing');
      expect(app.loginError, contains('offline'));
    },
  );
  test(
    'Android offers optional Gravitas login without any startup network',
    () async {
      final app = state();
      await app.restore();
      expect(app.api.base, gravitasOrigin);
      expect(app.usesGravitas, true);
      expect(await app.initializeGravitas(), true);
      expect(requests, 0);
      await app.loginLater();
      expect(await app.initializeGravitas(), false);
      expect(requests, 0);
    },
  );
  test(
    'A validated native callback connects from encrypted credentials and keeps offline entries',
    () async {
      final app = state();
      await app.save({
        'kind': 'todo',
        'title': 'Kept offline',
        'due_local': '2026-10-25',
        'all_day': true,
      });
      secrets[gravitasOrigin] = 'test-bearer';
      secrets['$gravitasOrigin/user'] = jsonEncode({
        'username': 'native',
        'name': 'Native',
      });
      nativeLoginResult.value = 'connected';
      await app.completeNativeLogin();
      expect(app.username, 'native');
      expect(app.api.token, 'test-bearer');
      expect(app.entries.single.title, 'Kept offline');
      expect(requests, 0);
      expect(nativeLoginResult.value, isNull);
    },
  );
  test(
    'Failed login and explicit disconnect cannot reattach a cached token',
    () async {
      final app = state();
      nativeLoginResult.value = 'failed';
      await app.completeNativeLogin();
      expect(app.connected, false);
      expect(app.loginError, isNotNull);
      await writePreference('spacetime.gravitas.disconnected', '1');
      secrets[gravitasOrigin] = 'stale';
      secrets['$gravitasOrigin/user'] = '{"username":"native"}';
      nativeLoginResult.value = 'connected';
      await app.completeNativeLogin();
      expect(app.connected, false);
      expect(app.api.token, isNull);
    },
  );
}
