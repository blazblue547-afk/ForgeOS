#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/common.sh"

KEY_DIR=$SECURE_BOOT_KEY_DIR
FORCE=0

usage() {
    cat <<'EOF'
Usage:
  generate-secure-boot-keys.sh [options]

Options:
  --dir PATH                 Output directory. Defaults to out/secure-boot.
  --common-name NAME         Certificate common name.
  --force                    Replace existing generated files.
  --help                     Show this help text.

Generated files:
  ForgeOS.key                Private signing key. Keep this secret.
  ForgeOS.crt                PEM X.509 certificate for sbsign.
  ForgeOS.cer                DER X.509 certificate for firmware/MOK import.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir)
            [[ $# -ge 2 ]] || die "--dir requires a value"
            KEY_DIR=$2
            shift 2
            ;;
        --common-name)
            [[ $# -ge 2 ]] || die "--common-name requires a value"
            SECURE_BOOT_COMMON_NAME=$2
            shift 2
            ;;
        --force)
            FORCE=1
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

require_cmd openssl
mkdir -p "$KEY_DIR"

KEY_PATH="$KEY_DIR/ForgeOS.key"
CERT_PEM="$KEY_DIR/ForgeOS.crt"
CERT_DER="$KEY_DIR/ForgeOS.cer"

if [[ "$FORCE" -ne 1 ]]; then
    for path in "$KEY_PATH" "$CERT_PEM" "$CERT_DER"; do
        [[ ! -e "$path" ]] || die "refusing to overwrite existing file: $path"
    done
fi

umask 077
msg "generating Secure Boot signing key"
openssl req \
    -new \
    -x509 \
    -newkey rsa:4096 \
    -sha256 \
    -nodes \
    -days 3650 \
    -subj "/CN=${SECURE_BOOT_COMMON_NAME}/" \
    -keyout "$KEY_PATH" \
    -out "$CERT_PEM" >/dev/null 2>&1

openssl x509 -in "$CERT_PEM" -outform DER -out "$CERT_DER"

chmod 0600 "$KEY_PATH"
chmod 0644 "$CERT_PEM" "$CERT_DER"

msg "Secure Boot key: $KEY_PATH"
msg "Secure Boot certificate: $CERT_PEM"
msg "enrollment certificate: $CERT_DER"
