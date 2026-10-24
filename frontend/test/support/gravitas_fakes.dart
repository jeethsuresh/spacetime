import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spacetime/browser_account.dart';
import 'package:spacetime/calendar_storage.dart';
import 'package:spacetime/models.dart';

class FakeBrowser extends BrowserAccount {
  String? passiveAttempt;
  @override
  String? readPassiveAttempt() => passiveAttempt;
  @override
  void rememberPassiveAttempt(int millis) => passiveAttempt = millis.toString();
  String? result;
  int silent = 0, interactive = 0, registrations = 0;
  String? username;
  FakeBrowser({this.result});
  @override
  bool get enabled => true;
  @override
  String? takeResult() {
    final value = result;
    result = null;
    return value;
  }

  @override
  void login({bool silent = false, String? username}) {
    this.username = username;
    if (silent) {
      this.silent++;
    } else {
      interactive++;
    }
  }

  @override
  void register() {
    registrations++;
  }
}

CalendarState accountState(
  FakeBrowser browser, {
  String defaultDomain = 'gravitas.cool',
  bool signedIn = false,
  bool offline = false,
  bool signedInHint = false,
  List<String>? paths,
}) => CalendarState(
  Api(
    client: MockClient((request) async {
      paths?.add(request.url.path);
      if (offline) throw StateError('offline');
      if (request.url.path == '/api/auth/config') {
        return http.Response(
          jsonEncode({
            'gravitas_enabled': true,
            'default_domain': defaultDomain,
            'gravitas_signed_in': signedInHint,
          }),
          200,
        );
      }
      if (request.url.path == '/api/me' && signedIn) {
        return http.Response('{"username":"jeeth","name":"Jeeth"}', 200);
      }
      if (request.url.path == '/api/logout') return http.Response('', 204);
      return http.Response('{"error":"Please sign in"}', 401);
    }),
  ),
  browserAccount: browser,
  storage: MemoryCalendarStorage(),
);
