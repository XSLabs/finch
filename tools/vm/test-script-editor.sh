#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Script Editor in the VM, on Finch's AppleScript: a script typed in a new document runs
# with ⌘R (it sets the clipboard, read back with pbpaste), is saved with ⌘S through the save
# panel as Untitled.scpt in Documents, and the saved script runs again with osascript.
# Apple's Script Editor comes from this Mac's install, never the repository:
#
#   FINCH_HOST_APPS="Script Editor," tools/vm/mkramdisk.sh && tools/vm/test-script-editor.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
app="finch-app-test /usr/libexec/finch-windowserver '/Applications/Script Editor.app/Contents/MacOS/Script Editor' wait:12000"
exec tools/vm/with-vm-lock.sh expect tools/vm/smoke.exp \
    'test -x "/Applications/Script Editor.app/Contents/MacOS/Script Editor" || { echo "Script Editor is not in the image (FINCH_HOST_APPS=\"Script Editor,\" tools/vm/mkramdisk.sh)"; false; }' \
    "rm -f /var/root/Documents/Untitled.scpt; $app 'type:set the clipboard to \"Finch\" & (6 * 7)' wait:2000 cmd:r wait:6000 cmd:s wait:4000 key:36,13 wait:6000 cmd:q wait:3000" \
    'test "$(pbpaste)" = Finch42' \
    'test -s /var/root/Documents/Untitled.scpt' \
    'printf cleared | pbcopy && osascript /var/root/Documents/Untitled.scpt && test "$(pbpaste)" = Finch42'
