#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/common.sh"

require_cmd meson ninja pkg-config "$CC" gperf file ldd ldconfig install tar gzip
ensure_dirs

[[ -z "$CROSS_COMPILE" ]] || die "systemd rootfs staging currently requires a native build; CROSS_COMPILE is not supported"
[[ "$ARCH" == "x86_64" ]] || die "systemd rootfs staging currently supports ARCH=x86_64 only"
[[ -d "$SYSTEMD_SRC_DIR" ]] || "$ROOT_DIR/scripts/fetch-sources.sh"

copy_runtime_dep() {
    local dep=$1
    local dest

    [[ -e "$dep" ]] || return 0
    dest="$SYSTEMD_STAGING_DIR$dep"
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

copy_named_library() {
    local soname=$1
    local ldconfig_output path

    ldconfig_output=$(ldconfig -p 2>/dev/null || true)
    path=$(awk -v soname="$soname" '$1 == soname { print $NF; exit }' <<< "$ldconfig_output")
    [[ -n "$path" ]] || die "could not locate runtime library: $soname"
    copy_runtime_dep "$path"
    copy_elf_deps "$path"
}

msg "configuring systemd ${SYSTEMD_VERSION}"
rm -rf "$SYSTEMD_BUILD_DIR" "$SYSTEMD_STAGING_DIR"
mkdir -p "$SYSTEMD_BUILD_DIR" "$SYSTEMD_STAGING_DIR"

meson setup "$SYSTEMD_BUILD_DIR" "$SYSTEMD_SRC_DIR" \
    --prefix=/usr \
    --libdir=lib \
    --sysconfdir=/etc \
    --localstatedir=/var \
    -Dmode=release \
    -Dsplit-bin=true \
    -Dinitrd=true \
    -Dcompat-sysv-interfaces=false \
    -Dquotaon-path=/bin/false \
    -Dquotacheck-path=/bin/false \
    -Dkmod-path=/sbin/modprobe \
    -Dkexec-path=/bin/false \
    -Dsulogin-path=/sbin/sulogin \
    -Dswapon-path=/sbin/swapon \
    -Dswapoff-path=/sbin/swapoff \
    -Dagetty-path=/sbin/getty \
    -Dmount-path=/bin/mount \
    -Dumount-path=/bin/umount \
    -Dloadkeys-path=/sbin/loadkmap \
    -Dsetfont-path=/usr/sbin/setfont \
    -Dnologin-path=/usr/sbin/nologin \
    -Dsystemd-network-uid=192 \
    -Dsystemd-resolve-uid=193 \
    -Dadm-group=false \
    -Dwheel-group=false \
    -Dtests=false \
    -Dslow-tests=false \
    -Dfuzz-tests=false \
    -Dinstall-tests=false \
    -Dman=disabled \
    -Dhtml=disabled \
    -Dtranslations=false \
    -Dfirstboot=false \
    -Dbinfmt=false \
    -Dhibernate=false \
    -Dldconfig=false \
    -Dresolve=true \
    -Defi=false \
    -Dtpm=false \
    -Drepart=disabled \
    -Dsysupdate=disabled \
    -Dsysupdated=disabled \
    -Dcoredump=false \
    -Dpstore=false \
    -Doomd=false \
    -Dlogind=true \
    -Dhostnamed=false \
    -Dlocaled=false \
    -Dmachined=false \
    -Dportabled=false \
    -Dsysext=false \
    -Dmountfsd=false \
    -Duserdb=false \
    -Dhomed=disabled \
    -Dnetworkd=true \
    -Ddefault-network=false \
    -Dtimedated=false \
    -Dtimesyncd=false \
    -Dremote=disabled \
    -Dnsresourced=false \
    -Dnss-myhostname=false \
    -Dnss-mymachines=disabled \
    -Dnss-resolve=disabled \
    -Dnss-systemd=false \
    -Dsysusers=false \
    -Dbacklight=false \
    -Dvconsole=false \
    -Dquotacheck=false \
    -Dhwdb=false \
    -Drfkill=false \
    -Dxdg-autostart=false \
    -Dnspawn=disabled \
    -Dvmspawn=disabled \
    -Dimportd=disabled \
    -Dseccomp=disabled \
    -Dselinux=disabled \
    -Dapparmor=disabled \
    -Dsmack=false \
    -Dpolkit=disabled \
    -Dima=false \
    -Dipe=false \
    -Dacl=disabled \
    -Daudit=disabled \
    -Dfdisk=disabled \
    -Dkmod=disabled \
    -Dpam=disabled \
    -Dpasswdqc=disabled \
    -Dpwquality=disabled \
    -Dmicrohttpd=disabled \
    -Dlibcrypt=disabled \
    -Dlibcryptsetup=disabled \
    -Dlibcryptsetup-plugins=disabled \
    -Dlibcurl=disabled \
    -Didn=false \
    -Dlibidn2=disabled \
    -Dqrencode=disabled \
    -Dgcrypt=disabled \
    -Dgnutls=disabled \
    -Dopenssl=disabled \
    -Dp11kit=disabled \
    -Dlibfido2=disabled \
    -Dtpm2=disabled \
    -Delfutils=disabled \
    -Dbzip2=disabled \
    -Dxz=disabled \
    -Dlz4=disabled \
    -Dzstd=disabled \
    -Dxkbcommon=disabled \
    -Dpcre2=disabled \
    -Dglib=disabled \
    -Ddbus=disabled \
    -Dlibarchive=disabled \
    -Dbootloader=disabled \
    -Dkernel-install=false \
    -Dukify=disabled \
    -Danalyze=false \
    -Dbashcompletiondir=no \
    -Dzshcompletiondir=no \
    -Ddefault-user-shell=/bin/sh

msg "building systemd ${SYSTEMD_VERSION}"
meson compile -C "$SYSTEMD_BUILD_DIR" -j "$JOBS"

msg "installing systemd ${SYSTEMD_VERSION}"
DESTDIR="$SYSTEMD_STAGING_DIR" meson install -C "$SYSTEMD_BUILD_DIR" --no-rebuild

msg "copying systemd runtime library dependencies"
while IFS= read -r -d '' elf; do
    file_type=$(file -b "$elf" 2>/dev/null || true)
    case "$file_type" in
        *ELF*) copy_elf_deps "$elf" ;;
    esac
done < <(find "$SYSTEMD_STAGING_DIR" -type f \( -perm /111 -o -name '*.so' -o -name '*.so.*' \) -print0)

copy_named_library libmount.so.1

[[ -x "$SYSTEMD_STAGING_DIR/usr/lib/systemd/systemd" ]] || die "systemd binary was not installed"
[[ -x "$SYSTEMD_STAGING_DIR/usr/lib/systemd/systemd-logind" ]] || die "systemd-logind binary was not installed"
[[ -x "$SYSTEMD_STAGING_DIR/usr/bin/loginctl" ]] || die "loginctl binary was not installed"
[[ -f "$SYSTEMD_STAGING_DIR/usr/share/dbus-1/system.d/org.freedesktop.login1.conf" ]] || die "logind D-Bus policy was not installed"
touch "$SYSTEMD_STAGING_DIR/.forgeos-systemd-complete"
msg "systemd staging tree: $SYSTEMD_STAGING_DIR"
