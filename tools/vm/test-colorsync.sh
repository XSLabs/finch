#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# ColorSync Utility in the VM: Profile First Aid's Verify checks the installed ICC
# profiles (Finch's ColorSync reading them) and reports; the report is selected, copied
# and read back with pbpaste. Apple's ColorSync Utility comes from this Mac's install,
# never the repository:
#
#   FINCH_HOST_APPS="ColorSync Utility," tools/vm/mkramdisk.sh && tools/vm/test-colorsync.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
app="finch-app-test /usr/libexec/finch-windowserver '/Applications/ColorSync Utility.app/Contents/MacOS/ColorSync Utility' wait:30000"
# (Verify, then the report's text)
exec tools/vm/with-vm-lock.sh expect tools/vm/smoke.exp \
    'test -x "/Applications/ColorSync Utility.app/Contents/MacOS/ColorSync Utility" || { echo "ColorSync Utility is not in the image"; false; }' \
    "$app click:718,550 wait:15000 click:500,400 wait:1000 cmd:a wait:1000 cmd:c wait:2000 cmd:q wait:2000" \
    'pbpaste | grep -Eq "Checking [0-9]+ profiles"' \
    'pbpaste | grep -q "Verify done. No problems found."'
