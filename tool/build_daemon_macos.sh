#!/usr/bin/env bash
# Compiles the daemon for macOS bundling. UNTESTED on macOS (authored on Windows).
#
# Xcode integration (manual, one-time): add a Runner-target "Run Script" build
# phase AFTER "Embed Frameworks" with:
#
#   DEST="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Helpers"
#   mkdir -p "$DEST" && cp "${SRCROOT}/../../daemon/build/"* "$DEST/"
#   # With hardened runtime, sign the nested binary individually (never --deep):
#   # codesign --force --options runtime --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$DEST/daemon"
#   # codesign --force --options runtime --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$DEST/coding-agent-voice"
#
# The app resolves the bundled daemon at ../Helpers/daemon relative to the app
# binary (see daemon_lifecycle/lib/src/daemon_exe_resolver.dart).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$root/packages/daemon/build"
(
  cd "$root/packages/daemon"
  dart compile exe bin/daemon.dart -o build/daemon
  dart compile exe bin/local_speech_worker.dart -o build/coding-agent-voice
)
sherpa_root="$(cd "$root" && dart run tool/package_root.dart sherpa_onnx_macos)"
cp "$sherpa_root"/macos/*.dylib "$root/packages/daemon/build/"
cp "$root/packages/daemon/lib/src/voice/local/sherpa/assets/silero_vad.onnx" \
  "$root/packages/daemon/build/silero_vad.onnx"
echo "daemon + voice worker + Sherpa runtime -> $root/packages/daemon/build"
