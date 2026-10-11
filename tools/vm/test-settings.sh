#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Build the current VM image with mkramdisk.sh first. Every command below runs
# in that disposable guest. The host's settings service is never changed.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
exec tools/vm/with-vm-lock.sh expect tools/vm/smoke.exp \
    'finch-configd-service-test --store-only' \
    'finch-configd-service-test --subscription-restart' \
    'mkdir -p /private/var/rw/configd-service-root/Library/Preferences/SystemConfiguration /private/var/rw/configd-service-root/etc && chown -R 0:0 /private/var/rw/configd-service-root && chmod 755 /private/var/rw/configd-service-root /private/var/rw/configd-service-root/Library /private/var/rw/configd-service-root/Library/Preferences /private/var/rw/configd-service-root/Library/Preferences/SystemConfiguration && cp /etc/passwd /etc/group /private/var/rw/configd-service-root/etc/' \
    'sed s,/usr/libexec/configd,/usr/local/bin/finch-configd-contained-service, /System/Library/Finch/LaunchDaemons/com.apple.SystemConfiguration.configd.plist > /tmp/finch-contained-configd.plist && launchctl bootout system/com.apple.SystemConfiguration.configd && launchctl bootstrap system /tmp/finch-contained-configd.plist' \
    'finch-configd-service-test' \
    'finch-configd-service-test --preferences-restart' \
    'finch-configd-network-test' \
    'test "$(stat -f %u:%g:%Lp /private/var/rw/configd-service-root/Library/Preferences/SystemConfiguration/preferences.plist)" = 0:0:644' \
    'launchctl bootout system/com.apple.SystemConfiguration.configd && finch-configd-service-test --unavailable'
