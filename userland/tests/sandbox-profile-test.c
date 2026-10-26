/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Guest-only test of Finch's sandbox end to end: SBPL compiled by Finch's
 * libsandbox, applied through libsystem_sandbox's sandbox_init, enforced by
 * the FinchSandbox kernel policy, and answered by sandbox_check and the
 * bootstrap server. Each case runs in a child of its own; the parent is
 * never sandboxed. The VM runner checks its exit status; don't run it on the
 * host (macOS's sandbox would answer instead).
 */
#include <errno.h>
#include <fcntl.h>
#include <servers/bootstrap.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <unistd.h>
#include <mach/mach.h>

/* syscall(2): the system call filter needs one made by number */
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

int sandbox_init_with_parameters(const char *profile, uint64_t flags, const char *const parameters[],
    char **errorbuf);
int sandbox_check(pid_t pid, const char *operation, int type, ...);
void sandbox_free_error(char *errorbuf);
#define SANDBOX_FILTER_PATH 1
#define SANDBOX_FILTER_GLOBAL_NAME 2

#define DIR "/private/tmp/finch-sbpt"

static int failures, checks;

#define CHECK(cond, what) do { \
	checks++; \
	if (!(cond)) { \
		failures++; \
		printf("FAIL: %s (errno %d %s)\n", what, errno, strerror(errno)); \
	} \
} while (0)

static int
apply(const char *profile)
{
	const char *params[] = { "DIR", DIR, NULL };
	char *error = NULL;
	int r = sandbox_init_with_parameters(profile, 0, params, &error);
	if (r != 0) {
		printf("sandbox_init failed: %s\n", error ? error : "?");
		sandbox_free_error(error);
	}
	return r;
}

static int
opens(const char *path, int flags)
{
	int fd = open(path, flags, 0600);
	if (fd < 0) {
		return 0;
	}
	close(fd);
	return 1;
}

/* Run fn in a child; its failures count here. */
static void
in_child(const char *name, void (*fn)(void))
{
	int pipefd[2];
	if (pipe(pipefd) != 0) {
		failures++;
		return;
	}
	pid_t pid = fork();
	if (pid == 0) {
		close(pipefd[0]);
		failures = checks = 0;
		fn();
		int counts[2] = { checks, failures };
		fflush(stdout);
		write(pipefd[1], counts, sizeof(counts));
		_exit(0);
	}
	close(pipefd[1]);
	int counts[2] = { 0, 1 };
	ssize_t n = read(pipefd[0], counts, sizeof(counts));
	close(pipefd[0]);
	int status = 0;
	waitpid(pid, &status, 0);
	if (n != sizeof(counts) || !WIFEXITED(status)) {
		printf("FAIL: %s: the child didn't finish (status %#x)\n", name, status);
		failures++;
		return;
	}
	checks += counts[0];
	failures += counts[1];
	printf("%s: %d checks, %d failed\n", name, counts[0], counts[1]);
}

static void
file_rules(void)
{
	if (apply("(version 1)(allow default)"
	          "(deny file-read-data (literal (string-append (param \"DIR\") \"/secret\")))"
	          "(deny file-read-data (regex #\"\\.hidden$\"))"
	          "(deny file-write* (subpath (string-append (param \"DIR\") \"/ro\")))") != 0) {
		failures++;
		return;
	}
	errno = 0;
	CHECK(!opens(DIR "/secret", O_RDONLY) && errno == EPERM, "reading the literal file is denied with EPERM");
	struct stat st;
	CHECK(stat(DIR "/secret", &st) == 0, "its metadata is still readable");
	CHECK(opens(DIR "/public", O_RDONLY), "another file reads");
	CHECK(!opens(DIR "/x.hidden", O_RDONLY), "the regex denies x.hidden");
	CHECK(!opens(DIR "/ro/new", O_WRONLY | O_CREAT), "creating inside the read-only subpath is denied");
	CHECK(!opens(DIR "/ro/existing", O_WRONLY), "writing inside it is denied");
	CHECK(unlink(DIR "/ro/existing") != 0, "unlinking inside it is denied");
	CHECK(rename(DIR "/public", DIR "/ro/moved") != 0, "renaming into it is denied");
	CHECK(opens(DIR "/ro/existing", O_RDONLY), "reading inside it is allowed");
	CHECK(opens(DIR "/rw-new", O_WRONLY | O_CREAT), "creating elsewhere is allowed");
	unlink(DIR "/rw-new");
	CHECK(opens(DIR "/rodir-sibling", O_WRONLY | O_CREAT), "a name that only starts like the subpath is outside it");
	unlink(DIR "/rodir-sibling");
	/* The sandbox can't be replaced or added to. */
	CHECK(apply("(version 1)(allow default)") != 0, "a second sandbox_init is refused");
	/* Children and programs they run keep it. */
	pid_t pid = fork();
	if (pid == 0) {
		execl("/bin/cat", "cat", DIR "/secret", (char *)NULL);
		_exit(99);
	}
	int status = 0;
	waitpid(pid, &status, 0);
	CHECK(WIFEXITED(status) && WEXITSTATUS(status) != 0 && WEXITSTATUS(status) != 99,
	    "cat in a child still can't read the file");
	/* sandbox_check answers from the same profile. */
	CHECK(sandbox_check(getpid(), "file-read-data", SANDBOX_FILTER_PATH, DIR "/secret") == 1,
	    "sandbox_check reports the denial");
	CHECK(sandbox_check(getpid(), "file-read-data", SANDBOX_FILTER_PATH, DIR "/public") == 0,
	    "sandbox_check reports an allowed path");
	CHECK(sandbox_check(getpid(), NULL, 0) == 1, "sandbox_check says this process is sandboxed");
}

