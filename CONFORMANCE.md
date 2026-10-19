# Recurrence validation

The implementation targets Gregorian iCalendar recurrence from RFC 5545 and the corresponding CalDAV operations in RFC 4791. Optional non-Gregorian RSCALE (RFC 7529) is not advertised. Unsupported rule parts and unsupported collations are rejected explicitly. This document records test evidence; it is not a certification of every CalDAV client or extension.

The final validation run passed **the Go suite with race detection**, **26 Flutter tests in both America/Toronto and Pacific/Apia**, `go vet`, Flutter analysis, and the Flutter web release build. The independent client result is saved in `interop/last-result.json`.

## Automated coverage

The backend suite includes published-style recurrence examples and regression tests for:

- Daily counts; every two weeks with multiple weekdays and explicit week starts; every three months; weekdays and weekends.
- Numbered month dates that do not exist in every month, leap-day birthdays, ordinal weekdays, last business days using BYSETPOS, negative selectors, hourly intervals, and expansion more than 290 years from DTSTART.
- Inclusive DATE and DATE-TIME UNTIL; mutually exclusive COUNT/UNTIL; invalid intervals, ranges, duplicate rule parts, and invalid combinations of BY selectors.
- DST gaps skipped without consuming COUNT, repeated clock times choosing their first occurrence, fixed local hours across DST, explicit gap interpretation, and floating-time interpretation in the viewer's zone.
- Exact DTEND duration versus nominal day-based DURATION; repeated-day and elapsed-hour differences over DST.
- RDATE/EXDATE set behavior, duplicate elimination, exclusion of DTSTART, RDATE PERIOD durations, and expansion that does not mutate the source calendar.
- Detached moved occurrences queried outside their original window; THISANDFUTURE rescheduling and changed duration; skipping a range anchor while retaining future rescheduling.
- Events overlapping the start of a query and exclusive end boundaries; VTODO time-range boundary cases from RFC 4791's table.
- Generated self-contained VTIMEZONE definitions, including stable future recurrence behavior hundreds of years ahead.
- API recurrence creation, local end-date authoring, per-occurrence todo completion, undated imported tasks, occasion field restrictions and legacy-type migration, and ownership/version checks.
- CalDAV discovery, query/expanded retrieval, recurrence IDs, UTC expansion, source retrieval, UID uniqueness, ETag conflicts, weak conditional GET, multi-ETag writes, relative alarm queries, free-busy generation, and default REPORT properties.
- App edits preserving imported alarms, extension properties, UID, RDATE PERIOD, and unchanged nominal DURATION.

Flutter tests cover DST-safe grid arithmetic, spring-DST inclusive all-day editing, Samoa’s skipped civil date and daily query range, all four calendar views at four viewport sizes, month bounds beside the desktop sidebar and above the mobile bottom bar, daily agenda isolation, twelve-month yearly display, narrow editors, recurrence serialization, advanced-rule retention, weekday alignment, backend-expanded occurrence rendering, occasion field omission, visible recurrence options, year query ranges, account-scoped preference persistence, setting controls, 12-hour time rendering, Monday-first weeks, header Add event placement, view dropdown selection, narrow search expansion and clearing, keyboard-safe calendar layout, Calendar/Todos long-press visibility, and month-end explanations.

## Independent client

`interop/test_caldav.py` uses **python-caldav 3.5.0** and **icalendar 7.3.0**, with server-side expansion and compatibility workarounds disabled. It starts a backend against a temporary database. The probe verifies principal and collection discovery, event/todo writes and reads, DST-aware expansion, RDATE/EXDATE, recurrence IDs, UTC output, extension retention, updates, and deletion. The probe passed during this implementation.

## Remaining certification boundaries

Apple Calendar, Thunderbird, DAVx⁵, and other native clients have not been exercised here. The application has not been independently certified as a complete CalDAV/WebDAV server. Native Flutter builds and their platform time-zone detection are not validated. Optional scheduling delivery, sync-token reports, multiple calendar collections, and non-Gregorian calendar scales are outside the implemented protocol surface.

A series with detached exceptions cannot be retyped between event/todo or DATE/DATE-TIME through the simple editor without first resolving those exceptions; the server returns a conflict rather than emitting mixed or inconsistent components. Existing exceptions, unknown properties, and calendar identifiers remain intact during ordinary series edits.

Large or infinite recurrence sets are evaluated only within requested windows, with explicit resource-limit errors rather than silent truncation. New tests and independent client suites should extend this evidence before making broader compatibility claims.
