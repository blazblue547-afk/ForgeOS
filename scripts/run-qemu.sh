#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/common.sh"

require_cmd qemu-system-x86_64
ensure_dirs

MODE=${1:-direct}
MEMORY_MB=${MEMORY_MB:-2048}
SMP_CPUS=${SMP_CPUS:-2}
QEMU_DISPLAY=${QEMU_DISPLAY:-gtk}

find_uefi_mode() {
    if [[ -n "${UEFI_FIRMWARE:-}" && -f "${UEFI_FIRMWARE}" ]]; then
        printf 'bios:%s\n' "$UEFI_FIRMWARE"
        return
    fi

    if [[ -f "/usr/share/OVMF/OVMF_CODE_4M.fd" && -f "/usr/share/OVMF/OVMF_VARS_4M.fd" ]]; then
        printf 'pflash:/usr/share/OVMF/OVMF_CODE_4M.fd:/usr/share/OVMF/OVMF_VARS_4M.fd\n'
        return
    fi

    if [[ -f "/home/joe/QEMU_EFI.fd" ]]; then
        printf 'bios:/home/joe/QEMU_EFI.fd\n'
        return
    fi

    return 1
}

case "$MODE" in
    direct)
        [[ -f "$OUT_DIR/bzImage" ]] || die "missing $OUT_DIR/bzImage"
        [[ -f "$OUT_DIR/rootfs.cpio.gz" ]] || die "missing $OUT_DIR/rootfs.cpio.gz"
        exec qemu-system-x86_64 \
            -m "$MEMORY_MB" \
            -smp "$SMP_CPUS" \
            -cpu max \
            -display none \
            -serial mon:stdio \
            -kernel "$OUT_DIR/bzImage" \
            -initrd "$OUT_DIR/rootfs.cpio.gz" \
            -append "console=ttyS0 rdinit=/sbin/init loglevel=4" \
            -device virtio-rng-pci
        ;;
    image)
        UEFI_MODE=$(find_uefi_mode) || die "no usable UEFI firmware found"
        IMAGE_PATH="$OUT_DIR/forgeos-${KERNEL_VERSION}.img"
        [[ -f "$IMAGE_PATH" ]] || die "missing $IMAGE_PATH"

        case "$UEFI_MODE" in
            bios:*)
                FIRMWARE=${UEFI_MODE#bios:}
                exec qemu-system-x86_64 \
                    -m "$MEMORY_MB" \
                    -smp "$SMP_CPUS" \
                    -cpu max \
                    -serial mon:stdio \
                    -display none \
                    -boot order=c \
                    -bios "$FIRMWARE" \
                    -drive file="$IMAGE_PATH",format=raw,if=virtio \
                    -netdev user,id=net0 \
                    -device virtio-net-pci,netdev=net0 \
                    -device virtio-rng-pci
                ;;
            pflash:*)
                CODE_FD=${UEFI_MODE#pflash:}
                CODE_FD=${CODE_FD%%:*}
                VARS_FD=${UEFI_MODE##*:}
                VARS_COPY=$(mktemp /tmp/forgeos-ovmf-vars.XXXXXX.fd)
                cp "$VARS_FD" "$VARS_COPY"
                qemu-system-x86_64 \
                    -m "$MEMORY_MB" \
                    -smp "$SMP_CPUS" \
                    -cpu max \
                    -serial mon:stdio \
                    -display none \
                    -boot order=c \
                    -drive if=pflash,format=raw,readonly=on,file="$CODE_FD" \
                    -drive if=pflash,format=raw,file="$VARS_COPY" \
                    -drive file="$IMAGE_PATH",format=raw,if=virtio \
                    -netdev user,id=net0 \
                    -device virtio-net-pci,netdev=net0 \
                    -device virtio-rng-pci
                rm -f "$VARS_COPY"
                ;;
            *)
                die "unsupported UEFI mode: $UEFI_MODE"
                ;;
        esac
        ;;
    image-gui)
        UEFI_MODE=$(find_uefi_mode) || die "no usable UEFI firmware found"
        IMAGE_PATH="$OUT_DIR/forgeos-${KERNEL_VERSION}.img"
        [[ -f "$IMAGE_PATH" ]] || "$ROOT_DIR/scripts/build-image.sh"

        case "$UEFI_MODE" in
            bios:*)
                FIRMWARE=${UEFI_MODE#bios:}
                exec qemu-system-x86_64 \
                    -m "$MEMORY_MB" \
                    -smp "$SMP_CPUS" \
                    -cpu max \
                    -serial mon:stdio \
                    -display "$QEMU_DISPLAY" \
                    -boot order=c \
                    -bios "$FIRMWARE" \
                    -drive file="$IMAGE_PATH",format=raw,if=virtio \
                    -device virtio-vga \
                    -device qemu-xhci \
                    -device usb-tablet \
                    -device usb-kbd \
                    -device virtio-rng-pci \
                    -netdev user,id=net0 \
                    -device virtio-net-pci,netdev=net0
                ;;
            pflash:*)
                CODE_FD=${UEFI_MODE#pflash:}
                CODE_FD=${CODE_FD%%:*}
                VARS_FD=${UEFI_MODE##*:}
                VARS_COPY=$(mktemp /tmp/forgeos-ovmf-vars.XXXXXX.fd)
                cp "$VARS_FD" "$VARS_COPY"
                qemu-system-x86_64 \
                    -m "$MEMORY_MB" \
                    -smp "$SMP_CPUS" \
                    -cpu max \
                    -serial mon:stdio \
                    -display "$QEMU_DISPLAY" \
                    -boot order=c \
                    -drive if=pflash,format=raw,readonly=on,file="$CODE_FD" \
                    -drive if=pflash,format=raw,file="$VARS_COPY" \
                    -drive file="$IMAGE_PATH",format=raw,if=virtio \
                    -device virtio-vga \
                    -device qemu-xhci \
                    -device usb-tablet \
                    -device usb-kbd \
                    -device virtio-rng-pci \
                    -netdev user,id=net0 \
                    -device virtio-net-pci,netdev=net0
                rm -f "$VARS_COPY"
                ;;
            *)
                die "unsupported UEFI mode: $UEFI_MODE"
                ;;
        esac
        ;;
    *)
        die "usage: $0 {direct|image|image-gui}"
        ;;
esac
