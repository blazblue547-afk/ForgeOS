#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/common.sh"

require_cmd meson ninja pkg-config "$CC" file ldd ldconfig install bison flex
ensure_dirs

[[ -z "$CROSS_COMPILE" ]] || die "Linux-PAM rootfs staging currently requires a native build; CROSS_COMPILE is not supported"
[[ "$ARCH" == "x86_64" ]] || die "Linux-PAM rootfs staging currently supports ARCH=x86_64 only"
[[ -d "$PAM_SRC_DIR" ]] || "$ROOT_DIR/scripts/fetch-sources.sh"

copy_runtime_dep() {
    local dep=$1
    local dest

    [[ -e "$dep" ]] || return 0
    dest="$PAM_STAGING_DIR$dep"
    mkdir -p "$(dirname "$dest")"
    install -Dm755 "$dep" "$dest"
}

copy_elf_deps() {
    local elf=$1
    local line dep

    LD_LIBRARY_PATH="$PAM_STAGING_DIR/usr/lib:${LD_LIBRARY_PATH:-}" ldd "$elf" 2>/dev/null | while IFS= read -r line; do
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
        case "$dep" in
            "$PAM_STAGING_DIR"/*)
                continue
                ;;
        esac
        copy_runtime_dep "$dep"
    done
}

msg "configuring Linux-PAM ${PAM_VERSION}"
rm -rf "$PAM_BUILD_DIR" "$PAM_STAGING_DIR"
mkdir -p "$PAM_BUILD_DIR" "$PAM_STAGING_DIR"

meson setup "$PAM_BUILD_DIR" "$PAM_SRC_DIR" \
    --prefix=/usr \
    --libdir=lib \
    --sysconfdir=/etc \
    --localstatedir=/var \
    -Ddocs=disabled \
    -Di18n=disabled \
    -Daudit=disabled \
    -Deconf=disabled \
    -Dlogind=disabled \
    -Delogind=disabled \
    -Dopenssl=disabled \
    -Dpwaccess=disabled \
    -Dselinux=disabled \
    -Dnis=disabled \
    -Dexamples=false \
    -Dxtests=false \
    -Dpam_userdb=disabled \
    -Dpam_lastlog=disabled \
    -Dpam_unix=enabled \
    -Dsecuredir=/usr/lib/security \
    -Dsconfigdir=/etc/security \
    -Dvendordir=/usr/share/pam

msg "building Linux-PAM ${PAM_VERSION}"
meson compile -C "$PAM_BUILD_DIR" -j "$JOBS"

msg "installing Linux-PAM ${PAM_VERSION}"
DESTDIR="$PAM_STAGING_DIR" meson install -C "$PAM_BUILD_DIR" --no-rebuild

mkdir -p "$PAM_BUILD_DIR/pkgconfig"
for pc in pam pam_misc pamc; do
    sed "s|^prefix=.*|prefix=$PAM_STAGING_DIR/usr|" \
        "$PAM_STAGING_DIR/usr/lib/pkgconfig/$pc.pc" > "$PAM_BUILD_DIR/pkgconfig/$pc.pc"
done

msg "copying Linux-PAM runtime library dependencies"
while IFS= read -r -d '' elf; do
    file_type=$(file -b "$elf" 2>/dev/null || true)
    case "$file_type" in
        *ELF*) copy_elf_deps "$elf" ;;
    esac
done < <(find "$PAM_STAGING_DIR" -type f \( -perm /111 -o -name '*.so' -o -name '*.so.*' \) -print0)

[[ -e "$PAM_STAGING_DIR/usr/lib/libpam.so" ]] || die "libpam was not installed"
[[ -e "$PAM_STAGING_DIR/usr/lib/libpam_misc.so" ]] || die "libpam_misc was not installed"
[[ -f "$PAM_STAGING_DIR/usr/include/security/pam_appl.h" ]] || die "PAM headers were not installed"
[[ -f "$PAM_STAGING_DIR/usr/lib/pkgconfig/pam.pc" ]] || die "PAM pkg-config file was not installed"
[[ -f "$PAM_STAGING_DIR/usr/lib/security/pam_unix.so" ]] || die "pam_unix module was not installed"
[[ -f "$PAM_STAGING_DIR/usr/lib/security/pam_deny.so" ]] || die "pam_deny module was not installed"
[[ -f "$PAM_STAGING_DIR/usr/lib/security/pam_permit.so" ]] || die "pam_permit module was not installed"

touch "$PAM_STAGING_DIR/.forgeos-pam-complete"
msg "Linux-PAM staging tree: $PAM_STAGING_DIR"
