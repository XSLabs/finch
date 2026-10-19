#define _DARWIN_C_SOURCE 1
#include "system_accounts.h"

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef O_CLOEXEC
#define O_CLOEXEC 0
#endif
#ifndef O_NOFOLLOW
#define O_NOFOLLOW 0
#endif
#ifndef O_DIRECTORY
#define O_DIRECTORY 0
#endif

#define SA_MAX_FILE_SIZE (8U * 1024U * 1024U)
#define SA_MAX_RECORDS 8192U
#define SA_NAME "_notifyd"
#define SA_MIN_SYSTEM_ID 2U
#define SA_MAX_SYSTEM_ID 499U

typedef struct {
    char *field[10];
    size_t field_count;
    uint32_t uid;
    uint32_t gid;
} account_record;

typedef struct {
    account_record *items;
    size_t count;
} record_list;

typedef struct {
    char *data;
    size_t length;
    size_t capacity;
} text_buffer;

typedef struct {
    char name[96];
    int fd;
    int active;
    const char *destination;
    mode_t mode;
    uid_t uid;
    gid_t gid;
    const char *data;
    size_t length;
} replacement;

struct sa_notifyd_plan {
    char *user_field[10];
    char *group_field[4];
    uint32_t uid;
    uint32_t gid;
};

#ifdef SYSTEM_ACCOUNTS_TESTING
static unsigned int fail_after_replace;

void
sa_test_fail_after_replace(unsigned int replacement_number)
{
    fail_after_replace = replacement_number;
}
#endif

static void
set_error(char *error, size_t error_size, const char *format, ...)
{
    va_list args;
    if (error == NULL || error_size == 0) {
        return;
    }
    va_start(args, format);
    (void)vsnprintf(error, error_size, format, args);
    va_end(args);
}

static int
bad(char *error, size_t error_size, const char *format, ...)
{
    va_list args;
    if (error != NULL && error_size != 0) {
        va_start(args, format);
        (void)vsnprintf(error, error_size, format, args);
        va_end(args);
    }
    return -1;
}

static int
bad_errno(char *error, size_t error_size, int error_number,
          const char *format, ...)
{
    va_list args;
    if (error != NULL && error_size != 0) {
        va_start(args, format);
        (void)vsnprintf(error, error_size, format, args);
        va_end(args);
    }
    errno = error_number;
    return -1;
}

static int
valid_name(const char *name)
{
    const unsigned char *p = (const unsigned char *)name;
    if (*p == '\0' || !(isalpha(*p) || *p == '_')) {
        return 0;
    }
    for (; *p != '\0'; p++) {
        if (!(isalnum(*p) || *p == '_' || *p == '-' || *p == '.')) {
            return 0;
        }
    }
    return 1;
}

static int
parse_id(const char *text, uint32_t *value)
{
    uint64_t n = 0;
    const unsigned char *p = (const unsigned char *)text;
    if (strcmp(text, "-2") == 0) {
        *value = UINT32_MAX - 1U;
        return 0;
    }
    if (*p == '\0') {
        return -1;
    }
    for (; *p != '\0'; p++) {
        if (*p < '0' || *p > '9') {
            return -1;
        }
        n = n * 10U + (uint64_t)(*p - '0');
        if (n > UINT32_MAX - 1U) {
            return -1;
        }
    }
    *value = (uint32_t)n;
    return 0;
}

static int
safe_field(const char *field)
{
    const unsigned char *p = (const unsigned char *)field;
    for (; *p != '\0'; p++) {
        if (*p < 0x20 || *p == 0x7f) {
            return 0;
        }
    }
    return 1;
}

static int
parse_fields(char *line, char **fields, size_t expected)
{
    size_t count = 1;
    char *p;
    fields[0] = line;
    for (p = line; *p != '\0'; p++) {
        if (*p == ':') {
            *p = '\0';
            if (count == expected) {
                return -1;
            }
            fields[count++] = p + 1;
        }
    }
    return count == expected ? 0 : -1;
}

static void
free_records(record_list *list)
{
    free(list->items);
    list->items = NULL;
    list->count = 0;
}

static int
record_unique(const record_list *list, const account_record *candidate,
              int groups, char *error, size_t error_size)
{
    size_t i;
    for (i = 0; i < list->count; i++) {
        const account_record *other = &list->items[i];
        if (strcmp(other->field[0], candidate->field[0]) == 0) {
            return bad(error, error_size, "duplicate %s name '%s'",
                       groups ? "group" : "user", candidate->field[0]);
        }
        if (groups ? other->gid == candidate->gid : other->uid == candidate->uid) {
            return bad(error, error_size, "duplicate %s ID %u",
                       groups ? "group" : "user",
                       groups ? candidate->gid : candidate->uid);
        }
    }
    return 0;
}

