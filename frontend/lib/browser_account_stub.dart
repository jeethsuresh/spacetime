import 'dart:async';
import 'native_platform.dart';

class BrowserAccount {
  const BrowserAccount();
  bool get enabled => nativePlatformReady;
  bool get native => nativePlatformReady;
  String? readPassiveAttempt() => null;
  void rememberPassiveAttempt(int millis) {}
  String? takeResult() => null;
  void login({bool silent = false}) {
    if (!silent) _open(false);
  }

  void register() => _open(true);
  void browserLogin() => _open(false, browserOnly: true);
  void enableGroups() => _open(false, browserOnly: true, groups: true);
  void _open(bool register, {bool browserOnly = false, bool groups = false}) {
    unawaited(
      nativeChannel
          .invokeMethod<void>('startGravitasLogin', {
            'register': register,
            'browserOnly': browserOnly,
            'groups': groups,
          })
          .catchError((Object _) {
            nativeLoginResult.value = 'failed';
          }),
    );
  }
}
