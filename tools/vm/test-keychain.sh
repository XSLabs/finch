#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Build the current VM image first. The test uses a private temporary folder
# and dummy secrets; it never opens the guest's default keychain.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
exec tools/vm/with-vm-lock.sh expect tools/vm/smoke.exp \
    'finch-keychain-crypto-test' \
    'finch-security-keychain-storage-test'
