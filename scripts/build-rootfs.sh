#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/common.sh"

copy_runtime_dep() {
    local dep=$1
    local dest

    [[ -e "$dep" ]] || return 0
    case "$dep" in
        "$PAM_STAGING_DIR"/*)
            dest="$ROOTFS_STAGING_DIR/${dep#"$PAM_STAGING_DIR"/}"
            ;;
        "$ROOTFS_STAGING_DIR"/*)
            dest="$dep"
            ;;
        "$SYSTEMD_STAGING_DIR"/*)
            dest="$ROOTFS_STAGING_DIR/${dep#"$SYSTEMD_STAGING_DIR"/}"
            ;;
        "$DBUS_STAGING_DIR"/*)
            dest="$ROOTFS_STAGING_DIR/${dep#"$DBUS_STAGING_DIR"/}"
            ;;
        *)
            dest="$ROOTFS_STAGING_DIR$dep"
            ;;
    esac

    [[ -e "$dest" ]] && return 0
    mkdir -p "$(dirname "$dest")"
    install -Dm755 "$dep" "$dest"
}

copy_busybox_deps() {
    local line dep

    LD_LIBRARY_PATH="$ROOTFS_STAGING_DIR/usr/lib:$PAM_STAGING_DIR/usr/lib:$SYSTEMD_STAGING_DIR/usr/lib:$DBUS_STAGING_DIR/usr/lib:${LD_LIBRARY_PATH:-}" ldd "$BUSYBOX_BUILD_DIR/busybox" 2>/dev/null | while IFS= read -r line; do
        dep=
        case "$line" in
            *"=>"*"/"*)
                dep=${line#*=> }
                dep=${dep%% *}
                ;;
            [[:space:]]/*)
                dep=${line#"${line%%[![:space:]]*}"}
                dep=${dep%% *}
                ;;
        esac
        [[ -n "${dep:-}" && "$dep" = /* ]] || continue
        copy_runtime_dep "$dep"
    done
}

if [[ "$DESKTOP" == "gnome" ]]; then
    exec "$ROOT_DIR/scripts/build-gnome-rootfs.sh"
fi

require_cmd make rsync cpio gzip
ensure_dirs

[[ -f "$PAM_STAGING_DIR/.forgeos-pam-complete" ]] || "$ROOT_DIR/scripts/build-pam.sh"
[[ -x "$BUSYBOX_BUILD_DIR/busybox" && -f "$OUT_DIR/busybox.config" ]] || "$ROOT_DIR/scripts/build-busybox.sh"
grep -qx 'CONFIG_PAM=y' "$OUT_DIR/busybox.config" || "$ROOT_DIR/scripts/build-busybox.sh"
grep -qx 'CONFIG_LOGIN_SESSION_AS_CHILD=y' "$OUT_DIR/busybox.config" || "$ROOT_DIR/scripts/build-busybox.sh"
[[ -x "$SYSTEMD_STAGING_DIR/usr/lib/systemd/systemd" && -x "$SYSTEMD_STAGING_DIR/usr/lib/systemd/systemd-logind" && -f "$SYSTEMD_STAGING_DIR/usr/lib/security/pam_systemd.so" && -f "$SYSTEMD_STAGING_DIR/.forgeos-systemd-complete" ]] || "$ROOT_DIR/scripts/build-systemd.sh"
[[ -x "$DBUS_STAGING_DIR/usr/bin/dbus-daemon" && -f "$DBUS_STAGING_DIR/.forgeos-dbus-complete" ]] || "$ROOT_DIR/scripts/build-dbus.sh"
[[ -f "$OUT_DIR/bzImage" ]] || "$ROOT_DIR/scripts/build-kernel.sh"

msg "assembling root filesystem"
if [[ -d "$ROOTFS_STAGING_DIR" ]]; then
    chmod -R u+w "$ROOTFS_STAGING_DIR" 2>/dev/null || true
fi
rm -rf "$ROOTFS_STAGING_DIR"
mkdir -p "$ROOTFS_STAGING_DIR"

make -C "$BUSYBOX_SRC_DIR" O="$BUSYBOX_BUILD_DIR" \
    CONFIG_PREFIX="$ROOTFS_STAGING_DIR" \
    EXTRA_CFLAGS="-I$PAM_STAGING_DIR/usr/include" \
    EXTRA_LDFLAGS="-L$PAM_STAGING_DIR/usr/lib" \
    install
rsync -a "$PAM_STAGING_DIR"/ "$ROOTFS_STAGING_DIR"/
rsync -a "$SYSTEMD_STAGING_DIR"/ "$ROOTFS_STAGING_DIR"/
rsync -a "$DBUS_STAGING_DIR"/ "$ROOTFS_STAGING_DIR"/
copy_busybox_deps

mkdir -p "$ROOTFS_STAGING_DIR"/{proc,sys,dev,run/dbus,tmp,var/lib/dbus,var/log,root,home/forge,boot,mnt,etc/systemd/system}
rsync -a "$OVERLAY_DIR"/ "$ROOTFS_STAGING_DIR"/
"$ROOT_DIR/scripts/stage-nix.sh"

rm -f "$ROOTFS_STAGING_DIR/sbin/init"
ln -s ../usr/lib/systemd/systemd "$ROOTFS_STAGING_DIR/sbin/init"
ln -sfn ../../sbin/modprobe "$ROOTFS_STAGING_DIR/usr/bin/modprobe"
ln -sfn ../run/systemd/resolve/resolv.conf "$ROOTFS_STAGING_DIR/etc/resolv.conf"
ln -sfn ../run "$ROOTFS_STAGING_DIR/var/run"

mkdir -p \
    "$ROOTFS_STAGING_DIR/etc/systemd/system/getty.target.wants" \
    "$ROOTFS_STAGING_DIR/etc/systemd/system/multi-user.target.wants" \
    "$ROOTFS_STAGING_DIR/etc/systemd/system/sockets.target.wants" \
    "$ROOTFS_STAGING_DIR/etc/systemd/system/sysinit.target.wants"

ln -sfn /usr/lib/systemd/system/multi-user.target \
    "$ROOTFS_STAGING_DIR/etc/systemd/system/default.target"
ln -sfn /etc/systemd/system/forgeos-login@.service \
    "$ROOTFS_STAGING_DIR/etc/systemd/system/getty.target.wants/forgeos-login@tty1.service"
ln -sfn /etc/systemd/system/forgeos-login@.service \
    "$ROOTFS_STAGING_DIR/etc/systemd/system/getty.target.wants/forgeos-login@ttyS0.service"
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
ln -sfn /etc/systemd/system/forgeos-nix-bootstrap.service \
    "$ROOTFS_STAGING_DIR/etc/systemd/system/sysinit.target.wants/forgeos-nix-bootstrap.service"
ln -sfn /etc/systemd/system/nix-daemon.service \
    "$ROOTFS_STAGING_DIR/etc/systemd/system/multi-user.target.wants/nix-daemon.service"
ln -sfn /etc/systemd/system/nix-daemon.socket \
    "$ROOTFS_STAGING_DIR/etc/systemd/system/sockets.target.wants/nix-daemon.socket"

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

if truthy "$ENABLE_DOOM_EMACS"; then
    "$ROOT_DIR/scripts/stage-doom-emacs.sh"
fi

chmod 755 \
    "$ROOTFS_STAGING_DIR/init" \
    "$ROOTFS_STAGING_DIR/sbin/forgeos-bootdiag" \
    "$ROOTFS_STAGING_DIR/sbin/forgeos-console-banner" \
    "$ROOTFS_STAGING_DIR/sbin/forgeos-switch-root" \
    "$ROOTFS_STAGING_DIR/usr/lib/forgeos/nix-bootstrap" \
    "$ROOTFS_STAGING_DIR/usr/bin/neofetch" \
    "$ROOTFS_STAGING_DIR/usr/share/udhcpc/default.script"
chmod 700 "$ROOTFS_STAGING_DIR/root" "$ROOTFS_STAGING_DIR/home/forge"
chown 1000:1000 "$ROOTFS_STAGING_DIR/home/forge"
[[ ! -f "$ROOTFS_STAGING_DIR/etc/shadow" ]] || chmod 600 "$ROOTFS_STAGING_DIR/etc/shadow"
[[ ! -f "$ROOTFS_STAGING_DIR/etc/gshadow" ]] || chmod 600 "$ROOTFS_STAGING_DIR/etc/gshadow"

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
