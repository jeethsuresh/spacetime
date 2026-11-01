import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'desktop_store_broker.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

bool get supported => [
  TargetPlatform.linux,
  TargetPlatform.macOS,
  TargetPlatform.windows,
].contains(defaultTargetPlatform);
bool get ready => _service != null;
DesktopPlatform? _service;
Future<Map<String, dynamic>> initialize(void Function(String) onLogin) async {
  final directory = await getApplicationSupportDirectory();
  final service = DesktopPlatform(directory, onLogin: onLogin);
  final values = await service.initialize();
  _service = service;
  return values;
}

Future<T?> invoke<T>(String method, [Map<String, dynamic>? arguments]) async =>
    await _service!.invoke(method, arguments ?? {}) as T?;

/// All mutable data lives outside the versioned executable installed by Store.
class DesktopFiles {
  final Directory directory;
  Future<void> _writes = Future.value();
  DesktopFiles(this.directory);
  Future<String?> read(String name) async {
    await _writes;
    final file = File('${directory.path}/$name');
    return await file.exists() ? file.readAsString() : null;
  }

  Future<void> write(String name, String value) {
    _writes = _writes.catchError((Object _) {}).then((_) async {
      await directory.create(recursive: true);
      final temporary = File('${directory.path}/$name.tmp');
      await temporary.writeAsString(value, flush: true);
      await temporary.rename('${directory.path}/$name');
    });
    return _writes;
  }
}

class DesktopPlatform {
  static const origin = 'https://spacetime.gravitas.cool';
  final DesktopFiles files;
  final void Function(String) onLogin;
  final FlutterSecureStorage secrets;
  final http.Client client;
  final Future<bool> Function(Uri) openBrowser;
  final Future<Map<String, dynamic>?> Function(String, String, String?)
  brokerAuthorize;
  final preferences = <String, String>{};
  HttpServer? _callback;
  Timer? _timeout;
  int _generation = 0;
  Future<void> _credentialWrites = Future.value();
  Future<void> _credentials(Future<void> Function() operation) {
    _credentialWrites = _credentialWrites
        .catchError((Object _) {})
        .then((_) => operation());
    return _credentialWrites;
  }

  DesktopPlatform(
    Directory directory, {
    required this.onLogin,
    this.secrets = const FlutterSecureStorage(
      mOptions: MacOsOptions(usesDataProtectionKeychain: false),
    ),
    http.Client? client,
    Future<bool> Function(Uri)? openBrowser,
    Future<Map<String, dynamic>?> Function(String, String, String?)?
    brokerAuthorize,
  }) : files = DesktopFiles(directory),
       client = client ?? http.Client(),
       brokerAuthorize =
           brokerAuthorize ??
           ((challenge, state, username) => authorizeDesktopStore(
             appOrigin: origin,
             challenge: challenge,
             state: state,
             username: username,
           )),
       openBrowser =
           openBrowser ??
           ((uri) => launchUrl(uri, mode: LaunchMode.externalApplication));

  Future<Map<String, dynamic>> initialize() async {
    final saved = await files.read('preferences.json');
    if (saved != null) {
      preferences.addAll(Map<String, String>.from(jsonDecode(saved)));
    }
    final timezone = await FlutterTimezone.getLocalTimezone();
    return {'preferences': preferences, 'timezone': timezone.identifier};
  }

  Future<dynamic> invoke(String method, Map<String, dynamic> arguments) async {
    switch (method) {
      case 'readCalendar':
        return files.read('calendar.json');
      case 'writeCalendar':
        return files.write('calendar.json', arguments['value'] as String);
      case 'writePreference':
        preferences[arguments['key'] as String] = arguments['value'] as String;
        return files.write('preferences.json', jsonEncode(preferences));
      case 'readSession':
        return secrets.read(key: 'spacetime:${arguments['server']}');
      case 'writeSession':
        return _credentials(() async {
          final key = 'spacetime:${arguments['server']}';
          if (arguments.containsKey('expectedToken') &&
              await secrets.read(key: key) != arguments['expectedToken']) {
            return;
          }
          if (arguments['token'] == null) {
            await secrets.delete(key: key);
          } else {
            await secrets.write(key: key, value: arguments['token'] as String);
          }
        });
      case 'startGravitasLogin':
        return startLogin(arguments);
      case 'cancelGravitasLogin':
        return cancelLogin();
      case 'recoverGravitasLogin':
        return recoverLogin(arguments);
      case 'requestNotifications':
        return false;
      case 'scheduleReminders':
        return;
      default:
        throw UnsupportedError('Unsupported desktop operation: $method');
    }
  }

  Future<void> cancelLogin() async {
    _generation++;
    _timeout?.cancel();
    await _callback?.close(force: true);
    _callback = null;
  }

  Future<void> acceptSession(http.Response response, int generation) async {
    if (generation != _generation) return;
    final result = jsonDecode(response.body) as Map<String, dynamic>;
    final token = result['token'] as String;
    final user = result['user'] as Map<String, dynamic>;
    if (!RegExp(r'^[a-f0-9]{48}$').hasMatch(token) ||
        (user['username'] as String).isEmpty) {
      throw StateError('Invalid session');
    }
    await _credentials(() async {
      if (generation != _generation) return;
      await secrets.write(
        key: 'spacetime:$origin/user',
        value: jsonEncode(user),
      );
      await secrets.write(key: 'spacetime:$origin', value: token);
      if (generation != _generation) {
        await secrets.delete(key: 'spacetime:$origin');
        await secrets.delete(key: 'spacetime:$origin/user');
        return;
      }
      onLogin('connected');
    });
  }

