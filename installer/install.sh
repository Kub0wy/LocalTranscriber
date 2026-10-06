#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$REPO_ROOT/runtime-manifest.json"
RUNTIME_VALIDATOR="$REPO_ROOT/scripts/validate_runtime.sh"

DEFAULT_INSTALL_DIR="$HOME/Library/Application Support/LocalTranscriber"
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
MODE="full"
ASSUME_YES=0
TEMP_DIR=""
INSTALL_DIR_CREATED=0
CLEANUP_ACTIVE=0
LOCK_OWNED=0
MACHINE_READABLE=0
ACTIVE_CHILD_PID=""
ERROR_EMITTED=0
FORCE_RUNTIME=0

usage() {
    cat <<'EOF'
Usage: ./installer/install.sh [options]

Options:
  --yes                    Confirm downloads non-interactively.
  --machine-readable       Emit newline-delimited JSON events on stdout.
  --runtime-only           Install and validate Runtime 1.0.0 only.
  --reinstall-runtime      Reinstall Runtime 1.0.0 without changing the model.
  --model-only             Install the model using an existing valid runtime.
  --validate               Validate the existing managed environment; no downloads.
  --quick-validate         Fast structural launch check; no downloads or model load.
  --repair                 Repair only missing or invalid managed components.
  --install-dir PATH       Use a custom managed installation directory.
  -h, --help               Show this help.
EOF
}

fail() {
    local message="$1"
    local code="${2:-installationFailed}"
    if (( MACHINE_READABLE && ! ERROR_EMITTED )); then
        emit_error "$code" "$message"
        ERROR_EMITTED=1
    fi
    echo "error: $message" >&2
    exit 1
}

json_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\t'/\\t}"
    printf '%s' "$value"
}

emit_json() {
    (( MACHINE_READABLE )) || return 0
    printf '%s\n' "$1"
}

emit_phase() {
    emit_json "{\"event\":\"phase\",\"id\":\"$(json_escape "$1")\",\"title\":\"$(json_escape "$2")\"}"
}

emit_status() {
    emit_json "{\"event\":\"status\",\"component\":\"$(json_escape "$1")\",\"state\":\"$(json_escape "$2")\"}"
}

emit_component_event() {
    emit_json "{\"event\":\"$(json_escape "$1")\",\"component\":\"$(json_escape "$2")\"}"
}

emit_progress() {
    emit_json "{\"event\":\"downloadProgress\",\"component\":\"$(json_escape "$1")\",\"bytesDownloaded\":$2,\"bytesTotal\":$3}"
}

emit_download_start() {
    emit_json "{\"event\":\"downloadStart\",\"component\":\"$(json_escape "$1")\",\"bytesTotal\":$2}"
}

emit_error() {
    emit_json "{\"event\":\"error\",\"code\":\"$(json_escape "$1")\",\"message\":\"$(json_escape "$2")\"}"
}

emit_complete() {
    emit_json "{\"event\":\"complete\",\"runtime\":$1,\"model\":$2}"
}

say() {
    (( MACHINE_READABLE )) || printf '%s\n' "$*"
}

