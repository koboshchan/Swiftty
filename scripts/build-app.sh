#!/bin/zsh
# Build, package, relaunch, and check Swiftty's idle process state.
set -euo pipefail

ROOT_DIR="${0:A:h}/.."
cd "$ROOT_DIR"

# Keep the diagnostic output from the requested command, without treating a
# clean build (and therefore no grep matches) as a failure.
swift build --disable-sandbox 2>&1 | grep -E "error:" -A3 | head -10 || true
echo "=== build done ==="

pkill -9 -f "Swiftty" 2>/dev/null || true

BIN_DIR="$(swift build --disable-sandbox --show-bin-path)"
APP_DIR="$ROOT_DIR/build/Swiftty.app"

mkdir -p "$APP_DIR/Contents/MacOS"
cp "$BIN_DIR/Swiftty" "$APP_DIR/Contents/MacOS/Swiftty"
cp "$ROOT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"

# SwiftTerm resolves its Metal shaders through Bundle.module. SwiftPM places
# that resource bundle next to the executable, but a hand-assembled .app must
# place it in Contents/Resources for Bundle.module to find it.
RESOURCE_DIR="$APP_DIR/Contents/Resources"
mkdir -p "$RESOURCE_DIR"
cp -R "$BIN_DIR/SwiftTerm_SwiftTerm.bundle" "$RESOURCE_DIR/"

# Re-sign after assembling the bundle so macOS validates the binary and
# Info.plist together at launch.
codesign --force --sign - --timestamp=none "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

open "$APP_DIR"
PID="$(pgrep -f 'Swiftty.app/Contents/MacOS/Swiftty' | head -1 || true)"
if [[ -z "$PID" ]]; then
    echo "Swiftty did not launch" >&2
    exit 1
fi

echo "pid=$PID shells=$(pgrep -P "$PID" | wc -l | tr -d ' ') cpu=$(ps -o %cpu= -p "$PID" | tr -d ' ')"
echo "idle cpu=$(ps -o %cpu= -p "$PID" | tr -d ' ')"
