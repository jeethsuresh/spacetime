import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';
import 'package:intl/intl.dart';
import 'models.dart';
import 'editor.dart';
import 'native_platform.dart';
import 'time_grid.dart';
import 'foreground_sync.dart';
import 'calendar_panel.dart';
import 'invitation_panel.dart';
import 'month_pager.dart';

const forest = Color(0xFF244F3F);
const ink = Color(0xFF263C34);
const muted = Color(0xFF788279);
const paper = Color(0xFFF7F8F3);
const line = Color(0xFFE6EAE1);
const kindColors = {
  'event': Color(0xFF587F65),
  'todo': Color(0xFFB78C3C),
  'occasion': Color(0xFFB67888),
};
const kindIcons = {
  'event': Icons.event_outlined,
  'todo': Icons.check_circle_outline,
  'occasion': Icons.celebration_outlined,
};

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeNativePlatform();
  SemanticsBinding.instance.ensureSemantics();
  runApp(const SpacetimeApp());
}

ThemeData appTheme() => ThemeData(
  useMaterial3: true,
  visualDensity: VisualDensity.compact,
  colorScheme: ColorScheme.fromSeed(
    seedColor: forest,
    surface: Colors.white,
    primary: forest,
  ),
  scaffoldBackgroundColor: paper,
  fontFamily: 'Spacetime',
  textTheme: const TextTheme(
    bodyMedium: TextStyle(color: ink, fontSize: 14),
    bodySmall: TextStyle(color: muted, fontSize: 12),
  ),
  dividerColor: line,
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: paper,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: line),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: line),
    ),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      backgroundColor: forest,
      foregroundColor: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(
      foregroundColor: ink,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      side: const BorderSide(color: line),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
  ),
);

class SpacetimeApp extends StatefulWidget {
  final CalendarState? state;
  const SpacetimeApp({super.key, this.state});
  @override
  State<SpacetimeApp> createState() => _SpacetimeAppState();
}

class _SpacetimeAppState extends State<SpacetimeApp>
    with WidgetsBindingObserver {
  late final CalendarState state = widget.state ?? CalendarState(Api());
  late final ForegroundSync foregroundSync;
  Timer? sessionTimer;
  bool restoring = true;
  String? error;
  @override
  void initState() {
    super.initState();
    foregroundSync = ForegroundSync(
      state,
      onUnauthorized:
          () => state.recoverGravitasSession(isForeground: () => foreground),
    );
    WidgetsBinding.instance.addObserver(this);
    nativeLoginResult.addListener(receiveNativeLogin);
    restore();
  }

  void receiveNativeLogin() {
    if (!restoring && nativeLoginResult.value != null) {
      unawaited(state.completeNativeLogin());
    }
  }

  Future<void> restore() async {
    try {
      if (widget.state == null) await state.restore();
    } catch (e) {
      error = e.toString();
      state.error = error;
    }
    if (mounted) {
      setState(() => restoring = false);
      foregroundSync.setForeground(
        WidgetsBinding.instance.lifecycleState == null ||
            WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
      );
      updateSessionChecks();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    foregroundSync.setForeground(foreground);
    updateSessionChecks();
    if (foreground) {
      unawaited(state.recoverGravitasSession(isForeground: () => foreground));
    }
  }

  void updateSessionChecks() {
    sessionTimer?.cancel();
    sessionTimer =
        foreground
            ? Timer.periodic(const Duration(seconds: 15), (_) {
              if (foreground && state.connected && state.usesGravitas) {
                unawaited(
                  state.recoverGravitasSession(isForeground: () => foreground),
                );
              }
            })
            : null;
  }

  bool get foreground =>
      mounted &&
      !restoring &&
      (WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    nativeLoginResult.removeListener(receiveNativeLogin);
    foregroundSync.dispose();
    sessionTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Spacetime',
    debugShowCheckedModeBanner: false,
    theme: appTheme(),
    home: ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        if (restoring) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return HomePage(state: state);
      },
    ),
  );
}

class Brand extends StatelessWidget {
  final bool light;
  const Brand({super.key, this.light = false});
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: light ? Colors.white.withValues(alpha: .15) : forest,
          borderRadius: BorderRadius.circular(11),
        ),
        child: const Icon(
          Icons.calendar_month_rounded,
          color: Colors.white,
          size: 21,
        ),
      ),
      const SizedBox(width: 11),
      Text(
        'spacetime',
        style: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w700,
          letterSpacing: -1,
          color: light ? Colors.white : forest,
        ),
      ),
    ],
  );
}

