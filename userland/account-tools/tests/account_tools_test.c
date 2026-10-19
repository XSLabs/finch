/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * These tests create a private account folder under /private/tmp. They never
 * read or change the computer's real account files.
 */

#include "../account_tools.h"

#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <unistd.h>

#define TEST_PASSWORD "a long local test password"
#define NEW_PASSWORD "a second long local test password"

#ifdef AT_ACCOUNT_TOOLS_TESTING
extern void at_test_fail_replace(const char *name);
#endif

struct legacy_check {
	const char *password;
	const char *hash;
};

static void *
repeat_legacy_verify(void *argument)
{
	struct legacy_check *check = argument;
	for (int i = 0; i < 100; ++i)
		if (!at_password_verify(check->password, check->hash))
			return (void *)1;
	return NULL;
}

static void
write_file(const char *path, const char *text, mode_t mode)
{
	int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, mode);
	assert(fd >= 0);
	assert(fchmod(fd, mode) == 0);
	size_t length = strlen(text), used = 0;
	while (used < length) {
		ssize_t n = write(fd, text + used, length - used);
		assert(n > 0);
		used += (size_t)n;
	}
	assert(close(fd) == 0);
}

static char *
read_file(const char *path)
{
	struct stat st;
	assert(stat(path, &st) == 0);
	assert(st.st_size >= 0 && st.st_size <= 1024 * 1024);
	int fd = open(path, O_RDONLY);
	assert(fd >= 0);
	char *bytes = calloc((size_t)st.st_size + 1, 1);
	assert(bytes);
	size_t used = 0;
	while (used < (size_t)st.st_size) {
		ssize_t n = read(fd, bytes + used, (size_t)st.st_size - used);
		assert(n > 0);
		used += (size_t)n;
	}
	assert(close(fd) == 0);
	return bytes;
}

static char *
account_hash(const char *master, const char *name)
{
	char prefix[64];
	assert(snprintf(prefix, sizeof(prefix), "%s:", name) < (int)sizeof(prefix));
	const char *start = strstr(master, prefix);
	assert(start);
	start += strlen(prefix);
	const char *end = strchr(start, ':');
	assert(end);
	char *hash = strndup(start, (size_t)(end - start));
	assert(hash);
	return hash;
}

static void
put_fixture(const char *directory, const char *legacy_hash)
{
	char path[1024];
	assert(snprintf(path, sizeof(path), "%s/master.passwd", directory) < (int)sizeof(path));
	char master[4096];
	assert(snprintf(master, sizeof(master),
	    "root:*:0:0::0:0:root:/var/root:/bin/sh\n"
	    "locked:*:501:20::0:0:Locked User:/Users/locked:/bin/sh\n"
	    "legacy:%s:502:20::0:0:Old User:/Users/legacy:/bin/sh\n",
	    legacy_hash) < (int)sizeof(master));
	write_file(path, master, 0600);
	assert(snprintf(path, sizeof(path), "%s/passwd", directory) < (int)sizeof(path));
	write_file(path,
	    "root:*:0:0:root:/var/root:/bin/sh\n"
	    "locked:*:501:20:Locked User:/Users/locked:/bin/sh\n"
	    "legacy:*:502:20:Old User:/Users/legacy:/bin/sh\n", 0644);
	assert(snprintf(path, sizeof(path), "%s/group", directory) < (int)sizeof(path));
	write_file(path, "wheel:*:0:root\nstaff:*:20:root,locked,legacy\n", 0644);
}

static void
copy_release_template(const char *directory, const char *name, mode_t mode)
{
	char source_path[1024], destination_path[1024];
	const char *release_etc = getenv("FINCH_RELEASE_ETC");
	if (!release_etc)
		release_etc = "userland/release/etc";
	assert(snprintf(source_path, sizeof(source_path), "%s/%s", release_etc, name) <
	    (int)sizeof(source_path));
	assert(snprintf(destination_path, sizeof(destination_path), "%s/%s", directory, name) <
	    (int)sizeof(destination_path));
	char *contents = read_file(source_path);
	write_file(destination_path, contents, mode);
	free(contents);
}

static void
write_home_store(const char *directory, gid_t gid)
{
	char path[1024], groups[256];
	assert(snprintf(path, sizeof(path), "%s/master.passwd", directory) <
	    (int)sizeof(path));
	write_file(path, "root:*:0:0::0:0:root:/var/root:/bin/sh\n", 0600);
	assert(snprintf(path, sizeof(path), "%s/passwd", directory) <
	    (int)sizeof(path));
	write_file(path, "root:*:0:0:root:/var/root:/bin/sh\n", 0644);
	assert(snprintf(groups, sizeof(groups), "wheel:*:0:root\nstaff:*:%u:root\n",
	    (unsigned)gid) < (int)sizeof(groups));
	assert(snprintf(path, sizeof(path), "%s/group", directory) <
	    (int)sizeof(path));
	write_file(path, groups, 0644);
}

