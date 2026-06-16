#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/common.sh"

rm -rf "$BUILD_DIR" "$STAGING_DIR" "$OUT_DIR"
msg "removed build, staging, and output directories"