static int
parse_database(char *data, size_t length, int groups, record_list *list,
               char *error, size_t error_size)
{
    size_t line_count = 0;
    char *cursor = data;
    char *end = data + length;
    size_t expected = groups ? 4U : 10U;
    memset(list, 0, sizeof(*list));
    if (length != 0 && data[length - 1] != '\n') {
        return bad(error, error_size, "%s must end with a newline",
                   groups ? "group" : "master.passwd");
    }
    list->items = calloc(SA_MAX_RECORDS, sizeof(*list->items));
    if (list->items == NULL) {
        return bad(error, error_size, "out of memory parsing account files");
    }
    while (cursor < end) {
        char *line_end = memchr(cursor, '\n', (size_t)(end - cursor));
        char *fields[10];
        account_record record;
        size_t line_length;
        size_t i;
        if (line_end == NULL) {
            free_records(list);
            return bad(error, error_size, "unterminated account record");
        }
        line_length = (size_t)(line_end - cursor);
        *line_end = '\0';
        if (line_length == 0 || cursor[0] == '#') {
            cursor = line_end + 1;
            continue;
        }
        if (++line_count > SA_MAX_RECORDS) {
            free_records(list);
            return bad(error, error_size, "too many account records");
        }
        if (parse_fields(cursor, fields, expected) != 0) {
            free_records(list);
            return bad(error, error_size, "bad field count in account record");
        }
        for (i = 0; i < expected; i++) {
            if (!safe_field(fields[i])) {
                free_records(list);
                return bad(error, error_size, "control character in account record");
            }
        }
        if (!valid_name(fields[0])) {
            free_records(list);
            return bad(error, error_size, "invalid account name '%s'", fields[0]);
        }
        memset(&record, 0, sizeof(record));
        record.field_count = expected;
        for (i = 0; i < expected; i++) {
            record.field[i] = fields[i];
        }
        if (groups) {
            if (parse_id(fields[2], &record.gid) != 0) {
                free_records(list);
                return bad(error, error_size, "invalid group ID for '%s'", fields[0]);
            }
            if (*fields[3] != '\0') {
                char *member = fields[3];
                while (member != NULL) {
                    char *comma = strchr(member, ',');
                    if (comma != NULL) {
                        *comma = '\0';
                    }
                    if (!valid_name(member)) {
                        free_records(list);
                        return bad(error, error_size, "invalid group member in '%s'", fields[0]);
                    }
                    member = comma == NULL ? NULL : comma + 1;
                }
            }
        } else {
            if (parse_id(fields[2], &record.uid) != 0 ||
                parse_id(fields[3], &record.gid) != 0) {
                free_records(list);
                return bad(error, error_size, "invalid user or group ID for '%s'", fields[0]);
            }
        }
        if (record_unique(list, &record, groups, error, error_size) != 0) {
            free_records(list);
            return -1;
        }
        list->items[list->count++] = record;
        cursor = line_end + 1;
    }
    return 0;
}

static int
check_directory_component(int fd, const char *path, int final, int target,
                          struct stat *st_out, char *error, size_t error_size)
{
    struct stat st;
    if (fstat(fd, &st) != 0) {
        int saved_errno = errno;
        return bad_errno(error, error_size, saved_errno,
                         "cannot check directory: %s", path);
    }
    if (!S_ISDIR(st.st_mode)) {
        return bad_errno(error, error_size, ENOTDIR,
                         "not a directory: %s", path);
    }
    if ((st.st_mode & (S_IWGRP | S_IWOTH)) != 0 &&
        !(!final && st.st_uid == 0 && (st.st_mode & S_ISVTX) != 0)) {
        return bad_errno(error, error_size, EPERM,
                         "writable directory in path: %s", path);
    }
    if (final && target && st.st_uid != geteuid()) {
        return bad_errno(error, error_size, EACCES,
                         "target directory is not owned by this user: %s", path);
    }
#if defined(__APPLE__)
    if (final && target) {
        struct statfs fs;
        if (fstatfs(fd, &fs) != 0) {
            int saved_errno = errno;
            return bad_errno(error, error_size, saved_errno,
                             "cannot check target mount ownership: %s", strerror(saved_errno));
        }
#ifdef MNT_IGNORE_OWNERSHIP
        if ((fs.f_flags & MNT_IGNORE_OWNERSHIP) != 0) {
            return bad_errno(error, error_size, EPERM,
                             "target mount ignores file ownership: %s", path);
        }
#else
        return bad_errno(error, error_size, ENOTSUP,
                         "cannot verify target mount ownership: %s", path);
#endif
    }
#endif
    if (st_out != NULL) {
        *st_out = st;
    }
    return 0;
}

static int
open_safe_directory(const char *path, int target, struct stat *final_stat,
                    int *path_missing, char *error, size_t error_size)
{
    char *copy;
    char *component;
    char *slash;
    int current;
    if (path_missing != NULL) {
        *path_missing = 0;
    }
    if (path == NULL || path[0] != '/' || path[1] == '\0') {
        errno = EINVAL;
        return bad_errno(error, error_size, EINVAL,
                         "directory path must be absolute: %s",
                         path == NULL ? "(null)" : path);
    }
    copy = strdup(path + 1);
    if (copy == NULL) {
        return bad_errno(error, error_size, ENOMEM,
                         "out of memory opening directory path");
    }
    current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (current < 0) {
        int saved_errno = errno;
        free(copy);
        return bad_errno(error, error_size, saved_errno,
                         "cannot open root directory: %s", strerror(saved_errno));
    }
    component = copy;
    while (component != NULL) {
        int next;
        slash = strchr(component, '/');
        if (slash != NULL) {
            *slash = '\0';
        }
        if (*component == '\0' || strcmp(component, ".") == 0 || strcmp(component, "..") == 0) {
            close(current);
            free(copy);
            return bad_errno(error, error_size, EINVAL,
                             "unsafe directory path: %s", path);
        }
        next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (next < 0) {
            int saved_errno = errno;
            if (path_missing != NULL && saved_errno == ENOENT) {
                *path_missing = 1;
            }
            close(current);
            free(copy);
            return bad_errno(error, error_size, saved_errno,
                             "cannot open directory path %s: %s", path, strerror(saved_errno));
        }
        close(current);
        current = next;
        if (check_directory_component(current, path, slash == NULL, target,
                slash == NULL ? final_stat : NULL, error, error_size) != 0) {
            int saved_errno = errno;
            close(current);
            free(copy);
            errno = saved_errno;
            return -1;
        }
        component = slash == NULL ? NULL : slash + 1;
    }
    free(copy);
    return current;
}

