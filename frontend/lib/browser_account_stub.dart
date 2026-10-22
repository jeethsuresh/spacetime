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
  void _open(bool register) {
    unawaited(
      nativeChannel
          .invokeMethod<void>('startGravitasLogin', {'register': register})
          .catchError((Object _) {
            nativeLoginResult.value = 'failed';
          }),
    );
  }
}
