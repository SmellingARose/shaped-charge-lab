#!/usr/bin/env bash
# Build a self-contained, ad-hoc signed "Shaped Charge Lab.app" and a drag-to-Applications .dmg.
#   packaging/macos/make_dmg.sh <build-dir> [out-dir]
# Env: SCL_SIGN_IDENTITY  codesign identity (default "-" = ad-hoc). A "Developer ID Application: ..." identity signs
#                         with the hardened runtime and a secure timestamp, ready for notarization.
set -euo pipefail
BUILD=${1:?build dir}
OUT=${2:-$BUILD/dist}
HERE=$(cd "$(dirname "$0")" && pwd)
SRC_APP="$BUILD/app/Shaped Charge Lab.app"
[[ -d "$SRC_APP" ]] || { echo "missing $SRC_APP (build the app first)"; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$SRC_APP/Contents/Info.plist")
IDENTITY=${SCL_SIGN_IDENTITY:--}

MACDEPLOYQT=$(grep '^SCL_MACDEPLOYQT:' "$BUILD/CMakeCache.txt" | cut -d= -f2- || true)
[[ -x "$MACDEPLOYQT" ]] || MACDEPLOYQT=$(command -v macdeployqt)

mkdir -p "$OUT"
STAGE="$OUT/stage"
rm -rf "$STAGE" && mkdir -p "$STAGE"
ditto "$SRC_APP" "$STAGE/Shaped Charge Lab.app"
APP="$STAGE/Shaped Charge Lab.app"
cp "$BUILD/core/scl_smoke" "$APP/Contents/MacOS/scl_smoke"   # headless benchmark travels inside the bundle

"$MACDEPLOYQT" "$APP" -qmldir="$HERE/../../app/qml" -executable="$APP/Contents/MacOS/scl_smoke" -always-overwrite
# macdeployqt copies the whole QtQuick QML tree, so QtQuick.LocalStorage brings in QtSql and every SQL driver plug-in.
# The app uses no SQL, and Qt's prebuilt drivers link client libraries of the Qt build host (ODBC, PostgreSQL, Mimer).
rm -rf "$APP/Contents/PlugIns/sqldrivers"

# Sign inside-out (dylibs / plugins, frameworks, helpers, then the bundle). --deep is deprecated for signing.
SIGN=(codesign --force --sign "$IDENTITY")
if [[ "$IDENTITY" != "-" ]]; then SIGN+=(--options runtime --timestamp --entitlements "$HERE/entitlements.plist"); fi
find "$APP/Contents" \( -name '*.dylib' -o -name '*.so' \) -type f -print0 | xargs -0 -n1 "${SIGN[@]}"
find "$APP/Contents/Frameworks" -maxdepth 1 -name '*.framework' -print0 | xargs -0 -n1 "${SIGN[@]}"
"${SIGN[@]}" "$APP/Contents/MacOS/scl_smoke"
"${SIGN[@]}" "$APP"
codesign --verify --strict --deep --verbose=2 "$APP"

# No binary in the bundle (executables, frameworks, plugins, QML plugins) may load anything by absolute path except
# the OS (/usr/lib, /System): everything else must be bundled and referenced through @rpath/@loader_path/@executable_path.
BAD=0
while IFS= read -r -d '' f; do
  if file -b "$f" | grep -q 'Mach-O'; then
    if otool -L "$f" | tail -n +2 | grep -vE '^[[:space:]]*(@|/usr/lib/|/System/)|:$' >/dev/null; then
      echo "error: $f links a non-bundled library:"; otool -L "$f" | tail -n +2 | grep -vE '^[[:space:]]*(@|/usr/lib/|/System/)|:$'
      BAD=1
    fi
  fi
done < <(find "$APP/Contents" -type f -print0)
(( BAD == 0 )) || exit 1

# Fixed name so the README can link to releases/latest/download/ShapedChargeLab-macOS.dmg
DMG="$OUT/ShapedChargeLab-macOS.dmg"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Shaped Charge Lab $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
[[ "$IDENTITY" == "-" ]] || codesign --force --sign "$IDENTITY" --timestamp "$DMG"
rm "$STAGE/Applications"
echo "$DMG"
