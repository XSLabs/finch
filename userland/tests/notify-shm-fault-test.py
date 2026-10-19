#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Test notifyd's real shared-memory setup function with injected failures.

Run: python3 userland/tests/notify-shm-fault-test.py
The vendor source is copied and patched in a temporary folder. No host shared
memory objects or service settings are changed.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'build/src/Libnotify/notifyd/notifyd.c'
PATCH = ROOT / 'userland/patches/Libnotify/0004-shared-memory-startup-checks.patch'

with tempfile.TemporaryDirectory(prefix='finch-notify-shm-test-') as directory:
    work = Path(directory)
    target = work / 'notifyd/notifyd.c'
    target.parent.mkdir()
    original = SOURCE.read_text()
    target.write_text(original)
    command = ['git', '-C', str(work), 'apply']
    patch = PATCH.read_text()
    forward = subprocess.run(command + ['--check'], input=patch, text=True, capture_output=True)
    if forward.returncode == 0:
        subprocess.run(command, input=patch, text=True, check=True)
    else:
        subprocess.run(command + ['--reverse', '--check'], input=patch, text=True, check=True)
    source = target.read_text()
    start = source.index('static int32_t\nopen_shared_memory(')
    end = source.index('\nint\nmain(', start)
    actual = source[start:end]
    prefix = r'''
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <stdarg.h>
#define ASL_LEVEL_NOTICE 5
#define CRSetCrashLogMessage(x) ((void)0)
static struct {
    uint32_t nslots, slot_id;
    uint32_t *shared_memory_base, *last_shm_base, *shared_memory_refcount;
} global;
static uint32_t memory[4];
static int existing, open_error, stat_error, truncate_error, map_error;
static int calloc_error, malloc_error, open_calls, truncate_calls, map_calls;
static int close_calls, unlink_calls, unmap_calls, wrong_owner, bad_mode, wrong_size, unlink_error, empty_object;
static unsigned log_calls;
static char last_log[2048];
static void log_message(int level, const char *format, ...) {
    (void)level; log_calls++;
    va_list args; va_start(args, format);
    vsnprintf(last_log, sizeof(last_log), format, args); va_end(args);
}
static int fake_shm_open(const char *name, int flags, mode_t mode) {
    (void)name;
    if (mode != 0644) abort();
    open_calls++;
    if (open_error) { errno = open_error; return -1; }
    if (existing && (flags & O_EXCL)) { errno = EEXIST; return -1; }
    return 42;
}
static int fake_fstat(int fd, struct stat *s) {
    if (fd != 42) abort();
    if (stat_error) { errno = EIO; return -1; }
    memset(s, 0, sizeof(*s));
    s->st_uid = wrong_owner ? 501 : 2;
    s->st_mode = bad_mode ? (mode_t)bad_mode : 0644;
    s->st_size = !existing || empty_object ? 0 : wrong_size ? (off_t)wrong_size : (off_t)sizeof(memory);
    return 0;
}
static int fake_ftruncate(int fd, off_t size) {
    if (fd != 42 || size != sizeof(memory)) abort();
    truncate_calls++;
    if (truncate_error) { errno = ENOSPC; return -1; }
    return 0;
}
static void *fake_mmap(void *addr, size_t size, int prot, int flags, int fd, off_t offset) {
    (void)addr;
    if (size != sizeof(memory) || prot != (PROT_READ|PROT_WRITE) || flags != MAP_SHARED || fd != 42 || offset) abort();
    map_calls++;
    if (map_error) { errno = ENOMEM; return MAP_FAILED; }
    return memory;
}
static void *fake_calloc(size_t n, size_t size) {
    if (calloc_error) { errno = ENOMEM; return NULL; }
    return calloc(n, size);
}
static void *fake_malloc(size_t size) {
    if (malloc_error) { errno = ENOMEM; return NULL; }
    return malloc(size);
}
static int fake_close(int fd) { if (fd != 42) abort(); close_calls++; errno = EBUSY; return 0; }
static int fake_unlink(const char *name) { (void)name; unlink_calls++; errno = unlink_error ? EACCES : EBUSY; return unlink_error ? -1 : 0; }
static int fake_munmap(void *addr, size_t size) {
    if (addr != memory || size != sizeof(memory)) abort();
    unmap_calls++; errno = EBUSY; return 0;
}
#define shm_open fake_shm_open
#define fstat fake_fstat
#define ftruncate fake_ftruncate
#define mmap fake_mmap
#define calloc fake_calloc
#define malloc fake_malloc
#define close fake_close
#define shm_unlink fake_unlink
#define munmap fake_munmap
#define geteuid() ((uid_t)2)
#define getpid() ((pid_t)123)
#define getpagesize() 16384
'''
    suffix = r'''
static int checks;
#define CHECK(x) do { checks++; if (!(x)) { fprintf(stderr, "failed line %d: %s\n", __LINE__, #x); exit(1); } } while (0)
static void reset(void) {
    free(global.last_shm_base);
    free(global.shared_memory_refcount);
    memset(&global, 0, sizeof(global));
    global.nslots = 4;
    for (int i = 0; i < 4; i++) memory[i] = 90 + i;
    existing = open_error = stat_error = truncate_error = map_error = 0;
    calloc_error = malloc_error = open_calls = truncate_calls = map_calls = 0;
    close_calls = unlink_calls = unmap_calls = wrong_owner = bad_mode = wrong_size = unlink_error = empty_object = 0;
    log_calls = 0; last_log[0] = '\0';
    errno = 0;
}
static void failed_unchanged(int wanted_errno, int expect_unlink) {
    CHECK(open_shared_memory("test") == -1);
    CHECK(errno == wanted_errno);
    CHECK(global.shared_memory_base == NULL);
    CHECK(global.shared_memory_refcount == NULL);
    CHECK(global.last_shm_base == NULL);
    for (int i = 0; i < 4; i++) CHECK(memory[i] == (uint32_t)(90 + i));
    CHECK(unlink_calls == expect_unlink);
}
int main(void) {
    reset(); CHECK(open_shared_memory("test") == 0);
    CHECK(open_calls == 1 && truncate_calls == 1 && close_calls == 1 && unlink_calls == 0);
    CHECK(global.shared_memory_base == memory && memory[0] == 123 && memory[1] == 0);
    CHECK(global.shared_memory_refcount[0] == 1 && global.shared_memory_refcount[1] == 0);
    CHECK(global.last_shm_base == NULL);
    reset(); existing = 1; CHECK(open_shared_memory("test") == 0);
    CHECK(open_calls == 2 && truncate_calls == 0 && close_calls == 1 && unlink_calls == 0);
    for (int i = 0; i < 4; i++) CHECK(global.last_shm_base[i] == (uint32_t)(90 + i));
    CHECK(memory[0] == 123 && memory[3] == 0);
    reset(); existing = empty_object = 1; CHECK(open_shared_memory("test") == 0);
    CHECK(open_calls == 2 && truncate_calls == 1 && unlink_calls == 0);
    CHECK(global.last_shm_base == NULL && memory[0] == 123 && memory[3] == 0);
    reset(); global.nslots = 0; failed_unchanged(EINVAL, 0); CHECK(open_calls == 0);
    reset(); global.nslots = UINT32_MAX; failed_unchanged(EINVAL, 0); CHECK(open_calls == 0);
    reset(); open_error = EACCES; failed_unchanged(EACCES, 0); CHECK(open_calls == 1);
    reset(); existing = 1; wrong_owner = 1; failed_unchanged(EPERM, 0); CHECK(truncate_calls == 0 && map_calls == 0);
    reset(); existing = 1; bad_mode = 0666; failed_unchanged(EPERM, 0); CHECK(map_calls == 0);
    reset(); existing = 1; bad_mode = 0600; failed_unchanged(EPERM, 0); CHECK(map_calls == 0);
    reset(); wrong_owner = 1; failed_unchanged(EPERM, 1); CHECK(truncate_calls == 0 && map_calls == 0);
    reset(); bad_mode = 0666; failed_unchanged(EPERM, 1); CHECK(truncate_calls == 0 && map_calls == 0);
    reset(); existing = 1; wrong_size = 4; failed_unchanged(EINVAL, 0); CHECK(truncate_calls == 0 && map_calls == 0);
    reset(); existing = 1; wrong_size = 64; failed_unchanged(EINVAL, 0); CHECK(truncate_calls == 0 && map_calls == 0);
    reset(); stat_error = 1; failed_unchanged(EIO, 1); CHECK(close_calls == 1);
    reset(); truncate_error = 1; failed_unchanged(ENOSPC, 1); CHECK(map_calls == 0);
    reset(); map_error = 1; failed_unchanged(ENOMEM, 1); CHECK(unmap_calls == 0 && close_calls == 1);
    reset(); calloc_error = 1; failed_unchanged(ENOMEM, 1); CHECK(unmap_calls == 1);
    reset(); existing = 1; malloc_error = 1; failed_unchanged(ENOMEM, 0); CHECK(unmap_calls == 1);
    reset(); existing = 1; stat_error = 1; failed_unchanged(EIO, 0);
    reset(); existing = 1; map_error = 1; failed_unchanged(ENOMEM, 0);
    reset(); existing = 1; calloc_error = 1; failed_unchanged(ENOMEM, 0);
    reset(); truncate_error = unlink_error = 1; failed_unchanged(ENOSPC, 1); CHECK(close_calls == 1 && log_calls == 2);
    CHECK(strstr(last_log, "setup failed") != NULL);
    reset(); existing = empty_object = truncate_error = 1; failed_unchanged(ENOSPC, 0); CHECK(map_calls == 0);
    uint32_t slots = UINT32_MAX;
    CHECK(parse_shm_pages("0", &slots) == 0 && slots == 0);
    CHECK(parse_shm_pages("1", &slots) == 0 && slots == 4096);
    CHECK(parse_shm_pages("262143", &slots) == 0 && slots == 1073737728);
    slots = 17;
    CHECK(parse_shm_pages("262144", &slots) == -1 && slots == 17);
    CHECK(parse_shm_pages("18446744073709551616", &slots) == -1 && slots == 17);
    CHECK(parse_shm_pages("-1", &slots) == -1 && slots == 17);
    CHECK(parse_shm_pages("", &slots) == -1 && slots == 17);
    CHECK(parse_shm_pages(" 1", &slots) == -1 && slots == 17);
    CHECK(parse_shm_pages("1x", &slots) == -1 && slots == 17);
    CHECK(parse_shm_pages(NULL, &slots) == -1 && slots == 17);
    reset(); printf("notifyd shared-memory fault test: %d checks passed\n", checks);
    return 0;
}
'''
    test = work / 'test.c'
    test.write_text(prefix + actual + suffix)
    binary = work / 'test'
    subprocess.run(['xcrun', 'clang', '-std=c11', '-Wall', '-Wextra', '-Werror',
                    str(test), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