static void
remove_home_store(const char *directory)
{
	char path[1024];
	const char *names[] = {"master.passwd", "passwd", "group", ".finch-account.lock"};
	for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); ++i) {
		assert(snprintf(path, sizeof(path), "%s/%s", directory, names[i]) <
		    (int)sizeof(path));
		assert(unlink(path) == 0);
	}
	assert(rmdir(directory) == 0);
}

static void
test_home_provisioning(void)
{
	char parent[] = "/private/tmp/finch-account-home.XXXXXX";
	assert(mkdtemp(parent) != NULL);
	char db[1024], existing_db[1024], users[1024], home[1024];
	char blocked_mode[1024], linked_home[1024], linked_parent[1024];
	char foreign_home[1024], sentinel[1024], rollback_home[1024];
	char populated_home[1024], populated_file[1024];
	char provisioned_home[1024], existing_home[1024], error[256] = {0};
	assert(snprintf(db, sizeof(db), "%s/db", parent) < (int)sizeof(db));
	assert(snprintf(existing_db, sizeof(existing_db), "%s/existing-db", parent) <
	    (int)sizeof(existing_db));
	assert(mkdir(db, 0700) == 0);
	assert(mkdir(existing_db, 0700) == 0);
	assert(snprintf(users, sizeof(users), "%s/Users", parent) < (int)sizeof(users));
	assert(mkdir(users, 0700) == 0);
	uid_t home_uid = geteuid() == 0 ? (uid_t)503 : geteuid();
	gid_t home_gid = geteuid() == 0 ? (gid_t)20 : getegid();
	write_home_store(db, home_gid);
	write_home_store(existing_db, home_gid);

	struct at_store store = {.directory_fd = -1};
	assert(at_store_open(&store, db, error, sizeof(error)) == 0);
	assert(snprintf(home, sizeof(home), "%s/Users/denied", parent) <
	    (int)sizeof(home));
	if (geteuid() != 0) {
		memset(error, 0, sizeof(error));
		assert(at_store_create_user_with_home_root(&store, "wrongowner",
		    home_uid + 1, home_gid, "Wrong Owner", "/Users/denied", "/bin/sh",
		    TEST_PASSWORD, parent, error, sizeof(error)) != 0);
		assert(access(home, F_OK) != 0 && errno == ENOENT);
	}

	/* A same-owner folder with unsafe permissions cannot become HOME. */
	assert(snprintf(blocked_mode, sizeof(blocked_mode), "%s/Users/bad-mode",
	    parent) < (int)sizeof(blocked_mode));
	assert(mkdir(blocked_mode, 0755) == 0);
	assert(chmod(blocked_mode, 0755) == 0);
	memset(error, 0, sizeof(error));
	assert(at_store_create_user_with_home_root(&store, "badmode", home_uid,
	    home_gid, "Bad Mode", "/Users/bad-mode", "/bin/sh", TEST_PASSWORD,
	    parent, error, sizeof(error)) != 0);
	assert(stat(blocked_mode, &(struct stat){0}) == 0);

	/* Neither a final symlink nor a symlink in the parent path is followed. */
	assert(snprintf(sentinel, sizeof(sentinel), "%s/sentinel", parent) <
	    (int)sizeof(sentinel));
	write_file(sentinel, "keep this file\n", 0600);
	assert(snprintf(linked_home, sizeof(linked_home), "%s/Users/linked-home",
	    parent) < (int)sizeof(linked_home));
	assert(symlink(sentinel, linked_home) == 0);
	memset(error, 0, sizeof(error));
	assert(at_store_create_user_with_home_root(&store, "linkedhome", home_uid,
	    home_gid, "Linked Home", "/Users/linked-home", "/bin/sh", TEST_PASSWORD,
	    parent, error, sizeof(error)) != 0);
	assert(snprintf(linked_parent, sizeof(linked_parent), "%s/LinkedUsers",
	    parent) < (int)sizeof(linked_parent));
	assert(symlink(users, linked_parent) == 0);
	memset(error, 0, sizeof(error));
	assert(at_store_create_user_with_home_root(&store, "linkedparent", home_uid,
	    home_gid, "Linked Parent", "/LinkedUsers/through-link", "/bin/sh",
	    TEST_PASSWORD, parent, error, sizeof(error)) != 0);
	char *sentinel_contents = read_file(sentinel);
	assert(strcmp(sentinel_contents, "keep this file\n") == 0);
	free(sentinel_contents);
	memset(error, 0, sizeof(error));
	assert(at_store_create_user_with_home_root(&store, "dotpath", home_uid,
	    home_gid, "Dot Path", "/Users/../escape", "/bin/sh", TEST_PASSWORD,
	    parent, error, sizeof(error)) != 0);
	assert(snprintf(home, sizeof(home), "%s/escape", parent) < (int)sizeof(home));
	assert(access(home, F_OK) != 0 && errno == ENOENT);

	/* Refuse a directory that belongs to another account where the test can
	 * safely set up one. Non-root runs still cover bad mode and symlink cases. */
	assert(snprintf(foreign_home, sizeof(foreign_home), "%s/Users/foreign",
	    parent) < (int)sizeof(foreign_home));
	if (geteuid() == 0) {
		assert(mkdir(foreign_home, 0700) == 0);
		assert(chown(foreign_home, 1001, 1001) == 0);
		assert(chmod(foreign_home, 0700) == 0);
		memset(error, 0, sizeof(error));
		assert(at_store_create_user_with_home_root(&store, "foreignhome",
		    home_uid, home_gid, "Foreign Home", "/Users/foreign", "/bin/sh",
		    TEST_PASSWORD, parent, error, sizeof(error)) != 0);
		struct stat foreign_stat;
		assert(stat(foreign_home, &foreign_stat) == 0 &&
		    foreign_stat.st_uid == 1001 && foreign_stat.st_gid == 1001 &&
		    (foreign_stat.st_mode & 07777) == 0700);
	}

	/* Do not attach a new account to a home that already holds user data. */
	assert(snprintf(populated_home, sizeof(populated_home),
	    "%s/Users/populated", parent) < (int)sizeof(populated_home));
	assert(mkdir(populated_home, 0700) == 0);
	assert(chown(populated_home, home_uid, home_gid) == 0);
	assert(chmod(populated_home, 0700) == 0);
	assert(snprintf(populated_file, sizeof(populated_file), "%s/keep.txt",
	    populated_home) < (int)sizeof(populated_file));
	write_file(populated_file, "old home data stays here\n", 0600);
	assert(chown(populated_file, home_uid, home_gid) == 0);
	memset(error, 0, sizeof(error));
	assert(at_store_create_user_with_home_root(&store, "populateduser", home_uid,
	    home_gid, "Populated User", "/Users/populated", "/bin/sh",
	    TEST_PASSWORD, parent, error, sizeof(error)) != 0);
	assert(strstr(error, "must be empty") != NULL);
	char *kept_contents = read_file(populated_file);
	assert(strcmp(kept_contents, "old home data stays here\n") == 0);
	free(kept_contents);
	char home_master_path[1024], home_passwd_path[1024];
	assert(snprintf(home_master_path, sizeof(home_master_path),
	    "%s/master.passwd", db) < (int)sizeof(home_master_path));
	assert(snprintf(home_passwd_path, sizeof(home_passwd_path), "%s/passwd", db) <
	    (int)sizeof(home_passwd_path));
	char *home_master = read_file(home_master_path);
	char *home_passwd = read_file(home_passwd_path);
	assert(strstr(home_master, "populateduser:") == NULL);
	assert(strstr(home_passwd, "populateduser:") == NULL);
	free(home_master);
	free(home_passwd);

	/* A failed account-file update removes only the empty home it just made. */
	assert(snprintf(rollback_home, sizeof(rollback_home), "%s/Users/rollback",
	    parent) < (int)sizeof(rollback_home));
#ifdef AT_ACCOUNT_TOOLS_TESTING
	char master_path[1024];
	at_test_fail_replace("master.passwd");
	memset(error, 0, sizeof(error));
	assert(at_store_create_user_with_home_root(&store, "rollbackuser", home_uid,
	    home_gid, "Rollback User", "/Users/rollback", "/bin/sh", TEST_PASSWORD,
	    parent, error, sizeof(error)) != 0);
	assert(access(rollback_home, F_OK) != 0 && errno == ENOENT);
	assert(snprintf(master_path, sizeof(master_path), "%s/master.passwd", db) <
	    (int)sizeof(master_path));
	char *master = read_file(master_path);
	assert(strstr(master, "rollbackuser:") == NULL);
	free(master);
#endif

	assert(snprintf(provisioned_home, sizeof(provisioned_home),
	    "%s/Users/provisioned", parent) < (int)sizeof(provisioned_home));
	memset(error, 0, sizeof(error));
	assert(at_store_create_user_with_home_root(&store, "provisioned", home_uid,
	    home_gid, "Provisioned User", "/Users/provisioned", "/bin/sh",
	    TEST_PASSWORD, parent, error, sizeof(error)) == 0);
	struct stat home_stat;
	assert(stat(provisioned_home, &home_stat) == 0 && S_ISDIR(home_stat.st_mode));
	assert(home_stat.st_uid == home_uid && home_stat.st_gid == home_gid &&
	    (home_stat.st_mode & 07777) == 0700);
	at_store_close(&store);

	/* A matching, already-owned empty home is accepted without being replaced. */
	assert(snprintf(existing_home, sizeof(existing_home), "%s/Users/existing",
	    parent) < (int)sizeof(existing_home));
	assert(mkdir(existing_home, 0700) == 0);
	assert(chown(existing_home, home_uid, home_gid) == 0);
	assert(chmod(existing_home, 0700) == 0);
	struct at_store existing_store = {.directory_fd = -1};
	assert(at_store_open(&existing_store, existing_db, error, sizeof(error)) == 0);
	assert(at_store_create_user_with_home_root(&existing_store, "existinguser",
	    home_uid, home_gid, "Existing User", "/Users/existing", "/bin/sh",
	    TEST_PASSWORD, parent, error, sizeof(error)) == 0);
	assert(stat(existing_home, &home_stat) == 0 && home_stat.st_uid == home_uid &&
	    home_stat.st_gid == home_gid && (home_stat.st_mode & 07777) == 0700);
	at_store_close(&existing_store);

	assert(unlink(linked_home) == 0);
	assert(unlink(linked_parent) == 0);
	assert(unlink(sentinel) == 0);
	assert(unlink(populated_file) == 0);
	assert(rmdir(blocked_mode) == 0);
	if (geteuid() == 0)
		assert(rmdir(foreign_home) == 0);
	assert(rmdir(populated_home) == 0);
	assert(rmdir(provisioned_home) == 0);
	assert(rmdir(existing_home) == 0);
	assert(rmdir(users) == 0);
	remove_home_store(db);
	remove_home_store(existing_db);
	assert(rmdir(parent) == 0);
}

