#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$REPO_ROOT/runtime-manifest.json"
LOCKFILE="$REPO_ROOT/requirements.lock"
BUILD_PARENT="${RUNTIME_BUILD_DIR:-$REPO_ROOT/runtime-build}"
BUILD_ROOT="$BUILD_PARENT/LocalTranscriber"
WHEELHOUSE="$BUILD_PARENT/wheelhouse-macos14"

fail() {
    echo "error: $*" >&2
    exit 1
}

[[ "$(uname -s)" == "Darwin" ]] || fail "Runtime 1.0 can only be built on macOS."
[[ "$(uname -m)" == "arm64" ]] || fail "Runtime 1.0 requires Apple Silicon (arm64)."
[[ -f "$MANIFEST" ]] || fail "Missing $MANIFEST"
[[ -f "$LOCKFILE" ]] || fail "Missing $LOCKFILE"

EXPECTED_PYTHON="$(/usr/bin/plutil -extract python.version raw -o - "$MANIFEST")"
EXPECTED_FFMPEG="$(/usr/bin/plutil -extract ffmpeg.version raw -o - "$MANIFEST")"
EXPECTED_FFMPEG_BASE="${EXPECTED_FFMPEG%%-*}"
EXPECTED_FFMPEG_SHA="$(/usr/bin/plutil -extract ffmpeg.sha256 raw -o - "$MANIFEST")"
EXPECTED_FFPROBE_SHA="$(/usr/bin/plutil -extract ffmpeg.ffprobeSha256 raw -o - "$MANIFEST")"
WHEEL_PLATFORM="$(/usr/bin/plutil -extract mlxDistribution.wheelPlatform raw -o - "$MANIFEST")"
MLX_VERSION="$(/usr/bin/plutil -extract pythonPackages.mlx raw -o - "$MANIFEST")"
MLX_METAL_VERSION="$(/usr/bin/plutil -extract pythonPackages.mlx-metal raw -o - "$MANIFEST")"
EXPECTED_MLX_WHEEL_SHA="$(/usr/bin/plutil -extract mlxDistribution.mlxWheelSha256 raw -o - "$MANIFEST")"
EXPECTED_MLX_METAL_WHEEL_SHA="$(/usr/bin/plutil -extract mlxDistribution.mlxMetalWheelSha256 raw -o - "$MANIFEST")"

# Inputs are deliberately external to the repository. Supplying paths makes the
# build independent of the user's active Python environment. For convenience on
# the inventory machine, Python and FFmpeg fall back to LocalTranscriber's saved
# Custom paths. ffprobe has no such fallback because that environment lacks it.
CONFIGURED_PYTHON="$(defaults read local.LocalTranscriber pythonPath 2>/dev/null || true)"
CONFIGURED_FFMPEG="$(defaults read local.LocalTranscriber ffmpegPath 2>/dev/null || true)"
PYTHON_INPUT="${PYTHON_RUNTIME_SOURCE:-$CONFIGURED_PYTHON}"
FFMPEG_INPUT="${FFMPEG_SOURCE:-$CONFIGURED_FFMPEG}"
FFPROBE_INPUT="${FFPROBE_SOURCE:-}"

[[ -x "$PYTHON_INPUT" ]] || fail "Set PYTHON_RUNTIME_SOURCE to the exact Python executable or standalone Python directory."
[[ -x "$FFMPEG_INPUT" ]] || fail "Set FFMPEG_SOURCE to the tested FFmpeg executable."
[[ -x "$FFPROBE_INPUT" ]] || fail "Set FFPROBE_SOURCE to a matching static ffprobe $EXPECTED_FFMPEG_BASE executable."

if [[ -d "$PYTHON_INPUT" ]]; then
    PYTHON_SOURCE="$(cd "$PYTHON_INPUT" && pwd -P)"
    SOURCE_PYTHON="$PYTHON_SOURCE/bin/python3"
else
    SOURCE_PYTHON="$PYTHON_INPUT"
    PYTHON_SOURCE="$("$SOURCE_PYTHON" -c 'import pathlib,sys; print(pathlib.Path(sys.base_prefix).resolve())')"
fi

[[ -x "$SOURCE_PYTHON" ]] || fail "Python source does not contain bin/python3."
ACTUAL_PYTHON="$("$SOURCE_PYTHON" -c 'import platform; print(platform.python_version())')"
[[ "$ACTUAL_PYTHON" == "$EXPECTED_PYTHON" ]] || fail "Python $ACTUAL_PYTHON does not match $EXPECTED_PYTHON."

ACTUAL_FFMPEG="$("$FFMPEG_INPUT" -version 2>&1 | sed -n '1s/^ffmpeg version \([^ ]*\).*/\1/p')"
ACTUAL_FFPROBE="$("$FFPROBE_INPUT" -version 2>&1 | sed -n '1s/^ffprobe version \([^ ]*\).*/\1/p')"
[[ "$ACTUAL_FFMPEG" == "$EXPECTED_FFMPEG" ]] || fail "FFmpeg $ACTUAL_FFMPEG does not match $EXPECTED_FFMPEG."
[[ "$ACTUAL_FFPROBE" == "$EXPECTED_FFMPEG" || "$ACTUAL_FFPROBE" == "$EXPECTED_FFMPEG_BASE" ]] \
    || fail "ffprobe $ACTUAL_FFPROBE does not match FFmpeg $EXPECTED_FFMPEG."
