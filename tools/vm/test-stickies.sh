#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Stickies in the VM (sandboxed, in its container): a new note typed on the keyboard is
# copied out with ⌘C (read back with pbpaste), saved as an RTFD in the container when
# Stickies quits, and back in its window when Stickies starts again; text put on the
# pasteboard with pbcopy is pasted into another note with ⌘V and saved too. Stickies asks
# its own XPC service where its notes live. Apple's Stickies comes from this Mac's
# install, never the repository:
#
#   FINCH_HOST_APPS=Stickies tools/vm/mkramdisk.sh && tools/vm/test-stickies.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
app="finch-app-test /usr/libexec/finch-windowserver /Applications/Stickies.app/Contents/MacOS/Stickies wait:8000"
notes=/var/root/Library/Containers/com.apple.Stickies/Data/Library/Stickies
exec tools/vm/with-vm-lock.sh expect tools/vm/smoke.exp \
    'test -x /Applications/Stickies.app/Contents/MacOS/Stickies || { echo "Stickies is not in the image (FINCH_HOST_APPS=Stickies tools/vm/mkramdisk.sh)"; false; }' \
    "$app cmd:n wait:3000 'type:Finch sticky note' wait:2000 cmd:a wait:500 cmd:c wait:2000 cmd:q wait:6000" \
    'test "$(pbpaste)" = "Finch sticky note"' \
    "grep -rq 'Finch sticky note' $notes/*.rtfd/TXT.rtf" \
    "$app windows wait:2000 > /tmp/stickies-windows.txt; grep -q 'window \"Finch sticky note\"' /tmp/stickies-windows.txt" \
    "printf 'pasted from pbcopy' | pbcopy" \
    "$app cmd:n wait:3000 cmd:v wait:3000 cmd:q wait:6000" \
    "grep -rq 'pasted from pbcopy' $notes/*.rtfd/TXT.rtf"
