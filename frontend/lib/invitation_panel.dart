import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'calendar_panel.dart';
import 'models.dart';

/// Resolve server calendar IDs before grouping, without borrowing another
/// account's cached calendar or guessing the name of a private collection.
CalendarCollection? invitationCalendar(CalendarState state, Entry invite) =>
    state.calendars
        .where(
          (c) =>
              (c.account == state.account || c.account == null) &&
              (c.id == invite.calendarId || c.remoteId == invite.calendarId),
        )
        .firstOrNull;

class InvitationsPanel extends StatelessWidget {
  final CalendarState state;
  final String query;
  final Future<void> Function(Future<void> Function()) onAction;
  final void Function(Entry) onDetails;
  final void Function(CalendarCollection) onOpenCalendar;
  final VoidCallback onSignIn;
  const InvitationsPanel({
    super.key,
    required this.state,
    required this.query,
    required this.onAction,
    required this.onDetails,
    required this.onOpenCalendar,
    required this.onSignIn,
  });

  bool matches(String text) => text.toLowerCase().contains(query.toLowerCase());

  Widget heading(String text, {int? count, Widget? action}) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 18, 12, 8),
    child: Row(
      children: [
        Expanded(
          child: Text(
            count == null ? text : '$text · $count',
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
          ),
        ),
        if (action != null) action,
      ],
    ),
  );

  Widget card(Color color, List<Widget> children, {Key? key}) => Container(
    key: key,
    margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .06),
      border: Border(left: BorderSide(color: color, width: 4)),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );

  Widget calendarTitle(String name, Color color, {bool shared = false}) => Row(
    children: [
      Icon(
        shared ? Icons.group_outlined : Icons.calendar_month_outlined,
        color: color,
        size: 20,
      ),
      const SizedBox(width: 8),
      Expanded(
        child: Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) {
      final shared =
          state.connected
              ? state.calendars
                  .where(
                    (c) =>
                        c.kind == 'shared' &&
                        c.account == state.account &&
                        matches(c.name),
                  )
                  .toList()
              : <CalendarCollection>[];
      shared.sort((a, b) {
        final order = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        return order == 0 ? a.id.compareTo(b.id) : order;
      });
      final groups =
          state.connected
              ? state.groups
                  .where(
                    (g) =>
                        g['membership'] == 'invite' &&
                        matches(g['name'] as String),
                  )
                  .toList()
              : <Map<String, dynamic>>[];
      final invites =
          state.currentInvitations
              .where(
                (e) => matches(
                  '${e.title} ${e.owner} ${e.description} ${invitationCalendar(state, e)?.name ?? ''}',
                ),
              )
              .toList();
      final sections = <String, List<Entry>>{};
      for (final invite in invites) {
        final calendar = invitationCalendar(state, invite);
        sections.putIfAbsent(calendar?.id ?? '', () => []).add(invite);
      }
      final ordered =
          sections.entries.toList()..sort((a, b) {
            String name(MapEntry<String, List<Entry>> s) =>
                invitationCalendar(state, s.value.first)?.name.toLowerCase() ??
                '\uffff';
            final order = name(a).compareTo(name(b));
            return order == 0 ? a.key.compareTo(b.key) : order;
          });
      return ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  state.connected
                      ? 'Invites refresh automatically.'
                      : 'Sign in to send and receive invites.',
                ),
                if (state.connected)
                  OutlinedButton.icon(
                    onPressed:
                        state.loading ? null : () => onAction(state.sync),
                    icon: const Icon(Icons.sync, size: 16),
                    label: const Text('Sync now'),
                  )
                else
                  TextButton(onPressed: onSignIn, child: const Text('Sign in')),
              ],
            ),
          ),
          if (state.connected && state.usesGravitas && !state.groupsEnabled)
            card(const Color(0xFF426EB4), [
              const Text(
                'Shared calendars need access in this session.',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const Text(
                'Enable access to see calendars you have joined on other devices.',
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed:
                      state.loading
                          ? null
                          : () => onAction(state.enableSharedCalendars),
                  icon: const Icon(Icons.group_outlined, size: 17),
                  label: const Text('Enable shared calendar invites'),
                ),
              ),
            ]),
          if (state.connected) ...[
            heading(
              'Shared calendars',
              count: shared.length,
              action: TextButton.icon(
                key: const ValueKey('invites-create-shared-calendar'),
                onPressed:
                    () => showDialog<void>(
                      context: context,
                      builder:
                          (_) => CalendarDialog(
                            state: state,
                            initialKind: 'shared',
                          ),
                    ),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Create'),
              ),
            ),
            if (shared.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(
                  query.isNotEmpty
                      ? 'No matching shared calendars.'
                      : !state.usesGravitas
                      ? 'Connect to Gravitas to use shared calendars.'
                      : state.groupsEnabled
                      ? 'Calendars you join will appear here.'
                      : 'Enable access above to load your shared calendars.',
                ),
              ),
            for (final c in shared)
              card(collectionColor(c), [
                calendarTitle(c.name, collectionColor(c), shared: true),
                const SizedBox(height: 4),
                Text(
                  c.data['_unavailable'] == true
                      ? 'Access unavailable · sync or enable shared calendars'
                      : c.data['owner'] == state.username
                      ? 'Shared calendar · You own this calendar'
                      : 'Shared calendar · ${c.readOnly ? 'Read only' : 'Member'}',
                  style: const TextStyle(fontSize: 12),
                ),
                Wrap(
                  spacing: 6,
                  children: [
                    TextButton.icon(
                      key: ValueKey('invites-open-${c.id}'),
                      onPressed:
                          c.data['_unavailable'] == true
                              ? null
                              : () => onOpenCalendar(c),
                      icon: const Icon(Icons.calendar_month_outlined, size: 17),
                      label: const Text('View calendar'),
                    ),
                    TextButton(
                      key: ValueKey('invites-settings-${c.id}'),
                      onPressed:
                          () => showDialog<void>(
                            context: context,
                            builder:
                                (_) =>
                                    CalendarDialog(state: state, calendar: c),
                          ),
                      child: const Text('Colour & settings'),
                    ),
                    if (state.canInviteToCalendar(c))
                      TextButton(
                        onPressed: () => inviteToCalendar(context, state, c),
                        child: const Text('Invite people'),
                      ),
                  ],
                ),
              ], key: ValueKey('shared-calendar-card-${c.id}')),
          ],
          if (groups.isNotEmpty) ...[
            heading('Calendar invitations', count: groups.length),
            for (final group in groups)
              card(groupColour(group['id'] as String), [
                calendarTitle(
                  group['name'] as String,
                  groupColour(group['id'] as String),
                  shared: true,
                ),
                const Text(
                  'Shared calendar group invitation',
                  style: TextStyle(fontSize: 12),
                ),
                Wrap(
                  spacing: 6,
                  children: [
                    FilledButton(
                      onPressed:
                          state.loading
                              ? null
                              : () => onAction(
                                () => state.groupAction(
                                  group['id'] as String,
                                  'accept',
                                ),
                              ),
                      child: const Text('Accept'),
                    ),
                    OutlinedButton(
                      onPressed:
                          state.loading
                              ? null
                              : () => onAction(
                                () => state.groupAction(
                                  group['id'] as String,
                                  'leave',
                                ),
                              ),
                      child: const Text('Decline'),
                    ),
                  ],
                ),
              ]),
          ],
          if (invites.isNotEmpty)
            heading('Event invitations', count: invites.length),
          if (invites.isEmpty && groups.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No invitations'),
            ),
          for (final section in ordered) invitationSection(section.value),
        ],
      );
    },
  );

  Widget invitationSection(List<Entry> entries) {
    final calendar = invitationCalendar(state, entries.first);
    final color =
        calendar == null ? const Color(0xFF6B7585) : collectionColor(calendar);
    return card(color, [
      calendarTitle(
        calendar?.name ?? 'Other event invitations',
        color,
        shared: calendar?.kind == 'shared',
      ),
      Text(
        '${entries.length} pending ${entries.length == 1 ? 'invitation' : 'invitations'}',
        style: const TextStyle(fontSize: 12),
      ),
      for (final e in entries) ...[
        const Divider(height: 20),
        Text(
          e.title,
          key: ValueKey('invite-title-${e.id}'),
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        Text(
          '@${e.owner}${e.when == null ? '' : ' · ${DateFormat.yMMMd().format(e.when!)}'}',
          style: const TextStyle(fontSize: 12),
        ),
        if (e.data['_response'] != null)
          Text(
            'Response queued: ${e.data['_response']}',
            style: const TextStyle(fontSize: 12),
          ),
        Wrap(
          spacing: 6,
          children: [
            FilledButton(
              key: ValueKey('accept-invite-${e.id}'),
              onPressed:
                  state.loading
                      ? null
                      : () => onAction(() => state.respond(e, 'accepted')),
              child: const Text('Accept'),
            ),
            OutlinedButton(
              key: ValueKey('decline-invite-${e.id}'),
              onPressed:
                  state.loading
                      ? null
                      : () => onAction(() => state.respond(e, 'declined')),
              child: const Text('Decline'),
            ),
            TextButton(
              onPressed: () => onDetails(e),
              child: const Text('Details'),
            ),
          ],
        ),
      ],
    ], key: ValueKey('invitation-section-${calendar?.id ?? 'other'}'));
  }

  Color groupColour(String id) {
    final known =
        state.calendars
            .where((c) => c.account == state.account && c.groupId == id)
            .firstOrNull;
    if (known != null) return collectionColor(known);
    final index = id.codeUnits.fold(
      0,
      (sum, c) => (sum * 31 + c) % (calendarPalette.length - 1),
    );
    return Color(
      int.parse('FF${calendarPalette[index + 1].substring(1)}', radix: 16),
    );
  }
}
