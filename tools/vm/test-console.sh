#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Console in the VM: the Mac's live log streams into its message table (Finch's ConsoleKit
# reading finch-logd's store), with a message sent by logger(1) (syslog, which reaches the
# unified log as on macOS) and finch-log-test's os_log messages; selecting them all and
# copying puts them on the pasteboard, read back with pbpaste. Apple's Console comes from
# this Mac's install, never the repository:
#
#   FINCH_HOST_APPS=Console tools/vm/mkramdisk.sh && tools/vm/test-console.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
app="finch-app-test /usr/libexec/finch-windowserver /Applications/Console.app/Contents/MacOS/Console wait:30000"
# (localhost in the sidebar, then "Start streaming", then the table)
exec tools/vm/with-vm-lock.sh expect tools/vm/smoke.exp \
    'test -x /Applications/Console.app/Contents/MacOS/Console || { echo "Console is not in the image (FINCH_HOST_APPS=Console tools/vm/mkramdisk.sh)"; false; }' \
    "(sleep 40; logger finch-console-logger-42; finch-log-test >/dev/null 2>&1) & ($app click:169,139 wait:3000 click:660,353 wait:16000 click:600,180 wait:1000 cmd:a wait:1000 cmd:c wait:2000 cmd:q wait:2000)" \
    'pbpaste | grep -Eq "default[[:space:]]+logger[[:space:]].*finch-console-logger-42"' \
    'pbpaste | grep -Eq "error[[:space:]]+finch-log-test[[:space:]].*open failed"'
