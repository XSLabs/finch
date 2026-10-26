#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# The administrator's trust settings through Finch's security command, on the
# persistent VM (whose /Library is writable, as an installed system's is): a
# server certificate for trust.finch.test isn't trusted until root trusts the
# root that signed it, and isn't once that's removed. The fixtures' keys were
# discarded. Build the images first:
#
#   tools/vm/mkramdisk.sh && tools/vm/mkpersistent.sh && tools/vm/test-trust-settings.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
out="${root}/build/vm-persistent"
[[ -f "${out}/data-empty.img" ]] || { echo "no empty data disk; run tools/vm/mkpersistent.sh" >&2; exit 2; }
disk="${out}/test-trust-settings.img"
rm -f "${disk}"
cp -c "${out}/data-empty.img" "${disk}"
export FINCH_DATA_IMAGE="${disk}" FINCH_PERSISTENT=1
cd "${root}"
f=/usr/local/share/finch/trust-settings
settings="/Library/Security/Trust Settings/Admin.plist"
tools/vm/with-vm-lock.sh expect tools/vm/smoke.exp \
    "! security verify-cert -c $f/server.pem -p ssl -s trust.finch.test" \
    "security add-trusted-cert -d -r trustRoot $f/root.pem" \
    "test \"\$(stat -f %u:%g:%Lp '$settings')\" = 0:0:644" \
    "security verify-cert -c $f/server.pem -p ssl -s trust.finch.test" \
    "! security verify-cert -c $f/server.pem -p ssl -s other.finch.test" \
    "security dump-trust-settings -d | grep -q 'Finch Trust Settings Test Root'" \
    "security remove-trusted-cert -d $f/root.pem" \
    "! security verify-cert -c $f/server.pem -p ssl -s trust.finch.test" \
    < /dev/null
rm -f "${disk}"
echo "trust-settings: the administrator's trusted root was honoured, then removed"
