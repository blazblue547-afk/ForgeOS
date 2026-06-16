#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/common.sh"

require_cmd curl tar
ensure_dirs

download "$KERNEL_URL" "$DOWNLOAD_DIR/$KERNEL_TARBALL"
download "$BUSYBOX_URL" "$DOWNLOAD_DIR/$BUSYBOX_TARBALL"
download "$SYSTEMD_URL" "$DOWNLOAD_DIR/$SYSTEMD_TARBALL"
download "$DBUS_URL" "$DOWNLOAD_DIR/$DBUS_TARBALL"

extract_tarball "$DOWNLOAD_DIR/$KERNEL_TARBALL" "$KERNEL_SRC_DIR"
extract_tarball "$DOWNLOAD_DIR/$BUSYBOX_TARBALL" "$BUSYBOX_SRC_DIR"
extract_tarball_into "$DOWNLOAD_DIR/$SYSTEMD_TARBALL" "$SYSTEMD_SRC_DIR"
extract_tarball "$DOWNLOAD_DIR/$DBUS_TARBALL" "$DBUS_SRC_DIR"

msg "sources are ready"
