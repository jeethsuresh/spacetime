import 'dart:js_interop';

@JS('Intl.DateTimeFormat')
external _DateFormat _format();
extension type _DateFormat(JSObject _) implements JSObject {
  external _Options resolvedOptions();
}
extension type _Options(JSObject _) implements JSObject {
  external String get timeZone;
}
String deviceTimeZone() => _format().resolvedOptions().timeZone;
