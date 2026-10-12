/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * libDiagnosticMessagesClient: message tracer messages, the diagnostic events apps log
 * with keys (com.apple.message.domain, .signature, ...). Apple's builds them as ASL
 * messages and sends them on as analytics events; Finch collects nothing, as its
 * CoreAnalytics doesn't, so messages are built and checked but go nowhere.
 */
#include <asl.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <uuid/uuid.h>

#define EXPORT __attribute__((visibility("default")))

typedef struct msgtracer_domain {
    char *name;
} *msgtracer_domain_t;
typedef aslmsg msgtracer_msg_t;

EXPORT msgtracer_domain_t
msgtracer_domain_new(const char *domain)
{
    if (!domain)
        return NULL;
    msgtracer_domain_t d = malloc(sizeof *d);
    if (!d)
        return NULL;
    d->name = strdup(domain);
    if (!d->name) {
        free(d);
        return NULL;
    }
    return d;
}

EXPORT void
msgtracer_domain_free(msgtracer_domain_t d)
{
    if (!d)
        return;
    free(d->name);
    free(d);
}

EXPORT msgtracer_msg_t
msgtracer_msg_new(msgtracer_domain_t d)
{
    if (!d)
        return NULL;
    aslmsg m = asl_new(ASL_TYPE_MSG);
    if (!m)
        return NULL;
    if (asl_set(m, "com.apple.message.domain", d->name)) {
        asl_free(m);
        return NULL;
    }
    asl_set(m, "com.apple.message.__source__", "SPI");
    return m;
}

EXPORT void
msgtracer_msg_free(msgtracer_msg_t m)
{
    if (m)
        asl_free(m);
}

EXPORT int
msgtracer_set(msgtracer_msg_t m, const char *key, const char *value)
{
    return m ? asl_set(m, key, value) : -1;
}

EXPORT int
msgtracer_vlog(msgtracer_msg_t m, int level, const char *format, va_list ap)
{
    return m && asl_get(m, "com.apple.message.domain") ? 0 : -1;
}

EXPORT int
msgtracer_log(msgtracer_msg_t m, int level, const char *format, ...)
{
    va_list ap;
    va_start(ap, format);
    int r = msgtracer_vlog(m, level, format, ap);
    va_end(ap);
    return r;
}

/* (keys and values in pairs after the level, ending at a NULL key) */
EXPORT int
msgtracer_vlog_with_keys_skip_nulls(const char *domain, int level, va_list ap, int skipNulls)
{
    if (!domain)
        return -1;
    for (;;) {
        const char *key = va_arg(ap, const char *);
        if (!key)
            break;
        (void)va_arg(ap, const char *);
    }
    return 0;
}

EXPORT int
msgtracer_vlog_with_keys(const char *domain, int level, va_list ap)
{
    return msgtracer_vlog_with_keys_skip_nulls(domain, level, ap, 0);
}

EXPORT int
msgtracer_log_with_keys(const char *domain, int level, ...)
{
    va_list ap;
    va_start(ap, level);
    int r = msgtracer_vlog_with_keys_skip_nulls(domain, level, ap, 0);
    va_end(ap);
    return r;
}

EXPORT int
msgtracer_log_with_keys_skip_nulls(const char *domain, int level, ...)
{
    va_list ap;
    va_start(ap, level);
    int r = msgtracer_vlog_with_keys_skip_nulls(domain, level, ap, 1);
    va_end(ap);
    return r;
}

/* A new random UUID as an uppercase string the caller frees. */
EXPORT char *
msgtracer_uuid_create(void)
{
    uuid_t u;
    uuid_generate_random(u);
    char *s = calloc(37, 1);
    if (s)
        uuid_unparse_upper(u, s);
    return s;
}
