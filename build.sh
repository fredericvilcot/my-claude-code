#!/bin/zsh
# Builds "My Claude Code.app" into ./build and optionally installs it: ./build.sh [--install]
set -euo pipefail
cd "$(dirname "$0")"
APP="build/My Claude Code.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/tmp build/swiftterm
# SwiftTerm (vendored terminal emulator) is its own module, built once and rebuilt only when its sources change.
ST=build/swiftterm
if [[ ! -f $ST/libSwiftTerm.a || -n $(find Vendor/SwiftTerm/Sources -newer $ST/libSwiftTerm.a -name '*.swift' | head -1) ]]; then
  swiftc -O -parse-as-library -target arm64-apple-macos14.0 -module-name SwiftTerm \
    -emit-module -emit-module-path $ST/SwiftTerm.swiftmodule -emit-library -static -o $ST/libSwiftTerm.a \
    Vendor/SwiftTerm/Sources/**/*.swift
fi
swiftc -O -parse-as-library -target arm64-apple-macos14.0 \
  -I $ST -L $ST -lSwiftTerm \
  -framework AppKit -framework SwiftUI -framework Charts -framework ServiceManagement -framework Speech -framework AVFoundation \
  Sources/**/*.swift -o "$APP/Contents/MacOS/MyClaudeCode"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ ! -f build/AppIcon.icns || Resources/MakeIcon.swift -nt build/AppIcon.icns ]]; then
  rm -rf build/tmp/AppIcon.iconset
  swift Resources/MakeIcon.swift build/tmp/AppIcon.iconset
  iconutil -c icns build/tmp/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Stable local identity (login keychain) keeps macOS privacy permissions across rebuilds; ad-hoc otherwise.
IDENTITY=$(security find-identity -p codesigning 2>/dev/null | awk '/"Local Menu Apps Signing"/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" --timestamp=none "$APP"
echo "Built $APP"
if [[ "${1:-}" == "--install" ]]; then
  DEST=/Applications; [[ -w $DEST ]] || DEST="$HOME/Applications"
  mkdir -p "$DEST"
  pkill -x MyClaudeCode 2>/dev/null || true; sleep 0.5
  rm -rf "$DEST/My Claude Code.app"; cp -R "$APP" "$DEST/"
  open "$DEST/My Claude Code.app" --args --open
  echo "Installed to $DEST/My Claude Code.app"
fi
