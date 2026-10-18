/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Guest-only checks for Finch's versioned kernel request interface. */
#include <errno.h>
#include <grp.h>
#include <mach/mach.h>
#include <pwd.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <security/mac.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>
#include "../../kernel/include/finch_sandbox_abi.h"

_Static_assert(sizeof(struct finch_sandbox_apply_request) == 32, "apply layout");
_Static_assert(sizeof(struct finch_sandbox_check_request) == 48, "check layout");
_Static_assert(offsetof(struct finch_sandbox_check_request, result) == 40, "result layout");

static audit_token_t
self_token(void)
{
    audit_token_t token = {{0}};
    mach_msg_type_number_t count = TASK_AUDIT_TOKEN_COUNT;
    if (task_info(mach_task_self(), TASK_AUDIT_TOKEN,
        (task_info_t)&token, &count) != KERN_SUCCESS ||
        count != TASK_AUDIT_TOKEN_COUNT) {
        fputs("cannot read own kernel identity\n", stderr);
        exit(1);
    }
    return token;
}

static struct finch_sandbox_check_request
request_for(audit_token_t token, uint32_t operation)
{
    return (struct finch_sandbox_check_request){
        .version = FINCH_SANDBOX_ABI_VERSION,
        .size = sizeof(struct finch_sandbox_check_request),
        .target_pid = (int32_t)token.val[5],
        .target_pidversion = token.val[7], .operation = operation,
        .result = UINT32_MAX,
    };
}

static int
check(audit_token_t token, uint32_t operation, uint32_t expected)
{
    struct finch_sandbox_check_request req = request_for(token, operation);
    if (__mac_syscall(FINCH_SANDBOX_POLICY, FINCH_SANDBOX_CALL_CHECK, &req) != 0 ||
        req.result != expected) {
        fprintf(stderr, "check %u: result %u, expected %u, errno %d\n",
            operation, req.result, expected, errno);
        return 1;
    }
    return 0;
}

static int
expect_error(int call, void *request, int expected)
{
    errno = 0;
    int result = __mac_syscall(FINCH_SANDBOX_POLICY, call, request);
    if (result != -1 || errno != expected) {
        fprintf(stderr, "call %d: result %d errno %d, expected %d\n",
            call, result, errno, expected);
        return 1;
    }
    return 0;
}

static int
apply(uint32_t profile)
{
    struct finch_sandbox_apply_request req = {
        .version = FINCH_SANDBOX_ABI_VERSION, .size = sizeof(req), .profile = profile,
    };
    return __mac_syscall(FINCH_SANDBOX_POLICY, FINCH_SANDBOX_CALL_APPLY, &req);
}

static int
malformed_requests(audit_token_t token)
{
    struct finch_sandbox_apply_request good = {
        .version = FINCH_SANDBOX_ABI_VERSION, .size = sizeof(good),
        .profile = FINCH_SANDBOX_PROFILE_DENY_WRITE,
    }, bad;
    int failed = 0;
#define BAD_APPLY(field, value, error) do { bad = good; bad.field = value; \
    failed |= expect_error(FINCH_SANDBOX_CALL_APPLY, &bad, error); } while (0)
    BAD_APPLY(version, 0, EINVAL);
    BAD_APPLY(size, sizeof(good) - 1, EINVAL);
    BAD_APPLY(size, sizeof(good) + 1, EINVAL);
    BAD_APPLY(flags, 1, EINVAL);
    BAD_APPLY(reserved[0], 1, EINVAL);
    BAD_APPLY(reserved[1], 1, EINVAL);
    BAD_APPLY(profile, 0, EINVAL);
    BAD_APPLY(profile, UINT32_MAX, EINVAL);
    BAD_APPLY(profile, FINCH_SANDBOX_PROFILE_NOTIFYD, ENOTSUP);
#undef BAD_APPLY
    failed |= expect_error(FINCH_SANDBOX_CALL_APPLY, (void *)(uintptr_t)1, EFAULT);
    failed |= check(token, FINCH_SANDBOX_OP_STATUS, 0);
    struct finch_sandbox_check_request query = request_for(token, FINCH_SANDBOX_OP_STATUS), invalid;
#define BAD_CHECK(field, value, error) do { invalid = query; invalid.field = value; \
    failed |= expect_error(FINCH_SANDBOX_CALL_CHECK, &invalid, error); } while (0)
    BAD_CHECK(version, 0, EINVAL);
    BAD_CHECK(size, sizeof(query) + 1, EINVAL);
    BAD_CHECK(size, sizeof(query) - 1, EINVAL);
    BAD_CHECK(flags, 1, EINVAL);
    BAD_CHECK(reserved[0], 1, EINVAL);
    BAD_CHECK(reserved[1], 1, EINVAL);
    BAD_CHECK(result_reserved, 1, EINVAL);
    BAD_CHECK(operation, UINT32_MAX, EINVAL);
    BAD_CHECK(target_pidversion, token.val[7] ^ 0x80000000u, ESRCH);
