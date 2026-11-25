#!/bin/bash
# Builds build/Nightshift.app (release, ad-hoc signed).
#   scripts/build-app.sh            build only
#   scripts/build-app.sh --install  also copy to /Applications
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product Nightshift
BIN="$(swift build -c release --show-bin-path)/Nightshift"

APP=build/Nightshift.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Nightshift"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - --timestamp=none "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x Nightshift 2>/dev/null || true
    rm -rf /Applications/Nightshift.app
    ditto "$APP" /Applications/Nightshift.app
    echo "Installed /Applications/Nightshift.app"
fi
