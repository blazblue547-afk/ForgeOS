#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/common.sh"

require_cmd apt-get cat chmod dpkg-deb mkdir rm
ensure_dirs

[[ "$DESKTOP" == "console" ]] || die "Openbox desktop layer is only supported on the normal ForgeOS rootfs"
[[ -d "$ROOTFS_STAGING_DIR" ]] || die "missing rootfs staging tree: $ROOTFS_STAGING_DIR"

desktop_package_array() {
    local package

    for package in $OPENBOX_DESKTOP_PACKAGES; do
        printf '%s\n' "$package"
    done
}

is_skipped_package() {
    local package=$1

    case " $OPENBOX_DESKTOP_SKIP_PACKAGES " in
        *" $package "*) return 0 ;;
        *) return 1 ;;
    esac
}

download_desktop_packages() {
    local -a packages=()
    local package
    local status_file="$OPENBOX_DESKTOP_APT_STATE_DIR/status"
    local extended_states_file="$OPENBOX_DESKTOP_APT_STATE_DIR/extended_states"

    while IFS= read -r package; do
        [[ -n "$package" ]] && packages+=("$package")
    done < <(desktop_package_array)

    [[ "${#packages[@]}" -gt 0 ]] || die "OPENBOX_DESKTOP_PACKAGES is empty"

    mkdir -p \
        "$OPENBOX_DESKTOP_DEB_DIR/partial" \
        "$OPENBOX_DESKTOP_APT_STATE_DIR"
    : > "$status_file"
    : > "$extended_states_file"

    msg "downloading Openbox desktop package closure"
    apt-get \
        -o "Dir::State::status=$status_file" \
        -o "Dir::State::extended_states=$extended_states_file" \
        -o "Dir::Cache::archives=$OPENBOX_DESKTOP_DEB_DIR" \
        -o Debug::NoLocking=1 \
        --yes \
        --download-only \
        --no-install-recommends \
        install "${packages[@]}"
}