class AuthPage extends StatefulWidget {
  final CalendarState state;
  final String? initialError;
  final bool customServer;
  const AuthPage({
    super.key,
    required this.state,
    this.initialError,
    this.customServer = false,
  });
  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final username = TextEditingController(),
      password = TextEditingController(),
      name = TextEditingController(),
      inviteKey = TextEditingController();
  late final server = TextEditingController(text: widget.state.api.base);
  bool register = false, busy = false, obscure = true;
  late String? error = widget.initialError;
  @override
  void dispose() {
    username.dispose();
    password.dispose();
    name.dispose();
    inviteKey.dispose();
    server.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (!kIsWeb) await widget.state.configureServer(server.text);
      await widget.state.signIn(
        username.text.trim(),
        password.text,
        name: register ? name.text.trim() : null,
        inviteKey: register ? inviteKey.text : null,
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) =>
      widget.state.usesGravitas && !widget.customServer
          ? Scaffold(
            appBar: AppBar(title: const Text('Log in')),
            body: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 380),
                  child: GravitasLogin(state: widget.state),
                ),
              ),
            ),
          )
          : legacyLogin(context);

  Widget legacyLogin(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text("Connect for sync")),
    body: LayoutBuilder(
      builder: (context, box) {
        final form = Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(26),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Brand(),
                    const SizedBox(height: 24),
                    Text(
                      register ? 'Create an account' : 'Sign in',
                      style: const TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -1,
                        color: ink,
                      ),
                    ),
                    const SizedBox(height: 18),
                    if (!kIsWeb) ...[
                      TextField(
                        key: const ValueKey('server-address'),
                        controller: server,
                        enabled: !busy && Api.configuredBase.isEmpty,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          labelText: 'Server address',
                          hintText: 'https://calendar.example.com',
                          prefixIcon: Icon(Icons.dns_outlined, size: 20),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (register) ...[
                      TextField(
                        controller: name,
                        autofillHints: const [AutofillHints.name],
                        decoration: const InputDecoration(
                          labelText: 'Your name',
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    TextField(
                      controller: username,
                      autofillHints: const [AutofillHints.username],
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Username',
                        prefixIcon: Icon(Icons.person_outline, size: 20),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: password,
                      autofillHints: [
                        register
                            ? AutofillHints.newPassword
                            : AutofillHints.password,
                      ],
                      obscureText: obscure,
                      onSubmitted: (_) {
                        if (!busy) submit();
                      },
                      decoration: InputDecoration(
                        labelText: 'Password',
                        helperText: register ? 'At least 10 characters' : null,
                        prefixIcon: const Icon(Icons.lock_outline, size: 20),
                        suffixIcon: IconButton(
                          tooltip: obscure ? 'Show password' : 'Hide password',
                          onPressed: () => setState(() => obscure = !obscure),
                          icon: Icon(
                            obscure
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                            size: 20,
                          ),
                        ),
                      ),
                    ),
                    if (register) ...[
                      const SizedBox(height: 16),
                      TextField(
                        key: const ValueKey('registration-invite-key'),
                        controller: inviteKey,
                        enabled: !busy,
                        autocorrect: false,
                        enableSuggestions: false,
                        obscureText: true,
                        onSubmitted: (_) {
                          if (!busy) submit();
                        },
                        decoration: const InputDecoration(
                          labelText: 'Invite key',
                          prefixIcon: Icon(Icons.key_outlined, size: 20),
                        ),
                      ),
                    ],
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Text(
                          error!,
                          style: const TextStyle(
                            color: Color(0xFFB34343),
                            height: 1.5,
                          ),
                        ),
                      ),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: busy ? null : submit,
                        child: Text(
                          busy
                              ? 'One moment…'
                              : register
                              ? 'Create account'
                              : 'Sign in',
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Center(
                      child: TextButton(
                        onPressed:
                            busy
                                ? null
                                : () => setState(() {
                                  register = !register;
                                  inviteKey.clear();
                                  error = null;
                                }),
                        child: Text(
                          register
                              ? 'Already have an account? Sign in'
                              : 'New here? Create an account',
                        ),
                      ),
                    ),
                    const SizedBox(height: 28),
                    const Divider(),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        const Icon(Icons.spa_outlined, size: 18, color: muted),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'Have a local demo running?',
                            style: TextStyle(color: muted, fontSize: 12),
                          ),
                        ),
                        TextButton(
                          onPressed:
                              () => setState(() {
                                register = false;
                                username.text = 'alex';
                                password.text = 'spacetime-demo-2026';
                              }),
                          child: const Text('Fill demo login'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        return form;
      },
    ),
  );
}

class GravitasUsernameForm extends StatefulWidget {
  const GravitasUsernameForm({super.key, required this.state});
  final CalendarState state;
  @override
  State<GravitasUsernameForm> createState() => _GravitasUsernameFormState();
}

class _GravitasUsernameFormState extends State<GravitasUsernameForm> {
  final username = TextEditingController();
  bool busy = false;
  @override
  void initState() {
    super.initState();
    unawaited(loadDomain());
  }

  Future<void> loadDomain() => widget.state.loadGravitasConfiguration();

  @override
  void dispose() {
    username.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (busy || username.text.trim().isEmpty) return;
    setState(() => busy = true);
    try {
      await widget.state.loginWithGravitas(username: username.text.trim());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: username,
              enabled: !busy,
              autofillHints: const [AutofillHints.username],
              textCapitalization: TextCapitalization.none,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.go,
              onSubmitted: (_) => submit(),
              decoration: InputDecoration(
                labelText: 'Username',
                hintText: 'username@${widget.state.gravitasDefaultDomain}',
              ),
            ),
          ),
          const SizedBox(width: 8),
          Semantics(
            label: 'Sign in',
            button: true,
            child: FilledButton(
              key: const ValueKey('gravitas-login'),
              onPressed: busy ? null : submit,
              child: const Text('🔥'),
            ),
          ),
        ],
      ),
      const SizedBox(height: 6),
      Text(
        'Without a domain, sign in at ${widget.state.gravitasDefaultDomain}.',
        style: const TextStyle(fontSize: 12),
      ),
    ],
  );
}

class GravitasLogin extends StatelessWidget {
  final CalendarState state;
  final VoidCallback? later;
  const GravitasLogin({super.key, required this.state, this.later});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        'Use your account to sync calendars and receive invites.',
      ),
      if (state.loginError != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(
            state.loginError!,
            style: const TextStyle(color: Color(0xFFB34343)),
          ),
        ),
      const SizedBox(height: 16),
      GravitasUsernameForm(state: state),
      const SizedBox(height: 8),
      OutlinedButton(
        key: const ValueKey('gravitas-register'),
        onPressed: state.registerWithGravitas,
        child: Text('Register at ${state.gravitasDefaultDomain}'),
      ),
      if (later != null)
        TextButton(
          key: const ValueKey('gravitas-login-later'),
          onPressed: later,
          child: const Text('Login later from settings'),
        ),
      if (!kIsWeb)
        TextButton(
          onPressed: state.loginWithBrowser,
          child: const Text('Use browser'),
        ),
      if (!kIsWeb)
        TextButton(
          onPressed: () {
            final navigation = Navigator.of(context);
            if (later != null) navigation.pop();
            navigation.push(
              MaterialPageRoute<void>(
                builder: (_) => AuthPage(state: state, customServer: true),
              ),
            );
          },
          child: const Text('Use another server'),
        ),
    ],
    ),
  );
}

