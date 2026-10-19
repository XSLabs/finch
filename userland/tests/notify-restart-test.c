/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Guest-only: kill the verified Finch notifyd and check existing registrations. */
#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <mach/mach.h>
#include <notify.h>
#include <security/mac.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include "../../kernel/include/finch_sandbox_abi.h"

/* Private libnotify helper used to verify the carried shared-memory counter. */
extern uint32_t notify_peek(int token, uint32_t *value);

static atomic_uint deliveries;

static int
require_finch_kernel(void)
{
    audit_token_t token = {{0}};
    mach_msg_type_number_t count = TASK_AUDIT_TOKEN_COUNT;
    if (task_info(mach_task_self(), TASK_AUDIT_TOKEN,
        (task_info_t)&token, &count) != KERN_SUCCESS ||
        count != TASK_AUDIT_TOKEN_COUNT) return -1;
    struct finch_sandbox_check_request request = {
        .version = FINCH_SANDBOX_ABI_VERSION, .size = sizeof(request),
        .target_pid = (int32_t)token.val[5], .target_pidversion = token.val[7],
        .operation = FINCH_SANDBOX_OP_STATUS, .result = UINT32_MAX,
    };
    return __mac_syscall(FINCH_SANDBOX_POLICY, FINCH_SANDBOX_CALL_CHECK,
        &request) == 0 && request.result == 0 ? 0 : -1;
}

static void
pause_briefly(void)
{
    struct timespec delay = {.tv_sec = 0, .tv_nsec = 20 * 1000 * 1000};
    while (nanosleep(&delay, &delay) < 0 && errno == EINTR) {}
}

static int
wait_for_delivery(unsigned before)
{
    for (unsigned attempt = 0; attempt < 250; attempt++) {
        if (atomic_load(&deliveries) > before) return 0;
        pause_briefly();
    }
    fputs("notification delivery timed out\n", stderr);
    return -1;
}

