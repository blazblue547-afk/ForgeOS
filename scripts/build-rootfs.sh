#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/common.sh"

if [[ "$DESKTOP" == "gnome" ]]; then
    exec "$ROOT_DIR/scripts/build-gnome-rootfs.sh"
fi

require_cmd make rsync cpio gzip
ensure_dirs

[[ -x "$BUSYBOX_BUILD_DIR/busybox" ]] || "$ROOT_DIR/scripts/build-busybox.sh"
[[ -x "$SYSTEMD_STAGING_DIR/usr/lib/systemd/systemd" && -x "$SYSTEMD_STAGING_DIR/usr/lib/systemd/systemd-logind" && -f "$SYSTEMD_STAGING_DIR/.forgeos-systemd-complete" ]] || "$ROOT_DIR/scripts/build-systemd.sh"
[[ -x "$DBUS_STAGING_DIR/usr/bin/dbus-daemon" && -f "$DBUS_STAGING_DIR/.forgeos-dbus-complete" ]] || "$ROOT_DIR/scripts/build-dbus.sh"
[[ -f "$OUT_DIR/bzImage" ]] || "$ROOT_DIR/scripts/build-kernel.sh"

msg "assembling root filesystem"
rm -rf "$ROOTFS_STAGING_DIR"
mkdir -p "$ROOTFS_STAGING_DIR"

make -C "$BUSYBOX_SRC_DIR" O="$BUSYBOX_BUILD_DIR" CONFIG_PREFIX="$ROOTFS_STAGING_DIR" install
rsync -a "$SYSTEMD_STAGING_DIR"/ "$ROOTFS_STAGING_DIR"/
rsync -a "$DBUS_STAGING_DIR"/ "$ROOTFS_STAGING_DIR"/

mkdir -p "$ROOTFS_STAGING_DIR"/{proc,sys,dev,run/dbus,tmp,var/lib/dbus,var/log,root,boot,mnt,etc/systemd/system}
rsync -a "$OVERLAY_DIR"/ "$ROOTFS_STAGING_DIR"/

rm -f "$ROOTFS_STAGING_DIR/sbin/init"
ln -s ../usr/lib/systemd/systemd "$ROOTFS_STAGING_DIR/sbin/init"
ln -sfn ../../sbin/modprobe "$ROOTFS_STAGING_DIR/usr/bin/modprobe"
ln -sfn ../run/systemd/resolve/resolv.conf "$ROOTFS_STAGING_DIR/etc/resolv.conf"

mkdir -p \
    "$ROOTFS_STAGING_DIR/etc/systemd/system/getty.target.wants" \
    "$ROOTFS_STAGING_DIR/etc/systemd/system/multi-user.target.wants" \
    "$ROOTFS_STAGING_DIR/etc/systemd/system/sockets.target.wants" \
    "$ROOTFS_STAGING_DIR/etc/systemd/system/sysinit.target.wants"

ln -sfn /usr/lib/systemd/system/multi-user.target \
    "$ROOTFS_STAGING_DIR/etc/systemd/system/default.target"
ln -sfn /etc/systemd/system/forgeos-shell@.service \
    "$ROOTFS_STAGING_DIR/etc/systemd/system/getty.target.wants/forgeos-shell@tty1.service"
ln -sfn /etc/systemd/system/forgeos-shell@.service \
    "$ROOTFS_STAGING_DIR/etc/systemd/system/getty.target.wants/forgeos-shell@ttyS0.service"
ln -sfn /etc/systemd/system/forgeos-bootdiag.service \
    "$ROOTFS_STAGING_DIR/etc/systemd/system/multi-user.target.wants/forgeos-bootdiag.service"
ln -sfn /etc/systemd/system/forgeos-console-banner.service \
    "$ROOTFS_STAGING_DIR/etc/systemd/system/multi-user.target.wants/forgeos-console-banner.service"
ln -sfn /usr/lib/systemd/system/dbus.service \
    "$ROOTFS_STAGING_DIR/etc/systemd/system/multi-user.target.wants/dbus.service"
ln -sfn /usr/lib/systemd/system/dbus.socket \
    "$ROOTFS_STAGING_DIR/etc/systemd/system/sockets.target.wants/dbus.socket"
ln -sfn /usr/lib/systemd/system/systemd-logind.service \
    "$ROOTFS_STAGING_DIR/etc/systemd/system/multi-user.target.wants/systemd-logind.service"