static void
test_hashes(void)
{
	char hash[160];
	assert(at_password_is_acceptable(TEST_PASSWORD));
	assert(!at_password_is_acceptable("short"));
	assert(at_password_hash("short", hash, sizeof(hash)) != 0);
	assert(at_password_hash(TEST_PASSWORD, hash, sizeof(hash)) == 0);
	assert(strncmp(hash, "$finch$pbkdf2-sha256$600000$",
	    strlen("$finch$pbkdf2-sha256$600000$")) == 0);
	assert(at_password_verify(TEST_PASSWORD, hash));
	assert(!at_password_verify("wrong password", hash));
	assert(!at_password_verify(TEST_PASSWORD,
	    "$finch$pbkdf2-sha256$999999999999999999999$00000000000000000000000000000000$0000000000000000000000000000000000000000000000000000000000000000"));
	assert(!at_password_verify(TEST_PASSWORD, "*"));
	assert(!at_password_verify(TEST_PASSWORD, "!locked"));
	char maximum_password[AT_PASSWORD_MAX + 1];
	memset(maximum_password, 'x', AT_PASSWORD_MAX);
	maximum_password[AT_PASSWORD_MAX] = '\0';
	assert(at_password_is_acceptable(maximum_password));
	assert(at_password_hash(maximum_password, hash, sizeof(hash)) == 0);
	assert(at_password_verify(maximum_password, hash));
	char too_long_password[AT_PASSWORD_MAX + 2];
	memset(too_long_password, 'x', sizeof(too_long_password) - 1);
	too_long_password[sizeof(too_long_password) - 1] = '\0';
	assert(!at_password_is_acceptable(too_long_password));
	at_secure_clear(too_long_password, sizeof(too_long_password));
	at_secure_clear(maximum_password, sizeof(maximum_password));
	at_secure_clear(hash, sizeof(hash));
}

