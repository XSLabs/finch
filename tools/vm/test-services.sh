#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# The system services in the VM: each daemon launchd keeps running is running (a process ID
# in launchctl list), and cron runs a job from a crontab within its minute. (Their clients are
# checked by the VM suite's tests: mdnsd-test, diskarbitration-session-test, configd's in
# tools/vm/test-settings.sh.)
#
#   tools/vm/mkramdisk.sh && tools/vm/test-services.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
running() {
    # launchctl list: PID, last exit status, label; a running daemon has a number in the first
    # column (the guest has grep, but no awk)
    echo "launchctl list | grep -qE '^[0-9]+[[:space:]].*[[:space:]]${1//./\\.}\$'"
}
exec tools/vm/with-vm-lock.sh expect tools/vm/smoke.exp \
    "$(running com.apple.notifyd)" \
    "$(running com.apple.syslogd)" \
    "$(running com.apple.logd)" \
    "$(running com.apple.SystemConfiguration.configd)" \
    "$(running com.apple.diskarbitrationd)" \
    "$(running com.apple.mDNSResponder)" \
    "$(running com.vix.cron)" \
    "rm -f /tmp/finch-cron-ran && echo '* * * * * /usr/bin/touch /tmp/finch-cron-ran' | crontab -" \
    'for i in $(seq 1 15); do [ -e /tmp/finch-cron-ran ] && break; sleep 5; done; test -e /tmp/finch-cron-ran' \
    'crontab -r'
