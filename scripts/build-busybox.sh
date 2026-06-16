#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/common.sh"

require_cmd make "$CC" bzip2
ensure_dirs

[[ -d "$BUSYBOX_SRC_DIR" ]] || "$ROOT_DIR/scripts/fetch-sources.sh"
[[ -f "$PAM_STAGING_DIR/.forgeos-pam-complete" ]] || "$ROOT_DIR/scripts/build-pam.sh"

msg "configuring BusyBox ${BUSYBOX_VERSION}"
rm -rf "$BUSYBOX_BUILD_DIR"
mkdir -p "$BUSYBOX_BUILD_DIR"

make -C "$BUSYBOX_SRC_DIR" O="$BUSYBOX_BUILD_DIR" defconfig
apply_kconfig_fragment "$BUSYBOX_BUILD_DIR/.config" "$ROOT_DIR/config/busybox.fragment"

msg "building BusyBox ${BUSYBOX_VERSION}"
make -C "$BUSYBOX_SRC_DIR" O="$BUSYBOX_BUILD_DIR" \
    CROSS_COMPILE="$CROSS_COMPILE" \
    CC="$CC" \
    EXTRA_CFLAGS="-I$PAM_STAGING_DIR/usr/include" \
    EXTRA_LDFLAGS="-L$PAM_STAGING_DIR/usr/lib" \
    -j"$JOBS"

install -Dm755 "$BUSYBOX_BUILD_DIR/busybox" "$OUT_DIR/busybox"
install -Dm644 "$BUSYBOX_BUILD_DIR/.config" "$OUT_DIR/busybox.config"

msg "busybox binary is in $OUT_DIR"
