#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Calculator in the VM, checked by what it copies: expressions typed on the keyboard, the
# result copied with Edit > Copy (⌘C) and read back with pbpaste. Apple's Calculator comes
# from this Mac's install, never the repository:
#
#   FINCH_HOST_APPS=Calculator tools/vm/mkramdisk.sh && tools/vm/test-calculator.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
app="finch-app-test /usr/libexec/finch-windowserver /Applications/Calculator.app/Contents/MacOS/Calculator window:Calculator wait:5000"
exec tools/vm/with-vm-lock.sh expect tools/vm/smoke.exp \
    'test -x /Applications/Calculator.app/Contents/MacOS/Calculator || { echo "Calculator is not in the image (FINCH_HOST_APPS=Calculator tools/vm/mkramdisk.sh)"; false; }' \
    "$app type:7+2= wait:4000 cmd:c wait:3000" \
    'test "$(pbpaste)" = 9' \
    "$app type:9/2= wait:4000 cmd:c wait:3000" \
    'test "$(pbpaste)" = 4.5' \
    "$app cmd:2 wait:20000 type:3^2= wait:4000 cmd:c wait:3000 cmd:1 wait:5000" \
    'test "$(pbpaste)" = 9'
