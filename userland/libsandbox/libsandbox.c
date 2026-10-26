// SPDX-License-Identifier: MIT OR Apache-2.0
#include <sandbox.h>
#include <errno.h>

#include "sbpl.h"
#include "finch_sandbox_abi.h"
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

const char SANDBOX_BUILD_ID[] = "Finch sandbox ABI 1";

/* libsystem_kernel */
int __mac_syscall(const char *policy, int call, void *arg);

static void set_error(char **errorbuf, const char *message);

typedef struct extension_token {
    char *token;
    char *extension_class;
    char *resource;
    unsigned int active;
    struct extension_token *next;
} extension_token;

typedef struct extension_handle {
    int value;
    extension_token *token;
    struct extension_handle *next;
} extension_handle;

typedef struct sandbox_parameters {
    const char **values;
    size_t count;
    size_t capacity;
} *sandbox_params_t;

/* A compiled profile: FSB1 bytes (kernel/sandbox/fsb_format.h). */
typedef struct sandbox_profile {
    char *builtin;
    void *data;
    size_t size;
} *sandbox_profile_t;

static pthread_mutex_t extension_lock = PTHREAD_MUTEX_INITIALIZER;
static extension_token *extension_tokens;
static extension_handle *extension_handles;
static int next_handle = 1;

static bool valid_text(const char *text)
{
    return text && text[0] != '\0';
}

int sandbox_is_sandboxed(void)
{
    return 0;
}

int sandbox_check(pid_t pid, const char *operation, int type, ...)
{
    if (pid < 0 || !valid_text(operation) || type < 0) {
        errno = EINVAL;
        return -1;
    }
    /* Finch has no per-process application sandbox. Every process is unconfined. */
    return 0;
}

int sandbox_check_by_audit_token(const void *audit_token, const char *operation, int type, ...)
{
    if (!audit_token || !valid_text(operation) || type < 0) {
        errno = EINVAL;
        return -1;
    }
    return 0;
}

static char *issue_token(const char *extension_class, const char *resource)
{
    if (!valid_text(extension_class) || !valid_text(resource)) {
        errno = EINVAL;
        return NULL;
    }
    char *token_string = malloc(49);
    extension_token *entry = calloc(1, sizeof(*entry));
    if (!token_string || !entry) {
        free(token_string);
        free(entry);
        errno = ENOMEM;
        return NULL;
    }
    unsigned char random_bytes[16];
    arc4random_buf(random_bytes, sizeof(random_bytes));
    int length = snprintf(token_string, 49,
        "finch-extension:%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x",
        random_bytes[0], random_bytes[1], random_bytes[2], random_bytes[3],
        random_bytes[4], random_bytes[5], random_bytes[6], random_bytes[7],
        random_bytes[8], random_bytes[9], random_bytes[10], random_bytes[11],
        random_bytes[12], random_bytes[13], random_bytes[14], random_bytes[15]);
    if (length < 0 || length >= 49) {
        free(token_string);
        free(entry);
        errno = EIO;
        return NULL;
    }
    entry->token = strdup(token_string);
    entry->extension_class = strdup(extension_class);
    entry->resource = strdup(resource);
    if (!entry->token || !entry->extension_class || !entry->resource) {
        free(entry->token);
        free(entry->extension_class);
        free(entry->resource);
        free(entry);
        free(token_string);
        errno = ENOMEM;
        return NULL;
    }
    pthread_mutex_lock(&extension_lock);
    entry->next = extension_tokens;
    extension_tokens = entry;
    pthread_mutex_unlock(&extension_lock);
    return token_string;
}

char *sandbox_extension_issue_file(const char *extension_class, const char *path, uint32_t flags)
{
    (void)flags;
    struct stat info;
    if (!valid_text(path) || stat(path, &info) != 0) return NULL;
    return issue_token(extension_class, path);
}

char *sandbox_extension_issue_file_to_process(pid_t pid, const char *extension_class,
    const char *path, uint32_t flags)
{
    if (pid != 0 && pid != getpid()) {
        errno = ENOTSUP;
        return NULL;
    }
    return sandbox_extension_issue_file(extension_class, path, flags);
}

char *sandbox_extension_issue_generic(const char *extension_class, const char *name, uint32_t flags)
{
    (void)flags;
    return issue_token(extension_class, name);
}

