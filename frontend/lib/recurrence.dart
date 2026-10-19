import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

const weekdays = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];
const weekdayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

class RepeatDraft {
  String preset = 'none',
      frequency = 'WEEKLY',
      monthly = 'date',
      ending = 'never',
      advanced = '';
  int interval = 1, count = 10;
  Set<String> days = {};
  DateTime? until;
  RepeatDraft();
  RepeatDraft.from(String rule, DateTime start, {String? untilDate}) {
    days = {weekdays[start.weekday - 1]};
    if (rule.isEmpty) return;
    final parts = {
      for (final part in rule.split(';'))
        if (part.contains('='))
          part.split('=').first: part.substring(part.indexOf('=') + 1),
    };
    frequency = parts['FREQ'] ?? 'WEEKLY';
    interval = int.tryParse(parts['INTERVAL'] ?? '1') ?? 1;
    preset =
        {
          'DAILY': 'daily',
          'WEEKLY': 'weekly',
          'MONTHLY': 'monthly',
          'YEARLY': 'yearly',
        }[frequency] ??
        'custom';
    if (parts['BYDAY'] != null) days = parts['BYDAY']!.split(',').toSet();
    if (frequency == 'WEEKLY' &&
        days.length == 5 &&
        days.containsAll(weekdays.take(5))) {
      preset = 'weekdays';
    }
    if (frequency == 'WEEKLY' &&
        days.length == 2 &&
        days.containsAll(['SA', 'SU'])) {
      preset = 'weekends';
    }
    if (parts['COUNT'] != null) {
      ending = 'count';
      count = int.tryParse(parts['COUNT']!) ?? 10;
    }
    if (parts['UNTIL'] != null) {
      ending = 'date';
      final v =
          untilDate ??
          '${parts['UNTIL']!.substring(0, 4)}-${parts['UNTIL']!.substring(4, 6)}-${parts['UNTIL']!.substring(6, 8)}';
      until = DateTime.tryParse(v);
    }
    final common = {'FREQ', 'INTERVAL', 'COUNT', 'UNTIL', 'WKST'};
    if (frequency == 'WEEKLY') common.add('BYDAY');
    if (frequency == 'MONTHLY') {
      if (parts['BYMONTHDAY'] == '-1') {
        monthly = 'lastday';
        common.add('BYMONTHDAY');
      } else if (parts['BYDAY'] == '-1${weekdays[start.weekday - 1]}') {
        monthly = 'lastweekday';
        common.add('BYDAY');
      } else if (parts['BYDAY'] ==
          '${(start.day - 1) ~/ 7 + 1}${weekdays[start.weekday - 1]}') {
        monthly = 'ordinal';
        common.add('BYDAY');
      }
    }
    if (parts.keys.any((k) => !common.contains(k)) ||
        (parts['WKST'] != null && parts['WKST'] != 'MO')) {
      preset = 'custom';
    }
    advanced = rule;
  }
  String rule(DateTime start) {
    if (preset == 'none') return '';
    if (preset == 'custom') return advanced.trim().toUpperCase();
    final freq =
        {
          'daily': 'DAILY',
          'weekly': 'WEEKLY',
          'weekdays': 'WEEKLY',
          'weekends': 'WEEKLY',
          'monthly': 'MONTHLY',
          'yearly': 'YEARLY',
        }[preset]!;
    final parts = ['FREQ=$freq', if (interval != 1) 'INTERVAL=$interval'];
    if (freq == 'WEEKLY') {
      final selected =
          preset == 'weekdays'
              ? weekdays.take(5).toSet()
              : preset == 'weekends'
              ? {'SA', 'SU'}
              : days;
      parts.add('BYDAY=${weekdays.where(selected.contains).join(',')}');
      parts.add('WKST=MO');
    }
    if (freq == 'MONTHLY') {
      if (monthly == 'ordinal') {
        parts.add(
          'BYDAY=${(start.day - 1) ~/ 7 + 1}${weekdays[start.weekday - 1]}',
        );
      }
      if (monthly == 'lastweekday') {
        parts.add('BYDAY=-1${weekdays[start.weekday - 1]}');
      }
      if (monthly == 'lastday') parts.add('BYMONTHDAY=-1');
    }
    if (ending == 'count') parts.add('COUNT=$count');
    return parts.join(';');
  }