static int
read_file_at(int dirfd, const char *name, int target, mode_t required_mode,
             const struct stat *dir_stat, char **data_out, size_t *length_out,
             struct stat *file_stat, int optional, char *error, size_t error_size)
{
    int fd = openat(dirfd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    struct stat st;
    char *data;
    size_t length;
    size_t offset = 0;
    if (fd < 0) {
        if (optional && errno == ENOENT) {
            *data_out = NULL;
            *length_out = 0;
            memset(file_stat, 0, sizeof(*file_stat));
            return 0;
        }
        return bad(error, error_size, "cannot open %s: %s", name, strerror(errno));
    }
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_nlink != 1 ||
        (target ? (st.st_mode & 07777) != required_mode : (st.st_mode & 022) != 0) || st.st_size < 0 ||
        (uint64_t)st.st_size > SA_MAX_FILE_SIZE) {
        close(fd);
        return bad(error, error_size, "unsafe file or mode: %s", name);
    }
    if (target && st.st_uid != dir_stat->st_uid) {
        close(fd);
        return bad(error, error_size, "wrong owner on %s", name);
    }
    length = (size_t)st.st_size;
    data = malloc(length + 1);
    if (data == NULL) {
        close(fd);
        return bad(error, error_size, "out of memory reading %s", name);
    }
    while (offset < length) {
        ssize_t n = read(fd, data + offset, length - offset);
        if (n < 0 && errno == EINTR) {
            continue;
        }
        if (n <= 0) {
            free(data);
            close(fd);
            return bad(error, error_size, "cannot read %s", name);
        }
        offset += (size_t)n;
    }
    close(fd);
    if (memchr(data, '\0', length) != NULL) {
        free(data);
        return bad(error, error_size, "NUL byte in %s", name);
    }
    data[length] = '\0';
    *data_out = data;
    *length_out = length;
    *file_stat = st;
    return 0;
}

static const account_record *
find_name(const record_list *list, const char *name)
{
    size_t i;
    for (i = 0; i < list->count; i++) {
        if (strcmp(list->items[i].field[0], name) == 0) {
            return &list->items[i];
        }
    }
    return NULL;
}

static int
append_bytes(text_buffer *buffer, const char *data, size_t length)
{
    size_t needed = buffer->length + length + 1;
    if (needed > buffer->capacity) {
        size_t capacity = buffer->capacity == 0 ? 256 : buffer->capacity;
        char *next;
        while (capacity < needed) {
            if (capacity > SIZE_MAX / 2) {
                return -1;
            }
            capacity *= 2;
        }
        next = realloc(buffer->data, capacity);
        if (next == NULL) {
            return -1;
        }
        buffer->data = next;
        buffer->capacity = capacity;
    }
    memcpy(buffer->data + buffer->length, data, length);
    buffer->length += length;
    buffer->data[buffer->length] = '\0';
    return 0;
}

static int
append_cstr(text_buffer *buffer, const char *text)
{
    return append_bytes(buffer, text, strlen(text));
}

static int
build_public_passwd(const char *master, size_t master_length,
                    char **data_out, size_t *length_out)
{
    char *copy = malloc(master_length + 1);
    char *cursor;
    char *end;
    text_buffer output = {0};
    if (copy == NULL) {
        return -1;
    }
    memcpy(copy, master, master_length);
    copy[master_length] = '\0';
    cursor = copy;
    end = copy + master_length;
    while (cursor < end) {
        char *line_end = memchr(cursor, '\n', (size_t)(end - cursor));
        char *fields[10];
        size_t line_length;
        if (line_end == NULL) {
            free(copy);
            free(output.data);
            return -1;
        }
        line_length = (size_t)(line_end - cursor);
        *line_end = '\0';
        if (line_length == 0 || cursor[0] == '#') {
            if (append_bytes(&output, cursor, line_length) != 0 || append_cstr(&output, "\n") != 0) {
                free(copy);
                free(output.data);
                return -1;
            }
        } else {
            if (parse_fields(cursor, fields, 10) != 0 ||
                append_cstr(&output, fields[0]) != 0 || append_cstr(&output, ":*:") != 0 ||
                append_cstr(&output, fields[2]) != 0 || append_cstr(&output, ":") != 0 ||
                append_cstr(&output, fields[3]) != 0 || append_cstr(&output, ":") != 0 ||
                append_cstr(&output, fields[7]) != 0 || append_cstr(&output, ":") != 0 ||
                append_cstr(&output, fields[8]) != 0 || append_cstr(&output, ":") != 0 ||
                append_cstr(&output, fields[9]) != 0 || append_cstr(&output, "\n") != 0) {
                free(copy);
                free(output.data);
                return -1;
            }
        }
        cursor = line_end + 1;
    }
    free(copy);
    if (output.data == NULL) {
        output.data = calloc(1, 1);
        if (output.data == NULL) {
            return -1;
        }
    }
    *data_out = output.data;
    *length_out = output.length;
    return 0;
}

