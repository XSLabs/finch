/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* The development image has uid-99 ancestors. Keep production path checks
 * intact by testing in a root-owned guest folder. No program is executed
 * after chroot; this header is only for the keychain regression program. */
#ifndef FINCH_KEYCHAIN_TEST_ROOT_H
#define FINCH_KEYCHAIN_TEST_ROOT_H
#include <fcntl.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int keychainTestOutsideRoot = -1;
static char keychainTestGuestRoot[PATH_MAX];

static bool keychainTestEnterRoot(void)
{
    if (access("/etc/finch/rc", R_OK) != 0 ||
        access("/System/Library/Finch/LaunchDaemons/com.apple.SystemConfiguration.configd.plist", R_OK) != 0)
        return true; /* Hosted Finch: use the host's private temporary folder. */
    if (geteuid() != 0) {
        fprintf(stderr, "The guest keychain check requires its disposable root console.\n");
        return false;
    }
    keychainTestOutsideRoot = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (keychainTestOutsideRoot < 0)
        return false;
    strcpy(keychainTestGuestRoot, "/private/var/rw/keychain-root.XXXXXX");
    if (!mkdtemp(keychainTestGuestRoot))
        return false;
    char path[PATH_MAX];
    int n = snprintf(path, sizeof(path), "%s/private", keychainTestGuestRoot);
    if (n < 0 || (size_t)n >= sizeof(path) || mkdir(path, 0700) != 0)
        return false;
    n = snprintf(path, sizeof(path), "%s/private/tmp", keychainTestGuestRoot);
    if (n < 0 || (size_t)n >= sizeof(path) || mkdir(path, 0700) != 0)
        return false;
    if (chroot(keychainTestGuestRoot) != 0 || chdir("/") != 0)
        return false;
    return setenv("TMPDIR", "/private/tmp/", 1) == 0;
}

static bool keychainTestLeaveRoot(void)
{
    if (keychainTestOutsideRoot < 0)
        return true;
    bool ok = fchdir(keychainTestOutsideRoot) == 0 && chroot(".") == 0 && chdir("/") == 0;
    close(keychainTestOutsideRoot);
    keychainTestOutsideRoot = -1;
    if (!ok)
        return false;
    char path[PATH_MAX];
    int n = snprintf(path, sizeof(path), "%s/private/tmp", keychainTestGuestRoot);
    if (n < 0 || (size_t)n >= sizeof(path) || rmdir(path) != 0)
        ok = false;
    n = snprintf(path, sizeof(path), "%s/private", keychainTestGuestRoot);
    if (n < 0 || (size_t)n >= sizeof(path) || rmdir(path) != 0)
        ok = false;
    if (rmdir(keychainTestGuestRoot) != 0)
        ok = false;
    return ok;
}
#endif