char *sandbox_extension_issue_mach(const char *extension_class, const char *service, uint32_t flags)
{
    (void)flags;
    return issue_token(extension_class, service);
}

char *sandbox_extension_issue_posix_sem(const char *extension_class, const char *name, uint32_t flags)
{
    (void)flags;
    return issue_token(extension_class, name);
}

char *sandbox_extension_issue_iokit_registry_entry_class(const char *extension_class,
    const char *entry_class, uint32_t flags)
{
    (void)flags;
    return issue_token(extension_class, entry_class);
}

int sandbox_extension_consume(const char *token)
{
    if (!valid_text(token)) { errno = EINVAL; return -1; }
    pthread_mutex_lock(&extension_lock);
    extension_token *entry = extension_tokens;
    while (entry && strcmp(entry->token, token) != 0) entry = entry->next;
    if (!entry) {
        pthread_mutex_unlock(&extension_lock);
        errno = EINVAL;
        return -1;
    }
    extension_handle *handle = calloc(1, sizeof(*handle));
    if (!handle) {
        pthread_mutex_unlock(&extension_lock);
        errno = ENOMEM;
        return -1;
    }
    handle->value = next_handle++;
    if (next_handle <= 0) next_handle = 1;
    handle->token = entry;
    handle->next = extension_handles;
    extension_handles = handle;
    entry->active++;
    int result = handle->value;
    pthread_mutex_unlock(&extension_lock);
    return result;
}

int sandbox_extension_release(int handle_value)
{
    if (handle_value <= 0) { errno = EINVAL; return -1; }
    pthread_mutex_lock(&extension_lock);
    extension_handle **cursor = &extension_handles;
    while (*cursor && (*cursor)->value != handle_value) cursor = &(*cursor)->next;
    if (!*cursor) {
        pthread_mutex_unlock(&extension_lock);
        errno = EINVAL;
        return -1;
    }
    extension_handle *handle = *cursor;
    *cursor = handle->next;
    if (handle->token->active) handle->token->active--;
    free(handle);
    pthread_mutex_unlock(&extension_lock);
    return 0;
}

int sandbox_extension_consume_process(pid_t pid, const char *token)
{
    if (pid != 0 && pid != getpid()) { errno = ENOTSUP; return -1; }
    return sandbox_extension_consume(token);
}

int sandbox_extension_release_process(pid_t pid, int handle)
{
    if (pid != 0 && pid != getpid()) { errno = ENOTSUP; return -1; }
    return sandbox_extension_release(handle);
}

void sandbox_free_error(char *errorbuf)
{
    free(errorbuf);
}

sandbox_params_t sandbox_create_params(void)
{
    return calloc(1, sizeof(struct sandbox_parameters));
}

int sandbox_set_param(sandbox_params_t params, const char *key, const char *value)
{
    if (!params || !valid_text(key) || !value) {
        errno = EINVAL;
        return -1;
    }

    char *key_copy = strdup(key);
    char *value_copy = strdup(value);
    if (!key_copy || !value_copy) {
        free(key_copy);
        free(value_copy);
        errno = ENOMEM;
        return -1;
    }

    if (params->count > SIZE_MAX - 2) {
        free(key_copy);
        free(value_copy);
        errno = EOVERFLOW;
        return -1;
    }
    if (params->count + 2 > params->capacity) {
        size_t capacity = params->capacity ? params->capacity : 8;
        while (capacity < params->count + 2) {
            if (capacity > SIZE_MAX / 2) {
                free(key_copy);
                free(value_copy);
                errno = EOVERFLOW;
                return -1;
            }
            capacity *= 2;
        }
        if (capacity > SIZE_MAX / sizeof(*params->values)) {
            free(key_copy);
            free(value_copy);
            errno = EOVERFLOW;
            return -1;
        }
        const char **values = realloc(params->values, capacity * sizeof(*values));
        if (!values) {
            free(key_copy);
            free(value_copy);
            errno = ENOMEM;
            return -1;
        }
        params->values = values;
        params->capacity = capacity;
    }

    params->values[params->count++] = key_copy;
    params->values[params->count++] = value_copy;
    return 0;
}

void sandbox_free_params(sandbox_params_t params)
{
    if (!params) return;
    for (size_t i = 0; i < params->count; i++) free((void *)params->values[i]);
    free(params->values);
    free(params);
}