static int
create_temp(int dirfd, replacement *item, char *error, size_t error_size)
{
    unsigned int attempt;
    for (attempt = 0; attempt < 128; attempt++) {
        int n = snprintf(item->name, sizeof(item->name), ".system-account-merge.%ld.%u.tmp",
                         (long)getpid(), attempt);
        if (n < 0 || (size_t)n >= sizeof(item->name)) {
            return bad(error, error_size, "temporary file name is too long");
        }
        item->fd = openat(dirfd, item->name,
                          O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (item->fd >= 0) {
            item->active = 1;
            break;
        }
        if (errno != EEXIST) {
            return bad(error, error_size, "cannot create staged account file: %s", strerror(errno));
        }
    }
    if (item->fd < 0) {
        return bad(error, error_size, "cannot find a free staged file name");
    }
    if (fchown(item->fd, item->uid, item->gid) != 0 ||
        fchmod(item->fd, item->mode) != 0) {
        return bad(error, error_size, "cannot set staged account file permissions: %s", strerror(errno));
    }
    {
        size_t offset = 0;
        while (offset < item->length) {
            ssize_t n = write(item->fd, item->data + offset, item->length - offset);
            if (n < 0 && errno == EINTR) {
                continue;
            }
            if (n <= 0) {
                return bad(error, error_size, "cannot write staged account file: %s", strerror(errno));
            }
            offset += (size_t)n;
        }
    }
    if (fsync(item->fd) != 0) {
        return bad(error, error_size, "cannot save staged account file: %s", strerror(errno));
    }
    {
        int close_result = close(item->fd);
        item->fd = -1;
        if (close_result != 0) {
            return bad(error, error_size, "cannot close staged account file: %s", strerror(errno));
        }
    }
    return 0;
}

static void
cleanup_replacements(int dirfd, replacement *items, size_t count)
{
    size_t i;
    for (i = 0; i < count; i++) {
        if (items[i].fd >= 0) {
            close(items[i].fd);
            items[i].fd = -1;
        }
        if (items[i].active) {
            (void)unlinkat(dirfd, items[i].name, 0);
            items[i].active = 0;
        }
    }
}

static int
replace_files(int dirfd, replacement *items, size_t count,
              char *error, size_t error_size)
{
    size_t i;
#ifdef SYSTEM_ACCOUNTS_TESTING
    unsigned int replaced = 0;
#endif
    for (i = 0; i < count; i++) {
        if (items[i].data == NULL) {
            continue;
        }
        if (create_temp(dirfd, &items[i], error, error_size) != 0) {
            cleanup_replacements(dirfd, items, count);
            return -1;
        }
    }
    for (i = 0; i < count; i++) {
        if (items[i].data == NULL) {
            continue;
        }
        if (renameat(dirfd, items[i].name, dirfd, items[i].destination) != 0) {
            cleanup_replacements(dirfd, items, count);
            return bad(error, error_size, "cannot replace staged %s: %s",
                       items[i].destination, strerror(errno));
        }
        items[i].active = 0;
#ifdef SYSTEM_ACCOUNTS_TESTING
        replaced++;
        if (fail_after_replace != 0 && replaced == fail_after_replace) {
            cleanup_replacements(dirfd, items, count);
            return bad(error, error_size, "injected failure after a staged file replacement");
        }
#endif
    }
    if (fsync(dirfd) != 0) {
        return bad(error, error_size, "cannot sync staged account directory: %s", strerror(errno));
    }
    return 0;
}

static int
sa_notifyd_plan_load_internal(const char *template_dir, sa_notifyd_plan **plan_out,
                              int allow_missing, char *error, size_t error_size)
{
    int template_fd = -1;
    struct stat template_st;
    struct stat template_master_st, template_group_st;
    char *template_master = NULL, *template_group = NULL;
    size_t template_master_len = 0, template_group_len = 0;
    char *template_master_parse = NULL, *template_group_parse = NULL;
    record_list template_users = {0}, template_groups = {0};
    const account_record *user, *group;
    sa_notifyd_plan *plan = NULL;
    int result = -1;
    int directory_missing = 0;
    char *master_name = "master.passwd";
    char *group_name = "group";

    if (error != NULL && error_size != 0) {
        error[0] = '\0';
    }
    if (plan_out == NULL) {
        return bad(error, error_size, "missing plan output");
    }
    *plan_out = NULL;
    template_fd = open_safe_directory(template_dir, 0, &template_st,
                                      &directory_missing, error, error_size);
    if (template_fd < 0) {
        if (allow_missing && directory_missing && errno == ENOENT) {
            result = 0;
        }
        goto done;
    }

    if (read_file_at(template_fd, master_name, 0, 0, &template_st,
                     &template_master, &template_master_len, &template_master_st,
                     1, error, error_size) != 0 ||
        read_file_at(template_fd, group_name, 0, 0, &template_st,
                     &template_group, &template_group_len, &template_group_st,
                     1, error, error_size) != 0) {
        goto done;
    }
    if (template_master == NULL && template_group == NULL) {
        result = allow_missing ? 0 : bad(error, error_size, "template has no account files");
        goto done;
    }
    if (template_master != NULL) template_master_parse = strdup(template_master);
    if (template_group != NULL) template_group_parse = strdup(template_group);
    if ((template_master != NULL && template_master_parse == NULL) ||
        (template_group != NULL && template_group_parse == NULL)) {
        set_error(error, error_size, "out of memory checking account files");
        goto done;
    }
    if ((template_master != NULL &&
         parse_database(template_master_parse, template_master_len, 0,
                        &template_users, error, error_size) != 0) ||
        (template_group != NULL &&
         parse_database(template_group_parse, template_group_len, 1,
                        &template_groups, error, error_size) != 0)) {
        goto done;
    }
    user = find_name(&template_users, SA_NAME);
    group = find_name(&template_groups, SA_NAME);
    if (user == NULL && group == NULL) {
        result = allow_missing ? 0 : bad(error, error_size, "template has no _notifyd account");
        goto done;
    }
    if (user == NULL || group == NULL) {
        set_error(error, error_size, "template has only part of the _notifyd account");
        goto done;
    }
    if (user->uid < SA_MIN_SYSTEM_ID || user->uid > SA_MAX_SYSTEM_ID ||
        user->gid < SA_MIN_SYSTEM_ID || user->gid > SA_MAX_SYSTEM_ID ||
        group->gid < SA_MIN_SYSTEM_ID || group->gid > SA_MAX_SYSTEM_ID) {
        set_error(error, error_size,
                  "template _notifyd user and group IDs must be between 2 and 499");
        goto done;
    }
    if (strcmp(user->field[1], "*") != 0 || user->field[4][0] != '\0' ||
        strcmp(user->field[5], "0") != 0 || strcmp(user->field[6], "0") != 0 ||
        strcmp(user->field[8], "/var/empty") != 0 ||
        strcmp(user->field[9], "/sbin/nologin") != 0 ||
        user->gid != group->gid || strcmp(group->field[1], "*") != 0 ||
        group->field[3][0] != '\0') {
        set_error(error, error_size, "template _notifyd entries are not locked service accounts");
        goto done;
    }
    plan = calloc(1, sizeof(*plan));
    if (plan == NULL) {
        set_error(error, error_size, "out of memory saving _notifyd account plan");
        goto done;
    }
    plan->uid = user->uid;
    plan->gid = group->gid;
    {
        size_t i;
        for (i = 0; i < 10; i++) {
            plan->user_field[i] = strdup(user->field[i]);
            if (plan->user_field[i] == NULL) goto plan_memory_error;
        }
        for (i = 0; i < 4; i++) {
            plan->group_field[i] = strdup(group->field[i]);
            if (plan->group_field[i] == NULL) goto plan_memory_error;
        }
    }
    *plan_out = plan;
    plan = NULL;
    result = 0;
    goto done;

plan_memory_error:
    set_error(error, error_size, "out of memory saving _notifyd account plan");

done:
    if (template_fd >= 0) close(template_fd);
    free(template_master);
    free(template_group);
    free(template_master_parse);
    free(template_group_parse);
    free_records(&template_users);
    free_records(&template_groups);
    sa_notifyd_plan_free(plan);
    return result;
}

int
sa_notifyd_plan_load_optional(const char *template_dir, sa_notifyd_plan **plan_out,
                              char *error, size_t error_size)
{
    return sa_notifyd_plan_load_internal(template_dir, plan_out, 1, error, error_size);
}

int
sa_notifyd_plan_load(const char *template_dir, sa_notifyd_plan **plan_out,
                     char *error, size_t error_size)
{
    if (sa_notifyd_plan_load_internal(template_dir, plan_out, 0, error, error_size) != 0) {
        return -1;
    }
    if (plan_out == NULL || *plan_out == NULL) {
        return bad(error, error_size, "template has no _notifyd account");
    }
    return 0;
}

void
sa_notifyd_plan_free(sa_notifyd_plan *plan)
{
    size_t i;
    if (plan == NULL) return;
    for (i = 0; i < 10; i++) free(plan->user_field[i]);
    for (i = 0; i < 4; i++) free(plan->group_field[i]);
    free(plan);
}

int
sa_notifyd_plan_apply_staged(const sa_notifyd_plan *plan, const char *target_dir,
                             char *error, size_t error_size)
{
    int target_fd = -1;
    struct stat target_st;
    struct stat target_master_st, target_group_st, target_passwd_st;
    char *target_master = NULL, *target_group = NULL, *target_passwd = NULL;
    size_t target_master_len = 0, target_group_len = 0, target_passwd_len = 0;
    char *target_master_parse = NULL, *target_group_parse = NULL;
    char *merged_master = NULL, *merged_group = NULL, *public_passwd = NULL;
    size_t merged_master_len = 0, merged_group_len = 0, public_passwd_len = 0;
    record_list target_users = {0}, target_groups = {0};
    account_record user_value = {0}, group_value = {0};
    const account_record *user = &user_value, *group = &group_value;
    const account_record *old_user, *old_group;
    replacement items[3];
    int changed = 0;
    int result = -1;
    size_t i;
    char *master_name = "master.passwd";
    char *group_name = "group";
    char *passwd_name = "passwd";

    if (error != NULL && error_size != 0) error[0] = '\0';
    if (plan == NULL) return bad(error, error_size, "missing account plan");
    memset(items, 0, sizeof(items));
    for (i = 0; i < 3; i++) items[i].fd = -1;
    for (i = 0; i < 10; i++) user_value.field[i] = plan->user_field[i];
    for (i = 0; i < 4; i++) group_value.field[i] = plan->group_field[i];
    user_value.uid = plan->uid;
    user_value.gid = plan->gid;
    group_value.gid = plan->gid;

    target_fd = open_safe_directory(target_dir, 1, &target_st, NULL, error, error_size);
    if (target_fd < 0) goto done;
    if (read_file_at(target_fd, master_name, 1, 0600, &target_st,
                     &target_master, &target_master_len, &target_master_st,
                     0, error, error_size) != 0 ||
        read_file_at(target_fd, group_name, 1, 0644, &target_st,
                     &target_group, &target_group_len, &target_group_st,
                     0, error, error_size) != 0 ||
        read_file_at(target_fd, passwd_name, 1, 0644, &target_st,
                     &target_passwd, &target_passwd_len, &target_passwd_st,
                     1, error, error_size) != 0) {
        goto done;
    }
    target_master_parse = strdup(target_master);
    target_group_parse = strdup(target_group);
    if (target_master_parse == NULL || target_group_parse == NULL) {
        set_error(error, error_size, "out of memory checking account files");
        goto done;
    }
    if (parse_database(target_master_parse, target_master_len, 0,
                       &target_users, error, error_size) != 0 ||
        parse_database(target_group_parse, target_group_len, 1,
                       &target_groups, error, error_size) != 0) {
        goto done;
    }
    old_user = find_name(&target_users, SA_NAME);
    old_group = find_name(&target_groups, SA_NAME);
    if ((old_user == NULL) != (old_group == NULL)) {
        set_error(error, error_size, "target has only part of the _notifyd account");
        goto done;
    }
    if (old_user != NULL) {
        if (strcmp(old_user->field[1], user->field[1]) != 0 ||
            old_user->uid != user->uid || old_user->gid != user->gid ||
            strcmp(old_user->field[4], user->field[4]) != 0 ||
            strcmp(old_user->field[5], user->field[5]) != 0 ||
            strcmp(old_user->field[6], user->field[6]) != 0 ||
            strcmp(old_user->field[7], user->field[7]) != 0 ||
            strcmp(old_user->field[8], user->field[8]) != 0 ||
            strcmp(old_user->field[9], user->field[9]) != 0 ||
            old_group->gid != group->gid ||
            strcmp(old_group->field[1], group->field[1]) != 0 ||
            strcmp(old_group->field[3], group->field[3]) != 0) {
            set_error(error, error_size, "target _notifyd account does not match the template");
            goto done;
        }
    } else {
        for (i = 0; i < target_users.count; i++) {
            if (target_users.items[i].uid == user->uid) {
                set_error(error, error_size, "user ID %u is already used by '%s'",
                          user->uid, target_users.items[i].field[0]);
                goto done;
            }
        }
        for (i = 0; i < target_groups.count; i++) {
            if (target_groups.items[i].gid == group->gid) {
                set_error(error, error_size, "group ID %u is already used by '%s'",
                          group->gid, target_groups.items[i].field[0]);
                goto done;
            }
        }
        if (target_master_len != 0 && target_master[target_master_len - 1] != '\n') {
            set_error(error, error_size, "target master.passwd must end with a newline");
            goto done;
        }
        if (target_group_len != 0 && target_group[target_group_len - 1] != '\n') {
            set_error(error, error_size, "target group must end with a newline");
            goto done;
        }
        merged_master_len = target_master_len + strlen(user->field[0]) + 64 +
                            strlen(user->field[7]) + strlen(user->field[8]) + strlen(user->field[9]);
        merged_master = malloc(merged_master_len + 1);
        merged_group_len = target_group_len + 64;
        merged_group = malloc(merged_group_len + 1);
        if (merged_master == NULL || merged_group == NULL) {
            set_error(error, error_size, "out of memory adding _notifyd account");
            goto done;
        }
        memcpy(merged_master, target_master, target_master_len);
        merged_master_len = target_master_len;
        {
            int n = snprintf(merged_master + merged_master_len,
                             target_master_len + 64 + strlen(user->field[7]) +
                             strlen(user->field[8]) + strlen(user->field[9]) + 1,
                             "%s:*:%u:%u::0:0:%s:%s:%s\n",
                             user->field[0], user->uid, user->gid,
                             user->field[7], user->field[8], user->field[9]);
            if (n < 0) {
                set_error(error, error_size, "cannot format _notifyd account");
                goto done;
            }
            merged_master_len += (size_t)n;
        }
        merged_master[merged_master_len] = '\0';
        memcpy(merged_group, target_group, target_group_len);
        merged_group_len = target_group_len;
        {
            int n = snprintf(merged_group + merged_group_len, 64,
                             "%s:*:%u:\n", group->field[0], group->gid);
            if (n < 0 || n >= 64) {
                set_error(error, error_size, "cannot format _notifyd group");
                goto done;
            }
            merged_group_len += (size_t)n;
        }
        merged_group[merged_group_len] = '\0';
        changed = 1;
    }
    if (!changed) {
        merged_master = strdup(target_master);
        merged_group = strdup(target_group);
        merged_master_len = target_master_len;
        merged_group_len = target_group_len;
        if (merged_master == NULL || merged_group == NULL) {
            set_error(error, error_size, "out of memory checking public passwd");
            goto done;
        }
    }
    if (build_public_passwd(merged_master, merged_master_len,
                            &public_passwd, &public_passwd_len) != 0) {
        set_error(error, error_size, "cannot build public passwd file");
        goto done;
    }
    if (target_passwd == NULL || target_passwd_len != public_passwd_len ||
        memcmp(target_passwd, public_passwd, public_passwd_len) != 0) {
        changed = 1;
    }
    if (!changed) {
        result = 0;
        goto done;
    }
    items[0].destination = master_name;
    items[0].mode = 0600;
    items[0].uid = target_st.st_uid;
    items[0].gid = target_master_st.st_gid;
    items[0].data = old_user == NULL ? merged_master : NULL;
    items[0].length = merged_master_len;
    items[1].destination = group_name;
    items[1].mode = 0644;
    items[1].uid = target_st.st_uid;
    items[1].gid = target_group_st.st_gid;
    items[1].data = old_group == NULL ? merged_group : NULL;
    items[1].length = merged_group_len;
    items[2].destination = passwd_name;
    items[2].mode = 0644;
    items[2].uid = target_st.st_uid;
    items[2].gid = target_passwd == NULL ? target_master_st.st_gid : target_passwd_st.st_gid;
    items[2].data = public_passwd;
    items[2].length = public_passwd_len;
    if (replace_files(target_fd, items, 3, error, error_size) != 0) {
        goto done;
    }
    result = 1;

done:
    if (target_fd >= 0) close(target_fd);
    free(target_master);
    free(target_group);
    free(target_passwd);
    free(target_master_parse);
    free(target_group_parse);
    free(merged_master);
    free(merged_group);
    free(public_passwd);
    free_records(&target_users);
    free_records(&target_groups);
    return result;
}

int
sa_merge_notifyd_staged(const char *template_dir, const char *target_dir,
                        char *error, size_t error_size)
{
    sa_notifyd_plan *plan = NULL;
    int result;
    if (sa_notifyd_plan_load(template_dir, &plan, error, error_size) != 0) {
        return -1;
    }
    result = sa_notifyd_plan_apply_staged(plan, target_dir, error, error_size);
    sa_notifyd_plan_free(plan);
    return result;
}

static int
normalize_account_file_at(int dirfd, const struct stat *dir_stat,
                          const char *name, mode_t mode,
                          uid_t owner, gid_t group, int optional,
                          char *error, size_t error_size)
{
    int fd = openat(dirfd, name, O_RDWR | O_NOFOLLOW | O_CLOEXEC);
    struct stat st;
    if (fd < 0) {
        if (optional && errno == ENOENT) return 0;
        return bad(error, error_size, "cannot open %s for normalization: %s",
                   name, strerror(errno));
    }
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_nlink != 1 ||
        st.st_dev != dir_stat->st_dev) {
        close(fd);
        return bad(error, error_size, "unsafe account file: %s", name);
    }
    if (fchown(fd, owner, group) != 0 || fchmod(fd, mode) != 0 || fsync(fd) != 0) {
        int saved_errno = errno;
        close(fd);
        return bad(error, error_size, "cannot normalize %s: %s",
                   name, strerror(saved_errno));
    }
    if (fstat(fd, &st) != 0 || st.st_uid != owner || st.st_gid != group ||
        (st.st_mode & 07777) != mode) {
        close(fd);
        return bad(error, error_size, "normalization did not take effect on %s", name);
    }
    if (close(fd) != 0) {
        return bad(error, error_size, "cannot close normalized %s: %s",
                   name, strerror(errno));
    }
    return 0;
}

