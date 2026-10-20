# Spacetime

An offline calendar for Android and the web, built with Flutter. Events, todos, occasions, recurrence, search, and settings work on the device without an account, internet connection, or Go installation. The optional Go server provides manual event sync, invitations, and CalDAV access.

## Android

Install the signed APK from [GitHub Releases](https://github.com/jeethsuresh/spacetime/releases/latest). Android 6.0 or later is supported. The universal APK includes ARM, ARM64, and x86-64 builds.

The calendar opens immediately. Entries are saved atomically in app-private device storage. Sign in under **Settings → Sync & invites** only if you want to connect a server. Signing in does not upload anything. Tap **Sync now** to upload device changes, fetch server changes, and send/receive invitation responses. Changes made offline remain queued across restarts. Conflicting versions stay on the device until you choose **Keep device version** or **Use server version** in Settings. Disconnecting keeps the calendar and works offline.

Enable **Settings → Reminders → Local notifications**, then choose a reminder when editing an entry. Android schedules alarms locally, including recurring events and due-date reminders. All-day reminders use 9 AM on the device. Editing, skipping, completing, or deleting an entry updates its alarms. Alarm delivery schedules the next occurrence with no fixed lookahead cutoff; OS boot and clock/time-zone broadcasts restore the schedules. There is no background sync, polling, WorkManager job, persistent service, FCM, or other push service. The operating system must permit notifications and alarms; an Android force-stop prevents alarms until the app is opened again.

Server addresses must use HTTPS, with HTTP allowed only for loopback/emulator development. Android bearer tokens are encrypted with an Android Keystore AES-GCM key; passwords are never stored. Reminders and display preferences stay on the device.

Long-press an empty part of the Android home screen, choose **Widgets → Spacetime**, and add **Next appointment (1×2)**, **Today (2×2)**, or **Week ahead (4×1)**. They read the device calendar, including recurring events and exceptions. Today includes events, occasions, and dated todos; Week ahead marks the next seven days. Tap a widget or a date to open the corresponding calendar view. The Invites visibility setting also applies to widgets. Widgets refresh after local edits, device clock changes, and a single OS-scheduled, non-wakeup event/date boundary alarm. They do not poll or connect to a server; the OS can defer boundary refresh while the device sleeps.

## Optional sync server

Requires **Go 1.25+** and **Flutter 3.32+** on PATH.

```sh
./run.sh
# Optional sample accounts and calendar:
./run.sh --demo
```

Open **http://localhost:8080**. Demo accounts are `alex`, `jamie`, and `sam`; the password is `spacetime-demo-2026`. Normal launches create no demo accounts.

Data is stored transactionally in `data/spacetime.db` using bbolt. Existing Daybook databases, account sessions, event IDs, UIDs, and calendar resource paths are retained. If the default database does not exist, startup also finds the previous `data/daybook.db`. Old sample passwords are upgraded only when `--demo` is explicitly used and they still match the known old demo password. Existing user passwords are not overwritten. Stop the process before copying its database for backup.

## Calendar and recurrence

- One compact header, Daily and Weekly time grids, a full-height month, and a twelve-month year with date numbers and event dots. Daily replaces Agenda. Timed blocks show duration and overlapping appointments appear beside each other; all-day items stay above the grid. Overnight events continue on the next day with exclusive end boundaries. Weekly scrolls horizontally on narrow phones. Double-tap an empty time slot to create an event there. The header contains a view dropdown, search, and Add event at the top right. Search becomes a button on narrower screens and expands inline when tapped. On mobile, a bottom bar provides Calendar, Todos, Invites, and Settings; desktop uses a sidebar. Hold Calendar for Events/Occasions visibility, Todos to show/hide todos, or Invites to show/hide invited events on the calendar. Invite visibility is saved on the device, includes pending invitations, and deduplicates accepted events. Right-clicking provides the same menus on desktop, and visibility is also exposed as an accessibility action. These filters do not remove entries from the Todos or Invites pages. The calendar fills the space beside the sidebar or above the bottom bar.
- Optional registration and account connection for manual sync and invitations; no sign-in requirement for the calendar.
- Settings offers a default calendar view, Sunday/Monday week start, and 12/24-hour time. Preferences are saved on the device. Settings also contains local reminders, optional account connection, manual sync, conflict resolution, the device time zone, and CalDAV connection information.
- Events with notes, optional location, and invitations to registered usernames. Invitees accept or decline; accepted events appear in their Flutter and CalDAV calendars.
- Todos with due dates, optional due times, overdue indicators, and completion. Repeating todos have an explicit start before their due date. Completing one occurrence leaves future tasks open.
- Occasions combine birthdays and holidays into one all-day type with **no location, organizer, or invitees**. UI, API, and CalDAV enforce these restrictions. Migration preserves existing UIDs, dates, recurrence rules, and exceptions. Legacy birthday/holiday API values and iCalendar metadata are read as occasions.
- New occasions default to yearly recurrence; all repeat controls remain available. February 29 is skipped in non-leap years rather than moved.
- Visible cadence, interval, day, monthly-pattern, and end controls without dropdowns. Daily, weekly, monthly, and yearly repeats; weekdays/weekends; selected weekdays; positive custom intervals such as every two weeks or three months.
- Monthly patterns: a numbered date, an ordinal weekday, the last chosen weekday, or the last day. Months without the selected date are skipped.
- Never-ending schedules, inclusive end dates, or a count including the first occurrence.
- Upcoming-date previews, extra dates, skipped dates, and individual-occurrence skipping.
- An advanced RFC 5545 RRULE field retains imported rules that do not fit the basic controls.

Flutter expands calendar occurrences locally, including offline previews. The backend expands occurrences for CalDAV. Timed schedules retain their IANA time zone and local clock hour across DST. Floating times stay at the viewer's local hour; all-day dates retain their calendar date. Self-contained VTIMEZONE definitions are exported and imported definitions are honored, including custom TZIDs.

## Standards and interoperability

Recurrence is defined by **[RFC 5545](https://www.rfc-editor.org/rfc/rfc5545)**. `RRULE` defines the pattern, `RDATE` adds instances, `EXDATE` removes instances, and `RECURRENCE-ID` identifies detached exceptions. **[RFC 4791](https://www.rfc-editor.org/rfc/rfc4791)** defines storage and queries over WebDAV. Recurrence instances are not stored as independent unrelated events: a master and its exceptions share one UID and resource.

Implemented behavior includes `INTERVAL`, `COUNT`, correctly typed inclusive `UNTIL`, `WKST`, ordinal and negative BY selectors, duplicate elimination, RDATE PERIOD durations, EXDATE precedence, moved exceptions outside their original query window, and `RANGE=THISANDFUTURE`. Invalid generated dates and nonexistent DST clock times are skipped without consuming COUNT; ambiguous times use the first occurrence. Explicit gap times follow RFC 5545's pre-gap offset interpretation. Nominal DURATION days/weeks are distinguished from exact DTEND/DUE durations. Imported legacy EXRULE is honored but not generated.

CalDAV supports principal/collection discovery, GET/HEAD, PUT, DELETE, calendar-query, calendar-multiget, server-side expansion, limited recurrence retrieval, property/component selection, time/property/parameter filters, relative/repeating alarm queries, and free-busy queries. Expanded date-times use UTC; DATE values retain their type. Conditional writes support ETag lists, correct strong/weak matching, 201 creation versus 204 updates, and no PUT ETag when the server canonicalizes the representation. UID collisions and invalid calendar data return DAV precondition errors.

App edits preserve unknown properties, alarms, timezone definitions, detached exceptions, external organizers/attendees, UIDs, and unchanged RDATE PERIOD or nominal DURATION data. The internal revision and iCalendar SEQUENCE are separate; editing never decreases an imported sequence. Converting an event/todo or DATE/DATE-TIME series that already has detached exceptions is rejected explicitly rather than storing inconsistent components.

See [CONFORMANCE.md](CONFORMANCE.md) for validation evidence and boundaries. The independent Python CalDAV client test runs with client compatibility workarounds disabled. Apple Calendar, Thunderbird, and DAVx⁵ certification has not been performed. This project does not claim implementation of every optional calendaring extension or universal client compatibility.

## Connect a CalDAV client

Use your username/password with HTTP Basic authentication:

```text
Discovery:     http://localhost:8080/.well-known/caldav
Principal:     http://localhost:8080/dav/USERNAME/
Calendar home: http://localhost:8080/dav/USERNAME/calendars/
Calendar URL:  http://localhost:8080/dav/USERNAME/calendars/default/
```

Settings provides a copyable CalDAV URL. Use HTTPS for connections over a network. `VEVENT` represents events and occasions; `VTODO` represents todos. `X-SPACETIME-KIND` identifies special types; old `X-DAYBOOK-KIND` metadata is read for migration. Existing UIDs ending in `@daybook` intentionally keep their identity.

Accepted invitations appear as read-only `invited-*.ics` resources. RSVP actions happen in Spacetime. Invitations are in-app; iTIP/iMIP email delivery and CalDAV scheduling inbox/outbox from RFC 6638 are not implemented. There is one personal calendar per user. Holiday dates are manually entered.

## Development and tests

```sh
cd backend
 go test -race ./...
 go vet ./...
 go run . -seed-demo

# In another terminal:
cd frontend
 flutter test
 flutter analyze
 flutter run -d chrome --web-port 5173 --dart-define=API_BASE=http://localhost:8080
```

For separate frontend development, start Go with `ALLOWED_ORIGINS=http://localhost:5173,http://127.0.0.1:5173`. Use one consistent hostname. The web client uses HttpOnly cookie sessions for explicitly requested sync calls; local data is retained in browser storage. The web build bundles its rendering resources for offline caching after its first successful load. Android packages all runtime assets, saves entries in an atomic private file, and obtains its IANA time zone through the native platform channel. App launch and resume never contact the server.

Build a signed Android release (JDK 17+, Android SDK 35, Flutter 3.32+):

```sh
export JAVA_HOME=/path/to/jdk
export ANDROID_HOME=/path/to/android/sdk
export SPACETIME_KEYSTORE=/private/path/spacetime-release.jks
export SPACETIME_STORE_PASSWORD=...   # keep these out of shell history and source control
export SPACETIME_KEY_PASSWORD=...
./build-android.sh
```

The key alias is `spacetime-release`. Release builds require your release key and never fall back to the debug key. Keep a private backup: future APK updates need the same key. The application ID is `com.jeethsuresh.spacetime`; debug/integration builds use `.dev` and have a separate database.

Additional Android checks:

```sh
cd frontend
flutter test integration_test/android_smoke_test.dart -d DEVICE_ID
cd android
./gradlew :app:testDebugUnitTest :app:connectedDebugAndroidTest
```

The native instrumentation tests grant notification permission to the development package and verify actual OS alarm delivery and cancellation without starting Flutter.

Independent client test:

```sh
python3 -m venv .venv-interop
.venv-interop/bin/pip install -r interop/requirements.txt
(cd backend && go build -o spacetime .)
.venv-interop/bin/python interop/test_caldav.py --binary "$PWD/backend/spacetime"
```

That test starts a separate backend with a temporary database and stops it on exit. It does not change existing calendars.

Environment variables:

- `ADDR`: default `127.0.0.1:8080`.
- `DATA_FILE`: default `../data/spacetime.db` relative to the backend directory, with legacy fallback described above.
- `STATIC_DIR`: default `../frontend/build/web`.
- `ALLOWED_ORIGINS`: explicit comma-separated development origins, empty by default.
- `COOKIE_SECURE=1`: secure cookies and HTTPS origin validation behind a TLS reverse proxy.

For deployment, use HTTPS, omit demo seeding, keep database files private, and configure backups. Passwords use bcrypt, random session tokens are stored as hashes with seven-day expirations, unsafe cross-origin requests are rejected, authentication is rate limited, and writes check ownership and revisions.

## API

- `POST /api/register` — `{username, password, name}`.
- `POST /api/login` — `{username, password}`; returns `{user, token}` and a browser cookie.
- `POST /api/logout`, `GET /api/me`.
- `GET /api/events` — owned and accepted series.
- `GET /api/occurrences?from=RFC3339&to=RFC3339&timezone=IANA` — expanded occurrences, including their original series and stable recurrence identifiers.
- `POST /api/events` — create; `PUT /api/events/{id}` — full organizer update including the current `version`.
- `DELETE /api/events/{id}` — organizer deletion with `If-Match: "VERSION"`.
- `POST /api/recurrence/preview?timezone=IANA` — draft entry; returns upcoming occurrences. Include `id` to preview an existing series while preserving imported calendar data.
- `POST /api/events/{id}/exceptions` — `{version, recurrence_id, operation: "skip" | "complete", completed?}`.
- `POST /api/events/{id}/completion` — `{version, completed}` for nonrepeating todos, including imported undated todos.
- `GET /api/invitations`; `POST /api/events/{id}/respond` — `{status: "accepted" | "declined"}`.

Entry fields include `title`, `description`, `location`, `kind`, `start`, `end`, `due`, `all_day`, `timezone`, `rrule`, `rdates`, `exdates`, `completed`, `attendees`, and `version`. Times use RFC 3339; all-day ends are exclusive. Local authoring fields (`start_local`, `end_local`, `due_local`) use ISO dates or local date-times without offsets and take precedence over the corresponding timestamp. `timezone` resolves them. `until_date` is an inclusive local date converted to the RRULE's required UNTIL type; COUNT and UNTIL cannot be combined. RDATE/EXDATE API values accept calendar dates or ISO date-times. Unchanged imported PERIOD values are preserved.

Occurrence requests are bounded to ten years and 10,000 returned instances. Candidate generation is bounded and cancellable. CalDAV limit failures use 507 and `number-of-matches-within-limits`; JSON requests fail explicitly instead of silently returning truncated schedules. These limits protect against unbounded expansion as required by RFC 4791 security guidance.
