import 'dart:convert';
import 'time_zone.dart';
import 'preference_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

DateTime day(DateTime d) => DateTime.utc(d.year, d.month, d.day);
List<DateTime> monthCellDates(DateTime month, {int weekStartsOn = 0}) {
  final first = DateTime.utc(month.year, month.month);
  final offset = (first.weekday % 7 - weekStartsOn + 7) % 7;
  final count =
      ((DateTime.utc(month.year, month.month + 1, 0).day + offset) / 7).ceil() *
      7;
  return List.generate(
    count,
    (i) => DateTime.utc(month.year, month.month, 1 - offset + i),
  );
}

const kinds = ['event', 'todo', 'occasion'];
const kindLabels = {
  'event': 'Events',
  'todo': 'Todos',
  'occasion': 'Occasions',
};

class Entry {
  final Map<String, dynamic> data;
  Entry(this.data);
  String get id => data['id'] as String;
  String get title => data['title'] as String;
  String get kind =>
      ['birthday', 'holiday'].contains(data['kind'])
          ? 'occasion'
          : data['kind'] as String;
  String get owner => data['owner'] as String;
  bool get allDay => data['all_day'] == true;
  bool get yearly => data['yearly'] == true;
  bool get completed => data['completed'] == true;
  bool get imported => data['imported'] == true;
  int get version => data['version'] as int;
  String get description => data['description'] as String? ?? '';
  String get location => data['location'] as String? ?? '';
  Map<String, String> get attendees =>
      Map<String, String>.from(data['attendees'] as Map? ?? {});
  DateTime? date(String key) {
    final raw = data[key] as String?;
    if (raw == null) return null;
    final parsed = DateTime.parse(raw);
    if (allDay) {
      return DateTime.utc(parsed.year, parsed.month, parsed.day);
    }
    if (timezone == 'floating') {
      return DateTime(
        parsed.year,
        parsed.month,
        parsed.day,
        parsed.hour,
        parsed.minute,
        parsed.second,
      );
    }
    return parsed.toLocal();
  }

  DateTime? get start => date('start');
  DateTime? get end => date('end');
  DateTime? get due => date('due');
  DateTime? get when => due ?? start;
  String get rrule => data['rrule'] as String? ?? (yearly ? 'FREQ=YEARLY' : '');
  String get timezone => data['timezone'] as String? ?? 'UTC';
  String? get recurrenceId => data['recurrence_id'] as String?;
  bool get recurring =>
      rrule.isNotEmpty || (data['rdates'] as List? ?? []).isNotEmpty;
  Entry get series =>
      data['series'] is Map
          ? Entry(Map<String, dynamic>.from(data['series'] as Map))
          : this;
  bool occursOn(DateTime date) {
    final first = when;
    if (first == null) return false;
    final last = kind == 'todo' ? first : end ?? first;
    final d = day(date), s = day(first);
    final lastDay = day(last.subtract(const Duration(microseconds: 1)));
    return d == s || (!d.isBefore(s) && !d.isAfter(lastDay));
  }

  bool get overdue =>
      kind == 'todo' &&
      !completed &&
      due != null &&
      (allDay
          ? day(due!).isBefore(day(DateTime.now()))
          : due!.isBefore(DateTime.now()));
}

class ApiException implements Exception {
  final String message;
  final int status;
  ApiException(this.message, [this.status = 0]);
  @override
  String toString() => message;
}

