#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Drags between apps, which need the pasteboard server: build the VM image with
# mkramdisk.sh first. The test drags from one process's window to another's on a
# headless window server and compares what both saw with the expected output (the
# image has no diff: the output is shown when it differs).
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
exec tools/vm/with-vm-lock.sh expect tools/vm/smoke.exp \
    'FINCH_THEME=Classic finch-appkit-drag-apps-test /usr/libexec/finch-windowserver > /tmp/drag-apps.out && { test "$(cat /tmp/drag-apps.out)" = "$(cat /usr/local/share/finch/tests/appkit-drag-apps-test.expected)" || { cat /tmp/drag-apps.out; false; }; }'
