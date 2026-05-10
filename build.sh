#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/LG TV Control.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
BIN="$ROOT/build/bin"

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES" "$BIN"

cp "$ROOT/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/Assets/AppIcon.icns" "$RESOURCES/AppIcon.icns"

swift build \
  --package-path "$ROOT" \
  -c release

cp "$ROOT/.build/release/LGTVControl" "$MACOS/LGTVControl"
cp "$ROOT/.build/release/LGTVControl" "$BIN/lgtv"

chmod +x "$MACOS/LGTVControl"
chmod +x "$BIN/lgtv"

CODESIGN_IDENTITY="${LGTV_CODESIGN_IDENTITY:-LG TV Control Dev}"
if security find-identity -p codesigning -v | grep -q "$CODESIGN_IDENTITY"; then
  codesign -s "$CODESIGN_IDENTITY" --force --identifier io.github.li-yifei.lgtv-control "$MACOS/LGTVControl"
  codesign -s "$CODESIGN_IDENTITY" --force --identifier io.github.li-yifei.lgtv-control "$BIN/lgtv"
else
  echo "Warning: '$CODESIGN_IDENTITY' not found. Falling back to ad-hoc signing." >&2
  echo "Run ./scripts/setup-codesign.sh for stable Keychain access." >&2
  codesign -s - --force --identifier io.github.li-yifei.lgtv-control "$MACOS/LGTVControl"
  codesign -s - --force --identifier io.github.li-yifei.lgtv-control "$BIN/lgtv"
fi
ZIP="$ROOT/build/LG-TV-Control.app.zip"
rm -f "$ZIP"
(cd "$ROOT/build" && /usr/bin/ditto -c -k --keepParent "LG TV Control.app" "$ZIP")

echo "$APP"
echo "$ZIP"
