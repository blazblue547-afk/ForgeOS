#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/common.sh"

require_cmd qemu-img parted mkfs.vfat mkfs.ext4 mcopy mmd dd awk truncate
ensure_dirs

normal_rootfs_matches() {
    [[ -d "$ROOTFS_STAGING_DIR" ]] || return 1
    [[ -f "$ROOTFS_STAGING_DIR/etc/forgeos-nix" ]] || return 1

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

write_grub_config() {
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
set linux_common="root=PARTLABEL=root rootfstype=ext4 rootwait rw console=tty0 loglevel=7 ignore_loglevel earlyprintk=efi,keep vt.global_cursor_default=1"
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

msg "creating raw image $IMAGE_PATH"
rm -f "$IMAGE_PATH" "$ESP_IMAGE" "$ROOT_IMAGE"
qemu-img create -f raw "$IMAGE_PATH" "${IMAGE_SIZE_MIB}M" >/dev/null
parted -s "$IMAGE_PATH" mklabel gpt
parted -s "$IMAGE_PATH" mkpart ESP fat32 1MiB "${ESP_END_MIB}MiB"
parted -s "$IMAGE_PATH" set 1 esp on
parted -s "$IMAGE_PATH" mkpart root ext4 "${ESP_END_MIB}MiB" 100%

ESP_OFFSET=$(partition_field 1 2)
ESP_SIZE=$(partition_field 1 4)
ROOT_OFFSET=$(partition_field 2 2)
ROOT_SIZE=$(partition_field 2 4)

[[ -n "$ESP_OFFSET" && -n "$ESP_SIZE" && -n "$ROOT_OFFSET" && -n "$ROOT_SIZE" ]] || die "failed to parse partition layout"

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
truncate -s "$ROOT_SIZE" "$ROOT_IMAGE"
mkfs.ext4 -F -L "$ROOT_LABEL" -d "$ROOTFS_STAGING_DIR" "$ROOT_IMAGE" >/dev/null

msg "embedding partitions into raw disk image"
dd if="$ESP_IMAGE" of="$IMAGE_PATH" bs=4M seek="$ESP_OFFSET" oflag=seek_bytes conv=notrunc status=none
dd if="$ROOT_IMAGE" of="$IMAGE_PATH" bs=4M seek="$ROOT_OFFSET" oflag=seek_bytes conv=notrunc status=none

sync
msg "disk image ready: $IMAGE_PATH"
