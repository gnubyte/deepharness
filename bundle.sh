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

# Copy the logo assets into the bundle (app icon + in-app logo).
cp "$ROOT/assets/logo/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/assets/logo/logo.png"     "$APP/Contents/Resources/Logo.png"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>DSH</string>
  <key>CFBundleDisplayName</key>     <string>DSH</string>
  <key>CFBundleIdentifier</key>      <string>dev.local.dsh.mac</string>
  <key>CFBundleVersion</key>         <string>1</string>
  <key>CFBundleShortVersionString</key> <string>0.2</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleExecutable</key>      <string>DSH</string>
  <key>CFBundleIconFile</key>        <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>  <string>14.0</string>
  <key>NSHighResolutionCapable</key> <true/>
  <!-- Model servers on your own network (a DGX Spark, vLLM, Ollama, LM Studio)
       speak plain HTTP. NSAllowsLocalNetworking permits loopback, .local, and
       private-range addresses while ATS still governs the public internet. -->
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key> <true/>
  </dict>
  <!-- The agent reads and writes the project folder you open, and the
       integrated terminal runs your login shell there. -->
  <key>NSDesktopFolderUsageDescription</key>
  <string>DSH opens project folders you choose so the agent can read and edit them.</string>
  <key>NSDocumentsFolderUsageDescription</key>
  <string>DSH opens project folders you choose so the agent can read and edit them.</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>DSH opens project folders you choose so the agent can read and edit them.</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so the app launches without a developer identity.
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "   (unsigned — Gatekeeper may prompt on first launch)"

# Build a distributable DMG (app + an Applications drag target).
DMG="$ROOT/build/DeepHarness.dmg"
STAGE="$(mktemp -d)/dmg"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
echo "==> building DMG ($DMG)"
hdiutil create -volname "DeepHarness" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
rm -rf "$(dirname "$STAGE")"

echo "==> done: $APP"
echo "==> done: $DMG"
