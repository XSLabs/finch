// SPDX-License-Identifier: MIT OR Apache-2.0
#include <sandbox.h>
#include <errno.h>
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

typedef struct sandbox_profile {
    char *builtin;
    unsigned char *data;
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

int sandbox_init(const char *profile, uint64_t flags, char **errorbuf)
{
    (void)profile;
    (void)flags;
    if (errorbuf) *errorbuf = strdup("Finch does not install application sandbox profiles");
    errno = ENOTSUP;
    return -1;
}

int sandbox_init_with_parameters(const char *profile, uint64_t flags,
    const char *const parameters[], char **errorbuf)
{
    (void)parameters;
    return sandbox_init(profile, flags, errorbuf);
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
    (void)parameters;
    (void)extensions;
    (void)extension_count;
    return sandbox_init(profile, flags, errorbuf);
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

static sandbox_profile_t sandbox_profile_unavailable(char **errorbuf)
{
    if (errorbuf) *errorbuf = strdup("Finch does not include a sandbox profile compiler");
    errno = ENOTSUP;
    return NULL;
}

sandbox_profile_t sandbox_compile_string(const char *profile, sandbox_params_t params,
    char **errorbuf)
{
    (void)profile;
    (void)params;
    return sandbox_profile_unavailable(errorbuf);
}

sandbox_profile_t sandbox_compile_file(const char *path, sandbox_params_t params,
    char **errorbuf)
{
    (void)path;
    (void)params;
    return sandbox_profile_unavailable(errorbuf);
}

void sandbox_free_profile(sandbox_profile_t profile)
{
    if (!profile) return;
    free(profile->builtin);
    free(profile->data);
    free(profile);
}
