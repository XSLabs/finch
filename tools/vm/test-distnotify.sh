#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Distributed notifications between processes in the VM, through finch-distnoted: a child
# process observes a name and object, the parent posts it with user info, and the child
# gets it (finch-distnotify-test --cross), in the system domain (the service's root
# instance) and within a process as on macOS (the same test's default run).
#
#   tools/vm/mkramdisk.sh && tools/vm/test-distnotify.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
exec tools/vm/with-vm-lock.sh expect tools/vm/smoke.exp \
    "finch-distnotify-test --cross" \
    "finch-distnotify-test | grep -q 'after removal: matching 1, any 3, block 2'" \
    "launchctl list | grep -q org.finch.distnoted"