static void
test_default_store_selection(void)
{
	char parent[] = "/private/tmp/finch-account-default.XXXXXX";
	char configured[1024], legacy[1024], settings[1024], setting[1024];
	char writable_settings[1024], writable_setting[1024];
	char linked_setting[1024], linked_settings[1024], missing_setting[1024];
	char error[256] = {0};
	assert(mkdtemp(parent) != NULL);
	assert(snprintf(configured, sizeof(configured), "%s/configured", parent) <
	    (int)sizeof(configured));
	assert(snprintf(legacy, sizeof(legacy), "%s/legacy", parent) <
	    (int)sizeof(legacy));
	assert(snprintf(settings, sizeof(settings), "%s/settings", parent) <
	    (int)sizeof(settings));
	assert(snprintf(writable_settings, sizeof(writable_settings),
	    "%s/writable-settings", parent) < (int)sizeof(writable_settings));
	assert(snprintf(setting, sizeof(setting), "%s/account-store", settings) <
	    (int)sizeof(setting));
	assert(snprintf(writable_setting, sizeof(writable_setting),
	    "%s/account-store", writable_settings) < (int)sizeof(writable_setting));
	assert(snprintf(linked_setting, sizeof(linked_setting), "%s/setting-link", parent) <
	    (int)sizeof(linked_setting));
	assert(snprintf(linked_settings, sizeof(linked_settings), "%s/settings-link", parent) <
	    (int)sizeof(linked_settings));
	assert(snprintf(missing_setting, sizeof(missing_setting),
	    "%s/missing/settings/account-store", parent) < (int)sizeof(missing_setting));
	assert(mkdir(configured, 0700) == 0);
	assert(mkdir(legacy, 0700) == 0);
	assert(mkdir(settings, 0700) == 0);
	assert(mkdir(writable_settings, 0700) == 0);
	write_home_store(configured, getegid());
	write_home_store(legacy, getegid());

	char configured_setting[1100];
	assert(snprintf(configured_setting, sizeof(configured_setting), "%s\n", configured) <
	    (int)sizeof(configured_setting));
	write_file(setting, configured_setting, 0644);
	struct at_store store = {.directory_fd = -1};
	assert(at_test_store_open_default(&store, setting, legacy, geteuid(), error,
	    sizeof(error)) == 0);
	assert(at_store_create_user(&store, "durableuser", 503, (gid_t)getegid(),
	    "Durable User", "/Users/durableuser", "/bin/sh", TEST_PASSWORD,
	    error, sizeof(error)) == 0);
	at_store_close(&store);
	char path[1200];
	assert(snprintf(path, sizeof(path), "%s/master.passwd", configured) <
	    (int)sizeof(path));
	char *master = read_file(path);
	assert(strstr(master, "durableuser:") != NULL);
	free(master);
	assert(snprintf(path, sizeof(path), "%s/master.passwd", legacy) <
	    (int)sizeof(path));
	master = read_file(path);
	assert(strstr(master, "durableuser:") == NULL);
	free(master);

	/* A missing setting parent and a missing setting file both keep old images working. */
	assert(at_test_store_open_default(&store, missing_setting, legacy, geteuid(),
	    error, sizeof(error)) == 0);
	assert(error[0] == '\0');
	assert(at_store_create_user(&store, "legacyuser", 504, (gid_t)getegid(),
	    "Legacy User", "/Users/legacyuser", "/bin/sh", TEST_PASSWORD,
	    error, sizeof(error)) == 0);
	at_store_close(&store);
	assert(unlink(setting) == 0);
	memset(error, 0, sizeof(error));
	assert(at_test_store_open_default(&store, setting, legacy, geteuid(), error,
	    sizeof(error)) == 0);
	at_store_close(&store);

	/* A present but unsafe setting never falls back to the legacy files. */
	write_file(setting, configured_setting, 0664);
	memset(error, 0, sizeof(error));
	assert(at_test_store_open_default(&store, setting, legacy, geteuid(), error,
	    sizeof(error)) != 0);
	assert(error[0] != '\0');
	assert(unlink(setting) == 0);

	/* FIFO settings are rejected quickly instead of blocking on open. */
	assert(mkfifo(setting, 0644) == 0);
	pid_t child = fork();
	assert(child >= 0);
	if (child == 0) {
		alarm(2);
		struct at_store fifo_store = {.directory_fd = -1};
		char child_error[256] = {0};
		int status = at_test_store_open_default(&fifo_store, setting, legacy,
		    geteuid(), child_error, sizeof(child_error));
		if (status == 0)
			at_store_close(&fifo_store);
		_exit(status == 0 ? 1 : 0);
	}
	int child_status = 0;
	pid_t waited;
	do {
		waited = waitpid(child, &child_status, 0);
	} while (waited < 0 && errno == EINTR);
	assert(waited == child);
	assert(WIFEXITED(child_status) && WEXITSTATUS(child_status) == 0);
	assert(unlink(setting) == 0);

	/* An unsafe parent is an error even when a usable legacy folder exists. */
	assert(chmod(writable_settings, 0777) == 0);
	write_file(writable_setting, configured_setting, 0644);
	memset(error, 0, sizeof(error));
	assert(at_test_store_open_default(&store, writable_setting, legacy,
	    geteuid(), error, sizeof(error)) != 0);
	assert(error[0] != '\0');
	assert(unlink(writable_setting) == 0);
	assert(chmod(writable_settings, 0700) == 0);
	assert(rmdir(writable_settings) == 0);

	assert(symlink(configured, linked_setting) == 0);
	memset(error, 0, sizeof(error));
	assert(at_test_store_open_default(&store, linked_setting, legacy, geteuid(),
	    error, sizeof(error)) != 0);
	assert(error[0] != '\0');
	assert(unlink(linked_setting) == 0);
	assert(symlink(settings, linked_settings) == 0);
	char linked_parent_setting[1100];
	assert(snprintf(linked_parent_setting, sizeof(linked_parent_setting),
	    "%s/account-store", linked_settings) < (int)sizeof(linked_parent_setting));
	memset(error, 0, sizeof(error));
	assert(at_test_store_open_default(&store, linked_parent_setting, legacy,
	    geteuid(), error, sizeof(error)) != 0);
	assert(error[0] != '\0');
	assert(unlink(linked_settings) == 0);

	/* Traversal components in the configured destination are rejected. */
	assert(snprintf(configured_setting, sizeof(configured_setting), "%s/../legacy\n",
	    configured) < (int)sizeof(configured_setting));
	write_file(setting, configured_setting, 0644);
	memset(error, 0, sizeof(error));
	assert(at_test_store_open_default(&store, setting, legacy, geteuid(), error,
	    sizeof(error)) != 0);
	assert(error[0] != '\0');
	assert(unlink(setting) == 0);

	remove_home_store(configured);
	remove_home_store(legacy);
	assert(rmdir(settings) == 0);
	assert(rmdir(parent) == 0);
}

