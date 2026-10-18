#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# finch-update on the host, with Finch's Security: signatures, file preservation, install,
# rollback, interruption recovery, concurrent installs, and resumable fetches are checked in
# temporary roots. The test build includes stop points used only to kill it at transaction edges.
# It uses a throwaway key pair, not the release's. It uses the Finch runtime by default;
# FINCH_UPDATE_TEST_USE_APPLE=1 compares the update code with Apple's host frameworks.
set -uo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
R="${FINCH_ROOT}/build/root/System/Library"
IOS_R="${FINCH_ROOT}/build/root/System/iOSSupport/System/Library"
T="$(mktemp -d)"
TOOL="${FINCH_UPDATE_TEST_TOOL:-${T}/finch-update-test}"
mkdir -p "${T}/lib"
for lib in libMobileGestalt libDiagnosticMessagesClient; do ln -s "${FINCH_ROOT}/build/root/usr/lib/${lib}.dylib" "${T}/lib/"; done
ln -s "${FINCH_ROOT}/build/root/usr/lib/system/libfinchaccount.dylib" "${T}/lib/"
ln -s "${FINCH_ROOT}/build/root/usr/lib/system/libsystem_dnssd.dylib" "${T}/lib/"
ln -s "${FINCH_ROOT}/build/root/usr/lib/libsandbox.1.dylib" "${T}/lib/"
FW="${FINCH_TRIAL:+${FINCH_TRIAL}:}${R}/Frameworks:${IOS_R}/Frameworks:${R}/PrivateFrameworks:${R}/Frameworks/Quartz.framework/Frameworks"
FW="${FW}:${R}/Frameworks/CoreServices.framework/Versions/A/Frameworks:${R}/Frameworks/ApplicationServices.framework/Versions/A/Frameworks"
FW="${FW}:${R}/Frameworks/Carbon.framework/Versions/A/Frameworks:${R}/Frameworks/OpenDirectory.framework/Versions/A/Frameworks"
LIBS="${FINCH_ROOT}/build/root/usr/lib/swift:${T}/lib:${R}/Frameworks/OpenGL.framework/Versions/A/Libraries"
server=
trap '[[ -n "${server}" ]] && { kill "${server}"; wait "${server}"; } 2>/dev/null; if [[ -z "${FINCH_UPDATE_KEEP_TMP:-}" ]]; then rm -rf "${T}"; else echo "test files kept at ${T}"; fi' EXIT
fails=0
if [[ -z "${FINCH_UPDATE_TEST_TOOL:-}" ]]; then
    xcrun -sdk macosx clang -arch arm64e -mmacosx-version-min=26.4 -O2 -Wall -Wextra -Werror \
        -DFINCH_UPDATE_TESTING -o "${TOOL}" "${FINCH_ROOT}/userland/update/finch-update.c" \
        "${FINCH_ROOT}/userland/update/fetch.m" -fobjc-arc -framework Security -framework CoreFoundation \
        -framework Foundation || exit 1
