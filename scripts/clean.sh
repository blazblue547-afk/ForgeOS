#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/common.sh"

for path in "$BUILD_DIR" "$STAGING_DIR" "$OUT_DIR"; do
    [[ -d "$path" ]] && chmod -R u+w "$path" 2>/dev/null || true
done
rm -rf "$BUILD_DIR" "$STAGING_DIR" "$OUT_DIR"
msg "removed build, staging, and output directories"
