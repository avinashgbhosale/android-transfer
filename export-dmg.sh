#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [path/to/existing.app]" >&2
    exit 1
fi
mkdir -p dist
staging="$(mktemp -d "$PWD/dist/.dmg-staging.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/Android Transfer.app"
if [[ $# -eq 1 ]]; then
    [[ -d "$1/Contents/MacOS" ]] || { echo "Not an app bundle: $1" >&2; exit 1; }
    ditto "$1" "$app"
else
    ANDROID_TRANSFER_OUTPUT="$app" ./build-app.sh
fi
codesign --verify --deep --strict "$app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
architecture="$(lipo -archs "$app/Contents/MacOS/AndroidTransfer" | tr ' ' '-')"
[[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo 'Invalid app version' >&2; exit 1; }
[[ "$architecture" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo 'Invalid architecture' >&2; exit 1; }
name="Android-Transfer-$version-$architecture.dmg"
ln -s /Applications "$staging/Applications"
cp README.md "$staging/README.md"
cp THIRD-PARTY.md "$staging/THIRD-PARTY.md"
cat > "$staging/INSTALL.txt" <<'TEXT'
Android Transfer for Mac

1. Drag Android Transfer.app to the Applications shortcut.
2. Eject this disk image.
3. Open Android Transfer from Applications.

Requires macOS 26 or later and a matching Mac architecture.
The app includes its USB libraries; users do not need Homebrew or Xcode.
Quit an older version before replacing it.

Wireless: click Start wireless sharing and scan the QR code on your phone.
USB: select File transfer on Android, then connect in the USB cable tab.

This is a locally signed, unnotarized build. See README.md for Apple's
instructions for opening a trusted app and for public-distribution requirements.
TEXT
# Create outside the image's source directory, then publish only after verification.
image_dir="$(mktemp -d "$PWD/dist/.dmg-output.XXXXXX")"
trap 'rm -rf "$staging" "$image_dir"' EXIT
hdiutil create -volname 'Android Transfer' -srcfolder "$staging" -format UDZO -fs HFS+ "$image_dir/$name"
hdiutil verify "$image_dir/$name"
mv -f "$image_dir/$name" "dist/$name"
(cd dist && shasum -a 256 "$name" > "$name.sha256")
echo "Exported: $PWD/dist/$name"
