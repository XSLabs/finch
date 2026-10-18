#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Build the current VM image first. Tests use a disposable login account,
# private temporary folders, and dummy secrets in a separate image copy.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd -P)"
cd "$root"
exec tools/vm/with-vm-lock.sh bash -c '
    set -e
    root=$1
    tools/vm/prepare-login-test-image.sh
    emit_image_marker() {
        name=$1
        image=$2
        [[ -f "$image" ]] || { printf "error: missing %s image: %s\n" "$name" "$image" >&2; exit 1; }
        digest=$(shasum -a 256 "$image")
        digest=${digest%% *}
        [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || { printf "error: could not hash %s image: %s\n" "$name" "$image" >&2; exit 1; }
        printf "VMTIMAGE|%s|%s|%s\n" "$name" "$image" "$digest"
    }
    emit_image_marker RAMDISK "$root/build/vm-login-test/ramdisk.dmg"
    emit_image_marker TC "$root/build/vm-login-test/ramdisk.tc"
    expect tools/vm/login-init-smoke.exp \
        "finch-keychain-crypto-test" \
        "finch-security-keychain-storage-test" \
        "finch-security-keychain-encryption-test" \
        "finch-security-keychain-service-test"
' keychain "$root"
