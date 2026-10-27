#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Terminal in the VM: commands typed at its shell run (their output is written to a file),
# and what the shell prints is on the screen to select and copy with ⌘A ⌘C (read back with
# pbpaste; the typed command has $((6*7)), so only its output says 42). Apple's Terminal
# comes from this Mac's install, never the repository. Its first launch takes about 30
# seconds (it archives its settings). It starts a third time, restoring its last session, and
# a line typed then runs promptly:
#
#   FINCH_HOST_APPS=Terminal tools/vm/mkramdisk.sh && tools/vm/test-terminal.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
app="finch-app-test /usr/libexec/finch-windowserver /Applications/Terminal.app/Contents/MacOS/Terminal wait:40000"
exec tools/vm/with-vm-lock.sh expect tools/vm/smoke.exp \
    'test -x /Applications/Terminal.app/Contents/MacOS/Terminal || { echo "Terminal is not in the image (FINCH_HOST_APPS=Terminal tools/vm/mkramdisk.sh)"; false; }' \
    "rm -f /tmp/term-out.txt; $app 'type:echo finch-\$((6*7)) > /tmp/term-out.txt; uname -s >> /tmp/term-out.txt' key:36,13 wait:5000 'type:echo finch-on-screen-\$((6*7))' key:36,13 wait:3000 cmd:a wait:1000 cmd:c wait:2000 cmd:q wait:3000" \
    'test "$(cat /tmp/term-out.txt)" = "$(printf "finch-42\nDarwin")"' \
    'pbpaste | grep -q finch-on-screen-42' \
    "rm -f /tmp/term-restored.txt; $app 'type:echo finch restored session > /tmp/term-restored.txt' key:36,13 wait:4000 cmd:q wait:3000" \
    'test "$(cat /tmp/term-restored.txt)" = "finch restored session"'
