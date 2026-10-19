#!/bin/zsh
# Builds AirZapper.app. Pass --open to launch it afterwards.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/AirZapper.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"

swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
  -framework AppKit -framework SwiftUI -framework CoreMotion -framework ApplicationServices \
  Sources/*.swift -o "$APP/Contents/MacOS/AirZapper"

# Sign with a real (even self-signed) identity so the Accessibility grant survives rebuilds.
# Falls back to ad-hoc, which makes macOS forget the grant on every rebuild.
IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/"/ { print $2; exit }')}
codesign --force --sign "${IDENTITY:--}" --identifier local.wildgunman.AirZapper "$APP"
echo "Built $PWD/$APP"

if [[ "${1:-}" == "--open" ]]; then
  pkill -x AirZapper 2>/dev/null || true
  while pgrep -qx AirZapper; do sleep 0.2; done
  open "$APP"
fi
