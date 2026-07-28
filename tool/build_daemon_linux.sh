#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
daemon_dir="$root/packages/daemon"
out_dir="$daemon_dir/build"
mkdir -p "$out_dir"

(
  cd "$daemon_dir"
  dart compile exe bin/daemon.dart -o build/daemon
  dart compile exe bin/local_speech_worker.dart -o build/coding-agent-voice
)

sherpa_root="$(cd "$root" && dart run tool/package_root.dart sherpa_onnx_linux)"
case "$(uname -m)" in
  aarch64|arm64) sherpa_arch="aarch64" ;;
  x86_64|amd64) sherpa_arch="x64" ;;
  *) echo "Unsupported Linux architecture: $(uname -m)" >&2; exit 1 ;;
esac
cp "$sherpa_root"/linux/"$sherpa_arch"/*.so "$out_dir/"
cp "$daemon_dir/lib/src/voice/local/sherpa/assets/silero_vad.onnx" \
  "$out_dir/silero_vad.onnx"
echo "daemon + voice worker + Sherpa runtime -> $out_dir"