fi
check() {
    if [[ "$1" == "$2" ]]; then echo "ok: $3"; else echo "FAIL: $3 (got $1, want $2)"; fails=$((fails + 1)); fi
}
run_tool() {
    if [[ "${FINCH_UPDATE_TEST_USE_APPLE:-}" == 1 ]]; then
        FINCH_UPDATE_KEY="${T}/key.der" "${TOOL}" "$@"
    else
        DYLD_FRAMEWORK_PATH="${FW}" DYLD_LIBRARY_PATH="${LIBS}" FINCH_UPDATE_KEY="${T}/key.der" \
            FINCH_TEST_SECURITY_IMAGE="${FINCH_TRIAL:-${R}/Frameworks}/Security.framework/Security" "${TOOL}" "$@"
    fi
}
upd() { run_tool "$@" > "${T}/out" 2>&1; echo $?; }
run_logged() { local log="$1"; shift; run_tool "$@" > "${log}" 2>&1; }
stopped_pid=
start_stopped_update() {
    local point="$1" ready="$2" log="$3"
    shift 3
    rm -f "${ready}"
    # Start the updater itself in the background, so $! is the process stopped by
    # the test hook. Backgrounding the run_tool shell function leaves an extra
    # shell process behind when we kill the updater.
    if [[ "${FINCH_UPDATE_TEST_USE_APPLE:-}" == 1 ]]; then
        FINCH_UPDATE_KEY="${T}/key.der" FINCH_UPDATE_TEST_STOP_AT="${point}" \
            FINCH_UPDATE_TEST_READY="${ready}" "${TOOL}" "$@" > "${log}" 2>&1 &
    else
        DYLD_FRAMEWORK_PATH="${FW}" DYLD_LIBRARY_PATH="${LIBS}" \
            FINCH_UPDATE_KEY="${T}/key.der" \
            FINCH_TEST_SECURITY_IMAGE="${FINCH_TRIAL:-${R}/Frameworks}/Security.framework/Security" \
            FINCH_UPDATE_TEST_STOP_AT="${point}" FINCH_UPDATE_TEST_READY="${ready}" \
            "${TOOL}" "$@" > "${log}" 2>&1 &
    fi
    stopped_pid=$!
    for _ in $(seq 100); do
        [[ -s "${ready}" ]] && return 0
        sleep 0.05
    done
    kill -KILL "${stopped_pid}" 2>/dev/null
    wait "${stopped_pid}" 2>/dev/null
    return 1
}
kill_stopped_update() {
    kill -KILL "${stopped_pid}" 2>/dev/null
    wait "${stopped_pid}" 2>/dev/null
    stopped_pid=
}
continue_stopped_update() {
    kill -CONT "${stopped_pid}" 2>/dev/null
    wait "${stopped_pid}"
    local status=$?
    stopped_pid=
    return "${status}"
}

openssl ecparam -name prime256v1 -genkey -noout -out "${T}/key.pem" 2>/dev/null
openssl ec -in "${T}/key.pem" -pubout -outform DER 2>/dev/null | tail -c 65 > "${T}/key.der"
openssl ecparam -name prime256v1 -genkey -noout -out "${T}/other.pem" 2>/dev/null
mkdir -p "${T}/v2/etc" && echo two > "${T}/v2/etc/version"
tar -C "${T}/v2" -czf "${T}/v2.tar.gz" .
openssl dgst -sha256 -sign "${T}/key.pem" -out "${T}/v2.tar.gz.sig" "${T}/v2.tar.gz"
mkdir -p "${T}/v3/etc" && echo three > "${T}/v3/etc/version"
head -c 8000000 /dev/urandom > "${T}/v3/etc/blob"
tar -C "${T}/v3" -czf "${T}/v3.tar.gz" .
openssl dgst -sha256 -sign "${T}/key.pem" -out "${T}/v3.tar.gz.sig" "${T}/v3.tar.gz"

check "$(upd verify "${T}/v2.tar.gz")" 0 "a signed update verifies"
cp "${T}/v2.tar.gz" "${T}/changed.tar.gz" && printf x >> "${T}/changed.tar.gz"
cp "${T}/v2.tar.gz.sig" "${T}/changed.tar.gz.sig"
check "$(upd verify "${T}/changed.tar.gz")" 1 "a changed archive doesn't"
openssl dgst -sha256 -sign "${T}/other.pem" -out "${T}/other.sig" "${T}/v2.tar.gz"
check "$(upd verify "${T}/v2.tar.gz" "${T}/other.sig")" 1 "another key's signature doesn't"

