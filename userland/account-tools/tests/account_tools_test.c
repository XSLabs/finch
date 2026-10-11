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
