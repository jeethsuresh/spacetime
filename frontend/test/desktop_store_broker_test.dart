import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:spacetime/desktop_store_broker.dart';

void main() {
  HttpOverrides.global = null;
  test(
    'Store IPC binds code to request and honors explicit cancellation',
    () async {
      final directory = await Directory.systemTemp.createTemp('store-broker-');
      addTearDown(() => directory.delete(recursive: true));
      final descriptor = File('${directory.path}/broker.json');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var mode = 'authorized', requests = 0;
      server.listen((request) async {
        requests++;
        expect(request.method, 'POST');
        expect(request.headers.value('Origin'), null);
        expect(request.headers.value('Authorization'), 'Bearer ${'n' * 43}');
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        expect(body.containsKey('verifier'), false);
        final reply = {
          'protocolVersion': 1,
          'status': mode,
          'issuer':
              mode == 'forged'
                  ? 'https://evil.example'
                  : 'https://gravitas.cool',
          'appOrigin': body['appOrigin'],
          'redirectUri': '${body['appOrigin']}/auth/gravitas/callback',
          'codeChallenge': body['codeChallenge'],
          'state': body['state'],
          'code': 'c' * 43,
          'sub': 'stable-subject',
          'session_id': 'family',
          'expires_in': 60,
        };
        if (mode == 'forged') reply['status'] = 'authorized';
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(reply));
        await request.response.close();
      });
      await descriptor.writeAsString(
        jsonEncode({
          'protocolVersion': 1,
          'nonce': 'n' * 43,
          'endpoint': 'http://127.0.0.1:${server.port}/v1/authorize',
        }),
      );
      Future<Map<String, dynamic>?> authorize() => authorizeDesktopStore(
        appOrigin: 'https://new-app.example',
        challenge: 'p' * 43,
        state: 's' * 43,
        discoveryFile: descriptor,
      );
      expect((await authorize())?['code'], 'c' * 43);
      mode = 'cancelled';
      await expectLater(authorize(), throwsA(isA<StoreSignInCancelled>()));
      mode = 'forged';
      expect(await authorize(), null);
      mode = 'consent_required';
      expect(await authorize(), null);
      expect(requests, 4);
      await descriptor.writeAsString(
        jsonEncode({
          'protocolVersion': 1,
          'nonce': 'n' * 43,
          'endpoint': 'https://evil.example/v1/authorize',
        }),
      );
      expect(await authorize(), null);
      expect(requests, 4);
    },
  );
  test(
    'Store helper wakes cold Store using its fresh discovery descriptor',
    () async {
      final directory = await Directory.systemTemp.createTemp('store-cold-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/broker.json');
      final old = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final oldPort = old.port;
      await old.close(force: true);
      await file.writeAsString(
        jsonEncode({
          'protocolVersion': 1,
          'nonce': 'n' * 43,
          'endpoint': 'http://127.0.0.1:$oldPort/v1/authorize',
          'launch': {'file': Platform.resolvedExecutable, 'args': <String>[]},
        }),
      );
      var wakes = 0;
      final result = await authorizeDesktopStore(
        appOrigin: 'https://new-app.example',
        challenge: 'p' * 43,
        state: 's' * 43,
        discoveryFile: file,
        launch: (executable, args) async {
          wakes++;
          expect(executable, Platform.resolvedExecutable);
          expect(args, isEmpty);
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          await file.writeAsString(
            jsonEncode({
              'protocolVersion': 1,
              'nonce': 'r' * 43,
              'endpoint': 'http://127.0.0.1:${server.port}/v1/authorize',
            }),
          );
          server.listen((request) async {
            expect(
              request.headers.value('Authorization'),
              'Bearer ${'r' * 43}',
            );
            await request.drain<void>();
            request.response.write(
              jsonEncode({'protocolVersion': 1, 'status': 'consent_required'}),
            );
            await request.response.close();
          });
        },
      );
      expect(result, null);
      expect(wakes, 1);
    },
  );
}
