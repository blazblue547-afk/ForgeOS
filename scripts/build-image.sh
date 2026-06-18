#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/common.sh"

require_cmd qemu-img parted mkfs.vfat mkfs.ext4 mcopy mmd dd awk sed truncate rsync du find fakeroot
ensure_dirs

normal_rootfs_matches() {
    [[ -d "$ROOTFS_STAGING_DIR" ]] || return 1
    [[ -f "$ROOTFS_STAGING_DIR/etc/forgeos-nix" ]] || return 1
    [[ -x "$ROOTFS_STAGING_DIR/usr/bin/forgeos-app" ]] || return 1
    [[ -f "$ROOTFS_STAGING_DIR/etc/machine-id" ]] || return 1
    [[ ! -f "$ROOTFS_STAGING_DIR/etc/fstab" ]] || return 1

    if truthy "$ENABLE_DESKTOP"; then
        [[ -f "$ROOTFS_STAGING_DIR/etc/forgeos-desktop" ]] || return 1
    else
        [[ ! -f "$ROOTFS_STAGING_DIR/etc/forgeos-desktop" ]] || return 1
    fi

    [[ ! -f "$ROOTFS_STAGING_DIR/etc/forgeos-doom-emacs" ]] || return 1
}

[[ -f "$OUT_DIR/bzImage" ]] || "$ROOT_DIR/scripts/build-kernel.sh"
if [[ "$DESKTOP" == "gnome" ]]; then
    [[ -d "$ROOTFS_STAGING_DIR" && -f "$ROOTFS_STAGING_DIR/etc/gdm3/daemon.conf" ]] || "$ROOT_DIR/scripts/build-gnome-rootfs.sh"
else
    normal_rootfs_matches || "$ROOT_DIR/scripts/build-rootfs.sh"

    if ! truthy "$ENABLE_DESKTOP"; then
        [[ -f "$OUT_DIR/rootfs.cpio.gz" ]] || "$ROOT_DIR/scripts/build-rootfs.sh"
    fi
fi

IMAGE_PATH="$OUT_DIR/forgeos-${KERNEL_VERSION}.img"
EFI_LOADER="$OUT_DIR/BOOTX64.EFI"
EFI_KERNEL="$OUT_DIR/FORGEOS.EFI"
EFI_INITRD="$OUT_DIR/rootfs.cpio.gz"
GRUB_CFG="$OUT_DIR/grub.cfg"
ESP_END_MIB=$((1 + ESP_SIZE_MIB))
ESP_IMAGE="$OUT_DIR/forgeos-esp.img"
ROOT_IMAGE="$OUT_DIR/forgeos-root.img"
APP_IMAGE="$OUT_DIR/forgeos-apps.img"
IMAGE_ROOTFS_DIR="$ROOTFS_STAGING_DIR"
APP_IMAGE_NEEDED=0

partition_field() {
    local partition=$1
    local field=$2
    parted -sm "$IMAGE_PATH" unit B print | awk -F: -v part="$partition" -v idx="$field" '
        $1 == part {
            gsub(/B$/, "", $idx)
            print $idx
        }
    '
}

reset_staging_tree() {
    local path=$1

    if [[ -d "$path" ]]; then
        chmod -R u+w "$path" 2>/dev/null || true
    fi
    rm -rf "$path"
    mkdir -p "$path"
}

copy_app_path() {
    local rel=$1
    local app_rel=$2
    local src="$ROOTFS_STAGING_DIR/$rel"
    local dest="$APPFS_STAGING_DIR/$app_rel"

    mkdir -p "$dest"
    if [[ -d "$src" ]]; then
        rsync -a "$src"/ "$dest"/
    fi
}

empty_base_mountpoint() {
    local rel=$1
    local path="$BASE_ROOTFS_STAGING_DIR/$rel"

    if [[ -e "$path" || -L "$path" ]]; then
        chmod -R u+w "$path" 2>/dev/null || true
    fi
    rm -rf "$path"
    mkdir -p "$path"
}

dir_size_mib() {
    du -sm "$1" | awk '{ print $1 }'
}

