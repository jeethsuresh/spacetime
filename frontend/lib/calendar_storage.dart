import 'native_platform.dart';
import 'preference_storage.dart';

abstract class CalendarStorage {
  Future<String?> read();
  Future<void> write(String value);
}

class DeviceCalendarStorage implements CalendarStorage {
  static const key = 'spacetime.calendar.v1';
  @override
  Future<String?> read() async =>
      nativePlatformReady
          ? nativeChannel.invokeMethod<String>('readCalendar')
          : readPreference(key);
  @override
  Future<void> write(String value) async {
    if (nativePlatformReady) {
      await nativeChannel.invokeMethod<void>('writeCalendar', {'value': value});
    } else {
      await writePreference(key, value);
    }
  }
}

class MemoryCalendarStorage implements CalendarStorage {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String value) async {
    this.value = value;
  }
}
