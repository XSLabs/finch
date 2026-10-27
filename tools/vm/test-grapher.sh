#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Grapher in the VM (sandboxed): a new 2D graph from the template chooser, an equation typed
# into it, the document saved with ⌘S through the save panel as Untitled.gcx in Documents (a
# typedstream archive, Grapher's format), and opened again in its own window. Apple's
# Grapher comes from this Mac's install, never the repository:
#
#   FINCH_HOST_APPS=Grapher tools/vm/mkramdisk.sh && tools/vm/test-grapher.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
app="finch-app-test /usr/libexec/finch-windowserver /Applications/Grapher.app/Contents/MacOS/Grapher wait:15000"
doc=/var/root/Documents/Untitled.gcx
exec tools/vm/with-vm-lock.sh expect tools/vm/smoke.exp \
    'test -x /Applications/Grapher.app/Contents/MacOS/Grapher || { echo "Grapher is not in the image (FINCH_HOST_APPS=Grapher tools/vm/mkramdisk.sh)"; false; }' \
    "rm -f $doc; $app key:36,13 wait:6000 'type:y=x^2' key:36,13 wait:4000 cmd:s wait:4000 key:36,13 wait:5000 cmd:q wait:3000" \
    "test -s $doc && head -c 16 $doc | grep -q streamtyped" \
    "FINCH_APP_ARGS=$doc $app windows cmd:q wait:3000 > /tmp/grapher-windows.txt; grep -q 'window \"Untitled.gcx\"' /tmp/grapher-windows.txt"
