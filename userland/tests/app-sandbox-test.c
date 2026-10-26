/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Guest-only test of the App Sandbox (libsystem_secinit and application.sb),
 * run as root by tools/vm/test-app-sandbox.sh on the persistent VM. Run as
 * root, it makes a user with files in their home and runs two sandboxed apps
 * as that user, which are this program signed with the sandbox entitlement:
 *
 *   SandboxTest.app      com.apple.security.app-sandbox only
 *   SandboxNetTest.app   also network.client, files.downloads.read-write and a
 *                        temporary read-only exception for one file
 *
 * Each checks, from inside, what it may and may not reach. The same checks
 * without a sandbox (this program as the user) show the files are there.
 */
#include "account_tools.h"

#include <arpa/inet.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <netinet/in.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#define USER "sbxtestuser"
#define PASSWORD "Finch sandbox user 2026"
#define APPS "/usr/local/share/finch/apps"
#define PLAIN_APP APPS "/SandboxTest.app/Contents/MacOS/SandboxTest"
#define NET_APP APPS "/SandboxNetTest.app/Contents/MacOS/SandboxNetTest"
#define EXCEPTION_FILE "/private/var/db/finch-sandbox-exception"
#define OTHER_FILE "/private/var/db/finch-sandbox-other"

int sandbox_check(pid_t pid, const char *operation, int type, ...);
char *sandbox_extension_issue_file(const char *extension_class, const char *path, uint32_t flags);
char *sandbox_extension_issue_file_to_process_by_pid(const char *extension_class, const char *path,
    uint32_t flags, pid_t pid);
int64_t sandbox_extension_consume(const char *token);
int sandbox_extension_release(int64_t handle);

static int failures, checks;

#define CHECK(cond, what) do { \
	checks++; \
	if (!(cond)) { \
		failures++; \
		printf("FAIL: %s (errno %d)\n", what, errno); \
	} \
} while (0)

static char home[PATH_MAX];

static void
real_home(void)
{
	struct passwd *pw = getpwuid(getuid());
	if (pw == NULL || realpath(pw->pw_dir, home) == NULL)
		strlcpy(home, "/nonexistent", sizeof(home));
}

/* open(2) for reading: 0, or the errno it failed with. */
static int
read_error(const char *path)
{
	int fd = open(path, O_RDONLY);
	if (fd < 0)
		return errno;
	char c;
	int r = read(fd, &c, 1) < 0 ? errno : 0;
	close(fd);
	return r;
}

static int
write_error(const char *path)
{
	int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
	if (fd < 0)
		return errno;
	int r = write(fd, "x\n", 2) == 2 ? 0 : errno;
	close(fd);
	return r;
}

static int
connect_error(void)
{
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0)
		return errno;
	struct sockaddr_in addr = { .sin_len = sizeof(addr), .sin_family = AF_INET, .sin_port = htons(9) };
	addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	int r = connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0 ? 0 : errno;
	close(fd);
	return r;
}

/* A program's exit status, run from here (in this sandbox). */
static int
run(char *const argv[])
{
	pid_t pid = fork();
	if (pid == 0) {
		int null = open("/dev/null", O_WRONLY);
		dup2(null, STDERR_FILENO);
		execv(argv[0], argv);
		_exit(127);
	}
	int status;
	waitpid(pid, &status, 0);
	return WIFEXITED(status) ? WEXITSTATUS(status) : 128;
}

static void
path(char *out, const char *relative)
{
	snprintf(out, PATH_MAX, "%s%s", home, relative);
}

/*
 * Extensions (net only; it has files.user-selected.read-write): tokens the
 * unsandboxed driver issued for the user's secret file (read) and another
 * Documents file (read-write).
 */
static void
extensions(const char *container, const char *secret, const char *read_token, const char *rw_token)
{
	char rw_file[PATH_MAX];
	path(rw_file, "/Documents/chosen.txt");
	CHECK(read_error(secret) == EPERM && read_error(rw_file) == EPERM, "before consuming: closed");
	int64_t read_handle = sandbox_extension_consume(read_token);
	CHECK(read_handle > 0, "a read extension is consumed");
	CHECK(read_error(secret) == 0, "and opens its file for reading");
	CHECK(write_error(secret) == EPERM, "but not for writing");
	CHECK(read_error(rw_file) == EPERM, "and nothing else");
	CHECK(run((char *[]){ "/bin/cat", (char *)secret, NULL }) == 0, "a tool it runs inherits the extension");
	int64_t rw_handle = sandbox_extension_consume(rw_token);
	CHECK(rw_handle > 0 && rw_handle != read_handle, "a read-write extension is consumed");
	CHECK(read_error(rw_file) == 0 && write_error(rw_file) == 0, "and opens its file for reading and writing");
	CHECK(sandbox_extension_release(read_handle) == 0, "releasing the read extension");
	CHECK(read_error(secret) == EPERM, "closes its file again");
	CHECK(write_error(rw_file) == 0, "and keeps the other");

	/* A changed token is refused. */
	char *tampered = strdup(read_token);
	size_t n = strlen(tampered);
	tampered[n - 1] = tampered[n - 1] == '0' ? '1' : '0';
	errno = 0;
	CHECK(sandbox_extension_consume(tampered) == -1 && errno == EINVAL, "a changed token is refused");
	free(tampered);
	CHECK(read_error(secret) == EPERM, "and opens nothing");

	/* It passes on only what it has, and a token issued to another process is that one's. */
	char inside[PATH_MAX];
	snprintf(inside, sizeof(inside), "%s/Documents", container);
	errno = 0;
	CHECK(sandbox_extension_issue_file("com.apple.app-sandbox.read", secret, 0) == NULL && errno == EPERM,
	    "it can't issue an extension for a file it can't read");
	char *mine = sandbox_extension_issue_file_to_process_by_pid("com.apple.app-sandbox.read", inside, 0, getppid());
	CHECK(mine != NULL, "it can issue one for its own container, to another process");
	errno = 0;
	CHECK(mine && sandbox_extension_consume(mine) == -1 && errno == EPERM,
	    "which it can't consume itself");
	free(mine);
}

