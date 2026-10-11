#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Build the current VM image with mkramdisk.sh first. These checks create only
# private guest fixtures and do not change the guest's real account files.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
exec tools/vm/with-vm-lock.sh expect tools/vm/smoke.exp \
    'FINCH_RELEASE_ETC=/usr/local/share/finch/account-fixture finch-account-tools-test' \
    'finch-account-login-test' \
    'accountctl -h'
