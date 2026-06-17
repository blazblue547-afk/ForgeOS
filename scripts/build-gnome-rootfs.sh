#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/common.sh"

require_cmd find openssl rsync
ensure_dirs

GNOME_DEBIAN_ARCH=${GNOME_DEBIAN_ARCH:-amd64}
GNOME_COMPONENTS=${GNOME_COMPONENTS:-main,contrib,non-free-firmware}
GNOME_BOOTSTRAP_TOOL=${GNOME_BOOTSTRAP_TOOL:-auto}
GNOME_USER=${GNOME_USER:-forge}
GNOME_USER_UID=${GNOME_USER_UID:-1000}
GNOME_USER_PASSWORD=${GNOME_USER_PASSWORD:-forge}
GNOME_AUTOLOGIN=${GNOME_AUTOLOGIN:-1}
GNOME_PACKAGES=${GNOME_PACKAGES:-systemd-sysv dbus dbus-user-session gnome-core gdm3 network-manager sudo locales xserver-xorg xserver-xorg-video-all xserver-xorg-input-libinput mesa-utils fonts-dejavu firmware-linux-free}

normalize_packages_csv() {
    local package_csv

    package_csv=${GNOME_PACKAGES//$'\n'/ }
    package_csv=${package_csv//$'\t'/ }
    package_csv=${package_csv// /,}
    while [[ "$package_csv" == *",,"* ]]; do
        package_csv=${package_csv//,,/,}
    done
    package_csv=${package_csv#,}
    package_csv=${package_csv%,}
    printf '%s\n' "$package_csv"
}

choose_bootstrap_tool() {
    case "$GNOME_BOOTSTRAP_TOOL" in
        auto)
            if command -v mmdebstrap >/dev/null 2>&1; then
                printf 'mmdebstrap\n'
            elif command -v debootstrap >/dev/null 2>&1; then
                printf 'debootstrap\n'
            else
                die "install mmdebstrap, or install debootstrap and run this target as root"
            fi
            ;;
        mmdebstrap|debootstrap)
            command -v "$GNOME_BOOTSTRAP_TOOL" >/dev/null 2>&1 || die "missing required command: $GNOME_BOOTSTRAP_TOOL"
            printf '%s\n' "$GNOME_BOOTSTRAP_TOOL"
            ;;
        *)
            die "unsupported GNOME_BOOTSTRAP_TOOL=$GNOME_BOOTSTRAP_TOOL"
            ;;
    esac
}

cleanup_chroot_mounts() {
    local mountpoint

    for mountpoint in \
        "$ROOTFS_STAGING_DIR/dev/pts" \
        "$ROOTFS_STAGING_DIR/dev" \
        "$ROOTFS_STAGING_DIR/proc" \
        "$ROOTFS_STAGING_DIR/sys"; do
        if mountpoint -q "$mountpoint"; then
            umount -R "$mountpoint"
        fi
    done
}

write_apt_sources() {
    cat > "$ROOTFS_STAGING_DIR/etc/apt/sources.list" <<EOF
deb $GNOME_MIRROR $GNOME_SUITE ${GNOME_COMPONENTS//,/ }
deb http://security.debian.org/debian-security ${GNOME_SUITE}-security ${GNOME_COMPONENTS//,/ }
deb $GNOME_MIRROR ${GNOME_SUITE}-updates ${GNOME_COMPONENTS//,/ }
EOF
}

bootstrap_with_mmdebstrap() {
    local package_csv

    require_cmd mmdebstrap
    package_csv=$(normalize_packages_csv)

    msg "bootstrapping Debian $GNOME_SUITE GNOME rootfs with mmdebstrap"
    DEBIAN_FRONTEND=noninteractive mmdebstrap \
        --mode=auto \
        --variant=apt \
        --architectures="$GNOME_DEBIAN_ARCH" \
        --components="$GNOME_COMPONENTS" \
        --include="$package_csv" \
        "$GNOME_SUITE" \
        "$ROOTFS_STAGING_DIR" \
        "$GNOME_MIRROR"

    write_apt_sources
}

bootstrap_with_debootstrap() {
    require_cmd apt-get chroot debootstrap mount mountpoint umount
    [[ "$EUID" -eq 0 ]] || die "debootstrap mode must run as root; install mmdebstrap for rootless builds"

    msg "bootstrapping Debian $GNOME_SUITE base rootfs with debootstrap"
    debootstrap \
        --arch="$GNOME_DEBIAN_ARCH" \
        --components="$GNOME_COMPONENTS" \
        "$GNOME_SUITE" \
        "$ROOTFS_STAGING_DIR" \
        "$GNOME_MIRROR"

    write_apt_sources

    mount -t proc proc "$ROOTFS_STAGING_DIR/proc"
    mount -t sysfs sysfs "$ROOTFS_STAGING_DIR/sys"
    mount --rbind /dev "$ROOTFS_STAGING_DIR/dev"
    mount --make-rslave "$ROOTFS_STAGING_DIR/dev"
    trap cleanup_chroot_mounts EXIT

    msg "installing GNOME package set"
    chroot "$ROOTFS_STAGING_DIR" env DEBIAN_FRONTEND=noninteractive apt-get update
    chroot "$ROOTFS_STAGING_DIR" env DEBIAN_FRONTEND=noninteractive apt-get install -y $GNOME_PACKAGES
    chroot "$ROOTFS_STAGING_DIR" env DEBIAN_FRONTEND=noninteractive apt-get clean

    cleanup_chroot_mounts
    trap - EXIT
}

unit_path() {
    local unit=$1

    if [[ -e "$ROOTFS_STAGING_DIR/lib/systemd/system/$unit" ]]; then
        printf '/lib/systemd/system/%s\n' "$unit"
    else
        printf '/usr/lib/systemd/system/%s\n' "$unit"
    fi
}

ensure_group() {
    local group=$1
    local gid=$2
    local group_file="$ROOTFS_STAGING_DIR/etc/group"

    grep -q "^${group}:" "$group_file" || printf '%s:x:%s:\n' "$group" "$gid" >> "$group_file"
}

add_group_member() {
    local group=$1
    local member=$2
    local group_file="$ROOTFS_STAGING_DIR/etc/group"
    local line
    local name
    local password
    local gid
    local members

    line=$(grep "^${group}:" "$group_file" || true)
    [[ -n "$line" ]] || return 0

    IFS=: read -r name password gid members <<< "$line"
    case ",$members," in
        *",$member,"*) return 0 ;;
    esac
    members=${members:+$members,}$member
    sed -i "s|^${group}:.*|${name}:${password}:${gid}:${members}|" "$group_file"
}

configure_user() {
    local passwd_file="$ROOTFS_STAGING_DIR/etc/passwd"
    local shadow_file="$ROOTFS_STAGING_DIR/etc/shadow"
    local password_hash
    local today
    local home_dir="$ROOTFS_STAGING_DIR/home/$GNOME_USER"

    ensure_group "$GNOME_USER" "$GNOME_USER_UID"

    if ! grep -q "^${GNOME_USER}:" "$passwd_file"; then
        printf '%s:x:%s:%s:ForgeOS GNOME User:/home/%s:/bin/bash\n' \
            "$GNOME_USER" "$GNOME_USER_UID" "$GNOME_USER_UID" "$GNOME_USER" >> "$passwd_file"
    fi

    password_hash=$(openssl passwd -6 -salt "$GNOME_USER" "$GNOME_USER_PASSWORD")
    today=$(($(date +%s) / 86400))
    if grep -q "^${GNOME_USER}:" "$shadow_file"; then
        sed -i "s|^${GNOME_USER}:.*|${GNOME_USER}:${password_hash}:${today}:0:99999:7:::|" "$shadow_file"
    else
        printf '%s:%s:%s:0:99999:7:::\n' "$GNOME_USER" "$password_hash" "$today" >> "$shadow_file"
    fi

    for group in sudo adm cdrom dip plugdev users video audio netdev; do
        add_group_member "$group" "$GNOME_USER"
    done

    mkdir -p "$home_dir"
    chmod 0750 "$home_dir"
    if [[ "$EUID" -eq 0 ]]; then
        chown -R "$GNOME_USER_UID:$GNOME_USER_UID" "$home_dir"
    fi

    mkdir -p "$ROOTFS_STAGING_DIR/etc/sudoers.d"
    printf '%s ALL=(ALL:ALL) ALL\n' "$GNOME_USER" > "$ROOTFS_STAGING_DIR/etc/sudoers.d/forgeos"
    chmod 0440 "$ROOTFS_STAGING_DIR/etc/sudoers.d/forgeos"
}

configure_desktop_services() {
    local graphical_target
    local gdm_service
    local network_manager_service

    graphical_target=$(unit_path graphical.target)
    gdm_service=$(unit_path gdm3.service)
    network_manager_service=$(unit_path NetworkManager.service)

    mkdir -p \
        "$ROOTFS_STAGING_DIR/etc/systemd/system" \
        "$ROOTFS_STAGING_DIR/etc/systemd/system/multi-user.target.wants"

    ln -sfn "$graphical_target" "$ROOTFS_STAGING_DIR/etc/systemd/system/default.target"

    if [[ -e "$ROOTFS_STAGING_DIR${gdm_service}" ]]; then
        ln -sfn "$gdm_service" "$ROOTFS_STAGING_DIR/etc/systemd/system/display-manager.service"
    fi

    if [[ -e "$ROOTFS_STAGING_DIR${network_manager_service}" ]]; then
        ln -sfn "$network_manager_service" \
            "$ROOTFS_STAGING_DIR/etc/systemd/system/multi-user.target.wants/NetworkManager.service"
    fi

    mkdir -p "$ROOTFS_STAGING_DIR/etc/gdm3"
    {
        printf '[daemon]\n'
        printf 'WaylandEnable=false\n'
        if truthy "$GNOME_AUTOLOGIN"; then
            printf 'AutomaticLoginEnable=true\n'
            printf 'AutomaticLogin=%s\n' "$GNOME_USER"
        fi
    } > "$ROOTFS_STAGING_DIR/etc/gdm3/daemon.conf"
}

configure_identity() {
    mkdir -p "$ROOTFS_STAGING_DIR/etc/default"
    printf 'forgeos\n' > "$ROOTFS_STAGING_DIR/etc/hostname"
    cat > "$ROOTFS_STAGING_DIR/etc/os-release" <<EOF
NAME=ForgeOS
ID=forgeos
ID_LIKE=debian
PRETTY_NAME="ForgeOS GNOME ($GNOME_SUITE userland)"
VERSION_CODENAME=$GNOME_SUITE
EOF
    printf 'LANG=en_US.UTF-8\n' > "$ROOTFS_STAGING_DIR/etc/default/locale"
    rm -f "$ROOTFS_STAGING_DIR/etc/machine-id"
    : > "$ROOTFS_STAGING_DIR/etc/machine-id"
}

msg "assembling GNOME root filesystem"
BOOTSTRAP_TOOL=$(choose_bootstrap_tool)

[[ "$ARCH" == "x86_64" ]] || die "GNOME rootfs currently supports ARCH=x86_64 only"
[[ -f "$OUT_DIR/bzImage" ]] || "$ROOT_DIR/scripts/build-kernel.sh"
[[ -d "$MODULES_STAGING_DIR/lib/modules" ]] || "$ROOT_DIR/scripts/build-kernel.sh"

if [[ -d "$ROOTFS_STAGING_DIR" ]]; then
    rm -rf "$ROOTFS_STAGING_DIR" || die "could not remove $ROOTFS_STAGING_DIR; rerun with sufficient permissions"
fi
mkdir -p "$ROOTFS_STAGING_DIR"

case "$BOOTSTRAP_TOOL" in
    mmdebstrap)
        bootstrap_with_mmdebstrap
        ;;
    debootstrap)
        bootstrap_with_debootstrap
        ;;
esac

msg "configuring ForgeOS GNOME defaults"
configure_identity
configure_user
configure_desktop_services

mkdir -p "$ROOTFS_STAGING_DIR/lib" "$ROOTFS_STAGING_DIR/boot"
rsync -a "$MODULES_STAGING_DIR/lib/" "$ROOTFS_STAGING_DIR/lib/"
install -Dm644 "$OUT_DIR/bzImage" "$ROOTFS_STAGING_DIR/boot/vmlinuz-${KERNEL_VERSION}-forge"

find "$ROOTFS_STAGING_DIR" -printf '%P\n' | LC_ALL=C sort > "$OUT_DIR/rootfs.manifest"
rm -f "$OUT_DIR/rootfs.cpio.gz"

msg "GNOME rootfs tree: $ROOTFS_STAGING_DIR"
msg "default desktop user: $GNOME_USER"
