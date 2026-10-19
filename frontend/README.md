# Spacetime frontend

Offline-first Flutter calendar. The Android APK needs no Go runtime, server, or account. Events and preferences are stored on the device; recurrence is expanded locally. Network requests occur only when signing in/registering or explicitly syncing. See [the project README](../README.md) for builds, local notifications, manual sync, and CalDAV.

The vendored `packages/rrule` retains its upstream licenses and documents the recurrence fixes in `SPACETIME_CHANGES.md`. Both the Dart calendar and native Android alarm engine are tested against independent recurrence fixtures in `test/fixtures/recurrence.json`.
