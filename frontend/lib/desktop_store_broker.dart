// https://github.com/jeethsuresh/appstore/blob/main/DESKTOP_SIGN_IN.md
// Private Store desktop broker v1. Keep this dependency-free helper in native
// code; never expose its discovery nonce or launch descriptor to web content.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

class StoreSignInCancelled implements Exception {
  @override
  String toString() => 'Sign-in cancelled.';
}

String desktopStoreDiscoveryPath() {
  final env = Platform.environment;
  final home = env[Platform.isWindows ? 'USERPROFILE' : 'HOME'] ?? '';
  final root = Platform.isWindows
      ? env['APPDATA'] ?? ''
      : Platform.isMacOS
      ? '$home/Library/Application Support'
      : env['XDG_DATA_HOME'] ?? '$home/.local/share';
  return '$root/Gravitas/Private Store/broker-v1.json';
}

Future<Map<String, dynamic>?> authorizeDesktopStore({
  required String appOrigin,
  required String challenge,
  required String state,
  String? username,
  File? discoveryFile,
  Future<void> Function(String, List<String>)? launch,
}) async {
  final proof = RegExp(r'^[A-Za-z0-9_-]{43}$');
  if (!proof.hasMatch(challenge) || !proof.hasMatch(state)) {
    throw ArgumentError('Invalid sign-in proof');
  }
  final file = discoveryFile ?? File(desktopStoreDiscoveryPath());
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
  try {
    Future<Map<String, dynamic>> read() async {
      final stat = await file.stat();
      if (stat.size > 8192 || stat.type != FileSystemEntityType.file) {
        throw const FormatException('Invalid Store discovery');
      }
      return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    }

    Future<Map<String, dynamic>> request(Map<String, dynamic> d) async {
      final endpoint = Uri.parse(d['endpoint'] as String);
      if (d['protocolVersion'] != 1 ||
          !proof.hasMatch(d['nonce'] as String) ||
          endpoint.scheme != 'http' ||
          endpoint.host != '127.0.0.1' ||
          endpoint.port < 1024 ||
          endpoint.path != '/v1/authorize' ||
          endpoint.userInfo.isNotEmpty ||
          endpoint.hasQuery ||
          endpoint.hasFragment) {
        throw const FormatException('Invalid Store endpoint');
      }
      final r = await client.postUrl(endpoint);
      r.followRedirects = false;
      r.headers.set('Authorization', 'Bearer ${d['nonce']}');
      r.headers.set('Content-Type', 'application/json');
      r.write(
        jsonEncode({
          'protocolVersion': 1,
          'appOrigin': appOrigin,
          'codeChallenge': challenge,
          'state': state,
          if (username != null) 'username': username,
        }),
      );
      final response = await r.close().timeout(const Duration(seconds: 95));
      var bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
        if (bytes.length > 8192) {
          throw const FormatException('Invalid Store response');
        }
      }
      if (response.statusCode != 200) return {'status': 'unavailable'};
      return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    }

    var descriptor = await read();
    Map<String, dynamic> result;
    try {
      result = await request(descriptor).timeout(const Duration(seconds: 95));
    } on SocketException {
      final command = descriptor['launch'] as Map<String, dynamic>;
      final executable = command['file'] as String;
      final args = (command['args'] as List).cast<String>();
      // Only this OS user's installed Store writes this descriptor. No shell,
      // remote command, environment overrides, or client-supplied arguments.
      if (!File(executable).isAbsolute ||
          args.length > 1 ||
          (args.isNotEmpty && !Directory(args.single).isAbsolute)) {
        return null;
      }
      if (launch != null) {
        await launch(executable, args);
      } else {
        await Process.start(executable, args, mode: ProcessStartMode.detached);
      }
      Map<String, dynamic>? reply;
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        descriptor = await read();
        try {
          reply = await request(descriptor)
              .timeout(const Duration(seconds: 95));
          break;
        } on SocketException {
          continue;
        }
      }
      if (reply == null) return null;
      result = reply;
    }
    if (result['status'] == 'cancelled') throw StoreSignInCancelled();
    if (result['status'] != 'authorized') return null;
    if (result['protocolVersion'] != 1 ||
        result['issuer'] != 'https://gravitas.cool' ||
        result['appOrigin'] != appOrigin ||
        result['redirectUri'] != '$appOrigin/auth/gravitas/callback' ||
        result['state'] != state ||
        result['codeChallenge'] != challenge ||
        !proof.hasMatch(result['code'] as String) ||
        result['sub'] is! String ||
        (result['sub'] as String).isEmpty ||
        result['session_id'] is! String ||
        (result['session_id'] as String).isEmpty ||
        result['expires_in'] is! int ||
        (result['expires_in'] as int) < 1 ||
        (result['expires_in'] as int) > 60) {
      return null;
    }
    return result;
  } on StoreSignInCancelled {
    rethrow;
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}