ACTUAL_FFMPEG_SHA="$(shasum -a 256 "$FFMPEG_INPUT" | awk '{print $1}')"
ACTUAL_FFPROBE_SHA="$(shasum -a 256 "$FFPROBE_INPUT" | awk '{print $1}')"
[[ "$ACTUAL_FFMPEG_SHA" == "$EXPECTED_FFMPEG_SHA" ]] || fail "FFmpeg SHA-256 does not match the manifest."
[[ "$ACTUAL_FFPROBE_SHA" == "$EXPECTED_FFPROBE_SHA" ]] || fail "ffprobe SHA-256 does not match the manifest."

case "$BUILD_ROOT" in
    "$REPO_ROOT"/runtime-build/LocalTranscriber|/tmp/*/LocalTranscriber|/private/tmp/*/LocalTranscriber) ;;
    *) fail "Refusing to clean unexpected build path: $BUILD_ROOT" ;;
esac
case "$WHEELHOUSE" in
    "$REPO_ROOT"/runtime-build/wheelhouse-macos14|/tmp/*/wheelhouse-macos14|/private/tmp/*/wheelhouse-macos14) ;;
    *) fail "Refusing to clean unexpected wheelhouse path: $WHEELHOUSE" ;;
esac

rm -rf "$BUILD_ROOT" "$WHEELHOUSE"
mkdir -p "$BUILD_ROOT/Runtime/Python" \
         "$BUILD_ROOT/Runtime/Environment/bin" \
         "$BUILD_ROOT/Runtime/FFmpeg" \
         "$BUILD_ROOT/Models" \
         "$WHEELHOUSE"

echo "Copying standalone Python $EXPECTED_PYTHON..."
rsync -a "$PYTHON_SOURCE/" "$BUILD_ROOT/Runtime/Python/"

BUILD_PYTHON="$BUILD_ROOT/Runtime/Python/bin/python3"
"$BUILD_PYTHON" -m pip --version >/dev/null \
    || fail "The standalone Python input must include pip."

echo "Resolving pinned wheels for $WHEEL_PLATFORM..."
"$BUILD_PYTHON" -m pip download \
    --disable-pip-version-check \
    --only-binary=:all: \
    --platform "$WHEEL_PLATFORM" \
    --python-version 3.12 \
    --implementation cp \
    --abi cp312 \
    --no-deps \
    --requirement "$LOCKFILE" \
    --dest "$WHEELHOUSE"

MLX_WHEEL="$WHEELHOUSE/mlx-$MLX_VERSION-cp312-cp312-$WHEEL_PLATFORM.whl"
MLX_METAL_WHEEL="$WHEELHOUSE/mlx_metal-$MLX_METAL_VERSION-py3-none-$WHEEL_PLATFORM.whl"
[[ -f "$MLX_WHEEL" ]] || fail "Official macOS 14 MLX wheel was not resolved."
[[ -f "$MLX_METAL_WHEEL" ]] || fail "Official macOS 14 mlx-metal wheel was not resolved."
[[ "$(shasum -a 256 "$MLX_WHEEL" | awk '{print $1}')" == "$EXPECTED_MLX_WHEEL_SHA" ]] \
    || fail "MLX macOS 14 wheel SHA-256 does not match the manifest."
[[ "$(shasum -a 256 "$MLX_METAL_WHEEL" | awk '{print $1}')" == "$EXPECTED_MLX_METAL_WHEEL_SHA" ]] \
    || fail "mlx-metal macOS 14 wheel SHA-256 does not match the manifest."

echo "Installing only from the macOS 14 wheelhouse..."
"$BUILD_PYTHON" -m pip install \
    --disable-pip-version-check \
    --break-system-packages \
    --no-index \
    --find-links "$WHEELHOUSE" \
    --no-deps \
    --requirement "$LOCKFILE"

# The app's established managed path remains Runtime/Environment/bin/python3.
# A relative launcher keeps the package relocatable while the complete standalone
# distribution and site-packages live under Runtime/Python.
ln -s ../../Python/bin/python3 "$BUILD_ROOT/Runtime/Environment/bin/python3"
ln -s python3 "$BUILD_ROOT/Runtime/Environment/bin/python"

install -m 0755 "$FFMPEG_INPUT" "$BUILD_ROOT/Runtime/FFmpeg/ffmpeg"
install -m 0755 "$FFPROBE_INPUT" "$BUILD_ROOT/Runtime/FFmpeg/ffprobe"
cp "$MANIFEST" "$BUILD_ROOT/runtime-manifest.json"

"$SCRIPT_DIR/validate_runtime.sh" "$BUILD_ROOT"

echo
echo "Runtime build ready: $BUILD_ROOT"
du -sh "$BUILD_ROOT/Runtime/Python" "$BUILD_ROOT/Runtime/Environment" "$BUILD_ROOT/Runtime/FFmpeg"
