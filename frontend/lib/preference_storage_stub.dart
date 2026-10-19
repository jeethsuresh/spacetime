import 'native_platform.dart';

String? readPreference(String key) => nativePreferences[key];
Future<void> writePreference(String key, String value) async {
  if (nativePlatformReady) {
    await nativeChannel.invokeMethod<void>('writePreference', {
      'key': key,
      'value': value,
    });
  }
  nativePreferences[key] = value;
}
