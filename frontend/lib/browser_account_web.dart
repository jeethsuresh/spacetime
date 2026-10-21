import 'dart:js_interop';

@JS('location')
external _Location get _location;
extension type _Location(JSObject _) implements JSObject {
  external String get href;
  external void assign(String url);
}

@JS('history.replaceState')
external void _replaceState(JSAny? state, String title, String url);

class BrowserAccount {
  const BrowserAccount();
  bool get enabled =>
      Uri.base.host == 'spacetime.gravitas.cool' ||
      const bool.fromEnvironment('GRAVITAS_LOGIN');
  String? takeResult() {
    final uri = Uri.parse(_location.href);
    final result = uri.queryParameters['gravitas'];
    if (result != null) {
      final query = Map<String, dynamic>.from(uri.queryParametersAll)
        ..remove('gravitas');
      _replaceState(
        null,
        '',
        uri.replace(query: Uri(queryParameters: query).query).toString(),
      );
    }
    return result;
  }

  void login({bool silent = false}) =>
      _location.assign('/auth/gravitas/start${silent ? '?prompt=none' : ''}');
  void register() => _location.assign('https://gravitas.cool/register');
}
