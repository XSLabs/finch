/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Exercise Finch's real local password checks in a disposable account root.
 * This program must only run as root inside a Finch VM. It loads Finch's PAM,
 * account, and OpenDirectory code before entering the fixture, then chroots
 * into a new root under /private/var/rw. It never runs another program there.
 */

#include "../account-tools/account_tools.h"

#include <CFOpenDirectory/CFOpenDirectory.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <security/pam_appl.h>
#include <pwd.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define FIXTURE_PARENT "/private/var/rw"
#define RELEASE_ACCOUNT_FIXTURE "/usr/local/share/finch/account-fixture"
#define PAM_SERVICE "finch-account-login-test"
#define PAM_MODULE_SOURCE "/usr/lib/pam/pam_unix.so.2"
#define PAM_DENY_SOURCE "/usr/lib/pam/pam_deny.so.2"
#define TEST_PASSWORD "Finch local password test 2026"
#define WRONG_PASSWORD "Finch wrong password test 2026"
#define TEST_UID_BASE 5000

struct prompt_state {
	const char *password;
};

static int
conversation(int count, const struct pam_message **messages,
	struct pam_response **responses, void *data)
{
	struct prompt_state *state = data;
	struct pam_response *answer;
	if (count != 1 || !messages || !messages[0] || !responses || !state ||
	    (messages[0]->msg_style != PAM_PROMPT_ECHO_OFF &&
	     messages[0]->msg_style != PAM_PROMPT_ECHO_ON))
		return PAM_CONV_ERR;
	answer = calloc(1, sizeof(*answer));
	if (!answer)
		return PAM_BUF_ERR;
	answer->resp = strdup(state->password);
	if (!answer->resp) {
		free(answer);
		return PAM_BUF_ERR;
	}
	*responses = answer;
	return PAM_SUCCESS;
}

static bool
finch_vm(void)
{
	return geteuid() == 0 && access("/etc/finch/rc", R_OK) == 0 &&
	    access("/System/Library/Finch/LaunchDaemons/com.apple.SystemConfiguration.configd.plist",
	        R_OK) == 0;
}

static bool
make_directory(const char *path, mode_t mode)
{
	return mkdir(path, mode) == 0 && chmod(path, mode) == 0;
}

static bool
write_file(const char *path, const char *bytes, mode_t mode)
{
	size_t length = strlen(bytes), used = 0;
	int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
	    mode);
	if (fd < 0)
		return false;
	if (fchmod(fd, mode) != 0) {
		close(fd);
		return false;
	}
	while (used < length) {
		ssize_t n = write(fd, bytes + used, length - used);
		if (n < 0 && errno == EINTR)
			continue;
		if (n <= 0) {
			close(fd);
			return false;
		}
		used += (size_t)n;
	}
	return close(fd) == 0;
}

static bool
copy_file(const char *source, const char *destination, mode_t mode,
	bool replace, bool source_must_be_root)
{
	struct stat st;
	char buffer[8192];
	int input = open(source, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
	if (input < 0 || fstat(input, &st) != 0 || !S_ISREG(st.st_mode) ||
	    (source_must_be_root && st.st_uid != 0) || (st.st_mode & 0022) != 0) {
		if (input >= 0)
			close(input);
		return false;
	}
	int flags = O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC |
	    (replace ? O_TRUNC : O_EXCL);
	int output = open(destination, flags, mode);
	if (output < 0 || fchmod(output, mode) != 0) {
		if (output >= 0)
			close(output);
		close(input);
		return false;
	}
	for (;;) {
		ssize_t n = read(input, buffer, sizeof(buffer));
		if (n < 0 && errno == EINTR)
			continue;
		if (n < 0) {
			close(input);
			close(output);
			return false;
		}
		if (n == 0)
			break;
		ssize_t used = 0;
		while (used < n) {
			ssize_t written = write(output, buffer + used,
			    (size_t)(n - used));
			if (written < 0 && errno == EINTR)
				continue;
			if (written <= 0) {
				close(input);
				close(output);
				return false;
			}
			used += written;
		}
	}
	return close(input) == 0 && close(output) == 0;
}

static bool
read_small_file(const char *path, char *buffer, size_t capacity,
	mode_t expected_mode)
{
	struct stat st;
	int fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
	if (fd < 0 || fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) ||
	    (st.st_mode & 07777) != expected_mode || st.st_size < 0 ||
	    (uint64_t)st.st_size >= capacity) {
		if (fd >= 0)
			close(fd);
		return false;
	}
	size_t used = 0;
	while (used < (size_t)st.st_size) {
		ssize_t n = read(fd, buffer + used, (size_t)st.st_size - used);
		if (n < 0 && errno == EINTR)
			continue;
		if (n <= 0) {
			close(fd);
			return false;
		}
		used += (size_t)n;
	}
	buffer[used] = '\0';
	return close(fd) == 0;
}

