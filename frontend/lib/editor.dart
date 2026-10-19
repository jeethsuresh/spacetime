import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'models.dart';
import 'recurrence.dart';

class EntryEditor extends StatefulWidget {
  final CalendarState state;
  final DateTime date;
  final Entry? entry;
  final String initialKind;
  const EntryEditor({
    super.key,
    required this.state,
    required this.date,
    this.entry,
    this.initialKind = 'event',
  });
  @override
  State<EntryEditor> createState() => _EntryEditorState();
}

class _EntryEditorState extends State<EntryEditor> {
  final formKey = GlobalKey<FormState>();
  late final title = TextEditingController(text: widget.entry?.title ?? '');
  late final location = TextEditingController(
    text: widget.entry?.location ?? '',
  );
  late final notes = TextEditingController(
    text: widget.entry?.description ?? '',
  );
  late final people = TextEditingController(
    text: widget.entry?.attendees.keys.join(', ') ?? '',
  );
  late final timezone = TextEditingController(
    text: widget.entry?.timezone ?? widget.state.timezone,
  );
  late String kind = widget.entry?.kind ?? widget.initialKind;
  late bool allDay = widget.entry?.allDay ?? (kind != 'event');
  DateTime local(String key, DateTime fallback) {
    final raw = widget.entry?.data['${key}_local'] as String?;
    if (raw == null || raw.isEmpty) return fallback;
    return DateTime.parse(
      allDay && raw.length == 10
          ? '${raw}T00:00:00Z'
          : allDay && !raw.endsWith('Z')
          ? '${raw}Z'
          : raw,
    );
  }

  late DateTime start = local(
    'start',
    widget.entry?.start ??
        (allDay
            ? DateTime.utc(widget.date.year, widget.date.month, widget.date.day)
            : DateTime(
              widget.date.year,
              widget.date.month,
              widget.date.day,
              9,
            )),
  );
  late DateTime end = local(
    'end',
    widget.entry?.end ??
        (allDay
            ? DateTime.utc(widget.date.year, widget.date.month, widget.date.day)
            : DateTime(
              widget.date.year,
              widget.date.month,
              widget.date.day,
              10,
            )),
  );
  late DateTime due = local(
    'due',
    widget.entry?.due ??
        (allDay
            ? DateTime.utc(widget.date.year, widget.date.month, widget.date.day)
            : DateTime(
              widget.date.year,
              widget.date.month,
              widget.date.day,
              17,
            )),
  );
  late RepeatDraft repeat = RepeatDraft.from(
    widget.entry?.rrule ?? (kind == 'occasion' ? 'FREQ=YEARLY' : ''),
    start,
    untilDate: widget.entry?.data['until_date'] as String?,
  );
  late List<String> extra = List<String>.from(
    widget.entry?.data['rdates'] as List? ?? [],
  );
  late List<String> skipped = List<String>.from(
    widget.entry?.data['exdates'] as List? ?? [],
  );
  bool saving = false, previewing = false;
  String? error;
  List<Map<String, dynamic>> preview = [];
  bool get special => kind == 'occasion';
  bool get repeating => repeat.preset != 'none';
  @override
  void initState() {
    super.initState();
    if (allDay) {
      start = day(start);
      end = day(end);
      due = day(due);
    }
    if (allDay && widget.entry?.end != null) {
      end = DateTime.utc(end.year, end.month, end.day - 1);
    }
    if (day(end).isBefore(day(start))) end = start;
  }

  @override
  void dispose() {
    for (final c in [title, location, notes, people, timezone]) {
      c.dispose();
    }
    super.dispose();
  }

  void changed() {
    setState(() {
      preview = [];
      error = null;
    });
  }

