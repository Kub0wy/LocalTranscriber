#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNTIME_ROOT="${1:-$REPO_ROOT/runtime-build/LocalTranscriber}"
DIST_DIR="${RUNTIME_DIST_DIR:-$REPO_ROOT/runtime-dist}"
MANIFEST="$RUNTIME_ROOT/runtime-manifest.json"

[[ -f "$MANIFEST" ]] || { echo "error: missing $MANIFEST" >&2; exit 1; }
"$SCRIPT_DIR/validate_runtime.sh" "$RUNTIME_ROOT"

VERSION="$(/usr/bin/plutil -extract runtimeVersion raw -o - "$MANIFEST")"
PLATFORM="$(/usr/bin/plutil -extract platform raw -o - "$MANIFEST" | tr '[:upper:]' '[:lower:]')"
ARCH="$(/usr/bin/plutil -extract architecture raw -o - "$MANIFEST")"
ARCHIVE_NAME="LocalTranscriber-Runtime-$VERSION-$PLATFORM-$ARCH.tar.gz"
ARCHIVE="$DIST_DIR/$ARCHIVE_NAME"
CHECKSUM="$DIST_DIR/LocalTranscriber-Runtime-$VERSION-$PLATFORM-$ARCH.sha256"

mkdir -p "$DIST_DIR"
rm -f "$ARCHIVE" "$CHECKSUM"

COPYFILE_DISABLE=1 tar -C "$(dirname "$RUNTIME_ROOT")" -czf "$ARCHIVE" "$(basename "$RUNTIME_ROOT")"
(
    cd "$DIST_DIR"
    shasum -a 256 "$ARCHIVE_NAME" > "$(basename "$CHECKSUM")"
)

echo "Created $ARCHIVE"
echo "Created $CHECKSUM"
cat "$CHECKSUM"