build_ext4_image() {
    local label=$1
    local tree=$2
    local image=$3
    local size=$4

    truncate -s "$size" "$image"
    fakeroot -- bash -euo pipefail -c '
        tree=$1
        label=$2
        image=$3

        find "$tree" -xdev -exec chown -h 0:0 {} + 2>/dev/null || true

        if [[ -d "$tree/home/forge" ]]; then
            find "$tree/home/forge" -xdev -exec chown -h 1000:1000 {} + 2>/dev/null || true
            chmod 0700 "$tree/home/forge"
        fi

        [[ ! -d "$tree/root" ]] || chmod 0700 "$tree/root"

        if [[ -d "$tree/nix/store" ]]; then
            find "$tree/nix/store" -xdev -exec chown -h 0:30000 {} + 2>/dev/null || true
            chmod 1775 "$tree/nix/store"
            chmod -R ugo-w "$tree/nix/store"/* 2>/dev/null || true
        fi

        mkfs.ext4 -F -L "$label" -d "$tree" "$image" >/dev/null
    ' bash "$tree" "$label" "$image"
}

write_atomic_fstab() {
    cat > "$BASE_ROOTFS_STAGING_DIR/etc/fstab" <<EOF
# ForgeOS keeps the base OS read-only in disk images and mounts mutable
# applications and state from the app layer.
LABEL=$APP_LABEL /forge ext4 rw,relatime,nofail,x-systemd.device-timeout=60s 0 2
/forge/nix /nix none bind,nofail,x-systemd.requires=forge.mount,x-systemd.after=forge.mount 0 0
/forge/home /home none bind,nofail,x-systemd.requires=forge.mount,x-systemd.after=forge.mount 0 0
/forge/root /root none bind,nofail,x-systemd.requires=forge.mount,x-systemd.after=forge.mount 0 0
/forge/var /var none bind,nofail,x-systemd.requires=forge.mount,x-systemd.after=forge.mount 0 0
/forge/opt /opt none bind,nofail,x-systemd.requires=forge.mount,x-systemd.after=forge.mount 0 0
/forge/usr-local /usr/local none bind,nofail,x-systemd.requires=forge.mount,x-systemd.after=forge.mount 0 0
tmpfs /tmp tmpfs rw,nosuid,nodev,mode=1777 0 0
EOF
}

prepare_atomic_image_trees() {
    msg "deriving atomic base and writable app layer trees"

    reset_staging_tree "$BASE_ROOTFS_STAGING_DIR"
    reset_staging_tree "$APPFS_STAGING_DIR"

    rsync -a "$ROOTFS_STAGING_DIR"/ "$BASE_ROOTFS_STAGING_DIR"/

    copy_app_path nix nix
    copy_app_path home home
    copy_app_path root root
    copy_app_path var var
    copy_app_path opt opt
    copy_app_path usr/local usr-local

    empty_base_mountpoint nix
    empty_base_mountpoint home
    empty_base_mountpoint root
    empty_base_mountpoint var
    empty_base_mountpoint opt
    empty_base_mountpoint usr/local
    mkdir -p "$BASE_ROOTFS_STAGING_DIR/forge"
    write_atomic_fstab

    chmod 0755 \
        "$BASE_ROOTFS_STAGING_DIR/nix" \
        "$BASE_ROOTFS_STAGING_DIR/home" \
        "$BASE_ROOTFS_STAGING_DIR/var" \
        "$BASE_ROOTFS_STAGING_DIR/opt" \
        "$BASE_ROOTFS_STAGING_DIR/usr/local" \
        "$BASE_ROOTFS_STAGING_DIR/forge" \
        "$APPFS_STAGING_DIR"
    chmod 0700 "$BASE_ROOTFS_STAGING_DIR/root"
    [[ ! -d "$APPFS_STAGING_DIR/root" ]] || chmod 0700 "$APPFS_STAGING_DIR/root"
    [[ ! -d "$APPFS_STAGING_DIR/home/forge" ]] || chmod 0700 "$APPFS_STAGING_DIR/home/forge"

    find "$BASE_ROOTFS_STAGING_DIR" -printf '%P\n' | LC_ALL=C sort > "$OUT_DIR/base-rootfs.manifest"
    find "$APPFS_STAGING_DIR" -printf '%P\n' | LC_ALL=C sort > "$OUT_DIR/appfs.manifest"

    IMAGE_ROOTFS_DIR="$BASE_ROOTFS_STAGING_DIR"
    APP_IMAGE_NEEDED=1
}

write_grub_config() {
    local root_mode=rw

    if atomic_base_enabled; then
        root_mode=ro
    fi

    cat > "$GRUB_CFG" <<'EOF'
set timeout=10
set default=0

terminal_input console
terminal_output console
set gfxmode=1024x768,800x600,auto
set gfxpayload=keep
insmod all_video
insmod gfxterm
terminal_output gfxterm console
set linux_common="__LINUX_COMMON__"
set initrd_common="rdinit=/sbin/init"
set handoff_common="rdinit=/init forgeos.switch_root=1"

menuentry "ForgeOS - Dell Precision 7720 default" {
    search --no-floppy --file --set=esp /EFI/BOOT/FORGEOS.EFI
    linux ($esp)/EFI/BOOT/FORGEOS.EFI $linux_common i915.enable_psr=0 i915.fastboot=0
}

menuentry "ForgeOS - Intel display only" {
    search --no-floppy --file --set=esp /EFI/BOOT/FORGEOS.EFI
    linux ($esp)/EFI/BOOT/FORGEOS.EFI $linux_common nouveau.modeset=0 i915.enable_psr=0 i915.fastboot=0
}

menuentry "ForgeOS - NVIDIA display only" {
    search --no-floppy --file --set=esp /EFI/BOOT/FORGEOS.EFI
    linux ($esp)/EFI/BOOT/FORGEOS.EFI $linux_common i915.modeset=0
}

menuentry "ForgeOS - firmware framebuffer safe mode" {
    search --no-floppy --file --set=esp /EFI/BOOT/FORGEOS.EFI
    linux ($esp)/EFI/BOOT/FORGEOS.EFI $linux_common nomodeset
}
EOF

    sed -i "s|__LINUX_COMMON__|root=PARTLABEL=root rootfstype=ext4 rootwait $root_mode console=tty0 loglevel=7 ignore_loglevel earlyprintk=efi,keep vt.global_cursor_default=1|" "$GRUB_CFG"

    if [[ "$DESKTOP" != "gnome" ]] && ! truthy "$ENABLE_DESKTOP"; then
        cat >> "$GRUB_CFG" <<'EOF'

menuentry "ForgeOS - initramfs-assisted root default display" {
    search --no-floppy --file --set=esp /EFI/BOOT/FORGEOS.EFI
    linux ($esp)/EFI/BOOT/FORGEOS.EFI $linux_common $handoff_common i915.enable_psr=0 i915.fastboot=0
    initrd ($esp)/EFI/BOOT/rootfs.cpio.gz
}

menuentry "ForgeOS - initramfs-assisted root fixed GRUB framebuffer" {
    search --no-floppy --file --set=esp /EFI/BOOT/FORGEOS.EFI
    set gfxmode=1024x768
    set gfxpayload=keep
    linux ($esp)/EFI/BOOT/FORGEOS.EFI $linux_common $handoff_common nomodeset video=efifb:1024x768 fbcon=map:0 fbcon=font:VGA8x16
    initrd ($esp)/EFI/BOOT/rootfs.cpio.gz
}

menuentry "ForgeOS - systemd initramfs default display" {
    search --no-floppy --file --set=esp /EFI/BOOT/FORGEOS.EFI
    linux ($esp)/EFI/BOOT/FORGEOS.EFI $linux_common rdinit=/sbin/init i915.enable_psr=0 i915.fastboot=0
    initrd ($esp)/EFI/BOOT/rootfs.cpio.gz
}

menuentry "ForgeOS - systemd initramfs framebuffer safe mode" {
    search --no-floppy --file --set=esp /EFI/BOOT/FORGEOS.EFI
    linux ($esp)/EFI/BOOT/FORGEOS.EFI $linux_common $initrd_common nomodeset
    initrd ($esp)/EFI/BOOT/rootfs.cpio.gz
}

menuentry "ForgeOS - systemd initramfs fixed GRUB framebuffer" {
    search --no-floppy --file --set=esp /EFI/BOOT/FORGEOS.EFI
    set gfxmode=1024x768
    set gfxpayload=keep
    linux ($esp)/EFI/BOOT/FORGEOS.EFI $linux_common $initrd_common nomodeset video=efifb:1024x768 fbcon=map:0 fbcon=font:VGA8x16
    initrd ($esp)/EFI/BOOT/rootfs.cpio.gz
}

menuentry "ForgeOS - EFI stub chainload" {
    search --no-floppy --file --set=esp /EFI/BOOT/FORGEOS.EFI
    chainloader ($esp)/EFI/BOOT/FORGEOS.EFI
}
EOF
    elif [[ "$DESKTOP" == "gnome" ]]; then
        cat >> "$GRUB_CFG" <<'EOF'

menuentry "ForgeOS GNOME - graphical target" {
    search --no-floppy --file --set=esp /EFI/BOOT/FORGEOS.EFI
    linux ($esp)/EFI/BOOT/FORGEOS.EFI $linux_common systemd.unit=graphical.target
}

menuentry "ForgeOS - EFI stub chainload" {
    search --no-floppy --file --set=esp /EFI/BOOT/FORGEOS.EFI
    chainloader ($esp)/EFI/BOOT/FORGEOS.EFI
}
EOF
    else
        cat >> "$GRUB_CFG" <<'EOF'

menuentry "ForgeOS Openbox desktop" {
    search --no-floppy --file --set=esp /EFI/BOOT/FORGEOS.EFI
    linux ($esp)/EFI/BOOT/FORGEOS.EFI $linux_common systemd.unit=multi-user.target
}

menuentry "ForgeOS - EFI stub chainload" {
    search --no-floppy --file --set=esp /EFI/BOOT/FORGEOS.EFI
    chainloader ($esp)/EFI/BOOT/FORGEOS.EFI
}
EOF
    fi
}

prepare_efi_loader() {
    case "$BOOTLOADER" in
        stub)
            "$ROOT_DIR/scripts/sign-efi-loader.sh" "$OUT_DIR/bzImage" "$EFI_LOADER"
            install -m 0644 "$OUT_DIR/bzImage" "$EFI_KERNEL"
            ;;
        grub)
            if truthy "$SECURE_BOOT"; then
                die "BOOTLOADER=grub does not support SECURE_BOOT=1 yet; use BOOTLOADER=stub or disable Secure Boot"
            fi
            require_cmd grub-mkstandalone
            write_grub_config
            msg "building GRUB UEFI fallback loader"
            grub-mkstandalone \
                -O x86_64-efi \
                -o "$EFI_LOADER" \
                --modules="part_gpt fat search search_fs_file linux chain all_video efi_gop efi_uga gfxterm font video video_fb" \
                "boot/grub/grub.cfg=$GRUB_CFG" >/dev/null
            install -m 0644 "$OUT_DIR/bzImage" "$EFI_KERNEL"
            ;;
        *)
            die "unsupported BOOTLOADER=$BOOTLOADER"
            ;;
    esac
}

msg "preparing EFI loader"
prepare_efi_loader

if atomic_base_enabled; then
    prepare_atomic_image_trees

    BASE_USED_MIB=$(dir_size_mib "$BASE_ROOTFS_STAGING_DIR")
    APP_USED_MIB=$(dir_size_mib "$APPFS_STAGING_DIR")
    BASE_HEADROOM_MIB=${BASE_HEADROOM_MIB:-256}
    APP_HEADROOM_MIB=${APP_HEADROOM_MIB:-1024}
    BASE_SIZE_MIB=${BASE_SIZE_MIB:-$((BASE_USED_MIB + BASE_HEADROOM_MIB))}
    BASE_MIN_MIB=$((BASE_USED_MIB + 64))
    APP_MIN_MIB=$((APP_USED_MIB + APP_HEADROOM_MIB))
    BASE_END_MIB=$((ESP_END_MIB + BASE_SIZE_MIB))
    APP_SIZE_MIB=$((IMAGE_SIZE_MIB - BASE_END_MIB))

    (( BASE_SIZE_MIB >= BASE_MIN_MIB )) || die "BASE_SIZE_MIB=$BASE_SIZE_MIB is too small; need at least ${BASE_MIN_MIB}MiB"
    (( APP_SIZE_MIB >= APP_MIN_MIB )) || die "IMAGE_SIZE_MIB=$IMAGE_SIZE_MIB leaves ${APP_SIZE_MIB}MiB for apps; need at least ${APP_MIN_MIB}MiB"

    msg "atomic layout: ${BASE_SIZE_MIB}MiB base root, ${APP_SIZE_MIB}MiB writable app/state layer"
fi

msg "creating raw image $IMAGE_PATH"
rm -f "$IMAGE_PATH" "$ESP_IMAGE" "$ROOT_IMAGE" "$APP_IMAGE"
qemu-img create -f raw "$IMAGE_PATH" "${IMAGE_SIZE_MIB}M" >/dev/null
parted -s "$IMAGE_PATH" mklabel gpt
parted -s "$IMAGE_PATH" mkpart ESP fat32 1MiB "${ESP_END_MIB}MiB"
parted -s "$IMAGE_PATH" set 1 esp on
if [[ "$APP_IMAGE_NEEDED" -eq 1 ]]; then
    parted -s "$IMAGE_PATH" mkpart root ext4 "${ESP_END_MIB}MiB" "${BASE_END_MIB}MiB"
    parted -s "$IMAGE_PATH" mkpart apps ext4 "${BASE_END_MIB}MiB" 100%
else
    parted -s "$IMAGE_PATH" mkpart root ext4 "${ESP_END_MIB}MiB" 100%
fi

ESP_OFFSET=$(partition_field 1 2)
ESP_SIZE=$(partition_field 1 4)
ROOT_OFFSET=$(partition_field 2 2)
ROOT_SIZE=$(partition_field 2 4)
if [[ "$APP_IMAGE_NEEDED" -eq 1 ]]; then
    APP_OFFSET=$(partition_field 3 2)
    APP_SIZE=$(partition_field 3 4)
else
    APP_OFFSET=
    APP_SIZE=
fi

[[ -n "$ESP_OFFSET" && -n "$ESP_SIZE" && -n "$ROOT_OFFSET" && -n "$ROOT_SIZE" ]] || die "failed to parse partition layout"
if [[ "$APP_IMAGE_NEEDED" -eq 1 ]]; then
    [[ -n "$APP_OFFSET" && -n "$APP_SIZE" ]] || die "failed to parse app partition layout"
fi

msg "building EFI partition image"
truncate -s "$ESP_SIZE" "$ESP_IMAGE"
mkfs.vfat -F 32 -n "$EFI_LABEL" "$ESP_IMAGE" >/dev/null
mmd -i "$ESP_IMAGE" ::/EFI
mmd -i "$ESP_IMAGE" ::/EFI/BOOT
mcopy -i "$ESP_IMAGE" "$EFI_LOADER" ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "$ESP_IMAGE" "$EFI_KERNEL" ::/EFI/BOOT/FORGEOS.EFI
if [[ "$DESKTOP" != "gnome" ]] && ! truthy "$ENABLE_DESKTOP"; then
    mcopy -i "$ESP_IMAGE" "$EFI_INITRD" ::/EFI/BOOT/rootfs.cpio.gz
fi

msg "building ext4 root partition image"
build_ext4_image "$ROOT_LABEL" "$IMAGE_ROOTFS_DIR" "$ROOT_IMAGE" "$ROOT_SIZE"

if [[ "$APP_IMAGE_NEEDED" -eq 1 ]]; then
    msg "building ext4 app/state partition image"
    build_ext4_image "$APP_LABEL" "$APPFS_STAGING_DIR" "$APP_IMAGE" "$APP_SIZE"
fi

msg "embedding partitions into raw disk image"
dd if="$ESP_IMAGE" of="$IMAGE_PATH" bs=4M seek="$ESP_OFFSET" oflag=seek_bytes conv=notrunc status=none
dd if="$ROOT_IMAGE" of="$IMAGE_PATH" bs=4M seek="$ROOT_OFFSET" oflag=seek_bytes conv=notrunc status=none
if [[ "$APP_IMAGE_NEEDED" -eq 1 ]]; then
    dd if="$APP_IMAGE" of="$IMAGE_PATH" bs=4M seek="$APP_OFFSET" oflag=seek_bytes conv=notrunc status=none
fi

sync
msg "disk image ready: $IMAGE_PATH"
