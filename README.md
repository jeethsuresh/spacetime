# Spacetime

An offline calendar for Android and the web, built with Flutter. Events, todos, occasions, recurrence, search, and settings work on the device without an account, internet connection, or Go installation. The optional Go server provides event sync, invitations, and CalDAV access.

## Android

Install the signed APK from [GitHub Releases](https://github.com/jeethsuresh/spacetime/releases/latest). Android 6.0 or later is supported. The universal APK includes ARM, ARM64, and x86-64 builds.

The calendar opens immediately. The optional first-open login can be dismissed with **Login later from settings**. **Log in with gravitas.cool** first checks a signed-in Private Store account on Android 8+. Spacetime pins the store package and signing certificate, then uses the caller-verified, call-only visibility preparation endpoint before requesting a fresh service-specific authorization code. This works immediately when Spacetime is installed after the store account was created. If the broker is absent, account selection is ambiguous, or browser consent/reauthentication is required, it uses the existing system-browser login. **Use browser** selects that path directly; **Create gravitas.cool ID** opens registration. **Use another server** retains password login for self-hosted servers. Android verifies a state-bound, one-use S256 handoff before saving its own encrypted app token; IAM passwords and tokens never enter the app. Signing out of Gravitas disconnects cloud access for the same browser family, while other devices and all offline calendar data remain intact. Entries are saved atomically in app-private device storage. Sign in under **Settings → Sync & invites** only if you want to connect a server. Autosync is the default when logged in. Connecting an account and each saved calendar operation trigger foreground sync: creation, edits, deletions, todo completion, recurrence changes, conflict resolution, and invitation responses. Changes are saved locally first; brief bursts combine into one sync, and edits made during a sync are sent in a follow-up without overlapping requests. Offline failures keep edits queued and retry with a 30-second to five-minute backoff while the app is visible. Hidden or paused apps start no sync work; returning syncs queued changes and fetches updates. Other devices’ changes and incoming invitations are also checked hourly. **Sync now** remains available. Changes made offline remain queued across restarts. Conflicting versions stay on the device until you choose **Keep device version** or **Use server version** in Settings. Disconnecting keeps the calendar and works offline.

Enable **Settings → Reminders → Local notifications**, then choose a reminder when editing an entry. Android schedules alarms locally, including recurring events and due-date reminders. All-day reminders use 9 AM on the device. Editing, skipping, completing, or deleting an entry updates its alarms. Alarm delivery schedules the next occurrence with no fixed lookahead cutoff; OS boot and clock/time-zone broadcasts restore the schedules. Spacetime starts no background sync, polling, WorkManager job, persistent service or FCM connection. With a signed Private Store installed and the same Gravitas account connected, event invitations and updates arrive over the store’s shared native listener. Spacetime verifies the store and current account, then posts a native notification without starting Flutter or fetching data. Enable **Settings → Sync & invites → Enable invite & event notifications**. The store pauses its direct connection in Doze, so delivery may wait until networking resumes. The operating system must permit notifications and alarms; an Android force-stop prevents alarms until the app is opened again.

Server addresses must use HTTPS, with HTTP allowed only for loopback/emulator development. Android bearer tokens are encrypted with an Android Keystore AES-GCM key; passwords are never stored. Reminders and display preferences stay on the device.

Previously linked Gravitas accounts renew an expired seven-day Spacetime session through the verified broker while the app is visible. Renewal must match the stored account, subject, and original IAM family; the old app bearer goes only to Spacetime over HTTPS and is consumed after successful renewal. It never opens a browser automatically. Transient failures keep encrypted credentials and offline work, with one recovery in flight and a persistent two-minute foreground retry cooldown. Confirmed revocation or an account mismatch requires explicit login. Disconnect cancels pending login and remains effective across restarts. Signed-out native launch and resume do not contact cloud authentication.

Long-press an empty part of the Android home screen, choose **Widgets → Spacetime**, and add **Next appointment (1×2)**, **Today (2×2)**, or **Week ahead (4×1)**. They read the device calendar, including recurring events and exceptions. Today includes events, occasions, and dated todos; Week ahead marks the next seven days. Tap a widget or a date to open the corresponding calendar view. The Invites visibility setting also applies to widgets. Widgets refresh after local edits, device clock changes, and a single OS-scheduled, non-wakeup event/date boundary alarm. They do not poll or connect to a server; the OS can defer boundary refresh while the device sleeps.

## Optional sync server

At **https://spacetime.gravitas.cool**, the web app reuses a connected Gravitas browser session through the platform's authorization-code/PKCE flow. A first connection may require permission to share your profile name. Signed-out visitors get a login modal with **Login later from settings**; dismissing it leaves the calendar fully usable and remembers that choice. Both the modal and Settings link to **Create gravitas.cool ID** at `https://gravitas.cool/register`. Disconnecting suppresses automatic reconnection until you request login again. Connected accounts sync automatically after login and every saved operation in the foreground; the web app uses its own origin without displaying or asking for a server address.

Gravitas passwords and IAM cookies remain on the identity site. Spacetime exchanges a one-use code server-side, requests only `profile.name`, and issues its own host-only, HttpOnly session. A status-only family credential is encrypted server-side and checked with IAM for every protected request. Visible clients also check every 15 seconds and on resume; no session checks run in the background. Confirmed revocation disconnects cloud access, while temporary IAM failures preserve the cached account and offline edits. Accounts are keyed by the stable issuer/subject pair; matching usernames never automatically merge an existing local account. The shared platform currently uses its custom IAM discovery/PKCE protocol, not OpenID Connect. Local-account login and CalDAV Basic authentication remain available for existing clients; Gravitas-only accounts do not acquire a local password or CalDAV password through SSO.

Requires **Go 1.25+** and **Flutter 3.32+** on PATH.

```sh
./run.sh
# Optional sample accounts and calendar:
./run.sh --demo
```

Open **http://localhost:8080**. Demo accounts are `alex`, `jamie`, and `sam`; the password is `spacetime-demo-2026`. Normal launches create no demo accounts.

Data is stored transactionally in `data/spacetime.db` using bbolt. Existing Daybook databases, account sessions, event IDs, UIDs, and calendar resource paths are retained. If the default database does not exist, startup also finds the previous `data/daybook.db`. Old sample passwords are upgraded only when `--demo` is explicitly used and they still match the known old demo password. Existing user passwords are not overwritten. Stop the process before copying its database for backup.

Account creation requires a server-configured invite key. Set `REGISTRATION_INVITE_KEY` in the server environment before registering; when it is unset, registration is disabled. Existing users sign in with just their username and password. Offline use needs neither an account nor an invite key.

## Calendar and recurrence

- One compact header, Daily and Weekly time grids, a full-height month, and a twelve-month year with date numbers and event dots. Daily replaces Agenda. Timed blocks show duration and overlapping appointments appear beside each other; all-day items stay above the grid. Overnight events continue on the next day with exclusive end boundaries. Weekly scrolls horizontally on narrow phones. Double-tap an empty time slot to create an event there. The header contains a view dropdown, search, and Add event at the top right. Search becomes a button on narrower screens and expands inline when tapped. A bottom bar provides Calendar, Todos, Invites, and Settings on phones and desktop. Swipe up from the bar or tap its handle to expand a bottom drawer with independent show/hide controls for each calendar and todo list, including shared calendars. Drag the drawer upward to expand it, scroll through long lists, and drag down, tap outside, or use Close to dismiss it. Swipe horizontally across the month or scroll sideways with a trackpad to move between months; each gesture snaps to a complete month. Hold Calendar or Todos to open the corresponding section of the drawer. Hold Invites to show or hide invited events on the calendar. Invite visibility is saved on the device, includes pending invitations, and deduplicates accepted events. Right-clicking provides the same menus on desktop, and visibility is also exposed as an accessibility action. Hiding a todo list also hides its entries from the Todos page. Invite visibility does not remove entries from the Invites page. The calendar fills the width above the bottom bar.
- Optional registration and account connection for per-operation foreground autosync and invitations; no sign-in requirement for the calendar.
- Settings offers a default calendar view, Sunday/Monday week start, and 12/24-hour time. Preferences are saved on the device. Settings also contains local reminders, optional account connection, per-operation autosync, Sync now, conflict resolution, the device time zone, and CalDAV connection information.
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

## Calendars and sharing

Swipe up from the bottom bar or tap its handle to open **Calendars & todos** on phones and desktop. Hold **Calendar** or **Todos** to open the drawer with that section first. Use **+** in the drawer to create a personal calendar, share one through Gravitas, or connect a CalDAV, WebDAV folder, or iCalendar URL. Each calendar has a name, colour, event checkbox and independent todo-list checkbox, including shared calendars. Visibility choices are saved on this device. New entries use the selected calendar; the editor can choose another writable calendar.

Personal calendars work fully offline. Connecting a source or setting up sharing requires a server account. Shared calendars ask for explicit Gravitas group consent in the browser; the Android account broker continues to request profile access only. Choose an existing joined group to reuse it, or create a new group. **Invite to calendar** sends a group invitation. Invitees accept under **Invites** before the calendar becomes accessible. All joined members can create entries; only an entry's creator can edit or remove it, including todo completion and recurrence exceptions. Calendar owners cannot modify other members' entries. Selecting a group does not duplicate it.

Source connections belong to the Go server, which stores source credentials and complete source URLs encrypted. Client metadata shows only the source origin. Clients keep an offline cache without those credentials. Each discovered source calendar becomes its own calendar and todo list. Foreground sync pulls source changes; permitted edits are sent to the source with strong ETag conditions and read back in its canonical form. Read-only sources remain read-only. A conflicting source/server version is shown in the calendar while unsent device edits remain recoverable in Settings. Failed or incomplete imports retain the last complete cache. Source synchronization runs on foreground requests, without a background worker or push service. Disconnecting a source removes its Spacetime cache without deleting the original source calendar.

Sources require HTTPS, verified certificates and same-origin resource URLs/redirects. Private, loopback, link-local, metadata and reserved addresses are denied by default. Self-hosted operators can explicitly allow a trusted internal host with `CALENDAR_REMOTE_ALLOWED_HOSTS`; never allow untrusted hosts. Source snapshots are bounded to 16 MiB, 2,000 resources and 10,000 series. Back up the database and its encryption key together: `CALENDAR_SECRET_KEY` (base64 32 bytes), the existing `GRAVITAS_SESSION_KEY`, or the generated private `DATA_FILE.calendar-key` when neither is configured. Losing the key requires reconnecting sources. The hosted deployment permits public source HTTPS on ports 443 and 8443; other ports require an operator policy change.

## Connect a CalDAV client

Use your username/password with HTTP Basic authentication:

```text
Discovery:     http://localhost:8080/.well-known/caldav
Principal:     http://localhost:8080/dav/USERNAME/
Calendar home: http://localhost:8080/dav/USERNAME/calendars/
Calendar URL:  http://localhost:8080/dav/USERNAME/calendars/default/
```

Settings provides a copyable CalDAV URL. Use HTTPS for connections over a network. `VEVENT` represents events and occasions; `VTODO` represents todos. `X-SPACETIME-KIND` identifies special types; old `X-DAYBOOK-KIND` metadata is read for migration. Existing UIDs ending in `@daybook` intentionally keep their identity.

Accepted invitations appear as read-only `invited-*.ics` resources. RSVP actions happen in Spacetime. Invitations are available in-app and as Android alerts through Private Store; iTIP/iMIP email delivery and CalDAV scheduling inbox/outbox from RFC 6638 are not implemented. Each calendar has a distinct collection URL and UID namespace. Holiday dates are manually entered.

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

For separate frontend development, start Go with `ALLOWED_ORIGINS=http://localhost:5173,http://127.0.0.1:5173`. Use one consistent hostname. The web client uses HttpOnly cookie sessions; local data is retained in browser storage. The web build bundles its rendering resources for offline caching after its first successful load. The hosted Gravitas web app performs a foreground session check at page startup and can navigate through shared login; connected accounts sync on login, saved operations and return to the app, plus hourly refreshes while visible. Android packages all runtime assets, saves entries in an atomic private file, and obtains its IANA time zone through the native platform channel. Signed-out Android launch and resume never contact the server. Connected accounts autosync queued changes when reopened, with no background task.

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

Increasing both the version name and build number and merging to `main` automatically tests, signs and publishes the Android release using the original key in GitHub’s main-only `android-release` environment. See [signed Android releases](ANDROID_RELEASES.md) for verification builds and secret maintenance.

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
- `REGISTRATION_INVITE_KEY`: expected invite key for local account creation only. Unset or empty disables local registration; existing login, sync and CalDAV remain available. Keep the value outside source control; Gravitas injects it from a Kubernetes Secret. Authenticated Gravitas identities are provisioned separately after IAM login and approval.
- `GRAVITAS_ISSUER`: optional trusted HTTPS IAM origin, such as `https://gravitas.cool`. Enables the server-side PKCE integration. Metadata and token/profile endpoints must remain on this origin; redirects are not followed.
- `PUBLIC_URL`: exact HTTPS Spacetime origin for the callback. Required with `GRAVITAS_ISSUER`.
- `GRAVITAS_SESSION_KEY`: base64 encoded 32 random bytes, required with Gravitas login. Keep this persistent server secret outside the repository and back it up separately from the database. It encrypts the status-only IAM session proofs; losing or replacing it requires logging in again. IAM must advertise `session_check_endpoint` and issue family-bound session proofs. Every cloud request checks the family with IAM; a confirmed revocation returns 401, temporary IAM failures return 503. Offline calendars are retained.
- `NOTIFICATION_STORE_URL`: optional trusted HTTPS Private Store origin. Pair with `NOTIFICATION_PROVIDER_KEY` (at least 32 random characters), using the same key as the store’s `NOTIFICATION_APP_KEYS=spacetime=KEY`. Store the key outside source control. The backend registers issuer/subject-bound providers, persists event notification callbacks atomically, and retries server-side without phone polling. Hosted manifests use the optional `spacetime-notifications` Secret’s `provider-key`; the store uses `appstore-notifications` / `app-keys`.
- `GRAVITAS_GATEWAY_ADDR`: optional private ingress host:port for IAM connections. HTTPS still validates the public issuer's certificate and hostname. Gravitas uses the private Traefik service to avoid public load-balancer hairpin routing.

For deployment, use HTTPS, omit demo seeding, keep database files private, and configure backups. Passwords use bcrypt, random session tokens are stored as hashes with seven-day expirations, unsafe cross-origin requests are rejected, authentication is rate limited, and writes check ownership and revisions.

## API

- `POST /api/auth/gravitas/broker` — redeem an Appstore-issued IAM authorization code with the native verifier, expected session family, and stable subject. The server independently checks the pinned IAM profile and live family proof, returning only its own app bearer/user. Optional `recovery:true` requires the expired prior app bearer in Authorization and an exact stored subject/family/user match; successful recovery consumes that prior session. Protected API responses distinguish `session_expired` from `gravitas_session_revoked` and `session_invalid` with `error_code`, without revealing identity to anonymous callers.
- `POST /api/auth/gravitas/android` — redeem a one-minute, one-use native handoff with its S256 verifier for an app bearer. The browser callback carries no bearer or IAM credential.
- `GET /api/auth/config` — whether Gravitas login is enabled, plus login/registration URLs.
- `GET /auth/gravitas/start` — interactive browser login; `?prompt=none` performs a passive session check.
- `GET /auth/gravitas/callback` — state- and browser-bound one-use code or error callback, followed by a clean app redirect. No access token enters the URL or browser storage.

- `POST /api/register` — `{username, password, name, invite_key}`. A missing or wrong key returns 403; an unconfigured server returns 503.
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

### Username sign-in

Sign in by entering your username and pressing **🔥** (or Enter). A bare name
such as `alice` uses the identity server configured by `GRAVITAS_ISSUER`, which
also owns the registration button. The Gravitas deployment uses `gravitas.cool`.
`alice@example.org`, `alice:example.org` and `@alice:example.org` select that
public domain's compatible IAM service over HTTPS. Registration always stays on
the configured default server. Login transactions and app sessions retain the
selected issuer, including subsequent session-revocation checks.
