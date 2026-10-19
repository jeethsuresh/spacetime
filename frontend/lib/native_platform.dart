import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const nativeChannel = MethodChannel('com.jeethsuresh.spacetime/platform');
final nativePreferences = <String, String>{};
bool nativePlatformReady = false;
String nativeTimeZone = 'UTC';

Future<void> initializeNativePlatform() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  final values = await nativeChannel.invokeMapMethod<String, dynamic>(
    'initialize',
  );
  nativeTimeZone = values?['timezone'] as String? ?? 'UTC';
  nativePreferences.addAll(
    Map<String, String>.from(values?['preferences'] as Map? ?? {}),
  );
  nativePlatformReady = true;
}

Future<String?> readNativeSession(String server) async =>
    nativePlatformReady
        ? nativeChannel.invokeMethod<String>('readSession', {'server': server})
        : null;
Future<void> writeNativeSession(String server, String? token) async {
  if (nativePlatformReady) {
    await nativeChannel.invokeMethod<void>('writeSession', {
      'server': server,
      'token': token,
    });
  }
}
