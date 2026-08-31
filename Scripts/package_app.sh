#!/usr/bin/env bash
#
# Build and assemble Atmark.app, then sign it with the stable local identity.
#
# There is no ad-hoc signing path. The upstream template falls back to
# `codesign --sign -` when no identity is configured; that fallback is removed
# deliberately. An ad-hoc signature has no stable designated requirement, so
# every rebuild would look like a different program to TCC and quietly drop the
# user's Automation and Full Disk Access grants. Failing loudly is the only safe
# behaviour here.

set -euo pipefail

CONF=${1:-release}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

# shellcheck source=../version.env
source "$ROOT/version.env"

ARCH=$(uname -m)
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/${APP_NAME}.app"

# --- Resolve the signing identity before doing any work ----------------------

IDENTITY_LINE=$(security find-identity -v -p codesigning 2>/dev/null \
                | grep -F "$SIGNING_IDENTITY" || true)

if [[ -z "$IDENTITY_LINE" ]]; then
  cat >&2 <<MSG
ERROR: no valid code-signing identity named '$SIGNING_IDENTITY'.

Run Scripts/setup_dev_signing.sh once to create it.

Refusing to fall back to ad-hoc signing: an ad-hoc signature would build
successfully and then silently invalidate every TCC permission granted to
Atmark.app, which surfaces later as unexplained permission failures.
MSG
  exit 1
fi

if [[ $(grep -c . <<<"$IDENTITY_LINE") -ne 1 ]]; then
  echo "ERROR: '$SIGNING_IDENTITY' is ambiguous — multiple identities match:" >&2
  echo "$IDENTITY_LINE" >&2
  echo "Resolve this in Keychain Access; signing with the wrong one breaks TCC." >&2
  exit 1
fi

# Sign by SHA-1 rather than by name so the result cannot be ambiguous.
IDENTITY_HASH=$(awk '{print $2}' <<<"$IDENTITY_LINE")

# --- Build -------------------------------------------------------------------

swift build -c "$CONF" --arch "$ARCH"

PRODUCT_DIR=".build/${ARCH}-apple-macosx/${CONF}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

install_binary() {
  local src="$PRODUCT_DIR/$1"
  local dest="$2"
  if [[ ! -f "$src" ]]; then
    echo "ERROR: missing build product $src" >&2
    exit 1
  fi
  cp "$src" "$dest"
  chmod +x "$dest"
}

# The bundle executable is named after the app; the SwiftPM product is AtmarkApp.
install_binary AtmarkApp   "$APP/Contents/MacOS/${APP_NAME}"
# The shim ships inside the bundle so there is one artifact to install and
# clients have a stable path to point at.
install_binary atmark-shim "$APP/Contents/MacOS/atmark-shim"

# --- Info.plist --------------------------------------------------------------

LSUI_VALUE="false"
[[ "${MENU_BAR_APP:-0}" == "1" ]] && LSUI_VALUE="true"

GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${MARKETING_VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>${MACOS_MIN_VERSION}</string>
    <key>LSUIElement</key><${LSUI_VALUE}/>
    <key>NSAppleEventsUsageDescription</key><string>Atmark controls other apps on your Mac to answer questions and make the changes you ask an AI assistant for.</string>
    <key>NSRemindersFullAccessUsageDescription</key><string>Atmark reads and edits your reminders so an AI assistant can work with them on your behalf.</string>
    <key>GitCommit</key><string>${GIT_COMMIT}</string>
</dict>
</plist>
PLIST

# --- Sign --------------------------------------------------------------------

# AppleDouble files break code sealing; strip extended attributes first.
chmod -R u+w "$APP"
xattr -cr "$APP"
find "$APP" -name '._*' -delete

# Nested binaries are signed before the bundle that contains them.
codesign --force --sign "$IDENTITY_HASH" "$APP/Contents/MacOS/atmark-shim"
codesign --force --sign "$IDENTITY_HASH" "$APP"

# No --options runtime: hardened runtime exists to satisfy notarization, which
# is permanently out of scope for this project (O2), and it would add an
# entitlement requirement for the Apple Events this app is built to send.

codesign --verify --deep --strict "$APP"

echo "Created $APP"
echo "Signed with: $SIGNING_IDENTITY ($IDENTITY_HASH)"
