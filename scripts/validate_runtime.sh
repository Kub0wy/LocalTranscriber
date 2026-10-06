#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNTIME_ROOT="${1:-$REPO_ROOT/runtime-build/LocalTranscriber}"
MANIFEST="$RUNTIME_ROOT/runtime-manifest.json"

fail() {
    echo "validation failed: $*" >&2
    exit 1
}

[[ "$(uname -s)" == "Darwin" ]] || fail "expected macOS"
[[ "$(uname -m)" == "arm64" ]] || fail "expected arm64"
[[ -f "$MANIFEST" ]] || fail "missing runtime-manifest.json"

MINIMUM_MACOS="$(/usr/bin/plutil -extract minimumMacOS raw -o - "$MANIFEST")"
PYTHON_REL="$(/usr/bin/plutil -extract python.executableRelativePath raw -o - "$MANIFEST")"
PYTHON_VERSION="$(/usr/bin/plutil -extract python.version raw -o - "$MANIFEST")"
FFMPEG_REL="$(/usr/bin/plutil -extract ffmpeg.executableRelativePath raw -o - "$MANIFEST")"
FFPROBE_REL="$(/usr/bin/plutil -extract ffmpeg.ffprobeRelativePath raw -o - "$MANIFEST")"
FFMPEG_VERSION="$(/usr/bin/plutil -extract ffmpeg.version raw -o - "$MANIFEST")"
FFMPEG_VERSION_BASE="${FFMPEG_VERSION%%-*}"
FFMPEG_SHA="$(/usr/bin/plutil -extract ffmpeg.sha256 raw -o - "$MANIFEST")"
FFPROBE_SHA="$(/usr/bin/plutil -extract ffmpeg.ffprobeSha256 raw -o - "$MANIFEST")"

ACTUAL_MACOS="$(sw_vers -productVersion)"
IFS=. read -r ACTUAL_MACOS_MAJOR ACTUAL_MACOS_MINOR _ <<< "$ACTUAL_MACOS"
IFS=. read -r MINIMUM_MACOS_MAJOR MINIMUM_MACOS_MINOR _ <<< "$MINIMUM_MACOS"
if (( ACTUAL_MACOS_MAJOR < MINIMUM_MACOS_MAJOR )) || \
   (( ACTUAL_MACOS_MAJOR == MINIMUM_MACOS_MAJOR && ACTUAL_MACOS_MINOR < MINIMUM_MACOS_MINOR )); then
    fail "macOS $ACTUAL_MACOS is older than required macOS $MINIMUM_MACOS"
fi

PYTHON="$RUNTIME_ROOT/$PYTHON_REL"
FFMPEG="$RUNTIME_ROOT/$FFMPEG_REL"
FFPROBE="$RUNTIME_ROOT/$FFPROBE_REL"

for directory in Runtime/Python Runtime/Environment Runtime/FFmpeg Models; do
    [[ -d "$RUNTIME_ROOT/$directory" ]] || fail "missing $directory"
done
[[ -x "$PYTHON" ]] || fail "Python is missing or not executable: $PYTHON_REL"
[[ -x "$FFMPEG" ]] || fail "FFmpeg is missing or not executable: $FFMPEG_REL"
[[ -x "$FFPROBE" ]] || fail "ffprobe is missing or not executable: $FFPROBE_REL"

ACTUAL_PYTHON="$("$PYTHON" -c 'import platform; print(platform.python_version())')"
[[ "$ACTUAL_PYTHON" == "$PYTHON_VERSION" ]] || fail "Python $ACTUAL_PYTHON != $PYTHON_VERSION"

ACTUAL_FFMPEG="$("$FFMPEG" -version 2>&1 | sed -n '1s/^ffmpeg version \([^ ]*\).*/\1/p')"
ACTUAL_FFPROBE="$("$FFPROBE" -version 2>&1 | sed -n '1s/^ffprobe version \([^ ]*\).*/\1/p')"
[[ "$ACTUAL_FFMPEG" == "$FFMPEG_VERSION" ]] || fail "FFmpeg $ACTUAL_FFMPEG != $FFMPEG_VERSION"
[[ "$ACTUAL_FFPROBE" == "$FFMPEG_VERSION" || "$ACTUAL_FFPROBE" == "$FFMPEG_VERSION_BASE" ]] \
    || fail "ffprobe $ACTUAL_FFPROBE does not match $FFMPEG_VERSION"
[[ "$(shasum -a 256 "$FFMPEG" | awk '{print $1}')" == "$FFMPEG_SHA" ]] \
    || fail "FFmpeg SHA-256 does not match the manifest"
[[ "$(shasum -a 256 "$FFPROBE" | awk '{print $1}')" == "$FFPROBE_SHA" ]] \
    || fail "ffprobe SHA-256 does not match the manifest"

"$PYTHON" - "$MANIFEST" <<'PY'
import importlib
import importlib.metadata
import json
import sys

manifest = json.load(open(sys.argv[1], encoding="utf-8"))
for package, expected in manifest["pythonPackages"].items():
    try:
        actual = importlib.metadata.version(package)
    except importlib.metadata.PackageNotFoundError:
        raise SystemExit(f"validation failed: missing Python package {package}")
    if actual != expected:
        raise SystemExit(
            f"validation failed: {package} {actual} != expected {expected}"
        )

importlib.import_module("mlx")
importlib.import_module("mlx_whisper")
print("mlx and mlx_whisper imports: OK")
PY

"$FFMPEG" -hide_banner -loglevel error -f lavfi -i anullsrc=r=16000:cl=mono -t 0.05 -f null -
"$FFPROBE" -v error -show_entries format=format_name -of default=nw=1 /dev/null >/dev/null 2>&1 || true
MACOS_AUDIT_QUIET=1 "$SCRIPT_DIR/audit_macos_compatibility.sh" "$RUNTIME_ROOT"

echo "Runtime validation passed."
echo "Python: $("$PYTHON" --version 2>&1)"
echo "FFmpeg: $("$FFMPEG" -version 2>&1 | sed -n '1p')"
echo "ffprobe: $("$FFPROBE" -version 2>&1 | sed -n '1p')"
