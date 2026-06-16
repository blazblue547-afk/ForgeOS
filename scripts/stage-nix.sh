#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/common.sh"

require_cmd chmod find head install ln mkdir rsync sort tar
ensure_dirs

[[ "$ARCH" == "x86_64" ]] || die "Nix rootfs staging currently supports ARCH=x86_64 only"
[[ "$NIX_SYSTEM" == "x86_64-linux" ]] || die "Nix rootfs staging currently supports NIX_SYSTEM=x86_64-linux only"
[[ -d "$ROOTFS_STAGING_DIR" ]] || die "missing rootfs staging tree: $ROOTFS_STAGING_DIR"

if [[ ! -d "$NIX_SRC_DIR/store" || ! -f "$NIX_SRC_DIR/.reginfo" ]]; then
    "$ROOT_DIR/scripts/fetch-sources.sh"
fi

[[ -d "$NIX_SRC_DIR/store" ]] || die "missing Nix store payload: $NIX_SRC_DIR/store"
[[ -f "$NIX_SRC_DIR/.reginfo" ]] || die "missing Nix registration info: $NIX_SRC_DIR/.reginfo"

nix_store_name=$(find "$NIX_SRC_DIR/store" -mindepth 1 -maxdepth 1 -type d -name "*-nix-${NIX_VERSION}" -printf '%f\n' | LC_ALL=C sort | head -n 1)
nix_manual_name=$(find "$NIX_SRC_DIR/store" -mindepth 1 -maxdepth 1 -type d -name "*-nix-manual-${NIX_VERSION}-man" -printf '%f\n' | LC_ALL=C sort | head -n 1)
nix_cacert_name=$(find "$NIX_SRC_DIR/store" -mindepth 1 -maxdepth 1 -type d -name "*-nss-cacert-*" -printf '%f\n' | LC_ALL=C sort | head -n 1)

[[ -n "$nix_store_name" ]] || die "could not locate nix-${NIX_VERSION} store path in $NIX_SRC_DIR/store"
[[ -n "$nix_manual_name" ]] || die "could not locate nix manual store path in $NIX_SRC_DIR/store"
[[ -n "$nix_cacert_name" ]] || die "could not locate nss-cacert store path in $NIX_SRC_DIR/store"

nix_store_path="/nix/store/$nix_store_name"
nix_manual_path="/nix/store/$nix_manual_name"
nix_cacert_path="/nix/store/$nix_cacert_name"

msg "staging Nix $NIX_VERSION as the core package manager"

mkdir -p \
    "$ROOTFS_STAGING_DIR/nix/store" \
    "$ROOTFS_STAGING_DIR/nix/var/log/nix/drvs" \
    "$ROOTFS_STAGING_DIR/nix/var/nix/bootstrap" \
    "$ROOTFS_STAGING_DIR/nix/var/nix/db" \
    "$ROOTFS_STAGING_DIR/nix/var/nix/gcroots/per-user" \
    "$ROOTFS_STAGING_DIR/nix/var/nix/profiles/per-user" \
    "$ROOTFS_STAGING_DIR/nix/var/nix/temproots" \
    "$ROOTFS_STAGING_DIR/nix/var/nix/userpool" \
    "$ROOTFS_STAGING_DIR/nix/var/nix/daemon-socket" \
    "$ROOTFS_STAGING_DIR/etc/nix" \
    "$ROOTFS_STAGING_DIR/etc/profile.d" \
    "$ROOTFS_STAGING_DIR/etc/systemd/system" \
    "$ROOTFS_STAGING_DIR/usr/bin" \
    "$ROOTFS_STAGING_DIR/usr/lib/forgeos" \
    "$ROOTFS_STAGING_DIR/usr/lib/tmpfiles.d"

rsync -a "$NIX_SRC_DIR/store/" "$ROOTFS_STAGING_DIR/nix/store/"
install -m 0644 "$NIX_SRC_DIR/.reginfo" "$ROOTFS_STAGING_DIR/nix/var/nix/bootstrap/reginfo"

