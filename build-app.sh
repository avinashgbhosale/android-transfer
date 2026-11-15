#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export HOMEBREW_PREFIX="$(brew --prefix)"
export CLANG_MODULE_CACHE_PATH=/tmp/android-transfer-module-cache
export SWIFTPM_MODULECACHE_OVERRIDE=/tmp/android-transfer-module-cache
if [[ ! -f "$HOMEBREW_PREFIX/include/libmtp.h" ]]; then
    echo 'Install the USB dependency first: brew install libmtp' >&2
    exit 1
fi
swift build -c release --product AndroidTransfer --disable-sandbox --cache-path /tmp/android-transfer-swift-cache \
    -Xswiftc -module-cache-path -Xswiftc /tmp/android-transfer-module-cache
APP="${ANDROID_TRANSFER_OUTPUT:-$PWD/dist/Android Transfer.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
find "$APP/Contents/Frameworks" -type f -name '*.dylib' -exec chmod u+w {} +
cp .build/release/AndroidTransfer "$APP/Contents/MacOS/AndroidTransfer"
for resource in .build/release/*.bundle; do
    [[ -d "$resource" ]] && cp -R "$resource" "$APP/Contents/Resources/"
done
cp -L "$HOMEBREW_PREFIX/lib/libmtp.9.dylib" "$APP/Contents/Frameworks/"
cp -L "$HOMEBREW_PREFIX/lib/libusb-1.0.0.dylib" "$APP/Contents/Frameworks/"
# Rewrite Homebrew links so this app can run without Homebrew libraries installed.
for binary in "$APP/Contents/MacOS/AndroidTransfer" "$APP/Contents/Frameworks/"*.dylib; do
    while read -r dependency; do
        case "$dependency" in
            */libmtp.9.dylib|*/libusb-1.0.0.dylib)
                install_name_tool -change "$dependency" "@executable_path/../Frameworks/$(basename "$dependency")" "$binary"
                ;;
        esac
    done < <(otool -L "$binary" | tail -n +2 | awk '{print $1}')
done
for library in "$APP/Contents/Frameworks/"*.dylib; do
    install_name_tool -id "@executable_path/../Frameworks/$(basename "$library")" "$library"
    codesign --force --sign - "$library"
done

# Build the macOS icon from the version-controlled 1024 px master artwork.
icon_work="$(mktemp -d /tmp/android-transfer-icon.XXXXXX)"
trap 'rm -rf "$icon_work"' EXIT
iconset="$icon_work/AppIcon.iconset"
mkdir -p "$iconset"
for specification in \
    '16 icon_16x16.png' \
    '32 icon_16x16@2x.png' \
    '32 icon_32x32.png' \
    '64 icon_32x32@2x.png' \
    '128 icon_128x128.png' \
    '256 icon_128x128@2x.png' \
    '256 icon_256x256.png' \
    '512 icon_256x256@2x.png' \
    '512 icon_512x512.png' \
    '1024 icon_512x512@2x.png'; do
    read -r size filename <<< "$specification"
    sips -z "$size" "$size" Resources/AppIcon.png --out "$iconset/$filename" >/dev/null
done
iconutil -c icns "$iconset" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AndroidTransfer</string>
<key>CFBundleIdentifier</key><string>local.android-transfer</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleName</key><string>Android Transfer</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.3</string>
<key>CFBundleVersion</key><string>5</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Transfer files directly between your phone and Mac on the same Wi-Fi network.</string>
</dict></plist>
PLIST
cp THIRD-PARTY.md "$APP/Contents/Resources/"
for dependency in libmtp libusb; do
    source_dir="$(brew --prefix "$dependency")"
    for license in COPYING LICENSE LICENSE.txt; do
        if [[ -f "$source_dir/$license" ]]; then
            cp "$source_dir/$license" "$APP/Contents/Resources/$dependency-$license"
        fi
    done
done
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Built: $APP"
