#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

APT_UPDATE=1
DRY_RUN=0
CHECK_ONLY=0

image_packages=(
    qemu-utils
    parted
    dosfstools
    e2fsprogs
    mtools
    grub-common
    grub-efi-amd64-bin
    ovmf
    fakeroot
)

required_commands=(
    qemu-img
    parted
    mkfs.vfat
    mkfs.ext4
    mcopy
    mmd
    grub-mkstandalone
    dd
    awk
    truncate
    qemu-system-x86_64
    fakeroot
)

required_paths=(
    /usr/lib/grub/x86_64-efi
    /usr/share/OVMF/OVMF_CODE_4M.fd
    /usr/share/OVMF/OVMF_VARS_4M.fd
)

usage() {
    cat <<EOF
Usage: scripts/install-image-deps.sh [options]

Install Debian/Ubuntu host packages needed for:
  make image
  make run-image

Options:
  --check       Only verify packages, commands, and firmware files; do not install.
  --dry-run     Print the apt commands that would run; do not install.
  --no-update   Skip apt-get update before installing.
  --help        Show this help.

This script first checks the console rootfs/run dependencies through
scripts/install-deps.sh, then installs the extra disk image and UEFI QEMU
dependencies. It does not install desktop, GNOME, host installer, or Secure Boot
signing extras.
EOF
}

msg() {
    printf '==> %s\n' "$*"
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)
            CHECK_ONLY=1
            ;;
        --dry-run)
            DRY_RUN=1
            ;;
        --no-update)
            APT_UPDATE=0
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
    shift
done

if [[ ! -x "$ROOT_DIR/scripts/install-deps.sh" ]]; then
    die "missing executable rootfs dependency installer: $ROOT_DIR/scripts/install-deps.sh"
fi

rootfs_args=()
[[ "$CHECK_ONLY" -eq 1 ]] && rootfs_args+=(--check)
[[ "$DRY_RUN" -eq 1 ]] && rootfs_args+=(--dry-run)
[[ "$APT_UPDATE" -eq 0 ]] && rootfs_args+=(--no-update)

rootfs_failed=0
if [[ "$CHECK_ONLY" -eq 1 ]]; then
    if ! "$ROOT_DIR/scripts/install-deps.sh" "${rootfs_args[@]}"; then
        rootfs_failed=1
    fi
else
    "$ROOT_DIR/scripts/install-deps.sh" "${rootfs_args[@]}"
fi

if ! command -v apt-get >/dev/null 2>&1; then
    printf 'error: apt-get was not found. Install equivalent image packages manually:\n' >&2
    printf '  %s\n' "${image_packages[*]}" >&2
    exit 1
fi

if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    os_family="${ID:-} ${ID_LIKE:-}"
    case " $os_family " in
        *" debian "*|*" ubuntu "*) ;;
        *)
            printf 'warning: this script is tested on Debian/Ubuntu hosts; detected ID=%s ID_LIKE=%s\n' "${ID:-unknown}" "${ID_LIKE:-unknown}" >&2
            ;;
    esac
fi

missing_packages=()
for package in "${image_packages[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -qx 'install ok installed'; then
        missing_packages+=("$package")
    fi
done

if [[ "$CHECK_ONLY" -eq 1 ]]; then
    if [[ "${#missing_packages[@]}" -gt 0 ]]; then
        printf 'missing image packages:\n' >&2
        printf '  %s\n' "${missing_packages[@]}" >&2
    fi
else
    if [[ "${#missing_packages[@]}" -eq 0 ]]; then
        msg "all required image packages are already installed"
    else
        if [[ "$EUID" -eq 0 ]]; then
            sudo_cmd=()
        elif command -v sudo >/dev/null 2>&1; then
            sudo_cmd=(sudo)
        else
            die "missing image packages require root privileges and sudo is not installed"
        fi

        if [[ "$DRY_RUN" -eq 1 ]]; then
            [[ "$APT_UPDATE" -eq 1 ]] && printf '%q ' "${sudo_cmd[@]}" apt-get update && printf '\n'
            printf '%q ' "${sudo_cmd[@]}" apt-get install -y --no-install-recommends "${missing_packages[@]}"
            printf '\n'
            exit 0
        fi

        if [[ "$APT_UPDATE" -eq 1 ]]; then
            msg "updating apt package indexes"
            "${sudo_cmd[@]}" apt-get update
        fi

        msg "installing ForgeOS image/run-image dependencies"
        "${sudo_cmd[@]}" apt-get install -y --no-install-recommends "${missing_packages[@]}"
    fi
fi

missing_commands=()
for tool in "${required_commands[@]}"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        missing_commands+=("$tool")
    fi
done

missing_paths=()
for path in "${required_paths[@]}"; do
    if [[ ! -e "$path" ]]; then
        missing_paths+=("$path")
    fi
done

failed=0
if [[ "$rootfs_failed" -ne 0 ]]; then
    failed=1
fi
if [[ "${#missing_packages[@]}" -gt 0 && "$CHECK_ONLY" -eq 1 ]]; then
    failed=1
fi
if [[ "${#missing_commands[@]}" -gt 0 ]]; then
    printf 'missing commands after image dependency check:\n' >&2
    printf '  %s\n' "${missing_commands[@]}" >&2
    failed=1
fi
if [[ "${#missing_paths[@]}" -gt 0 ]]; then
    printf 'missing files after image dependency check:\n' >&2
    printf '  %s\n' "${missing_paths[@]}" >&2
    failed=1
fi

if [[ "$failed" -ne 0 ]]; then
    exit 1
fi

msg "host dependencies are ready for make image and make run-image"
msg "project: $ROOT_DIR"
