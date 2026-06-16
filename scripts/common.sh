#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DOWNLOAD_DIR=${DOWNLOAD_DIR:-"$ROOT_DIR/downloads"}
SOURCE_DIR=${SOURCE_DIR:-"$ROOT_DIR/sources"}
BUILD_DIR=${BUILD_DIR:-"$ROOT_DIR/build"}
STAGING_DIR=${STAGING_DIR:-"$ROOT_DIR/staging"}
OUT_DIR=${OUT_DIR:-"$ROOT_DIR/out"}
OVERLAY_DIR=${OVERLAY_DIR:-"$ROOT_DIR/overlay/rootfs"}

ARCH=${ARCH:-x86_64}
KERNEL_VERSION=${KERNEL_VERSION:-7.1}
BUSYBOX_VERSION=${BUSYBOX_VERSION:-1.38.0}
SYSTEMD_VERSION=${SYSTEMD_VERSION:-260}
DBUS_VERSION=${DBUS_VERSION:-1.16.2}
PAM_VERSION=${PAM_VERSION:-1.7.2}
DESKTOP=${DESKTOP:-console}
ENABLE_DESKTOP=${ENABLE_DESKTOP:-0}
ENABLE_DOOM_EMACS=${ENABLE_DOOM_EMACS:-0}
ROOT_LABEL=${ROOT_LABEL:-FORGE_ROOT}
EFI_LABEL=${EFI_LABEL:-FORGE_EFI}
case "$DESKTOP" in
    console|gnome) ;;
    *)
        printf 'error: unsupported DESKTOP=%s\n' "$DESKTOP" >&2
        exit 1
        ;;
esac
if [[ -z "${IMAGE_SIZE_MIB:-}" ]]; then
    if [[ "$DESKTOP" == "gnome" ]]; then
        IMAGE_SIZE_MIB=12288
    elif [[ "$ENABLE_DESKTOP" =~ ^(1|true|TRUE|yes|YES|on|ON)$ || "$ENABLE_DOOM_EMACS" =~ ^(1|true|TRUE|yes|YES|on|ON)$ ]]; then
        IMAGE_SIZE_MIB=4096
    else
        IMAGE_SIZE_MIB=2048
    fi
fi
ESP_SIZE_MIB=${ESP_SIZE_MIB:-256}
BOOTLOADER=${BOOTLOADER:-grub}
SECURE_BOOT=${SECURE_BOOT:-0}
SECURE_BOOT_KEY=${SECURE_BOOT_KEY:-}
SECURE_BOOT_CERT=${SECURE_BOOT_CERT:-}
SECURE_BOOT_KEY_DIR=${SECURE_BOOT_KEY_DIR:-"$OUT_DIR/secure-boot"}
SECURE_BOOT_COMMON_NAME=${SECURE_BOOT_COMMON_NAME:-ForgeOS Secure Boot}
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}
CROSS_COMPILE=${CROSS_COMPILE:-}
CC=${CC:-${CROSS_COMPILE}gcc}