static int
normalize_staged_account_files(const char *target_dir, uid_t owner, gid_t group,
                               char *error, size_t error_size)
{
    int target_fd = -1;
    struct stat target_st;
    int result = -1;
    if (error != NULL && error_size != 0) error[0] = '\0';
    target_fd = open_safe_directory(target_dir, 1, &target_st, NULL,
                                    error, error_size);
    if (target_fd < 0) return -1;
    if (normalize_account_file_at(target_fd, &target_st, "master.passwd", 0600,
                                  owner, group, 0, error, error_size) != 0 ||
        normalize_account_file_at(target_fd, &target_st, "passwd", 0644,
                                  owner, group, 1, error, error_size) != 0 ||
        normalize_account_file_at(target_fd, &target_st, "group", 0644,
                                  owner, group, 0, error, error_size) != 0) {
        goto done;
    }
    if (fsync(target_fd) != 0) {
        bad(error, error_size, "cannot sync staged account directory: %s", strerror(errno));
        goto done;
    }
    result = 0;

done:
    close(target_fd);
    return result;
}

int
sa_normalize_staged_account_files(const char *target_dir,
                                  char *error, size_t error_size)
{
    if (geteuid() != 0) {
        return bad_errno(error, error_size, EPERM,
                         "account-file normalization must run as root");
    }
    return normalize_staged_account_files(target_dir, 0, 0, error, error_size);
}