extract_desktop_packages() {
    local deb
    local package
    local extracted_count=0
    local skipped_count=0

    shopt -s nullglob
    for deb in "$OPENBOX_DESKTOP_DEB_DIR"/*.deb; do
        package=$(dpkg-deb -f "$deb" Package)
        if is_skipped_package "$package"; then
            skipped_count=$((skipped_count + 1))
            continue
        fi

        dpkg-deb -x "$deb" "$ROOTFS_STAGING_DIR"
        extracted_count=$((extracted_count + 1))
    done
    shopt -u nullglob

    [[ "$extracted_count" -gt 0 ]] || die "no desktop packages were extracted from $OPENBOX_DESKTOP_DEB_DIR"
    msg "extracted $extracted_count desktop packages; skipped $skipped_count base packages"
}

write_desktop_config() {
    mkdir -p \
        "$ROOTFS_STAGING_DIR/etc/X11/xorg.conf.d" \
        "$ROOTFS_STAGING_DIR/etc/systemd/system/multi-user.target.wants" \
        "$ROOTFS_STAGING_DIR/root/.config/openbox" \
        "$ROOTFS_STAGING_DIR/root/.config/pcmanfm/default" \
        "$ROOTFS_STAGING_DIR/root/.config/tint2" \
        "$ROOTFS_STAGING_DIR/usr/local/bin" \
        "$ROOTFS_STAGING_DIR/var/lib/dbus"

    cat > "$ROOTFS_STAGING_DIR/etc/X11/Xwrapper.config" <<'EOF'
allowed_users=anybody
needs_root_rights=yes
EOF

    cat > "$ROOTFS_STAGING_DIR/etc/X11/xorg.conf.d/10-forgeos-input.conf" <<'EOF'
Section "InputClass"
    Identifier "ForgeOS libinput pointers"
    MatchIsPointer "on"
    Driver "libinput"
EndSection

Section "InputClass"
    Identifier "ForgeOS libinput keyboards"
    MatchIsKeyboard "on"
    Driver "libinput"
EndSection
EOF

    cat > "$ROOTFS_STAGING_DIR/root/.config/openbox/autostart" <<'EOF'
pcmanfm --desktop --profile default &
tint2 &
lxterminal &
EOF

    cat > "$ROOTFS_STAGING_DIR/root/.config/pcmanfm/default/desktop-items-0.conf" <<'EOF'
[*]
wallpaper_mode=color
desktop_bg=#1f2933
desktop_fg=#f3f4f6
desktop_shadow=#000000
show_wm_menu=1
sort=mtime;ascending;
show_documents=0
show_trash=0
show_mounts=0
EOF

    cat > "$ROOTFS_STAGING_DIR/root/.config/tint2/tint2rc" <<'EOF'
rounded = 0
border_width = 0
background_color = #111827 95
panel_monitor = all
panel_position = bottom center horizontal
panel_size = 100% 32
panel_margin = 0 0
panel_padding = 4 2 4
panel_items = TSC
task_text = 1
task_icon = 1
task_centered = 1
task_padding = 4 2
task_background_id = 0
clock = 1
time1_format = %H:%M
time1_font = DejaVu Sans 10
clock_font_color = #f9fafb 100
systray = 1
systray_padding = 4 0 4
EOF

    cat > "$ROOTFS_STAGING_DIR/usr/local/bin/forgeos-openbox-session" <<'EOF'
#!/bin/sh
set -eu

export HOME=/root
export USER=root
export LOGNAME=root
export XDG_RUNTIME_DIR=/run/user/0
export XDG_CONFIG_HOME=/root/.config
export XDG_CACHE_HOME=/root/.cache

mkdir -p "$XDG_RUNTIME_DIR" "$XDG_CACHE_HOME"
chmod 0700 "$XDG_RUNTIME_DIR"

if command -v dbus-uuidgen >/dev/null 2>&1 && [ ! -s /var/lib/dbus/machine-id ]; then
    dbus-uuidgen --ensure=/var/lib/dbus/machine-id || true
fi

if command -v openbox-session >/dev/null 2>&1; then
    exec openbox-session
fi

pcmanfm --desktop --profile default &
tint2 &
lxterminal &
exec openbox
EOF
    chmod 0755 "$ROOTFS_STAGING_DIR/usr/local/bin/forgeos-openbox-session"

    cat > "$ROOTFS_STAGING_DIR/etc/systemd/system/forgeos-desktop.service" <<'EOF'
[Unit]
Description=ForgeOS Openbox desktop
Wants=dbus.service systemd-udevd.service
After=dbus.service systemd-udevd.service systemd-user-sessions.service
Conflicts=forgeos-shell@tty1.service getty@tty1.service

[Service]
Type=simple
Environment=HOME=/root
Environment=USER=root
Environment=LOGNAME=root
Environment=XDG_RUNTIME_DIR=/run/user/0
ExecStartPre=/bin/mkdir -p /run/user/0
ExecStartPre=/bin/chmod 0700 /run/user/0
ExecStart=/usr/bin/xinit /usr/local/bin/forgeos-openbox-session -- /usr/lib/xorg/Xorg :0 vt1 -keeptty -nolisten tcp
Restart=on-failure
RestartSec=2
StandardInput=tty
StandardOutput=journal
StandardError=journal
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes

[Install]
WantedBy=multi-user.target
EOF

    ln -sfn /etc/systemd/system/forgeos-desktop.service \
        "$ROOTFS_STAGING_DIR/etc/systemd/system/multi-user.target.wants/forgeos-desktop.service"
    rm -f "$ROOTFS_STAGING_DIR/etc/systemd/system/getty.target.wants/forgeos-shell@tty1.service"

    if [[ -e "$ROOTFS_STAGING_DIR/usr/lib/systemd/system/dbus.socket" ]]; then
        mkdir -p "$ROOTFS_STAGING_DIR/etc/systemd/system/sockets.target.wants"
        ln -sfn /usr/lib/systemd/system/dbus.socket \
            "$ROOTFS_STAGING_DIR/etc/systemd/system/sockets.target.wants/dbus.socket"
    fi

    if [[ -e "$ROOTFS_STAGING_DIR/usr/lib/systemd/system/dbus.service" ]]; then
        ln -sfn /usr/lib/systemd/system/dbus.service \
            "$ROOTFS_STAGING_DIR/etc/systemd/system/multi-user.target.wants/dbus.service"
    fi

    cat > "$ROOTFS_STAGING_DIR/etc/forgeos-desktop" <<'EOF'
NAME=Openbox
COMPONENTS=openbox,tint2,pcmanfm,xorg,lxterminal
EOF
}

download_desktop_packages
extract_desktop_packages
write_desktop_config

msg "Openbox desktop layer staged into $ROOTFS_STAGING_DIR"