/* Where named profiles and imports are found, as on macOS. */
static const char *const profile_folders[] = {
    "/System/Library/Sandbox/Profiles", "/usr/share/sandbox",
};

/*
 * The built-in named profiles sandbox_init(..., SANDBOX_NAMED, ...) takes
 * (kSBXProfile* in sandbox.h), written for Finch.
 */
static const struct { const char *name; const char *source; } builtin_profiles[] = {
    { "no-internet",
      "(version 1)(allow default)(deny network-outbound (remote ip))(deny network-inbound (local ip))" },
    { "no-network",
      "(version 1)(allow default)(deny network*)" },
    { "no-write",
      "(version 1)(allow default)(deny file-write*)" },
    { "no-write-except-temporary",
      "(version 1)(allow default)(deny file-write*)"
      "(allow file-write* (subpath \"/private/tmp\") (subpath \"/private/var/tmp\")"
      " (subpath \"/private/var/folders\"))" },
    { "pure-computation",
      "(version 1)(deny default)(allow process-exec* (literal \"/usr/lib/dyld\"))"
      "(allow file-read* (subpath \"/usr/lib\") (subpath \"/System/Library\"))"
      "(allow sysctl-read)" },
};

static void set_error(char **errorbuf, const char *message)
{
    if (errorbuf) *errorbuf = message ? strdup(message) : NULL;
}

/*
 * The compiler's view of sandbox_set_param's pairs. A parameter named
 * "ENTITLEMENT:key" is instead an entitlement the profile asks about
 * ((entitlement-is-bool-true "key") and the like), as "key=value": the App
 * Sandbox's start (libsystem_secinit) passes the app's this way. An array's
 * values are separated by commas.
 */
#define ENTITLEMENT_PARAM "ENTITLEMENT:"
static struct sbpl_param *compile_params(sandbox_params_t params, size_t *count,
    char ***entitlements, size_t *entitlement_count)
{
    size_t pairs = params ? params->count / 2 : 0;
    struct sbpl_param *list = calloc(pairs ? pairs : 1, sizeof(*list));
    char **ents = calloc(pairs ? pairs : 1, sizeof(*ents));
    if (!list || !ents) {
        free(list);
        free(ents);
        return NULL;
    }
    *count = *entitlement_count = 0;
    for (size_t i = 0; i < pairs; i++) {
        const char *name = params->values[2 * i], *value = params->values[2 * i + 1];
        if (!strncmp(name, ENTITLEMENT_PARAM, strlen(ENTITLEMENT_PARAM))) {
            if (asprintf(&ents[*entitlement_count], "%s=%s", name + strlen(ENTITLEMENT_PARAM), value) < 0) {
                for (size_t j = 0; j < *entitlement_count; j++) free(ents[j]);
                free(ents);
                free(list);
                return NULL;
            }
            (*entitlement_count)++;
            continue;
        }
        list[*count].name = name;
        list[*count].value = value;
        (*count)++;
    }
    *entitlements = ents;
    return list;
}

static sandbox_profile_t wrap(void *compiled, size_t size)
{
    sandbox_profile_t profile = calloc(1, sizeof(*profile));
    if (!profile) {
        free(compiled);
        errno = ENOMEM;
        return NULL;
    }
    profile->data = compiled;
    profile->size = size;
    return profile;
}

