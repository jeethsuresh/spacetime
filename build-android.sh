#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/frontend"
: "${SPACETIME_KEYSTORE:?Set the private release keystore path}"
: "${SPACETIME_STORE_PASSWORD:?Set the release keystore password}"
: "${SPACETIME_KEY_PASSWORD:?Set the release key password}"
# Do not use --no-pub here: Flutter must regenerate release-only plugin registration.
flutter build apk --release "$@"