mkdir -p "${T}/system/etc" && echo one > "${T}/system/etc/version"
# the user's files and accounts, which an update keeps
mkdir -p "${T}/system/Users/ada/Documents" "${T}/system/private/etc" && echo draft > "${T}/system/Users/ada/Documents/notes.txt"
chmod 640 "${T}/system/Users/ada/Documents/notes.txt"
ln -s Documents/notes.txt "${T}/system/Users/ada/note-link"
echo 'ada:*:501:20::0:0:Ada:/Users/ada:/bin/zsh' > "${T}/system/private/etc/master.passwd"
mkdir -p "${T}/system/Library/Preferences" "${T}/system/Library/LaunchDaemons" "${T}/v2/Library/LaunchDaemons"
mkdir -p "${T}/system/private/var/root" && echo hi > "${T}/system/private/var/root/.profile"
echo dark > "${T}/system/Library/Preferences/look" && echo old > "${T}/system/Library/LaunchDaemons/job" && echo new > "${T}/v2/Library/LaunchDaemons/job"
head -c 1000000 /dev/urandom > "${T}/v2/etc/blob"
mkdir -p "${T}/v2/Users" "${T}/v2/private/etc" && echo 'root:*:0:0::0:0:System Administrator:/var/root:/bin/sh' > "${T}/v2/private/etc/master.passwd"
tar -C "${T}/v2" -czf "${T}/v2.tar.gz" . && openssl dgst -sha256 -sign "${T}/key.pem" -out "${T}/v2.tar.gz.sig" "${T}/v2.tar.gz"
check "$(upd install "${T}/changed.tar.gz" --root "${T}/system")" 1 "an unsigned update isn't installed"
check "$(cat "${T}/system/etc/version")" one "  and the system is unchanged"
check "$(upd install "${T}/v2.tar.gz" --root "${T}/system")" 0 "a signed update installs"
check "$(cat "${T}/system/etc/version")" two "  the new system is in place"
check "$(cat "${T}/system.finch-old/etc/version")" one "  the previous one is kept"
check "$(cat "${T}/system/Users/ada/Documents/notes.txt")" draft "  the user's files came across"
check "$(stat -f '%Lp' "${T}/system/Users/ada/Documents/notes.txt")" 640 "  with its file mode"
check "$([[ -L "${T}/system/Users/ada/note-link" ]] && readlink "${T}/system/Users/ada/note-link" || echo missing)" Documents/notes.txt "  and its symbolic link"
check "$(cut -d: -f1 "${T}/system/private/etc/master.passwd")" ada "  and the accounts, not the payload's"
check "$(cat "${T}/system/Library/Preferences/look")" dark "  and the settings"
check "$(cat "${T}/system/private/var/root/.profile")" hi "  even where the update has no folder for them"
check "$(cat "${T}/system/Library/LaunchDaemons/job")" new "  but the system's own files are the update's"
# a signed archive that doesn't unpack: the root stays
head -c 100 "${T}/v2.tar.gz" > "${T}/broken.tar.gz"
openssl dgst -sha256 -sign "${T}/key.pem" -out "${T}/broken.tar.gz.sig" "${T}/broken.tar.gz"
check "$(upd install "${T}/broken.tar.gz" --root "${T}/system")" 1 "an archive that doesn't unpack fails"
check "$(cat "${T}/system/etc/version")" two "  and the system is unchanged"
check "$([[ -e "${T}/system.finch-new" ]] && echo left || echo cleared)" cleared "  its staging folder is cleared"
check "$(upd rollback --root "${T}/system")" 0 "rollback"
check "$(cat "${T}/system/etc/version")" one "  the previous system is back"
check "$(cat "${T}/system/Users/ada/Documents/notes.txt")" draft "  with the user's files"
check "$(upd rollback --root "${T}/system")" 1 "a second rollback has nothing to go back to"

# A recovery name may contain only a real system tree. A symlink could otherwise be
# renamed into a missing active-root path.
mkdir -p "${T}/bad-layout-target/etc"
echo protected > "${T}/bad-layout-target/etc/version"
ln -s "${T}/bad-layout-target" "${T}/bad-layout.finch-old"
check "$(upd install "${T}/v2.tar.gz" --root "${T}/bad-layout")" 1 "a symlinked recovery copy is refused"
check "$([[ -L "${T}/bad-layout.finch-old" ]] && echo symlink || echo changed)" symlink "  and left in place"
check "$(cat "${T}/bad-layout-target/etc/version")" protected "  without changing its target"

