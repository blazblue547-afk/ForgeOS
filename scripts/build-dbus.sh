#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/common.sh"

require_cmd meson ninja pkg-config "$CC" file ldd install tar xz
ensure_dirs

[[ -z "$CROSS_COMPILE" ]] || die "D-Bus rootfs staging currently requires a native build; CROSS_COMPILE is not supported"
[[ "$ARCH" == "x86_64" ]] || die "D-Bus rootfs staging currently supports ARCH=x86_64 only"
[[ -d "$DBUS_SRC_DIR" ]] || "$ROOT_DIR/scripts/fetch-sources.sh"

copy_runtime_dep() {
    local dep=$1
    local dest

    [[ -e "$dep" ]] || return 0
    dest="$DBUS_STAGING_DIR$dep"
    mkdir -p "$(dirname "$dest")"
    install -Dm755 "$dep" "$dest"
}

copy_elf_deps() {
    local elf=$1
    local line dep

    ldd "$elf" 2>/dev/null | while IFS= read -r line; do
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

msg "configuring D-Bus ${DBUS_VERSION}"
rm -rf "$DBUS_BUILD_DIR" "$DBUS_STAGING_DIR"
mkdir -p "$DBUS_BUILD_DIR" "$DBUS_STAGING_DIR"

meson setup "$DBUS_BUILD_DIR" "$DBUS_SRC_DIR" \
    --prefix=/usr \
    --libdir=lib \
    --libexecdir=libexec \
    --sysconfdir=/etc \
    --localstatedir=/var \
    --buildtype=release \
    -Dmessage_bus=true \
    -Dtools=true \
    -Dsystemd=enabled \
    -Dsystemd_system_unitdir=/usr/lib/systemd/system \
    -Dsystemd_user_unitdir=/usr/lib/systemd/user \
    -Duser_session=false \
    -Ddbus_user=messagebus \
    -Druntime_dir=/run \
    -Dsystem_socket=/run/dbus/system_bus_socket \
    -Dsystem_pid_file=/run/dbus/pid \
    -Dsession_socket_dir=/tmp \
    -Dtest_socket_dir=/tmp \
    -Dtraditional_activation=false \
    -Dapparmor=disabled \
    -Dselinux=disabled \
    -Dlibaudit=disabled \
    -Dlaunchd=disabled \
    -Dx11_autolaunch=disabled \
    -Dinstalled_tests=false \
    -Dintrusive_tests=false \
    -Dmodular_tests=disabled \
    -Ddoxygen_docs=disabled \
    -Dducktype_docs=disabled \
    -Dxml_docs=disabled \
    -Dqt_help=disabled \
    -Drelocation=disabled \
    -Dvalgrind=disabled \
    -Dstats=false

msg "building D-Bus ${DBUS_VERSION}"
meson compile -C "$DBUS_BUILD_DIR" -j "$JOBS"

msg "installing D-Bus ${DBUS_VERSION}"
DESTDIR="$DBUS_STAGING_DIR" meson install -C "$DBUS_BUILD_DIR" --no-rebuild

msg "copying D-Bus runtime library dependencies"
while IFS= read -r -d '' elf; do
    file_type=$(file -b "$elf" 2>/dev/null || true)
    case "$file_type" in
        *ELF*) copy_elf_deps "$elf" ;;
    esac
done < <(find "$DBUS_STAGING_DIR" -type f \( -perm /111 -o -name '*.so' -o -name '*.so.*' \) -print0)

[[ -x "$DBUS_STAGING_DIR/usr/bin/dbus-daemon" ]] || die "dbus-daemon binary was not installed"
[[ -S "$DBUS_STAGING_DIR/run/dbus/system_bus_socket" ]] && die "unexpected build-time system bus socket in staging"
touch "$DBUS_STAGING_DIR/.forgeos-dbus-complete"
msg "D-Bus staging tree: $DBUS_STAGING_DIR"
