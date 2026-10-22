import 'dart:convert';
import 'dart:math';
import 'calendar_storage.dart';
import 'local_recurrence.dart';
import 'local_icalendar.dart';
import 'time_zone.dart';
import 'preference_storage.dart';
import 'native_platform.dart';
import 'browser_account.dart';
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
  String get owner => data['owner'] as String? ?? 'local';
  bool get allDay => data['all_day'] == true;
  bool get yearly => data['yearly'] == true;
  bool get completed => data['completed'] == true;
  bool get imported => data['imported'] == true;
  int get version => data['version'] as int? ?? 0;
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

String normalizeServerAddress(String input) {
  final uri = Uri.tryParse(input.trim());
  if (uri == null ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/')) {
    throw ApiException(
      'Enter a server address such as https://calendar.example.com.',
    );
  }
  final local = [
    'localhost',
    '127.0.0.1',
    '10.0.2.2',
    '::1',
  ].contains(uri.host);
  if (uri.scheme != 'https' && !(uri.scheme == 'http' && local)) {
    throw ApiException(
      'Use HTTPS for your server. HTTP is available only for local development.',
    );
  }
  return uri.replace(path: '').toString();
}

class Api {
  final http.Client client;
  String? token;
  Api({http.Client? client}) : client = client ?? http.Client();
  static const configuredBase = String.fromEnvironment('API_BASE');
  String get base =>
      configuredBase.isNotEmpty
          ? configuredBase
          : kIsWeb
          ? Uri.base.origin
          : (readPreference('spacetime.server') ?? '');
  Future<dynamic> request(
    String method,
    String path, [
    Map<String, dynamic>? body,
    Map<String, String>? extraHeaders,
  ]) async {
    if (base.isEmpty) {
      throw ApiException('Enter your Spacetime server address.');
    }
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
  final CalendarStorage storage;
  final BrowserAccount browserAccount;
  String? loginError;
  bool _checkingGravitas = false;
  Map<String, dynamic>? user;
  List<Entry> entries = [], invitations = [], occurrences = [];
  List<Map<String, dynamic>> tombstones = [];
  DateTime viewMonth = DateTime(DateTime.now().year, DateTime.now().month);
  DateTime? rangeStart, rangeEnd;
  String defaultView = 'Month';
  int weekStartsOn = 0;
  bool use24Hour = true, notificationsEnabled = false, showInvites = true;
  List<Entry> invitationOccurrences = [];
  String? reminderError;
  String? lastSync;
  bool loading = false, occurrencesLoaded = false;
  String? error;
  int refreshGeneration = 0;
  int localChangeGeneration = 0;
  final String timezone = deviceTimeZone();
  Future<void> _writes = Future.value();
  CalendarState(
    this.api, {
    CalendarStorage? storage,
    this.browserAccount = const BrowserAccount(),
  }) : storage = storage ?? DeviceCalendarStorage() {
    initializeCalendarZones();
  }
  String get username => user?['username'] as String? ?? 'local';
  String get name => user?['name'] as String? ?? 'On this device';
  bool get connected => user != null;
  bool get usesGravitas => browserAccount.enabled;
  String get account => '${api.base}#$username';
  String get preferenceKey => 'spacetime.preferences.device';
  bool canEdit(Entry entry) =>
      entry.owner == 'local' ||
      entry.data['_editable'] == true ||
      entry.owner == username;
  int get pendingChanges =>
      entries.where((e) => e.data['_dirty'] == true).length +
      tombstones.length +
      invitations.where((e) => e.data['_response'] != null).length;
  bool isInvite(Entry e) =>
      e.data['_invitation'] == true ||
      e.data['_editable'] == false ||
      (e.owner != 'local' &&
          e.owner != username &&
          e.data['_editable'] != true);
  List<Entry> get currentInvitations =>
      invitations
          .where(
            (e) => e.data['_account'] == null || e.data['_account'] == account,
          )
          .toList();
  List<Entry> get pendingCalendarInvites =>
      currentInvitations
          .where(
            (e) =>
                e.data['_response'] != 'declined' &&
                !entries.any(
                  (saved) =>
                      (saved.data['_remote_id'] ?? saved.id) == e.id &&
                      (saved.data['_account'] == null ||
                          saved.data['_account'] == e.data['_account']),
                ),
          )
          .toList();
  List<Entry> get calendarEntries => [
    ...(occurrencesLoaded ? occurrences : entries).where(
      (e) => showInvites || !isInvite(e),
    ),
    if (showInvites)
      ...(occurrencesLoaded ? invitationOccurrences : pendingCalendarInvites),
  ];
  List<Entry> get todos => [
    ...entries.where((e) => e.kind == 'todo' && !e.recurring),
    ...(occurrencesLoaded ? occurrences : entries).where(
      (e) => e.kind == 'todo' && e.recurring,
    ),
  ];

  void loadPreferences() {
    try {
      final raw = readPreference(preferenceKey);
      if (raw == null) return;
      final values = jsonDecode(raw) as Map;
      if (values['default_view'] == 'Agenda') values['default_view'] = 'Daily';
      if ([
        'Daily',
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
      notificationsEnabled = values['notifications'] == true;
      showInvites = values['show_invites'] != false;
    } catch (_) {
      /* Invalid preferences never discard the event database. */
    }
  }

  Future<void> savePreferences({
    String? defaultView,
    int? weekStartsOn,
    bool? use24Hour,
    bool? notifications,
    bool? showInvites,
  }) async {
    final nextView = defaultView ?? this.defaultView;
    final nextWeek = weekStartsOn ?? this.weekStartsOn;
    if (!['Daily', 'Weekly', 'Month', 'Yearly'].contains(nextView) ||
        ![0, 1].contains(nextWeek)) {
      throw ApiException('Invalid calendar preferences.');
    }
    var enabled = notifications ?? notificationsEnabled;
    if (notifications == true && nativePlatformReady) {
      enabled =
          await nativeChannel.invokeMethod<bool>('requestNotifications') ??
          false;
      if (!enabled) {
        throw ApiException(
          'Allow Spacetime notifications in Android Settings to enable reminders.',
        );
      }
    }
    await writePreference(
      preferenceKey,
      jsonEncode({
        'default_view': nextView,
        'week_starts_on': nextWeek,
        'use_24_hour': use24Hour ?? this.use24Hour,
        'notifications': enabled,
        'show_invites': showInvites ?? this.showInvites,
      }),
    );
    this.defaultView = nextView;
    this.weekStartsOn = nextWeek;
    this.use24Hour = use24Hour ?? this.use24Hour;
    notificationsEnabled = enabled;
    this.showInvites = showInvites ?? this.showInvites;
    await _scheduleReminders();
    notifyListeners();
  }

  Map<String, dynamic> _snapshot() => {
    'schema': 1,
    'entries': entries.map((e) => e.data).toList(),
    'deleted': tombstones,
    'invitations': invitations.map((e) => e.data).toList(),
    'user': user,
    'server': api.base,
    'last_sync': lastSync,
  };
  Future<void> _transaction(void Function() action, {bool syncNeeded = false}) {
    final operation = _writes.then((_) async {
      final previous =
          jsonDecode(jsonEncode(_snapshot())) as Map<String, dynamic>;
      try {
        action();
        await storage.write(jsonEncode(_snapshot()));
      } catch (_) {
        _hydrate(previous);
        rethrow;
      }
      if (syncNeeded) localChangeGeneration++;
      await refresh();
      await _scheduleReminders();
    });
    _writes = operation.catchError((Object _) {});
    return operation;
  }

  void _hydrate(Map<String, dynamic> value) {
    if (value['schema'] != 1) {
      throw ApiException(
        'This calendar database needs a newer version of Spacetime.',
      );
    }
    entries =
        (value['entries'] as List)
            .map((e) => Entry(Map<String, dynamic>.from(e as Map)))
            .toList();
    tombstones =
        (value['deleted'] as List? ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
    invitations =
        (value['invitations'] as List? ?? [])
            .map((e) => Entry(Map<String, dynamic>.from(e as Map)))
            .toList();
    user =
        value['server'] == api.base && value['user'] is Map
            ? Map<String, dynamic>.from(value['user'] as Map)
            : null;
    lastSync = value['last_sync'] as String?;
  }

  Future<void> restore() async {
    loadPreferences();
    final stored = await storage.read();
    if (stored != null) {
      _hydrate(Map<String, dynamic>.from(jsonDecode(stored) as Map));
    }
    if (invitations.any(
      (e) => e.data['calendar_data'] != null && e.data['_timezones'] == null,
    )) {
      // Upgrade cached invitations so native widgets use their complete time
      // zones and detached exceptions without a server connection.
      await _transaction(() {
        invitations =
            invitations.map((e) => Entry(hydrateCalendarData(e.data))).toList();
      });
    }
    if (!kIsWeb && api.base.isNotEmpty) {
      api.token = await readNativeSession(api.base);
    }
    // No connection is attempted on launch or resume, including session checks.
    await refresh();
    await _scheduleReminders();
  }

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

  Future<void> refresh() async {
    final from = rangeStart ?? DateTime(viewMonth.year, viewMonth.month, -6);
    final to = rangeEnd ?? DateTime(viewMonth.year, viewMonth.month + 1, 8);
    occurrences =
        entries
            .expand(
              (e) => expandLocalEvent(
                e.data,
                from,
                to,
                viewTimezone: timezone,
              ).map(Entry.new),
            )
            .toList();
    invitationOccurrences =
        pendingCalendarInvites
            .expand(
              (e) => expandLocalEvent(
                {
                  ...hydrateCalendarData(e.data),
                  '_invitation': true,
                  '_editable': false,
                },
                from,
                to,
                viewTimezone: timezone,
              ).map(Entry.new),
            )
            .toList();
    occurrencesLoaded = true;
    notifyListeners();
  }

  Future<void> configureServer(String address) async {
    final server = normalizeServerAddress(address);
    if (server == api.base) return;
    await writePreference('spacetime.server', server);
    api.token = null;
    user = null;
    invitations =
        invitations.where((e) => e.data['_response'] != null).toList();
    // Device calendars are kept when changing or disconnecting accounts.
    await _transaction(() {});
  }

  Future<bool> initializeGravitas() async {
    if (_checkingGravitas) return false;
    _checkingGravitas = true;
    try {
      return await _initializeGravitas();
    } finally {
      _checkingGravitas = false;
    }
  }

  bool _passiveLoginAllowed() {
    final previous = int.tryParse(
      readPreference('spacetime.gravitas.passive_attempt_at') ?? '',
    );
    if (previous == null) return true;
    final age = DateTime.now().millisecondsSinceEpoch - previous;
    return age < 0 || age >= const Duration(minutes: 2).inMilliseconds;
  }

  Future<void> _passiveLogin() async {
    await writePreference(
      'spacetime.gravitas.passive_attempt_at',
      DateTime.now().millisecondsSinceEpoch.toString(),
    );
    browserAccount.login(silent: true);
  }

  /// Only a confirmed 401 permits passive recovery. The shared cookie exposed
  /// by auth/config is an untrusted navigation hint, never authentication.
  Future<void> recoverGravitasSession({
    required bool Function() isForeground,
  }) async {
    if (!usesGravitas ||
        _checkingGravitas ||
        !isForeground() ||
        readPreference('spacetime.gravitas.disconnected') == '1') {
      return;
    }
    _checkingGravitas = true;
    try {
      final config = await api.request('GET', '/api/auth/config');
      if (!isForeground() || config['gravitas_enabled'] != true) return;
      final hint = config['gravitas_signed_in'] == true;
      if (!connected && !hint) return;
      try {
        final current = Map<String, dynamic>.from(
          await api.request('GET', '/api/me') as Map,
        );
        if (!isForeground()) return;
        if (!connected) await _transaction(() => user = current);
        return;
      } on ApiException catch (e) {
        if (e.status != 401 || !isForeground()) return;
      }
      loginError = 'Your session expired. Log in to continue syncing.';
      await _transaction(() {
        user = null;
        // Unsent responses survive reauthentication just like unsent events.
        invitations =
            invitations.where((e) => e.data['_response'] != null).toList();
      });
      if (hint && isForeground() && _passiveLoginAllowed()) {
        // No interactive consent or modal is opened here. The normal callback
        // handles saved dismissal choices and the state-bound result.
        await writePreference(
          'spacetime.gravitas.passive_attempt_at',
          DateTime.now().millisecondsSinceEpoch.toString(),
        );
        if (isForeground()) browserAccount.login(silent: true);
      }
    } catch (_) {
      // A connection failure keeps the cached account and all offline work.
    } finally {
      _checkingGravitas = false;
    }
  }

  Future<bool> _initializeGravitas() async {
    if (!usesGravitas ||
        readPreference('spacetime.gravitas.disconnected') == '1') {
      return false;
    }
    loginError = null;
    final result = browserAccount.takeResult();
    try {
      final config = await api.request('GET', '/api/auth/config');
      if (config['gravitas_enabled'] != true) return false;
      try {
        final current = await api.request('GET', '/api/me');
        await _transaction(
          () => user = Map<String, dynamic>.from(current as Map),
        );
        return false;
      } on ApiException catch (e) {
        if (e.status != 401) rethrow;
        if (connected) {
          await _transaction(() {
            user = null;
            invitations =
                invitations.where((e) => e.data['_response'] != null).toList();
          });
        }
      }
      if (result == null) {
        if (_passiveLoginAllowed()) await _passiveLogin();
        return false;
      }
      if (result == 'consent_required' &&
          readPreference('spacetime.gravitas.prompt_dismissed') != '1') {
        // An existing base-site session needs only IAM's first-connection consent.
        await loginWithGravitas();
        return false;
      }
      if (![
        'login_required',
        'consent_required',
        'access_denied',
      ].contains(result)) {
        loginError = 'Could not complete Gravitas login. Please try again.';
      }
    } catch (_) {
      // Connection failure never removes the device calendar or a cached account.
      loginError =
          'Gravitas is unavailable. Your calendar still works offline.';
    }
    return !connected &&
        (readPreference('spacetime.gravitas.prompt_dismissed') != '1' ||
            ['connected', 'failed', 'access_denied'].contains(result));
  }

  Future<void> loginWithGravitas() async {
    await writePreference('spacetime.gravitas.disconnected', '0');
    browserAccount.login();
  }

  Future<void> loginLater() =>
      writePreference('spacetime.gravitas.prompt_dismissed', '1');

  Future<void> disconnectGravitas() async {
    await writePreference('spacetime.gravitas.disconnected', '1');
    try {
      await api.request('POST', '/api/logout');
    } catch (_) {
      /* Local disconnect works offline. */
    }
    await signOut();
  }

  Future<void> signIn(
    String username,
    String password, {
    String? name,
    String? inviteKey,
  }) async {
    final result = await api
        .request('POST', name == null ? '/api/login' : '/api/register', {
          'username': username,
          'password': password,
          if (name != null) 'name': name,
          if (name != null) 'invite_key': inviteKey ?? '',
        });
    api.token = result['token'] as String;
    if (!kIsWeb) await writeNativeSession(api.base, api.token);
    await _transaction(() {
      user = Map<String, dynamic>.from(result['user'] as Map);
    });
    // The foreground coordinator syncs the connected account automatically.
  }

  String _id() =>
      List.generate(
        24,
        (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
  Future<void> save(Map<String, dynamic> data, {String? id}) =>
      _transaction(() {
        final index = entries.indexWhere((e) => e.id == id);
        final old = index >= 0 ? entries[index] : null;
        if (old != null && !canEdit(old)) {
          throw ApiException('Only the organizer can edit this entry.');
        }
        final identifier = old?.id ?? _id();
        final normalized = normalizeLocalEvent({
          ...?old?.data, ...data,
          'id': identifier,
          'uid': old?.data['uid'] ?? '$identifier@spacetime.local',
          'owner': old?.owner ?? 'local', 'version': (old?.version ?? 0) + 1,
          '_editable': true, '_dirty': true,
          '_pending_exceptions':
              old?.data['_pending_exceptions'] ?? <String, dynamic>{},
          // Reminders are preferences on this device, never sent to the server.
          'reminder_minutes': data['reminder_minutes'],
        });
        if (old != null &&
            (old.data['_overrides'] as Map? ?? {}).isNotEmpty &&
            ((old.kind == 'todo') != (normalized['kind'] == 'todo') ||
                old.allDay != (normalized['all_day'] == true))) {
          throw ApiException(
            'Resolve individual exceptions before changing this series type.',
          );
        }
        if (old != null &&
            (data['end_local'] != old.data['end_local'] ||
                data['due_local'] != old.data['due_local'])) {
          normalized.remove('_nominal_duration');
        }
        if (old == null) {
          entries = [...entries, Entry(normalized)];
        } else {
          entries = [...entries]..[index] = Entry(normalized);
        }
      }, syncNeeded: true);
  Future<void> remove(Entry entry) => _transaction(() {
    final master = entries.firstWhere((e) => e.id == entry.id);
    if (!canEdit(master)) {
      throw ApiException('Only the organizer can delete this entry.');
    }
    if (master.data['_remote_id'] != null) {
      tombstones = [...tombstones, master.data];
    }
    entries = entries.where((e) => e.id != entry.id).toList();
  }, syncNeeded: true);
  Future<void> occurrenceAction(
    Entry entry,
    String operation, {
    bool? completed,
  }) => _transaction(() {
    final index = entries.indexWhere((e) => e.id == entry.id);
    final master = entries[index];
    if (!canEdit(master)) {
      throw ApiException('Only the organizer can edit this occurrence.');
    }
    if (entry.recurrenceId == null) {
      throw ApiException('Missing recurrence identifier.');
    }
    final exceptions = Map<String, dynamic>.from(
      master.data['_exceptions'] as Map? ?? {},
    );
    exceptions[entry.recurrenceId!] = {
      'operation': operation,
      if (completed != null) 'completed': completed,
    };
    final pending = Map<String, dynamic>.from(
      master.data['_pending_exceptions'] as Map? ?? {},
    );
    pending[entry.recurrenceId!] = exceptions[entry.recurrenceId!];
    entries = [...entries]
      ..[index] = Entry({
        ...master.data,
        '_exceptions': exceptions,
        '_pending_exceptions': pending,
        '_dirty': true,
        'version': master.version + 1,
      });
  }, syncNeeded: true);
  Future<void> complete(Entry entry, bool done) async {
    if (entry.recurring && entry.recurrenceId != null) {
      await occurrenceAction(entry, 'complete', completed: done);
    } else {
      await save({...entry.series.data, 'completed': done}, id: entry.id);
    }
  }

  Future<void> respond(Entry entry, String status) async {
    if (!connected) throw ApiException('Sign in to respond to invitations.');
    // Responses are durable offline changes, queued for foreground autosync.
    await _transaction(() {
      invitations =
          invitations
              .map(
                (e) =>
                    e.id == entry.id &&
                            (e.data['_account'] == null ||
                                e.data['_account'] == account)
                        ? Entry({...e.data, '_response': status})
                        : e,
              )
              .toList();
    }, syncNeeded: true);
  }

  Future<void> _scheduleReminders() async {
    if (!nativePlatformReady) return;
    try {
      await nativeChannel.invokeMethod<void>('scheduleReminders', {
        'enabled': notificationsEnabled,
        'events':
            entries
                .where(
                  (e) => !e.completed && e.data['reminder_minutes'] != null,
                )
                .map((e) => e.data)
                .toList(),
      });
      reminderError = null;
    } catch (_) {
      reminderError =
          'Your entries are saved. Android could not schedule reminders; check notification permissions.';
      notifyListeners();
    }
  }

  List<Map<String, dynamic>> preview(Map<String, dynamic> data) {
    final normalized = normalizeLocalEvent(data);
    final first = parseWall(
      (normalized['start_local'] ?? normalized['due_local']) as String,
    );
    final interval =
        int.tryParse(
          ruleParts(normalized['rrule'] as String)['INTERVAL'] ?? '',
        ) ??
        1;
    final frequency = ruleParts(normalized['rrule'] as String)['FREQ'];
    final years =
        frequency == 'YEARLY'
            ? interval * 10
            : frequency == 'MONTHLY'
            ? (interval * 10 / 12).ceil() + 1
            : 2;
    return expandLocalEvent(
      normalized,
      first.subtract(const Duration(days: 2)),
      DateTime.utc((first.year + years).clamp(1, 9999), first.month, first.day),
      limit: 8,
    );
  }

  Map<String, dynamic> _wire(Entry e) => {
    for (final field in [
      'id',
      'uid',
      'title',
      'description',
      'location',
      'kind',
      'all_day',
      'timezone',
      'rrule',
      'until_date',
      'rdates',
      'exdates',
      'completed',
      'attendees',
      'start',
      'end',
      'due',
      'start_local',
      'end_local',
      'due_local',
    ])
      if (e.data.containsKey(field)) field: e.data[field],
    'version': e.data['_remote_version'] ?? 0,
  };
  List<Entry> get conflicts => [
    ...entries.where((e) => e.data.containsKey('_conflict')),
    ...tombstones.where((e) => e.containsKey('_conflict')).map(Entry.new),
  ];
  Future<void> resolveConflict(Entry entry, {required bool keepDevice}) =>
      _transaction(() {
        final index = entries.indexWhere((e) => e.id == entry.id);
        final deleted = index < 0;
        final current =
            deleted
                ? Entry(tombstones.firstWhere((e) => e['id'] == entry.id))
                : entries[index];
        final remote = current.data['_conflict'] as Map?;
        final data = Map<String, dynamic>.from(
          keepDevice || remote == null
              ? current.data
              : hydrateCalendarData(Map<String, dynamic>.from(remote)),
        );
        data['id'] = current.id;
        data['_account'] = current.data['_account'];
        data['_editable'] = true;
        data['reminder_minutes'] = current.data['reminder_minutes'];
        data.remove('_conflict');
        if (remote == null) {
          data.remove('_remote_id');
          data.remove('_remote_version');
        } else {
          data['_remote_id'] = remote['id'];
          data['_remote_version'] = remote['version'];
        }
        data['_dirty'] = keepDevice;
        data['version'] = current.version + 1;
        if (deleted) {
          tombstones = tombstones.where((e) => e['id'] != current.id).toList();
          if (keepDevice && remote != null) tombstones.add(data);
          if (!keepDevice && remote != null) {
            entries = [...entries, Entry(data)];
          }
        } else if (!keepDevice && remote == null) {
          entries = entries.where((e) => e.id != current.id).toList();
        } else {
          entries = [...entries]..[index] = Entry(data);
        }
        error = null;
      }, syncNeeded: true);
  Future<void> _conflict(Entry entry, Map<String, dynamic>? remote) =>
      _transaction(() {
        entries =
            entries
                .map(
                  (e) =>
                      e.id == entry.id
                          ? Entry({...e.data, '_conflict': remote})
                          : e,
                )
                .toList();
        tombstones =
            tombstones
                .map(
                  (e) => e['id'] == entry.id ? {...e, '_conflict': remote} : e,
                )
                .toList();
      });
  Future<void> _bind(
    Entry sent,
    String binding,
    Map<String, dynamic> remote,
    int revision, {
    bool finished = false,
    String? exceptionId,
    dynamic exception,
  }) => _transaction(() {
    final index = entries.indexWhere((e) => e.id == sent.id);
    if (index < 0) {
      final deleted =
          tombstones.where((e) => e['id'] == sent.id).firstOrNull ?? sent.data;
      tombstones =
          tombstones.where((e) => e['id'] != sent.id).toList()..add({
            ...deleted,
            '_account': binding,
            '_remote_id': remote['id'],
            '_remote_version': revision,
          });
      return;
    }
    final current = entries[index];
    final pending = Map<String, dynamic>.from(
      current.data['_pending_exceptions'] as Map? ?? {},
    );
    if (exceptionId != null &&
        jsonEncode(pending[exceptionId]) == jsonEncode(exception)) {
      pending.remove(exceptionId);
    }
    entries = [...entries]
      ..[index] = Entry({
        ...current.data,
        'owner': username,
        '_account': binding,
        '_remote_id': remote['id'],
        '_remote_version': revision,
        '_pending_exceptions': pending,
        '_dirty':
            !finished || current.version != sent.version || pending.isNotEmpty,
      });
  });
  Future<void> sync() async {
    if (loading) return;
    if (!connected) {
      throw ApiException(
        'Sign in in Settings to sync. Your device calendar works offline.',
      );
    }
    loading = true;
    error = null;
    notifyListeners();
    final binding = account;
    try {
      // Confirm the identity before attaching any unbound device events.
      final identity = Map<String, dynamic>.from(
        await api.request('GET', '/api/me') as Map,
      );
      if (identity['username'] != username) {
        throw ApiException(
          'The server session belongs to another account. Sign in again.',
        );
      }
      var remote =
          (await api.request('GET', '/api/events') as List)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
      for (final deleted in [
        ...tombstones,
      ].where((e) => e['_account'] == binding)) {
        final existing =
            remote.where((e) => e['id'] == deleted['_remote_id']).firstOrNull;
        if (existing != null &&
            existing['version'] != deleted['_remote_version']) {
          await _conflict(Entry(deleted), existing);
          throw ApiException(
            '“${deleted['title']}” changed before your deletion synced. Resolve it in Settings.',
          );
        }
        try {
          await api.request(
            'DELETE',
            '/api/events/${deleted['_remote_id']}',
            null,
            {'If-Match': '"${deleted['_remote_version']}"'},
          );
        } on ApiException catch (e) {
          if (e.status != 404) rethrow;
        }
        await _transaction(() {
          tombstones =
              tombstones.where((e) => e['id'] != deleted['id']).toList();
        });
        remote.removeWhere((e) => e['id'] == deleted['_remote_id']);
      }
      for (final entry in [...entries].where(
        (e) =>
            e.data['_dirty'] == true &&
            (e.data['_account'] == null || e.data['_account'] == binding),
      )) {
        final existing =
            remote
                .where(
                  (e) =>
                      e['id'] == entry.data['_remote_id'] ||
                      e['uid'] == entry.data['uid'],
                )
                .firstOrNull;
        final remoteId =
            existing?['id'] as String? ?? entry.data['_remote_id'] as String?;
        final expected = entry.data['_remote_version'] as int?;
        if (remoteId != null && existing == null) {
          await _conflict(entry, null);
          throw ApiException(
            '“${entry.title}” was removed on the server. Your device copy is kept; resolve it in Settings.',
          );
        }
        if (expected != null && existing?['version'] != expected) {
          await _conflict(entry, existing);
          throw ApiException(
            '“${entry.title}” changed on another device. Your edits are kept. Resolve the conflict in Settings.',
          );
        }
        final sent = Map<String, dynamic>.from(
          await api.request(
                remoteId == null ? 'POST' : 'PUT',
                '/api/events${remoteId == null ? '' : '/$remoteId'}',
                {..._wire(entry), 'version': existing?['version'] ?? 0},
              )
              as Map,
        );
        var remoteVersion = sent['version'] as int;
        await _bind(entry, binding, sent, remoteVersion);
        final exceptions = Map<String, dynamic>.from(
          entry.data['_pending_exceptions'] as Map? ?? {},
        );
        for (final exception in exceptions.entries) {
          final updated = await api
              .request('POST', '/api/events/${sent['id']}/exceptions', {
                ...Map<String, dynamic>.from(exception.value as Map),
                'recurrence_id': exception.key,
                'version': remoteVersion,
              });
          if (updated is Map && updated['version'] is int) {
            remoteVersion = updated['version'] as int;
          } else {
            remoteVersion++;
          }
          await _bind(
            entry,
            binding,
            sent,
            remoteVersion,
            exceptionId: exception.key,
            exception: exception.value,
          );
        }
        await _bind(entry, binding, sent, remoteVersion, finished: true);
      }
      final sentResponses = <String, String>{};
      for (final invite in [...invitations].where(
        (e) => e.data['_response'] != null && e.data['_account'] == binding,
      )) {
        await api.request('POST', '/api/events/${invite.id}/respond', {
          'status': invite.data['_response'],
        });
        sentResponses[invite.id] = invite.data['_response'] as String;
      }
      final values = await Future.wait([
        api.request('GET', '/api/events'),
        api.request('GET', '/api/invitations'),
      ]);
      final downloaded =
          (values[0] as List)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
      await _transaction(() {
        final next = [...entries];
        for (final raw in downloaded) {
          final item = hydrateCalendarData(raw);
          if (tombstones.any(
            (e) => e['_account'] == binding && e['_remote_id'] == item['id'],
          )) {
            continue;
          }
          final index = next.indexWhere(
            (e) =>
                e.data['_account'] == binding &&
                e.data['_remote_id'] == item['id'],
          );
          final old = index < 0 ? null : next[index];
          if (old?.data['_dirty'] == true) continue;
          final data = {
            ...item,
            'id': old?.id ?? _id(),
            '_account': binding,
            '_remote_id': item['id'],
            '_remote_version': item['version'],
            '_dirty': false,
            '_editable': item['owner'] == username,
            if (old != null) 'reminder_minutes': old.data['reminder_minutes'],
            '_pending_exceptions': <String, dynamic>{},
          };
          if (index < 0) {
            next.add(Entry(data));
          } else {
            next[index] = Entry(data);
          }
        }
        entries =
            next
                .where(
                  (e) =>
                      e.data['_account'] != binding ||
                      e.data['_dirty'] == true ||
                      downloaded.any((d) => d['id'] == e.data['_remote_id']),
                )
                .toList();
        // A response can be changed while requests are in flight. Preserve
        // anything not sent with its current value, even if the server no longer
        // lists the invitation after an earlier accept/decline.
        final otherPendingResponses =
            invitations
                .where(
                  (e) =>
                      e.data['_account'] != binding &&
                      e.data['_response'] != null,
                )
                .toList();
        final pendingResponses = {
          for (final invite in invitations.where(
            (e) =>
                e.data['_account'] == binding &&
                e.data['_response'] != null &&
                e.data['_response'] != sentResponses[e.id],
          ))
            invite.id: invite,
        };
        final downloadedInvites =
            (values[1] as List)
                .map(
                  (e) => Entry({
                    ...hydrateCalendarData(Map<String, dynamic>.from(e as Map)),
                    '_account': binding,
                  }),
                )
                .toList();
        invitations = [
          for (final invite in downloadedInvites)
            pendingResponses.remove(invite.id) ?? invite,
          ...pendingResponses.values,
          ...otherPendingResponses,
        ];
        lastSync = DateTime.now().toIso8601String();
      });
    } catch (e) {
      error = e.toString();
      notifyListeners();
      rethrow;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> signOut() async {
    // Disconnect is entirely local and always works without a connection.
    if (!kIsWeb && api.base.isNotEmpty) {
      await writeNativeSession(api.base, null);
    }
    api.token = null;
    await _transaction(() {
      user = null;
      invitations =
          invitations.where((e) => e.data['_response'] != null).toList();
    });
  }
}
