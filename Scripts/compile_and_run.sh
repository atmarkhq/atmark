#!/usr/bin/env bash
#
# Dev loop: stop the running instance, repackage, relaunch the bundle.
#
# Always run the packaged bundle, never `swift run`. A bare executable has a
# different code signature and bundle identity from Atmark.app, so it neither
# inherits the app's TCC grants nor can meaningfully acquire its own — every
# permission-dependent path would fail or prompt again.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../version.env
source "$ROOT/version.env"

APP="$ROOT/build/${APP_NAME}.app"

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  echo "Stopping running $APP_NAME..."
  pkill -x "$APP_NAME" || true
  # Give the resident process a moment to release its port and endpoint file.
  for _ in $(seq 20); do
    pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
    sleep 0.1
  done
fi

"$ROOT/Scripts/package_app.sh" "${1:-debug}"

echo "Launching $APP..."
open "$APP"