class HomePage extends StatefulWidget {
  final CalendarState state;
  const HomePage({super.key, required this.state});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  DateTime selected = day(DateTime.now());
  late DateTime month = DateTime(selected.year, selected.month);
  int page = 0;
  late String view;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    view = state.defaultView;
    final launch = calendarNavigation.value;
    if (launch != null) {
      selected = day(DateTime.parse(launch['date']!));
      month = DateTime(selected.year, selected.month);
      view = launch['view']!;
      calendarNavigation.value = null;
    }
    calendarNavigation.addListener(openWidgetDate);
    if (state.usesGravitas) {
      WidgetsBinding.instance.addPostFrameCallback((_) => connectGravitas());
    }
    if (view != 'Month') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) loadRange();
      });
    }
  }

  Future<void> connectGravitas() async {
    final showLogin = await state.initializeGravitas();
    if (!mounted || !showLogin) return;
    var closing = false;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder:
          (dialogContext) => ListenableBuilder(
            listenable: state,
            builder: (context, _) {
              if (state.connected && !closing) {
                closing = true;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (dialogContext.mounted) Navigator.pop(dialogContext);
                });
              }
              return AlertDialog(
                title: const Text('Log in to Spacetime'),
                content: SizedBox(
                  width: 340,
                  child: SingleChildScrollView(
                    child: GravitasLogin(
                      state: state,
                      later: () async {
                        await state.loginLater();
                        if (dialogContext.mounted) Navigator.pop(dialogContext);
                      },
                    ),
                  ),
                ),
              );
            },
          ),
    );
  }

  void openWidgetDate() {
    final navigation = calendarNavigation.value;
    if (navigation == null || !mounted) return;
    calendarNavigation.value = null;
    setState(() {
      page = 0;
      query = '';
      searchExpanded = false;
      searchController.clear();
    });
    select(DateTime.parse(navigation['date']!), mode: navigation['view']);
  }

  final searchController = TextEditingController();
  bool searchExpanded = false;
  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (lifecycle == AppLifecycleState.resumed) return;
    bottomBarDrag = 0;
    final drawer = calendarDrawerRoute;
    if (drawer != null && drawer.isActive) {
      // Remove this sheet even if a calendar editor is above it.
      drawer.navigator?.removeRoute(drawer);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    calendarNavigation.removeListener(openWidgetDate);
    searchController.dispose();
    super.dispose();
  }

  String query = '';
  ModalBottomSheetRoute<void>? calendarDrawerRoute;
  double bottomBarDrag = 0;
  final enabled = kinds.toSet();
  CalendarState get state => widget.state;
  Color entryColor(Entry e) => collectionColor(state.calendarFor(e));
  List<Entry> get filtered =>
      state.calendarEntries
          .where(
            (e) =>
                enabled.contains(e.kind) &&
                ('${e.title} ${e.location} ${e.description}')
                    .toLowerCase()
                    .contains(query.toLowerCase()),
          )
          .toList();
  List<Entry> onDay(DateTime d) =>
      filtered.where((e) => e.occursOn(d)).toList()..sort((a, b) {
        if (a.allDay != b.allDay) return a.allDay ? -1 : 1;
        return (a.when ?? d).compareTo(b.when ?? d);
      });
  DateTime get weekStart => DateTime.utc(
    selected.year,
    selected.month,
    selected.day - (selected.weekday % 7 - state.weekStartsOn + 7) % 7,
  );
  void loadRange() {
    final first =
        view == 'Yearly'
            ? DateTime.utc(selected.year)
            : view == 'Weekly'
            ? weekStart
            : view == 'Daily'
            ? selected
            : monthCellDates(month, weekStartsOn: state.weekStartsOn).first;
    final last =
        view == 'Yearly'
            ? DateTime.utc(selected.year + 1)
            : view == 'Weekly'
            ? weekStart.add(const Duration(days: 7))
            : view == 'Daily'
            ? DateTime.utc(selected.year, selected.month, selected.day + 1)
            : monthCellDates(
              month,
              weekStartsOn: state.weekStartsOn,
            ).last.add(const Duration(days: 1));
    act(() => state.setRange(first, last));
  }

  void select(DateTime d, {String? mode}) {
    setState(() {
      selected = day(d);
      month = DateTime.utc(d.year, d.month);
      if (mode != null) view = mode;
    });
    loadRange();
  }

  void navigate(int amount) {
    select(
      view == 'Yearly'
          ? DateTime.utc(selected.year + amount, selected.month, selected.day)
          : view == 'Month'
          ? DateTime.utc(month.year, month.month + amount)
          : DateTime.utc(
            selected.year,
            selected.month,
            selected.day + amount * (view == 'Weekly' ? 7 : 1),
          ),
    );
  }

  Future<void> act(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> edit({Entry? entry, String? kind, DateTime? at}) async {
    await showDialog<void>(
      context: context,
      builder:
          (_) => EntryEditor(
            state: state,
            date: at ?? selected,
            initialTime: at,
            entry: entry?.series,
            initialKind: kind ?? 'event',
          ),
    );
  }

  Future<void> details(Entry e) async {
    await showDialog<void>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: Row(
              children: [
                Icon(kindIcons[e.kind], color: entryColor(e)),
                const SizedBox(width: 12),
                Expanded(child: Text(e.title)),
              ],
            ),
            content: SizedBox(
              width: 400,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${kindLabels[e.kind]}${e.recurring ? ' · Repeating' : ''}',
                      style: const TextStyle(color: muted),
                    ),
                    const SizedBox(height: 20),
                    if (e.when != null)
                      Text(
                        '${DateFormat.yMMMMd().format(e.when!)}${e.allDay ? ' · All day' : ' · ${(state.use24Hour ? DateFormat.Hm() : DateFormat.jm()).format(e.when!)}'}',
                      ),
                    if (e.end != null && !e.allDay)
                      Text(
                        'Until ${(state.use24Hour ? DateFormat.yMMMd().add_Hm() : DateFormat.yMMMd().add_jm()).format(e.end!)}',
                        style: const TextStyle(color: muted),
                      ),
                    if (e.location.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 14),
                        child: Text('⌖  ${e.location}'),
                      ),
                    if (e.description.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 18),
                        child: Text(
                          e.description,
                          style: const TextStyle(height: 1.6),
                        ),
                      ),
                    const SizedBox(height: 20),
                    Text(
                      e.owner == 'local'
                          ? 'On this device'
                          : 'Organized by @${e.owner}',
                      style: const TextStyle(color: muted),
                    ),
                    for (final person in e.attendees.entries)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.person_outline,
                              size: 17,
                              color: muted,
                            ),
                            const SizedBox(width: 8),
                            Expanded(child: Text('@${person.key}')),
                            Text(
                              person.value,
                              style: const TextStyle(
                                color: muted,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (e.recurring)
                      const Padding(
                        padding: EdgeInsets.only(top: 20),
                        child: Text(
                          'Edits apply to the series. You can skip a single occurrence without changing the remaining schedule.',
                          style: TextStyle(color: muted, height: 1.5),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              if (state.canEdit(e) && e.recurring && e.recurrenceId != null)
                TextButton(
                  onPressed: () async {
                    Navigator.pop(ctx);
                    await act(() => state.occurrenceAction(e, 'skip'));
                  },
                  child: const Text('Skip this occurrence'),
                ),
              if (state.canEdit(e))
                TextButton(
                  onPressed: () async {
                    final confirmed = await showDialog<bool>(
                      context: ctx,
                      builder:
                          (c) => AlertDialog(
                            title: Text(
                              e.recurring
                                  ? 'Delete the entire series?'
                                  : 'Delete this entry?',
                            ),
                            content: const Text(
                              'It will also be removed from invited people’s calendars.',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(c, false),
                                child: const Text('Keep it'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(c, true),
                                child: const Text('Delete'),
                              ),
                            ],
                          ),
                    );
                    if (confirmed == true && ctx.mounted) {
                      Navigator.pop(ctx);
                      await act(() => state.remove(e));
                    }
                  },
                  child: const Text(
                    'Delete',
                    style: TextStyle(color: Color(0xFFB34343)),
                  ),
                ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close'),
              ),
              if (state.canEdit(e))
                FilledButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    edit(entry: e);
                  },
                  child: const Text('Edit entry'),
                ),
            ],
          ),
    );
  }

  Widget toolIcon(String label, IconData icon, VoidCallback action) =>
      IconButton(
        tooltip: label,
        onPressed: action,
        icon: Icon(icon, size: 19),
        constraints: const BoxConstraints.tightFor(width: 30, height: 32),
        padding: EdgeInsets.zero,
      );

  String get period =>
      view == 'Yearly'
          ? '${selected.year}'
          : view == 'Daily'
          ? DateFormat('MMM d, y').format(selected)
          : view == 'Weekly'
          ? '${DateFormat('MMM d').format(weekStart)} – ${DateFormat('MMM d, y').format(weekStart.add(const Duration(days: 6)))}'
          : DateFormat.yMMMM().format(month);

  Widget viewSelector({bool compact = false}) => PopupMenuButton<String>(
    key: const ValueKey('view-selector'),
    tooltip: 'Calendar view',
    initialValue: view,
    position: PopupMenuPosition.under,
    onSelected: (mode) {
      setState(() => view = mode);
      loadRange();
    },
    itemBuilder:
        (_) => [
          for (final mode in ['Daily', 'Weekly', 'Month', 'Yearly'])
            PopupMenuItem(
              value: mode,
              key: ValueKey('view-$mode'),
              height: 40,
              child: Row(
                children: [
                  Expanded(
                    child: Text(mode, style: const TextStyle(fontSize: 13)),
                  ),
                  if (mode == view)
                    const Icon(Icons.check, size: 16, color: forest),
                ],
              ),
            ),
        ],
    child: Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border.all(color: line),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!compact) ...[
            Text(view, style: const TextStyle(fontSize: 12)),
            const SizedBox(width: 3),
          ],
          const Icon(Icons.arrow_drop_down, size: 18),
        ],
      ),
    ),
  );

  Widget searchField({bool autofocus = false}) => SizedBox(
    height: 36,
    child: TextField(
      key: const ValueKey('search-input'),
      controller: searchController,
      autofocus: autofocus,
      decoration: InputDecoration(
        hintText: 'Search',
        prefixIcon: const Icon(Icons.search, size: 18),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10),
        suffixIcon:
            query.isEmpty
                ? null
                : IconButton(
                  tooltip: 'Clear search',
                  icon: const Icon(Icons.close, size: 17),
                  onPressed: () {
                    searchController.clear();
                    setState(() => query = '');
                  },
                ),
      ),
      onChanged: (value) => setState(() => query = value),
      onSubmitted: (_) => setState(() => searchExpanded = false),
    ),
  );

  Widget addEventButton(bool compact) =>
      compact
          ? IconButton.filled(
            key: const ValueKey('header-add-event'),
            tooltip: 'Add event',
            onPressed: () => edit(),
            icon: const Icon(Icons.add, size: 21),
            style: IconButton.styleFrom(
              minimumSize: const Size(36, 36),
              maximumSize: const Size(36, 36),
              padding: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6),
              ),
            ),
          )
          : FilledButton.icon(
            key: const ValueKey('header-add-event'),
            onPressed: () => edit(),
            icon: const Icon(Icons.add, size: 17),
            label: const Text('Add event', style: TextStyle(fontSize: 12)),
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 36),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6),
              ),
            ),
          );

  Widget header() => LayoutBuilder(
    builder: (context, box) {
      final narrow = box.maxWidth < 760, compact = box.maxWidth < 600;
      final calendar = page == 0, canSearch = page != 3;
      final shortPeriod =
          view == 'Month'
              ? DateFormat.yMMM().format(month)
              : view == 'Yearly'
              ? '${selected.year}'
              : view == 'Daily'
              ? DateFormat.MMMd().format(selected)
              : '${DateFormat.MMMd().format(weekStart)}–${DateFormat.MMMd().format(weekStart.add(const Duration(days: 6)))}';
      return Container(
        key: const ValueKey('header-bar'),
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        color: Colors.white,
        child: Row(
          children: [
            if (narrow && searchExpanded && canSearch) ...[
              toolIcon(
                'Close search',
                Icons.arrow_back,
                () => setState(() => searchExpanded = false),
              ),
              const SizedBox(width: 4),
              Expanded(child: searchField(autofocus: true)),
            ] else ...[
              if (calendar) ...[
                toolIcon('Previous', Icons.chevron_left, () => navigate(-1)),
                if (!compact)
                  TextButton(
                    onPressed: () => select(DateTime.now()),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 34),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                    ),
                    child: const Text('Today'),
                  ),
                toolIcon('Next', Icons.chevron_right, () => navigate(1)),
                Expanded(
                  child: Tooltip(
                    message: period,
                    child: Text(
                      compact ? shortPeriod : period,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: compact ? 12 : 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 5),
                viewSelector(compact: box.maxWidth < 400),
              ] else
                Expanded(
                  child: Text(
                    page == 1
                        ? 'Todos'
                        : page == 2
                        ? 'Invites'
                        : 'Settings',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              if (canSearch) ...[
                const SizedBox(width: 6),
                if (narrow)
                  IconButton(
                    key: const ValueKey('search-button'),
                    tooltip: 'Search',
                    onPressed: () => setState(() => searchExpanded = true),
                    icon: Badge(
                      isLabelVisible: query.isNotEmpty,
                      smallSize: 5,
                      child: const Icon(Icons.search, size: 21),
                    ),
                    style: IconButton.styleFrom(
                      minimumSize: const Size(36, 36),
                      maximumSize: const Size(36, 36),
                      padding: EdgeInsets.zero,
                    ),
                  )
                else
                  SizedBox(width: 190, child: searchField()),
              ],
              if (box.maxWidth >= 1000 && canSearch && state.connected)
                toolIcon('Sync', Icons.sync, () => act(state.sync)),
            ],
            const SizedBox(width: 6),
            toolIcon(
              'Calendars & todos',
              Icons.calendar_month_outlined,
              () => openCalendarDrawer(todosFirst: page == 1),
            ),
            addEventButton(compact),
          ],
        ),
      );
    },
  );

  void openDestination(int index) {
    setState(() {
      page = index;
      searchExpanded = false;
    });
    if (index == 0) loadRange();
  }

  static const destinations = [
    ('Calendar', Icons.calendar_month_outlined),
    ('Todos', Icons.check_circle_outline),
    ('Invites', Icons.mail_outline),
    ('Settings', Icons.settings_outlined),
  ];

  Future<void> openCalendarDrawer({bool todosFirst = false}) async {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (calendarDrawerRoute != null ||
        (lifecycle != null && lifecycle != AppLifecycleState.resumed)) {
      return;
    }
    final navigator = Navigator.of(context);
    final localizations = MaterialLocalizations.of(context);
    try {
      final drawer = ModalBottomSheetRoute<void>(
        capturedThemes: InheritedTheme.capture(
          from: context,
          to: navigator.context,
        ),
        barrierLabel: localizations.scrimLabel,
        barrierOnTapHint: localizations.scrimOnTapHint(
          localizations.bottomSheetLabel,
        ),
        modalBarrierColor: Theme.of(context).bottomSheetTheme.modalBarrierColor,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        backgroundColor: paper,
        constraints: const BoxConstraints(maxWidth: 640),
        builder:
            (context) => DraggableScrollableSheet(
              key: const ValueKey('calendar-drawer'),
              expand: false,
              initialChildSize: 0.65,
              minChildSize: 0.35,
              maxChildSize: 0.92,
              snap: true,
              builder:
                  (context, controller) => ListView(
                    controller: controller,
                    padding: EdgeInsets.only(
                      bottom: MediaQuery.paddingOf(context).bottom + 16,
                    ),
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
                        child: Row(
                          children: [
                            const Expanded(
                              child: Text(
                                'Calendars & todos',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Close calendars',
                              onPressed: () => Navigator.pop(context),
                              icon: const Icon(Icons.close),
                            ),
                          ],
                        ),
                      ),
                      CalendarPanel(state: state, todosFirst: todosFirst),
                    ],
                  ),
            ),
      );
      calendarDrawerRoute = drawer;
      await navigator.push(drawer);
    } finally {
      calendarDrawerRoute = null;
    }
  }

  Future<void> visibilityMenu(int index, BuildContext anchor) async {
    if (index < 2) {
      await openCalendarDrawer(todosFirst: index == 1);
      return;
    }
    final box = anchor.findRenderObject() as RenderBox;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final rect = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
    final kind = await showMenu<String>(
      context: context,
      semanticLabel: 'Invite visibility',
      position: RelativeRect.fromRect(rect, Offset.zero & overlay.size),
      items: [
        CheckedPopupMenuItem<String>(
          key: const ValueKey('visibility-invite'),
          value: 'invite',
          checked: state.showInvites,
          child: const Text(
            'Show invites on calendar',
            style: TextStyle(fontSize: 13),
          ),
        ),
      ],
    );
    if (kind == 'invite' && mounted) {
      await act(() => state.savePreferences(showInvites: !state.showInvites));
    }
  }

  Widget visibilityTarget(int index, Widget child) =>
      index > 2
          ? child
          : Builder(
            builder:
                (anchor) => Semantics(
                  hint: 'Long press for visibility options',
                  customSemanticsActions: {
                    const CustomSemanticsAction(label: 'Visibility options'):
                        () => visibilityMenu(index, anchor),
                  },
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onLongPress: () => visibilityMenu(index, anchor),
                    onSecondaryTapUp: (_) => visibilityMenu(index, anchor),
                    child: child,
                  ),
                ),
          );

  Widget navigationIcon(int index) => Badge(
    isLabelVisible: index == 2 && state.invitationCount > 0,
    label: Text('${state.invitationCount}'),
    child: Icon(destinations[index].$2, size: 22),
  );

  Widget bottomNavigation() => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onVerticalDragStart: (_) => bottomBarDrag = 0,
    onVerticalDragUpdate: (details) => bottomBarDrag += details.delta.dy,
    onVerticalDragEnd: (details) {
      if (bottomBarDrag < -24 || (details.primaryVelocity ?? 0) < -250) {
        openCalendarDrawer(todosFirst: page == 1);
      }
    },
    child: Material(
      key: const ValueKey('mobile-navigation'),
      color: Colors.white,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: line)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Tooltip(
                message: 'Calendars and todo lists',
                child: Semantics(
                  button: true,
                  label: 'Calendars and todo lists',
                  hint: 'Tap or swipe up to show visibility options',
                  child: InkWell(
                    key: const ValueKey('calendar-drawer-handle'),
                    onTap: () => openCalendarDrawer(todosFirst: page == 1),
                    child: SizedBox(
                      height: 20,
                      width: double.infinity,
                      child: Center(
                        child: Container(
                          width: 36,
                          height: 4,
                          decoration: BoxDecoration(
                            color: muted.withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(
                height: 58,
                child: Row(
                  children: [
                    for (var i = 0; i < destinations.length; i++)
                      Expanded(
                        child: visibilityTarget(
                          i,
                          Semantics(
                            button: true,
                            selected: page == i,
                            label: destinations[i].$1,
                            onTap: () => openDestination(i),
                            child: ExcludeSemantics(
                              child: InkWell(
                                onTap: () => openDestination(i),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 13,
                                        vertical: 3,
                                      ),
                                      decoration: BoxDecoration(
                                        color:
                                            page == i
                                                ? const Color(0xFFE7EEE6)
                                                : Colors.transparent,
                                        borderRadius: BorderRadius.circular(18),
                                      ),
                                      child: IconTheme(
                                        data: IconThemeData(
                                          color: page == i ? forest : muted,
                                        ),
                                        child: navigationIcon(i),
                                      ),
                                    ),
                                    Text(
                                      destinations[i].$1,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: page == i ? forest : muted,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.white,
    bottomNavigationBar: bottomNavigation(),
    body: SafeArea(
      bottom: false,
      child: Column(
        children: [
          header(),
          const Divider(height: 1),
          if (state.loading) const LinearProgressIndicator(minHeight: 2),
          if (state.error != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              color: const Color(0xFFFFEFEA),
              child: Text(
                state.error!,
                style: const TextStyle(color: Color(0xFFB34343), fontSize: 12),
              ),
            ),
          Expanded(
            child:
                page == 1
                    ? todoContent()
                    : page == 2
                    ? invitationContent()
                    : page == 3
                    ? settingsContent()
                    : view == 'Daily'
                    ? dailyView()
                    : view == 'Weekly'
                    ? weeklyView()
                    : view == 'Yearly'
                    ? yearView()
                    : MonthPager(
                      key: const ValueKey('month-calendar'),
                      month: month,
                      onMonthChanged: select,
                      builder: monthView,
                    ),
          ),
        ],
      ),
    ),
  );

  Widget weekdaysRow({bool short = false}) => SizedBox(
    height: short ? 18 : 26,
    child: Row(
      children: [
        for (final label in List.generate(
          7,
          (i) =>
              [
                'Sun',
                'Mon',
                'Tue',
                'Wed',
                'Thu',
                'Fri',
                'Sat',
              ][(i + state.weekStartsOn) % 7],
        ))
          Expanded(
            child: Center(
              child: Text(
                short ? label.substring(0, 1) : label,
                style: TextStyle(color: muted, fontSize: short ? 10 : 11),
              ),
            ),
          ),
      ],
    ),
  );

  Widget eventChip(Entry e) => Padding(
    padding: const EdgeInsets.fromLTRB(3, 0, 3, 2),
    child: Material(
      color: entryColor(e).withValues(alpha: .12),
      borderRadius: BorderRadius.circular(3),
      child: InkWell(
        onTap: () => details(e),
        child: Container(
          height: 21,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: entryColor(e), width: 2)),
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '${e.allDay || e.when == null ? '' : '${DateFormat(state.use24Hour ? 'HH:mm' : 'h:mm a').format(e.when!)} '}${e.title}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: ink,
                decoration: e.completed ? TextDecoration.lineThrough : null,
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget monthView(DateTime displayedMonth) {
    final dates = monthCellDates(
          displayedMonth,
          weekStartsOn: state.weekStartsOn,
        ),
        rows =
            monthCellDates(
              displayedMonth,
              weekStartsOn: state.weekStartsOn,
            ).length ~/
            7;
    return Column(
      children: [
        weekdaysRow(),
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) {
              final gridHeight =
                  box.maxHeight < rows * 44 ? rows * 44.0 : box.maxHeight;
              final cellHeight = gridHeight / rows;
              final capacity = ((cellHeight - 32) / 23).floor().clamp(0, 8);
              final grid = Column(
                children: [
                  for (var row = 0; row < rows; row++)
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var col = 0; col < 7; col++)
                            Expanded(
                              child: Builder(
                                builder: (context) {
                                  final date = dates[row * 7 + col],
                                      entries = onDay(dates[row * 7 + col]);
                                  final current =
                                          date.month == displayedMonth.month,
                                      today = date == day(DateTime.now());
                                  final shown =
                                      entries.length > capacity && capacity > 0
                                          ? capacity - 1
                                          : capacity;
                                  return GestureDetector(
                                    onTap: () {
                                      if (!current) {
                                        select(date);
                                      } else {
                                        setState(() => selected = date);
                                      }
                                    },
                                    onDoubleTap: () {
                                      setState(() => selected = date);
                                      edit();
                                    },
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color:
                                            date == selected
                                                ? const Color(0xFFF0F4EE)
                                                : current
                                                ? Colors.white
                                                : const Color(0xFFF8F9F6),
                                        border: Border(
                                          top: const BorderSide(color: line),
                                          right:
                                              col < 6
                                                  ? const BorderSide(
                                                    color: line,
                                                  )
                                                  : BorderSide.none,
                                        ),
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          SizedBox(
                                            height: 29,
                                            child: Align(
                                              alignment: Alignment.centerLeft,
                                              child: Container(
                                                margin: const EdgeInsets.only(
                                                  left: 5,
                                                ),
                                                width: 23,
                                                height: 23,
                                                decoration:
                                                    today
                                                        ? const BoxDecoration(
                                                          color: forest,
                                                          shape:
                                                              BoxShape.circle,
                                                        )
                                                        : null,
                                                child: Center(
                                                  child: Text(
                                                    '${date.day}',
                                                    style: TextStyle(
                                                      fontSize: 12,
                                                      color:
                                                          today
                                                              ? Colors.white
                                                              : current
                                                              ? ink
                                                              : muted,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                          if (capacity > 0) ...[
                                            for (final e in entries.take(shown))
                                              eventChip(e),
                                            if (entries.length > capacity)
                                              InkWell(
                                                onTap:
                                                    () => select(
                                                      date,
                                                      mode: 'Daily',
                                                    ),
                                                child: Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                        left: 7,
                                                      ),
                                                  child: Text(
                                                    '+${entries.length - shown} more',
                                                    style: const TextStyle(
                                                      fontSize: 10,
                                                      color: muted,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                          ] else if (entries.isNotEmpty)
                                            Center(child: dots(entries)),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              );
              return gridHeight > box.maxHeight
                  ? SingleChildScrollView(
                    child: SizedBox(height: gridHeight, child: grid),
                  )
                  : grid;
            },
          ),
        ),
      ],
    );
  }

  Widget dots(List<Entry> entries) => Row(
    mainAxisSize: MainAxisSize.min,
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      for (final calendarId in entries.map((e) => e.calendarId).toSet().take(4))
        Container(
          width: 4,
          height: 4,
          margin: const EdgeInsets.symmetric(horizontal: 1),
          decoration: BoxDecoration(
            color: entryColor(
              entries.firstWhere((e) => e.calendarId == calendarId),
            ),
            shape: BoxShape.circle,
          ),
        ),
    ],
  );

  Widget entryRow(Entry e) => Container(
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: line)),
    ),
    child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      dense: true,
      minVerticalPadding: 6,
      leading: SizedBox(
        width: 66,
        child: Row(
          children: [
            Container(width: 3, height: 28, color: entryColor(e)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                e.allDay
                    ? 'All day'
                    : e.when == null
                    ? 'Undated'
                    : DateFormat(
                      state.use24Hour ? 'HH:mm' : 'h:mm a',
                    ).format(e.when!),
                style: const TextStyle(fontSize: 12, color: muted),
              ),
            ),
          ],
        ),
      ),
      title: Text(
        e.title,
        style: TextStyle(
          fontSize: 13,
          decoration: e.completed ? TextDecoration.lineThrough : null,
        ),
      ),
      subtitle:
          e.location.isEmpty
              ? null
              : Text(
                e.location,
                style: const TextStyle(fontSize: 11, color: muted),
              ),
      trailing:
          e.kind == 'todo'
              ? Checkbox(
                value: e.completed,
                onChanged:
                    state.canEdit(e)
                        ? (v) => act(() => state.complete(e, v!))
                        : null,
              )
              : Icon(kindIcons[e.kind], size: 17, color: entryColor(e)),
      onTap: () => details(e),
    ),
  );

  Widget dateHeading(DateTime d) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
    color: paper,
    child: Text(
      DateFormat('EEEE, MMMM d').format(d),
      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
    ),
  );

  Widget dailyView() => TimeGrid(
    key: ValueKey('daily-calendar-${selected.toIso8601String()}'),
    dates: [selected],
    entries: filtered,
    colorFor: entryColor,
    selected: selected,
    use24Hour: state.use24Hour,
    onEntry: details,
    onSelect: (d) => select(d),
    onOpenDay: (d) => select(d, mode: 'Daily'),
    onCreate: (d) => edit(at: d),
  );
  Widget weeklyView() => TimeGrid(
    key: const ValueKey('weekly-calendar'),
    dates: List.generate(7, (i) => weekStart.add(Duration(days: i))),
    entries: filtered,
    colorFor: entryColor,
    selected: selected,
    use24Hour: state.use24Hour,
    onEntry: details,
    onSelect: (d) => select(d),
    onOpenDay: (d) => select(d, mode: 'Daily'),
    onCreate: (d) => edit(at: d),
  );

  Widget yearView() => LayoutBuilder(
    builder: (context, box) {
      final columns =
          box.maxWidth >= 1100
              ? 4
              : box.maxWidth >= 760
              ? 3
              : box.maxWidth >= 460
              ? 2
              : 1;
      final height = (box.maxHeight / (12 / columns).ceil()).clamp(
        180.0,
        300.0,
      );
      final byDate = <DateTime, List<Entry>>{};
      for (var m = 1; m <= 12; m++) {
        for (var d = 1; d <= DateTime.utc(selected.year, m + 1, 0).day; d++) {
          final date = DateTime.utc(selected.year, m, d);
          byDate[date] = onDay(date);
        }
      }
      return GridView.builder(
        key: const ValueKey('year-calendar'),
        itemCount: 12,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          mainAxisExtent: height,
        ),
        itemBuilder: (context, index) {
          final m = DateTime.utc(selected.year, index + 1),
              first =
                  monthCellDates(
                    DateTime.utc(selected.year, index + 1),
                    weekStartsOn: state.weekStartsOn,
                  ).first;
          return Container(
            padding: const EdgeInsets.fromLTRB(10, 3, 10, 7),
            decoration: const BoxDecoration(
              border: Border(
                right: BorderSide(color: line),
                bottom: BorderSide(color: line),
              ),
            ),
            child: Column(
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      minimumSize: const Size(0, 28),
                    ),
                    onPressed: () => select(m, mode: 'Month'),
                    child: Text(
                      DateFormat.MMMM().format(m),
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                weekdaysRow(short: true),
                for (var row = 0; row < 6; row++)
                  Expanded(
                    child: Row(
                      children: [
                        for (var col = 0; col < 7; col++)
                          Expanded(
                            child: Builder(
                              builder: (context) {
                                final d = first.add(
                                  Duration(days: row * 7 + col),
                                );
                                if (d.month != m.month) {
                                  return const SizedBox.shrink();
                                }
                                return InkWell(
                                  onTap: () => select(d, mode: 'Daily'),
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(
                                        '${d.day}',
                                        style: TextStyle(
                                          fontSize: 12,
                                          height: 1,
                                          color:
                                              d == day(DateTime.now())
                                                  ? forest
                                                  : ink,
                                          fontWeight:
                                              d == day(DateTime.now())
                                                  ? FontWeight.w700
                                                  : FontWeight.w400,
                                        ),
                                      ),
                                      SizedBox(
                                        height: 5,
                                        child: dots(byDate[d] ?? []),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          );
        },
      );
    },
  );

  Widget todoContent() {
    final todos =
        state.todos
            .where(
              (e) => ('${e.title} ${e.description}').toLowerCase().contains(
                query.toLowerCase(),
              ),
            )
            .toList()
          ..sort(
            (a, b) =>
                (a.due ?? DateTime(9999)).compareTo(b.due ?? DateTime(9999)),
          );
    return ListView(
      children: [
        for (final done in [false, true])
          if (todos.any((e) => e.completed == done)) ...[
            Container(
              padding: const EdgeInsets.all(12),
              color: paper,
              child: Text(
                done ? 'Completed' : 'To do',
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ),
            for (final e in todos.where((e) => e.completed == done))
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  entryRow(e),
                  Padding(
                    padding: const EdgeInsets.only(left: 89, bottom: 5),
                    child: Text(
                      e.due == null
                          ? 'No due date'
                          : 'Due ${DateFormat.yMMMd().format(e.due!)}',
                      style: TextStyle(
                        fontSize: 11,
                        color: e.overdue ? const Color(0xFFB34343) : muted,
                      ),
                    ),
                  ),
                ],
              ),
          ],
        if (todos.isEmpty)
          const Padding(padding: EdgeInsets.all(12), child: Text('No todos')),
      ],
    );
  }

  Widget invitationContent() => InvitationsPanel(
    state: state,
    query: query,
    onAction: act,
    onDetails: details,
    onSignIn:
        () => Navigator.push(
          context,
          MaterialPageRoute<void>(builder: (_) => AuthPage(state: state)),
        ),
    onOpenCalendar:
        (calendar) => act(() async {
          await state.selectCalendar(calendar.id);
          await state.setCalendarVisible(calendar.id, true);
          if (mounted) openDestination(0);
        }),
  );

  Widget settingSection(String title, List<Widget> children) => Container(
    width: double.infinity,
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      border: Border.all(color: line),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        ...children,
      ],
    ),
  );

  Widget preferenceChoice(
    String label,
    bool selected,
    Future<void> Function() action, {
    Key? key,
  }) => ChoiceChip(
    key: key,
    label: Text(label, style: const TextStyle(fontSize: 12)),
    selected: selected,
    showCheckmark: false,
    onSelected: (_) => act(action),
  );

  Widget settingsContent() {
    final url = '${state.api.base}/dav/${state.username}/calendars/default/';
    return ListView(
      key: const ValueKey('settings-screen'),
      padding: const EdgeInsets.all(12),
      children: [
        Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                settingSection('Calendar preferences', [
                  const Text('Default view', style: TextStyle(fontSize: 12)),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 5,
                    runSpacing: 3,
                    children: [
                      for (final mode in ['Daily', 'Weekly', 'Month', 'Yearly'])
                        preferenceChoice(
                          mode,
                          state.defaultView == mode,
                          () => state.savePreferences(defaultView: mode),
                          key: ValueKey('default-$mode'),
                        ),
                    ],
                  ),
                  const Padding(
                    padding: EdgeInsets.only(top: 4, bottom: 14),
                    child: Text(
                      'Applies when you open Spacetime.',
                      style: TextStyle(fontSize: 11, color: muted),
                    ),
                  ),
                  const Text('Week starts on', style: TextStyle(fontSize: 12)),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 5,
                    children: [
                      preferenceChoice(
                        'Sunday',
                        state.weekStartsOn == 0,
                        () => state.savePreferences(weekStartsOn: 0),
                        key: const ValueKey('week-start-sunday'),
                      ),
                      preferenceChoice(
                        'Monday',
                        state.weekStartsOn == 1,
                        () => state.savePreferences(weekStartsOn: 1),
                        key: const ValueKey('week-start-monday'),
                      ),
                    ],
                  ),
                  SwitchListTile(
                    key: const ValueKey('settings-24-hour'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text(
                      '24-hour time',
                      style: TextStyle(fontSize: 12),
                    ),
                    subtitle: Text(
                      state.use24Hour ? '13:00' : '1:00 PM',
                      style: const TextStyle(fontSize: 11, color: muted),
                    ),
                    value: state.use24Hour,
                    onChanged:
                        (value) => act(() async {
                          await state.savePreferences(use24Hour: value);
                        }),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Time zone: ${state.timezone}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Preferences are saved ${kIsWeb ? 'in this browser' : 'on this device'}.',
                    style: const TextStyle(fontSize: 11, color: muted),
                  ),
                ]),
                settingSection('Reminders', [
                  if (!kIsWeb)
                    SwitchListTile(
                      key: const ValueKey('enable-reminders'),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('Local notifications'),
                      subtitle: const Text(
                        'Choose a reminder when editing an entry.',
                      ),
                      value: state.notificationsEnabled,
                      onChanged:
                          (v) => act(
                            () => state.savePreferences(notifications: v),
                          ),
                    )
                  else
                    const Text(
                      'Scheduled notifications are available in the Android app.',
                    ),
                  const SizedBox(height: 4),
                  const Text(
                    'Reminders run on your device. Invite and event alerts use Private Store.',
                    style: TextStyle(fontSize: 12, color: muted),
                  ),
                  if (state.reminderError != null)
                    Text(
                      state.reminderError!,
                      style: const TextStyle(color: Colors.red),
                    ),
                ]),
                settingSection('Sync & invites', [
                  if (!kIsWeb && nativePlatformReady)
                    TextButton(
                      onPressed:
                          () => act(() async {
                            await nativeChannel.invokeMethod<bool>(
                              'requestNotifications',
                            );
                            await nativeChannel.invokeMethod<void>(
                              'openCalendarNotificationSettings',
                            );
                          }),
                      child: const Text('Enable invite & event notifications'),
                    ),
                  if (state.loginError != null)
                    Text(
                      state.loginError!,
                      style: const TextStyle(color: Color(0xFFB34343)),
                    ),
                  Text(
                    state.connected
                        ? '${state.name} · @${state.username}'
                        : 'No account connected',
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Changes sync automatically while logged in. Offline edits are queued. Updates from other devices are checked hourly while Spacetime is open.',
                    style: TextStyle(fontSize: 12, color: muted),
                  ),
                  if (state.connected) ...[
                    const SizedBox(height: 8),
                    if (!kIsWeb) ...[
                      SelectableText(
                        state.api.base,
                        key: const ValueKey('account-server-address'),
                        style: const TextStyle(fontSize: 12),
                      ),
                      const SizedBox(height: 8),
                    ],
                    Text(
                      '${state.pendingChanges} pending changes${state.lastSync == null ? '' : ' · Last synced ${DateFormat.yMMMd().add_Hm().format(DateTime.parse(state.lastSync!))}'}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      if (state.connected)
                        FilledButton.icon(
                          key: const ValueKey('sync-now'),
                          onPressed:
                              state.loading ? null : () => act(state.sync),
                          icon: const Icon(Icons.sync, size: 17),
                          label: Text(state.loading ? 'Syncing…' : 'Sync now'),
                        )
                      else
                        FilledButton.icon(
                          key: const ValueKey('connect-account'),
                          onPressed:
                              state.usesGravitas
                                  ? () => showDialog<void>(
                                    context: context,
                                    builder:
                                        (_) => AlertDialog(
                                          content: GravitasLogin(state: state),
                                        ),
                                  )
                                  : () => Navigator.push(
                                    context,
                                    MaterialPageRoute<void>(
                                      builder: (_) => AuthPage(state: state),
                                    ),
                                  ),
                          icon: const Icon(Icons.person_outline, size: 17),
                          label: Text(
                            state.usesGravitas ? 'Sign in' : 'Sign in for sync',
                          ),
                        ),
                      if (!state.connected && state.usesGravitas)
                        OutlinedButton(
                          key: const ValueKey('settings-gravitas-register'),
                          onPressed: state.registerWithGravitas,
                          child: Text(
                            'Register at ${state.gravitasDefaultDomain}',
                          ),
                        ),
                      if (!kIsWeb &&
                          state.usesGravitas &&
                          (!state.connected || state.loginError != null))
                        TextButton(
                          onPressed: state.loginWithBrowser,
                          child: const Text('Use browser'),
                        ),
                      if (!kIsWeb && !state.connected && state.usesGravitas)
                        TextButton(
                          onPressed:
                              () => Navigator.push(
                                context,
                                MaterialPageRoute<void>(
                                  builder:
                                      (_) => AuthPage(
                                        state: state,
                                        customServer: true,
                                      ),
                                ),
                              ),
                          child: const Text('Use another server'),
                        ),
                      if (state.connected)
                        OutlinedButton.icon(
                          onPressed:
                              state.loading
                                  ? null
                                  : () => act(
                                    state.usesGravitas
                                        ? state.disconnectGravitas
                                        : state.signOut,
                                  ),
                          icon: const Icon(Icons.logout, size: 17),
                          label: const Text('Disconnect'),
                        ),
                    ],
                  ),
                  if (state.conflicts.isNotEmpty) ...[
                    const Text(
                      'The server version is shown. Your unsent edits are kept below.',
                      style: TextStyle(fontSize: 12, color: muted),
                    ),
                    const SizedBox(height: 12),
                    for (final entry in state.conflicts)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Conflict: ${entry.title}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Wrap(
                              spacing: 8,
                              children: [
                                TextButton(
                                  onPressed:
                                      () => act(
                                        () => state.resolveConflict(
                                          entry,
                                          keepDevice: true,
                                        ),
                                      ),
                                  child: const Text('Keep device version'),
                                ),
                                TextButton(
                                  onPressed:
                                      () => act(
                                        () => state.resolveConflict(
                                          entry,
                                          keepDevice: false,
                                        ),
                                      ),
                                  child: const Text('Use server version'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                  ],
                ]),
                if (state.connected && state.user?['password_login'] == false)
                  const Text(
                    'Gravitas login does not create a local password. CalDAV clients require a local Spacetime account.',
                    style: TextStyle(fontSize: 12, color: muted),
                  ),
                if (state.connected && state.user?['password_login'] != false)
                  settingSection('CalDAV', [
                    const Text(
                      'Use this calendar URL with your Spacetime username and password.',
                      style: TextStyle(fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                    if (!kIsWeb) ...[
                      SelectableText(
                        url,
                        key: const ValueKey('caldav-address'),
                        style: const TextStyle(fontSize: 12),
                      ),
                      const SizedBox(height: 4),
                    ],
                    TextButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: url));
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Calendar URL copied'),
                            ),
                          );
                        }
                      },
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text('Copy calendar URL'),
                    ),
                  ]),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
