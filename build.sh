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
echo "$APP"
