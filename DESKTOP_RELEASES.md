# Native desktop releases

`Spacetime` ships a real Flutter application for macOS (Intel and Apple Silicon), Windows x64 and Linux x64. The full native runtime is bundled; it does not require a browser, a local development server, Flutter, Node, or Go on the user's computer.

Merge to `main` runs the existing web/Android checks and four native package jobs. Each native job launches the built app and checks local storage/credentials or its packaged Go backend and persistence across relaunch. Deployment waits for those checks. After verified deployment, CI uploads a draft GitHub release, checks the SHA-256 and size of every upload, and publishes `desktop-vX.Y.Z` with `desktop-release.json`, `desktop-changelog.json`, `SHA256SUMS` and four native ZIPs. Repositories with Android release configuration retain mobile as GitHub's latest release; desktop-only repositories mark their new native release as latest automatically. Existing tags are immutable.

Edit `desktop-release.config.json` to increase the desktop `version` and `versionCode` and describe the user-facing changes. Electron's package version must match. Desktop and Android release versions/codes are independent. The configuration also selects the real launch entry in each archive and pins the Flutter or Bun toolchain. There are no per-app Store adapters.

Private Store uses the manifest to filter compatible targets, verify downloads, install the full native bundle in a versioned per-user directory, create a desktop shortcut and update installed apps. All mutable app data and credentials live in the OS application-support/credential directories, outside those versioned binaries. Updates therefore keep calendars, media indexes, workspace documents or reading state. Close and reopen an app to use its new version. There are no desktop background notification requirements.

For a local native build with the pinned toolchain, run `python3 scripts/desktop-build.py linux x64` (or `windows x64`, `macos x64`, `macos arm64`) on that OS. The checked-in runners identify the app consistently across updates. Linux x64 builds use an Ubuntu 22.04/glibc 2.35 baseline and need GTK 3 plus a desktop Secret Service for encrypted credentials. Linux ZIPs include the executable and adjacent libraries/data; extract the whole ZIP before running. macOS and Windows builds currently lack commercial publisher certificates/notarization, so the OS may require first-launch approval. Never bypass a checksum failure.

Validation: `python3 scripts/test-desktop-release.py`; production CI also requires all existing repository tests and the native smoke checks before merge and publication.

Desktop Gravitas sign-in can use Private Store's account broker before the browser.
The vendored `desktop_store_broker.dart` follows the reusable protocol documented at
https://github.com/jeethsuresh/appstore/blob/main/DESKTOP_SIGN_IN.md. Keep the helper
and its binding/cancellation/cold-start tests aligned with the Store SDK.
