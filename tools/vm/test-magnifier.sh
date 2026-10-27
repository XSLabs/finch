#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Magnifier in the VM: with the pointer over the menu bar, its view shows the menu bar's
# bottom edge magnified (a dark line where the window server's screen has a one-point one)
# and the desktop below it light; with Invert checked, the same places come out the other
# way round. Pixels are read from the window server's own screen. Apple's Magnifier comes
# from this Mac's install, never the repository:
#
#   FINCH_HOST_APPS=Magnifier tools/vm/mkramdisk.sh && tools/vm/test-magnifier.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
app="finch-app-test /usr/libexec/finch-windowserver /Applications/Magnifier.app/Contents/MacOS/Magnifier wait:30000"
exec tools/vm/with-vm-lock.sh expect tools/vm/smoke.exp \
    'test -x /Applications/Magnifier.app/Contents/MacOS/Magnifier || { echo "Magnifier is not in the image (FINCH_HOST_APPS=Magnifier tools/vm/mkramdisk.sh)"; false; }' \
    "$app move:60,10 wait:3000 sample:512,256,line sample:512,341,below click:747,444 wait:1000 move:60,10 wait:3000 sample:512,256,inverted-line sample:512,341,inverted-below cmd:q wait:2000 > /tmp/magnifier.txt" \
    'grep -Eq "^line: [0-9]{1,2} [0-9]{1,2} [0-9]{1,2}$" /tmp/magnifier.txt' \
    'grep -Eq "^below: 2[0-9]{2} 2[0-9]{2} 2[0-9]{2}$" /tmp/magnifier.txt' \
    'grep -Eq "^inverted-line: 2[0-9]{2} 2[0-9]{2} 2[0-9]{2}$" /tmp/magnifier.txt' \
    'grep -Eq "^inverted-below: [0-9]{1,2} [0-9]{1,2} [0-9]{1,2}$" /tmp/magnifier.txt'
