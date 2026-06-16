#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/common.sh"

usage() {
    cat <<'EOF'
Usage:
  sign-efi-loader.sh [input-bzImage] [output-efi]

Environment:
  SECURE_BOOT=1              Sign the loader instead of copying it unsigned.
  SECURE_BOOT_KEY=PATH       Private key used by sbsign.
  SECURE_BOOT_CERT=PATH      X.509 certificate used by sbsign.

The certificate must be enrolled in the target firmware Secure Boot db, or
imported through a trusted shim/MOK flow, before firmware will trust the output.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi

INPUT=${1:-"$OUT_DIR/bzImage"}
OUTPUT=${2:-"$OUT_DIR/BOOTX64.EFI"}

[[ -f "$INPUT" ]] || die "missing EFI stub kernel: $INPUT"
mkdir -p "$(dirname "$OUTPUT")"

if ! truthy "$SECURE_BOOT"; then
    install -m 0644 "$INPUT" "$OUTPUT"
    msg "unsigned EFI loader ready: $OUTPUT"
    exit 0
fi

[[ -n "$SECURE_BOOT_KEY" ]] || die "SECURE_BOOT=1 requires SECURE_BOOT_KEY=/path/to/signing.key"
[[ -n "$SECURE_BOOT_CERT" ]] || die "SECURE_BOOT=1 requires SECURE_BOOT_CERT=/path/to/signing.crt"
[[ -f "$SECURE_BOOT_KEY" ]] || die "missing Secure Boot key: $SECURE_BOOT_KEY"
[[ -f "$SECURE_BOOT_CERT" ]] || die "missing Secure Boot certificate: $SECURE_BOOT_CERT"

require_cmd sbsign

TMP_OUTPUT=$(mktemp "$OUTPUT.tmp.XXXXXX")
cleanup() {
    rm -f "$TMP_OUTPUT"
}
trap cleanup EXIT

msg "signing EFI loader for Secure Boot"
sbsign \
    --key "$SECURE_BOOT_KEY" \
    --cert "$SECURE_BOOT_CERT" \
    --output "$TMP_OUTPUT" \
    "$INPUT" >/dev/null

install -m 0644 "$TMP_OUTPUT" "$OUTPUT"

if command -v sbverify >/dev/null 2>&1; then
    sbverify --cert "$SECURE_BOOT_CERT" "$OUTPUT" >/dev/null
fi

msg "signed EFI loader ready: $OUTPUT"
