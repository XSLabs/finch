#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Check that a failed first start wakes a waiting XPC client and that the same
# declared service starts again after the cause of the failure is removed.
# This test writes only under the disposable VM's /tmp directory.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"

# The guest wrapper exits before it checks in while the marker exists. Once
# the test removes the marker, the same job starts the already-staged test
# daemon. Keep both files in the guest's writable /tmp.
setup=$(cat <<'GUEST'
(
    set -e
    rm -f /tmp/finch-bootstrap-startup-failure.fail
    cat > /tmp/finch-bootstrap-startup-failure-wrapper <<'WRAPPER'
#!/bin/sh
if [ -e /tmp/finch-bootstrap-startup-failure.fail ]; then
    exit 1
fi
exec /usr/local/bin/finch-xpc-service-test daemon org.finch.test.bootstrap-startup-failure
WRAPPER
    chmod 755 /tmp/finch-bootstrap-startup-failure-wrapper
    touch /tmp/finch-bootstrap-startup-failure.fail
    cat > /tmp/finch-bootstrap-startup-failure.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>org.finch.test.bootstrap-startup-failure</string>
    <key>ProgramArguments</key>
    <array>
        <string>/tmp/finch-bootstrap-startup-failure-wrapper</string>
    </array>
    <key>MachServices</key>
    <dict>
        <key>org.finch.test.bootstrap-startup-failure</key>
        <true/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>0</integer>
    <key>StandardErrorPath</key>
    <string>/tmp/finch-bootstrap-startup-failure.log</string>
</dict>
</plist>
PLIST
)
GUEST
)

exec tools/vm/with-vm-lock.sh expect tools/vm/smoke.exp \
    "$setup" \
    'launchctl bootstrap system /tmp/finch-bootstrap-startup-failure.plist' \
    'output=$(/usr/local/bin/finch-xpc-service-test ping org.finch.test.bootstrap-startup-failure 2>&1); finch_ping_status=$?; printf "%s\n" "$output"; [[ "$finch_ping_status" -eq 1 && "$output" == *"no reply (connection error)"* && "$output" != *"TIMED OUT"* ]]' \
    'job=$(launchctl print system/org.finch.test.bootstrap-startup-failure); printf "%s\n" "$job"; [[ "$job" == *"runs = 1"* && "$job" == *"last exit code = 1"* && "$job" == *"waiting for first message"* ]]' \
    'rm -f /tmp/finch-bootstrap-startup-failure.fail' \
    'output=$(/usr/local/bin/finch-xpc-service-test ping org.finch.test.bootstrap-startup-failure 2>&1); finch_ping_status=$?; printf "%s\n" "$output"; [[ "$finch_ping_status" -eq 0 && "$output" == *"replied"* && "$output" != *"TIMED OUT"* ]]' \
    'job=$(launchctl print system/org.finch.test.bootstrap-startup-failure); printf "%s\n" "$job"; [[ "$job" == *"runs = 2"* && "$job" == *"state = running"* && "$job" == *"state = active"* ]]' \
    'launchctl bootout system/org.finch.test.bootstrap-startup-failure && rm -f /tmp/finch-bootstrap-startup-failure.plist /tmp/finch-bootstrap-startup-failure-wrapper /tmp/finch-bootstrap-startup-failure.fail'