# Kill the updater after it has copied a user path to a temporary name. The active root must
# still contain the source, and the next install must discard the partial stage and retry.
mkdir -p "${T}/recovery/etc" "${T}/recovery/Users/ada/Documents"
echo one > "${T}/recovery/etc/version"
echo draft > "${T}/recovery/Users/ada/Documents/notes.txt"
ln -s Documents/notes.txt "${T}/recovery/Users/ada/note-link"
start_stopped_update copy.after_temp "${T}/copy.ready" "${T}/copy.log" install "${T}/v2.tar.gz" --root "${T}/recovery"
check "$([[ $? -eq 0 ]] && echo stopped || echo missed)" stopped "the copy interruption point is reached"
kill_stopped_update
check "$(cat "${T}/recovery/etc/version")" one "  killing the copy leaves the active system alone"
check "$(cat "${T}/recovery/Users/ada/Documents/notes.txt")" draft "  and leaves the user's file in place"
check "$(upd install "${T}/v2.tar.gz" --root "${T}/recovery")" 0 "the interrupted copy can be retried"
check "$(cat "${T}/recovery/etc/version")" two "  the retry installs the new system"
check "$([[ -L "${T}/recovery/Users/ada/note-link" ]] && readlink "${T}/recovery/Users/ada/note-link" || echo missing)" Documents/notes.txt "  while keeping a user link"

# Kill after the old root has moved aside. Restarting install must restore it first, then
# retry the new update while keeping the last good rollback copy.
start_stopped_update install.after_old_rename "${T}/swap.ready" "${T}/swap.log" install "${T}/v3.tar.gz" --root "${T}/recovery"
check "$([[ $? -eq 0 ]] && echo stopped || echo missed)" stopped "the install swap interruption point is reached"
kill_stopped_update
check "$([[ -e "${T}/recovery" ]] && echo present || echo missing)" missing "  the killed process leaves the rename gap"
check "$(cat "${T}/recovery.finch-old/etc/version")" two "  the old system remains recoverable"
check "$(cat "${T}/recovery.finch-discard/etc/version")" one "  the earlier rollback copy remains recoverable"
check "$(upd install "${T}/v3.tar.gz" --root "${T}/recovery")" 0 "install recovers and retries after the rename gap"
check "$(cat "${T}/recovery/etc/version")" three "  the requested update is installed"
echo latest > "${T}/recovery/Users/ada/Documents/notes.txt"

# Kill rollback after it moves the active system away. The next rollback should finish from
# the old tree, which already has the latest user data copied into it.
start_stopped_update rollback.after_root_rename "${T}/rollback.ready" "${T}/rollback.log" rollback --root "${T}/recovery"
check "$([[ $? -eq 0 ]] && echo stopped || echo missed)" stopped "the rollback interruption point is reached"
kill_stopped_update
check "$([[ -e "${T}/recovery" ]] && echo present || echo missing)" missing "  the killed rollback leaves the rename gap"
check "$(upd rollback --root "${T}/recovery")" 0 "the next rollback finishes the interrupted one"
check "$(cat "${T}/recovery/etc/version")" two "  the old system is back"
check "$(cat "${T}/recovery/Users/ada/Documents/notes.txt")" latest "  with the latest user file"

# Hold the root lock while a second install starts. It must wait, then both live installs
# must finish in order; a killed lock holder must also release the lock for the next updater.
mkdir -p "${T}/locked/etc"
echo one > "${T}/locked/etc/version"
start_stopped_update install.after_lock "${T}/lock-a.ready" "${T}/lock-a.log" install "${T}/v2.tar.gz" --root "${T}/locked"
check "$([[ $? -eq 0 ]] && echo stopped || echo missed)" stopped "the first install holds the root lock"
(
    run_logged "${T}/lock-b.log" install "${T}/v3.tar.gz" --root "${T}/locked"
    echo $? > "${T}/lock-b.status"
) & lock_b=$!
sleep 0.2
check "$([[ -e "${T}/lock-b.status" ]] && echo done || echo waiting)" waiting "  the second install waits for the lock"
continue_stopped_update
check "$([[ $? -eq 0 ]] && echo ok || echo failed)" ok "  both concurrent installs finish"
wait "${lock_b}"
check "$(cat "${T}/lock-b.status")" 0 "  the waiting install succeeds"
check "$(cat "${T}/locked/etc/version")" three "  the second install becomes active"
check "$(cat "${T}/locked.finch-old/etc/version")" two "  the first install remains available for rollback"