/* Keep any existing VM user or password out of the copied fixture. */
static bool
release_accounts_are_locked(void)
{
	char bytes[65536];
	char path[PATH_MAX];
	unsigned seen = 0;
	if (snprintf(path, sizeof(path), "%s/master.passwd",
	    RELEASE_ACCOUNT_FIXTURE) >= (int)sizeof(path) ||
	    !read_small_file(path, bytes, sizeof(bytes), 0644))
		return false;
	for (char *line = bytes; *line;) {
		char *end = strchr(line, '\n');
		if (end)
			*end = '\0';
		if (*line && *line != '#') {
			char *colon = strchr(line, ':');
			if (!colon)
				return false;
			*colon++ = '\0';
			char *hash_end = strchr(colon, ':');
			if (!hash_end)
				return false;
			*hash_end = '\0';
			if (strcmp(colon, "*") != 0)
				return false;
			if (strcmp(line, "root") == 0)
				seen |= 1;
			else if (strcmp(line, "daemon") == 0)
				seen |= 2;
			else if (strcmp(line, "nobody") == 0)
				seen |= 4;
			else
				return false;
		}
		if (!end)
			break;
		line = end + 1;
	}
	return seen == 7;
}

static bool
remove_contents(int directory_fd)
{
	int duplicate = dup(directory_fd);
	if (duplicate < 0)
		return false;
	DIR *directory = fdopendir(duplicate);
	if (!directory) {
		close(duplicate);
		return false;
	}
	bool ok = true;
	struct dirent *entry;
	while ((entry = readdir(directory)) != NULL) {
		if (strcmp(entry->d_name, ".") == 0 ||
		    strcmp(entry->d_name, "..") == 0)
			continue;
		struct stat st;
		if (fstatat(directory_fd, entry->d_name, &st, AT_SYMLINK_NOFOLLOW) != 0) {
			ok = false;
			continue;
		}
		if (S_ISDIR(st.st_mode)) {
			int child = openat(directory_fd, entry->d_name,
			    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
			if (child < 0 || !remove_contents(child) ||
			    unlinkat(directory_fd, entry->d_name, AT_REMOVEDIR) != 0)
				ok = false;
			if (child >= 0)
				close(child);
		} else if (unlinkat(directory_fd, entry->d_name, 0) != 0) {
			ok = false;
		}
	}
	if (closedir(directory) != 0)
		ok = false;
	return ok;
}

static bool
remove_fixture(int parent_fd, const char *leaf)
{
	int root = openat(parent_fd, leaf,
	    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
	if (root < 0)
		return errno == ENOENT;
	bool ok = remove_contents(root);
	close(root);
	if (unlinkat(parent_fd, leaf, AT_REMOVEDIR) != 0)
		ok = false;
	return ok;
}

static bool
pam_check(const char *user, const char *password, int expected)
{
	struct prompt_state state = { password };
	struct pam_conv conv = { conversation, &state };
	pam_handle_t *handle = NULL;
	int result = pam_start(PAM_SERVICE, user, &conv, &handle);
	if (result == PAM_SUCCESS)
		result = pam_authenticate(handle, 0);
	if (handle)
		(void)pam_end(handle, result);
	return result == expected;
}

static bool
directory_check(const char *user, const char *password, bool expected)
{
	ODSessionRef session = ODSessionCreate(kCFAllocatorDefault, NULL, NULL);
	if (!session)
		return false;
	ODNodeRef node = ODNodeCreateWithNodeType(kCFAllocatorDefault, session,
	    kODNodeTypeAuthentication, NULL);
	if (!node) {
		CFRelease(session);
		return false;
	}
	CFStringRef name = CFStringCreateWithCString(kCFAllocatorDefault, user,
	    kCFStringEncodingUTF8);
	CFStringRef token = CFStringCreateWithCString(kCFAllocatorDefault, password,
	    kCFStringEncodingUTF8);
	ODRecordRef record = name ? ODNodeCopyRecord(node, kODRecordTypeUsers,
	    name, NULL, NULL) : NULL;
	bool result = false;
	if (record && token)
		result = ODRecordVerifyPassword(record, token, NULL) == expected;
	if (record)
		CFRelease(record);
	if (token)
		CFRelease(token);
	if (name)
		CFRelease(name);
	CFRelease(node);
	CFRelease(session);
	return result;
}

int
main(void)
{
	char fixture[] = FIXTURE_PARENT "/account-login-test.XXXXXX";
	char leaf[NAME_MAX + 1] = {0};
	char path[PATH_MAX];
	char home[PATH_MAX];
	char error[256] = {0};
	char username[32];
	struct at_store store = { .directory_fd = -1 };
	void *pam_module = NULL;
	void *pam_deny = NULL;
	int parent_fd = -1, root_fd = -1;
	bool entered = false, ok = false;
	int status = 1;
	struct stat st;

	if (!finch_vm()) {
		fputs("account login test only runs as root inside a Finch VM\n", stderr);
		return 1;
	}
	parent_fd = open(FIXTURE_PARENT,
	    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
	if (parent_fd < 0 || fstat(parent_fd, &st) != 0 || st.st_uid != 0 ||
	    (st.st_mode & 0022) != 0 || !release_accounts_are_locked()) {
		fputs("account login test needs Finch's locked release account files\n", stderr);
		goto done;
	}
	if (!mkdtemp(fixture) || chmod(fixture, 0700) != 0) {
		perror("account login test fixture");
		goto done;
	}
	const char *last_slash = strrchr(fixture, '/');
	if (!last_slash || strlen(last_slash + 1) >= sizeof(leaf))
		goto done;
	strlcpy(leaf, last_slash + 1, sizeof(leaf));
	if (!make_directory(strcat(strcpy(path, fixture), "/etc"), 0755) ||
	    !make_directory(strcat(strcpy(path, fixture), "/etc/pam.d"), 0755) ||
	    !make_directory(strcat(strcpy(path, fixture), "/Users"), 0755) ||
	    !make_directory(strcat(strcpy(path, fixture), "/private"), 0755) ||
	    !make_directory(strcat(strcpy(path, fixture), "/private/etc"), 0755) ||
	    !make_directory(strcat(strcpy(path, fixture), "/usr"), 0755) ||
	    !make_directory(strcat(strcpy(path, fixture), "/usr/lib"), 0755) ||
	    !make_directory(strcat(strcpy(path, fixture), "/usr/lib/pam"), 0755)) {
		perror("account login test folders");
		goto done;
	}
	const char *accounts[] = { "master.passwd", "group" };
	const mode_t modes[] = { 0600, 0644 };
	for (size_t i = 0; i < sizeof(accounts) / sizeof(accounts[0]); ++i) {
		char source[PATH_MAX], destination[PATH_MAX];
		if (snprintf(source, sizeof(source), "%s/%s",
		    RELEASE_ACCOUNT_FIXTURE, accounts[i]) >=
		    (int)sizeof(source))
			goto done;
		if (snprintf(destination, sizeof(destination), "%s/private/etc/%s",
		    fixture, accounts[i]) >= (int)sizeof(destination) ||
		    !copy_file(source, destination, modes[i], false, false)) {
			perror("account login test release copy");
			goto done;
		}
		if (snprintf(destination, sizeof(destination), "%s/etc/%s", fixture,
		    accounts[i]) >= (int)sizeof(destination) ||
		    !copy_file(source, destination, modes[i], false, false)) {
			perror("account login test release copy");
			goto done;
		}
	}
	static const char public_accounts[] =
	    "root:*:0:0:System Administrator:/var/root:/bin/zsh\n"
	    "daemon:*:1:1:System Services:/var/root:/sbin/nologin\n"
	    "nobody:*:-2:-2:Unprivileged User:/var/empty:/sbin/nologin\n";
	if (snprintf(path, sizeof(path), "%s/private/etc/passwd", fixture) >=
	    (int)sizeof(path) || !write_file(path, public_accounts, 0644) ||
	    snprintf(path, sizeof(path), "%s/etc/passwd", fixture) >= (int)sizeof(path) ||
	    !write_file(path, public_accounts, 0644)) {
		perror("account login test passwd fixture");
		goto done;
	}
	if (snprintf(path, sizeof(path), "%s/etc/pam.d/%s", fixture,
	    PAM_SERVICE) >= (int)sizeof(path) ||
	    !write_file(path, "auth required /usr/lib/pam/pam_unix.so\n", 0644)) {
		perror("account login test PAM policy");
		goto done;
	}
	if (snprintf(path, sizeof(path), "%s/usr/lib/pam/pam_unix.so.2", fixture) >=
	    (int)sizeof(path) || !copy_file(PAM_MODULE_SOURCE, path, 0755, false, false) ||
	    snprintf(path, sizeof(path), "%s/usr/lib/pam/pam_deny.so.2", fixture) >=
	    (int)sizeof(path) || !copy_file(PAM_DENY_SOURCE, path, 0755, false, false)) {
		perror("account login test PAM module");
		goto done;
	}
	/* Keep OpenPAM's library-validation fallback out of the test path. */
	pam_module = dlopen(PAM_MODULE_SOURCE, RTLD_NOW | RTLD_LOCAL);
	if (!pam_module) {
		fprintf(stderr, "account login test could not preload PAM module: %s\n",
		    dlerror());
		goto done;
	}
	pam_deny = dlopen(PAM_DENY_SOURCE, RTLD_NOW | RTLD_LOCAL);
	if (!pam_deny) {
		fprintf(stderr, "account login test could not preload deny module: %s\n",
		    dlerror());
		goto done;
	}
	if (snprintf(username, sizeof(username), "finchlogin%d", (int)getpid()) >=
	    (int)sizeof(username) ||
	    snprintf(home, sizeof(home), "/Users/%s", username) >= (int)sizeof(home))
		goto done;
	root_fd = open(fixture, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
	if (root_fd < 0 || fchdir(root_fd) != 0 || chroot(".") != 0) {
		perror("account login test chroot");
		goto done;
	}
	entered = true;
	if (chdir("/") != 0) {
		perror("account login test chroot directory");
		goto done;
	}
	close(root_fd);
	root_fd = -1;
	if (at_store_open(&store, "/private/etc", error, sizeof(error)) != 0)
		goto done;
	/* A recycled user number must not give a new account an old home's files.
	 * Leave the empty folder afterward to check safe reuse on the real path. */
	static const char kept_contents[] = "previous user's file\n";
	if (!make_directory(home, 0700) ||
	    chown(home, TEST_UID_BASE + (uid_t)getpid(), 20) != 0 ||
	    snprintf(path, sizeof(path), "%s/keep.txt", home) >= (int)sizeof(path) ||
	    !write_file(path, kept_contents, 0600)) {
		perror("account login test existing home");
		goto done;
	}
	if (at_store_create_user_with_home_root(&store, username,
	    TEST_UID_BASE + (uid_t)getpid(), 20, "Finch Login Test", home,
	    "/bin/sh", TEST_PASSWORD, "/", error, sizeof(error)) == 0) {
		fputs("account login test accepted a non-empty home\n", stderr);
		goto done;
	}
	char kept[sizeof(kept_contents)] = {0};
	int kept_fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
	ssize_t kept_length = kept_fd < 0 ? -1 : read(kept_fd, kept, sizeof(kept));
	if (kept_fd >= 0)
		close(kept_fd);
	if (kept_length != (ssize_t)(sizeof(kept_contents) - 1) ||
	    memcmp(kept, kept_contents, sizeof(kept_contents) - 1) != 0 ||
	    unlink(path) != 0) {
		fputs("account login test changed the rejected home's file\n", stderr);
		goto done;
	}
	memset(error, 0, sizeof(error));
	if (at_store_create_user_with_home_root(&store, username,
	        TEST_UID_BASE + (uid_t)getpid(), 20, "Finch Login Test", home,
	        "/bin/sh", TEST_PASSWORD, "/", error, sizeof(error)) != 0) {
		fprintf(stderr, "account login test could not create its fixture user: %s\n",
		    error);
		goto done;
	}
	if (!copy_file("/private/etc/master.passwd", "/etc/master.passwd", 0600,
	    true, true) || !copy_file("/private/etc/passwd", "/etc/passwd", 0644,
	    true, true)) {
		perror("account login test account copy");
		goto done;
	}
	setpwent();
	struct passwd *test_user = getpwnam(username);
	bool user_visible = test_user &&
	    test_user->pw_uid == TEST_UID_BASE + (uid_t)getpid();
	endpwent();
	if (!user_visible) {
		fputs("account login test fixture user was not visible after chroot\n", stderr);
		goto done;
	}
	if (!pam_check(username, TEST_PASSWORD, PAM_SUCCESS) ||
	    !pam_check(username, WRONG_PASSWORD, PAM_AUTH_ERR) ||
	    !pam_check("nobody", TEST_PASSWORD, PAM_AUTH_ERR)) {
		fputs("account login test PAM password checks failed\n", stderr);
		goto done;
	}
	if (!directory_check(username, TEST_PASSWORD, true) ||
	    !directory_check(username, WRONG_PASSWORD, false) ||
	    !directory_check("nobody", TEST_PASSWORD, false)) {
		fputs("account login test OpenDirectory password checks failed\n", stderr);
		goto done;
	}
	ok = true;
	status = 0;

done:
	if (store.directory_fd >= 0)
		at_store_close(&store);
	if (root_fd >= 0)
		close(root_fd);
	if (entered) {
		if (fchdir(parent_fd) != 0 || chroot(".") != 0 || chdir("/") != 0) {
			perror("account login test cleanup root");
			status = 1;
		} else {
			entered = false;
		}
	}
	if (!entered && parent_fd >= 0 && leaf[0] && !remove_fixture(parent_fd, leaf)) {
		fputs("account login test could not remove its private fixture\n", stderr);
		status = 1;
	}
	if (parent_fd >= 0)
		close(parent_fd);
	if (pam_module)
		dlclose(pam_module);
	if (pam_deny)
		dlclose(pam_deny);
	if (ok && status == 0)
		puts("account-login: PASS (PAM and OpenDirectory)");
	return status;
}