int
main(void)
{
    int result = 1, check_token = NOTIFY_TOKEN_INVALID;
    int quiet_token = NOTIFY_TOKEN_INVALID;
    int dispatch_token = NOTIFY_TOKEN_INVALID, fd = -1, changed = 0;
    uint32_t *shared = MAP_FAILED;
    size_t map_size = sizeof(uint32_t);
    dispatch_queue_t queue = NULL;
    struct stat info;
    char name[160], quiet_name[192], process_path[PROC_PIDPATHINFO_MAXSIZE];
    const uint64_t wanted_state = UINT64_C(0x46696e6368525354);
    uint64_t state = 0;
    uint32_t pending_value_before = 0, pending_value = 0, restored_value = 0;
    alarm(40);
    if (geteuid() != 0 || require_finch_kernel() != 0) {
        fputs("requires root in a Finch guest with the Finch kernel policy\n", stderr);
        return 1;
    }
    snprintf(name, sizeof(name), "user.uid.0.org.finch.restart.%d.%08x",
        getpid(), arc4random());
    if (snprintf(quiet_name, sizeof(quiet_name), "%s.quiet", name) >= (int)sizeof(quiet_name)) {
        fputs("could not build quiet check name\n", stderr);
        goto done;
    }
    atomic_init(&deliveries, 0);
    queue = dispatch_queue_create("org.finch.test.notify-restart", DISPATCH_QUEUE_SERIAL);
    if (queue == NULL || notify_register_check(name, &check_token) != NOTIFY_STATUS_OK ||
        notify_register_dispatch(name, &dispatch_token, queue, ^(int token) {
            (void)token;
            atomic_fetch_add(&deliveries, 1);
        }) != NOTIFY_STATUS_OK) {
        fputs("could not register notification clients\n", stderr);
        goto done;
    }
    if (notify_register_check(quiet_name, &quiet_token) != NOTIFY_STATUS_OK ||
        notify_check(quiet_token, &changed) != NOTIFY_STATUS_OK || changed != 1 ||
        notify_check(quiet_token, &changed) != NOTIFY_STATUS_OK || changed != 0) {
        fputs("could not clear the quiet check token's initial change\n", stderr);
        goto done;
    }
    if (notify_check(check_token, &changed) != NOTIFY_STATUS_OK ||
        notify_set_state(check_token, wanted_state) != NOTIFY_STATUS_OK ||
        notify_get_state(check_token, &state) != NOTIFY_STATUS_OK || state != wanted_state ||
        notify_post(name) != NOTIFY_STATUS_OK || wait_for_delivery(0) != 0 ||
        notify_check(check_token, &changed) != NOTIFY_STATUS_OK || changed != 1) {
        fputs("notification checks failed before restart\n", stderr);
        goto done;
    }
    /* Leave this second check notification pending while notifyd restarts. */
    if (notify_peek(check_token, &pending_value_before) != NOTIFY_STATUS_OK ||
        pending_value_before == UINT32_MAX) {
        fputs("could not read the check counter before the pending post\n", stderr);
        goto done;
    }
    unsigned before_pending = atomic_load(&deliveries);
    if (notify_post(name) != NOTIFY_STATUS_OK || wait_for_delivery(before_pending) != 0 ||
        notify_get_state(check_token, &state) != NOTIFY_STATUS_OK || state != wanted_state ||
        notify_peek(check_token, &pending_value) != NOTIFY_STATUS_OK ||
        pending_value != pending_value_before + 1) {
        fputs("could not prepare a pending notification for restart\n", stderr);
        goto done;
    }
    fd = shm_open("apple.shm.notification_center", O_RDONLY, 0);
    if (fd < 0 || fstat(fd, &info) != 0 || info.st_uid != 0 ||
        (info.st_mode & 07777) != 0644 || info.st_size < (off_t)map_size) {
        fputs("cannot verify notification shared memory\n", stderr);
        goto done;
    }
    shared = mmap(NULL, map_size, PROT_READ, MAP_SHARED, fd, 0);
    if (shared == MAP_FAILED) goto done;
    pid_t old_pid = (pid_t)*(volatile uint32_t *)shared;
    memset(process_path, 0, sizeof(process_path));
    if (old_pid <= 1 || old_pid == getpid() ||
        proc_pidpath(old_pid, process_path, sizeof(process_path)) <= 0 ||
        strcmp(process_path, "/usr/sbin/notifyd") != 0) {
        fprintf(stderr, "refusing to stop unverified process %d (%s)\n", old_pid, process_path);
        goto done;
    }
    dispatch_sync(queue, ^{});
    if (kill(old_pid, SIGKILL) != 0) {
        perror("stop guest notifyd");
        goto done;
    }
    pid_t new_pid = old_pid;
    for (unsigned attempt = 0; attempt < 500; attempt++) {
        new_pid = (pid_t)*(volatile uint32_t *)shared;
        if (new_pid > 1 && new_pid != old_pid) break;
        pause_briefly();
    }
    if (new_pid <= 1 || new_pid == old_pid) {
        fputs("notifyd did not restart within ten seconds\n", stderr);
        goto done;
    }
    memset(process_path, 0, sizeof(process_path));
    if (proc_pidpath(new_pid, process_path, sizeof(process_path)) <= 0 ||
        strcmp(process_path, "/usr/sbin/notifyd") != 0) {
        fputs("replacement notifyd identity could not be verified\n", stderr);
        goto done;
    }
    /* These calls must reuse the original tokens after regeneration. */
    if (notify_get_state(check_token, &state) != NOTIFY_STATUS_OK || state != wanted_state ||
        notify_peek(check_token, &restored_value) != NOTIFY_STATUS_OK ||
        restored_value != pending_value ||
        notify_check(check_token, &changed) != NOTIFY_STATUS_OK || changed != 1 ||
        notify_check(check_token, &changed) != NOTIFY_STATUS_OK || changed != 0 ||
        notify_check(quiet_token, &changed) != NOTIFY_STATUS_OK || changed != 0) {
        fputs("saved state or the pending check notification failed after restart\n", stderr);
        goto done;
    }
    dispatch_sync(queue, ^{});
    unsigned before = atomic_load(&deliveries);
    if (notify_post(name) != NOTIFY_STATUS_OK || wait_for_delivery(before) != 0 ||
        notify_check(check_token, &changed) != NOTIFY_STATUS_OK || changed != 1) {
        fputs("existing notification clients failed after restart\n", stderr);
        goto done;
    }
    printf("notify-restart: PASS (service %d -> %d; original check and dispatch tokens and state survive)\n",
        old_pid, new_pid);
    result = 0;
done:
    if (check_token != NOTIFY_TOKEN_INVALID && notify_cancel(check_token) != NOTIFY_STATUS_OK) result = 1;
    if (quiet_token != NOTIFY_TOKEN_INVALID && notify_cancel(quiet_token) != NOTIFY_STATUS_OK) result = 1;
    if (dispatch_token != NOTIFY_TOKEN_INVALID && notify_cancel(dispatch_token) != NOTIFY_STATUS_OK) result = 1;
    if (queue != NULL) { dispatch_sync(queue, ^{}); dispatch_release(queue); }
    if (shared != MAP_FAILED) munmap(shared, map_size);
    if (fd >= 0) close(fd);
    return result;
}
