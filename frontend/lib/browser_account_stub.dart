class BrowserAccount {
  const BrowserAccount();
  bool get enabled => false;
  String? readPassiveAttempt() => null;
  void rememberPassiveAttempt(int millis) {}
  String? takeResult() => null;
  void login({bool silent = false}) {}
  void register() {}
}
