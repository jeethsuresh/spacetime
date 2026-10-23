# Recurrence validation

The implementation targets Gregorian iCalendar recurrence from RFC 5545 and the corresponding CalDAV operations in RFC 4791. Optional non-Gregorian RSCALE (RFC 7529) is not advertised. Unsupported rule parts and unsupported collations are rejected explicitly. This document records test evidence; it is not a certification of every CalDAV client or extension.

The final checks passed: **82 Flutter tests in America/Toronto and Pacific/Apia**, Flutter analysis and web release compilation, Go race tests and vet, the independent CalDAV client probe, **10 Android unit tests**, **2 Android notification instrumentation tests**, and the Android Flutter integration test. The signed universal APK was built and verified with Android apksigner.

The automated suites cover the Go CalDAV engine, the offline Dart calendar, and native Android reminder scheduling. Both local recurrence engines are checked against 32 independent python-dateutil vectors covering all seven week starts, intervals, week numbers, negative selectors, BYSETPOS, leap days, and subdaily frequencies. The independent CalDAV client result is saved in `interop/last-result.json`.

Offline state tests reject all network access while exercising startup, CRUD, navigation, recurring exceptions, completion, persistent restore, and disconnect. They also cover atomic-write rollback, concurrent saves, upload/download retries, edits during sync, and explicit conflict resolution. Android integration tests exercise real platform storage, time-zone detection, encrypted per-server sessions, and local alarm scheduling. Native instrumentation tests verify OS notification delivery, schedule restoration, and cancellation without starting a Flutter engine.

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

Flutter tests cover DST-safe grid arithmetic, spring-DST inclusive all-day editing, Samoa’s skipped civil date and daily query range, all four calendar views at four viewport sizes, month bounds beside the desktop sidebar and above the mobile bottom bar, daily isolation, twelve-month yearly display, narrow editors, recurrence serialization, advanced-rule retention, weekday alignment, local occurrence rendering, occasion field omission, visible recurrence options, year view ranges, device preference persistence, setting controls, 12-hour time rendering, Monday-first weeks, header Add event placement, view dropdown selection, narrow search expansion and clearing, keyboard-safe calendar layout, Calendar/Todos/Invites long-press visibility, invite recurrence/deduplication, legacy Agenda preference migration, side-by-side overlap placement, event duration geometry, overnight clipping, and month-end explanations.

Native Android widget tests cover ongoing and next appointments, recurrence skips and distant future instances, multi-day exclusive ends, all-day device dates, and invite visibility/deduplication. Device instrumentation verifies the three launcher providers expose 1×2, 2×2, and 4×1 target sizes with periodic updates disabled, and renders their RemoteViews with calendar data. Widgets use local storage and one non-wakeup boundary alarm, with no network or background synchronization.

## Multiple calendars and source synchronization

The collection tests cover collection-scoped UIDs/resources, per-calendar events and todos, existing default-path migration, collection discovery, author-only shared resources and reported DAV privileges/colours. Isolated IAM fixtures check explicit browser group consent, profile-only login, encrypted family-bound delegated credentials, serialized refresh, joined versus invited/removed access, group reuse and identity-service outages. No production user/group fixtures are created for these checks.

Independent TLS source fixtures exercise CalDAV event/todo reads, canonical read-after-write, completion/deletion, read-only privileges, concurrent ETag conflicts, WebDAV collections, writable multi-entry calendar files, signed-URL redaction/encryption, reconnect ownership, disconnect preserving the source, and incomplete snapshot rollback. iCalendar stream tests preserve other UIDs, calendar objects, METHOD on generic files, unknown fields, VJOURNAL and time zones. Untrusted remote addresses and cross-origin credential redirects are rejected. Sync-token reports are not implemented; complete bounded snapshots are fetched instead. Shared access requires an explicitly authorized selected Gravitas group, and basic-password DAV access does not inherit a browser's group grant.

Flutter tests cover offline multi-calendar persistence, separate event/todo visibility, per-calendar UID matching, ownership restrictions, authoritative server conflicts with retained drafts, metadata conflicts and member-specific local colour overrides. Native widget projections use calendar selections and canonical server conflict versions. The current local Flutter suite contains 141 tests; exact final release evidence is recorded separately with the APK checksum.

## Independent client

`interop/test_caldav.py` uses **python-caldav 3.5.0** and **icalendar 7.3.0**, with server-side expansion and compatibility workarounds disabled. It starts a backend against a temporary database. The probe verifies principal and collection discovery, event/todo writes and reads, DST-aware expansion, RDATE/EXDATE, recurrence IDs, UTC output, extension retention, updates, and deletion. The probe passed during this implementation.

## Remaining certification boundaries

Apple Calendar, Thunderbird, DAVx⁵, and other native clients have not been exercised here. The application has not been independently certified as a complete CalDAV/WebDAV server. Android release builds, platform storage/time-zone detection, and local notifications are exercised; iOS and desktop native builds are not included. Optional scheduling delivery, sync-token reports, and non-Gregorian calendar scales are outside the implemented protocol surface.

A series with detached exceptions cannot be retyped between event/todo or DATE/DATE-TIME through the simple editor without first resolving those exceptions; the server returns a conflict rather than emitting mixed or inconsistent components. Existing exceptions, unknown properties, and calendar identifiers remain intact during ordinary series edits.

Large or infinite recurrence sets are evaluated only within requested windows, with explicit resource-limit errors rather than silent truncation. New tests and independent client suites should extend this evidence before making broader compatibility claims.