/* Inside a sandboxed app: "plain" or "net". */
static int
sandboxed(const char *mode, const char *identifier, const char *read_token, const char *rw_token)
{
	bool net = !strcmp(mode, "net");
	char container[PATH_MAX], file[PATH_MAX], secret[PATH_MAX], downloads[PATH_MAX];
	real_home();
	snprintf(container, sizeof(container), "%s/Library/Containers/%s/Data", home, identifier);
	path(secret, "/Documents/secret.txt");
	path(downloads, "/Downloads/dl.txt");

	CHECK(sandbox_check(getpid(), NULL, 0) == 1, "the app is sandboxed");
	CHECK(getenv("HOME") && !strcmp(getenv("HOME"), container), "HOME is the container");
	char tmp[PATH_MAX];
	snprintf(tmp, sizeof(tmp), "%s/tmp/", container);
	CHECK(getenv("TMPDIR") && !strcmp(getenv("TMPDIR"), tmp), "TMPDIR is the container's tmp");
	struct stat st;
	snprintf(file, sizeof(file), "%s/Documents", container);
	CHECK(stat(file, &st) == 0 && S_ISDIR(st.st_mode) && (st.st_mode & 0777) == 0700, "the container has Documents");
	snprintf(file, sizeof(file), "%s/Desktop", container);
	CHECK(lstat(file, &st) == 0 && S_ISLNK(st.st_mode), "the container's Desktop links to the user's");
	snprintf(file, sizeof(file), "%s/Library/Preferences/test.plist", container);
	CHECK(write_error(file) == 0 && read_error(file) == 0, "the app writes and reads its container");

	CHECK(read_error(secret) == EPERM, "the user's Documents are closed");
	errno = 0;
	CHECK(opendir(home) == NULL && errno == EPERM, "the user's home can't be listed");
	CHECK(stat(home, &st) == 0, "but it can be looked up");
	snprintf(file, sizeof(file), "%s/Documents/secret.txt", container);
	CHECK(read_error(file) == ENOENT, "the container's Documents isn't the user's");
	CHECK(write_error("/private/tmp/finch-sandbox-escape") == EPERM, "/tmp is closed");
	CHECK(read_error("/usr/lib/dyld") == 0 && read_error("/private/etc/shells") == 0, "system files are readable");
	CHECK(read_error(OTHER_FILE) == EPERM, "other files outside are closed");

	if (net) {
		CHECK(connect_error() != EPERM, "network.client: connecting is allowed");
		CHECK(read_error(downloads) == 0 && write_error(downloads) == 0, "downloads.read-write: Downloads is open");
		CHECK(read_error(EXCEPTION_FILE) == 0, "a temporary exception opens its file");
		CHECK(write_error(EXCEPTION_FILE) == EPERM, "read-only: but not for writing");
	} else {
		CHECK(connect_error() == EPERM, "no network.client: connecting is refused");
		CHECK(read_error(downloads) == EPERM, "no downloads entitlement: Downloads is closed");
		CHECK(read_error(EXCEPTION_FILE) == EPERM, "no exception: its file is closed");
	}

	if (net && read_token && rw_token)
		extensions(container, secret, read_token, rw_token);

	/* What it runs is sandboxed too. */
	snprintf(file, sizeof(file), "%s/Library/Preferences/test.plist", container);
	CHECK(run((char *[]){ "/bin/cat", file, NULL }) == 0, "a tool it runs reads the container");
	CHECK(run((char *[]){ "/bin/cat", secret, NULL }) != 0, "but not the user's Documents");
	printf("%s: %d checks, %d failed\n", identifier, checks, failures);
	return failures != 0;
}

