#!/bin/sh
# Builds Gannin from this checkout and swaps it in for whatever Gannin is
# running, so there's only ever one. Safe to run from a Claude Code session
# inside Gannin: the swap runs detached, and the session resumes in the new
# build.
#
#   scripts/relaunch.sh            build, then quit and relaunch
#   scripts/relaunch.sh --no-build relaunch the last build from here
#
# The build is signed as Xcode signs it (Apple Development, the team in
# project.yml), so it reads the same keychain token as any other build.
# A failed build quits nothing.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
# One place per checkout, so the app's path doesn't move between runs.
derived="$HOME/Library/Developer/Xcode/DerivedData/Gannin-relaunch-$(printf '%s' "$root" | shasum | cut -c1-8)"
app="$derived/Build/Products/Debug/Gannin.app"
log="${TMPDIR:-/tmp}/gannin-relaunch.log"

if [ "${1:-}" != "--no-build" ]; then
    cd "$root"
    xcodegen generate --quiet
    echo "Building $root (log: $log)"
    if ! xcodebuild -project Gannin.xcodeproj -scheme Gannin -destination 'platform=macOS' \
        -derivedDataPath "$derived" -skipPackagePluginValidation -skipMacroValidation \
        build > "$log" 2>&1; then
        grep -E "error:" "$log" | sort -u | head -20
        echo "Build failed; Gannin left running. Full log: $log"
        exit 1
    fi
fi

[ -d "$app" ] || { echo "No build at $app; run without --no-build first."; exit 1; }

# Detached, so it outlives a session whose terminal belongs to the Gannin
# it quits. SIGTERM skips the quit prompt; sessions are on disk and resume.
nohup sh -c '
    sleep 3
    pids=$(pgrep -f "Gannin.app/Contents/MacOS/Gannin$" || true)
    [ -n "$pids" ] && kill $pids
    for _ in $(seq 1 40); do
        pgrep -f "Gannin.app/Contents/MacOS/Gannin$" > /dev/null || break
        sleep 0.5
    done
    pids=$(pgrep -f "Gannin.app/Contents/MacOS/Gannin$" || true)
    [ -n "$pids" ] && kill -9 $pids
    open "$1"
' relaunch "$app" > /dev/null 2>&1 < /dev/null &

echo "Relaunching $app in 3 seconds."
