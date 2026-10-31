import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spacetime/desktop_platform_io.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test(
    'calendar and preference writes survive restarts and concurrent saves',
    () async {
      final dir = await Directory.systemTemp.createTemp('spacetime-desktop-');
      addTearDown(() => dir.delete(recursive: true));
      final store = DesktopFiles(dir);
      await Future.wait([
        store.write('calendar.json', 'first'),
        store.write('calendar.json', 'latest'),
      ]);
      expect(await DesktopFiles(dir).read('calendar.json'), 'latest');
      await store.write('preferences.json', '{"week":"Monday"}');
      expect(
        await DesktopFiles(dir).read('preferences.json'),
        contains('Monday'),
      );
      expect(await dir.list().where((f) => f.path.endsWith('.tmp')).length, 0);
    },
  );

  test(
    'browser callback requires state and PKCE; only the app stores the bearer',
    () async {
      final dir = await Directory.systemTemp.createTemp('spacetime-login-');
      addTearDown(() => dir.delete(recursive: true));
      late Uri approval;
      final finished = Completer<String>();
      var exchanges = 0;
      final platform = DesktopPlatform(
        dir,
        onLogin: finished.complete,
        openBrowser: (uri) async {
          approval = uri;
          return true;
        },
        client: MockClient((request) async {
          exchanges++;
          final body = jsonDecode(request.body) as Map;
          final challenge = base64UrlEncode(
            sha256.convert(utf8.encode(body['code_verifier'] as String)).bytes,
          ).replaceAll('=', '');
          expect(challenge, approval.queryParameters['native_challenge']);
          expect(body['code'], 'a' * 48);
          return http.Response(
            jsonEncode({
              'token': 'b' * 48,
              'user': {'username': 'native'},
            }),
            200,
          );
        }),
      );
      addTearDown(platform.cancelLogin);
      await platform.startLogin({'username': 'native'});
      final callback = Uri.parse(
        approval.queryParameters['native_return_uri']!,
      );
      expect(callback.host, '127.0.0.1');
      final wrong = await http.get(
        callback.replace(
          queryParameters: {
            'state': 'forged',
            'result': 'connected',
            'code': 'a' * 48,
          },
        ),
      );
      expect(wrong.statusCode, 400);
      expect(exchanges, 0);
      final response = await http.get(
        callback.replace(
          queryParameters: {
            'state': approval.queryParameters['native_state']!,
            'result': 'connected',
            'code': 'a' * 48,
          },
        ),
      );
      expect(response.body, isNot(contains('b' * 48)));
      expect(await finished.future, 'connected');
      expect(
        await platform.invoke('readSession', {
          'server': DesktopPlatform.origin,
        }),
        'b' * 48,
      );
      expect(exchanges, 1);
    },
  );

  test('disconnect during exchange cannot persist the late login', () async {
    final dir = await Directory.systemTemp.createTemp('spacetime-cancel-');
    addTearDown(() => dir.delete(recursive: true));
    late Uri approval;
    final response = Completer<http.Response>(), requested = Completer<void>();
    final results = <String>[];
    final platform = DesktopPlatform(
      dir,
      onLogin: results.add,
      openBrowser: (uri) async {
        approval = uri;
        return true;
      },
      client: MockClient((_) {
        requested.complete();
        return response.future;
      }),
    );
    await platform.startLogin({});
    final callback = Uri.parse(
      approval.queryParameters['native_return_uri']!,
    ).replace(
      queryParameters: {
        'state': approval.queryParameters['native_state']!,
        'result': 'connected',
        'code': 'a' * 48,
      },
    );
    await http.get(callback);
    await requested.future;
    await platform.cancelLogin();
    response.complete(
      http.Response(
        jsonEncode({
          'token': 'b' * 48,
          'user': {'username': 'late'},
        }),
        200,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      await platform.invoke('readSession', {'server': DesktopPlatform.origin}),
      isNull,
    );
    expect(results, isEmpty);
  });
}