KERNEL_MAJOR=${KERNEL_VERSION%%.*}
KERNEL_TARBALL="linux-${KERNEL_VERSION}.tar.xz"
KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_MAJOR}.x/${KERNEL_TARBALL}"
BUSYBOX_TARBALL="busybox-${BUSYBOX_VERSION}.tar.bz2"
BUSYBOX_URL="https://busybox.net/downloads/${BUSYBOX_TARBALL}"
SYSTEMD_TARBALL="systemd-v${SYSTEMD_VERSION}.tar.gz"
SYSTEMD_URL="https://github.com/systemd/systemd/archive/refs/tags/v${SYSTEMD_VERSION}.tar.gz"
DBUS_TARBALL="dbus-${DBUS_VERSION}.tar.xz"
DBUS_URL="https://dbus.freedesktop.org/releases/dbus/${DBUS_TARBALL}"
PAM_TARBALL="linux-pam-${PAM_VERSION}.tar.gz"
PAM_URL="https://github.com/linux-pam/linux-pam/archive/refs/tags/v${PAM_VERSION}.tar.gz"
GNOME_SUITE=${GNOME_SUITE:-trixie}
GNOME_MIRROR=${GNOME_MIRROR:-http://deb.debian.org/debian}
DOOM_EMACS_GIT_URL=${DOOM_EMACS_GIT_URL:-https://github.com/doomemacs/doomemacs.git}
DOOM_EMACS_REF=${DOOM_EMACS_REF:-master}
DOOM_EMACS_PACKAGES=${DOOM_EMACS_PACKAGES:-emacs-nox git ripgrep fd-find findutils ca-certificates}
OPENBOX_DESKTOP_PACKAGES=${OPENBOX_DESKTOP_PACKAGES:-openbox tint2 pcmanfm xinit xserver-xorg-core xserver-xorg-input-libinput xserver-xorg-video-fbdev xserver-xorg-video-vesa xserver-xorg-video-vmware lxterminal fonts-dejavu adwaita-icon-theme hicolor-icon-theme shared-mime-info}
OPENBOX_DESKTOP_SKIP_PACKAGES=${OPENBOX_DESKTOP_SKIP_PACKAGES:-base-files dbus dbus-bin dbus-daemon dbus-session-bus-common dbus-system-bus-common dbus-user-session debconf dpkg init-system-helpers keyboard-configuration libpam-systemd mount procps systemd systemd-sysv sysvinit-utils tar tzdata udev}
DOOM_EMACS_SKIP_PACKAGES=${DOOM_EMACS_SKIP_PACKAGES:-$OPENBOX_DESKTOP_SKIP_PACKAGES}

KERNEL_SRC_DIR="$SOURCE_DIR/linux-${KERNEL_VERSION}"
BUSYBOX_SRC_DIR="$SOURCE_DIR/busybox-${BUSYBOX_VERSION}"
SYSTEMD_SRC_DIR="$SOURCE_DIR/systemd-${SYSTEMD_VERSION}"
DBUS_SRC_DIR="$SOURCE_DIR/dbus-${DBUS_VERSION}"
PAM_SRC_DIR="$SOURCE_DIR/linux-pam-${PAM_VERSION}"
KERNEL_BUILD_DIR="$BUILD_DIR/linux-${KERNEL_VERSION}"
BUSYBOX_BUILD_DIR="$BUILD_DIR/busybox-${BUSYBOX_VERSION}"
SYSTEMD_BUILD_DIR="$BUILD_DIR/systemd-${SYSTEMD_VERSION}"
DBUS_BUILD_DIR="$BUILD_DIR/dbus-${DBUS_VERSION}"
PAM_BUILD_DIR="$BUILD_DIR/linux-pam-${PAM_VERSION}"
DOOM_EMACS_SRC_DIR="$SOURCE_DIR/doomemacs"
MODULES_STAGING_DIR="$STAGING_DIR/modules"
SYSTEMD_STAGING_DIR="$STAGING_DIR/systemd"
DBUS_STAGING_DIR="$STAGING_DIR/dbus"
PAM_STAGING_DIR="$STAGING_DIR/pam"
ROOTFS_STAGING_DIR="$STAGING_DIR/rootfs"
OPENBOX_DESKTOP_DEB_DIR=${OPENBOX_DESKTOP_DEB_DIR:-"$DOWNLOAD_DIR/openbox-desktop-debs"}
OPENBOX_DESKTOP_APT_STATE_DIR=${OPENBOX_DESKTOP_APT_STATE_DIR:-"$BUILD_DIR/openbox-desktop-apt-state"}
DOOM_EMACS_DEB_DIR=${DOOM_EMACS_DEB_DIR:-"$DOWNLOAD_DIR/doom-emacs-debs"}
DOOM_EMACS_APT_STATE_DIR=${DOOM_EMACS_APT_STATE_DIR:-"$BUILD_DIR/doom-emacs-apt-state"}

msg() {
    printf '==> %s\n' "$*"
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_cmd() {
    local tool
    for tool in "$@"; do
        command -v "$tool" >/dev/null 2>&1 || die "missing required command: $tool"
    done
}

truthy() {
    case "${1:-0}" in
        1|true|TRUE|yes|YES|on|ON)
            return 0
            ;;
        0|false|FALSE|no|NO|off|OFF|"")
            return 1
            ;;
        *)
            die "invalid boolean value: $1"
            ;;
    esac
}

ensure_dirs() {
    mkdir -p "$DOWNLOAD_DIR" "$SOURCE_DIR" "$BUILD_DIR" "$STAGING_DIR" "$OUT_DIR"
}

download() {
    local url=$1
    local dest=$2

    if [[ -f "$dest" ]]; then
        msg "using cached $(basename "$dest")"
        return
    fi

    msg "downloading $(basename "$dest")"
    curl -L --fail --retry 3 --output "$dest" "$url"
}

extract_tarball() {
    local tarball=$1
    local target_dir=$2

    if [[ -d "$target_dir" ]]; then
        msg "using extracted source $(basename "$target_dir")"
        return
    fi

    msg "extracting $(basename "$tarball")"
    tar -C "$SOURCE_DIR" -xf "$tarball"
}

extract_tarball_into() {
    local tarball=$1
    local target_dir=$2

    if [[ -d "$target_dir" ]]; then
        msg "using extracted source $(basename "$target_dir")"
        return
    fi

    msg "extracting $(basename "$tarball")"
    mkdir -p "$target_dir"
    tar -C "$target_dir" --strip-components=1 -xf "$tarball"
}

apply_kconfig_fragment() {
    local target_config=$1
    local fragment=$2
    local line key value

    [[ -f "$target_config" ]] || die "missing config: $target_config"
    [[ -f "$fragment" ]] || die "missing fragment: $fragment"

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue

        case "$line" in
            \#\ CONFIG_*" is not set")
                key=${line#\# }
                key=${key% is not set}
                if grep -q "^${key}=" "$target_config"; then
                    sed -i "s|^${key}=.*|# ${key} is not set|" "$target_config"
                elif ! grep -q "^# ${key} is not set" "$target_config"; then
                    printf '# %s is not set\n' "$key" >> "$target_config"
                fi
                ;;
            CONFIG_*=*)
                key=${line%%=*}
                value=${line#*=}
                if grep -q "^${key}=" "$target_config"; then
                    sed -i "s|^${key}=.*|${key}=${value}|" "$target_config"
                elif grep -q "^# ${key} is not set" "$target_config"; then
                    sed -i "s|^# ${key} is not set|${key}=${value}|" "$target_config"
                else
                    printf '%s=%s\n' "$key" "$value" >> "$target_config"
                fi
                ;;
        esac
    done < "$fragment"
}

cleanup_path() {
    local path=$1
    [[ -e "$path" ]] && rm -rf "$path"
}
