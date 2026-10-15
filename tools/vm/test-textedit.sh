#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# TextEdit's documents in the VM, checked by their files: a text file opened, typed into and
# saved twice keeps two versions, File > Revert To > Browse All Versions restores the earlier
# one, File > Export as PDF writes a PDF (the save panel's Documents, its Save at 688,460),
# Find (⌘F, Return) selects a match that Escape leaves selected for typing over, and Format >
# Make Rich Text then Format > Table... inserts a table whose first cell takes the typing
# (saved as RTF, the typed text in the table).
# Apple's TextEdit comes from this Mac's install, never the repository:
#
#   FINCH_HOST_APPS=TextEdit tools/vm/mkramdisk.sh && tools/vm/test-textedit.sh
#
# The clicks are at TextEdit's places on the VM's 1024x768 screen, relative to the document
# window (it opens at 80,86): File at 82,-74; Revert To at 114,119; Browse All Versions at
# 358,152; in the version sheet, the pop-up at 357,128, its second (older) version at
# 310,150, Restore at 475,173; Export as PDF at 114,174; Format at 175,-74, Make Rich Text at
# 214,9, Table... at 189,152, the table panel's Insert at 507,256. (A relaunch restores the window
# where it was, which may not be there: the restore and the export share a launch.)
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
    "rm -f /var/root/Documents/notes.pdf" \
    "$app click:82,-74 wait:3000 move:114,119 wait:4000 move:358,152 wait:1500 click:358,152 wait:6000 click:357,128 wait:3000 move:310,150 wait:1500 click:310,150 wait:3000 click:475,173 wait:6000 click:82,-74 wait:3000 move:114,174 wait:1500 click:114,174 wait:6000 click:688,460 wait:6000" \
    "test \"\$(cat $doc)\" = secondfirst" \
    "test \"\$(head -c 4 /var/root/Documents/notes.pdf)\" = %PDF" \
    "$app cmd:f wait:3000 type:first wait:2000 key:36,13 wait:2000 key:53,27 wait:2000 type:FIRST wait:2000 cmd:s wait:5000" \
    "test \"\$(cat $doc)\" = secondFIRST" \
    "printf 'hello\\n' > $doc" \
    "$app click:175,-74 wait:2000 move:214,9 wait:1000 click:214,9 wait:4000 click:175,-74 wait:2000 move:189,152 wait:1000 click:189,152 wait:5000 click:507,256 wait:4000 type:cellA wait:2000 cmd:s wait:5000" \
    "tr -d '\\n' < $doc | grep -q 'intbl[^}]*cellA'"