#undef BAD_CHECK
    failed |= expect_error(FINCH_SANDBOX_CALL_CHECK, (void *)(uintptr_t)1, EFAULT);
    size_t page_size = (size_t)getpagesize();
    void *page = mmap(NULL, page_size, PROT_READ | PROT_WRITE,
        MAP_PRIVATE | MAP_ANON, -1, 0);
    if (page == MAP_FAILED) return 1;
    memcpy(page, &query, sizeof(query));
    if (mprotect(page, page_size, PROT_READ) != 0) {
        munmap(page, page_size);
        return 1;
    }
    failed |= expect_error(FINCH_SANDBOX_CALL_CHECK, page, EFAULT);
    if (munmap(page, page_size) != 0) failed = 1;
    return failed;
}

static int
wait_ok(pid_t child)
{
    int status = 0;
    while (waitpid(child, &status, 0) < 0) {
        if (errno == EINTR) continue;
        return 1;
    }
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        fprintf(stderr, "child failed (wait status %d)\n", status);
        return 1;
    }
    return 0;
}

static int
restricted_child(uint32_t profile, int report, int resume, const char *program)
{
    alarm(20);
    if (apply(profile) != 0) return 1;
    audit_token_t token = self_token();
    if (write(report, &token, sizeof(token)) != sizeof(token)) return 1;
    char byte;
    if (read(resume, &byte, 1) != 1) return 1;
    close(report);
    close(resume);
    if (check(token, FINCH_SANDBOX_OP_STATUS, profile) ||
        check(token, FINCH_SANDBOX_OP_READ_DATA, profile == FINCH_SANDBOX_PROFILE_DENY_READ) ||
        check(token, FINCH_SANDBOX_OP_WRITE_DATA, profile == FINCH_SANDBOX_PROFILE_DENY_WRITE)) return 1;
    errno = 0;
    if (apply(profile) != -1 || errno != EPERM) return 1;
    pid_t child = fork();
    if (child < 0) return 1;
    if (child == 0) {
        _exit(check(self_token(), FINCH_SANDBOX_OP_STATUS, profile));
    }
    if (wait_ok(child)) return 1;

    /* A read-denied process may be blocked from loading the next image. */
    child = fork();
    if (child < 0) return 1;
    if (child == 0) {
        char profile_text[16];
        (void)snprintf(profile_text, sizeof(profile_text), "%u", profile);
        execlp(program, program, "--after-exec", profile_text, (char *)NULL);
        if (profile == FINCH_SANDBOX_PROFILE_DENY_READ &&
            (errno == EACCES || errno == EPERM)) {
            _exit(0);
        }
        perror("exec restricted child");
        _exit(1);
    }
    return wait_ok(child);
}

int
main(int argc, char **argv)
{
    alarm(60);
    signal(SIGPIPE, SIG_IGN);
    if (argc == 3 && !strcmp(argv[1], "--after-exec")) {
        uint32_t profile;
        if (!strcmp(argv[2], "1")) profile = FINCH_SANDBOX_PROFILE_DENY_READ;
        else if (!strcmp(argv[2], "2")) profile = FINCH_SANDBOX_PROFILE_DENY_WRITE;
        else return 1;
        return check(self_token(), FINCH_SANDBOX_OP_STATUS, profile);
    }
    if (argc != 1 || geteuid() != 0) {
        fputs("run this check as root inside the Finch guest\n", stderr);
        return 1;
    }
    audit_token_t root = self_token();
    if (malformed_requests(root)) return 1;
    struct passwd *user = getpwnam("finchtest");
    if (!user || user->pw_uid == 0) return 1;
    uid_t uid = user->pw_uid;
    gid_t gid = user->pw_gid;
    pid_t ordinary = fork();
    if (ordinary < 0) return 1;
    if (ordinary == 0) {
        alarm(15);
        if (setgroups(0, NULL) || setgid(gid) || setuid(uid)) _exit(1);
        struct finch_sandbox_check_request req = request_for(root, FINCH_SANDBOX_OP_STATUS);
        _exit(expect_error(FINCH_SANDBOX_CALL_CHECK, &req, EPERM) |
            check(self_token(), FINCH_SANDBOX_OP_STATUS, 0));
    }
    if (wait_ok(ordinary)) return 1;
    for (uint32_t profile = 1; profile <= 2; ++profile) {
        int report[2], resume[2];
        if (pipe(report) || pipe(resume)) return 1;
        pid_t child = fork();
        if (child < 0) return 1;
        if (child == 0) {
            close(report[0]); close(resume[1]);
            _exit(restricted_child(profile, report[1], resume[0], argv[0]));
        }
        close(report[1]); close(resume[0]);
        audit_token_t target;
        int failed = read(report[0], &target, sizeof(target)) != sizeof(target);
        if (!failed) failed = check(target, FINCH_SANDBOX_OP_STATUS, profile) |
            check(target, FINCH_SANDBOX_OP_READ_DATA, profile == FINCH_SANDBOX_PROFILE_DENY_READ) |
            check(target, FINCH_SANDBOX_OP_WRITE_DATA, profile == FINCH_SANDBOX_PROFILE_DENY_WRITE);
        if (write(resume[1], "x", 1) != 1) failed = 1;
        close(report[0]); close(resume[1]);
        failed |= wait_ok(child);
        if (failed) return 1;
        struct finch_sandbox_check_request req = request_for(target, FINCH_SANDBOX_OP_STATUS);
        if (expect_error(FINCH_SANDBOX_CALL_CHECK, &req, ESRCH)) return 1;
    }
    if (check(root, FINCH_SANDBOX_OP_STATUS, 0)) return 1;
    puts("Finch sandbox request checks passed");
    return 0;
}
