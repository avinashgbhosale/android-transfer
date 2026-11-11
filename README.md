# Android Transfer for Mac

A native SwiftUI app for copying files over USB or local Wi-Fi in either direction.
USB transfers use libmtp; wireless transfers use a temporary local HTTP server
and the phone's browser. No Android app, account, cloud, or USB debugging is required.
This is a custom local app, not an
Apple product or Apple-endorsed software.

Version 1.2 adds Finder drag-and-drop, recursive USB folder uploads, and a
per-item transfer queue with progress and failure details.

## Install and run the exported app

End users need **macOS 26 or later** and a matching Mac architecture. The current
export is **arm64 for Apple silicon (M-series Macs)**. Homebrew, Swift, Python,
and Xcode are not needed to run the exported app; its USB libraries are bundled.

1. Open `dist/Android-Transfer-1.2-arm64.dmg`.
2. Drag **Android Transfer.app** onto the **Applications** shortcut.
3. Eject the disk image and open **Android Transfer** from Applications.
4. Choose the **Wireless** or **USB cable** tab and follow the steps below.

Quit an older version before replacing it. You can also run a built `.app`
directly from Finder, without creating or installing a DMG.

This build is locally signed (ad-hoc), not Developer ID signed or notarized.
If macOS blocks a copy you trust, attempt to open it, then use **System Settings →
Privacy & Security → Open Anyway**, if available. See
[Apple's instructions for opening apps](https://support.apple.com/en-us/102445).
Do not disable Gatekeeper system-wide.

## Build and run from source

Open a terminal in the cloned `android-transfer` repository. If you are in its
parent directory, enter it first:

```sh
cd android-transfer
```

Building requires macOS 26+, Xcode Command Line Tools (Swift 5.9+), and
[Homebrew](https://brew.sh). Install Command Line Tools with `xcode-select --install`
if needed, and finish its installer before building.
The minimum macOS version matches the installed Homebrew USB libraries.

```sh
brew install libmtp
./build-app.sh
open "dist/Android Transfer.app"
```

The build bundles libmtp and libusb and signs the app locally. The artifact targets
the Mac architecture used to build it; it is not a universal or notarized release.
Quit a running copy before rebuilding to the same output path. To build separately:

```sh
ANDROID_TRANSFER_OUTPUT="$PWD/dist/Validated Android Transfer.app" ./build-app.sh
open "dist/Validated Android Transfer.app"
```

## Export a desktop app or DMG

Run all commands here from `android-transfer`.

The result of `./build-app.sh` is already a standalone desktop app:
`dist/Android Transfer.app`. Copy the entire bundle, including its `Contents`
directory; the executable alone is not sufficient.

To build the latest source and export a compressed disk image:

```sh
./export-dmg.sh
```

This builds in a temporary directory, so it does not replace a running app.
The DMG contains the app, an Applications shortcut, installation instructions,
and documentation. Its filename includes the version and architecture, such as
`dist/Android-Transfer-1.2-arm64.dmg`. A `.sha256` checksum is written beside it.

To package an existing, verified app without recompiling:

```sh
./export-dmg.sh "dist/Validated Android Transfer.app"
```

Verify the exported image and checksum:

```sh
hdiutil verify "dist/Android-Transfer-1.2-arm64.dmg"
(cd dist && shasum -a 256 -c Android-Transfer-1.2-arm64.dmg.sha256)
```

For a ZIP of the app instead of a DMG, preserve the bundle with macOS `ditto`:

```sh
ditto -c -k --sequesterRsrc --keepParent \
  "dist/Android Transfer.app" "dist/Android-Transfer.zip"
```

### Distribution to other people

The DMG is a packaging format; creating one does not notarize the app. For a
public release, use an Apple Developer ID Application certificate, sign the
app and nested code with the appropriate hardened-runtime settings, then submit
the package for notarization and staple the ticket. This export script currently
produces local/test builds and does not perform those steps. See
[Apple's distribution and notarization guide](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

The current binary is for Apple silicon; Intel Macs need a separate compatible
build of the app and both USB libraries. Include the corresponding third-party
sources and license materials when distributing; see [THIRD-PARTY.md](THIRD-PARTY.md).

## Wireless transfers

1. Put your Mac and Android on the same Wi-Fi network.
2. In the **Wireless** tab, click **Start wireless sharing**.
3. Scan the QR code with the phone camera or open the displayed link in its browser.
4. On the phone, choose files and tap **Send selected files**. Incoming files land
   in `~/Downloads/Android Transfer`. Existing files are preserved with numbered
   prefixes for duplicate names.
5. For Mac → phone, click **Add files to share…** on the Mac, then **Refresh files**
   on the phone. Tap Download beside a file. You can also drag Mac files onto the
   sharing list; wireless folder sharing is not supported yet.
6. Click **Stop sharing** when finished. It invalidates the link and interrupts
   active transfers; incomplete incoming files are removed.

If macOS asks, allow local network access/incoming connections. Guest networks may
isolate devices; VPNs or firewalls may also interfere. If multiple Mac addresses
appear, choose the one on the phone's network. Restart sharing after changing networks.

The random session link grants access to the selected files and permission to
upload. Only explicitly selected Mac files are downloadable. This uses **HTTP,
not encrypted HTTPS**; use trusted Wi-Fi. There is no port forwarding or cloud relay.
Uploads stream to disk with a 20 GB per-file limit and a 60-second inactivity timeout.
The phone's browser shows upload progress; downloads use its built-in download UI.
Folder uploads, resumable transfers, and remote browsing of Android storage are not
supported in wireless mode. Keep the app running and your Mac awake during transfers.

## USB transfers

1. Connect one Android phone with a USB data cable and unlock it.
2. Tap Android's USB notification and select **File transfer / Android Auto**.
   Allow file access if requested. Quit other MTP apps if connection fails.
3. Click **Connect phone**, select a storage location, and click **Open folder**.
4. Navigate into folders the same way. Use the up arrow to return to a parent.
5. **Upload to phone** opens a Mac file picker (multiple files supported).
   Files and complete folders are accepted. You can also drag files or folders
   from Finder onto the phone file table. Transfers run sequentially in the queue.
6. Select a phone file and click **Download to Mac** to choose a destination.
7. Wait for completion and click **Disconnect** before unplugging.

Transfers run on a serial background queue, with byte progress, so the window
remains responsive. A failed download removes its temporary data and preserves
the existing destination. Successful replacement is allowed only through the
Mac save dialog. Uploads reject existing names, including case-only differences.

## Current scope

- One phone at a time; internal storage and SD storage exposed through MTP.
- Folder browsing, current-folder search, individual downloads, batch uploads,
  recursive folder uploads, Finder drag-and-drop, and a visible transfer queue.
- Hidden files inside uploaded folders are skipped. Symbolic links are rejected.
- No recursive folder downloads, delete, rename, resume, or cancellation yet.
- Keep the phone connected during transfers. A failed upload may leave an
  incomplete file on Android; inspect/remove it using the phone before retrying.
- Android protected app folders may not be accessible through MTP.
- A real phone is required to verify device-specific compatibility and speed.

## Development and checks

```sh
swift run AndroidTransfer
CLANG_MODULE_CACHE_PATH=/tmp/android-transfer-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/android-transfer-module-cache \
swift run --disable-sandbox --cache-path /tmp/android-transfer-swift-cache TransferChecks

# Build and exercise the real wireless server using disposable local files:
swift build --product WirelessChecks
python3 WirelessChecks/integration.py
```

Standalone checks cover untrusted filenames, upload name collisions, failed-download
cleanup, atomic publication, and USB operations without a connection. They do not
require the full Xcode/XCTest installation. Hardware acceptance: connect a
phone, browse DCIM/Download, upload a disposable file, download it to another Mac
folder, compare with `shasum -a 256`, then disconnect. Also check an empty folder,
a Unicode filename, a large file, and unplugging during a disposable transfer.

Wireless integration checks cover the browser page, token authentication, origin
checks, byte-exact upload/download, empty files, size limits, path traversal,
concurrent filename collisions, fragmented HTTP requests, and disconnect cleanup.
They also verify that a restart expires the old link and quitting waits for
partial-upload cleanup.
An actual Android browser is still needed to validate QR scanning, Wi-Fi reachability,
and the file-picker/download experience on your phone.

## GitHub repository

This folder is a standalone Swift package and Git repository. Build caches,
exported `.app`/DMG files, local environment files, and editor settings are ignored.
Keep generated installers outside Git history; they can be attached to a release
after completing the distribution steps above.

To create a private GitHub repository and push the local commits using the
[GitHub CLI](https://cli.github.com/):

```sh
brew install gh
gh auth login
gh repo create android-transfer --private --source=. --remote=origin --push
```

For an existing empty repository, configure its actual URL and push:

```sh
git remote add origin https://github.com/YOUR-ACCOUNT/android-transfer.git
git push -u origin main
```

Use only one of these setup methods. After the remote exists, publish later changes
with `git push`. Do not commit access tokens or signing credentials.
