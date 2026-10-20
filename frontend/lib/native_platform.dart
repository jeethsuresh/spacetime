import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const nativeChannel = MethodChannel('com.jeethsuresh.spacetime/platform');
final nativePreferences = <String, String>{};
bool nativePlatformReady = false;
String nativeTimeZone = 'UTC';
final calendarNavigation = ValueNotifier<Map<String, String>?>(null);
void receiveCalendarNavigation(dynamic value) {
  if (value is! Map) return;
  final date = DateTime.tryParse(value['date'] as String? ?? '');
  final view = value['view'];
  if (date == null || !['Daily', 'Weekly'].contains(view)) return;
  calendarNavigation.value = {
    'date': value['date'] as String,
    'view': view as String,
  };
}

Future<void> initializeNativePlatform() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  final values = await nativeChannel.invokeMapMethod<String, dynamic>(
    'initialize',
  );
  nativeTimeZone = values?['timezone'] as String? ?? 'UTC';
  receiveCalendarNavigation(values?['navigation']);
  nativeChannel.setMethodCallHandler((call) async {
    if (call.method == 'openCalendar') {
      receiveCalendarNavigation(call.arguments);
    }
  });
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