  Future<bool> tryBroker(
    String verifier,
    String challenge,
    String state,
    int generation,
    Map<String, dynamic> arguments, {
    bool recovery = false,
  }) async {
    final broker = await brokerAuthorize(
      challenge,
      state,
      arguments['username'] as String?,
    );
    if (generation != _generation) return true;
    if (broker == null) return false;
    final prior =
        recovery ? await secrets.read(key: 'spacetime:$origin') : null;
    final response = await client
        .post(
          Uri.parse('$origin/api/auth/gravitas/broker'),
          headers: {
            'Content-Type': 'application/json',
            if (prior != null) 'Authorization': 'Bearer $prior',
          },
          body: jsonEncode({
            'code': broker['code'],
            'code_verifier': verifier,
            'session_id': broker['session_id'],
            'sub': broker['sub'],
            if (recovery) 'recovery': true,
          }),
        )
        .timeout(const Duration(seconds: 20));
    if (generation != _generation) return true;
    if ([400, 401, 403, 404, 405].contains(response.statusCode)) return false;
    if (response.statusCode != 200) {
      throw StateError('Store sign-in is temporarily unavailable');
    }
    await acceptSession(response, generation);
    return true;
  }

  Future<bool> recoverLogin(Map<String, dynamic> arguments) async {
    await cancelLogin();
    final generation = _generation;
    String random() => base64UrlEncode(
      List.generate(32, (_) => Random.secure().nextInt(256)),
    ).replaceAll('=', '');
    final verifier = random(), state = random();
    final challenge = base64UrlEncode(
      sha256.convert(utf8.encode(verifier)).bytes,
    ).replaceAll('=', '');
    return tryBroker(
      verifier,
      challenge,
      state,
      generation,
      arguments,
      recovery: true,
    );
  }

  Future<void> startLogin(Map<String, dynamic> arguments) async {
    await cancelLogin();
    final generation = _generation;
    String random() => base64UrlEncode(
      List.generate(32, (_) => Random.secure().nextInt(256)),
    ).replaceAll('=', '');
    final state = random(), verifier = random();
    final challenge = base64UrlEncode(
      sha256.convert(utf8.encode(verifier)).bytes,
    ).replaceAll('=', '');
    if (arguments['register'] != true &&
        arguments['groups'] != true &&
        arguments['browserOnly'] != true) {
      try {
        if (await tryBroker(verifier, challenge, state, generation, arguments)) {
          return;
        }
      } on StoreSignInCancelled {
        if (generation == _generation) onLogin('cancelled');
        return;
      }
    }
    if (generation != _generation) return;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _callback = server;
    final callback = 'http://127.0.0.1:${server.port}/auth/callback';
    var consumed = false;
    server.listen((request) async {
      final q = request.uri.queryParametersAll;
      if (consumed ||
          request.method != 'GET' ||
          request.uri.path != '/auth/callback' ||
          q.keys.any((key) => !['state', 'code', 'result'].contains(key)) ||
          q.values.any((values) => values.length != 1) ||
          q['state']?.single != state) {
        request.response.statusCode = 400;
        await request.response.close();
        return;
      }
      consumed = true;
      _timeout?.cancel();
      request.response.headers.contentType = ContentType.text;
      request.response.headers.set('Cache-Control', 'no-store');
      request.response.write('Return to Spacetime to finish signing in.');
      await request.response.close();
      try {
        if (q['result']?.single != 'connected') {
          throw StateError('Login was not completed');
        }
        final code = q['code']?.single ?? '';
        if (!RegExp(r'^[a-f0-9]{48}$').hasMatch(code)) {
          throw StateError('Invalid login code');
        }
        final response = await client
            .post(
              Uri.parse('$origin/api/auth/gravitas/android'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'code': code, 'code_verifier': verifier}),
            )
            .timeout(const Duration(seconds: 20));
        if (response.statusCode != 200 || generation != _generation) {
          throw StateError('Login expired');
        }
        await acceptSession(response, generation);
      } catch (_) {
        if (generation == _generation) onLogin('failed');
      } finally {
        await server.close(force: true);
        if (_callback == server) _callback = null;
      }
    });
    _timeout = Timer(const Duration(minutes: 5), () {
      if (generation == _generation) {
        unawaited(cancelLogin());
        onLogin('failed');
      }
    });
    final uri = Uri.parse('$origin/auth/gravitas/start').replace(
      queryParameters: {
        'native_challenge': challenge,
        'native_state': state,
        'native_return_uri': callback,
        if (arguments['username'] != null)
          'username': arguments['username'] as String,
        if (arguments['register'] == true) 'screen': 'register',
        if (arguments['groups'] == true) 'groups': '1',
      },
    );
    try {
      if (!await openBrowser(uri)) {
        throw StateError('Could not open the sign-in browser');
      }
    } catch (_) {
      await cancelLogin();
      rethrow;
    }
  }
}
