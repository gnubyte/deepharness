#!/bin/bash
# Assemble the SPM executable into a launchable macOS .app bundle.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/DSH.app"
BIN_NAME="DSHMacApp"

echo "==> building ($CONFIG)"
swift build -c "$CONFIG" --package-path "$ROOT" >/dev/null

BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/$BIN_NAME"
[ -f "$BIN" ] || { echo "missing binary: $BIN" >&2; exit 1; }

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DSH"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>DSH</string>
  <key>CFBundleDisplayName</key>     <string>DSH</string>
  <key>CFBundleIdentifier</key>      <string>dev.local.dsh.mac</string>
  <key>CFBundleVersion</key>         <string>1</string>
  <key>CFBundleShortVersionString</key> <string>0.1</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleExecutable</key>      <string>DSH</string>
  <key>LSMinimumSystemVersion</key>  <string>14.0</string>
  <key>NSHighResolutionCapable</key> <true/>
  <!-- The harness runs on loopback without TLS, so the app must be allowed
       to reach http://127.0.0.1 while ATS still governs everything else. -->
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key> <true/>
  </dict>
</dict>
</plist>
PLIST

# Ad-hoc sign so the app launches without a developer identity.
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "   (unsigned — Gatekeeper may prompt on first launch)"

echo "==> done: $APP"
