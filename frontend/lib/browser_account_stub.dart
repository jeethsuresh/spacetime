import 'dart:async';

import 'native_platform.dart';
import 'desktop_platform.dart' as desktop;

class BrowserAccount {
  const BrowserAccount();
  bool get enabled => nativePlatformReady;
  bool get native => nativePlatformReady;
  String? readPassiveAttempt() => null;
  void rememberPassiveAttempt(int millis) {}
  String? takeResult() => null;
  void login({bool silent = false, String? username}) {
    // Android retains initial shared-calendar consent. Desktop can use the
    // Store profile broker; shared-calendar consent is requested when enabled.
    if (!silent) _open(false, browserOnly: !desktop.ready, username: username);
  }

  void register() => _open(true);
  void browserLogin() => _open(false, browserOnly: true);
  void enableGroups({String? username}) =>
      _open(false, browserOnly: true, groups: true, username: username);
  void _open(
    bool register, {
    bool browserOnly = false,
    bool groups = false,
    String? username,
  }) {
    unawaited(
      invokeNative<void>('startGravitasLogin', {
        'register': register,
        if (username != null) 'username': username,
        'browserOnly': browserOnly,
        'groups': groups,
      }).catchError((Object _) {
        nativeLoginResult.value = 'failed';
      }),
    );
  }
}
