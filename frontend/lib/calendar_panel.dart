import 'package:flutter/material.dart';
import 'models.dart';

Color collectionColor(CalendarCollection c) =>
    Color(int.parse('FF${c.color.replaceFirst('#', '')}', radix: 16));
const calendarColorNames = [
  'Green',
  'Blue',
  'Purple',
  'Orange',
  'Gold',
  'Teal',
  'Pink',
  'Grey',
];
const calendarPalette = [
  '#376B51',
  '#426EB4',
  '#9163B3',
  '#BE6946',
  '#B88A2C',
  '#368D94',
  '#B45578',
  '#6B7585',
];

/// Give new shared calendars a contrasting, least-used default. Saved colours
/// and local overrides remain explicit user choices.
String suggestedCalendarColor(CalendarState state) {
  final candidates = calendarPalette.skip(1).toList();
  final usage = <String, int>{for (final color in candidates) color: 0};
  for (final c in state.calendars.where(
    (c) => c.account == null || c.account == state.account,
  )) {
    final color = c.color.toUpperCase();
    if (usage.containsKey(color)) usage[color] = usage[color]! + 1;
  }
  return candidates.reduce((a, b) => usage[a]! <= usage[b]! ? a : b);
}

class CalendarPanel extends StatelessWidget {
  final CalendarState state;
  final bool todosFirst;
  const CalendarPanel({
    super.key,
    required this.state,
    this.todosFirst = false,
  });
  Future<void> edit(BuildContext context, [CalendarCollection? calendar]) =>
      showDialog<void>(
        context: context,
        builder: (_) => CalendarDialog(state: state, calendar: calendar),
      );
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder:
        (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: OutlinedButton.icon(
                key: const ValueKey('create-shared-calendar'),
                onPressed:
                    () => showDialog<void>(
                      context: context,
                      builder:
                          (_) => CalendarDialog(
                            state: state,
                            initialKind: 'shared',
                          ),
                    ),
                icon: const Icon(Icons.group_add_outlined, size: 18),
                label: const Text('Create shared calendar'),
              ),
            ),
            for (final todos in todosFirst ? [true, false] : [false, true]) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 9, 5, 2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        todos ? 'Todo lists' : 'Calendars',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      key: ValueKey(
                        todos ? 'add-todo-calendar' : 'add-calendar',
                      ),
                      tooltip: 'Add calendar',
                      onPressed: () => edit(context),
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.add, size: 17),
                    ),
                  ],
                ),
              ),
              for (final c in state.calendars)
                Container(
                  height: 40,
                  decoration:
                      c.kind == 'shared'
                          ? BoxDecoration(
                            color: collectionColor(c).withValues(alpha: .07),
                            border: Border(
                              left: BorderSide(
                                color: collectionColor(c),
                                width: 3,
                              ),
                            ),
                          )
                          : null,
                  child: Row(
                    children: [
                      Semantics(
                        label: '${c.name} ${todos ? 'todos' : 'calendar'}',
                        child: Checkbox(
                          key: ValueKey(
                            '${todos ? 'todos' : 'calendar'}-visible-${c.id}',
                          ),
                          value:
                              !(todos
                                      ? state.hiddenTodoCalendars
                                      : state.hiddenCalendars)
                                  .contains(c.id),
                          activeColor: collectionColor(c),
                          visualDensity: VisualDensity.compact,
                          onChanged:
                              (v) => state.setCalendarVisible(
                                c.id,
                                v == true,
                                todos: todos,
                              ),
                        ),
                      ),
                      Expanded(
                        child: InkWell(
                          onTap: () => state.selectCalendar(c.id),
                          child: Row(
                            children: [
                              if (c.kind == 'shared')
                                Padding(
                                  padding: const EdgeInsets.only(right: 4),
                                  child: Tooltip(
                                    message: 'Shared calendar',
                                    child: Icon(
                                      Icons.group_outlined,
                                      size: 14,
                                      color: collectionColor(c),
                                    ),
                                  ),
                                ),
                              if (c.data['sync_error'] != null ||
                                  c.data['_unavailable'] == true)
                                const Tooltip(
                                  message:
                                      'Calendar unavailable — open calendar settings',
                                  child: Icon(Icons.error_outline, size: 14),
                                ),
                              if (c.readOnly)
                                const Padding(
                                  padding: EdgeInsets.only(right: 4),
                                  child: Icon(Icons.lock_outline, size: 13),
                                ),
                              Expanded(
                                child: Text(
                                  c.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight:
                                        state.selectedCalendarId == c.id
                                            ? FontWeight.w600
                                            : FontWeight.w400,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      PopupMenuButton<String>(
                        tooltip: '${c.name} settings',
                        padding: EdgeInsets.zero,
                        iconSize: 16,
                        itemBuilder:
                            (_) => [
                              const PopupMenuItem(
                                value: 'edit',
                                child: Text('Calendar settings'),
                              ),
                              if (state.canInviteToCalendar(c))
                                const PopupMenuItem(
                                  value: 'invite',
                                  child: Text('Invite to calendar'),
                                ),
                              if (state.canLeaveCalendar(c))
                                PopupMenuItem(
                                  value: 'leave',
                                  enabled: !state.loading,
                                  child: const Text('Leave calendar'),
                                ),
                            ],
                        onSelected: (action) {
                          if (action == 'edit') {
                            edit(context, c);
                          } else if (action == 'invite') {
                            inviteToCalendar(context, state, c);
                          } else if (action == 'leave') {
                            leaveCalendar(context, state, c);
                          }
                        },
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
  );
}

Future<void> inviteToCalendar(
  BuildContext context,
  CalendarState state,
  CalendarCollection c,
) => showDialog<void>(
  context: context,
  builder: (_) => CalendarInviteDialog(state: state, calendar: c),
);

class CalendarInviteDialog extends StatefulWidget {
  final CalendarState state;
  final CalendarCollection calendar;
  const CalendarInviteDialog({
    super.key,
    required this.state,
    required this.calendar,
  });
  @override
  State<CalendarInviteDialog> createState() => _CalendarInviteDialogState();
}

class _CalendarInviteDialogState extends State<CalendarInviteDialog> {
  final user = TextEditingController();
  String? error;
  bool saving = false;
  @override
  void dispose() {
    user.dispose();
    super.dispose();
  }

  Future<void> invite() async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.state.inviteToSharedCalendar(widget.calendar, user.text);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      Navigator.pop(context);
      messenger?.showSnackBar(
        const SnackBar(
          content: Text('Invitation sent. They can accept it under Invites.'),
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e.toString();
          saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Invite to ${widget.calendar.name}'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: user,
          autofocus: true,
          readOnly: saving,
          autocorrect: false,
          enableSuggestions: false,
          onSubmitted: (_) {
            if (!saving) invite();
          },
          decoration: const InputDecoration(
            labelText: 'Gravitas username',
            helperText: 'Username or @username:domain',
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(error!, style: const TextStyle(color: Colors.red)),
          ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: saving ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: saving ? null : invite,
        child: Text(saving ? 'Inviting…' : 'Invite'),
      ),
    ],
  );
}

Future<void> leaveCalendar(
  BuildContext context,
  CalendarState state,
  CalendarCollection c,
) async {
  final affected =
      state.calendars
          .where((v) => v.account == c.account && v.groupId == c.groupId)
          .toList();
  final confirmed = await showDialog<bool>(
    context: context,
    builder:
        (_) => AlertDialog(
          title: Text('Leave ${c.name}?'),
          content: Text(
            'You will leave its Gravitas group and lose access to ${affected.length > 1 ? 'these calendars: ${affected.map((v) => v.name).join(', ')}' : 'this calendar'}. '
            'Your cached entries and unsent changes in these calendars will be removed from this device. Entries already shared stay available to other members. You will need a new invitation to rejoin.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Leave calendar'),
            ),
          ],
        ),
  );
  if (confirmed != true || !context.mounted) return;
  try {
    await state.leaveSharedCalendar(c);
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('You left the shared calendar.')),
      );
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }
}

class CalendarDialog extends StatefulWidget {
  final CalendarState state;
  final CalendarCollection? calendar;
  final String initialKind;
  const CalendarDialog({
    super.key,
    required this.state,
    this.calendar,
    this.initialKind = 'personal',
  });
  @override
  State<CalendarDialog> createState() => _CalendarDialogState();
}

class _CalendarDialogState extends State<CalendarDialog> {
  late final name = TextEditingController(text: widget.calendar?.name ?? '');
  final url = TextEditingController(),
      username = TextEditingController(),
      password = TextEditingController();
  late String color;
  bool colorChosen = false;
  String kind = 'personal', sourceKind = 'caldav';
  String? groupId, error;
  bool saving = false, reconnect = false;
  List<Map<String, dynamic>> discovered = [];
  final selectedSources = <String>{};
  late final requestId = widget.state.newCalendarRequestId();
  CalendarState get state => widget.state;
  @override
  void initState() {
    super.initState();
    kind = widget.calendar?.kind ?? widget.initialKind;
    color =
        widget.calendar?.color ??
        (kind == 'shared'
            ? suggestedCalendarColor(state)
            : calendarPalette.first);
    url.text = widget.calendar?.data['source_url'] as String? ?? '';
    sourceKind = widget.calendar?.data['source_kind'] as String? ?? 'caldav';
    if (widget.calendar == null && kind == 'shared' && state.connected) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) run(state.refreshGroups);
      });
    }
  }

  @override
  void dispose() {
    name.dispose();
    url.dispose();
    username.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() operation) async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await operation();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> save() => run(() async {
    if (widget.calendar != null && reconnect) {
      await state.connectRemote(
        name.text,
        color,
        url.text,
        sourceKind,
        username.text,
        password.text,
        existingId: widget.calendar!.remoteId,
      );
      await state.sync();
    } else if (widget.calendar != null) {
      await state.updateCalendar(widget.calendar!, name.text, color);
    } else if (kind == 'shared') {
      await state.createSharedCalendar(
        name.text,
        color,
        groupId: groupId,
        requestId: requestId,
      );
    } else if (kind == 'source') {
      if (discovered.isEmpty) {
        discovered = await state.discoverRemote(
          url.text,
          sourceKind,
          username.text,
          password.text,
        );
        selectedSources.addAll(discovered.map((c) => c['url'] as String));
        return;
      }
      for (final c in discovered.where(
        (c) => selectedSources.contains(c['url']),
      )) {
        await state.connectRemote(
          name.text.trim().isEmpty ? c['name'] as String : name.text,
          color,
          c['url'] as String,
          sourceKind,
          username.text,
          password.text,
        );
      }
      await state.sync();
    } else {
      await state.createCalendar(name.text, color);
    }
    if (mounted) Navigator.pop(context);
  });
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) => buildDialog(context),
  );

  Widget buildDialog(BuildContext context) => AlertDialog(
    title: Text(
      widget.calendar == null
          ? (kind == 'shared' ? 'Create shared calendar' : 'Add calendar')
          : 'Calendar settings',
    ),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.calendar == null)
              Wrap(
                spacing: 5,
                children: [
                  for (final option in [
                    ('personal', 'Personal'),
                    ('shared', 'Shared'),
                    ('source', 'Connect'),
                  ])
                    ChoiceChip(
                      label: Text(option.$2),
                      selected: kind == option.$1,
                      onSelected:
                          saving
                              ? null
                              : (_) {
                                setState(() {
                                  kind = option.$1;
                                  if (!colorChosen) {
                                    color =
                                        kind == 'shared'
                                            ? suggestedCalendarColor(state)
                                            : calendarPalette.first;
                                  }
                                });
                                if (kind == 'shared' && state.connected) {
                                  run(state.refreshGroups);
                                }
                              },
                    ),
                ],
              ),
            TextField(
              key: const ValueKey('calendar-name'),
              controller: name,
              readOnly:
                  widget.calendar != null &&
                  !state.canManageCalendar(widget.calendar!),
              decoration: InputDecoration(
                labelText: kind == 'source' ? 'Name (optional)' : 'Name',
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: [
                for (final value in calendarPalette)
                  Semantics(
                    label:
                        '${calendarColorNames[calendarPalette.indexOf(value)]} calendar colour',
                    button: true,
                    selected: color == value,
                    child: InkWell(
                      onTap:
                          saving
                              ? null
                              : () => setState(() {
                                color = value;
                                colorChosen = true;
                              }),
                      borderRadius: BorderRadius.circular(18),
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: Color(
                            int.parse('FF${value.substring(1)}', radix: 16),
                          ),
                          shape: BoxShape.circle,
                        ),
                        child:
                            color == value
                                ? const Icon(
                                  Icons.check,
                                  color: Colors.white,
                                  size: 17,
                                )
                                : null,
                      ),
                    ),
                  ),
              ],
            ),
            if (kind == 'shared' && widget.calendar == null) ...[
              const SizedBox(height: 12),
              const Text(
                'Share events and todos with people you invite. You can invite people after creating the calendar.',
              ),
              if (!state.connected || !state.groupsEnabled)
                FilledButton.tonalIcon(
                  onPressed:
                      saving ? null : () => run(state.enableSharedCalendars),
                  icon: const Icon(Icons.group_outlined),
                  label: const Text('Enable shared calendars with Gravitas'),
                )
              else ...[
                RadioListTile<String>(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Create a Gravitas group'),
                  value: 'new',
                  groupValue: groupId ?? 'new',
                  onChanged:
                      saving ? null : (_) => setState(() => groupId = null),
                ),
                for (final group in state.groups.where(
                  (g) => g['membership'] == 'join',
                ))
                  RadioListTile<String>(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(group['name'] as String),
                    subtitle: const Text('Use existing group'),
                    value: group['id'] as String,
                    groupValue: groupId ?? 'new',
                    onChanged:
                        saving ? null : (v) => setState(() => groupId = v),
                  ),
              ],
            ],
            if (kind == 'source' && widget.calendar == null) ...[
              const SizedBox(height: 8),
              if (!state.connected)
                const Text(
                  'Log in from Settings to connect a calendar through your Spacetime server.',
                ),
              Wrap(
                spacing: 5,
                children: [
                  for (final option in [
                    ('caldav', 'CalDAV'),
                    ('webdav', 'WebDAV'),
                    ('ics', 'Calendar URL'),
                  ])
                    ChoiceChip(
                      label: Text(option.$2),
                      selected: sourceKind == option.$1,
                      onSelected:
                          saving
                              ? null
                              : (_) => setState(() {
                                sourceKind = option.$1;
                                discovered = [];
                                selectedSources.clear();
                              }),
                    ),
                ],
              ),
              TextField(
                controller: url,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Calendar or server URL',
                ),
              ),
              TextField(
                controller: username,
                decoration: const InputDecoration(
                  labelText: 'Source username (optional)',
                ),
                autocorrect: false,
              ),
              TextField(
                controller: password,
                decoration: const InputDecoration(
                  labelText: 'Source password or app password',
                ),
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
              ),
              for (final c in discovered)
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(c['name'] as String),
                  subtitle:
                      c['read_only'] == true ? const Text('Read-only') : null,
                  value: selectedSources.contains(c['url']),
                  onChanged:
                      saving
                          ? null
                          : (v) => setState(() {
                            if (v == true) {
                              selectedSources.add(c['url'] as String);
                            } else {
                              selectedSources.remove(c['url']);
                            }
                          }),
                ),
            ],
            if (widget.calendar?.kind == 'source' && state.connected) ...[
              TextButton.icon(
                onPressed:
                    saving
                        ? null
                        : () => setState(() => reconnect = !reconnect),
                icon: const Icon(Icons.sync),
                label: Text(
                  reconnect ? 'Cancel reconnect' : 'Reconnect source',
                ),
              ),
              if (reconnect) ...[
                TextField(
                  controller: username,
                  decoration: const InputDecoration(
                    labelText: 'Source username (blank to keep current)',
                  ),
                  autocorrect: false,
                ),
                TextField(
                  controller: password,
                  decoration: const InputDecoration(
                    labelText: 'Source password (blank to keep current)',
                  ),
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                ),
              ],
            ],
            if (widget.calendar?.data['source_url'] != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  widget.calendar!.data['source_url'] as String,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            if (widget.calendar?.data['sync_error'] != null)
              Text(
                widget.calendar!.data['sync_error'] as String,
                style: const TextStyle(color: Colors.red, fontSize: 12),
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  error!,
                  style: const TextStyle(color: Colors.red, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      if (widget.calendar != null &&
          state.canInviteToCalendar(widget.calendar!))
        TextButton(
          onPressed:
              saving
                  ? null
                  : () => inviteToCalendar(context, state, widget.calendar!),
          child: const Text('Invite people'),
        ),
      if (widget.calendar != null && state.canLeaveCalendar(widget.calendar!))
        TextButton(
          onPressed:
              saving || state.loading
                  ? null
                  : () async {
                    await leaveCalendar(context, state, widget.calendar!);
                    if (context.mounted &&
                        !state.calendars.any(
                          (c) => c.id == widget.calendar!.id,
                        )) {
                      Navigator.pop(context);
                    }
                  },
          child: const Text('Leave calendar'),
        ),
      if (widget.calendar != null &&
          widget.calendar!.id != 'device' &&
          widget.calendar!.remoteId?.startsWith('default-') != true &&
          state.canManageCalendar(widget.calendar!))
        TextButton(
          onPressed:
              saving
                  ? null
                  : () async {
                    final source = widget.calendar!.kind == 'source';
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder:
                          (context) => AlertDialog(
                            title: Text(
                              source
                                  ? 'Disconnect calendar?'
                                  : 'Remove calendar?',
                            ),
                            content: Text(
                              source
                                  ? 'This removes the cached calendar and any unsent edits from Spacetime. The source calendar stays intact.'
                                  : 'Only empty calendars can be removed. The Gravitas group stays intact.',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context, false),
                                child: const Text('Cancel'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(context, true),
                                child: Text(source ? 'Disconnect' : 'Remove'),
                              ),
                            ],
                          ),
                    );
                    if (confirmed == true) {
                      await run(() async {
                        await state.removeCalendar(widget.calendar!);
                        if (context.mounted) Navigator.pop(context);
                      });
                    }
                  },
          child: Text(
            widget.calendar!.kind == 'source' ? 'Disconnect' : 'Remove',
          ),
        ),
      TextButton(
        onPressed: saving ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed:
            saving ||
                    (widget.calendar == null &&
                        kind == 'shared' &&
                        (!state.connected || !state.groupsEnabled)) ||
                    (widget.calendar == null &&
                        kind == 'source' &&
                        (!state.connected ||
                            (discovered.isNotEmpty && selectedSources.isEmpty)))
                ? null
                : save,
        child: Text(
          saving
              ? 'Saving…'
              : widget.calendar == null &&
                  kind == 'source' &&
                  discovered.isEmpty
              ? 'Find calendars'
              : 'Save',
        ),
      ),
    ],
  );
}
