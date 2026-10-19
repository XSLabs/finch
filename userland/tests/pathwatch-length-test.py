#!/usr/bin/env python3
"""Check pathwatch's path-length limit on the real patched initializer.

Run from any directory with:
    python3 userland/tests/pathwatch-length-test.py
    python3 userland/tests/pathwatch-length-test.py --source PATH

The test copies the vendored source, applies Finch's pathwatch patches there,
then compiles the real path initializer and update functions with sanitizers.
It does not modify build/src or start notifyd.
"""
from pathlib import Path
import argparse
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SOURCE = ROOT / 'build/src/Libnotify/notifyd/pathwatch.c'
PATCH_DIR = ROOT / 'userland/patches/Libnotify'
PATCHES = (
    PATCH_DIR / '0002-pathwatch-credential-fail-closed.patch',
    PATCH_DIR / '0005-pathwatch-length-limit.patch',
)

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=Path, default=DEFAULT_SOURCE,
                    help='vendor pathwatch.c source; defaults to build/src')
SOURCE = parser.parse_args().source


def ensure_patch(work_path, patch_file):
    """Apply this exact patch, or confirm that it is already applied."""
    patch_text = patch_file.read_text()

    def check(reverse=False):
        args = ['git', '-C', str(work_path), 'apply']
        if reverse:
            args.append('--reverse')
        args.append('--check')
        return subprocess.run(
            args, input=patch_text, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        )

    forward = check()
    if forward.returncode == 0:
        subprocess.run(
            ['git', '-C', str(work_path), 'apply'], input=patch_text,
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            check=True,
        )
        return

    reverse = check(reverse=True)
    if reverse.returncode != 0:
        raise RuntimeError(
            f'{patch_file} did not match this source:\n'
            f'forward check: {forward.stdout}\nreverse check: {reverse.stdout}'
        )


