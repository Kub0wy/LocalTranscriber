#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNTIME_ROOT="${1:-$REPO_ROOT/runtime-build/LocalTranscriber}"
MANIFEST="$RUNTIME_ROOT/runtime-manifest.json"

fail() {
    echo "compatibility audit failed: $*" >&2
    exit 1
}

[[ -d "$RUNTIME_ROOT/Runtime" ]] || fail "missing Runtime directory"
[[ -f "$MANIFEST" ]] || fail "missing runtime-manifest.json"
command -v file >/dev/null || fail "file is unavailable"
command -v vtool >/dev/null || fail "vtool is unavailable"

TARGET="$(/usr/bin/plutil -extract minimumMacOS raw -o - "$MANIFEST")"
REPORT="${MACOS_AUDIT_REPORT:-}"
TMP_REPORT="$(mktemp -t localtranscriber-macos-audit)"
trap 'rm -f "$TMP_REPORT"' EXIT

version_greater() {
    local left_major left_minor right_major right_minor
    IFS=. read -r left_major left_minor _ <<< "$1"
    IFS=. read -r right_major right_minor _ <<< "$2"
    left_minor="${left_minor:-0}"
    right_minor="${right_minor:-0}"
    (( left_major > right_major )) || \
        (( left_major == right_major && left_minor > right_minor ))
}

component_for() {
    case "$1" in
        */site-packages/mlx/*) echo "mlx / mlx-metal" ;;
        */site-packages/numpy/*) echo "numpy" ;;
        */site-packages/scipy/*) echo "scipy" ;;
        */site-packages/torch/*) echo "torch" ;;
        */site-packages/llvmlite/*) echo "llvmlite" ;;
        */site-packages/numba/*) echo "numba" ;;
        */site-packages/tiktoken/*) echo "tiktoken" ;;
        */site-packages/regex/*) echo "regex" ;;
        */site-packages/charset_normalizer/*) echo "charset-normalizer" ;;
        */site-packages/yaml/*) echo "PyYAML" ;;
        */Runtime/FFmpeg/ffmpeg) echo "FFmpeg" ;;
        */Runtime/FFmpeg/ffprobe) echo "ffprobe" ;;
        */Runtime/Python/*) echo "Python runtime / stdlib" ;;
        *) echo "other" ;;
    esac
}

printf 'component\tminimum_macos\tpath\n' > "$TMP_REPORT"
highest="0.0"
count=0

while IFS= read -r -d '' candidate; do
    file_output="$(file -b "$candidate")"
    [[ "$file_output" == *Mach-O* ]] || continue
    min_versions="$(vtool -show-build "$candidate" 2>/dev/null | awk '$1 == "minos" {print $2}')"
    [[ -n "$min_versions" ]] || fail "no LC_BUILD_VERSION minimum found for $candidate"
    while IFS= read -r minimum; do
        relative="${candidate#"$RUNTIME_ROOT"/}"
        component="$(component_for "$candidate")"
        printf '%s\t%s\t%s\n' "$component" "$minimum" "$relative" >> "$TMP_REPORT"
        count=$((count + 1))
        if version_greater "$minimum" "$highest"; then highest="$minimum"; fi
        if version_greater "$minimum" "$TARGET"; then
            fail "$relative requires macOS $minimum, above target $TARGET"
        fi
    done <<< "$min_versions"
done < <(
    find "$RUNTIME_ROOT/Runtime/Python" "$RUNTIME_ROOT/Runtime/FFmpeg" -type f \
        \( -perm -111 -o -name '*.so' -o -name '*.dylib' -o -name '*.bundle' \) -print0
)

(( count > 0 )) || fail "no Mach-O binaries found"

while IFS= read -r -d '' metallib; do
    relative="${metallib#"$RUNTIME_ROOT"/}"
    printf 'mlx-metal (MetalLib)\tn/a (official %s wheel)\t%s\n' "$TARGET" "$relative" >> "$TMP_REPORT"
done < <(find "$RUNTIME_ROOT/Runtime/Python" -type f -name '*.metallib' -print0)

if [[ -n "$REPORT" ]]; then
    mkdir -p "$(dirname "$REPORT")"
    cp "$TMP_REPORT" "$REPORT"
fi

if [[ "${MACOS_AUDIT_QUIET:-0}" != "1" ]]; then
    cat "$TMP_REPORT"
fi
echo "Mach-O compatibility audit passed: $count binaries, highest minimum macOS $highest (target $TARGET)."
