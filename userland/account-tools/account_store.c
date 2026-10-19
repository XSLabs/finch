/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Small, guarded writer for Finch's local account files. The master file is
 * the source of truth. The public passwd file always gets a '*' password.
 */

#include "account_tools.h"

#include <CommonCrypto/CommonRandom.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef O_CLOEXEC
#define O_CLOEXEC 0
#endif

#define DB_MAX_BYTES (8U * 1024U * 1024U)
#define DB_MAX_LINE 4096
#define USERNAME_MAX 31
#define HASH_FIELD_MAX 256
#define GECOS_MAX 256
#define PATH_FIELD_MAX 1024
#define STORE_CONFIG_PATH "/private/etc/finch/account-store"
#define LEGACY_STORE_PATH "/private/etc"
#define STORE_CONFIG_MAX 1024
#define FIELD_COUNT 10

#if defined(AT_ACCOUNT_TOOLS_TESTING)
static const char *test_fail_replace_name;

void
at_test_fail_replace(const char *name)
{
	test_fail_replace_name = name;
}
#endif

struct file_data {
	char *bytes;
	size_t length;
	uid_t owner;
	gid_t group;
	mode_t mode;
};

struct account_record {
	char name[USERNAME_MAX + 1];
	char hash[HASH_FIELD_MAX + 1];
	char uid_text[16];
	char gid_text[16];
	char gecos[GECOS_MAX + 1];
	char home[PATH_FIELD_MAX + 1];
	char shell[PATH_FIELD_MAX + 1];
	uid_t uid;
	gid_t gid;
	size_t line_start;
	size_t line_length;
	size_t hash_start;
	size_t hash_length;
};

struct home_directory {
	int parent_fd;
	char leaf[NAME_MAX + 1];
	dev_t device;
	ino_t inode;
	bool identity_valid;
	bool created;
};

static void
set_error(char *error, size_t size, const char *format, ...)
{
	if (!error || size == 0)
		return;
	va_list args;
	va_start(args, format);
	(void)vsnprintf(error, size, format, args);
	va_end(args);
}

static void
free_file(struct file_data *file)
{
	free(file->bytes);
	memset(file, 0, sizeof(*file));
}

