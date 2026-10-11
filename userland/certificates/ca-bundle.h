/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_CA_BUNDLE_H
#define FINCH_CA_BUNDLE_H
#include <dlfcn.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>

/* Host comparison builds use their own staged roots, not the Mac's trust store.
   In Finch's image the same framework lives directly under /System/Library. */
static inline const char *
finch_ca_bundle(const void *symbol, char path[PATH_MAX])
{
    Dl_info info = {0};
    if (dladdr(symbol, &info) && info.dli_fname) {
        const char *system = strstr(info.dli_fname, "/System/Library/");
        if (system == info.dli_fname)
            return "/etc/ssl/cert.pem";
        if (system) {
            int n = snprintf(path, PATH_MAX, "%.*s/private/etc/ssl/cert.pem",
                (int)(system - info.dli_fname), info.dli_fname);
            if (n > 0 && n < PATH_MAX)
                return path;
            return NULL;
        }
    }
    return NULL;
}
#endif
