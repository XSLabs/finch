/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * SoftLinking (private): _sl_dlopen, which soft-linking code calls to open a library
 * the first time one of its symbols is used. It tries each path of a NULL-terminated
 * list in turn and returns the first that opens; on failure, *error gets dlerror's
 * message (the caller frees it).
 */
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>

__attribute__((visibility("default"))) void *
_sl_dlopen(const char **paths, char **error)
{
    for (const char **p = paths; p && *p; p++) {
        void *h = dlopen(*p, RTLD_LAZY | RTLD_FIRST);
        if (h)
            return h;
    }
    if (error) {
        const char *e = dlerror();
        *error = strdup(e ? e : "no library could be opened");
    }
    return NULL;
}
