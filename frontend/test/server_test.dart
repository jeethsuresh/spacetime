import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spacetime/models.dart';
import 'package:spacetime/preference_storage.dart';

void main() {
  test(
    'Server addresses preserve HTTPS origins and reject unsafe or ambiguous URLs',
    () {
      expect(
        normalizeServerAddress(' https://calendar.example.com/ '),
        'https://calendar.example.com',
      );
      expect(
        normalizeServerAddress('https://calendar.example.com:8443'),
        'https://calendar.example.com:8443',
      );
      expect(
        normalizeServerAddress('http://10.0.2.2:8080'),
        'http://10.0.2.2:8080',
      );
      for (final invalid in [
        'http://calendar.example.com',
        'http://192.168.1.2',
        'https://user:pass@example.com',
        'https://example.com/api',
        'https://example.com?token=secret',
        'https://example.com#fragment',
        'not-a-url',
        'ftp://example.com',
      ]) {
        expect(
          () => normalizeServerAddress(invalid),
          throwsA(isA<ApiException>()),
        );
      }
    },
  );
  test(
    'Changing server discards the previous account and bearer token',
    () async {
      await writePreference('spacetime.server', 'https://old.example.com');
      final api = Api(client: MockClient((_) async => http.Response('', 204)))
        ..token = 'old-token';
      final state = CalendarState(api)
        ..user = {'username': 'old', 'name': 'Old'};
      await state.configureServer('https://new.example.com/');
      expect(api.base, 'https://new.example.com');
      expect(api.token, isNull);
      expect(state.user, isNull);
      final restored = Api();
      expect(restored.base, 'https://new.example.com');
    },
  );
  test('An expired server session still allows local sign-out', () async {
    await writePreference('spacetime.server', 'https://calendar.example.com');
    final state = CalendarState(
      Api(
        client: MockClient(
          (_) async => http.Response('{"error":"Expired"}', 401),
        ),
      ),
    )..user = {'username': 'old'};
    await state.signOut();
    expect(state.user, isNull);
    expect(state.api.token, isNull);
  });
}
