#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

APT_UPDATE=1
DRY_RUN=0
CHECK_ONLY=0

packages=(
    build-essential
    bc
    bison
    flex
    ca-certificates
    curl
    tar
    xz-utils
    bzip2
    gzip
    cpio
    rsync
    file
    pkg-config
    meson
    ninja-build
    gperf
    python3
    perl
    kmod
    openssl
    libcrypt-dev
    libcap-dev
    libmount-dev
    libblkid-dev
    libexpat1-dev
    zlib1g-dev
    libzstd-dev
    libssl-dev
    libelf-dev
    qemu-system-x86
)

required_commands=(
    bash
    make
    gcc
    curl
    tar
    xz
    bzip2
    gzip
    cpio
    rsync
    file
    pkg-config
    meson
    ninja
    gperf
    python3
    perl
    depmod
    openssl
    ldd
    ldconfig
    install
    qemu-system-x86_64
)

usage() {
    cat <<EOF
Usage: scripts/install-deps.sh [options]

Install Debian/Ubuntu host packages needed for:
  make rootfs
  make run

Options:
  --check       Only verify packages and commands; do not install.
  --dry-run     Print the apt commands that would run; do not install.
  --no-update   Skip apt-get update before installing.
  --help        Show this help.

This does not install desktop, GNOME, disk-image, installer, or Secure Boot
extras. It is intentionally scoped to the console rootfs and direct QEMU run
path.
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

if [[ "$(uname -m)" != "x86_64" ]]; then
    printf 'warning: ForgeOS currently expects a native x86_64 build host; this host is %s\n' "$(uname -m)" >&2
fi

if ! command -v apt-get >/dev/null 2>&1; then
    printf 'error: apt-get was not found. Install equivalent packages manually:\n' >&2
    printf '  %s\n' "${packages[*]}" >&2
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
for package in "${packages[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -qx 'install ok installed'; then
        missing_packages+=("$package")
    fi
done

if [[ "$CHECK_ONLY" -eq 1 ]]; then
    if [[ "${#missing_packages[@]}" -gt 0 ]]; then
        printf 'missing packages:\n' >&2
        printf '  %s\n' "${missing_packages[@]}" >&2
        exit 1
    fi
else
    if [[ "${#missing_packages[@]}" -eq 0 ]]; then
        msg "all required packages are already installed"
    else
        if [[ "$EUID" -eq 0 ]]; then
            sudo_cmd=()
        elif command -v sudo >/dev/null 2>&1; then
            sudo_cmd=(sudo)
        else
            die "missing packages require root privileges and sudo is not installed"
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

        msg "installing ForgeOS rootfs/run dependencies"
        "${sudo_cmd[@]}" apt-get install -y --no-install-recommends "${missing_packages[@]}"
    fi
fi

missing_commands=()
for tool in "${required_commands[@]}"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        missing_commands+=("$tool")
    fi
done

if [[ "${#missing_commands[@]}" -gt 0 ]]; then
    printf 'missing commands after dependency check:\n' >&2
    printf '  %s\n' "${missing_commands[@]}" >&2
    exit 1
fi

msg "host dependencies are ready for make rootfs and make run"
msg "project: $ROOT_DIR"