static void
other_rules(void)
{
	if (apply("(version 1)(allow default)"
	          "(deny sysctl-read (sysctl-name \"kern.hostname\"))"
	          "(deny signal (target others))"
	          "(deny ipc-posix-shm* (ipc-posix-name \"finch.sbpt.denied\"))"
	          "(deny mach-lookup (global-name \"com.apple.system.logger\"))") != 0) {
		failures++;
		return;
	}
	char buf[256];
	size_t len = sizeof(buf);
	errno = 0;
	CHECK(sysctlbyname("kern.hostname", buf, &len, NULL, 0) != 0 && errno == EPERM, "kern.hostname is denied");
	len = sizeof(buf);
	CHECK(sysctlbyname("kern.ostype", buf, &len, NULL, 0) == 0, "kern.ostype reads");
	CHECK(kill(getppid(), 0) != 0 && errno == EPERM, "signalling the parent is denied");
	CHECK(kill(getpid(), 0) == 0, "signalling itself is allowed");
	errno = 0;
	CHECK(shm_open("finch.sbpt.denied", O_RDWR | O_CREAT, 0600) < 0 && errno == EPERM,
	    "the denied shared memory name can't be made");
	int fd = shm_open("finch.sbpt.allowed", O_RDWR | O_CREAT, 0600);
	CHECK(fd >= 0, "another shared memory name can");
	if (fd >= 0) {
		close(fd);
		shm_unlink("finch.sbpt.allowed");
	}
	mach_port_t port = MACH_PORT_NULL;
	kern_return_t kr = bootstrap_look_up(bootstrap_port, "com.apple.system.logger", &port);
	CHECK(kr == BOOTSTRAP_NOT_PRIVILEGED, "looking up the denied service is refused (1100)");
	kr = bootstrap_look_up(bootstrap_port, "com.apple.system.notification_center", &port);
	CHECK(kr == KERN_SUCCESS, "another service is found");
	CHECK(sandbox_check(getpid(), "mach-lookup", SANDBOX_FILTER_GLOBAL_NAME, "com.apple.system.logger") == 1,
	    "sandbox_check agrees about the service");
}

static void
deny_default(void)
{
	if (apply("(version 1)(deny default)"
	          "(allow file-read* (literal (string-append (param \"DIR\") \"/public2\")))") != 0) {
		failures++;
		return;
	}
	CHECK(opens(DIR "/public2", O_RDONLY), "the one allowed file reads");
	CHECK(!opens("/private/etc/hosts", O_RDONLY), "anything else is denied");
	char buf[64];
	size_t len = sizeof(buf);
	CHECK(sysctlbyname("kern.ostype", buf, &len, NULL, 0) != 0, "sysctls are denied by default");
	CHECK(fork() < 0 && errno == EPERM, "fork is denied by default");
}

static void
syscall_filter(void)
{
	/* (version 2) profiles filter system calls by number. */
	if (apply("(version 2)(allow default)"
	          "(deny syscall-unix (syscall-number SYS_getppid))") != 0) {
		failures++;
		return;
	}
	errno = 0;
	CHECK(syscall(SYS_getppid) == -1 && errno == EPERM, "the denied system call fails with EPERM");
	CHECK(syscall(SYS_getpid) == getpid(), "another system call runs");
}

static void
version1_unfiltered(void)
{
	/* In a (version 1) profile, syscall rules don't filter system calls. */
	if (apply("(version 1)(allow default)(deny syscall-unix)") != 0) {
		failures++;
		return;
	}
	CHECK(syscall(SYS_getppid) == getppid(), "version 1 leaves system calls alone");
}

int
main(void)
{
	mkdir(DIR, 0755);
	mkdir(DIR "/ro", 0755);
	close(open(DIR "/secret", O_WRONLY | O_CREAT, 0644));
	close(open(DIR "/public", O_WRONLY | O_CREAT, 0644));
	close(open(DIR "/public2", O_WRONLY | O_CREAT, 0644));
	close(open(DIR "/x.hidden", O_WRONLY | O_CREAT, 0644));
	close(open(DIR "/ro/existing", O_WRONLY | O_CREAT, 0644));

	CHECK(sandbox_check(getpid(), NULL, 0) == 0, "the test itself isn't sandboxed");
	in_child("files", file_rules);
	in_child("sysctl, signals, shared memory, lookups", other_rules);
	in_child("deny default", deny_default);
	in_child("system call filter", syscall_filter);
	in_child("version 1", version1_unfiltered);

	unlink(DIR "/secret");
	unlink(DIR "/public");
	unlink(DIR "/ro/moved");
	unlink(DIR "/public2");
	unlink(DIR "/x.hidden");
	unlink(DIR "/ro/existing");
	rmdir(DIR "/ro");
	rmdir(DIR);
	printf("sandbox-profile-test: %d checks, %d failed\n", checks, failures);
	return failures != 0;
}