chmod 1775 "$ROOTFS_STAGING_DIR/nix/store"
chmod -R ugo-w "$ROOTFS_STAGING_DIR/nix/store"/* 2>/dev/null || true
chmod 0755 \
    "$ROOTFS_STAGING_DIR/nix" \
    "$ROOTFS_STAGING_DIR/nix/var" \
    "$ROOTFS_STAGING_DIR/nix/var/nix" \
    "$ROOTFS_STAGING_DIR/nix/var/nix/bootstrap" \
    "$ROOTFS_STAGING_DIR/nix/var/nix/daemon-socket"

for tool in nix nix-build nix-channel nix-collect-garbage nix-copy-closure nix-daemon nix-env nix-instantiate nix-shell nix-store; do
    if [[ -x "$ROOTFS_STAGING_DIR$nix_store_path/bin/$tool" ]]; then
        ln -sfn "$nix_store_path/bin/$tool" "$ROOTFS_STAGING_DIR/usr/bin/$tool"
    fi
done

if [[ -e "$ROOTFS_STAGING_DIR/usr/sbin/nologin" ]]; then
    ln -sfn ../usr/sbin/nologin "$ROOTFS_STAGING_DIR/sbin/nologin"
fi

cat > "$ROOTFS_STAGING_DIR/etc/nix/nix.conf" <<'EOF'
build-users-group = nixbld
allowed-users = *
trusted-users = root
substituters = https://cache.nixos.org/
trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
experimental-features = nix-command flakes
ssl-cert-file = /nix/var/nix/profiles/default/etc/ssl/certs/ca-bundle.crt
max-jobs = auto
sandbox = false
EOF

cat > "$ROOTFS_STAGING_DIR/etc/profile.d/nix.sh" <<EOF
# ForgeOS provides Nix as the core package manager through nix-daemon.
export NIX_REMOTE=\${NIX_REMOTE:-daemon}

if [ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
    . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
elif [ -e "$nix_store_path/etc/profile.d/nix-daemon.sh" ]; then
    . "$nix_store_path/etc/profile.d/nix-daemon.sh"
fi
EOF

cat > "$ROOTFS_STAGING_DIR/usr/lib/forgeos/nix-bootstrap" <<EOF
#!/bin/sh
set -eu
PATH=/usr/bin:/usr/sbin:/bin:/sbin
export PATH

NIX_STORE_PATH="$nix_store_path"
NIX_MANUAL_PATH="$nix_manual_path"
NIX_CACERT_PATH="$nix_cacert_path"
NIX_STATE=/nix/var/nix
REGINFO="\$NIX_STATE/bootstrap/reginfo"
MARKER="\$NIX_STATE/forgeos-bootstrap-complete"

mkdir -p \\
    /nix/store \\
    /nix/var/log/nix/drvs \\
    "\$NIX_STATE/bootstrap" \\
    "\$NIX_STATE/db" \\
    "\$NIX_STATE/gcroots/per-user" \\
    "\$NIX_STATE/profiles/per-user" \\
    "\$NIX_STATE/temproots" \\
    "\$NIX_STATE/userpool" \\
    "\$NIX_STATE/daemon-socket" \\
    /root

chown root:root /nix /nix/var /nix/var/nix /nix/var/log /nix/var/log/nix /nix/var/log/nix/drvs 2>/dev/null || true
chown -R root:nixbld /nix/store 2>/dev/null || true
chmod 1775 /nix/store
chmod -R ugo-w /nix/store/* 2>/dev/null || true
chmod 0755 "\$NIX_STATE" "\$NIX_STATE/bootstrap" "\$NIX_STATE/daemon-socket"

if [ -e "\$MARKER" ]; then
    exit 0
fi

if [ ! -s "\$REGINFO" ]; then
    echo "missing Nix registration info at \$REGINFO" >&2
    exit 1
fi

export HOME=/root
export USER=root
export NIX_CONF_DIR=/etc/nix

"\$NIX_STORE_PATH/bin/nix-store" --load-db < "\$REGINFO"
"\$NIX_STORE_PATH/bin/nix-env" -p /nix/var/nix/profiles/default -i "\$NIX_STORE_PATH" "\$NIX_MANUAL_PATH" "\$NIX_CACERT_PATH"
printf '%s\n' 'https://channels.nixos.org/nixpkgs-unstable nixpkgs' > /root/.nix-channels

touch "\$MARKER"
EOF
chmod 0755 "$ROOTFS_STAGING_DIR/usr/lib/forgeos/nix-bootstrap"

cat > "$ROOTFS_STAGING_DIR/etc/systemd/system/forgeos-nix-bootstrap.service" <<'EOF'
[Unit]
Description=Bootstrap ForgeOS Nix store
DefaultDependencies=no
After=local-fs.target
Before=sockets.target multi-user.target
ConditionPathExists=/nix/var/nix/bootstrap/reginfo
ConditionPathExists=!/nix/var/nix/forgeos-bootstrap-complete

[Service]
Type=oneshot
ExecStart=/usr/lib/forgeos/nix-bootstrap
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
EOF

cat > "$ROOTFS_STAGING_DIR/etc/systemd/system/nix-daemon.service" <<EOF
[Unit]
Description=Nix package manager daemon
Documentation=man:nix-daemon https://nixos.org/manual
After=forgeos-nix-bootstrap.service
RequiresMountsFor=/nix/store
RequiresMountsFor=/nix/var
RequiresMountsFor=/nix/var/nix/db
ConditionPathIsReadWrite=/nix/var/nix/daemon-socket

[Service]
ExecStart=$nix_store_path/bin/nix-daemon --daemon
KillMode=process
LimitNOFILE=1048576
TasksMax=1048576
Delegate=yes

[Install]
WantedBy=multi-user.target
EOF

cat > "$ROOTFS_STAGING_DIR/etc/systemd/system/nix-daemon.socket" <<'EOF'
[Unit]
Description=Nix package manager daemon socket
Before=multi-user.target
RequiresMountsFor=/nix/store
ConditionPathIsReadWrite=/nix/var/nix/daemon-socket

[Socket]
ListenStream=/nix/var/nix/daemon-socket/socket

[Install]
WantedBy=sockets.target
EOF

cat > "$ROOTFS_STAGING_DIR/usr/lib/tmpfiles.d/nix-daemon.conf" <<'EOF'
d /nix/var/nix/daemon-socket 0755 root root - -
d /nix/var/nix/builds 0755 root root 7d -
EOF

printf 'Nix %s (%s)\n' "$NIX_VERSION" "$NIX_SYSTEM" > "$ROOTFS_STAGING_DIR/etc/forgeos-nix"

msg "Nix staged from $nix_store_path"