/* As the user, without a sandbox: the files are there to be refused. */
static int
unsandboxed(void)
{
	char secret[PATH_MAX], downloads[PATH_MAX];
	real_home();
	path(secret, "/Documents/secret.txt");
	path(downloads, "/Downloads/dl.txt");
	CHECK(sandbox_check(getpid(), NULL, 0) == 0, "the control isn't sandboxed");
	CHECK(read_error(secret) == 0 && read_error(downloads) == 0 && read_error(OTHER_FILE) == 0,
	    "without a sandbox the user reads their files");
	CHECK(connect_error() != EPERM, "and may connect");
	printf("unsandboxed: %d checks, %d failed\n", checks, failures);
	return failures != 0;
}

static int
run_as_user(char *const argv[])
{
	fflush(stdout);
	pid_t pid = fork();
	if (pid == 0) {
		struct passwd *pw = getpwnam(USER);
		if (pw == NULL || initgroups(USER, (int)pw->pw_gid) != 0 || setgid(pw->pw_gid) != 0 ||
		    setuid(pw->pw_uid) != 0)
			_exit(126);
		setenv("HOME", pw->pw_dir, 1);
		execv(argv[0], argv);
		_exit(127);
	}
	int status;
	waitpid(pid, &status, 0);
	return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}

static void
put(const char *file, uid_t uid, mode_t mode)
{
	int fd = open(file, O_WRONLY | O_CREAT | O_TRUNC, mode);
	if (fd >= 0) {
		(void)!write(fd, "data\n", 5);
		fchown(fd, uid, 20);
		fchmod(fd, mode);
		close(fd);
	}
}

int
main(int argc, char *argv[])
{
	if (argc >= 4 && !strcmp(argv[1], "--sandboxed"))
		return sandboxed(argv[2], argv[3], argc > 5 ? argv[4] : NULL, argc > 5 ? argv[5] : NULL);
	if (argc == 2 && !strcmp(argv[1], "--unsandboxed"))
		return unsandboxed();
	if (getuid() != 0) {
		printf("run as root\n");
		return 2;
	}
	/* A user with a home of their own (under /Users, wherever it leads). */
	if (getpwnam(USER) == NULL) {
		struct at_store store = { .directory_fd = -1 };
		char error[256], users[PATH_MAX], root[PATH_MAX];
		if (realpath("/Users", users) == NULL) {
			printf("no /Users\n");
			return 1;
		}
		strlcpy(root, users, sizeof(root));
		root[strlen(root) - strlen("/Users")] = '\0';
		if (at_store_open_default(&store, error, sizeof(error)) != 0 ||
		    at_store_create_user_with_home_root(&store, USER, 6531, 20, "Sandbox Test", "/Users/" USER, "/bin/sh",
		    PASSWORD, root[0] ? root : "/", error, sizeof(error)) != 0) {
			printf("can't make %s: %s\n", USER, error);
			return 1;
		}
		at_store_close(&store);
	}
	struct passwd *pw = getpwnam(USER);
	char file[PATH_MAX];
	snprintf(file, sizeof(file), "%s/Documents/secret.txt", pw->pw_dir);
	put(file, pw->pw_uid, 0600);
	snprintf(file, sizeof(file), "%s/Downloads/dl.txt", pw->pw_dir);
	put(file, pw->pw_uid, 0600);
	char chosen[PATH_MAX], secret[PATH_MAX];
	snprintf(chosen, sizeof(chosen), "%s/Documents/chosen.txt", pw->pw_dir);
	put(chosen, pw->pw_uid, 0600);
	snprintf(secret, sizeof(secret), "%s/Documents/secret.txt", pw->pw_dir);
	/* What an open panel would hand the app: tokens for the files the user chose. */
	char *read_token = sandbox_extension_issue_file("com.apple.app-sandbox.read", secret, 0);
	char *rw_token = sandbox_extension_issue_file("com.apple.app-sandbox.read-write", chosen, 0);
	CHECK(read_token != NULL && rw_token != NULL, "root issues extension tokens");
	put(EXCEPTION_FILE, 0, 0644);
	put(OTHER_FILE, 0, 0644);

	CHECK(run_as_user((char *[]){ "/usr/local/bin/finch-app-sandbox-test", "--unsandboxed", NULL }) == 0,
	    "the unsandboxed control");
	CHECK(run_as_user((char *[]){ PLAIN_APP, "--sandboxed", "plain", "org.finch.test.sandboxed", NULL }) == 0,
	    "SandboxTest.app's checks");
	CHECK(run_as_user((char *[]){ NET_APP, "--sandboxed", "net", "org.finch.test.sandboxed-net",
	    read_token ? read_token : "none", rw_token ? rw_token : "none", NULL }) == 0,
	    "SandboxNetTest.app's checks");
	/* The container is the user's own and private. */
	struct stat st;
	snprintf(file, sizeof(file), "%s/Library/Containers/org.finch.test.sandboxed/Data", pw->pw_dir);
	CHECK(stat(file, &st) == 0 && st.st_uid == pw->pw_uid && (st.st_mode & 0777) == 0700,
	    "the container is the user's, mode 0700");
	printf("app-sandbox-test: %d checks, %d failed\n", checks, failures);
	return failures != 0;
}