  DateTime align(DateTime start) {
    DateTime date(
      int year,
      int month,
      int day, [
      int hour = 0,
      int minute = 0,
      int second = 0,
    ]) =>
        start.isUtc
            ? DateTime.utc(year, month, day, hour, minute, second)
            : DateTime(year, month, day, hour, minute, second);
    if (['weekly', 'weekdays', 'weekends'].contains(preset)) {
      final selected =
          preset == 'weekdays'
              ? weekdays.take(5).toSet()
              : preset == 'weekends'
              ? {'SA', 'SU'}
              : days;
      for (var i = 0; i < 7; i++) {
        final next = date(
          start.year,
          start.month,
          start.day + i,
          start.hour,
          start.minute,
          start.second,
        );
        if (selected.contains(weekdays[next.weekday - 1])) return next;
      }
    }
    if (preset == 'monthly' && monthly == 'lastday') {
      return date(start.year, start.month + 1, 0, start.hour, start.minute);
    }
    if (preset == 'monthly' && monthly == 'lastweekday') {
      var d = start;
      while (date(d.year, d.month, d.day + 7).month == d.month) {
        d = date(d.year, d.month, d.day + 7, d.hour, d.minute);
      }
      return d;
    }
    return start;
  }
}

class RepeatEditor extends StatelessWidget {
  final RepeatDraft draft;
  final DateTime start;
  final VoidCallback onChanged;
  final bool disabled;
  const RepeatEditor({
    super.key,
    required this.draft,
    required this.start,
    required this.onChanged,
    this.disabled = false,
  });

  Widget choice(String label, bool selected, VoidCallback action) => ChoiceChip(
    label: Text(label, style: const TextStyle(fontSize: 12)),
    selected: selected,
    showCheckmark: false,
    onSelected: disabled ? null : (_) => action(),
    padding: EdgeInsets.zero,
    labelPadding: const EdgeInsets.symmetric(horizontal: 8),
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    visualDensity: VisualDensity.compact,
  );

