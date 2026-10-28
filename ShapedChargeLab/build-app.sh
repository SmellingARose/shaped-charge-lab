#!/bin/zsh
# Builds ShapedChargeLab.app (release, Apple Silicon) next to this script.
set -e
cd "$(dirname "$0")"
swift build -c release
APP=ShapedChargeLab.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ShapedChargeLab "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Shaped Charge Lab</string>
  <key>CFBundleDisplayName</key><string>Shaped Charge Lab</string>
  <key>CFBundleIdentifier</key><string>local.shapedchargelab</string>
  <key>CFBundleExecutable</key><string>ShapedChargeLab</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $PWD/$APP"
