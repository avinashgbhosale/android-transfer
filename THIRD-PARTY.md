This app uses dynamically linked libmtp and libusb, both under the GNU Lesser
General Public License, version 2.1 or later. Their license files are included
in the app's Contents/Resources folder by build-app.sh.

- libmtp project and source: https://github.com/libmtp/libmtp
- libusb project and source: https://github.com/libusb/libusb

The bundled libraries are unmodified Homebrew builds apart from macOS load paths
and ad-hoc signatures. They can be replaced in Contents/Frameworks with compatible
builds; re-sign the replacement libraries and app with `codesign --force --sign -`.
Before distributing binaries to others, include corresponding library sources
and comply with the LGPL distribution requirements. This build is for local use.