cleanup() {
    (( ${CLEANUP_ACTIVE:-0} )) || return 0
    if [[ -n "$ACTIVE_CHILD_PID" ]]; then
        kill "$ACTIVE_CHILD_PID" 2>/dev/null || true
        wait "$ACTIVE_CHILD_PID" 2>/dev/null || true
        ACTIVE_CHILD_PID=""
    fi
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
    if [[ -n "${INSTALL_DIR:-}" && "$INSTALL_DIR" != "/" && -d "$INSTALL_DIR" ]]; then
        if [[ ! -e "$INSTALL_DIR/Runtime" && -d "$INSTALL_DIR/.previous-runtime" ]]; then
            mv "$INSTALL_DIR/.previous-runtime" "$INSTALL_DIR/Runtime" || true
        fi
        if [[ ! -e "$INSTALL_DIR/runtime-manifest.json" && -f "$INSTALL_DIR/.previous-runtime-manifest.json" ]]; then
            mv "$INSTALL_DIR/.previous-runtime-manifest.json" "$INSTALL_DIR/runtime-manifest.json" || true
        fi
        if [[ -n "${MODEL_REPOSITORY_DIR:-}" && ! -e "$MODEL_REPOSITORY_DIR" && -d "$INSTALL_DIR/.previous-model" ]]; then
            mkdir -p "$INSTALL_DIR/Models"
            mv "$INSTALL_DIR/.previous-model" "$MODEL_REPOSITORY_DIR" || true
        fi
        rm -rf "$INSTALL_DIR/.installing-runtime" "$INSTALL_DIR/.installing-model"
        if (( ${LOCK_OWNED:-0} )); then
            rmdir "$INSTALL_DIR/.installer-lock" 2>/dev/null || true
        fi
        if (( ${INSTALL_DIR_CREATED:-0} )) && \
           [[ ! -e "$INSTALL_DIR/Runtime" && ! -e "$INSTALL_DIR/runtime-manifest.json" && ! -e "${MODEL_REPOSITORY_DIR:-$INSTALL_DIR/Models/.missing}" ]]; then
            rmdir "$INSTALL_DIR/Models" 2>/dev/null || true
            rmdir "$INSTALL_DIR" 2>/dev/null || true
        fi
    fi
}

interrupted() {
    if (( MACHINE_READABLE )); then
        emit_error "cancelled" "Setup was cancelled. No incomplete component was installed."
        ERROR_EMITTED=1
    else
        echo >&2
    fi
    echo "Installation interrupted. The previous valid installation was preserved." >&2
    exit 130
}

trap cleanup EXIT
trap interrupted INT TERM HUP

manifest_value() {
    /usr/bin/plutil -extract "$1" raw -o - "$MANIFEST"
}

