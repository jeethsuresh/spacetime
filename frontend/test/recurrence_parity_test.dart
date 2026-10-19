import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:spacetime/local_recurrence.dart';

void main() {
  final fixtures =
      jsonDecode(File('test/fixtures/recurrence.json').readAsStringSync())
          as Map;
  for (final raw in fixtures['cases'] as List) {
    final fixture = raw as Map;
    test('Independent recurrence parity: ${fixture['name']}', () {
      final event = {
        'all_day': false,
        'timezone': 'UTC',
        'start_local': fixture['start'],
        'rrule': fixture['rule'],
      };
      final dates =
          recurrenceDates(
                event,
                parseWall(fixture['upper'] as String),
                after: parseWall(fixture['lower'] as String),
              )
              .where((d) => d.isBefore(parseWall(fixture['upper'] as String)))
              .map((d) => wallString(d, false))
              .toList();
      expect(dates, fixture['expected']);
    });
  }
}
