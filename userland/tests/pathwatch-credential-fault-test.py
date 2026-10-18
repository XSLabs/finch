#!/usr/bin/env python3
"""Fault-test patched pathwatch credential handling on a private source copy.

Run from any directory with:
    python3 userland/tests/pathwatch-credential-fault-test.py
    python3 userland/tests/pathwatch-credential-fault-test.py --source PATH

The test applies the Finch patch to a temporary source copy. If it is already
applied, it first reverse-checks the exact patch, then reapplies it. It extracts
the real helpers and _path_stat function, then compiles them with fault
injection for each credential and cleanup operation.
"""
from pathlib import Path
import argparse
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SOURCE = ROOT / 'build/src/Libnotify/notifyd/pathwatch.c'
PATCH = ROOT / 'userland/patches/Libnotify/0002-pathwatch-credential-fail-closed.patch'

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=Path, default=DEFAULT_SOURCE,
                    help='vendor pathwatch.c source; defaults to build/src')
SOURCE = parser.parse_args().source

with tempfile.TemporaryDirectory(prefix='pathwatch-credential-test-') as work:
    work_path = Path(work)
    target = work_path / 'notifyd/pathwatch.c'
    target.parent.mkdir(parents=True)
    source = SOURCE.read_text()
    target.write_text(source)

    def apply_patch_series(patch_files, reverse=False):
        for patch_file in patch_files:
            patch_text = patch_file.read_text()
            patch_args = ['git', '-C', str(work_path), 'apply']
            if reverse:
                patch_args.append('--reverse')
            dry_run = subprocess.run(
                patch_args + ['--check'], input=patch_text, text=True,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            )
            if dry_run.returncode != 0:
                raise RuntimeError(f'{patch_file} did not match this source:\n{dry_run.stdout}')
            subprocess.run(
                patch_args, input=patch_text, text=True,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=True,
            )

    patch_files = (PATCH,)
    try:
        apply_patch_series(patch_files)
    except RuntimeError as forward_error:
        target.write_text(source)
        try:
            apply_patch_series(reversed(patch_files), reverse=True)
        except RuntimeError as reverse_error:
            raise RuntimeError(
                'Source is neither clean nor has the exact patch; refusing to test a partial or unknown version.\n'
                f'forward check: {forward_error}\nreverse check: {reverse_error}'
            ) from reverse_error
        apply_patch_series(patch_files)
    source = target.read_text()
    tz_start = source.index('static bool\n_path_is_in_tzdir')
    tz_end = source.index('\nstatic int\n_path_stat_status_for_errno', tz_start)
    tz_helper = source[tz_start:tz_end]
    start = source.index('static int\n_path_stat_status_for_errno')
    end = source.index('\n/*\n * Check access to a path', start)
    actual = source[start:end]

    prefix = r'''#include <sys/types.h>
    #include <sys/stat.h>
    #include <errno.h>
    #include <pwd.h>
    #include <stdint.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
#include <strings.h>
#include <stdbool.h>
    #include <setjmp.h>
    #define TARGET_OS_IPHONE 0
    #define NGROUPS_MAX 16
    #define PATH_STAT_OK 0
    #define PATH_STAT_FAILED 1
    #define PATH_STAT_ACCESS 2
    #define PATH_STAT_MISSING 3
    #define PATH_STAT_CREDENTIAL 4
    #define KAUTH_UID_NONE ((uid_t)-1)
    #define KAUTH_GID_NONE ((gid_t)-1)
    #define SYS_initgroups 243
    static uint32_t gL1CacheEnabled;
    static int fail_getgroups, fail_getpwuid, fail_initgroups;
    static int fail_set_identity, fail_reset_identity, fail_restore_groups;
    static int stat_result, stat_error, stat_calls, identity_active;
    static int set_identity_calls, reset_identity_calls, initgroups_calls, restore_group_calls;
    static int crash_count;
    static jmp_buf crash_env;
    static struct passwd test_passwd;
    static char test_name[] = "client";
static struct { char *tzdir; size_t tzdir_len; } _global;
    static int test_getgroups(int size, gid_t *groups);
    static struct passwd *test_getpwuid(uid_t uid);
    static int test_initgroups(const char *name, int gid);
    static int test_pthread_setugid_np(uid_t uid, gid_t gid);
    static int test_stat(const char *path, struct stat *sb);
    static int test_lstat(const char *path, struct stat *sb);
    static long test_syscall(long number, ...);
    _Noreturn static void test_crash(int cause, const char *message);
    #define getgroups test_getgroups
    #define getpwuid test_getpwuid
    #define initgroups test_initgroups
    #define pthread_setugid_np test_pthread_setugid_np
    #define stat(path, sb) test_stat((path), (sb))
    #define lstat(path, sb) test_lstat((path), (sb))
    #define syscall test_syscall
    #define NOTIFY_INTERNAL_CRASH(c, m) test_crash((c), (m))

    static int test_getgroups(int size, gid_t *groups) {
        if (fail_getgroups) { errno = EIO; return -1; }
        if (size < 2) { errno = EINVAL; return -1; }
        groups[0] = 10; groups[1] = 20; return 2;
    }
    static struct passwd *test_getpwuid(uid_t uid) {
        (void)uid;
        if (fail_getpwuid) { errno = EIO; return NULL; }
        test_passwd.pw_name = test_name; return &test_passwd;
    }
    static int test_initgroups(const char *name, int gid) {
        (void)name; (void)gid; initgroups_calls++;
        if (fail_initgroups) { errno = EPERM; return -1; }
        return 0;
    }
    static int test_pthread_setugid_np(uid_t uid, gid_t gid) {
        (void)gid;
        if (uid == KAUTH_UID_NONE) {
            reset_identity_calls++;
            if (fail_reset_identity) { errno = EPERM; return -1; }
            identity_active = 0; errno = EBUSY; return 0;
        }
        set_identity_calls++;
        if (fail_set_identity) { errno = EPERM; return -1; }
        identity_active = 1; return 0;
    }
    static int test_stat(const char *path, struct stat *sb) {
        (void)path; (void)sb; stat_calls++;
        if (!identity_active) { fprintf(stderr, "stat ran without client credentials\n"); abort(); }
        if (stat_result < 0) errno = stat_error;
        return stat_result;
    }
    static int test_lstat(const char *path, struct stat *sb) { return test_stat(path, sb); }
    static long test_syscall(long number, ...) {
        (void)number; restore_group_calls++;
        if (fail_restore_groups) { errno = EPERM; return -1; }
        errno = EBUSY; return 0;
    }
    _Noreturn static void test_crash(int cause, const char *message) {
        (void)cause; (void)message; crash_count++; longjmp(crash_env, 1);
    }
    '''

    suffix = r'''
    static void reset_test(void) {
        fail_getgroups = fail_getpwuid = fail_initgroups = 0;
        fail_set_identity = fail_reset_identity = fail_restore_groups = 0;
        stat_result = 0; stat_error = 0; stat_calls = 0; identity_active = 0;
        set_identity_calls = reset_identity_calls = initgroups_calls = restore_group_calls = 0;
        crash_count = 0; gL1CacheEnabled = 1;
    }
    #define CHECK(c, msg) do { if (!(c)) { fprintf(stderr, "FAIL: %s\n", msg); return 1; } } while (0)
    int main(void) {
        int result;
        reset_test();
        result = _path_stat("/client/file", 0, 501, 20);
        CHECK(result == PATH_STAT_OK, "successful stat should be allowed");
        CHECK(stat_calls == 1 && set_identity_calls == 1 && reset_identity_calls == 1, "success must stat between credential switch and reset");
        CHECK(restore_group_calls == 1 && gL1CacheEnabled == 1, "success must restore groups and cache");

        reset_test(); fail_getgroups = 1;
        result = _path_stat("/client/file", 0, 501, 20);
        CHECK(result == PATH_STAT_CREDENTIAL && stat_calls == 0, "getgroups failure must deny without stat");
        CHECK(gL1CacheEnabled == 1, "getgroups failure must restore cache");

        reset_test(); fail_getpwuid = 1;
        result = _path_stat("/client/file", 0, 501, 20);
        CHECK(result == PATH_STAT_CREDENTIAL && stat_calls == 0 && gL1CacheEnabled == 1, "passwd lookup failure must deny and restore cache");

        reset_test(); fail_initgroups = 1;
        result = _path_stat("/client/file", 0, 501, 20);
        CHECK(result == PATH_STAT_CREDENTIAL && stat_calls == 0 && gL1CacheEnabled == 1 && restore_group_calls == 0, "group lookup failure must deny without stat or restore unchanged groups");

        reset_test(); fail_set_identity = 1;
        result = _path_stat("/client/file", 0, 501, 20);
        CHECK(result == PATH_STAT_CREDENTIAL && stat_calls == 0, "credential switch failure must not stat");
        CHECK(reset_identity_calls == 0 && restore_group_calls == 1, "failed switch must restore groups without resetting an identity that was never set");

        reset_test(); stat_result = -1; stat_error = EACCES;
        result = _path_stat("/client/file", 0, 501, 20);
        CHECK(result == PATH_STAT_ACCESS && restore_group_calls == 1, "permission errors must remain access failures");
        reset_test(); stat_result = -1; stat_error = ENOENT;
        result = _path_stat("/client/file", 0, 501, 20);
        CHECK(result == PATH_STAT_MISSING, "missing files must have a separate status");
        reset_test(); stat_result = -1; stat_error = EIO;
        result = _path_stat("/client/file", 0, 501, 20);
        CHECK(result == PATH_STAT_FAILED, "other stat errors must remain failures");

        reset_test(); fail_set_identity = 1; fail_restore_groups = 1;
        if (setjmp(crash_env) == 0) (void)_path_stat("/client/file", 0, 501, 20);
        CHECK(crash_count == 1 && stat_calls == 0, "failed credential setup must fail-stop if group restoration fails");
        reset_test(); fail_reset_identity = 1;
        if (setjmp(crash_env) == 0) (void)_path_stat("/client/file", 0, 501, 20);
        CHECK(crash_count == 1 && restore_group_calls == 0, "thread credential reset failure must fail-stop before more work");
        reset_test(); fail_restore_groups = 1;
        if (setjmp(crash_env) == 0) (void)_path_stat("/client/file", 0, 501, 20);
        CHECK(crash_count == 1, "group restoration failure must fail-stop");

        CHECK(_path_stat_status_for_errno(ENOENT) == PATH_STAT_MISSING, "ENOENT mapping");
        CHECK(_path_stat_status_for_errno(ENOTDIR) == PATH_STAT_MISSING, "ENOTDIR mapping");
        CHECK(_path_stat_status_for_errno(EPERM) == PATH_STAT_ACCESS, "EPERM mapping");
        CHECK(_path_stat_status_for_errno(EIO) == PATH_STAT_FAILED, "transient mapping");
        char tzdir[] = "/private/var/db/timezone/zoneinfo";
        _global.tzdir = tzdir;
        _global.tzdir_len = strlen(tzdir);
        CHECK(_path_is_in_tzdir(tzdir), "exact timezone directory must match");
        CHECK(_path_is_in_tzdir("/private/var/db/timezone/zoneinfo/UTC"), "timezone descendant must match");
        CHECK(!_path_is_in_tzdir("/private/var/db/timezone/zoneinfo-private/secret"), "sibling prefix must not match");
        CHECK(!_path_is_in_tzdir("/private/var/db/timezone/zone"), "shorter prefix must not match");
        CHECK(_path_is_in_tzdir("/PRIVATE/VAR/DB/TIMEZONE/ZONEINFO/UTC"), "timezone matching must preserve case-insensitive behavior");
        puts("pathwatch credential and timezone fault tests passed");
        return 0;
    }
    '''

    out = Path(work) / 'pathwatch-fault-test.c'
    out.write_text(prefix + '\n' + tz_helper + '\n' + actual + '\n' + suffix)
    binary = Path(work) / 'pathwatch-fault-test'
    subprocess.run(['clang', '-std=c11', '-Wall', '-Wextra', '-Werror', str(out), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