  DateTime wall(DateTime d) =>
      DateTime.utc(d.year, d.month, d.day, d.hour, d.minute, d.second);
  DateTime fromWall(DateTime d) =>
      allDay
          ? DateTime.utc(d.year, d.month, d.day, d.hour, d.minute, d.second)
          : DateTime(d.year, d.month, d.day, d.hour, d.minute, d.second);
  void alignSchedule() {
    final next = repeat.align(start);
    final shift = wall(next).difference(wall(start));
    start = next;
    end = fromWall(wall(end).add(shift));
    due = fromWall(wall(due).add(shift));
    if (kind == 'todo' &&
        repeating &&
        (allDay ? !day(due).isAfter(day(start)) : !due.isAfter(start))) {
      due =
          allDay
              ? DateTime.utc(start.year, start.month, start.day + 1)
              : start.add(const Duration(hours: 1));
    }
  }

  Future<DateTime?> pick(DateTime current) async {
    final chosen = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(1900),
      lastDate: DateTime(2200),
    );
    if (chosen == null || !mounted) return null;
    if (allDay) return day(chosen);
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
      builder:
          (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(alwaysUse24HourFormat: widget.state.use24Hour),
            child: child!,
          ),
    );
    if (time == null) return null;
    return DateTime(
      chosen.year,
      chosen.month,
      chosen.day,
      time.hour,
      time.minute,
    );
  }

  String localStamp(DateTime d) =>
      allDay
          ? DateFormat('yyyy-MM-dd').format(d)
          : DateFormat("yyyy-MM-dd'T'HH:mm:ss").format(d);
  String stamp(DateTime d) =>
      allDay
          ? DateTime.utc(d.year, d.month, d.day).toIso8601String()
          : d.toUtc().toIso8601String();
  Map<String, dynamic> payload() {
    final names = people.text
        .split(',')
        .map((s) => s.trim().replaceFirst(RegExp(r'^@'), '').toLowerCase())
        .where((s) => s.isNotEmpty);
    final last = allDay ? DateTime.utc(end.year, end.month, end.day + 1) : end;
    return {
      if (widget.entry != null) 'id': widget.entry!.id,
      'title': title.text.trim(),
      'description': notes.text.trim(),
      'location': special ? '' : location.text.trim(),
      'kind': kind,
      'all_day': allDay,
      'timezone': allDay ? 'UTC' : timezone.text.trim(),
      'rrule': repeat.rule(start),
      'yearly': false,
      'until_date':
          repeat.preset != 'custom' && repeat.ending == 'date' && repeating
              ? DateFormat('yyyy-MM-dd').format(repeat.until ?? start)
              : '',
      'rdates': extra,
      'exdates': skipped,
      'completed': widget.entry?.completed ?? false,
      'attendees':
          special ? <String, String>{} : {for (final n in names) n: 'pending'},
      'version': widget.entry?.version ?? 0,
      if (kind != 'todo' || repeating) ...{
        'start': stamp(start),
        'start_local': localStamp(start),
      },
      if (kind != 'todo') ...{
        'end': stamp(last),
        'end_local': localStamp(last),
      },
      if (kind == 'todo') ...{'due': stamp(due), 'due_local': localStamp(due)},
    };
  }

  bool validate() {
    if (!formKey.currentState!.validate()) return false;
    if (repeat.preset == 'weekly' && repeat.days.isEmpty) {
      setState(() => error = 'Select at least one weekday.');
      return false;
    }
    alignSchedule();
    if (kind != 'todo' &&
        (allDay ? day(end).isBefore(day(start)) : !end.isAfter(start))) {
      setState(() => error = 'Choose an end after the start.');
      return false;
    }
    return true;
  }

  Future<void> save() async {
    if (!validate()) return;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.state.save(payload(), id: widget.entry?.id);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          saving = false;
          error = e.toString();
        });
      }
    }
  }

  Future<void> previewSchedule() async {
    if (!validate()) return;
    setState(() {
      previewing = true;
      error = null;
    });
    try {
      final values = await widget.state.api.request(
        'POST',
        '/api/recurrence/preview?timezone=${Uri.encodeQueryComponent(widget.state.timezone)}',
        payload(),
      );
      if (mounted) {
        setState(
          () =>
              preview =
                  (values as List)
                      .map((v) => Map<String, dynamic>.from(v as Map))
                      .toList(),
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => previewing = false);
    }
  }

  Future<void> addDate(List<String> dates) async {
    final d = await pick(start);
    if (d == null || !mounted) return;
    String value;
    if (allDay) {
      value = DateFormat('yyyy-MM-dd').format(d);
    } else {
      value = localStamp(d);
    }
    setState(() {
      if (!dates.contains(value)) dates.add(value);
      preview = [];
    });
  }

  Widget dateButton(
    String label,
    DateTime date,
    void Function(DateTime) update,
  ) => OutlinedButton.icon(
    onPressed:
        saving
            ? null
            : () async {
              final d = await pick(date);
              if (d != null && mounted) {
                setState(() {
                  update(d);
                  preview = [];
                  error = null;
                });
              }
            },
    icon: const Icon(Icons.calendar_today_outlined, size: 16),
    label: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 10, color: Color(0xFF788279)),
        ),
        const SizedBox(height: 5),
        Text(
          allDay
              ? DateFormat.yMMMd().format(date)
              : DateFormat(
                widget.state.use24Hour
                    ? 'MMM d, y · HH:mm'
                    : 'MMM d, y · h:mm a',
              ).format(date),
          style: const TextStyle(fontSize: 12),
        ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(10),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 680),
      child: SingleChildScrollView(
        padding: EdgeInsets.all(
          MediaQuery.sizeOf(context).width < 600 ? 12 : 18,
        ),
        child: Form(
          key: formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.entry == null ? 'New entry' : 'Edit entry',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w500,
                        letterSpacing: -.8,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close editor',
                    onPressed: saving ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close, size: 20),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 7,
                runSpacing: 7,
                children: [
                  for (final k in kinds)
                    ChoiceChip(
                      label: Text(
                        {
                          'event': 'Event',
                          'todo': 'Todo',
                          'occasion': 'Occasion',
                        }[k]!,
                        style: const TextStyle(fontSize: 12),
                      ),
                      selected: kind == k,
                      onSelected:
                          saving
                              ? null
                              : (_) {
                                setState(() {
                                  if (kind == k) return;
                                  kind = k;
                                  if (special) {
                                    allDay = true;
                                    start = day(start);
                                    end = day(end);
                                    due = day(due);
                                    location.clear();
                                    people.clear();
                                  }
                                  if (kind == 'occasion') {
                                    repeat = RepeatDraft.from(
                                      'FREQ=YEARLY',
                                      start,
                                    );
                                  }
                                  preview = [];
                                  error = null;
                                });
                              },
                    ),
                ],
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: title,
                autofocus: widget.entry == null,
                maxLength: 200,
                decoration: InputDecoration(
                  labelText: 'Title',
                  counterText: '',
                ),
                validator:
                    (v) =>
                        v == null || v.trim().isEmpty ? 'Add a title.' : null,
              ),
              if (!special)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    kind == 'todo' ? 'Use dates without times' : 'All day',
                    style: const TextStyle(fontSize: 13),
                  ),
                  value: allDay,
                  onChanged:
                      saving
                          ? null
                          : (v) {
                            setState(() {
                              allDay = v;
                              if (!allDay) {
                                start = DateTime(
                                  start.year,
                                  start.month,
                                  start.day,
                                  9,
                                );
                                end = DateTime(
                                  end.year,
                                  end.month,
                                  end.day,
                                  10,
                                );
                                due = DateTime(
                                  due.year,
                                  due.month,
                                  due.day,
                                  17,
                                );
                              }
                              if (allDay) {
                                start = day(start);
                                end = day(end);
                                due = day(due);
                              }
                              alignSchedule();
                              preview = [];
                            });
                          },
                ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  if (kind != 'todo' || repeating)
                    dateButton('START', start, (d) {
                      final shift = wall(d).difference(wall(start));
                      start = d;
                      end = fromWall(wall(end).add(shift));
                      due = fromWall(wall(due).add(shift));
                    }),
                  if (kind != 'todo')
                    dateButton(
                      allDay ? 'LAST DAY' : 'END',
                      end,
                      (d) => end = d,
                    ),
                  if (kind == 'todo') dateButton('DUE', due, (d) => due = d),
                ],
              ),
              if (!allDay) ...[
                const SizedBox(height: 10),
                TextFormField(
                  controller: timezone,
                  decoration: const InputDecoration(
                    labelText: 'Time zone',
                    hintText: 'America/Toronto',
                    helperText:
                        'Keeps the same local hour through daylight saving changes',
                  ),
                  onChanged: (_) => changed(),
                ),
              ],
              const SizedBox(height: 10),
              RepeatEditor(
                draft: repeat,
                start: start,
                disabled: saving,
                onChanged: () {
                  setState(() {
                    alignSchedule();
                    preview = [];
                    error = null;
                  });
                },
              ),
              if (repeating || extra.isNotEmpty || skipped.isNotEmpty) ...[
                const SizedBox(height: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final group in [
                      ('Extra dates', extra),
                      ('Skipped dates', skipped),
                    ])
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  group.$1,
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                              TextButton.icon(
                                onPressed: () => addDate(group.$2),
                                icon: const Icon(Icons.add, size: 14),
                                label: const Text('Add date'),
                              ),
                            ],
                          ),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final value in group.$2)
                                InputChip(
                                  label: Text(
                                    value,
                                    style: const TextStyle(fontSize: 10),
                                  ),
                                  onDeleted: () {
                                    setState(() {
                                      group.$2.remove(value);
                                      preview = [];
                                    });
                                  },
                                ),
                            ],
                          ),
                        ],
                      ),
                  ],
                ),
                OutlinedButton.icon(
                  onPressed: saving || previewing ? null : previewSchedule,
                  icon: const Icon(Icons.event_repeat, size: 17),
                  label: Text(
                    previewing ? 'Checking dates…' : 'Preview upcoming dates',
                  ),
                ),
                if (preview.isNotEmpty)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(top: 12),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF3F5EE),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'UPCOMING',
                          style: TextStyle(
                            fontSize: 10,
                            letterSpacing: 1.2,
                            color: Color(0xFF788279),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 14,
                          runSpacing: 2,
                          children: [
                            for (final item in preview)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 4,
                                ),
                                child: Text(
                                  _previewLabel(item),
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
              ],
              const SizedBox(height: 10),
              if (!special) ...[
                if (kind == 'event') ...[
                  TextFormField(
                    controller: location,
                    maxLength: 500,
                    decoration: const InputDecoration(
                      labelText: 'Location (optional)',
                      prefixIcon: Icon(Icons.place_outlined, size: 19),
                      counterText: '',
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                TextFormField(
                  controller: people,
                  decoration: const InputDecoration(
                    labelText: 'Invite people (optional)',
                    hintText: 'jamie, sam',
                    helperText: 'Spacetime usernames, separated by commas',
                    prefixIcon: Icon(Icons.people_outline, size: 19),
                  ),
                ),
                const SizedBox(height: 10),
              ],
              TextFormField(
                controller: notes,
                minLines: 1,
                maxLines: 5,
                maxLength: 10000,
                decoration: const InputDecoration(
                  labelText: 'A few notes (optional)',
                  alignLabelWithHint: true,
                  counterText: '',
                ),
              ),
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
              const SizedBox(height: 26),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                alignment: WrapAlignment.end,
                children: [
                  TextButton(
                    onPressed: saving ? null : () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: saving ? null : save,
                    child: Text(
                      saving
                          ? 'Saving…'
                          : widget.entry == null
                          ? 'Create entry'
                          : 'Save series',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
  String _previewLabel(Map<String, dynamic> item) {
    final raw =
        (item[kind == 'todo' ? 'due_local' : 'start_local'] ??
                item[kind == 'todo' ? 'due' : 'start'])
            as String?;
    if (raw == null) return 'Undated';
    final d = DateTime.parse(raw);
    return allDay
        ? DateFormat('EEE, MMM d, y').format(d)
        : '${DateFormat(widget.state.use24Hour ? 'EEE, MMM d, y · HH:mm' : 'EEE, MMM d, y · h:mm a').format(d)} · ${timezone.text}';
  }
}