class Api {
  final http.Client client;
  String? token;
  Api({http.Client? client}) : client = client ?? http.Client();
  static const configuredBase = String.fromEnvironment('API_BASE');
  String get base =>
      configuredBase.isNotEmpty
          ? configuredBase
          : (kIsWeb ? Uri.base.origin : 'http://localhost:8080');
  Future<dynamic> request(
    String method,
    String path, [
    Map<String, dynamic>? body,
    Map<String, String>? extraHeaders,
  ]) async {
    final req = http.Request(method, Uri.parse('$base$path'));
    req.headers.addAll({
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
      ...?extraHeaders,
    });
    if (body != null) req.body = jsonEncode(body);
    http.Response res;
    try {
      res = await http.Response.fromStream(
        await client.send(req).timeout(const Duration(seconds: 15)),
      );
    } catch (_) {
      throw ApiException(
        'Cannot reach Spacetime. Check your connection and try again.',
      );
    }
    final decoded = res.body.isEmpty ? null : jsonDecode(res.body);
    if (res.statusCode >= 400) {
      throw ApiException(
        decoded is Map
            ? decoded['error'] as String? ?? 'Request failed.'
            : 'Request failed.',
        res.statusCode,
      );
    }
    return decoded;
  }
}

class CalendarState extends ChangeNotifier {
  final Api api;
  Map<String, dynamic>? user;
  List<Entry> entries = [], invitations = [], occurrences = [];
  DateTime viewMonth = DateTime(DateTime.now().year, DateTime.now().month);
  DateTime? rangeStart, rangeEnd;
  String defaultView = 'Month';
  int weekStartsOn = 0;
  bool use24Hour = true;
  String get preferenceKey => 'spacetime.preferences.$username';
  void loadPreferences() {
    defaultView = 'Month';
    weekStartsOn = 0;
    use24Hour = true;
    try {
      final raw = readPreference(preferenceKey);
      if (raw == null) return;
      final values = jsonDecode(raw) as Map;
      if ([
        'Agenda',
        'Weekly',
        'Month',
        'Yearly',
      ].contains(values['default_view'])) {
        defaultView = values['default_view'] as String;
      }
      if ([0, 1].contains(values['week_starts_on'])) {
        weekStartsOn = values['week_starts_on'] as int;
      }
      if (values['use_24_hour'] is bool) {
        use24Hour = values['use_24_hour'] as bool;
      }
    } catch (_) {
      /* Keep defaults if browser storage is unavailable or invalid. */
    }
  }

  void savePreferences({
    String? defaultView,
    int? weekStartsOn,
    bool? use24Hour,
  }) {
    final nextView = defaultView ?? this.defaultView;
    final nextWeek = weekStartsOn ?? this.weekStartsOn;
    final nextClock = use24Hour ?? this.use24Hour;
    if (!['Agenda', 'Weekly', 'Month', 'Yearly'].contains(nextView) ||
        ![0, 1].contains(nextWeek)) {
      throw ApiException('Invalid calendar preferences.');
    }
    try {
      writePreference(
        preferenceKey,
        jsonEncode({
          'default_view': nextView,
          'week_starts_on': nextWeek,
          'use_24_hour': nextClock,
        }),
      );
    } catch (_) {
      throw ApiException(
        'Could not save settings. Browser storage is unavailable.',
      );
    }
    this.defaultView = nextView;
    this.weekStartsOn = nextWeek;
    this.use24Hour = nextClock;
    notifyListeners();
  }

  bool occurrencesLoaded = false;
  final String timezone = deviceTimeZone();
  List<Entry> get calendarEntries => occurrencesLoaded ? occurrences : entries;
  List<Entry> get todos => [
    ...entries.where((e) => e.kind == 'todo' && !e.recurring),
    ...calendarEntries.where((e) => e.kind == 'todo' && e.recurring),
  ];
  Future<void> setMonth(DateTime date) async {
    viewMonth = DateTime(date.year, date.month);
    rangeStart = rangeEnd = null;
    await refresh();
  }

  Future<void> setRange(DateTime start, DateTime end) async {
    rangeStart = start;
    rangeEnd = end;
    await refresh();
  }