expand_path() {
    case "$1" in
        "~") printf '%s\n' "$HOME" ;;
        "~/"*) printf '%s/%s\n' "$HOME" "${1#\~/}" ;;
        /*) printf '%s\n' "$1" ;;
        *) printf '%s/%s\n' "$PWD" "$1" ;;
    esac
}

version_at_least() {
    local actual_major actual_minor required_major required_minor
    IFS=. read -r actual_major actual_minor _ <<< "$1"
    IFS=. read -r required_major required_minor _ <<< "$2"
    actual_minor="${actual_minor:-0}"
    required_minor="${required_minor:-0}"
    (( actual_major > required_major )) || \
        (( actual_major == required_major && actual_minor >= required_minor ))
}

nearest_existing_directory() {
    local candidate="$1"
    while [[ ! -d "$candidate" ]]; do
        local parent
        parent="$(dirname "$candidate")"
        [[ "$parent" != "$candidate" ]] || return 1
        candidate="$parent"
    done
    printf '%s\n' "$candidate"
}

confirm() {
    local prompt="$1" answer
    if (( ASSUME_YES )); then
        (( MACHINE_READABLE )) || echo "$prompt yes (--yes)"
        return 0
    fi
    (( MACHINE_READABLE )) && return 1
    printf '%s' "$prompt"
    IFS= read -r answer || answer=""
    case "$answer" in
        y|Y|yes|YES|Yes) return 0 ;;
        *) return 1 ;;
    esac
}

file_size() {
    [[ -f "$1" ]] && stat -f '%z' "$1" 2>/dev/null || printf '0\n'
}

directory_size() {
    [[ -d "$1" ]] && du -sk "$1" 2>/dev/null | awk '{ print $1 * 1024 }' || printf '0\n'
}

download_runtime_archive() {
    local destination="$1"
    if (( ! MACHINE_READABLE )); then
        curl --fail --location --retry 3 --retry-delay 2 --output "$destination" "$RUNTIME_URL"
        return
    fi

    emit_download_start "runtime" "$RUNTIME_DOWNLOAD_BYTES"
    curl --fail --location --retry 3 --retry-delay 2 --silent --show-error \
        --output "$destination" "$RUNTIME_URL" &
    ACTIVE_CHILD_PID=$!
    while kill -0 "$ACTIVE_CHILD_PID" 2>/dev/null; do
        emit_progress "runtime" "$(file_size "$destination")" "$RUNTIME_DOWNLOAD_BYTES"
        sleep 0.25
    done
    local result=0
    wait "$ACTIVE_CHILD_PID" || result=$?
    ACTIVE_CHILD_PID=""
    (( result == 0 )) || return "$result"
    emit_progress "runtime" "$(file_size "$destination")" "$RUNTIME_DOWNLOAD_BYTES"
    emit_component_event "downloadComplete" "runtime"
}

format_mib() {
    awk -v bytes="$1" 'BEGIN { printf "%.0f", bytes / 1048576 }'
}

check_platform_and_tools() {
    [[ "$(uname -s)" == "Darwin" ]] || fail "LocalTranscriber Runtime requires macOS."
    [[ "$(uname -m)" == "arm64" ]] || fail "LocalTranscriber Runtime requires Apple Silicon (arm64)."

    local actual_macos
    actual_macos="$(sw_vers -productVersion)"
    version_at_least "$actual_macos" "$MINIMUM_MACOS" \
        || fail "macOS $actual_macos is older than the required macOS $MINIMUM_MACOS."

    local tool
    for tool in curl tar shasum file vtool; do
        command -v "$tool" >/dev/null 2>&1 || fail "Required tool is unavailable: $tool"
    done
    [[ -x "$RUNTIME_VALIDATOR" ]] || fail "Runtime validator is missing: $RUNTIME_VALIDATOR"
}

check_destination() {
    [[ -n "$INSTALL_DIR" && "$INSTALL_DIR" != "/" ]] \
        || fail "Refusing unsafe installation directory: $INSTALL_DIR"
    local existing_parent
    existing_parent="$(nearest_existing_directory "$INSTALL_DIR")" \
        || fail "Could not resolve an existing parent for $INSTALL_DIR"
    [[ -w "$existing_parent" ]] || fail "Destination is not writable: $existing_parent"
    if [[ -e "$INSTALL_DIR" && ! -d "$INSTALL_DIR" ]]; then
        fail "Installation destination exists and is not a directory: $INSTALL_DIR"
    fi
    if [[ -d "$INSTALL_DIR" && ! -w "$INSTALL_DIR" ]]; then
        fail "Installation destination is not writable: $INSTALL_DIR"
    fi
}

available_bytes() {
    local existing_parent
    existing_parent="$(nearest_existing_directory "$INSTALL_DIR")"
    df -Pk "$existing_parent" | awk 'NR == 2 { printf "%.0f\n", $4 * 1024 }'
}

check_disk_space() {
    local needed="$1" available
    (( needed > 0 )) || return 0
    available="$(available_bytes)"
    [[ "$available" =~ ^[0-9]+$ ]] || fail "Could not determine free disk space."
    (( available >= needed )) || fail "Insufficient free disk space: need approximately $(format_mib "$needed") MiB, have $(format_mib "$available") MiB." "insufficientDiskSpace"
}

recover_interrupted_swaps() {
    [[ -d "$INSTALL_DIR" ]] || return 0
    if [[ ! -e "$INSTALL_DIR/Runtime" && -d "$INSTALL_DIR/.previous-runtime" ]]; then
        mv "$INSTALL_DIR/.previous-runtime" "$INSTALL_DIR/Runtime"
    fi
    if [[ ! -e "$INSTALL_DIR/runtime-manifest.json" && -f "$INSTALL_DIR/.previous-runtime-manifest.json" ]]; then
        mv "$INSTALL_DIR/.previous-runtime-manifest.json" "$INSTALL_DIR/runtime-manifest.json"
    fi
    if [[ ! -e "$MODEL_REPOSITORY_DIR" && -d "$INSTALL_DIR/.previous-model" ]]; then
        mkdir -p "$INSTALL_DIR/Models"
        mv "$INSTALL_DIR/.previous-model" "$MODEL_REPOSITORY_DIR"
    fi
}

validate_runtime_at() {
    if (( MACHINE_READABLE )); then
        "$RUNTIME_VALIDATOR" "$1" 1>&2
    else
        "$RUNTIME_VALIDATOR" "$1"
    fi
}

runtime_is_valid() {
    [[ -d "$INSTALL_DIR/Runtime" && -f "$INSTALL_DIR/runtime-manifest.json" ]] || return 1
    validate_runtime_at "$INSTALL_DIR" >/dev/null 2>&1
}

validate_model_snapshot() {
    local snapshot="$1"
    [[ -x "$MANAGED_PYTHON" ]] || return 1
    "$MANAGED_PYTHON" - "$snapshot" "$MODEL_REVISION" <<'PY'
import json
import sys
from pathlib import Path

snapshot = Path(sys.argv[1])
revision = sys.argv[2]
if snapshot.name != revision:
    raise SystemExit(f"model validation failed: expected revision {revision}, got {snapshot.name}")

config_path = snapshot / "config.json"
weights_path = snapshot / "weights.safetensors"
for path in (config_path, weights_path):
    if not path.is_file():
        raise SystemExit(f"model validation failed: missing {path.name}")
if weights_path.stat().st_size < 1_000_000_000:
    raise SystemExit("model validation failed: weights.safetensors is unexpectedly small")

config = json.loads(config_path.read_text(encoding="utf-8"))
required_config = {
    "n_mels", "n_audio_ctx", "n_audio_state", "n_audio_head", "n_audio_layer",
    "n_vocab", "n_text_ctx", "n_text_state", "n_text_head", "n_text_layer",
}
missing = sorted(required_config.difference(config))
if missing:
    raise SystemExit(f"model validation failed: config.json lacks {', '.join(missing)}")

import mlx.core as mx
from mlx_whisper.load_models import load_model
from mlx_whisper.tokenizer import get_tokenizer

model = load_model(str(snapshot), dtype=mx.float16)
mx.eval(model.parameters())
tokenizer = get_tokenizer(multilingual=True, language="en", task="transcribe")
if not tokenizer.encode("LocalTranscriber"):
    raise SystemExit("model validation failed: tokenizer support is unavailable")
print(f"Model revision {revision}: OK", file=sys.stderr)
PY
}

model_is_valid() {
    [[ -d "$MODEL_SNAPSHOT_DIR" ]] || return 1
    validate_model_snapshot "$MODEL_SNAPSHOT_DIR" >/dev/null 2>&1
}

model_is_quickly_valid() {
    local snapshot="$MODEL_SNAPSHOT_DIR"
    local config="$snapshot/config.json"
    local weights="$snapshot/weights.safetensors"
    [[ -d "$snapshot" && -f "$config" && -f "$weights" ]] || return 1
    [[ "$(basename "$snapshot")" == "$MODEL_REVISION" ]] || return 1
    local weight_size
    weight_size="$(wc -c < "$weights" 2>/dev/null | tr -d '[:space:]' || printf '0')"
    [[ "$weight_size" =~ ^[0-9]+$ ]] && (( weight_size >= 1000000000 )) || return 1
    "$MANAGED_PYTHON" -c '
import json, sys
config = json.load(open(sys.argv[1], encoding="utf-8"))
required = {"n_mels", "n_audio_ctx", "n_audio_state", "n_audio_head", "n_audio_layer", "n_vocab", "n_text_ctx", "n_text_state", "n_text_head", "n_text_layer"}
if required.difference(config):
    raise SystemExit(1)
' "$config" >/dev/null 2>&1 || return 1
}

install_runtime() {
    local archive="$TEMP_DIR/$RUNTIME_ARCHIVE"
    local extract_dir="$TEMP_DIR/extracted"
    local stage="$INSTALL_DIR/.installing-runtime"
    local backup="$INSTALL_DIR/.previous-runtime"
    local manifest_backup="$INSTALL_DIR/.previous-runtime-manifest.json"

    say
    say "Downloading Runtime $RUNTIME_VERSION from GitHub Release $RUNTIME_RELEASE_TAG..."
    download_runtime_archive "$archive" \
        || fail "Runtime download failed. No installed runtime was changed." "runtimeDownloadFailed"

    emit_component_event "verifyStart" "runtime"
    local actual_sha
    actual_sha="$(shasum -a 256 "$archive" | awk '{print $1}')"
    if [[ "$actual_sha" != "$RUNTIME_SHA256" ]]; then
        rm -f "$archive"
        echo "SECURITY / INTEGRITY ERROR: Runtime SHA-256 mismatch." >&2
        echo "Expected: $RUNTIME_SHA256" >&2
        echo "Received: $actual_sha" >&2
        fail "The downloaded Runtime failed verification and was not installed." "checksumMismatch"
    fi
    emit_component_event "verifyComplete" "runtime"

    emit_component_event "installStart" "runtime"
    mkdir -p "$extract_dir"
    tar -xzf "$archive" -C "$extract_dir" \
        || fail "Runtime extraction failed. The previous runtime was preserved." "runtimeExtractionFailed"
    [[ -d "$extract_dir/LocalTranscriber/Runtime" ]] \
        || fail "Runtime archive has an unexpected structure." "runtimeArchiveInvalid"

    rm -rf "$stage"
    mv "$extract_dir/LocalTranscriber" "$stage"
    cp "$MANIFEST" "$stage/runtime-manifest.json"
    emit_json '{"event":"validationStart","component":"runtime"}'
    validate_runtime_at "$stage" \
        || fail "Staged Runtime validation failed. The previous runtime was preserved." "runtimeValidationFailed"
    emit_json '{"event":"validationComplete","component":"runtime"}'

    rm -rf "$backup"
    rm -f "$manifest_backup"
    if [[ -d "$INSTALL_DIR/Runtime" ]]; then
        mv "$INSTALL_DIR/Runtime" "$backup"
    fi
    if [[ -f "$INSTALL_DIR/runtime-manifest.json" ]]; then
        mv "$INSTALL_DIR/runtime-manifest.json" "$manifest_backup"
    fi

    if ! mv "$stage/Runtime" "$INSTALL_DIR/Runtime" || \
       ! mv "$stage/runtime-manifest.json" "$INSTALL_DIR/runtime-manifest.json"; then
        rm -rf "$INSTALL_DIR/Runtime"
        rm -f "$INSTALL_DIR/runtime-manifest.json"
        [[ -d "$backup" ]] && mv "$backup" "$INSTALL_DIR/Runtime"
        [[ -f "$manifest_backup" ]] && mv "$manifest_backup" "$INSTALL_DIR/runtime-manifest.json"
        fail "Atomic Runtime installation failed; the previous runtime was restored." "runtimeInstallFailed"
    fi

    mkdir -p "$INSTALL_DIR/Models"
    if ! validate_runtime_at "$INSTALL_DIR"; then
        rm -rf "$INSTALL_DIR/Runtime"
        rm -f "$INSTALL_DIR/runtime-manifest.json"
        [[ -d "$backup" ]] && mv "$backup" "$INSTALL_DIR/Runtime"
        [[ -f "$manifest_backup" ]] && mv "$manifest_backup" "$INSTALL_DIR/runtime-manifest.json"
        fail "Installed Runtime failed validation; the previous runtime was restored." "runtimeValidationFailed"
    fi

    rm -rf "$backup" "$stage"
    rm -f "$manifest_backup"
    emit_component_event "installComplete" "runtime"
    say "Runtime $RUNTIME_VERSION installed and validated."
}

download_model() {
    local stage="$INSTALL_DIR/.installing-model"
    local staged_repository="$stage/$MODEL_CACHE_DIRECTORY"
    local staged_snapshot="$staged_repository/snapshots/$MODEL_REVISION"
    local backup="$INSTALL_DIR/.previous-model"

    rm -rf "$stage"
    mkdir -p "$stage"

    say
    say "Downloading $MODEL_REPO at pinned revision $MODEL_REVISION from Hugging Face..."
    emit_download_start "model" "$MODEL_DOWNLOAD_BYTES"
    if (( MACHINE_READABLE )); then
        HF_HUB_DISABLE_PROGRESS_BARS=1 "$MANAGED_PYTHON" - "$MODEL_REPO" "$MODEL_REVISION" "$stage" <<'PY' &
import sys
from pathlib import Path
from huggingface_hub import snapshot_download

repo, revision, cache_dir = sys.argv[1:]
snapshot = Path(snapshot_download(repo_id=repo, revision=revision, cache_dir=cache_dir))
if snapshot.name != revision:
    raise SystemExit(f"Hugging Face resolved unexpected revision: {snapshot.name}")
print(snapshot, file=sys.stderr)
PY
        ACTIVE_CHILD_PID=$!
        while kill -0 "$ACTIVE_CHILD_PID" 2>/dev/null; do
            emit_progress "model" "$(directory_size "$stage")" "$MODEL_DOWNLOAD_BYTES"
            sleep 0.25
        done
        local download_result=0
        wait "$ACTIVE_CHILD_PID" || download_result=$?
        ACTIVE_CHILD_PID=""
        (( download_result == 0 )) || fail "Unable to download the Whisper model." "modelDownloadFailed"
        emit_progress "model" "$(directory_size "$stage")" "$MODEL_DOWNLOAD_BYTES"
        emit_component_event "downloadComplete" "model"
    else
        "$MANAGED_PYTHON" - "$MODEL_REPO" "$MODEL_REVISION" "$stage" <<'PY'
import sys
from pathlib import Path
from huggingface_hub import snapshot_download

repo, revision, cache_dir = sys.argv[1:]
snapshot = Path(snapshot_download(repo_id=repo, revision=revision, cache_dir=cache_dir))
if snapshot.name != revision:
    raise SystemExit(f"Hugging Face resolved unexpected revision: {snapshot.name}")
print(snapshot)
PY
    fi

    [[ -d "$staged_snapshot" ]] || fail "The downloaded model does not contain the pinned snapshot." "modelDownloadIncomplete"
    emit_json '{"event":"validationStart","component":"model"}'
    validate_model_snapshot "$staged_snapshot" \
        || fail "Staged model validation failed. The previous model was preserved." "modelValidationFailed"
    emit_json '{"event":"validationComplete","component":"model"}'

    emit_component_event "installStart" "model"
    mkdir -p "$INSTALL_DIR/Models"
    rm -rf "$backup"
    if [[ -d "$MODEL_REPOSITORY_DIR" ]]; then
        mv "$MODEL_REPOSITORY_DIR" "$backup"
    fi
    if ! mv "$staged_repository" "$MODEL_REPOSITORY_DIR"; then
        [[ -d "$backup" ]] && mv "$backup" "$MODEL_REPOSITORY_DIR"
        fail "Atomic model installation failed; the previous model was restored." "modelInstallFailed"
    fi

    if ! validate_model_snapshot "$MODEL_SNAPSHOT_DIR"; then
        rm -rf "$MODEL_REPOSITORY_DIR"
        [[ -d "$backup" ]] && mv "$backup" "$MODEL_REPOSITORY_DIR"
        fail "Installed model failed validation; the previous model was restored." "modelValidationFailed"
    fi

    rm -rf "$backup" "$stage"
    emit_component_event "installComplete" "model"
    say "Whisper Large v3 Turbo installed and validated."
}

print_plan() {
    (( MACHINE_READABLE )) && return 0
    echo
    echo "LocalTranscriber Setup"
    echo
    echo "Installation location:"
    echo "$INSTALL_DIR"
    echo
    echo "Components:"
    if (( NEED_RUNTIME )); then
        echo "Runtime $RUNTIME_VERSION        ~$(format_mib "$RUNTIME_DOWNLOAD_BYTES") MiB download"
    else
        echo "Runtime $RUNTIME_VERSION        already valid; no download"
    fi
    if (( WANT_MODEL )); then
        if (( NEED_MODEL )); then
            echo "Whisper model        ~1.6 GB download"
        else
            echo "Whisper model        already valid; no download"
        fi
    else
        echo "Whisper model        skipped"
    fi
    echo
    echo "The runtime includes:"
    echo "- Python $PYTHON_VERSION"
    echo "- FFmpeg $FFMPEG_VERSION"
    echo "- MLX / mlx-whisper"
    echo "- required Python dependencies"
    echo
    echo "No system Python or Homebrew installation will be modified."
    echo "Custom runtime settings in LocalTranscriber will not be changed."
}

print_success() {
    if (( MACHINE_READABLE )); then
        local model_ready=false
        model_is_valid && model_ready=true
        emit_complete true "$model_ready"
        return 0
    fi
    echo
    echo "LocalTranscriber Setup"
    echo
    echo "✓ Runtime $RUNTIME_VERSION"
    echo "✓ Python $PYTHON_VERSION"
    echo "✓ FFmpeg $FFMPEG_VERSION"
    echo "✓ ffprobe $FFMPEG_VERSION"
    echo "✓ MLX $MLX_VERSION"
    echo "✓ mlx-whisper $MLX_WHISPER_VERSION"
    if model_is_valid; then
        echo "✓ Whisper Large v3 Turbo"
        echo
        echo "LocalTranscriber is ready."
    else
        echo "! Whisper Large v3 Turbo is not installed."
        echo
        echo "Runtime installation is complete. Install the model later with:"
        echo "./installer/install.sh --model-only --install-dir \"$INSTALL_DIR\""
    fi
}

while (( $# > 0 )); do
    case "$1" in
        --yes) ASSUME_YES=1 ;;
        --machine-readable) MACHINE_READABLE=1 ;;
        --runtime-only|--model-only|--validate|--quick-validate|--repair)
            [[ "$MODE" == "full" ]] || fail "Only one installation mode may be selected."
            MODE="${1#--}"
            ;;
        --reinstall-runtime)
            [[ "$MODE" == "full" ]] || fail "Only one installation mode may be selected."
            MODE="runtime-only"
            FORCE_RUNTIME=1
            ;;
        --install-dir)
            shift
            (( $# > 0 )) || fail "--install-dir requires a path."
            INSTALL_DIR="$1"
            ;;
        --install-dir=*) INSTALL_DIR="${1#*=}" ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Unknown option: $1" ;;
    esac
    shift
done

[[ -f "$MANIFEST" ]] || fail "Runtime manifest is missing: $MANIFEST"
INSTALL_DIR="$(expand_path "$INSTALL_DIR")"

RUNTIME_VERSION="$(manifest_value runtimeVersion)"
MINIMUM_MACOS="$(manifest_value minimumMacOS)"
RUNTIME_ARCHIVE="$(manifest_value runtime.archive)"
RUNTIME_SHA256="$(manifest_value runtime.sha256)"
RUNTIME_DOWNLOAD_BYTES="$(manifest_value runtime.downloadSizeBytes)"
RUNTIME_RELEASE_TAG="$(manifest_value runtime.releaseTag)"
RUNTIME_URL="$(manifest_value runtime.url)"
PYTHON_VERSION="$(manifest_value python.version)"
FFMPEG_FULL_VERSION="$(manifest_value ffmpeg.version)"
FFMPEG_VERSION="${FFMPEG_FULL_VERSION%%-*}"
MLX_VERSION="$(manifest_value pythonPackages.mlx)"
MLX_WHISPER_VERSION="$(manifest_value pythonPackages.mlx-whisper)"
MODEL_REPO="$(manifest_value model.repo)"
MODEL_REVISION="$(manifest_value model.revision)"
MODEL_DOWNLOAD_BYTES="$(manifest_value model.downloadSizeBytesApproximate)"
MODEL_CACHE_DIRECTORY="models--${MODEL_REPO//\//--}"
MODEL_REPOSITORY_DIR="$INSTALL_DIR/Models/$MODEL_CACHE_DIRECTORY"
MODEL_SNAPSHOT_DIR="$MODEL_REPOSITORY_DIR/snapshots/$MODEL_REVISION"
MANAGED_PYTHON="$INSTALL_DIR/Runtime/Environment/bin/python3"

emit_phase "preflight" "Checking system and destination"
check_platform_and_tools
check_destination
emit_phase "preflightComplete" "System and destination are ready"

recover_interrupted_swaps

RUNTIME_VALID=0
MODEL_VALID=0
runtime_is_valid && RUNTIME_VALID=1
if [[ -x "$MANAGED_PYTHON" ]]; then
    if [[ "$MODE" == "quick-validate" ]]; then
        model_is_quickly_valid && MODEL_VALID=1
    else
        model_is_valid && MODEL_VALID=1
    fi
fi

RUNTIME_STATE="missing"
MODEL_STATE="missing"
if [[ -d "$INSTALL_DIR/Runtime" || -f "$INSTALL_DIR/runtime-manifest.json" ]]; then
    RUNTIME_STATE="invalid"
fi
(( RUNTIME_VALID )) && RUNTIME_STATE="ready"
if [[ -d "$MODEL_REPOSITORY_DIR" ]]; then
    MODEL_STATE="invalid"
fi
(( MODEL_VALID )) && MODEL_STATE="ready"
emit_status "runtime" "$RUNTIME_STATE"
emit_status "model" "$MODEL_STATE"

if [[ "$MODE" == "validate" || "$MODE" == "quick-validate" ]]; then
    emit_json '{"event":"validationStart"}'
    (( RUNTIME_VALID )) || fail "Managed Runtime is $RUNTIME_STATE." "runtimeValidationFailed"
    (( MODEL_VALID )) || fail "Whisper model is $MODEL_STATE." "modelValidationFailed"
    emit_json '{"event":"validationComplete"}'
    if [[ "$MODE" == "quick-validate" && "$MACHINE_READABLE" -eq 1 ]]; then
        emit_complete true true
    else
        print_success
    fi
    exit 0
fi

WANT_RUNTIME=1
WANT_MODEL=1
case "$MODE" in
    runtime-only) WANT_MODEL=0 ;;
    model-only)
        WANT_RUNTIME=0
        (( RUNTIME_VALID )) || fail "--model-only requires an existing valid managed Runtime."
        ;;
    repair) ;;
    full) ;;
    *) fail "Internal error: unsupported mode $MODE" ;;
esac

NEED_RUNTIME=0
NEED_MODEL=0
(( WANT_RUNTIME && ! RUNTIME_VALID )) && NEED_RUNTIME=1
(( WANT_MODEL && ! MODEL_VALID )) && NEED_MODEL=1
(( FORCE_RUNTIME )) && NEED_RUNTIME=1

print_plan

if (( ! NEED_RUNTIME && ! NEED_MODEL )); then
    print_success
    exit 0
fi

DISK_REQUIRED=0
(( NEED_RUNTIME )) && DISK_REQUIRED=$((DISK_REQUIRED + RUNTIME_DOWNLOAD_BYTES * 4))
(( NEED_MODEL )) && DISK_REQUIRED=$((DISK_REQUIRED + MODEL_DOWNLOAD_BYTES + 536870912))
check_disk_space "$DISK_REQUIRED"

if (( MACHINE_READABLE && ! ASSUME_YES )); then
    fail "Machine-readable installation requires explicit --yes consent." "consentRequired"
fi

if ! confirm "Continue? [y/N] "; then
    say "Installation cancelled. Nothing was downloaded or changed."
    exit 0
fi

if [[ ! -d "$INSTALL_DIR" ]]; then
    INSTALL_DIR_CREATED=1
fi
mkdir -p "$INSTALL_DIR"
if mkdir "$INSTALL_DIR/.installer-lock" 2>/dev/null; then
    LOCK_OWNED=1
    CLEANUP_ACTIVE=1
else
    fail "Another LocalTranscriber installer appears to be running for this destination."
fi
TEMP_DIR="$(mktemp -d "$INSTALL_DIR/.installer-tmp.XXXXXX")"

if (( NEED_RUNTIME )); then
    install_runtime
    RUNTIME_VALID=1
fi

if (( NEED_MODEL )); then
    if model_is_valid; then
        NEED_MODEL=0
        say "Existing Whisper model is valid; no model download is needed."
    fi
fi

if (( NEED_MODEL )); then
    say
    say "Whisper Large v3 Turbo is not installed."
    if confirm "Download approximately 1.6 GB from Hugging Face now? [y/N] "; then
        download_model
    else
        say "Runtime is installed. The model can be installed later with --model-only."
        print_success
        exit 0
    fi
fi

emit_json '{"event":"validationStart"}'
validate_runtime_at "$INSTALL_DIR"
if (( WANT_MODEL )); then
    validate_model_snapshot "$MODEL_SNAPSHOT_DIR"
fi
emit_json '{"event":"validationComplete"}'
print_success
