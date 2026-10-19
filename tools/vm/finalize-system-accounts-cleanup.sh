# SPDX-License-Identifier: MIT OR Apache-2.0
# Cleanup for finalize-system-accounts.sh. Kept separate so failure recovery can
# be checked with plain temporary files, without attaching a disk image.

finalize_cleanup_find_device() {
    mounted_device
}

finalize_cleanup_detach() {
    /usr/bin/hdiutil detach "$1" >/dev/null
}

finalize_cleanup_restore() {
    /bin/mv -f "$1" "$2"
}

finalize_cleanup_remove_tree() {
    /bin/rm -rf "$1"
}

finalize_cleanup_remove_empty_dir() {
    /bin/rmdir "$1"
}

finch_finalize_cleanup() {
    local status="$1"
    local stage_dir="$2"
    local stage="$3"
    local mount="$4"
    local image="$5"
    local backup="$6"
    local mounted="$7"
    local replaced="$8"
    local committed="$9"
    local PRESERVE_STAGE="${10}"
    local device=""
    local device_status=0

    set +e
    if [[ "$mounted" == 1 ]]; then
        device="$(finalize_cleanup_find_device "$stage" "$mount")"
        device_status=$?
        if [[ "$device_status" == 0 && -n "$device" ]]; then
            if finalize_cleanup_detach "$device"; then
                device="$(finalize_cleanup_find_device "$stage" "$mount")"
                device_status=$?
                if [[ "$device_status" == 1 ]]; then
                    mounted=0
                else
                    echo "finalize-system-accounts: could not confirm that the staging image detached" >&2
                    PRESERVE_STAGE=1
                fi
            else
                echo "finalize-system-accounts: could not detach the staging image; it is left at $stage" >&2
                PRESERVE_STAGE=1
            fi
        elif [[ "$device_status" == 1 ]]; then
            mounted=0
        else
            echo "finalize-system-accounts: could not check the staging mount; it is left at $stage" >&2
            PRESERVE_STAGE=1
        fi
    fi
    if [[ "$replaced" == 1 && "$committed" == 0 ]]; then
        if [[ -n "$backup" && -f "$backup" ]]; then
            if finalize_cleanup_restore "$backup" "$image"; then
                replaced=0
                echo "finalize-system-accounts: restored the original ramdisk after a failed check" >&2
            else
                echo "finalize-system-accounts: could not restore the original; backup remains at $backup" >&2
                status=1
                PRESERVE_STAGE=1
            fi
        else
            echo "finalize-system-accounts: original image backup is missing; inspect $image and $stage_dir" >&2
            status=1
            PRESERVE_STAGE=1
        fi
    fi

    if [[ "$PRESERVE_STAGE" == 1 || "$mounted" == 1 ]]; then
        echo "finalize-system-accounts: staging files were kept for recovery in $stage_dir" >&2
    elif [[ "$committed" == 1 && -n "$stage_dir" && -d "$stage_dir" ]]; then
        if [[ -n "$mount" && -d "$mount" ]] &&
            ! finalize_cleanup_remove_empty_dir "$mount"; then
            echo "finalize-system-accounts: staging mount directory is not empty; it was kept at $mount" >&2
        elif ! finalize_cleanup_remove_empty_dir "$stage_dir"; then
            echo "finalize-system-accounts: could not remove the empty staging directory $stage_dir" >&2
        fi
    elif [[ -n "$stage_dir" && -d "$stage_dir" ]]; then
        finalize_cleanup_remove_tree "$stage_dir"
    fi
    exit "$status"
}