start_stopped_update install.after_lock "${T}/lock-crash.ready" "${T}/lock-crash.log" install "${T}/v2.tar.gz" --root "${T}/locked"
check "$([[ $? -eq 0 ]] && echo stopped || echo missed)" stopped "a second lock holder can be stopped"
(
    run_logged "${T}/lock-c.log" install "${T}/v3.tar.gz" --root "${T}/locked"
    echo $? > "${T}/lock-c.status"
) & lock_c=$!
sleep 0.2
check "$([[ -e "${T}/lock-c.status" ]] && echo done || echo waiting)" waiting "  another install waits while the lock is held"
kill_stopped_update
wait "${lock_c}"
check "$(cat "${T}/lock-c.status")" 0 "  killing one updater releases the lock"
check "$(cat "${T}/locked/etc/version")" three "  the waiting update leaves a whole root"

# fetch, from a server that cuts off the first download of each archive halfway
if [[ "${FINCH_UPDATE_TEST_SKIP_FETCH:-0}" == 1 ]]; then
    echo "skip: fetch tests disabled by FINCH_UPDATE_TEST_SKIP_FETCH"
else
mkdir -p "${T}/web"
cp "${T}/v2.tar.gz" "${T}/v2.tar.gz.sig" "${T}/web/"
cp "${T}/v2.tar.gz" "${T}/web/again.tar.gz" && cp "${T}/v2.tar.gz.sig" "${T}/web/again.tar.gz.sig"
cp "${T}/changed.tar.gz" "${T}/web/changed.tar.gz" && cp "${T}/v2.tar.gz.sig" "${T}/web/changed.tar.gz.sig"
python3 "${FINCH_ROOT}/tools/release/test-server.py" "${T}/web" & server=$!
for _ in $(seq 50); do [[ -s "${T}/web/.port" ]] && break; sleep 0.1; done
web="http://127.0.0.1:$(cat "${T}/web/.port")"
check "$(FINCH_UPDATE_ATTEMPTS=1 upd fetch "${web}/v2.tar.gz" "${T}/dl")" 1 "a fetch cut off fails"
check "$([[ -s "${T}/dl/v2.tar.gz.resume" ]] && echo kept || echo none)" kept "  and keeps its resume data"
check "$(upd fetch "${web}/v2.tar.gz" "${T}/dl")" 0 "the next fetch finishes it"
check "$(grep -c '^v2.tar.gz bytes=[1-9][0-9]*-$' "${T}/web/.ranges")" 1 "  from where it stopped"
check "$(cmp -s "${T}/dl/v2.tar.gz" "${T}/v2.tar.gz" && echo same || echo differs)" same "  and the archive is whole"
check "$([[ -e "${T}/dl/v2.tar.gz.resume" ]] && echo kept || echo cleared)" cleared "  its resume data cleared"
check "$(upd fetch "${web}/again.tar.gz" "${T}/dl")" 0 "a fetch cut off resumes in the same run"
check "$(grep -c '^again.tar.gz bytes=[1-9][0-9]*-$' "${T}/web/.ranges")" 1 "  from where it stopped"
check "$(upd fetch "${web}/changed.tar.gz" "${T}/dl")" 1 "a fetched archive the key didn't sign fails"
check "$(upd fetch "${web}/missing.tar.gz" "${T}/dl")" 1 "a missing one fails"
fi
echo "${fails} failed"
[[ "${fails}" -eq 0 ]]
