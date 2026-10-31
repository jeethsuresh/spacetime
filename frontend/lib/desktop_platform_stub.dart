bool get ready => false;
bool get supported => false;
Future<Map<String, dynamic>> initialize(void Function(String) onLogin) async =>
    {};
Future<T?> invoke<T>(String method, [Map<String, dynamic>? arguments]) async =>
    null;
