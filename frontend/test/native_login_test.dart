import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:spacetime/calendar_storage.dart';
import 'package:spacetime/models.dart';
import 'package:spacetime/native_platform.dart';
import 'package:spacetime/preference_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secrets = <String, String>{};
  var requests = 0;
  CalendarState state() => CalendarState(
    Api(
      client: MockClient((_) async {
        requests++;
        throw StateError('offline');
      }),
    ),
    storage: MemoryCalendarStorage(),
  );
  setUp(() {
    nativePlatformReady = true;
    nativePreferences.clear();
    secrets.clear();
    requests = 0;
    nativeLoginResult.value = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeChannel, (call) async {
          if (call.method == 'readSession') {
            return secrets[call.arguments['server']];
          }
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
