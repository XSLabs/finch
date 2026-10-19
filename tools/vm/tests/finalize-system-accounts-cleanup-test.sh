#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Exercise finalizer recovery with temporary files and mocked disk actions.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${SCRIPT_DIR}/finalize-system-accounts-cleanup.sh"

ROOT="$(/usr/bin/mktemp -d /private/tmp/finch-finalizer-cleanup-test.XXXXXX)"
trap '/bin/rm -rf "$ROOT"' EXIT
checks=0
failures=0

check() {
    local condition="$1"
    local message="$2"
    checks=$((checks + 1))
    if [[ "$condition" != 1 ]]; then
        failures=$((failures + 1))
        echo "FAIL: $message" >&2
    fi
}

file_has() {
    [[ -f "$1" ]] && [[ "$(/bin/cat "$1")" == "$2" ]]
}

make_case() {
    CASE_DIR="${ROOT}/$1"
    STAGE_DIR="${CASE_DIR}/stage"
    STAGE="${STAGE_DIR}/ramdisk.dmg"
    MOUNT="${STAGE_DIR}/mount"
    IMAGE="${CASE_DIR}/ramdisk.dmg"
    BACKUP="${STAGE_DIR}/original-ramdisk.dmg"
    /bin/mkdir -p "$MOUNT"
    /usr/bin/printf 'new image\n' >"$IMAGE"
    /usr/bin/printf 'staged image\n' >"$STAGE"
    /usr/bin/printf 'old image\n' >"$BACKUP"
}

# These hooks keep the tests away from hdiutil and real VM images.
finalize_cleanup_find_device() {
    case "${MOCK_MOUNT_STATE:-none}" in
        attached) /usr/bin/printf '/dev/mock-disk\n'; return 0 ;;
        unknown) return 2 ;;
        none) return 1 ;;
        *) return 2 ;;
    esac
}

finalize_cleanup_detach() {
    return "${MOCK_DETACH_STATUS:-0}"
}

finalize_cleanup_restore() {
    [[ "${MOCK_RESTORE_FAIL:-0}" == 1 ]] && return 1
    /bin/mv -f "$1" "$2"
}

finalize_cleanup_remove_empty_dir() {
    /usr/bin/printf '%s\n' "$1" >>"$CLEANUP_LOG"
    /bin/rmdir "$1"
}

finalize_cleanup_remove_tree() {
    /bin/rm -rf "$1"
}

# A failed restore must keep the only backup copy and its staging directory.
make_case restore-fail
CLEANUP_LOG="${ROOT}/restore-fail.log"
if (MOCK_MOUNT_STATE=none MOCK_RESTORE_FAIL=1 \
    finch_finalize_cleanup 1 "$STAGE_DIR" "$STAGE" "$MOUNT" "$IMAGE" \
        "$BACKUP" 0 1 0 0 >/dev/null 2>&1); then
    status=0
else
    status=$?
fi
check "$([[ $status -eq 1 ]] && echo 1 || echo 0)" "failed restore keeps failure status"
check "$(file_has "$IMAGE" 'new image' && echo 1 || echo 0)" "failed restore leaves the current image untouched"
check "$(file_has "$BACKUP" 'old image' && echo 1 || echo 0)" "failed restore keeps the backup"
check "$( [[ -d "$STAGE_DIR" ]] && echo 1 || echo 0 )" "failed restore keeps the staging directory"

# A good restore brings the old image back, then removes the now-unneeded stage.
make_case restore-ok
CLEANUP_LOG="${ROOT}/restore-ok.log"
if (MOCK_MOUNT_STATE=none MOCK_RESTORE_FAIL=0 \
    finch_finalize_cleanup 1 "$STAGE_DIR" "$STAGE" "$MOUNT" "$IMAGE" \
        "$BACKUP" 0 1 0 0 >/dev/null 2>&1); then
    status=0
else
    status=$?
fi
check "$([[ $status -eq 1 ]] && echo 1 || echo 0)" "successful restore keeps the original failure status"
check "$(file_has "$IMAGE" 'old image' && echo 1 || echo 0)" "successful restore puts the old image back"
check "$( [[ ! -e "$STAGE_DIR" ]] && echo 1 || echo 0 )" "successful restore removes the staging directory"

# If disk status cannot be read, preserve all recovery files.
make_case mount-unknown
CLEANUP_LOG="${ROOT}/mount-unknown.log"
if (MOCK_MOUNT_STATE=unknown \
    finch_finalize_cleanup 1 "$STAGE_DIR" "$STAGE" "$MOUNT" "$IMAGE" \
        "$BACKUP" 1 0 0 0 >/dev/null 2>&1); then
    status=0
else
    status=$?
fi
check "$([[ $status -eq 1 ]] && echo 1 || echo 0)" "unknown mount keeps failure status"
check "$( [[ -d "$STAGE_DIR" ]] && echo 1 || echo 0 )" "unknown mount keeps the staging directory"
check "$(file_has "$BACKUP" 'old image' && echo 1 || echo 0)" "unknown mount keeps the backup"

# If rollback was requested but its backup is gone, retain the stage for review.
make_case missing-backup
/bin/rm -f "$BACKUP"
CLEANUP_LOG="${ROOT}/missing-backup.log"
if (MOCK_MOUNT_STATE=none \
    finch_finalize_cleanup 1 "$STAGE_DIR" "$STAGE" "$MOUNT" "$IMAGE" \
        "$BACKUP" 0 1 0 0 >/dev/null 2>&1); then
    status=0
else
    status=$?
fi
check "$([[ $status -eq 1 ]] && echo 1 || echo 0)" "missing backup keeps failure status"
check "$( [[ -d "$STAGE_DIR" ]] && echo 1 || echo 0 )" "missing backup keeps the staging directory"

# A verified commit removes the empty mount directory before its parent.
make_case committed
/bin/rm -f "$BACKUP" "$STAGE"
CLEANUP_LOG="${ROOT}/committed.log"
: >"$CLEANUP_LOG"
if (MOCK_MOUNT_STATE=none \
    finch_finalize_cleanup 0 "$STAGE_DIR" "$STAGE" "$MOUNT" "$IMAGE" \
        "$BACKUP" 0 0 1 0 >/dev/null 2>&1); then
    status=0
else
    status=$?
fi
check "$([[ $status -eq 0 ]] && echo 1 || echo 0)" "committed cleanup succeeds"
check "$( [[ ! -e "$STAGE_DIR" ]] && echo 1 || echo 0 )" "committed cleanup removes its empty staging directory"
first="$(/usr/bin/sed -n '1p' "$CLEANUP_LOG")"
second="$(/usr/bin/sed -n '2p' "$CLEANUP_LOG")"
check "$( [[ "$first" == "$MOUNT" && "$second" == "$STAGE_DIR" ]] && echo 1 || echo 0 )" \
    "committed cleanup removes the empty mount before the staging directory"

if [[ "$failures" -ne 0 ]]; then
    echo "finalizer cleanup: ${checks} checks, ${failures} failures" >&2
    exit 1
fi
echo "finalizer cleanup: ${checks} checks passed"
