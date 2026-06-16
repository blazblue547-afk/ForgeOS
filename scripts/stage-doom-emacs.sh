#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/common.sh"

require_cmd chmod cp git mkdir rm rsync
ensure_dirs

[[ -d "$ROOTFS_STAGING_DIR" ]] || die "missing rootfs staging tree: $ROOTFS_STAGING_DIR"

doom_package_array() {
    local package

    for package in $DOOM_EMACS_PACKAGES; do
        printf '%s\n' "$package"
    done
}

is_skipped_package() {
    local package=$1

    case " $DOOM_EMACS_SKIP_PACKAGES " in
        *" $package "*) return 0 ;;
        *) return 1 ;;
    esac
}

has_doom_runtime() {
    local emacs_ok=1

    if [[ -x "$ROOTFS_STAGING_DIR/usr/bin/emacs" || -x "$ROOTFS_STAGING_DIR/usr/bin/emacs-nox" || -x "$ROOTFS_STAGING_DIR/usr/bin/emacs-gtk" ]]; then
        emacs_ok=0
    fi

    [[ "$emacs_ok" -eq 0 ]] &&
        [[ -x "$ROOTFS_STAGING_DIR/usr/bin/git" ]] &&
        [[ -x "$ROOTFS_STAGING_DIR/usr/bin/rg" ]] &&
        [[ -x "$ROOTFS_STAGING_DIR/usr/bin/find" ]]
}

download_doom_packages() {
    local -a packages=()
    local package
    local status_file="$DOOM_EMACS_APT_STATE_DIR/status"
    local extended_states_file="$DOOM_EMACS_APT_STATE_DIR/extended_states"

    require_cmd apt-get

    while IFS= read -r package; do
        [[ -n "$package" ]] && packages+=("$package")
    done < <(doom_package_array)

    [[ "${#packages[@]}" -gt 0 ]] || die "DOOM_EMACS_PACKAGES is empty"

    mkdir -p \
        "$DOOM_EMACS_DEB_DIR/partial" \
        "$DOOM_EMACS_APT_STATE_DIR"
    : > "$status_file"
    : > "$extended_states_file"

    msg "downloading Doom Emacs runtime package closure"
    apt-get \
        -o "Dir::State::status=$status_file" \
        -o "Dir::State::extended_states=$extended_states_file" \
        -o "Dir::Cache::archives=$DOOM_EMACS_DEB_DIR" \
        -o Debug::NoLocking=1 \
        --yes \
        --download-only \
        --no-install-recommends \
        install "${packages[@]}"
}