with tempfile.TemporaryDirectory(prefix='pathwatch-length-test-') as work:
    work_path = Path(work)
    target = work_path / 'notifyd/pathwatch.c'
    target.parent.mkdir(parents=True)
    target.write_text(SOURCE.read_text())

    for patch_file in PATCHES:
        ensure_patch(work_path, patch_file)

    source = target.read_text()
    start = source.index('static path_node_t *\n_path_node_init(')
    end = source.index('\nstatic void\n_path_node_update', start)
    actual_initializer = source[start:end]
    update_start = end + 1
    update_end = source.index('\n/*\n * Creates a dispatch source that activates', update_start)
    actual_update = source[update_start:update_end]

    prefix = r'''#include <assert.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/param.h>
#include <stdbool.h>
#include <sys/stat.h>

#ifndef MAXPATHLEN
#define MAXPATHLEN 1024
#endif

typedef struct {
    char *path;
    size_t plen;
    uint64_t audit;
    uint32_t pname_count;
    char **pname;
    uint32_t type;
    uint32_t flags;
    void *src;
} path_node_t;

typedef struct {
    char *path;
} vnode_t;

typedef unsigned long dispatch_time_t;

#define PATH_STAT_OK 0
#define PATH_STAT_MISSING 3
#define PATH_NODE_TYPE_GHOST 0
#define PATH_NODE_TYPE_DIR 3
#define PATH_NODE_DELETE 0x0001
#define VPATH_NODE_TYPE_LINK 1
#define PATH_NODE_ALL 0x000003ff
#define PATH_NODE_MTIME 0x0100
#define PATH_NODE_CTIME 0x0200
#define PATH_NODE_CREATE 0x0080
#define PATH_SRC_SUSPENDED 0x10000000
#define PATH_NODE_CLIENT_NOTIFYD 0x20000000
#define DISPATCH_VNODE_DELETE 0x0001
#define DISPATCH_VNODE_RENAME 0x0002
#define DISPATCH_VNODE_REVOKE 0x0004
#define DISPATCH_VNODE_UNAVAIL (DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME | DISPATCH_VNODE_REVOKE)
#define DISPATCH_TIME_NOW 0
#define PNODE_COALESCE_TIME 100000000

#define forever for (;;)
#define streq(left, right) (strcmp((left), (right)) == 0)

#define dispatch_source_testcancel(source) ((void)(source), 0)
#define dispatch_suspend(source) ((void)(source))
#define dispatch_resume(source) ((void)(source))
#define dispatch_source_merge_data(source, data) ((void)(source), (void)(data))
#define dispatch_time(when, delta) ((void)(when), (void)(delta), 0)
/* The tested update passes no path events, so the deferred block is not run. */
#define dispatch_after(when, queue, block) ((void)(when), (void)(queue))

static void *test_reallocf(void *pointer, size_t size) {
    void *result = realloc(pointer, size);
    if (result == NULL) free(pointer);
    return result;
}

static size_t test_strlcat(char *destination, const char *source, size_t size) {
    size_t destination_length = strnlen(destination, size);
    size_t source_length = strlen(source);
    if (destination_length == size) return size + source_length;
    size_t copy_length = size - destination_length - 1;
    if (copy_length > source_length) copy_length = source_length;
    memcpy(destination + destination_length, source, copy_length);
    destination[destination_length + copy_length] = '\0';
    return destination_length + source_length;
}

#define reallocf test_reallocf
#define strlcat test_strlcat

static int _path_stat_check_access(const char *path, uint64_t audit,
    bool client_is_notifyd, uint32_t *type) {
    (void)path; (void)audit; (void)client_is_notifyd;
    *type = PATH_NODE_TYPE_DIR;
    return PATH_STAT_OK;
}
static void _path_node_retain(path_node_t *node) { (void)node; }
static void _vnode_release_for_node(path_node_t *node) { (void)node; }
static void _vnode_sweep(void) {}
static vnode_t *_vnode_create(const char *path, uint32_t type, path_node_t *node) {
    (void)path; (void)type; (void)node; return NULL;
}
static vnode_t *_vnode_create_real_path(const char *path, uint32_t type, path_node_t *node) {
    (void)path; (void)type; (void)node; return NULL;
}
static void *get_notifyd_workloop(void) { return NULL; }
'''

    suffix = r'''
static void free_node(path_node_t *node) {
    if (node == NULL) return;
    free(node->path);
    for (uint32_t i = 0; i < node->pname_count; i++) free(node->pname[i]);
    free(node->pname);
    free(node);
}

static int expect_normalized(const char *input, const char *expected) {
    path_node_t *node = _path_node_init(input);
    if (node == NULL) return 0;
    int matches = strcmp(node->path, expected) == 0;
    free_node(node);
    return matches;
}

static int expect_rejected(const char *input) {
    path_node_t *node = _path_node_init(input);
    if (node != NULL) {
        free_node(node);
        return 0;
    }
    return 1;
}

static void exercise_update_buffer(size_t path_length) {
    path_node_t node = { 0 };
    node.path = "/";
    node.plen = path_length;
    node.flags = PATH_NODE_ALL;
    _path_node_update(&node, 0, NULL);
}

#define CHECK(condition, message) do { \
    if (!(condition)) { fprintf(stderr, "FAIL: %s\n", message); return 1; } \
} while (0)

int main(void) {
    CHECK(MAXPATHLEN > 2, "MAXPATHLEN must leave room for a path");
    CHECK(expect_normalized("///tmp//notify///", "/tmp/notify"),
        "valid absolute paths must still be normalized");
    CHECK(expect_rejected("relative/path"),
        "relative paths must remain rejected");

    path_node_t *root = _path_node_init(NULL);
    CHECK(root != NULL && root->pname_count == 0,
        "NULL must keep its internal root-path meaning");
    free_node(root);

    char *path = malloc((size_t)MAXPATHLEN + 2);
    CHECK(path != NULL, "could not allocate boundary path");
    path[0] = '/';
    memset(path + 1, 'x', (size_t)MAXPATHLEN);
    path[MAXPATHLEN - 1] = '\0';
    CHECK(strlen(path) == (size_t)MAXPATHLEN - 1,
        "limit-minus-one test input has the wrong size");

    path_node_t *node = _path_node_init(path);
    CHECK(node != NULL, "a path one byte below MAXPATHLEN must be accepted");
    CHECK(node->plen == MAXPATHLEN && strcmp(node->path, path) == 0,
        "a boundary-sized valid path must keep its contents and fit its buffer");
    free_node(node);

    path[MAXPATHLEN - 1] = 'x';
    path[MAXPATHLEN] = '\0';
    CHECK(expect_rejected(path), "a path exactly MAXPATHLEN bytes must be rejected");
    path[MAXPATHLEN] = 'x';
    path[MAXPATHLEN + 1] = '\0';
    CHECK(expect_rejected(path), "a path above MAXPATHLEN bytes must be rejected");
    free(path);

    size_t slash_count = (size_t)MAXPATHLEN * 4096;
    char *slashes = malloc(slash_count + 1);
    CHECK(slashes != NULL, "could not allocate long-slash test input");
    memset(slashes, '/', slash_count);
    slashes[slash_count] = '\0';
    CHECK(expect_rejected(slashes),
        "a huge raw path made of redundant slashes must be rejected before normalization");
    free(slashes);

    exercise_update_buffer((size_t)MAXPATHLEN + 1);
    exercise_update_buffer((size_t)MAXPATHLEN + 2);

    puts("pathwatch path-length and scratch-buffer checks passed");
    return 0;
}
'''

    out = work_path / 'pathwatch-length-test.c'
    out.write_text(prefix + '\n' + actual_initializer + '\n' + actual_update + '\n' + suffix)
    binary = work_path / 'pathwatch-length-test'
    subprocess.run([
        'clang', '-std=c11', '-Wall', '-Wextra', '-Werror',
        '-fsanitize=address,undefined', '-fno-omit-frame-pointer',
        str(out), '-o', str(binary),
    ], check=True)
    environment = os.environ.copy()
    environment['ASAN_OPTIONS'] = 'detect_leaks=0'
    subprocess.run([str(binary)], check=True, env=environment)
