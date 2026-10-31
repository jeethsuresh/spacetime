import 'desktop_platform.dart' as desktop;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const nativeChannel = MethodChannel('com.jeethsuresh.spacetime/platform');
final nativePreferences = <String, String>{};
bool nativePlatformReady = false;
String nativeTimeZone = 'UTC';
final calendarNavigation = ValueNotifier<Map<String, String>?>(null);
const gravitasOrigin = 'https://spacetime.gravitas.cool';
final nativeLoginResult = ValueNotifier<String?>(null);
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

bool get nativeNotificationsSupported => !desktop.ready;
Future<T?> invokeNative<T>(String method, [Map<String, dynamic>? arguments]) =>
    desktop.ready
        ? desktop.invoke<T>(method, arguments)
        : nativeChannel.invokeMethod<T>(method, arguments);

Future<void> initializeNativePlatform() async {
  if (!kIsWeb && desktop.supported) {
    final values = await desktop.initialize(
      (result) => nativeLoginResult.value = result,
    );
    nativePreferences.addAll(
      Map<String, String>.from(values['preferences'] as Map),
    );
    nativeTimeZone = values['timezone'] as String;
    nativePlatformReady = true;
    return;
  }
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  final values = await nativeChannel.invokeMapMethod<String, dynamic>(
    'initialize',
  );
  nativeTimeZone = values?['timezone'] as String? ?? 'UTC';
  receiveCalendarNavigation(values?['navigation']);
  nativeLoginResult.value = values?['gravitasResult'] as String?;
  nativeChannel.setMethodCallHandler((call) async {
    if (call.method == 'openCalendar') {
      receiveCalendarNavigation(call.arguments);
    } else if (call.method == 'gravitasResult') {
      nativeLoginResult.value = call.arguments as String?;
    }
  });
  nativePreferences.addAll(
    Map<String, String>.from(values?['preferences'] as Map? ?? {}),
  );
  nativePlatformReady = true;
}

Future<String?> readNativeSession(String server) async =>
    nativePlatformReady
        ? invokeNative<String>('readSession', {'server': server})
        : null;
Future<void> writeNativeSession(String server, String? token) async {
  if (nativePlatformReady) {
    await invokeNative<void>('writeSession', {
      'server': server,
      'token': token,
    });
  }
}

Future<void> clearNativeSession(String server, String? expectedToken) async {
  if (nativePlatformReady) {
    await invokeNative<void>('writeSession', {
      'server': server,
      'token': null,
      'expectedToken': expectedToken,
    });
  }
}
