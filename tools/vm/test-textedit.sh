#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# TextEdit's documents in the VM, checked by their files: a text file opened, typed into and
# saved twice keeps two versions, and File > Revert To > Browse All Versions restores the
# earlier one. Apple's TextEdit comes from this Mac's install, never the repository:
#
#   FINCH_HOST_APPS=TextEdit tools/vm/mkramdisk.sh && tools/vm/test-textedit.sh
#
# The clicks are at TextEdit's places on the VM's 1024x768 screen, relative to the document
# window (it opens at 80,86): File at 82,-74; Revert To at 114,119; Browse All Versions at
# 358,152; in the version sheet, the pop-up at 357,128, its second (older) version at
# 310,150, Restore at 475,173.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
doc=/tmp/finch-textedit/notes.txt
app="FINCH_APP_ARGS=$doc finch-app-test /usr/libexec/finch-windowserver /Applications/TextEdit.app/Contents/MacOS/TextEdit 'window:notes*' wait:5000"
exec tools/vm/with-vm-lock.sh expect tools/vm/smoke.exp \
    'test -x /Applications/TextEdit.app/Contents/MacOS/TextEdit || { echo "TextEdit is not in the image (FINCH_HOST_APPS=TextEdit tools/vm/mkramdisk.sh)"; false; }' \
    "rm -rf /tmp/finch-textedit /var/root/Library/Application\\ Support/Finch/Versions && mkdir -p /tmp/finch-textedit && printf 'first\\n' > $doc" \
    "$app type:second wait:2000 cmd:s wait:5000 type:third wait:2000 cmd:s wait:5000" \
    "test \"\$(cat $doc)\" = secondthirdfirst" \
    "test \$(ls /var/root/Library/Application\\ Support/Finch/Versions/*/*.txt | wc -l) -eq 2" \
    "$app click:82,-74 wait:3000 move:114,119 wait:4000 move:358,152 wait:1500 click:358,152 wait:6000 click:357,128 wait:3000 move:310,150 wait:1500 click:310,150 wait:3000 click:475,173 wait:6000" \
    "test \"\$(cat $doc)\" = secondfirst"