int
main(void)
{
	char legacy_password[] = "old local password";
	const char *legacy_hash = crypt(legacy_password, "ab");
	assert(legacy_hash && strlen(legacy_hash) == 13);
	char legacy_copy[32];
	strlcpy(legacy_copy, legacy_hash, sizeof(legacy_copy));
	assert(at_password_verify(legacy_password, legacy_copy));
	assert(!at_password_verify("wrong local password", legacy_copy));
	struct legacy_check check = {legacy_password, legacy_copy};
	pthread_t verifiers[4];
	for (size_t i = 0; i < sizeof(verifiers) / sizeof(verifiers[0]); ++i)
		assert(pthread_create(&verifiers[i], NULL, repeat_legacy_verify, &check) == 0);
	for (size_t i = 0; i < sizeof(verifiers) / sizeof(verifiers[0]); ++i) {
		void *thread_result = NULL;
		assert(pthread_join(verifiers[i], &thread_result) == 0);
		assert(thread_result == NULL);
	}

	test_hashes();
	test_home_provisioning();
	test_default_store_selection();

	char error[256] = {0};
	char parent[] = "/private/tmp/finch-account-tools.XXXXXX";
	assert(mkdtemp(parent) != NULL);
	char directory[1024], linked[1024], master_path[1024], passwd_path[1024];
	assert(snprintf(directory, sizeof(directory), "%s/db", parent) < (int)sizeof(directory));
	assert(mkdir(directory, 0700) == 0);
	assert(snprintf(linked, sizeof(linked), "%s/link", parent) < (int)sizeof(linked));
	assert(symlink(directory, linked) == 0);
	put_fixture(directory, legacy_copy);
	assert(chmod(parent, 0777) == 0);
	assert(at_store_open(&(struct at_store){.directory_fd = -1}, directory,
	    error, sizeof(error)) != 0);
	assert(chmod(parent, 0700) == 0);

	struct at_store store = {.directory_fd = -1};
	assert(at_store_open(&store, linked, error, sizeof(error)) != 0);
	memset(error, 0, sizeof(error));
	assert(at_store_open(&store, directory, error, sizeof(error)) == 0);
	assert(snprintf(master_path, sizeof(master_path), "%s/master.passwd", directory) < (int)sizeof(master_path));
	assert(snprintf(passwd_path, sizeof(passwd_path), "%s/passwd", directory) < (int)sizeof(passwd_path));

	assert(at_store_create_user(&store, "newuser", 503, 20, "New User",
	    "/Users/newuser", "/bin/sh", TEST_PASSWORD, error, sizeof(error)) == 0);
	char *master = read_file(master_path);
	char *passwd = read_file(passwd_path);
	assert(strstr(master, "newuser:$finch$pbkdf2-sha256$600000$") != NULL);
	assert(strstr(passwd, "newuser:*:503:20:New User:/Users/newuser:/bin/sh\n") != NULL);
	assert(strstr(passwd, "$finch$") == NULL);
	struct stat st;
	assert(stat(master_path, &st) == 0 && (st.st_mode & 0777) == 0600);
	assert(stat(passwd_path, &st) == 0 && (st.st_mode & 0777) == 0644);
	char *new_hash = account_hash(master, "newuser");
	assert(at_password_verify(TEST_PASSWORD, new_hash));
	free(new_hash);

	/* A failure on the second file must roll the first file back to the saved master. */
#ifdef AT_ACCOUNT_TOOLS_TESTING
	char *before_failed_create_master = read_file(master_path);
	char *before_failed_create_passwd = read_file(passwd_path);
	at_test_fail_replace("master.passwd");
	memset(error, 0, sizeof(error));
	assert(at_store_create_user(&store, "rollbackuser", 504, 20, "Rollback User",
	    "/Users/rollbackuser", "/bin/sh", TEST_PASSWORD, error, sizeof(error)) != 0);
	char *after_failed_create_master = read_file(master_path);
	char *after_failed_create_passwd = read_file(passwd_path);
	assert(strcmp(after_failed_create_master, before_failed_create_master) == 0);
	assert(strcmp(after_failed_create_passwd, before_failed_create_passwd) == 0);
	assert(strstr(after_failed_create_master, "rollbackuser:") == NULL);
	assert(strstr(after_failed_create_passwd, "rollbackuser:") == NULL);
	free(after_failed_create_master);
	free(after_failed_create_passwd);
	free(before_failed_create_master);
	free(before_failed_create_passwd);
#endif

	/* A half-written public view is repaired from master.passwd under the lock. */
	char *valid_passwd = strdup(passwd);
	assert(valid_passwd);
	char *ahead = malloc(strlen(passwd) + 40);
	assert(ahead);
	sprintf(ahead, "%sghost:*:900:20:Ghost:/ghost:/bin/sh\n", passwd);
	write_file(passwd_path, ahead, 0644);
	char *before_master = strdup(master);
	assert(before_master);
	memset(error, 0, sizeof(error));
	assert(at_store_change_password(&store, "newuser", 503, false,
	    "wrong current password", NEW_PASSWORD, error, sizeof(error)) != 0);
	char *repaired = read_file(passwd_path);
	char *after_failed_change = read_file(master_path);
	assert(strcmp(repaired, valid_passwd) == 0);
	assert(strcmp(after_failed_change, before_master) == 0);
	assert(strstr(repaired, "ghost:") == NULL);

	/* Wrong old password and another user's id cannot replace the master file. */
	memset(error, 0, sizeof(error));
	assert(at_store_change_password(&store, "newuser", 503, false,
	    "wrong current password", NEW_PASSWORD, error, sizeof(error)) != 0);
	free(after_failed_change);
	after_failed_change = read_file(master_path);
	assert(strcmp(after_failed_change, before_master) == 0);
	assert(at_store_change_password(&store, "newuser", 504, false,
	    TEST_PASSWORD, NEW_PASSWORD, error, sizeof(error)) != 0);
	uid_t mismatched_actor = getuid() == 0 ? (uid_t)1 : getuid();
	assert(at_store_change_password(&store, "newuser", mismatched_actor, true,
	    NULL, NEW_PASSWORD, error, sizeof(error)) != 0);
	if (geteuid() != 0)
		assert(at_store_change_password(&store, "newuser", 0, true,
		    NULL, NEW_PASSWORD, error, sizeof(error)) != 0);
	assert(at_store_change_password(&store, "root", 0, true,
	    NULL, NEW_PASSWORD, error, sizeof(error)) != 0);
	assert(at_store_change_password(&store, "locked", 0, true,
	    NULL, NEW_PASSWORD, error, sizeof(error)) != 0);

	assert(at_store_change_password(&store, "newuser", 503, false,
	    TEST_PASSWORD, NEW_PASSWORD, error, sizeof(error)) == 0);
	free(master);
	master = read_file(master_path);
	assert(strstr(master, "newuser:$finch$pbkdf2-sha256$600000$") != NULL);
	new_hash = account_hash(master, "newuser");
	assert(at_password_verify(NEW_PASSWORD, new_hash));
	assert(!at_password_verify(TEST_PASSWORD, new_hash));
	free(new_hash);
	char *after_change_passwd = read_file(passwd_path);
	assert(strcmp(after_change_passwd, valid_passwd) == 0);

	/* Duplicate names, duplicate ids, weak passwords and missing groups fail. */
	assert(at_store_create_user(&store, "newuser", 504, 20, "Other",
	    "/Users/other", "/bin/sh", TEST_PASSWORD, error, sizeof(error)) != 0);
	assert(at_store_create_user(&store, "other", 503, 20, "Other",
	    "/Users/other", "/bin/sh", TEST_PASSWORD, error, sizeof(error)) != 0);
	assert(at_store_create_user(&store, "other", 504, 999, "Other",
	    "/Users/other", "/bin/sh", TEST_PASSWORD, error, sizeof(error)) != 0);
	assert(at_store_create_user(&store, "other", 504, 20, "Other",
	    "/Users/other", "/bin/sh", "short", error, sizeof(error)) != 0);
	assert(at_store_create_user(&store, "reserved", (uid_t)UINT32_MAX, 20,
	    "Other", "/Users/other", "/bin/sh", TEST_PASSWORD, error, sizeof(error)) != 0);
	assert(at_store_create_user(&store, "nobodyid", (uid_t)(UINT32_MAX - 1U), 20,
	    "Other", "/Users/other", "/bin/sh", TEST_PASSWORD, error, sizeof(error)) != 0);
	assert(at_store_create_user(&store, "widegid", 504, (gid_t)UINT32_MAX,
	    "Other", "/Users/other", "/bin/sh", TEST_PASSWORD, error, sizeof(error)) != 0);
	assert(at_store_create_user(&store, "wideuid", (uid_t)((uint64_t)INT_MAX + 1),
	    20, "Other", "/Users/other", "/bin/sh", TEST_PASSWORD,
	    error, sizeof(error)) != 0);
	assert(at_store_create_user(&store, "widegid", 504,
	    (gid_t)((uint64_t)INT_MAX + 1), "Other", "/Users/other", "/bin/sh",
	    TEST_PASSWORD, error, sizeof(error)) != 0);

	/* A linked master file is refused without reading its target. */
	char backup_path[1024], secret_path[1024];
	assert(snprintf(backup_path, sizeof(backup_path), "%s/master.backup", directory) < (int)sizeof(backup_path));
	assert(snprintf(secret_path, sizeof(secret_path), "%s/secret", parent) < (int)sizeof(secret_path));
	write_file(secret_path, "leave this alone\n", 0600);
	assert(rename(master_path, backup_path) == 0);
	assert(symlink(secret_path, master_path) == 0);
	assert(at_store_change_password(&store, "newuser", 503, false,
	    NEW_PASSWORD, TEST_PASSWORD, error, sizeof(error)) != 0);
	char *secret = read_file(secret_path);
	assert(strcmp(secret, "leave this alone\n") == 0);
	assert(unlink(master_path) == 0);
	assert(rename(backup_path, master_path) == 0);

	at_store_close(&store);
	free(secret);
	free(after_change_passwd);
	free(after_failed_change);
	free(before_master);
	free(ahead);
	free(valid_passwd);
	free(repaired);
	free(master);
	free(passwd);
	assert(unlink(linked) == 0);
	assert(unlink(secret_path) == 0);
	assert(unlink(master_path) == 0);
	assert(unlink(passwd_path) == 0);
	char group_path[1024], lock_path[1024];
	assert(snprintf(group_path, sizeof(group_path), "%s/group", directory) < (int)sizeof(group_path));
	assert(snprintf(lock_path, sizeof(lock_path), "%s/.finch-account.lock", directory) < (int)sizeof(lock_path));
	assert(unlink(group_path) == 0);
	assert(unlink(lock_path) == 0);
	assert(rmdir(directory) == 0);

	/* Run the checked-in release account files through the same parser and writer. */
	char release_directory[1024], release_master_path[1024], release_passwd_path[1024];
	assert(snprintf(release_directory, sizeof(release_directory), "%s/release", parent) <
	    (int)sizeof(release_directory));
	assert(mkdir(release_directory, 0700) == 0);
	copy_release_template(release_directory, "master.passwd", 0600);
	copy_release_template(release_directory, "group", 0644);
	assert(snprintf(release_master_path, sizeof(release_master_path), "%s/master.passwd",
	    release_directory) < (int)sizeof(release_master_path));
	assert(snprintf(release_passwd_path, sizeof(release_passwd_path), "%s/passwd",
	    release_directory) < (int)sizeof(release_passwd_path));
	write_file(release_passwd_path,
	    "root:*:0:0:System Administrator:/var/root:/bin/zsh\n"
	    "daemon:*:1:1:System Services:/var/root:/sbin/nologin\n"
	    "nobody:*:-2:-2:Unprivileged User:/var/empty:/sbin/nologin\n", 0644);
	struct at_store release_store = {.directory_fd = -1};
	assert(at_store_open(&release_store, release_directory, error, sizeof(error)) == 0);
	assert(at_store_create_user(&release_store, "releaseuser", 503, 20,
	    "Release User", "/Users/releaseuser", "/bin/zsh", TEST_PASSWORD,
	    error, sizeof(error)) == 0);
	char *release_master = read_file(release_master_path);
	char *release_passwd = read_file(release_passwd_path);
	assert(strstr(release_master,
	    "nobody:*:-2:-2::0:0:Unprivileged User:/var/empty:/sbin/nologin\n") != NULL);
	assert(strstr(release_passwd,
	    "nobody:*:-2:-2:Unprivileged User:/var/empty:/sbin/nologin\n") != NULL);
	free(release_master);
	free(release_passwd);
	at_store_close(&release_store);
	assert(unlink(release_master_path) == 0);
	assert(unlink(release_passwd_path) == 0);
	char release_group_path[1024], release_lock_path[1024];
	assert(snprintf(release_group_path, sizeof(release_group_path), "%s/group",
	    release_directory) < (int)sizeof(release_group_path));
	assert(snprintf(release_lock_path, sizeof(release_lock_path), "%s/.finch-account.lock",
	    release_directory) < (int)sizeof(release_lock_path));
	assert(unlink(release_group_path) == 0);
	assert(unlink(release_lock_path) == 0);
	assert(rmdir(release_directory) == 0);
	assert(rmdir(parent) == 0);
	puts("account tools fixture tests passed");
	return 0;
}
