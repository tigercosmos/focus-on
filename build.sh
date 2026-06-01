#!/bin/bash
#
# Builds the FocusOn executable with SwiftPM, then assembles it into a menu bar
# app bundle at build/FocusOn.app. Requires the Swift toolchain (swift build),
# which ships with the Xcode Command Line Tools.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$DIR/build/FocusOn.app"

echo "==> Building FocusOn (SwiftPM, release)"
( cd "$DIR" && swift build -c release --product FocusOn )
BIN="$DIR/.build/release/FocusOn"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$DIR/app/Info.plist" "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/FocusOn"

echo "    Built: $APP"
