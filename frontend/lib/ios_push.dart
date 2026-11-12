import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class IOSPush {
  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  static const channel = MethodChannel('cool.gravitas/apns');

  static Future<void> bind(String? credential) async {
    if (!supported || credential == null) return;
    try {
      await channel.invokeMethod<void>('bind', credential);
    } on MissingPluginException {
      // A local sign-in is still usable when the iOS bridge is unavailable.
    } on PlatformException {
      // APNs registration is retried independently of sign-in.
    }
  }

  static Future<void> unbind() async {
    if (!supported) return;
    try {
      await channel.invokeMethod<void>('unbind');
    } on MissingPluginException {
      // This runtime has no iOS notification registration.
    } on PlatformException {
      // Local sign-out can finish without a working notification service.
    }
  }

  static Future<Map<String, dynamic>> takeOpen() async =>
      await channel.invokeMapMethod<String, dynamic>('takeOpen') ?? {};
}