extract_doom_packages() {
    local deb
    local package
    local extracted_count=0
    local skipped_count=0

    require_cmd dpkg-deb

    shopt -s nullglob
    for deb in "$DOOM_EMACS_DEB_DIR"/*.deb; do
        package=$(dpkg-deb -f "$deb" Package)
        if is_skipped_package "$package"; then
            skipped_count=$((skipped_count + 1))
            continue
        fi

        dpkg-deb -x "$deb" "$ROOTFS_STAGING_DIR"
        extracted_count=$((extracted_count + 1))
    done
    shopt -u nullglob

    [[ "$extracted_count" -gt 0 ]] || die "no Doom Emacs runtime packages were extracted from $DOOM_EMACS_DEB_DIR"
    msg "extracted $extracted_count Doom Emacs packages; skipped $skipped_count base packages"
}

sync_doom_source() {
    mkdir -p "$(dirname "$DOOM_EMACS_SRC_DIR")"

    if [[ -d "$DOOM_EMACS_SRC_DIR/.git" ]]; then
        msg "updating Doom Emacs source"
        git -C "$DOOM_EMACS_SRC_DIR" fetch --depth 1 origin "$DOOM_EMACS_REF"
        git -C "$DOOM_EMACS_SRC_DIR" checkout -q FETCH_HEAD
    else
        msg "cloning Doom Emacs source"
        rm -rf "$DOOM_EMACS_SRC_DIR"
        git clone --depth 1 --branch "$DOOM_EMACS_REF" "$DOOM_EMACS_GIT_URL" "$DOOM_EMACS_SRC_DIR"
    fi
}

stage_doom_source() {
    local doom_share="$ROOTFS_STAGING_DIR/usr/share/doom-emacs"

    mkdir -p "$doom_share"
    rsync -a --delete "$DOOM_EMACS_SRC_DIR"/ "$doom_share"/
}

write_doom_integration() {
    mkdir -p \
        "$ROOTFS_STAGING_DIR/etc/profile.d" \
        "$ROOTFS_STAGING_DIR/etc/skel/.config/doom" \
        "$ROOTFS_STAGING_DIR/usr/local/bin" \
        "$ROOTFS_STAGING_DIR/usr/local/libexec"

    cat > "$ROOTFS_STAGING_DIR/etc/profile.d/doom-emacs.sh" <<'EOF'
doom_emacs_config_home=${XDG_CONFIG_HOME:-"$HOME/.config"}
doom_emacs_bin="$doom_emacs_config_home/emacs/bin"

case ":$PATH:" in
    *":$doom_emacs_bin:"*) ;;
    *) PATH="$doom_emacs_bin:$PATH" ;;
esac
export PATH

if [ -n "${HOME:-}" ] && [ -w "$HOME" ] && [ -x /usr/local/libexec/forgeos-doom-seed ]; then
    /usr/local/libexec/forgeos-doom-seed >/dev/null 2>&1 || true
fi

unset doom_emacs_config_home doom_emacs_bin
EOF

    cat > "$ROOTFS_STAGING_DIR/usr/local/libexec/forgeos-doom-seed" <<'EOF'
#!/bin/sh
set -eu

[ -n "${HOME:-}" ] || exit 0
[ -d /usr/share/doom-emacs ] || exit 0

config_home=${XDG_CONFIG_HOME:-"$HOME/.config"}
emacs_dir=${EMACS_DIR:-"$config_home/emacs"}
doom_dir=${DOOMDIR:-"$config_home/doom"}
tmp_dir="$emacs_dir.tmp"

mkdir -p "$config_home"

if [ ! -e "$emacs_dir" ]; then
    rm -rf "$tmp_dir"
    cp -a /usr/share/doom-emacs "$tmp_dir"
    mv "$tmp_dir" "$emacs_dir"
fi

if [ ! -d "$doom_dir" ]; then
    mkdir -p "$doom_dir"
    for name in init config packages; do
        template="$emacs_dir/templates/$name.example.el"
        if [ -f "$template" ]; then
            cp "$template" "$doom_dir/$name.el"
        fi
    done

    if [ ! -f "$doom_dir/init.el" ]; then
        printf ';;; init.el -*- lexical-binding: t; -*-\n(doom!)\n' > "$doom_dir/init.el"
    fi
    if [ ! -f "$doom_dir/config.el" ]; then
        printf ';;; config.el -*- lexical-binding: t; -*-\n(setq user-full-name "ForgeOS User")\n' > "$doom_dir/config.el"
    fi
    if [ ! -f "$doom_dir/packages.el" ]; then
        printf ';;; packages.el -*- lexical-binding: t; -*-\n' > "$doom_dir/packages.el"
    fi
fi
EOF

    cat > "$ROOTFS_STAGING_DIR/usr/local/bin/doom" <<'EOF'
#!/bin/sh
set -eu

if [ -x /usr/local/libexec/forgeos-doom-seed ]; then
    /usr/local/libexec/forgeos-doom-seed >/dev/null 2>&1 || true
fi

config_home=${XDG_CONFIG_HOME:-"$HOME/.config"}
doom_bin="$config_home/emacs/bin/doom"

if [ ! -x "$doom_bin" ]; then
    printf 'doom: Doom Emacs is not staged for this user\n' >&2
    exit 127
fi

exec "$doom_bin" "$@"
EOF

    cat > "$ROOTFS_STAGING_DIR/usr/local/bin/emacs" <<'EOF'
#!/bin/sh
set -eu

if [ -x /usr/bin/emacs ]; then
    exec /usr/bin/emacs "$@"
fi
if [ -x /usr/bin/emacs-nox ]; then
    exec /usr/bin/emacs-nox "$@"
fi
if [ -x /usr/bin/emacs-gtk ]; then
    exec /usr/bin/emacs-gtk "$@"
fi

printf 'emacs: no Emacs binary found in /usr/bin\n' >&2
exit 127
EOF

    cat > "$ROOTFS_STAGING_DIR/usr/local/bin/fd" <<'EOF'
#!/bin/sh
set -eu

if [ -x /usr/bin/fdfind ]; then
    exec /usr/bin/fdfind "$@"
fi
if [ -x /usr/bin/fd ]; then
    exec /usr/bin/fd "$@"
fi

printf 'fd: no fd-compatible binary found\n' >&2
exit 127
EOF

    cat > "$ROOTFS_STAGING_DIR/usr/local/bin/find" <<'EOF'
#!/bin/sh
set -eu

if [ -x /usr/bin/find ]; then
    exec /usr/bin/find "$@"
fi
if [ -x /bin/find ]; then
    exec /bin/find "$@"
fi

printf 'find: no find binary found\n' >&2
exit 127
EOF

    cat > "$ROOTFS_STAGING_DIR/etc/forgeos-doom-emacs" <<EOF
NAME=Doom Emacs
GIT_URL=$DOOM_EMACS_GIT_URL
REF=$DOOM_EMACS_REF
CONFIG_HOME=.config/emacs
DOOMDIR=.config/doom
EOF

    chmod 0755 \
        "$ROOTFS_STAGING_DIR/usr/local/libexec/forgeos-doom-seed" \
        "$ROOTFS_STAGING_DIR/usr/local/bin/doom" \
        "$ROOTFS_STAGING_DIR/usr/local/bin/emacs" \
        "$ROOTFS_STAGING_DIR/usr/local/bin/fd" \
        "$ROOTFS_STAGING_DIR/usr/local/bin/find"
}

if has_doom_runtime; then
    msg "using existing Emacs/Git/ripgrep runtime in rootfs"
else
    download_doom_packages
    extract_doom_packages
fi

sync_doom_source
stage_doom_source
write_doom_integration

msg "Doom Emacs layer staged into $ROOTFS_STAGING_DIR"
