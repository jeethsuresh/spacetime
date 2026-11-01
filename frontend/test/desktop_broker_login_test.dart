import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spacetime/desktop_platform_io.dart';
import 'package:spacetime/desktop_store_broker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  test(
    'Store code exchanges with child PKCE and persists only app session',
    () async {
      final dir = await Directory.systemTemp.createTemp('spacetime-broker-');
      addTearDown(() => dir.delete(recursive: true));
      String? expected;
      final results = <String>[];
      final platform = DesktopPlatform(
        dir,
        onLogin: results.add,
        brokerAuthorize: (challenge, state, username) async {
          expected = challenge;
          expect(username, 'alice');
          return {'code': 'c' * 43, 'sub': 'alice', 'session_id': 'family'};
        },
        openBrowser:
            (_) async => throw StateError('Unexpected browser fallback'),
        client: MockClient((r) async {
          expect(r.url.path, '/api/auth/gravitas/broker');
          final body = jsonDecode(r.body) as Map;
          expect(
            base64UrlEncode(
              sha256
                  .convert(utf8.encode(body['code_verifier'] as String))
                  .bytes,
            ).replaceAll('=', ''),
            expected,
          );
          expect(body['sub'], 'alice');
          return http.Response(
            jsonEncode({
              'token': 'b' * 48,
              'user': {'username': 'alice'},
            }),
            200,
          );
        }),
      );
      await platform.startLogin({'username': 'alice'});
      expect(results, ['connected']);
      expect(
        await platform.invoke('readSession', {
          'server': DesktopPlatform.origin,
        }),
        'b' * 48,
      );
    },
  );
  test(
    'Store denial does not fall back to browser and late exchange cannot restore logout',
    () async {
      final dir = await Directory.systemTemp.createTemp('spacetime-denial-');
      addTearDown(() => dir.delete(recursive: true));
      final results = <String>[];
      var browsers = 0;
      final cancelled = DesktopPlatform(
        dir,
        onLogin: results.add,
        brokerAuthorize: (_, _, _) async => throw StoreSignInCancelled(),
        openBrowser: (_) async {
          browsers++;
          return true;
        },
      );
      await cancelled.startLogin({});
      expect(results, ['cancelled']);
      expect(browsers, 0);
      final response = Completer<http.Response>(),
          requested = Completer<void>();
      final pending = DesktopPlatform(
        dir,
        onLogin: results.add,
        brokerAuthorize:
            (_, _, _) async => {
              'code': 'c' * 43,
              'sub': 'alice',
              'session_id': 'family',
            },
        client: MockClient((_) {
          requested.complete();
          return response.future;
        }),
      );
      final login = pending.startLogin({});
      await requested.future;
      await pending.cancelLogin();
      response.complete(
        http.Response(
          jsonEncode({
            'token': 'b' * 48,
            'user': {'username': 'alice'},
          }),
          200,
        ),
      );
      await login;
      expect(
        await pending.invoke('readSession', {'server': DesktopPlatform.origin}),
        null,
      );
      expect(results, ['cancelled']);
    },
  );
}