ln -sfn /usr/lib/systemd/system/systemd-logind.service \
    "$ROOTFS_STAGING_DIR/etc/systemd/system/dbus-org.freedesktop.login1.service"
ln -sfn /usr/lib/systemd/system/systemd-logind-varlink.socket \
    "$ROOTFS_STAGING_DIR/etc/systemd/system/sockets.target.wants/systemd-logind-varlink.socket"
ln -sfn /usr/lib/systemd/system/systemd-networkd.service \
    "$ROOTFS_STAGING_DIR/etc/systemd/system/multi-user.target.wants/systemd-networkd.service"
ln -sfn /usr/lib/systemd/system/systemd-resolved.service \
    "$ROOTFS_STAGING_DIR/etc/systemd/system/sysinit.target.wants/systemd-resolved.service"
ln -sfn /usr/lib/systemd/system/systemd-networkd.socket \
    "$ROOTFS_STAGING_DIR/etc/systemd/system/sockets.target.wants/systemd-networkd.socket"
ln -sfn /usr/lib/systemd/system/systemd-resolved-monitor.socket \
    "$ROOTFS_STAGING_DIR/etc/systemd/system/sockets.target.wants/systemd-resolved-monitor.socket"
ln -sfn /usr/lib/systemd/system/systemd-resolved-varlink.socket \
    "$ROOTFS_STAGING_DIR/etc/systemd/system/sockets.target.wants/systemd-resolved-varlink.socket"
ln -sfn /usr/lib/systemd/system/systemd-udevd.service \
    "$ROOTFS_STAGING_DIR/etc/systemd/system/sysinit.target.wants/systemd-udevd.service"
ln -sfn /usr/lib/systemd/system/systemd-udevd-control.socket \
    "$ROOTFS_STAGING_DIR/etc/systemd/system/sockets.target.wants/systemd-udevd-control.socket"
ln -sfn /usr/lib/systemd/system/systemd-udevd-kernel.socket \
    "$ROOTFS_STAGING_DIR/etc/systemd/system/sockets.target.wants/systemd-udevd-kernel.socket"

ln -sfn /dev/null "$ROOTFS_STAGING_DIR/etc/systemd/system/autovt@.service"
ln -sfn /dev/null "$ROOTFS_STAGING_DIR/etc/systemd/system/getty@tty1.service"
ln -sfn /dev/null "$ROOTFS_STAGING_DIR/etc/systemd/system/serial-getty@ttyS0.service"

if [[ -d "$MODULES_STAGING_DIR/lib/modules" ]]; then
    mkdir -p "$ROOTFS_STAGING_DIR/lib"
    rsync -a "$MODULES_STAGING_DIR/lib/" "$ROOTFS_STAGING_DIR/lib/"
fi

if truthy "$ENABLE_DESKTOP"; then
    "$ROOT_DIR/scripts/stage-openbox-desktop.sh"
fi

chmod 755 \
    "$ROOTFS_STAGING_DIR/init" \
    "$ROOTFS_STAGING_DIR/sbin/forgeos-bootdiag" \
    "$ROOTFS_STAGING_DIR/sbin/forgeos-console-banner" \
    "$ROOTFS_STAGING_DIR/sbin/forgeos-switch-root" \
    "$ROOTFS_STAGING_DIR/usr/bin/neofetch" \
    "$ROOTFS_STAGING_DIR/usr/share/udhcpc/default.script"

find "$ROOTFS_STAGING_DIR" -printf '%P\n' | LC_ALL=C sort > "$OUT_DIR/rootfs.manifest"

if truthy "$ENABLE_DESKTOP"; then
    rm -f "$OUT_DIR/rootfs.cpio.gz"
    msg "rootfs tree: $ROOTFS_STAGING_DIR"
    msg "desktop rootfs uses the ext4 image path; initramfs generation skipped"
else
    (
        cd "$ROOTFS_STAGING_DIR"
        find . -print0 | cpio --null -ov --format=newc --owner 0:0 2>/dev/null | gzip -9 > "$OUT_DIR/rootfs.cpio.gz"
    )

    msg "rootfs tree: $ROOTFS_STAGING_DIR"
    msg "initramfs: $OUT_DIR/rootfs.cpio.gz"
fi