/* kind 0: source text; 1: a file path; 2: a name (built in or in profile_folders). */
static sandbox_profile_t compile(int kind, const char *what, sandbox_params_t params,
    char **errorbuf)
{
    if (errorbuf) *errorbuf = NULL;
    if (!what) {
        set_error(errorbuf, "no profile");
        errno = EINVAL;
        return NULL;
    }
    size_t nparams, nentitlements;
    char **entitlements = NULL;
    struct sbpl_param *list = compile_params(params, &nparams, &entitlements, &nentitlements);
    if (!list) {
        set_error(errorbuf, "out of memory");
        errno = ENOMEM;
        return NULL;
    }
    struct sbpl_options options = {
        .params = list, .param_count = nparams,
        .search_paths = profile_folders,
        .search_path_count = sizeof(profile_folders) / sizeof(profile_folders[0]),
        .entitlements = (const char *const *)entitlements, .entitlement_count = nentitlements,
    };
    void *compiled = NULL;
    size_t size = 0;
    char *error = NULL;
    int r;
    if (kind == 2) {
        r = 1;
        for (size_t i = 0; i < sizeof(builtin_profiles) / sizeof(builtin_profiles[0]); i++) {
            if (!strcmp(builtin_profiles[i].name, what)) {
                r = sbpl_compile_string(builtin_profiles[i].source,
                    strlen(builtin_profiles[i].source), what, &options, &compiled, &size, &error);
                break;
            }
        }
        if (r == 1) {
            if (strchr(what, '/')) {
                r = -1;
                error = strdup("a profile name has no '/'");
            } else {
                r = sbpl_compile_file(what, &options, &compiled, &size, &error);
            }
        }
    } else if (kind == 1) {
        r = sbpl_compile_file(what, &options, &compiled, &size, &error);
    } else {
        r = sbpl_compile_string(what, strlen(what), NULL, &options, &compiled, &size, &error);
    }
    free(list);
    for (size_t i = 0; i < nentitlements; i++) free(entitlements[i]);
    free(entitlements);
    if (r != 0) {
        if (errorbuf) *errorbuf = error ? error : strdup("compile failed");
        else free(error);
        errno = EINVAL;
        return NULL;
    }
    return wrap(compiled, size);
}

sandbox_profile_t sandbox_compile_string(const char *profile, sandbox_params_t params,
    char **errorbuf)
{
    return compile(0, profile, params, errorbuf);
}

sandbox_profile_t sandbox_compile_file(const char *path, sandbox_params_t params,
    char **errorbuf)
{
    return compile(1, path, params, errorbuf);
}

sandbox_profile_t sandbox_compile_named(const char *name, sandbox_params_t params,
    char **errorbuf)
{
    return compile(2, name, params, errorbuf);
}

/* Give the calling process the compiled profile (FinchSandbox, call 0x102). */
int sandbox_apply(sandbox_profile_t profile)
{
    if (!profile || !profile->data || !profile->size) {
        errno = EINVAL;
        return -1;
    }
    struct finch_sandbox_profile_request request = {
        .version = FINCH_SANDBOX_ABI_VERSION,
        .size = sizeof(request),
        .profile = (uint64_t)(uintptr_t)profile->data,
        .profile_size = profile->size,
    };
    return __mac_syscall(FINCH_SANDBOX_POLICY, FINCH_SANDBOX_CALL_APPLY_PROFILE, &request) == 0 ? 0 : -1;
}

void sandbox_free_profile(sandbox_profile_t profile)
{
    if (!profile) return;
    free(profile->builtin);
    free(profile->data);
    free(profile);
}

int sandbox_init_with_parameters(const char *profile, uint64_t flags,
    const char *const parameters[], char **errorbuf)
{
    sandbox_params_t params = NULL;
    if (parameters && parameters[0]) {
        params = sandbox_create_params();
        if (!params) {
            set_error(errorbuf, "out of memory");
            return -1;
        }
        for (const char *const *p = parameters; p[0] && p[1]; p += 2) {
            if (sandbox_set_param(params, p[0], p[1]) != 0) {
                sandbox_free_params(params);
                set_error(errorbuf, strerror(errno));
                return -1;
            }
        }
    }
    sandbox_profile_t compiled = (flags & SANDBOX_NAMED) ? sandbox_compile_named(profile, params, errorbuf) :
        sandbox_compile_string(profile, params, errorbuf);
    sandbox_free_params(params);
    if (!compiled) return -1;
    int r = sandbox_apply(compiled);
    if (r != 0) set_error(errorbuf, strerror(errno));
    sandbox_free_profile(compiled);
    return r;
}

int sandbox_init(const char *profile, uint64_t flags, char **errorbuf)
{
    return sandbox_init_with_parameters(profile, flags, NULL, errorbuf);
}

int sandbox_init_with_extensions(const char *profile, uint64_t flags,
    const char *const extensions[], size_t extension_count, char **errorbuf)
{
    (void)extensions;
    (void)extension_count;
    return sandbox_init(profile, flags, errorbuf);
}

int sandbox_init_with_parameters_and_extensions(const char *profile, uint64_t flags,
    const char *const parameters[], const char *const extensions[],
    size_t extension_count, char **errorbuf)
{
    (void)extensions;
    (void)extension_count;
    return sandbox_init_with_parameters(profile, flags, parameters, errorbuf);
}
