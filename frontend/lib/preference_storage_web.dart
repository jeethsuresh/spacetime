import 'dart:js_interop';

@JS('localStorage')
external _Storage get _storage;
extension type _Storage(JSObject _) implements JSObject {
  external String? getItem(String key);
  external void setItem(String key, String value);
}

String? readPreference(String key) => _storage.getItem(key);
Future<void> writePreference(String key, String value) async =>
    _storage.setItem(key, value);
