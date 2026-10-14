#!/bin/sh
# Captures Gannin's screenshots for the site, docs and README from the demo
# build (invented data, no GitHub, beside any Gannin you have running): each
# shot in Gannin/Demo/DemoShot.swift, dark then light, into
# site/assets/screens/<shot>-dark.png and <shot>-light.png.
#
#   scripts/capture-screenshots.sh            build Gannin Demo, then capture
#   scripts/capture-screenshots.sh --no-build capture with the last build
#   scripts/capture-screenshots.sh workload   only the shots named
#
# The terminal running it needs Screen Recording (System Settings › Privacy
# & Security) for screencapture to see the window. Leave the Mac alone while
# it runs: each shot is taken with the demo app in front, and it stops if
# another app keeps the focus. Only the demo app's own appearance changes,
# never the Mac's. docs/SCREENSHOTS.md has more.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
derived="$root/build/DemoDerivedData"
app="$derived/Build/Products/Debug/Gannin Demo.app"
log="$root/build/capture-screenshots.log"
screens="$root/site/assets/screens"

build=true
if [ "${1:-}" = "--no-build" ]; then build=false; shift; fi

mkdir -p "$root/build"
if $build; then
    cd "$root"
    xcodegen generate --quiet
    echo "Building Gannin Demo (log: $log)"
    if ! xcodebuild -project Gannin.xcodeproj -scheme 'Gannin Demo' -destination 'platform=macOS' \
        -derivedDataPath "$derived" -skipPackagePluginValidation -skipMacroValidation \
        build > "$log" 2>&1; then
        grep -E "error:" "$log" | sort -u | head -20
        echo "Build failed. Full log: $log"
        exit 1
    fi
fi
[ -d "$app" ] || { echo "No build at $app; run without --no-build first."; exit 1; }

# The demo app and this script talk through files here (DemoDirector).
talk=$(mktemp -d "${TMPDIR:-/tmp}/gannin-capture.XXXXXX")
pid=""
# Whatever happens, the demo app quits and the folder goes. The demo app
# exits on SIGTERM; kill -9 if it hasn't after a few seconds.
finish() {
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
        kill -9 "$pid" 2>/dev/null || true
    fi
    rm -rf "$talk"
}
trap finish EXIT
trap 'exit 130' INT TERM

"$app/Contents/MacOS/Gannin Demo" --capture "$talk" >> "$log" 2>&1 &
pid=$!

# Waits up to $2 seconds for file $1 to exist and, with $3, to start with it.
await() {
    tries=$(( $2 * 5 ))
    while [ "$tries" -gt 0 ]; do
        if [ -f "$1" ] && { [ -z "${3:-}" ] || head -n 1 "$1" | grep -q "^$3 "; }; then return 0; fi
        kill -0 "$pid" 2>/dev/null || { echo "Gannin Demo quit. Log: $log"; exit 1; }
        sleep 0.2
        tries=$(( tries - 1 ))
    done
    echo "Timed out waiting for $(basename "$1")${3:+ ($3)}."
    exit 1
}

await "$talk/shots" 60
shots=$(cat "$talk/shots")
if [ $# -gt 0 ]; then
    wanted=""
    for name in "$@"; do
        echo "$shots" | grep -qx "$name" || { echo "No shot called $name. Shots: $(echo $shots)"; exit 1; }
        # Once each: the demo app ignores a request repeating the last.
        case " $wanted " in *" $name "*) ;; *) wanted="$wanted $name" ;; esac
    done
    shots=$wanted
fi

mkdir -p "$screens"
for shot in $shots; do
    for appearance in dark light; do
        printf '%s %s\n' "$shot" "$appearance" > "$talk/request.tmp"
        mv "$talk/request.tmp" "$talk/request"
        await "$talk/posed" 30 "$shot $appearance"
        line=$(head -n 1 "$talk/posed")
        window=${line##* }
        case "$window" in
            ''|*[!0-9]*) echo "Couldn't pose $shot ($appearance): ${line#"$shot $appearance "}"; exit 1 ;;
        esac
        screencapture -x -o -l "$window" "$screens/$shot-$appearance.png"
        echo "Captured $shot ($appearance)"
    done
done