static int
open_directory_path(const char *path, uid_t expected_owner, char *error,
	size_t error_size)
{
	int current = -1;
	char *copy = NULL, *component, *next;
	struct stat st;

	if (!path || path[0] != '/' || path[1] == '\0') {
		set_error(error, error_size, "account folder must be an absolute path below /");
		errno = EINVAL;
		return -1;
	}
	current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
	if (current < 0)
		goto system_error;
	if (fstat(current, &st) != 0)
		goto system_error;
	if (!S_ISDIR(st.st_mode) || st.st_uid != 0) {
		set_error(error, error_size, "account folder path does not start at a root-owned folder");
		errno = EPERM;
		goto fail;
	}
	copy = strdup(path + 1);
	if (!copy)
		goto system_error;
	component = copy;
	while (*component) {
		next = strchr(component, '/');
		if (next)
			*next = '\0';
		if (component[0] == '\0' || strcmp(component, ".") == 0 ||
		    strcmp(component, "..") == 0) {
			set_error(error, error_size, "account folder has an unsafe path part");
			errno = EINVAL;
			goto fail;
		}
		int child = openat(current, component,
		    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
		if (child < 0)
			goto system_error;
		if (fstat(child, &st) != 0) {
			close(child);
			goto system_error;
		}
		if (!S_ISDIR(st.st_mode)) {
			close(child);
			set_error(error, error_size, "account folder contains a non-folder");
			errno = ENOTDIR;
			goto fail;
		}
		if (next && (expected_owner == 0 ? st.st_uid != 0 :
		    (st.st_uid != 0 && st.st_uid != expected_owner))) {
			close(child);
			set_error(error, error_size, "account folder has an unsafe parent owner");
			errno = EPERM;
			goto fail;
		}
		/* Sticky, root-owned /private/tmp is safe as a parent for our fixture. */
		if (next && (st.st_mode & 0022) != 0 &&
		    !(st.st_uid == 0 && (st.st_mode & S_ISVTX) != 0)) {
			close(child);
			set_error(error, error_size, "account folder has a writable parent");
			errno = EPERM;
			goto fail;
		}
		close(current);
		current = child;
		if (!next)
			break;
		component = next + 1;
	}
	if (fstat(current, &st) != 0)
		goto system_error;
	if (st.st_uid != expected_owner || (st.st_mode & 0022) != 0) {
		set_error(error, error_size, "account folder must belong to its caller and block group and other writes");
		errno = EPERM;
		goto fail;
	}
	free(copy);
	return current;

system_error:
	set_error(error, error_size, "cannot safely open account folder: %s", strerror(errno));
fail:
	free(copy);
	if (current >= 0)
		close(current);
	return -1;
}

static bool
is_canonical_absolute_path(const char *path)
{
	const char *component;
	if (!path || path[0] != '/' || path[1] == '\0')
		return false;
	component = path + 1;
	for (const char *p = component;; ++p) {
		if (*p == '/' || *p == '\0') {
			size_t length = (size_t)(p - component);
			if (length == 0 || (length == 1 && component[0] == '.') ||
			    (length == 2 && component[0] == '.' && component[1] == '.'))
				return false;
			if (*p == '\0')
				return true;
			component = p + 1;
		}
	}
}

/* Open a single trusted config file without following any part of its path. */
static int
open_store_config(const char *path, uid_t expected_owner, char *error,
	size_t error_size)
{
	char *copy = NULL, *slash, *leaf = NULL;
	int directory_fd = -1, fd = -1;
	struct stat st;

	if (!path || path[0] != '/') {
		set_error(error, error_size, "account store setting path is invalid");
		errno = EINVAL;
		return -1;
	}
	copy = strdup(path);
	if (!copy) {
		set_error(error, error_size, "not enough memory to read account store setting");
		return -1;
	}
	slash = strrchr(copy, '/');
	if (!slash || slash[1] == '\0') {
		set_error(error, error_size, "account store setting path is invalid");
		errno = EINVAL;
		goto done;
	}
	leaf = slash + 1;
	leaf = strdup(leaf);
	if (!leaf) {
		set_error(error, error_size, "not enough memory to read account store setting");
		goto done;
	}
	if (slash == copy) {
		copy[1] = '\0';
	} else {
		*slash = '\0';
	}
	directory_fd = open_directory_path(copy, expected_owner, error, error_size);
	if (directory_fd < 0)
		goto done;
	fd = openat(directory_fd, leaf,
	    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
	if (fd < 0) {
		set_error(error, error_size, "cannot safely open account store setting: %s",
		    strerror(errno));
		goto done;
	}
	if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_nlink != 1 ||
	    st.st_uid != expected_owner || (st.st_mode & 0022) != 0) {
		set_error(error, error_size,
		    "account store setting has unsafe owner, type, link count, or mode");
		close(fd);
		fd = -1;
		errno = EPERM;
	}
done:
	if (directory_fd >= 0)
		close(directory_fd);
	free(leaf);
	free(copy);
	return fd;
}

static int
store_open_default_at(struct at_store *store, const char *config_path,
	const char *fallback_directory, uid_t config_owner, char *error,
	size_t error_size)
{
	char configured_path[STORE_CONFIG_MAX + 1];
	size_t used = 0;
	int fd;

	if (!store) {
		set_error(error, error_size, "missing account store");
		errno = EINVAL;
		return -1;
	}
	store->directory_fd = -1;
	store->owner = geteuid();
	fd = open_store_config(config_path, config_owner, error, error_size);
	if (fd < 0) {
		if (errno == ENOENT) {
			int fallback_status = at_store_open(store, fallback_directory, error,
			    error_size);
			if (fallback_status == 0 && error && error_size > 0)
				error[0] = '\0';
			return fallback_status;
		}
		return -1;
	}
	for (;;) {
		ssize_t amount = read(fd, configured_path + used,
		    sizeof(configured_path) - used);
		if (amount < 0) {
			if (errno == EINTR)
				continue;
			set_error(error, error_size, "cannot read account store setting: %s",
			    strerror(errno));
			close(fd);
			return -1;
		}
		if (amount == 0)
			break;
		used += (size_t)amount;
		if (used == sizeof(configured_path)) {
			set_error(error, error_size, "account store setting is too long");
			close(fd);
			errno = EINVAL;
			return -1;
		}
	}
	close(fd);
	if (used < 2 || configured_path[used - 1] != '\n' ||
	    memchr(configured_path, '\0', used) != NULL ||
	    memchr(configured_path, '\n', used - 1) != NULL) {
		set_error(error, error_size,
		    "account store setting must contain one absolute path ending in a newline");
		errno = EINVAL;
		return -1;
	}
	configured_path[used - 1] = '\0';
	if (!is_canonical_absolute_path(configured_path)) {
		set_error(error, error_size,
		    "account store setting must name a canonical absolute directory");
		errno = EINVAL;
		return -1;
	}
	return at_store_open(store, configured_path, error, error_size);
}

int
at_store_open(struct at_store *store, const char *directory, char *error,
	size_t error_size)
{
	if (!store) {
		set_error(error, error_size, "missing account store");
		errno = EINVAL;
		return -1;
	}
	store->directory_fd = -1;
	store->owner = geteuid();
	store->directory_fd = open_directory_path(directory, store->owner, error,
	    error_size);
	return store->directory_fd < 0 ? -1 : 0;
}

int
at_store_open_default(struct at_store *store, char *error, size_t error_size)
{
	return store_open_default_at(store, STORE_CONFIG_PATH, LEGACY_STORE_PATH, 0,
	    error, error_size);
}

#if defined(AT_ACCOUNT_TOOLS_TESTING)
int
at_test_store_open_default(struct at_store *store, const char *config_path,
	const char *fallback_directory, uid_t config_owner, char *error,
	size_t error_size)
{
	return store_open_default_at(store, config_path, fallback_directory,
	    config_owner, error, error_size);
}
#endif

void
at_store_close(struct at_store *store)
{
	if (store && store->directory_fd >= 0) {
		close(store->directory_fd);
		store->directory_fd = -1;
	}
}

static int
lock_store(struct at_store *store, char *error, size_t error_size)
{
	struct stat st;
	int fd = openat(store->directory_fd, ".finch-account.lock",
	    O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
	if (fd < 0) {
		set_error(error, error_size, "cannot open account lock: %s", strerror(errno));
		return -1;
	}
	if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_nlink != 1 ||
	    st.st_uid != store->owner || fchmod(fd, 0600) != 0) {
		set_error(error, error_size, "account lock has unsafe owner, type, or mode");
		close(fd);
		errno = EPERM;
		return -1;
	}
	if (flock(fd, LOCK_EX) != 0) {
		set_error(error, error_size, "cannot lock account files: %s", strerror(errno));
		close(fd);
		return -1;
	}
	return fd;
}

static int
read_file(struct at_store *store, const char *name, mode_t expected_mode,
	struct file_data *out, char *error, size_t error_size)
{
	struct stat st;
	int fd = openat(store->directory_fd, name,
	    O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
	if (fd < 0) {
		set_error(error, error_size, "cannot open %s: %s", name, strerror(errno));
		return -1;
	}
	if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_nlink != 1 ||
	    st.st_uid != store->owner || (st.st_mode & 07777) != expected_mode) {
		set_error(error, error_size, "%s has unsafe owner, type, link count, or mode", name);
		close(fd);
		errno = EPERM;
		return -1;
	}
	char *bytes = malloc(DB_MAX_BYTES + 1);
	if (!bytes) {
		set_error(error, error_size, "not enough memory to read %s", name);
		close(fd);
		return -1;
	}
	size_t length = 0;
	for (;;) {
		ssize_t n = read(fd, bytes + length, DB_MAX_BYTES - length + 1);
		if (n < 0 && errno == EINTR)
			continue;
		if (n < 0) {
			set_error(error, error_size, "cannot read %s: %s", name, strerror(errno));
			free(bytes);
			close(fd);
			return -1;
		}
		if (n == 0)
			break;
		length += (size_t)n;
		if (length > DB_MAX_BYTES) {
			set_error(error, error_size, "%s is too large to update safely", name);
			free(bytes);
			close(fd);
			errno = EFBIG;
			return -1;
		}
	}
	close(fd);
	if (memchr(bytes, '\0', length) != NULL) {
		set_error(error, error_size, "%s contains a zero byte", name);
		free(bytes);
		errno = EINVAL;
		return -1;
	}
	bytes[length] = '\0';
	out->bytes = bytes;
	out->length = length;
	out->owner = st.st_uid;
	out->group = st.st_gid;
	out->mode = st.st_mode & 0777;
	return 0;
}

static int
write_all(int fd, const char *data, size_t size)
{
	while (size > 0) {
		ssize_t n = write(fd, data, size);
		if (n < 0 && errno == EINTR)
			continue;
		if (n <= 0)
			return -1;
		data += n;
		size -= (size_t)n;
	}
	return 0;
}

static int
atomic_replace(struct at_store *store, const char *name, const char *data,
	size_t length, mode_t mode, uid_t owner, gid_t group,
	char *error, size_t error_size)
{
	unsigned char random[8];
	char temp[64] = {0};
	int fd = -1, result = -1;
	struct stat st;

	if (length > DB_MAX_BYTES) {
		set_error(error, error_size, "new account file is too large");
		errno = EFBIG;
		return -1;
	}
	for (int attempt = 0; attempt < 64; ++attempt) {
		if (CCRandomGenerateBytes(random, sizeof(random)) != kCCSuccess) {
			set_error(error, error_size, "secure random bytes are not available");
			errno = EIO;
			goto done;
		}
		static const char hex[] = "0123456789abcdef";
		memcpy(temp, ".finch-account-", 15);
		for (size_t i = 0; i < sizeof(random); ++i) {
			temp[15 + i * 2] = hex[random[i] >> 4];
			temp[16 + i * 2] = hex[random[i] & 15];
		}
		memcpy(temp + 31, ".tmp", 5);
		fd = openat(store->directory_fd, temp,
		    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
		if (fd >= 0)
			break;
		if (errno != EEXIST)
			break;
	}
	if (fd < 0) {
		set_error(error, error_size, "cannot create a private account file: %s", strerror(errno));
		goto done;
	}
	if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_nlink != 1 ||
	    st.st_uid != geteuid() || fchown(fd, owner, group) != 0 ||
	    fchmod(fd, mode) != 0 || write_all(fd, data, length) != 0 || fsync(fd) != 0) {
		set_error(error, error_size, "cannot prepare new %s: %s", name, strerror(errno));
		goto done;
	}
	if (close(fd) != 0) {
		fd = -1;
		set_error(error, error_size, "cannot close new %s: %s", name, strerror(errno));
		goto done;
	}
	fd = -1;
#if defined(AT_ACCOUNT_TOOLS_TESTING)
	if (test_fail_replace_name && strcmp(test_fail_replace_name, name) == 0) {
		test_fail_replace_name = NULL;
		set_error(error, error_size, "injected test failure while saving %s", name);
		errno = EIO;
		goto done;
	}
#endif
	if (renameat(store->directory_fd, temp, store->directory_fd, name) != 0) {
		set_error(error, error_size, "cannot replace %s: %s", name, strerror(errno));
		goto done;
	}
	if (fsync(store->directory_fd) != 0) {
		set_error(error, error_size, "cannot finish saving %s: %s", name, strerror(errno));
		goto done;
	}
	result = 0;
done:
	if (fd >= 0)
		close(fd);
	if (result != 0 && temp[0] != '\0')
		(void)unlinkat(store->directory_fd, temp, 0);
	at_secure_clear(random, sizeof(random));
	return result;
}

static int
parse_uid_gid(const char *text, uint64_t maximum, uint64_t *value)
{
	if (!text || !text[0])
		return -1;
	/* Darwin uses -2 for the nobody uid and gid. Preserve that spelling. */
	if (strcmp(text, "-2") == 0) {
		*value = UINT32_MAX - 1U;
		return 0;
	}
	for (const char *p = text; *p; ++p)
		if (*p < '0' || *p > '9')
			return -1;
	char *end;
	errno = 0;
	unsigned long long parsed = strtoull(text, &end, 10);
	if (errno || *end || parsed > maximum || parsed == UINT32_MAX)
		return -1;
	*value = (uint64_t)parsed;
	return 0;
}

static int
valid_username(const char *name)
{
	if (!name || !name[0] || strlen(name) > USERNAME_MAX ||
	    !((name[0] >= 'A' && name[0] <= 'Z') ||
	      (name[0] >= 'a' && name[0] <= 'z') || name[0] == '_'))
		return 0;
	for (const char *p = name + 1; *p; ++p)
		if (!((*p >= 'A' && *p <= 'Z') || (*p >= 'a' && *p <= 'z') ||
		    (*p >= '0' && *p <= '9') || *p == '_' || *p == '.' || *p == '-'))
			return 0;
	return 1;
}

static int
copy_field(char *out, size_t capacity, const char *field, size_t length)
{
	if (length >= capacity)
		return -1;
	memcpy(out, field, length);
	out[length] = '\0';
	return 0;
}

/* Parse one ten-field master.passwd line and keep its offsets for safe edits. */
static int
parse_account_line(const char *line, size_t length, size_t line_start,
	struct account_record *record)
{
	char copy[DB_MAX_LINE + 1];
	char *fields[FIELD_COUNT];
	size_t starts[FIELD_COUNT], lengths[FIELD_COUNT];
	if (length > DB_MAX_LINE)
		return -1;
	if (length == 0 || line[0] == '#')
		return 1;
	if (memchr(line, '\r', length) != NULL)
		return -1;
	memcpy(copy, line, length);
	copy[length] = '\0';
	fields[0] = copy;
	starts[0] = 0;
	unsigned count = 1;
	for (size_t i = 0; i < length; ++i) {
		if (copy[i] == ':') {
			if (count >= FIELD_COUNT)
				return -1;
			lengths[count - 1] = i - starts[count - 1];
			copy[i] = '\0';
			fields[count] = copy + i + 1;
			starts[count] = i + 1;
			++count;
		}
	}
	if (count != FIELD_COUNT)
		return -1;
	lengths[FIELD_COUNT - 1] = length - starts[FIELD_COUNT - 1];
	for (unsigned i = 0; i < FIELD_COUNT; ++i)
		for (size_t j = 0; j < lengths[i]; ++j)
			if ((unsigned char)fields[i][j] < 0x20 || fields[i][j] == 0x7f)
				return -1;
	if (!valid_username(fields[0]) || lengths[1] > HASH_FIELD_MAX ||
	    lengths[2] >= sizeof(record->uid_text) ||
	    lengths[3] >= sizeof(record->gid_text) || lengths[7] > GECOS_MAX ||
	    lengths[8] > PATH_FIELD_MAX || lengths[9] > PATH_FIELD_MAX)
		return -1;
	uint64_t uid, gid;
	if (parse_uid_gid(fields[2], UINT32_MAX - 1U, &uid) != 0 ||
	    parse_uid_gid(fields[3], UINT32_MAX - 1U, &gid) != 0 ||
	    copy_field(record->name, sizeof(record->name), fields[0], lengths[0]) != 0 ||
	    copy_field(record->hash, sizeof(record->hash), fields[1], lengths[1]) != 0 ||
	    copy_field(record->uid_text, sizeof(record->uid_text), fields[2], lengths[2]) != 0 ||
	    copy_field(record->gid_text, sizeof(record->gid_text), fields[3], lengths[3]) != 0 ||
	    copy_field(record->gecos, sizeof(record->gecos), fields[7], lengths[7]) != 0 ||
	    copy_field(record->home, sizeof(record->home), fields[8], lengths[8]) != 0 ||
	    copy_field(record->shell, sizeof(record->shell), fields[9], lengths[9]) != 0)
		return -1;
	record->uid = (uid_t)uid;
	record->gid = (gid_t)gid;
	record->line_start = line_start;
	record->line_length = length;
	record->hash_start = starts[1];
	record->hash_length = lengths[1];
	return 0;
}

static int
scan_master(const char *bytes, size_t length, const char *wanted_name,
	uid_t wanted_uid, int find_uid, struct account_record *match,
	unsigned *name_count, unsigned *uid_count, char *error, size_t error_size)
{
	size_t start = 0;
	if (name_count)
		*name_count = 0;
	if (uid_count)
		*uid_count = 0;
	while (start < length) {
		size_t end = start;
		while (end < length && bytes[end] != '\n')
			++end;
		size_t line_length = end - start;
		struct account_record record = {0};
		int parsed = parse_account_line(bytes + start, line_length, start, &record);
		if (parsed < 0) {
			set_error(error, error_size, "master.passwd has a malformed or oversized line");
			errno = EINVAL;
			return -1;
		}
		if (parsed == 0) {
			int name_match = wanted_name && strcmp(record.name, wanted_name) == 0;
			int uid_match = find_uid && record.uid == wanted_uid;
			if (name_match && name_count)
				++*name_count;
			if (uid_match && uid_count)
				++*uid_count;
			if (name_match && match)
				*match = record;
		}
		start = end < length ? end + 1 : end;
	}
	return 0;
}

static int
validate_group(const char *bytes, size_t length, gid_t wanted_gid)
{
	size_t start = 0;
	while (start < length) {
		size_t end = start;
		while (end < length && bytes[end] != '\n')
			++end;
		size_t n = end - start;
		if (n > DB_MAX_LINE)
			return -1;
		if (n == 0 || bytes[start] == '#') {
			start = end < length ? end + 1 : end;
			continue;
		}
		char line[DB_MAX_LINE + 1];
		memcpy(line, bytes + start, n);
		line[n] = '\0';
		char *field[4];
		field[0] = line;
		unsigned count = 1;
		for (size_t i = 0; i < n; ++i)
			if (line[i] == ':') {
				if (count >= 4)
					return -1;
				line[i] = '\0';
				field[count++] = line + i + 1;
			}
		if (count != 4 || !field[0][0] || !field[1][0])
			return -1;
		uint64_t gid;
		if (parse_uid_gid(field[2], UINT32_MAX - 1U, &gid) != 0)
			return -1;
		if ((gid_t)gid == wanted_gid)
			return 1;
		start = end < length ? end + 1 : end;
	}
	return 0;
}

static int
derive_public_passwd(const char *master, size_t master_length, char **out,
	size_t *out_length, char *error, size_t error_size)
{
	char *public = malloc(DB_MAX_BYTES + 1);
	if (!public) {
		set_error(error, error_size, "not enough memory to build passwd");
		return -1;
	}
	size_t start = 0, used = 0;
	while (start < master_length) {
		size_t end = start;
		while (end < master_length && master[end] != '\n')
			++end;
		struct account_record record = {0};
		int parsed = parse_account_line(master + start, end - start, start, &record);
		if (parsed < 0) {
			set_error(error, error_size, "master.passwd has a malformed or oversized line");
			free(public);
			return -1;
		}
		if (parsed == 0) {
			char line[DB_MAX_LINE + 1];
			int n = snprintf(line, sizeof(line), "%s:*:%s:%s:%s:%s:%s\n",
			    record.name, record.uid_text, record.gid_text, record.gecos,
			    record.home, record.shell);
			if (n < 0 || (size_t)n >= sizeof(line) ||
			    (size_t)n > DB_MAX_BYTES - used) {
				set_error(error, error_size, "public passwd would be too large");
				free(public);
				return -1;
			}
			memcpy(public + used, line, (size_t)n);
			used += (size_t)n;
		}
		start = end < master_length ? end + 1 : end;
	}
	public[used] = '\0';
	*out = public;
	*out_length = used;
	return 0;
}

static int
load_database(struct at_store *store, struct file_data *master,
	struct file_data *passwd, char *error, size_t error_size)
{
	char *projection = NULL;
	size_t projection_length = 0;
	if (read_file(store, "master.passwd", 0600, master, error, error_size) != 0 ||
	    read_file(store, "passwd", 0644, passwd, error, error_size) != 0)
		goto fail;
	if (derive_public_passwd(master->bytes, master->length, &projection,
	    &projection_length, error, error_size) != 0)
		goto fail;
	if (projection_length != passwd->length ||
	    memcmp(projection, passwd->bytes, projection_length) != 0) {
		/* Recover a half-finished account create from its master-file source. */
		if (atomic_replace(store, "passwd", projection, projection_length,
		    0644, passwd->owner, passwd->group, error, error_size) != 0)
			goto fail;
		free(passwd->bytes);
		passwd->bytes = projection;
		passwd->length = projection_length;
		projection = NULL;
	}
	free(projection);
	return 0;
fail:
	free(projection);
	free_file(master);
	free_file(passwd);
	return -1;
}

/* Restore the public view from whichever master file is present after an error. */
static int
resync_public_passwd(struct at_store *store, const struct file_data *passwd,
	char *error, size_t error_size)
{
	struct file_data current_master = {0};
	char *projection = NULL;
	size_t projection_length = 0;
	int result = -1;
	if (read_file(store, "master.passwd", 0600, &current_master,
	    error, error_size) != 0)
		goto done;
	if (derive_public_passwd(current_master.bytes, current_master.length,
	    &projection, &projection_length, error, error_size) != 0)
		goto done;
	result = atomic_replace(store, "passwd", projection, projection_length,
	    0644, passwd->owner, passwd->group, error, error_size);
done:
	free(projection);
	free_file(&current_master);
	return result;
}

static int
valid_field(const char *text, size_t maximum)
{
	if (!text || !text[0] || strnlen(text, maximum + 1) > maximum)
		return 0;
	for (const unsigned char *p = (const unsigned char *)text; *p; ++p)
		if (*p < 0x20 || *p == 0x7f || *p == ':')
			return 0;
	return 1;
}

static int
valid_optional_field(const char *text, size_t maximum)
{
	if (!text || strnlen(text, maximum + 1) > maximum)
		return 0;
	for (const unsigned char *p = (const unsigned char *)text; *p; ++p)
		if (*p < 0x20 || *p == 0x7f || *p == ':')
			return 0;
	return 1;
}

static int
open_home_root(const char *path, uid_t store_owner, char *error,
	size_t error_size)
{
	struct stat st;
	int fd;

	if (!path || path[0] != '/') {
		set_error(error, error_size, "home root must be an absolute folder path");
		errno = EINVAL;
		return -1;
	}
	if (strcmp(path, "/") != 0)
		return open_directory_path(path, store_owner, error, error_size);

	fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
	if (fd < 0) {
		set_error(error, error_size, "cannot safely open home root: %s",
		    strerror(errno));
		return -1;
	}
	if (fstat(fd, &st) != 0 || !S_ISDIR(st.st_mode) || st.st_uid != 0 ||
	    (st.st_mode & 0022) != 0) {
		set_error(error, error_size, "home root must be a protected root-owned folder");
		close(fd);
		errno = EPERM;
		return -1;
	}
	return fd;
}

static int
open_home_parent(int root_fd, const char *home, uid_t store_owner,
	struct home_directory *directory, char *error, size_t error_size)
{
	char path[PATH_FIELD_MAX + 1];
	size_t length;

	if (!home || home[0] != '/' || home[1] == '\0' ||
	    (length = strnlen(home, sizeof(path))) >= sizeof(path) ||
	    home[length - 1] == '/') {
		set_error(error, error_size, "home must be an absolute path below the home root");
		errno = EINVAL;
		return -1;
	}
	for (size_t start = 1; start < length;) {
		size_t end = start;
		while (end < length && home[end] != '/')
			end++;
		size_t component_length = end - start;
		if (component_length == 0 || component_length > NAME_MAX ||
		    (component_length == 1 && home[start] == '.') ||
		    (component_length == 2 && home[start] == '.' &&
		        home[start + 1] == '.')) {
			set_error(error, error_size, "home path has an unsafe path part");
			errno = EINVAL;
			return -1;
		}
		start = end + 1;
	}
	memcpy(path, home, length + 1);
	char *last_slash = strrchr(path, '/');
	if (!last_slash || strlcpy(directory->leaf, last_slash + 1,
	    sizeof(directory->leaf)) >= sizeof(directory->leaf)) {
		set_error(error, error_size, "home path has an invalid final folder name");
		errno = EINVAL;
		return -1;
	}
	bool parent_is_root = last_slash == path;
	if (!parent_is_root)
		*last_slash = '\0';

	int current = dup(root_fd);
	if (current < 0) {
		set_error(error, error_size, "cannot open home root: %s", strerror(errno));
		return -1;
	}
	if (!parent_is_root) {
		char *component = path + 1;
		for (;;) {
			char *slash = strchr(component, '/');
			if (slash)
				*slash = '\0';
			int child = openat(current, component,
			    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
			if (child < 0) {
				set_error(error, error_size, "cannot safely open home parent: %s",
				    strerror(errno));
				close(current);
				return -1;
			}
			struct stat st;
			if (fstat(child, &st) != 0 || !S_ISDIR(st.st_mode) ||
			    (st.st_uid != 0 && st.st_uid != store_owner) ||
			    ((st.st_mode & 0022) != 0 &&
			        !(st.st_uid == 0 && (st.st_mode & S_ISVTX) != 0))) {
				set_error(error, error_size,
				    "home parent must be a protected folder owned by root or the caller");
				close(child);
				close(current);
				errno = EPERM;
				return -1;
			}
			close(current);
			current = child;
			if (!slash)
				break;
			component = slash + 1;
		}
	}
	directory->parent_fd = current;
	return 0;
}

static int
remove_created_home(struct home_directory *directory, char *error,
	size_t error_size)
{
	struct stat st;
	if (!directory->created)
		return 0;
	if (directory->parent_fd < 0 || !directory->identity_valid ||
	    fstatat(directory->parent_fd, directory->leaf, &st,
	        AT_SYMLINK_NOFOLLOW) != 0 || !S_ISDIR(st.st_mode) ||
	    st.st_dev != directory->device || st.st_ino != directory->inode) {
		set_error(error, error_size,
		    "new home changed before cleanup, so it was left in place");
		errno = ESTALE;
		return -1;
	}
	if (unlinkat(directory->parent_fd, directory->leaf, AT_REMOVEDIR) != 0) {
		set_error(error, error_size, "cannot remove new home: %s", strerror(errno));
		return -1;
	}
	directory->created = false;
	if (fsync(directory->parent_fd) != 0) {
		set_error(error, error_size, "cannot finish removing new home: %s",
		    strerror(errno));
		return -1;
	}
	return 0;
}

/* Return 1 for an empty directory, 0 for a non-empty one, and -1 on error.
 * Open relative to the already checked directory FD so this scan never follows
 * a path that could have been replaced after the ownership check. */
static int
home_directory_is_empty(int home_fd)
{
	int scan_fd = openat(home_fd, ".",
	    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
	if (scan_fd < 0)
		return -1;
	DIR *entries = fdopendir(scan_fd);
	if (!entries) {
		int saved_errno = errno;
		close(scan_fd);
		errno = saved_errno;
		return -1;
	}

	int result = 1;
	errno = 0;
	for (;;) {
		struct dirent *entry = readdir(entries);
		if (!entry) {
			if (errno != 0)
				result = -1;
			break;
		}
		if (strcmp(entry->d_name, ".") != 0 &&
		    strcmp(entry->d_name, "..") != 0) {
			result = 0;
			break;
		}
	}
	int saved_errno = errno;
	if (closedir(entries) != 0 && result == 1)
		result = -1;
	if (result < 0)
		errno = saved_errno ? saved_errno : EIO;
	return result;
}

static int
prepare_home_directory(const char *target_root, const char *home,
	uid_t uid, gid_t gid, uid_t store_owner,
	struct home_directory *directory, char *error, size_t error_size)
{
	struct stat st, opened;
	int root_fd = -1, home_fd = -1, result = -1;

	if (geteuid() != 0 && (uid != geteuid() || gid != getegid())) {
		set_error(error, error_size,
		    "a non-root caller can only create a home for their own account");
		errno = EPERM;
		return -1;
	}
	root_fd = open_home_root(target_root, store_owner, error, error_size);
	if (root_fd < 0)
		goto done;
	if (open_home_parent(root_fd, home, store_owner, directory, error,
	    error_size) != 0)
		goto done;
	if (fstatat(directory->parent_fd, directory->leaf, &st,
	    AT_SYMLINK_NOFOLLOW) == 0) {
		if (!S_ISDIR(st.st_mode) || st.st_uid != uid || st.st_gid != gid ||
		    (st.st_mode & 07777) != 0700) {
			set_error(error, error_size,
			    "existing home must be a real directory owned by the new account with mode 0700");
			errno = EPERM;
			goto done;
		}
		home_fd = openat(directory->parent_fd, directory->leaf,
		    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
		if (home_fd < 0 || fstat(home_fd, &opened) != 0 ||
		    opened.st_dev != st.st_dev || opened.st_ino != st.st_ino ||
		    !S_ISDIR(opened.st_mode) || opened.st_uid != uid ||
		    opened.st_gid != gid || (opened.st_mode & 07777) != 0700) {
			set_error(error, error_size,
			    "existing home changed while it was checked");
			errno = ESTALE;
			goto done;
		}
		int empty = home_directory_is_empty(home_fd);
		if (empty <= 0) {
			if (empty == 0) {
				set_error(error, error_size,
				    "existing home must be empty for a new account");
				errno = ENOTEMPTY;
			} else {
				set_error(error, error_size,
				    "cannot safely check existing home contents: %s",
				    strerror(errno));
			}
			goto done;
		}
		result = 0;
		goto done;
	}
	if (errno != ENOENT) {
		set_error(error, error_size, "cannot check home path: %s", strerror(errno));
		goto done;
	}
	if (mkdirat(directory->parent_fd, directory->leaf, 0700) != 0) {
		set_error(error, error_size, "cannot create home: %s", strerror(errno));
		goto done;
	}
	directory->created = true;
	if (fstatat(directory->parent_fd, directory->leaf, &st,
	    AT_SYMLINK_NOFOLLOW) != 0 || !S_ISDIR(st.st_mode) ||
	    st.st_uid != geteuid()) {
		set_error(error, error_size, "cannot safely identify the new home directory");
		errno = EPERM;
		goto done;
	}
	directory->device = st.st_dev;
	directory->inode = st.st_ino;
	directory->identity_valid = true;
	home_fd = openat(directory->parent_fd, directory->leaf,
	    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
	if (home_fd < 0 || fstat(home_fd, &opened) != 0 ||
	    opened.st_dev != directory->device || opened.st_ino != directory->inode ||
	    !S_ISDIR(opened.st_mode) || fchown(home_fd, uid, gid) != 0 ||
	    fchmod(home_fd, 0700) != 0 || fstat(home_fd, &opened) != 0 ||
	    opened.st_uid != uid || opened.st_gid != gid ||
	    (opened.st_mode & 07777) != 0700 || fsync(home_fd) != 0) {
		set_error(error, error_size, "cannot set new home ownership and mode: %s",
		    strerror(errno));
		goto done;
	}
	if (fsync(directory->parent_fd) != 0) {
		set_error(error, error_size, "cannot finish creating home: %s",
		    strerror(errno));
		goto done;
	}
	result = 0;
done:
	if (home_fd >= 0)
		close(home_fd);
	if (root_fd >= 0)
		close(root_fd);
	return result;
}

static int
account_entry_has_home(struct at_store *store, const char *name, uid_t uid,
	const char *home, char *error, size_t error_size)
{
	struct file_data master = {0};
	struct account_record match = {0};
	unsigned names = 0, uids = 0;
	int result = -1;

	if (read_file(store, "master.passwd", 0600, &master, error,
	    error_size) != 0)
		goto done;
	if (scan_master(master.bytes, master.length, name, uid, 1, &match,
	    &names, &uids, error, error_size) != 0)
		goto done;
	result = names == 1 && uids == 1 && match.uid == uid &&
	    strcmp(match.home, home) == 0;
done:
	free_file(&master);
	return result;
}

static int
at_store_create_user_internal(struct at_store *store, const char *name,
	uid_t uid, gid_t gid, const char *gecos, const char *home,
	const char *shell, const char *password, const char *target_root,
	char *error, size_t error_size)
{
	struct home_directory home_directory = {.parent_fd = -1};
	struct file_data master = {0}, passwd = {0}, group = {0};
	char hash[160] = {0};
	char *new_master = NULL, *new_passwd = NULL;
	size_t new_master_length = 0, new_passwd_length = 0;
	int lock = -1, result = -1;

	if (!store || store->directory_fd < 0 || !valid_username(name) || uid < 500 ||
	    (uint64_t)uid > INT_MAX || (uint64_t)gid > INT_MAX ||
	    !valid_optional_field(gecos, GECOS_MAX) || !valid_field(home, PATH_FIELD_MAX) || home[0] != '/' ||
	    !valid_field(shell, PATH_FIELD_MAX) || shell[0] != '/' ||
	    !at_password_is_acceptable(password) ||
	    (target_root && (!target_root[0] || target_root[0] != '/'))) {
		set_error(error, error_size, "new account details do not meet the local login rules");
		errno = EINVAL;
		return -1;
	}
	lock = lock_store(store, error, error_size);
	if (lock < 0)
		return -1;
	if (load_database(store, &master, &passwd, error, error_size) != 0 ||
	    read_file(store, "group", 0644, &group, error, error_size) != 0)
		goto done;
	int group_exists = validate_group(group.bytes, group.length, gid);
	if (group_exists <= 0) {
		set_error(error, error_size, group_exists == 0 ? "primary group does not exist" : "group file is malformed");
		errno = EINVAL;
		goto done;
	}
	unsigned names = 0, uids = 0;
	if (scan_master(master.bytes, master.length, name, uid, 1, NULL,
	    &names, &uids, error, error_size) != 0)
		goto done;
	if (names || uids) {
		set_error(error, error_size, names ? "account name already exists" : "account id already exists");
		errno = EEXIST;
		goto done;
	}
	if (at_password_hash(password, hash, sizeof(hash)) != 0) {
		set_error(error, error_size, "could not make a secure password hash");
		errno = EIO;
		goto done;
	}
	if (master.length && master.bytes[master.length - 1] != '\n') {
		set_error(error, error_size, "master.passwd must end with a line break");
		errno = EINVAL;
		goto done;
	}
	if (asprintf(&new_master, "%s%s:%s:%u:%u::0:0:%s:%s:%s\n",
	    master.bytes, name, hash, (unsigned)uid, (unsigned)gid, gecos, home, shell) < 0) {
		new_master = NULL;
		set_error(error, error_size, "not enough memory to add account");
		goto done;
	}
	new_master_length = strlen(new_master);
	if (new_master_length > DB_MAX_BYTES || derive_public_passwd(new_master,
	    new_master_length, &new_passwd, &new_passwd_length, error, error_size) != 0)
		goto done;
	if (target_root && prepare_home_directory(target_root, home, uid, gid,
	    store->owner, &home_directory, error, error_size) != 0)
		goto done;
	/* Keep the two account files in sync if either replacement reports failure. */
	if (atomic_replace(store, "passwd", new_passwd, new_passwd_length,
	    0644, passwd.owner, passwd.group, error, error_size) != 0) {
		char original_error[256] = {0}, repair_error[256] = {0};
		if (error && error_size)
			strlcpy(original_error, error, sizeof(original_error));
		if (resync_public_passwd(store, &passwd, repair_error,
		    sizeof(repair_error)) != 0)
			set_error(error, error_size, "%s; could not restore passwd: %s",
			    original_error, repair_error);
		else
			set_error(error, error_size, "%s; passwd was restored from master.passwd",
			    original_error);
		goto done;
	}
	if (atomic_replace(store, "master.passwd", new_master, new_master_length,
	    0600, master.owner, master.group, error, error_size) != 0) {
		char original_error[256] = {0}, repair_error[256] = {0};
		if (error && error_size)
			strlcpy(original_error, error, sizeof(original_error));
		if (resync_public_passwd(store, &passwd, repair_error,
		    sizeof(repair_error)) != 0)
			set_error(error, error_size, "%s; could not sync passwd to master.passwd: %s",
			    original_error, repair_error);
		else
			set_error(error, error_size, "%s; passwd was synced to the saved master.passwd",
			    original_error);
		goto done;
	}
	result = 0;
done:
	if (result != 0 && home_directory.created) {
		char original_error[512] = {0}, state_error[256] = {0};
		if (error && error_size)
			strlcpy(original_error, error, sizeof(original_error));
		int account_state = account_entry_has_home(store, name, uid, home,
		    state_error, sizeof(state_error));
		if (account_state == 0) {
			char cleanup_error[256] = {0};
			if (remove_created_home(&home_directory, cleanup_error,
			    sizeof(cleanup_error)) != 0)
				set_error(error, error_size, "%s; home cleanup failed: %s",
				    original_error, cleanup_error);
			else
				set_error(error, error_size, "%s; the new home was removed",
				    original_error);
		} else {
			if (account_state == 1)
				set_error(error, error_size,
				    "%s; the account may have been saved, so the new home was kept",
				    original_error);
			else
				set_error(error, error_size,
				    "%s; account files could not be checked (%s), so the new home was kept",
				    original_error, state_error);
		}
	}
	if (home_directory.parent_fd >= 0)
		close(home_directory.parent_fd);
	if (lock >= 0)
		close(lock);
	free_file(&master);
	free_file(&passwd);
	free_file(&group);
	free(new_master);
	free(new_passwd);
	at_secure_clear(hash, sizeof(hash));
	return result;
}

int
at_store_create_user(struct at_store *store, const char *name, uid_t uid,
	gid_t gid, const char *gecos, const char *home, const char *shell,
	const char *password, char *error, size_t error_size)
{
	return at_store_create_user_internal(store, name, uid, gid, gecos, home,
	    shell, password, NULL, error, error_size);
}

int
at_store_create_user_with_home_root(struct at_store *store, const char *name,
	uid_t uid, gid_t gid, const char *gecos, const char *home,
	const char *shell, const char *password, const char *target_root,
	char *error, size_t error_size)
{
	if (!target_root) {
		set_error(error, error_size, "home creation needs an explicit target root");
		errno = EINVAL;
		return -1;
	}
	return at_store_create_user_internal(store, name, uid, gid, gecos, home,
	    shell, password, target_root, error, error_size);
}

int
at_store_change_password(struct at_store *store, const char *name,
	uid_t actor_uid, bool root_override, const char *old_password,
	const char *new_password, char *error, size_t error_size)
{
	struct file_data master = {0}, passwd = {0};
	struct account_record target = {0};
	char hash[160] = {0};
	char *new_master = NULL;
	size_t new_master_length;
	unsigned matches = 0;
	int lock = -1, result = -1;

	if (!store || store->directory_fd < 0 || !valid_username(name) ||
	    !at_password_is_acceptable(new_password)) {
		set_error(error, error_size, "password change details do not meet the local login rules");
		errno = EINVAL;
		return -1;
	}
	if (root_override && (actor_uid != 0 || geteuid() != 0)) {
		set_error(error, error_size, "password change caller identity is inconsistent");
		errno = EPERM;
		return -1;
	}
	lock = lock_store(store, error, error_size);
	if (lock < 0)
		return -1;
	if (load_database(store, &master, &passwd, error, error_size) != 0)
		goto done;
	if (scan_master(master.bytes, master.length, name, 0, 0, &target,
	    &matches, NULL, error, error_size) != 0)
		goto done;
	if (matches != 1) {
		set_error(error, error_size, matches == 0 ? "account does not exist" : "account name is repeated");
		errno = matches == 0 ? ENOENT : EINVAL;
		goto done;
	}
	if (target.uid < 500 || target.hash[0] == '*' || target.hash[0] == '!' ||
	    target.hash[0] == '\0') {
		set_error(error, error_size, "locked system accounts cannot be changed here");
		errno = EPERM;
		goto done;
	}
	if (!root_override) {
		if (target.uid != actor_uid || !old_password ||
		    !at_password_verify(old_password, target.hash)) {
			set_error(error, error_size, "current password could not be verified for this account");
			errno = EACCES;
			goto done;
		}
	}
	if (at_password_hash(new_password, hash, sizeof(hash)) != 0) {
		set_error(error, error_size, "could not make a secure password hash");
		errno = EIO;
		goto done;
	}
	if (asprintf(&new_master, "%.*s%s%s",
	    (int)(target.line_start + target.hash_start), master.bytes, hash,
	    master.bytes + target.line_start + target.hash_start + target.hash_length) < 0) {
		new_master = NULL;
		set_error(error, error_size, "not enough memory to update account");
		goto done;
	}
	new_master_length = strlen(new_master);
	if (new_master_length > DB_MAX_BYTES) {
		set_error(error, error_size, "new master.passwd is too large");
		errno = EFBIG;
		goto done;
	}
	if (atomic_replace(store, "master.passwd", new_master, new_master_length,
	    0600, master.owner, master.group, error, error_size) != 0)
		goto done;
	result = 0;
done:
	if (lock >= 0)
		close(lock);
	free_file(&master);
	free_file(&passwd);
	free(new_master);
	at_secure_clear(hash, sizeof(hash));
	return result;
}
