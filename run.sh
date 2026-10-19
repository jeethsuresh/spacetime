#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ "${1:-}" != "" && "${1:-}" != "--demo" ]]; then
  echo 'Usage: ./run.sh [--demo]'
  exit 1
fi
command -v go >/dev/null || { echo 'Go 1.25 or newer is required.'; exit 1; }
command -v flutter >/dev/null || { echo 'Flutter 3.32 or newer is required.'; exit 1; }
(cd frontend && flutter pub get && flutter build web --release --no-pub --no-web-resources-cdn)
cd backend
go build -o spacetime .
if [[ "${1:-}" == "--demo" ]]; then
  exec ./spacetime -seed-demo
else
  exec ./spacetime
fi
