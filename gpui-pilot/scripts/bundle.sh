#!/bin/sh
# Builds the app and wraps it as target/release/Gannin.app, with Gannin's
# icon and bundle ID, so the Dock and Command-Tab show it as Gannin.
#
#   scripts/bundle.sh             build, then bundle
#   scripts/bundle.sh --no-build  bundle the last build
#
# The executable inside is `gannin` (lowercase): Gannin's own relaunch
# script stops anything at Gannin.app/Contents/MacOS/Gannin, which must
# never be this app.
set -e
cd "$(dirname "$0")/.."

if [ "$1" != "--no-build" ]; then
    export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH"
    SDKROOT="$(xcrun --show-sdk-path)"
    export SDKROOT BINDGEN_EXTRA_CLANG_ARGS="-isysroot $SDKROOT"
    cargo build --release
fi

app=target/release/Gannin.app
icons=../Gannin/Assets.xcassets/AppIcon.appiconset
version=$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp target/release/gannin-gpui-pilot "$app/Contents/MacOS/gannin"

# The icon, from the PNGs in Gannin's asset catalog.
iconset=$(mktemp -d)/AppIcon.iconset
mkdir -p "$iconset"
cp "$icons"/icon_*.png "$iconset/"
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$iconset")"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Gannin</string>
    <key>CFBundleDisplayName</key><string>Gannin</string>
    <key>CFBundleIdentifier</key><string>dev.andon.gannin</string>
    <key>CFBundleExecutable</key><string>gannin</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>$version</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Signed ad hoc, so macOS treats the bundle as one app.
codesign --force --sign - "$app" 2>/dev/null || true
echo "Bundled $app"