int
sa_notifyd_plan_verify_staged(const sa_notifyd_plan *plan, const char *target_dir,
                              uid_t expected_uid, gid_t expected_gid,
                              char *error, size_t error_size)
{
    int target_fd = -1;
    struct stat target_st;
    struct stat master_st, group_st, passwd_st;
    char *master = NULL, *group = NULL, *passwd = NULL;
    char *master_parse = NULL, *group_parse = NULL;
    char *public_passwd = NULL;
    size_t master_len = 0, group_len = 0, passwd_len = 0, public_passwd_len = 0;
    record_list users = {0}, groups = {0};
    const account_record *user, *service_group;
    account_record expected_user = {0}, expected_group = {0};
    size_t i;
    int result = -1;

    if (error != NULL && error_size != 0) error[0] = '\0';
    if (plan == NULL) return bad(error, error_size, "missing account plan");
    target_fd = open_safe_directory(target_dir, 1, &target_st, NULL,
                                    error, error_size);
    if (target_fd < 0) goto done;
    if (target_st.st_uid != expected_uid || target_st.st_gid != expected_gid) {
        set_error(error, error_size, "staged account directory has the wrong owner");
        goto done;
    }
    if (read_file_at(target_fd, "master.passwd", 1, 0600, &target_st,
                     &master, &master_len, &master_st, 0, error, error_size) != 0 ||
        read_file_at(target_fd, "group", 1, 0644, &target_st,
                     &group, &group_len, &group_st, 0, error, error_size) != 0 ||
        read_file_at(target_fd, "passwd", 1, 0644, &target_st,
                     &passwd, &passwd_len, &passwd_st, 0, error, error_size) != 0) {
        goto done;
    }
    if (master_st.st_uid != expected_uid || master_st.st_gid != expected_gid ||
        group_st.st_uid != expected_uid || group_st.st_gid != expected_gid ||
        passwd_st.st_uid != expected_uid || passwd_st.st_gid != expected_gid) {
        set_error(error, error_size, "staged account files must have the expected owner and group");
        goto done;
    }
    master_parse = strdup(master);
    group_parse = strdup(group);
    if (master_parse == NULL || group_parse == NULL) {
        set_error(error, error_size, "out of memory checking staged account files");
        goto done;
    }
    if (parse_database(master_parse, master_len, 0, &users, error, error_size) != 0 ||
        parse_database(group_parse, group_len, 1, &groups, error, error_size) != 0) {
        goto done;
    }
    user = find_name(&users, SA_NAME);
    service_group = find_name(&groups, SA_NAME);
    if (user == NULL || service_group == NULL) {
        set_error(error, error_size, "staged account files are missing _notifyd");
        goto done;
    }
    for (i = 0; i < 10; i++) expected_user.field[i] = plan->user_field[i];
    for (i = 0; i < 4; i++) expected_group.field[i] = plan->group_field[i];
    expected_user.uid = plan->uid;
    expected_user.gid = plan->gid;
    expected_group.gid = plan->gid;
    if (user->uid != expected_user.uid || user->gid != expected_user.gid ||
        service_group->gid != expected_group.gid) {
        set_error(error, error_size, "staged _notifyd IDs do not match the template");
        goto done;
    }
    for (i = 0; i < 10; i++) {
        if (strcmp(user->field[i], expected_user.field[i]) != 0) {
            set_error(error, error_size, "staged _notifyd user does not match the template");
            goto done;
        }
    }
    for (i = 0; i < 4; i++) {
        if (strcmp(service_group->field[i], expected_group.field[i]) != 0) {
            set_error(error, error_size, "staged _notifyd group does not match the template");
            goto done;
        }
    }
    if (build_public_passwd(master, master_len, &public_passwd, &public_passwd_len) != 0) {
        set_error(error, error_size, "cannot build public passwd file for verification");
        goto done;
    }
    if (passwd_len != public_passwd_len ||
        memcmp(passwd, public_passwd, public_passwd_len) != 0) {
        set_error(error, error_size, "public passwd does not match master.passwd");
        goto done;
    }
    result = 0;

done:
    if (target_fd >= 0) close(target_fd);
    free(master);
    free(group);
    free(passwd);
    free(master_parse);
    free(group_parse);
    free(public_passwd);
    free_records(&users);
    free_records(&groups);
    return result;
}

#ifdef SYSTEM_ACCOUNTS_TESTING
int
sa_test_normalize_staged_account_files(const char *target_dir, uid_t owner,
                                       gid_t group, char *error, size_t error_size)
{
    return normalize_staged_account_files(target_dir, owner, group, error, error_size);
}
#endif