  String get occurrencesPath {
    final first = rangeStart ?? DateTime(viewMonth.year, viewMonth.month, -6);
    final last = rangeEnd ?? DateTime(viewMonth.year, viewMonth.month + 1, 8);
    var from = DateTime(first.year, first.month, first.day).toUtc();
    var to = DateTime(last.year, last.month, last.day).toUtc();
    // A whole civil day can be skipped by a zone change (Apia, 2011-12-30).
    // Fetch the surrounding instants; the calendar still selects the civil date.
    if (!to.isAfter(from)) {
      from = from.subtract(const Duration(days: 1));
      to = to.add(const Duration(days: 1));
    }
    return '/api/occurrences?from=${Uri.encodeQueryComponent(from.toIso8601String())}&to=${Uri.encodeQueryComponent(to.toIso8601String())}&timezone=${Uri.encodeQueryComponent(timezone)}';
  }

  bool loading = false;
  String? error;
  CalendarState(this.api);
  String get username => user?['username'] as String? ?? '';
  String get name => user?['name'] as String? ?? '';
  Future<void> restore() async {
    try {
      user = Map<String, dynamic>.from(
        await api.request('GET', '/api/me') as Map,
      );
      loadPreferences();
      await refresh();
    } on ApiException catch (e) {
      if (e.status != 401) rethrow;
    }
    notifyListeners();
  }

  Future<void> signIn(String username, String password, {String? name}) async {
    final result = await api.request(
      'POST',
      name == null ? '/api/login' : '/api/register',
      {
        'username': username,
        'password': password,
        if (name != null) 'name': name,
      },
    );
    api.token = result['token'] as String;
    user = Map<String, dynamic>.from(result['user'] as Map);
    loadPreferences();
    await refresh();
  }

  int refreshGeneration = 0;
  Future<void> refresh() async {
    final generation = ++refreshGeneration;
    error = null;
    loading = true;
    notifyListeners();
    try {
      final values = await Future.wait([
        api.request('GET', '/api/events'),
        api.request('GET', '/api/invitations'),
        api.request('GET', occurrencesPath),
      ]);
      if (generation != refreshGeneration) return;
      entries =
          (values[0] as List)
              .map((v) => Entry(Map<String, dynamic>.from(v as Map)))
              .toList();
      invitations =
          (values[1] as List)
              .map((v) => Entry(Map<String, dynamic>.from(v as Map)))
              .toList();
      occurrences =
          (values[2] as List)
              .map((v) => Entry(Map<String, dynamic>.from(v as Map)))
              .toList();
      occurrencesLoaded = true;
    } catch (e) {
      if (generation == refreshGeneration) {
        error = e.toString();
      }
      rethrow;
    } finally {
      if (generation == refreshGeneration) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> save(Map<String, dynamic> data, {String? id}) async {
    await api.request(
      id == null ? 'POST' : 'PUT',
      '/api/events${id == null ? '' : '/$id'}',
      data,
    );
    await refresh();
  }

  Future<void> remove(Entry entry) async {
    await api.request('DELETE', '/api/events/${entry.id}', null, {
      'If-Match': '"${entry.version}"',
    });
    await refresh();
  }

  Future<void> respond(Entry entry, String status) async {
    await api.request('POST', '/api/events/${entry.id}/respond', {
      'status': status,
    });
    await refresh();
  }

  Future<void> occurrenceAction(
    Entry entry,
    String operation, {
    bool? completed,
  }) async {
    await api.request('POST', '/api/events/${entry.id}/exceptions', {
      'recurrence_id': entry.recurrenceId,
      'operation': operation,
      'version': entry.version,
      if (completed != null) 'completed': completed,
    });
    await refresh();
  }

  Future<void> complete(Entry entry, bool done) async {
    if (entry.recurring && entry.recurrenceId != null) {
      await occurrenceAction(entry, 'complete', completed: done);
    } else {
      await api.request('POST', '/api/events/${entry.id}/completion', {
        'completed': done,
        'version': entry.version,
      });
      await refresh();
    }
  }

  Future<void> signOut() async {
    await api.request('POST', '/api/logout');
    refreshGeneration++;
    api.token = null;
    user = null;
    entries = [];
    invitations = [];
    occurrences = [];
    occurrencesLoaded = false;
    rangeStart = rangeEnd = null;
    viewMonth = DateTime(DateTime.now().year, DateTime.now().month);
    notifyListeners();
  }
}
