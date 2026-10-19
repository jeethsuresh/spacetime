import 'package:time/time.dart';

import '../frequency.dart';
import '../recurrence_rule.dart';
import '../utils.dart';

DateTime addFrequencyAndInterval(
  RecurrenceRule rrule,
  DateTime currentStart, {
  required bool wereDatesFiltered,
}) {
  assert(currentStart.isValidRruleDateTime);

  if (rrule.frequency == Frequency.yearly) {
    return currentStart._addYears(rrule.actualInterval);
  } else if (rrule.frequency == Frequency.monthly) {
    return currentStart._addMonths(rrule.actualInterval);
  } else if (rrule.frequency == Frequency.weekly) {
    return currentStart._addWeeks(rrule.actualInterval, rrule.actualWeekStart);
  } else if (rrule.frequency == Frequency.daily) {
    return currentStart._addDays(rrule.actualInterval);
  } else if (rrule.frequency == Frequency.hourly) {
    return currentStart._addHours(
      rrule.actualInterval,
      wereDatesFiltered,
      rrule.byHours,
    );
  } else if (rrule.frequency == Frequency.minutely) {
    return currentStart._addMinutes(
      rrule.actualInterval,
      wereDatesFiltered,
      rrule.byHours,
      rrule.byMinutes,
    );
  } else if (rrule.frequency == Frequency.secondly) {
    return currentStart._addSeconds(
      rrule.actualInterval,
      wereDatesFiltered,
      rrule.byHours,
      rrule.byMinutes,
      rrule.bySeconds,
    );
  }

  throw ArgumentError('Unknown frequency: ${rrule.frequency}.');
}

extension _FrequencyIntervalCalculation on DateTime {
  DateTime _addYears(int years) => plusYears(years);

  DateTime _addMonths(int months) => plusMonths(months);

  DateTime _addWeeks(int weeks, int weekStart) {
    final surplusDays = (weekday - weekStart) % DateTime.daysPerWeek;
    return add(weeks.weeks).subtract(surplusDays.days);
  }

  DateTime _addDays(int days) => add(days.days);

  DateTime _addHours(int hours, bool filtered, List<int> byHours) =>
      _addClock(hours * 3600, filtered, byHours, [], []);
  DateTime _addMinutes(
          int minutes, bool filtered, List<int> byHours, List<int> byMinutes) =>
      _addClock(minutes * 60, filtered, byHours, byMinutes, []);
  DateTime _addSeconds(int seconds, bool filtered, List<int> byHours,
          List<int> byMinutes, List<int> bySeconds) =>
      _addClock(seconds, filtered, byHours, byMinutes, bySeconds);
  DateTime _addClock(int seconds, bool filtered, List<int> hours,
      List<int> minutes, List<int> secondValues) {
    var value = this;
    if (filtered) {
      final remaining =
          86399 - value.hour * 3600 - value.minute * 60 - value.second;
      value = value.add(Duration(seconds: (remaining ~/ seconds) * seconds));
    }
    // Clock filters repeat in a day. Preserve the interval phase while applying
    // them together, and terminate impossible combinations without a spin loop.
    final period = 86400 ~/ seconds.gcd(86400);
    for (var i = 0; i < period; i++) {
      value = value.add(Duration(seconds: seconds));
      if ((hours.isEmpty || hours.contains(value.hour)) &&
          (minutes.isEmpty || minutes.contains(value.minute)) &&
          (secondValues.isEmpty || secondValues.contains(value.second))) {
        return value;
      }
    }
    return DateTime.utc(10000);
  }
}
