#!/bin/bash
# Builds build/ClaudeSwitcher.app.
#   --install          copy it to ~/Applications and open it
#   --universal        arm64 + x86_64 (Apple silicon and Intel)
#   --version X.Y.Z    set CFBundleShortVersionString / CFBundleVersion
#   --zip              also write build/ClaudeSwitcher-<version>.zip for a release
set -euo pipefail
cd "$(dirname "$0")/.."

INSTALL=0 UNIVERSAL=0 ZIP=0 VERSION=""
while [ $# -gt 0 ]; do
    case "$1" in
        --install) INSTALL=1 ;;
        --universal) UNIVERSAL=1 ;;
        --zip) ZIP=1 ;;
        --version) VERSION="$2"; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

ARCH_ARGS=()
[ "$UNIVERSAL" = 1 ] && ARCH_ARGS=(--arch arm64 --arch x86_64)

swift build -c release ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}
BIN="$(swift build -c release ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --show-bin-path)/ClaudeSwitcher"

APP=build/ClaudeSwitcher.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/ClaudeSwitcher"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -n "$VERSION" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
fi
codesign --force --sign - "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/ClaudeSwitcher"))"

if [ "$ZIP" = 1 ]; then
    NAME="ClaudeSwitcher-${VERSION:-dev}.zip"
    rm -f "build/$NAME"
    ditto -c -k --keepParent "$APP" "build/$NAME"
    echo "Zipped build/$NAME"
fi

if [ "$INSTALL" = 1 ]; then
    pkill -x ClaudeSwitcher 2>/dev/null || true
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/ClaudeSwitcher.app"
    cp -R "$APP" "$HOME/Applications/"
    open "$HOME/Applications/ClaudeSwitcher.app"
    echo "Installed ~/Applications/ClaudeSwitcher.app"
fi
