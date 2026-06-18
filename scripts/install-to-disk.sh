#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/common.sh"

IMAGE_PATH="$OUT_DIR/forgeos-${KERNEL_VERSION}.img"
DEVICE=""
AUTO_CONFIRM=0
EXPAND_WRITABLE=1
LIST_ONLY=0
RANDOMIZE_FS_UUIDS=1
UNMOUNT_TARGET=0
CUSTOM_IMAGE=0

usage() {
    cat <<'EOF'
Usage:
  install-to-disk.sh --list
  install-to-disk.sh --device /dev/sdX [options]

Options:
  --device PATH              Target disk to erase and install to.
  --image PATH               Raw ForgeOS image to install.
  --list                     Show candidate disk devices and exit.
  --yes                      Skip the interactive destruction prompt.
  --unmount                  Unmount non-critical mounted target partitions first.
  --no-expand-apps           Keep the writable app/state partition at the image's built size.
  --no-expand-root           Legacy alias for --no-expand-apps.
  --keep-uuids               Preserve ext4 filesystem UUIDs.
  --keep-root-uuid           Legacy alias for --keep-uuids.
  --help                     Show this help text.

Examples:
  ./scripts/install-to-disk.sh --list
  sudo ./scripts/install-to-disk.sh --device /dev/nvme0n1
  sudo ./scripts/install-to-disk.sh --device /dev/sdc --yes --unmount
EOF
}

partition_path() {
    local disk=$1
    local partition=$2

    if [[ "$disk" =~ [0-9]$ ]]; then
        printf '%sp%s\n' "$disk" "$partition"
    else
        printf '%s%s\n' "$disk" "$partition"
    fi
}

