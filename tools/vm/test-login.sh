#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# The real console login in the VM, and the login keychain PAM makes and unlocks with its
# password (tools/vm/account-console-smoke.exp). Build the image first:
#
#   tools/vm/mkramdisk.sh && tools/vm/test-login.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
exec tools/vm/with-vm-lock.sh expect tools/vm/account-console-smoke.exp
