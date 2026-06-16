#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/common.sh"

require_cmd make gcc xz
ensure_dirs

[[ -d "$KERNEL_SRC_DIR" ]] || "$ROOT_DIR/scripts/fetch-sources.sh"

msg "configuring Linux ${KERNEL_VERSION}"
rm -rf "$MODULES_STAGING_DIR"
mkdir -p "$KERNEL_BUILD_DIR" "$MODULES_STAGING_DIR"

make -C "$KERNEL_SRC_DIR" O="$KERNEL_BUILD_DIR" ARCH="$ARCH" x86_64_defconfig
apply_kconfig_fragment "$KERNEL_BUILD_DIR/.config" "$ROOT_DIR/config/kernel.fragment"
cmdline_fragment=$(mktemp)
printf 'CONFIG_CMDLINE="root=PARTLABEL=root rootfstype=ext4 rootwait rw console=tty0 console=ttyS0,115200n8 loglevel=7 ignore_loglevel i915.enable_psr=0 i915.fastboot=0"\n' > "$cmdline_fragment"
apply_kconfig_fragment "$KERNEL_BUILD_DIR/.config" "$cmdline_fragment"
rm -f "$cmdline_fragment"
make -C "$KERNEL_SRC_DIR" O="$KERNEL_BUILD_DIR" ARCH="$ARCH" olddefconfig

msg "building Linux ${KERNEL_VERSION}"
make -C "$KERNEL_SRC_DIR" O="$KERNEL_BUILD_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" -j"$JOBS" bzImage modules
make -C "$KERNEL_SRC_DIR" O="$KERNEL_BUILD_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" INSTALL_MOD_PATH="$MODULES_STAGING_DIR" modules_install

install -Dm644 "$KERNEL_BUILD_DIR/arch/x86/boot/bzImage" "$OUT_DIR/bzImage"
install -Dm644 "$KERNEL_BUILD_DIR/.config" "$OUT_DIR/kernel.config"
install -Dm644 "$KERNEL_BUILD_DIR/System.map" "$OUT_DIR/System.map"

msg "kernel artifacts are in $OUT_DIR"
