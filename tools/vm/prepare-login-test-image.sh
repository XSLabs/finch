#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Copy the current Finch VM image and add a disposable, tmpfs-only login test.
set -euo pipefail

FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BASE="${FINCH_ROOT}/build/vm/ramdisk.dmg"
BASE_HASHES="${FINCH_ROOT}/build/vm/all_hashes"
ACCOUNT_LIBRARY="${FINCH_ROOT}/build/root/usr/lib/system/libfinchaccount.dylib"
OUT="${FINCH_ROOT}/build/vm-login-test"
HELPER="${OUT}/finch-login-test-account"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

assert_no_symlink_in_image_path() {
    local finch_image_path=$1
    local finch_image_cursor="$mnt"
    local -a finch_image_components
    local finch_image_component

    [[ "$finch_image_path" == "$mnt/"* ]] ||
        die "path is outside the mounted image: ${finch_image_path}"
    IFS='/' read -r -a finch_image_components <<< "${finch_image_path#"$mnt"/}"
    for finch_image_component in "${finch_image_components[@]}"; do
        [[ -n "$finch_image_component" &&
            "$finch_image_component" != "." &&
            "$finch_image_component" != ".." ]] ||
            die "unsafe path inside mounted image: ${finch_image_path}"
        finch_image_cursor="${finch_image_cursor}/${finch_image_component}"
        [[ ! -L "$finch_image_cursor" ]] ||
            die "symlink in mounted image path: ${finch_image_cursor}"
    done
}

[[ -f "${BASE}" && -f "${BASE_HASHES}" ]] ||
    die "build the regular Finch VM image first"
[[ -f "${ACCOUNT_LIBRARY}" ]] ||
    die "build the Finch account library first"

mkdir -p "${OUT}"

# This helper can write only when the guest carries the test boot flag and
# both account-related paths are guest tmpfs mounts.
xcrun -sdk macosx clang -arch arm64e -mmacosx-version-min=26.0 \
    -O2 -Wall -Wextra -Werror \
    -I"${FINCH_ROOT}/userland/account-tools" \
    -o "${HELPER}" "${FINCH_ROOT}/tools/vm/login-test-account.c" \
    -L"${FINCH_ROOT}/build/root/usr/lib/system" -lfinchaccount
codesign -f -s - "${HELPER}" 2>/dev/null

# Keep the user's regular VM image intact. All test-only files go in this copy.
# APFS can make an independent copy without first writing several GB of zeros.
cp -c "${BASE}" "${OUT}/ramdisk.dmg" || cp "${BASE}" "${OUT}/ramdisk.dmg"
cp "${BASE_HASHES}" "${OUT}/all_hashes"

mnt="$(mktemp -d)"
attached=0
cleanup() {
    if [[ "${attached}" == 1 ]]; then
        hdiutil detach "${mnt}" >/dev/null || true
    fi
    rmdir "${mnt}" 2>/dev/null || true
}
trap cleanup EXIT

hdiutil attach -owners off -nobrowse -mountpoint "${mnt}" \
    -imagekey diskimage-class=CRawDiskImage "${OUT}/ramdisk.dmg" >/dev/null
attached=1

fixture="${mnt}/usr/local/share/finch/login-test"
for finch_image_path in \
    "${mnt}/private/etc" \
    "${mnt}/private/etc/finch/rc" \
    "${mnt}/usr/lib/pam" \
    "${mnt}/usr/local/share/finch/account-fixture/master.passwd" \
    "${mnt}/usr/local/share/finch/account-fixture/group" \
    "${mnt}/usr/local/bin/finch-login-test-account" \
    "${fixture}" \
    "${fixture}/etc" \
    "${fixture}/pam" \
    "${fixture}/account-fixture" \
    "${fixture}/account-fixture/master.passwd" \
    "${fixture}/account-fixture/group" \
    "${fixture}/standard-rc"; do
    assert_no_symlink_in_image_path "${finch_image_path}"
done

assert_no_symlink_in_image_path "${fixture}"
rm -rf "${fixture}"
mkdir -p "${fixture}"
for finch_image_path in \
    "${fixture}" \
    "${fixture}/etc" \
    "${fixture}/pam" \
    "${fixture}/account-fixture" \
    "${fixture}/account-fixture/master.passwd" \
    "${fixture}/account-fixture/group" \
    "${fixture}/standard-rc" \
    "${mnt}/private/etc/finch/rc" \
    "${mnt}/usr/local/bin/finch-login-test-account"; do
    assert_no_symlink_in_image_path "${finch_image_path}"
done
cp -R "${mnt}/private/etc" "${fixture}/etc"
for finch_image_path in \
    "${fixture}/etc/master.passwd" \
    "${fixture}/etc/passwd" \
    "${fixture}/etc/group"; do
    assert_no_symlink_in_image_path "${finch_image_path}"
done
rm -f "${fixture}/etc/master.passwd" "${fixture}/etc/passwd" \
    "${fixture}/etc/group"
assert_no_symlink_in_image_path "${fixture}/pam"
cp -R "${mnt}/usr/lib/pam" "${fixture}/pam"
mkdir -p "${fixture}/account-fixture"
for finch_image_path in \
    "${mnt}/usr/local/share/finch/account-fixture/master.passwd" \
    "${mnt}/usr/local/share/finch/account-fixture/group" \
    "${fixture}/account-fixture/master.passwd" \
    "${fixture}/account-fixture/group"; do
    assert_no_symlink_in_image_path "${finch_image_path}"
done
cp -Np "${mnt}/usr/local/share/finch/account-fixture/master.passwd" \
    "${fixture}/account-fixture/master.passwd"
cp -Np "${mnt}/usr/local/share/finch/account-fixture/group" \
    "${fixture}/account-fixture/group"
assert_no_symlink_in_image_path "${fixture}/standard-rc"
cp "${mnt}/private/etc/finch/rc" "${fixture}/standard-rc"
assert_no_symlink_in_image_path "${mnt}/private/etc/finch/rc"
cp "${FINCH_ROOT}/tools/vm/login-test-rc.sh" \
    "${mnt}/private/etc/finch/rc"
assert_no_symlink_in_image_path "${mnt}/usr/local/bin/finch-login-test-account"
cp "${HELPER}" "${mnt}/usr/local/bin/finch-login-test-account"
for finch_image_path in \
    "${mnt}/private/etc/finch/rc" \
    "${mnt}/usr/local/bin/finch-login-test-account"; do
    assert_no_symlink_in_image_path "${finch_image_path}"
done
chmod 755 "${mnt}/private/etc/finch/rc" \
    "${mnt}/usr/local/bin/finch-login-test-account"

hdiutil detach "${mnt}" >/dev/null
attached=0

helper_hashes="${OUT}/login-test-account.cdhashes"
: > "${helper_hashes}"
for arch in $(lipo -archs "${HELPER}"); do
    codesign -a "${arch}" -d -vvv "${HELPER}" 2>&1 |
        sed -n 's/^CDHash=//p' >> "${helper_hashes}"
done
[[ -s "${helper_hashes}" ]] ||
    die "could not read the login-test helper's code hash"
cat "${helper_hashes}" >> "${OUT}/all_hashes"
sort -u -o "${OUT}/all_hashes" "${OUT}/all_hashes"
python3 "${FINCH_ROOT}/third_party/darwin-vm/build_tc.py" \
    "${OUT}/all_hashes" "${OUT}/ramdisk.tc"

printf 'prepared separate login-test image in %s\n' "${OUT}"