list_disks() {
    local line
    local name
    local type
    local size
    local transport
    local model

    msg "candidate disks"
    printf '%-16s %-8s %-8s %-24s %s\n' "DEVICE" "TYPE" "SIZE" "TRANSPORT" "MODEL"

    while IFS= read -r line; do
        name=${line#*NAME=\"}
        name=${name%%\"*}
        type=${line#*TYPE=\"}
        type=${type%%\"*}
        size=${line#*SIZE=\"}
        size=${size%%\"*}
        transport=${line#*TRAN=\"}
        transport=${transport%%\"*}
        model=${line#*MODEL=\"}
        model=${model%%\"*}

        [[ "$type" == "disk" ]] || continue

        printf '%-16s %-8s %-8s %-24s %s\n' \
            "$name" \
            "$type" \
            "$size" \
            "${transport:--}" \
            "${model:--}"
    done < <(lsblk -dpP -o NAME,TYPE,SIZE,TRAN,MODEL)
}

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "installer must run as root"
}

device_type() {
    lsblk -dnpo TYPE "$1" 2>/dev/null | head -n1
}

device_size_bytes() {
    blockdev --getsize64 "$1"
}

critical_source_on_target() {
    local source=$1
    local child
    local parent

    [[ -n "$source" ]] || return 1

    if [[ "$source" == "$DEVICE" ]]; then
        return 0
    fi

    while IFS= read -r child; do
        [[ -n "$child" ]] || continue
        if [[ "$source" == "$child" ]]; then
            return 0
        fi
    done < <(lsblk -lnpo NAME "$DEVICE")

    parent=$(lsblk -dnro PKNAME "$source" 2>/dev/null | tail -n1 || true)
    [[ -n "$parent" && "/dev/$parent" == "$DEVICE" ]]
}

ensure_target_is_safe() {
    local source
    local critical_mount

    [[ -b "$DEVICE" ]] || die "target is not a block device: $DEVICE"

    case "$(device_type "$DEVICE")" in
        disk) ;;
        *)
            die "refusing to install to non-disk target: $DEVICE"
            ;;
    esac

    for critical_mount in / /boot /boot/efi /home /nix /var /forge /opt /usr/local; do
        source=$(findmnt -nr -o SOURCE "$critical_mount" 2>/dev/null || true)
        if critical_source_on_target "$source"; then
            die "refusing to overwrite active system storage mounted at $critical_mount"
        fi
    done
}

collect_mounted_children() {
    lsblk -lnpo NAME,MOUNTPOINT "$DEVICE" | awk '$2 != "" {print $1 "|" $2}'
}

unmount_target_children() {
    local -a mounts=()
    local i
    local entry
    local part
    local mountpoint

    mapfile -t mounts < <(collect_mounted_children)
    [[ "${#mounts[@]}" -gt 0 ]] || return 0

    if [[ "$UNMOUNT_TARGET" -ne 1 ]]; then
        printf 'Mounted target partitions detected:\n' >&2
        printf '  %s\n' "${mounts[@]//|/ mounted at }" >&2
        die "unmount them first or rerun with --unmount"
    fi

    for entry in "${mounts[@]}"; do
        part=${entry%%|*}
        mountpoint=${entry#*|}
        case "$mountpoint" in
            /|/boot|/boot/efi|/home|/nix|/var|/forge|/opt|/usr/local)
                die "refusing to unmount critical mountpoint $mountpoint on $part"
                ;;
        esac
    done

    for ((i=${#mounts[@]} - 1; i>=0; i--)); do
        entry=${mounts[$i]}
        part=${entry%%|*}
        mountpoint=${entry#*|}
        msg "unmounting $part from $mountpoint"
        umount "$part"
    done
}

wait_for_block() {
    local path=$1
    local attempt

    for attempt in $(seq 1 20); do
        [[ -b "$path" ]] && return 0
        udevadm settle >/dev/null 2>&1 || true
        sleep 0.5
    done

    die "timed out waiting for block device $path"
}

build_default_image_if_needed() {
    if [[ "$CUSTOM_IMAGE" -eq 0 && ! -f "$IMAGE_PATH" ]]; then
        msg "default image missing, building it first"
        "$ROOT_DIR/scripts/build-image.sh"
    fi

    [[ -f "$IMAGE_PATH" ]] || die "missing image: $IMAGE_PATH"
}

confirm_install() {
    msg "target disk"
    lsblk -dpno NAME,SIZE,MODEL,TRAN "$DEVICE"
    msg "source image"
    ls -lh "$IMAGE_PATH"

    if [[ "$AUTO_CONFIRM" -eq 1 ]]; then
        return
    fi

    printf 'Type INSTALL to erase %s and continue: ' "$DEVICE"
    read -r reply
    [[ "$reply" == "INSTALL" ]] || die "installation aborted"
}

write_image() {
    msg "writing image to $DEVICE"
    dd if="$IMAGE_PATH" of="$DEVICE" bs=16M iflag=fullblock conv=fsync status=progress
    sync
}

repair_and_rescan_partitions() {
    msg "repairing GPT backup header"
    parted -s -f "$DEVICE" print >/dev/null
    partprobe "$DEVICE" >/dev/null 2>&1 || true
    udevadm settle >/dev/null 2>&1 || true
}

partition_fstype() {
    lsblk -dnro FSTYPE "$1" 2>/dev/null | head -n1
}

partition_partlabel() {
    lsblk -dnro PARTLABEL "$1" 2>/dev/null | head -n1
}

partition_label() {
    lsblk -dnro LABEL "$1" 2>/dev/null | head -n1
}

partition_number() {
    lsblk -dnro PARTN "$1" 2>/dev/null | head -n1
}

device_partitions() {
    lsblk -lnpo NAME "$DEVICE" | awk 'NR > 1 { print $1 }'
}

writable_partition_path() {
    local part
    local partlabel
    local fs_label
    local last_ext4=

    while IFS= read -r part; do
        [[ -b "$part" ]] || continue
        partlabel=$(partition_partlabel "$part")
        fs_label=$(partition_label "$part")
        if [[ "$partlabel" == "apps" || "$fs_label" == "$APP_LABEL" ]]; then
            printf '%s\n' "$part"
            return 0
        fi

        if [[ "$(partition_fstype "$part")" == "ext4" ]]; then
            last_ext4=$part
        fi
    done < <(device_partitions)

    [[ -n "$last_ext4" ]] || return 1
    printf '%s\n' "$last_ext4"
}

writable_partition_name() {
    local part=$1
    local partlabel
    local fs_label

    partlabel=$(partition_partlabel "$part")
    fs_label=$(partition_label "$part")
    if [[ "$partlabel" == "apps" || "$fs_label" == "$APP_LABEL" ]]; then
        printf 'app/state\n'
    else
        printf 'root\n'
    fi
}

expand_writable_partition() {
    local image_size
    local device_size
    local part_num
    local target_part
    local target_name

    image_size=$(stat -c %s "$IMAGE_PATH")
    device_size=$(device_size_bytes "$DEVICE")
    target_part=$(writable_partition_path) || die "could not locate writable ForgeOS partition on $DEVICE"
    part_num=$(partition_number "$target_part")
    [[ -n "$part_num" ]] || die "could not determine partition number for $target_part"
    target_name=$(writable_partition_name "$target_part")

    wait_for_block "$target_part"

    if (( device_size <= image_size )) || [[ "$EXPAND_WRITABLE" -ne 1 ]]; then
        msg "leaving $target_name partition at image size"
        return
    fi

    msg "expanding $target_name partition to fill the remaining disk"
    parted -s -f "$DEVICE" resizepart "$part_num" 100%
    partprobe "$DEVICE" >/dev/null 2>&1 || true
    udevadm settle >/dev/null 2>&1 || true
    wait_for_block "$target_part"

    msg "checking ext4 $target_name filesystem"
    e2fsck -fy "$target_part" >/dev/null

    msg "resizing ext4 $target_name filesystem"
    resize2fs "$target_part" >/dev/null
}

randomize_ext4_uuids() {
    local part
    local fs_type

    [[ "$RANDOMIZE_FS_UUIDS" -eq 1 ]] || return 0

    while IFS= read -r part; do
        [[ -b "$part" ]] || continue
        fs_type=$(partition_fstype "$part")
        [[ "$fs_type" == "ext4" ]] || continue

        msg "randomizing ext4 filesystem UUID on $part"
        tune2fs -U random "$part" >/dev/null
    done < <(device_partitions)
}

print_summary() {
    msg "installed disk layout"
    lsblk -o NAME,SIZE,FSTYPE,PARTLABEL,LABEL,UUID,MOUNTPOINT "$DEVICE"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --device)
            [[ $# -ge 2 ]] || die "--device requires a value"
            DEVICE=$2
            shift 2
            ;;
        --image)
            [[ $# -ge 2 ]] || die "--image requires a value"
            IMAGE_PATH=$2
            CUSTOM_IMAGE=1
            shift 2
            ;;
        --list)
            LIST_ONLY=1
            shift
            ;;
        --yes)
            AUTO_CONFIRM=1
            shift
            ;;
        --unmount)
            UNMOUNT_TARGET=1
            shift
            ;;
        --no-expand-apps|--no-expand-root)
            EXPAND_WRITABLE=0
            shift
            ;;
        --keep-uuids|--keep-root-uuid)
            RANDOMIZE_FS_UUIDS=0
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

if [[ "$LIST_ONLY" -eq 1 ]]; then
    list_disks
    exit 0
fi

[[ -n "$DEVICE" ]] || die "missing required --device argument"

require_cmd lsblk findmnt parted partprobe dd blockdev e2fsck resize2fs tune2fs udevadm flock awk
require_root
ensure_dirs

exec 9>"/tmp/forgeos-install.lock"
flock -n 9 || die "another ForgeOS installer is already running"

build_default_image_if_needed
ensure_target_is_safe
unmount_target_children

if (( $(device_size_bytes "$DEVICE") < $(stat -c %s "$IMAGE_PATH") )); then
    die "target disk is smaller than the ForgeOS image"
fi

confirm_install
write_image
repair_and_rescan_partitions
expand_writable_partition
randomize_ext4_uuids
repair_and_rescan_partitions
print_summary

msg "installation complete"
msg "UEFI boots from EFI/BOOT/BOOTX64.EFI on the target disk"