  @override
  Widget build(BuildContext context) {
    final repeating = draft.preset != 'none',
        week = ['weekly', 'weekdays', 'weekends'].contains(draft.preset);
    const labels = {
      'none': 'None',
      'daily': 'Daily',
      'weekly': 'Weekly',
      'weekdays': 'Weekdays',
      'weekends': 'Weekends',
      'monthly': 'Monthly',
      'yearly': 'Yearly',
      'custom': 'RRULE',
    };
    final unit =
        week
            ? 'weeks'
            : draft.preset == 'daily'
            ? 'days'
            : draft.preset == 'monthly'
            ? 'months'
            : 'years';
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F5EE),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Repeat',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final e in labels.entries)
                choice(e.value, draft.preset == e.key, () {
                  draft.preset = e.key;
                  if (draft.days.isEmpty) {
                    draft.days = {weekdays[start.weekday - 1]};
                  }
                  onChanged();
                }),
            ],
          ),
          if (repeating && draft.preset != 'custom') ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('Every', style: TextStyle(fontSize: 12)),
                const SizedBox(width: 8),
                SizedBox(
                  width: 56,
                  child: TextFormField(
                    key: ValueKey('interval-${draft.preset}'),
                    initialValue: '${draft.interval}',
                    enabled: !disabled,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      isDense: true,
                      contentPadding: EdgeInsets.all(8),
                    ),
                    validator:
                        (v) =>
                            (int.tryParse(v ?? '') ?? 0) < 1 ? 'Use 1+' : null,
                    onChanged: (v) {
                      draft.interval = int.tryParse(v) ?? 0;
                      onChanged();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  draft.interval == 1
                      ? unit.substring(0, unit.length - 1)
                      : unit,
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
            if (week) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 3,
                runSpacing: 3,
                children: [
                  for (var i = 0; i < 7; i++)
                    choice(
                      weekdayNames[i],
                      draft.preset == 'weekdays'
                          ? i < 5
                          : draft.preset == 'weekends'
                          ? i >= 5
                          : draft.days.contains(weekdays[i]),
                      () {
                        if (draft.preset == 'weekdays') {
                          draft.days = weekdays.take(5).toSet();
                        }
                        if (draft.preset == 'weekends') {
                          draft.days = {'SA', 'SU'};
                        }
                        draft.preset = 'weekly';
                        draft.days.contains(weekdays[i])
                            ? draft.days.remove(weekdays[i])
                            : draft.days.add(weekdays[i]);
                        onChanged();
                      },
                    ),
                ],
              ),
            ],
            if (draft.preset == 'monthly') ...[
              const SizedBox(height: 8),
              const Text('On', style: TextStyle(fontSize: 12)),
              const SizedBox(height: 4),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final p
                      in {
                        'date': 'Day ${start.day}',
                        'ordinal':
                            '${(start.day - 1) ~/ 7 + 1}${['st', 'nd', 'rd'].elementAtOrNull((start.day - 1) ~/ 7) ?? 'th'} ${DateFormat.E().format(start)}',
                        'lastweekday': 'Last ${DateFormat.E().format(start)}',
                        'lastday': 'Last day',
                      }.entries)
                    choice(p.value, draft.monthly == p.key, () {
                      draft.monthly = p.key;
                      onChanged();
                    }),
                ],
              ),
              if (draft.monthly == 'date' && start.day > 28)
                const Padding(
                  padding: EdgeInsets.only(top: 5),
                  child: Text(
                    'Months without this date are skipped.',
                    style: TextStyle(fontSize: 11, color: Color(0xFF788279)),
                  ),
                ),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('Ends', style: TextStyle(fontSize: 12)),
                for (final e
                    in {
                      'never': 'Never',
                      'date': 'On date',
                      'count': 'After count',
                    }.entries)
                  choice(e.value, draft.ending == e.key, () {
                    draft.ending = e.key;
                    draft.until ??= DateTime(
                      start.year,
                      start.month + 3,
                      start.day,
                    );
                    onChanged();
                  }),
              ],
            ),
            if (draft.ending == 'count')
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    SizedBox(
                      width: 70,
                      child: TextFormField(
                        key: const ValueKey('count'),
                        initialValue: '${draft.count}',
                        enabled: !disabled,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.all(8),
                        ),
                        validator:
                            (v) =>
                                (int.tryParse(v ?? '') ?? 0) < 1
                                    ? 'Use 1+'
                                    : null,
                        onChanged: (v) {
                          draft.count = int.tryParse(v) ?? 0;
                          onChanged();
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'occurrences, including the first',
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ),
            if (draft.ending == 'date')
              TextButton.icon(
                onPressed:
                    disabled
                        ? null
                        : () async {
                          final date = await showDatePicker(
                            context: context,
                            initialDate: draft.until ?? start,
                            firstDate: DateTime(1900),
                            lastDate: DateTime(2200),
                          );
                          if (date != null) {
                            draft.until = date;
                            onChanged();
                          }
                        },
                icon: const Icon(Icons.calendar_today_outlined, size: 14),
                label: Text(
                  DateFormat.yMMMd().format(draft.until ?? start),
                  style: const TextStyle(fontSize: 12),
                ),
              ),
          ],
          if (draft.preset == 'custom')
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextFormField(
                initialValue: draft.advanced,
                enabled: !disabled,
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: 'iCalendar RRULE',
                  helperText: 'RFC 5545 · no RRULE: prefix',
                  isDense: true,
                ),
                onChanged: (v) {
                  draft.advanced = v;
                  onChanged();
                },
              ),
            ),
        ],
      ),
    );
  }
}
