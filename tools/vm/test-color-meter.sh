#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Digital Color Meter in the VM: with the pointer over the desktop and then over the menu
# bar, Copy Color as Text (⇧⌘C) puts the colour under the pointer on the pasteboard, and it
# is the colour the window server has there (finch-app-test's sample of the same point).
# It reads the screen through Finch's window capture. Apple's Digital Color Meter comes
# from this Mac's install, never the repository:
#
#   FINCH_HOST_APPS="Digital Color Meter," tools/vm/mkramdisk.sh && tools/vm/test-color-meter.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
app="finch-app-test /usr/libexec/finch-windowserver '/Applications/Digital Color Meter.app/Contents/MacOS/Digital Color Meter' 'window:Digital Color Meter' wait:8000"
# (points relative to its window, which opens at 325,350: the desktop above it, the menu bar)
check() {
    echo "printf none | pbcopy; $app move:$1 wait:2000 sample:$1,here shiftcmd:C wait:2000 cmd:q wait:2000 > /tmp/dcm.txt; test \"\$(grep '^here:' /tmp/dcm.txt | sed 's/^here: //')\" = \"\$(pbpaste | tr '\\t' ' ')\""
}
exec tools/vm/with-vm-lock.sh expect tools/vm/smoke.exp \
    'test -x "/Applications/Digital Color Meter.app/Contents/MacOS/Digital Color Meter" || { echo "Digital Color Meter is not in the image"; false; }' \
    "$(check 300,-40)" \
    "$(check 300,-340)"
