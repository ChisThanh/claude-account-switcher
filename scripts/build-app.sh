#!/bin/bash
# Builds build/ClaudeSwitcher.app. With --install, copies it to ~/Applications and opens it.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/ClaudeSwitcher"

APP=build/ClaudeSwitcher.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/ClaudeSwitcher"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
    pkill -x ClaudeSwitcher 2>/dev/null || true
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/ClaudeSwitcher.app"
    cp -R "$APP" "$HOME/Applications/"
    open "$HOME/Applications/ClaudeSwitcher.app"
    echo "Installed ~/Applications/ClaudeSwitcher.app"
fi
