#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# finch-update on the host, with Finch's Security: a signed update verifies, a changed archive
# or another key's signature doesn't; install puts a new root in place and keeps the old one,
# an unreadable archive leaves the root as it was, and rollback puts the old one back. Uses a
# throwaway key pair, not the release's. Run directly (DYLD_* is set per command).
set -uo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
R="${FINCH_ROOT}/build/root/System/Library"
TOOL="${FINCH_ROOT}/build/root/usr/sbin/finch-update"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
fails=0
check() {
    if [[ "$1" == "$2" ]]; then echo "ok: $3"; else echo "FAIL: $3 (got $1, want $2)"; fails=$((fails + 1)); fi
}
upd() { DYLD_FRAMEWORK_PATH="${R}/Frameworks:${R}/PrivateFrameworks" FINCH_UPDATE_KEY="${T}/key.der" "${TOOL}" "$@" > "${T}/out" 2>&1; echo $?; }

openssl ecparam -name prime256v1 -genkey -noout -out "${T}/key.pem" 2>/dev/null
openssl ec -in "${T}/key.pem" -pubout -outform DER 2>/dev/null | tail -c 65 > "${T}/key.der"
openssl ecparam -name prime256v1 -genkey -noout -out "${T}/other.pem" 2>/dev/null
mkdir -p "${T}/v2/etc" && echo two > "${T}/v2/etc/version"
tar -C "${T}/v2" -czf "${T}/v2.tar.gz" .
openssl dgst -sha256 -sign "${T}/key.pem" -out "${T}/v2.tar.gz.sig" "${T}/v2.tar.gz"

check "$(upd verify "${T}/v2.tar.gz")" 0 "a signed update verifies"
cp "${T}/v2.tar.gz" "${T}/changed.tar.gz" && printf x >> "${T}/changed.tar.gz"
cp "${T}/v2.tar.gz.sig" "${T}/changed.tar.gz.sig"
check "$(upd verify "${T}/changed.tar.gz")" 1 "a changed archive doesn't"
openssl dgst -sha256 -sign "${T}/other.pem" -out "${T}/other.sig" "${T}/v2.tar.gz"
check "$(upd verify "${T}/v2.tar.gz" "${T}/other.sig")" 1 "another key's signature doesn't"

mkdir -p "${T}/system/etc" && echo one > "${T}/system/etc/version"
check "$(upd install "${T}/changed.tar.gz" --root "${T}/system")" 1 "an unsigned update isn't installed"
check "$(cat "${T}/system/etc/version")" one "  and the system is unchanged"
check "$(upd install "${T}/v2.tar.gz" --root "${T}/system")" 0 "a signed update installs"
check "$(cat "${T}/system/etc/version")" two "  the new system is in place"
check "$(cat "${T}/system.finch-old/etc/version")" one "  the previous one is kept"
# a signed archive that doesn't unpack: the root stays
head -c 100 "${T}/v2.tar.gz" > "${T}/broken.tar.gz"
openssl dgst -sha256 -sign "${T}/key.pem" -out "${T}/broken.tar.gz.sig" "${T}/broken.tar.gz"
check "$(upd install "${T}/broken.tar.gz" --root "${T}/system")" 1 "an archive that doesn't unpack fails"
check "$(cat "${T}/system/etc/version")" two "  and the system is unchanged"
check "$([[ -e "${T}/system.finch-new" ]] && echo left || echo cleared)" cleared "  its staging folder is cleared"
check "$(upd rollback --root "${T}/system")" 0 "rollback"
check "$(cat "${T}/system/etc/version")" one "  the previous system is back"
check "$(upd rollback --root "${T}/system")" 1 "a second rollback has nothing to go back to"
echo "${fails} failed"
[[ "${fails}" -eq 0 ]]
