#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Build the current VM image first. Tests use a disposable login account,
# private temporary folders, and dummy secrets in a separate image copy.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
exec tools/vm/with-vm-lock.sh bash -c '
    set -e
    tools/vm/prepare-login-test-image.sh
    expect tools/vm/login-init-smoke.exp \
        "finch-keychain-crypto-test" \
        "finch-security-keychain-storage-test" \
        "finch-security-keychain-encryption-test" \
        "finch-security-keychain-service-test"
'
