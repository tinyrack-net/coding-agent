#!/usr/bin/env bash
# Compiles the daemon for macOS bundling. UNTESTED on macOS (authored on Windows).
#
# Xcode integration (manual, one-time): add a Runner-target "Run Script" build
# phase AFTER "Embed Frameworks" with:
#
#   DAEMON_SRC="${SRCROOT}/../../daemon/build/daemon"
#   DEST="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Helpers"
#   mkdir -p "$DEST" && cp "$DAEMON_SRC" "$DEST/daemon"
#   # With hardened runtime, sign the nested binary individually (never --deep):
#   # codesign --force --options runtime --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$DEST/daemon"
#
# The app resolves the bundled daemon at ../Helpers/daemon relative to the app
# binary (see daemon_lifecycle/lib/src/daemon_exe_resolver.dart).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$root/packages/daemon/build"
(cd "$root/packages/daemon" && dart compile exe bin/daemon.dart -o build/daemon)
echo "daemon -> $root/packages/daemon/build/daemon"
