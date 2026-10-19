/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Check that a nonroot path watch stays quiet when a file is hidden, then
 * notices when access returns. Run as root in the Finch VM.
 */
#include <dispatch/dispatch.h>
#include <notify.h>
#include <notify_private.h>

#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <limits.h>
#include <poll.h>
#include <pwd.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define PATH_WATCH_FLAGS 0x3ff
#define PATH_SIZE 1024
#define NAME_SIZE 192
#define START_TIMEOUT_MS 7000
#define PHASE_TIMEOUT_MS 6500
#define CHILD_EXIT_TIMEOUT_MS 8000
#define EVENT_TIMEOUT_MS 5000
#define EVENT_QUIET_MS 350
/* Cover at least one blocked-path retry, not just immediate file events. */
#define NO_EVENT_QUIET_MS 1600
#define ARM_QUIET_MS 300
#define POLL_NS (10ull * 1000000ull)

struct child_process {
	pid_t pid;
	int command_fd;
	int result_fd;
};

struct setup_report {
	int identity_error;
	uid_t uid;
	uid_t effective_uid;
	uint32_t register_status;
	uint32_t monitor_status;
	int token;
	uint32_t setup_callbacks;
	uint32_t setup_check_changes;
};

struct phase_report {
	uint32_t callbacks;
	uint32_t check_changes;
	uint32_t api_errors;
	uint32_t wrong_tokens;
	int event_seen;
};

static dispatch_queue_t callback_queue;
static atomic_uint callback_count;
static atomic_uint wrong_token_count;
static int watched_token = NOTIFY_TOKEN_INVALID;

static int
write_all(int fd, const void *buffer, size_t size)
{
	const char *bytes = buffer;
	while (size != 0) {
		ssize_t written = write(fd, bytes, size);
		if (written < 0 && errno == EINTR) continue;
		if (written <= 0) return -1;
		bytes += written;
		size -= (size_t)written;
	}
	return 0;
}

static int
read_all_timeout(int fd, void *buffer, size_t size, int timeout_ms)
{
	char *bytes = buffer;
	uint64_t deadline = (uint64_t)timeout_ms;
	struct timespec now;
	if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return -1;
	deadline += (uint64_t)now.tv_sec * 1000ull + (uint64_t)now.tv_nsec / 1000000ull;
	while (size != 0) {
		struct pollfd descriptor = { .fd = fd, .events = POLLIN | POLLHUP };
		if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return -1;
		uint64_t current = (uint64_t)now.tv_sec * 1000ull + (uint64_t)now.tv_nsec / 1000000ull;
		if (current >= deadline) { errno = ETIMEDOUT; return -1; }
		int remaining = (int)(deadline - current);
		int ready;
		do { ready = poll(&descriptor, 1, remaining); } while (ready < 0 && errno == EINTR);
		if (ready <= 0) { if (ready == 0) errno = ETIMEDOUT; return -1; }
		ssize_t got;
		do { got = read(fd, bytes, size); } while (got < 0 && errno == EINTR);
		if (got <= 0) { if (got == 0) errno = EPIPE; return -1; }
		bytes += got;
		size -= (size_t)got;
	}
	return 0;
}

static int
read_byte_timeout(int fd, char *byte, int timeout_ms)
{
	return read_all_timeout(fd, byte, 1, timeout_ms);
}

static int
write_byte(int fd, char byte)
{
	return write_all(fd, &byte, 1);
}

static int
parse_fd(const char *text, int *fd)
{
	char *end = NULL;
	long value;
	errno = 0;
	value = strtol(text, &end, 10);
	if (errno != 0 || end == text || *end != '\0' || value < 0 || value > INT_MAX) return -1;
	*fd = (int)value;
	return 0;
}

static int
parse_uid(const char *text, uid_t *uid)
{
	char *end = NULL;
	unsigned long long value;
	errno = 0;
	value = strtoull(text, &end, 10);
	if (errno != 0 || end == text || *end != '\0' || value > UINT_MAX) return -1;
	*uid = (uid_t)value;
	return (unsigned long long)*uid == value ? 0 : -1;
}

static int
parse_gid(const char *text, gid_t *gid)
{
	char *end = NULL;
	unsigned long long value;
	errno = 0;
	value = strtoull(text, &end, 10);
	if (errno != 0 || end == text || *end != '\0' || value > UINT_MAX) return -1;
	*gid = (gid_t)value;
	return (unsigned long long)*gid == value ? 0 : -1;
}

static uint64_t
monotonic_ms(void)
{
	struct timespec now;
	if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0;
	return (uint64_t)now.tv_sec * 1000ull + (uint64_t)now.tv_nsec / 1000000ull;
}

static void
pause_briefly(void)
{
	struct timespec pause = { .tv_sec = 0, .tv_nsec = (long)POLL_NS };
	while (nanosleep(&pause, &pause) != 0 && errno == EINTR) {}
}

static int
drop_to_user(uid_t uid, gid_t gid, struct setup_report *report)
{
	if (setgroups(1, &gid) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		report->identity_error = errno;
		return -1;
	}
	report->uid = getuid();
	report->effective_uid = geteuid();
	if (report->uid != uid || report->effective_uid != uid) {
		report->identity_error = EPERM;
		return -1;
	}
	return 0;
}

static void
dispatch_handler(int token)
{
	if (token != watched_token)
		atomic_fetch_add_explicit(&wrong_token_count, 1, memory_order_relaxed);
	else
		atomic_fetch_add_explicit(&callback_count, 1, memory_order_relaxed);
}

/* notify_check on this same token is the public fence for local path events. */
static int
poll_path_event(struct phase_report *report, int *activity,
	uint32_t callback_base, uint32_t wrong_base)
{
	int changed = 0;
	uint32_t status = notify_check(watched_token, &changed);
	if (status != NOTIFY_STATUS_OK) {
		report->api_errors++;
		return -1;
	}
	if (changed) {
		report->check_changes++;
		*activity = 1;
	}
	dispatch_sync(callback_queue, ^{});
	uint32_t callbacks = atomic_load_explicit(&callback_count, memory_order_relaxed) - callback_base;
	if (callbacks > report->callbacks) {
		report->callbacks = callbacks;
		*activity = 1;
	}
	uint32_t wrong = atomic_load_explicit(&wrong_token_count, memory_order_relaxed) - wrong_base;
	if (wrong > report->wrong_tokens) {
		report->wrong_tokens = wrong;
		*activity = 1;
	}
	return 0;
}

static int
settle_quiet(struct phase_report *report, int quiet_ms, int timeout_ms)
{
	uint64_t start = monotonic_ms();
	uint64_t last_activity = start;
	uint32_t callback_base = atomic_load_explicit(&callback_count, memory_order_relaxed);
	uint32_t wrong_base = atomic_load_explicit(&wrong_token_count, memory_order_relaxed);
	while (monotonic_ms() - start < (uint64_t)timeout_ms) {
		int activity = 0;
		if (poll_path_event(report, &activity, callback_base, wrong_base) != 0) return -1;
		if (activity) last_activity = monotonic_ms();
		if (monotonic_ms() - last_activity >= (uint64_t)quiet_ms) return 0;
		pause_briefly();
	}
	errno = ETIMEDOUT;
	return -1;
}

static int
collect_phase(int expected_event, uint32_t callback_base, uint32_t wrong_base,
	struct phase_report *report)
{
	uint64_t start = monotonic_ms();
	uint64_t last_activity = start;
	int seen = 0;
	memset(report, 0, sizeof(*report));
	while (monotonic_ms() - start < EVENT_TIMEOUT_MS) {
		int activity = 0;
		if (poll_path_event(report, &activity, callback_base, wrong_base) != 0) break;
		if (activity) last_activity = monotonic_ms();
		if (report->callbacks != 0 || report->check_changes != 0) seen = 1;
		if (expected_event && seen && monotonic_ms() - last_activity >= EVENT_QUIET_MS) {
			report->event_seen = 1;
			return 0;
		}
		if (!expected_event && monotonic_ms() - last_activity >= NO_EVENT_QUIET_MS)
			return 0;
		pause_briefly();
	}
	if (expected_event && seen) report->event_seen = 1;
	return 0;
}

static int
send_phase_report(int result_fd, struct phase_report *phase)
{
	if (write_byte(result_fd, 'P') != 0) return -1;
	return write_all(result_fd, phase, sizeof(*phase));
}

static int
has_open_inode(const struct stat *file)
{
	long limit = sysconf(_SC_OPEN_MAX);
	if (limit < 0) return -1;
	if (limit > 65536) limit = 65536;
	for (int fd = 0; fd < limit; fd++) {
		struct stat current;
		if (fstat(fd, &current) == 0 && current.st_dev == file->st_dev &&
		    current.st_ino == file->st_ino) return 1;
	}
	return 0;
}

static int
watcher_child(int command_fd, int result_fd, const char *name, const char *path,
	uid_t uid, gid_t gid)
{
	struct setup_report setup;
	struct phase_report phase;
	char command = '\0';
	int status = 1;
	struct stat base_stat;
	char base_path[PATH_SIZE];
	int have_base = 0;
	memset(&setup, 0, sizeof(setup));
	setup.register_status = UINT32_MAX;
	setup.monitor_status = UINT32_MAX;
	setup.token = NOTIFY_TOKEN_INVALID;
	atomic_init(&callback_count, 0);
	atomic_init(&wrong_token_count, 0);

	if (drop_to_user(uid, gid, &setup) != 0) goto report_setup;
	(void)snprintf(base_path, sizeof(base_path), "%s", path);
	char *separator = strrchr(base_path, '/');
	if (separator != NULL) *separator = '\0';
	separator = strrchr(base_path, '/');
	if (separator != NULL) *separator = '\0';
	have_base = stat(base_path, &base_stat) == 0;
	callback_queue = dispatch_queue_create("com.finch.notify.path.permission", DISPATCH_QUEUE_SERIAL);
	if (callback_queue == NULL) goto report_setup;
	setup.register_status = notify_register_dispatch(name, &setup.token, callback_queue,
		^(int token) { dispatch_handler(token); });
	if (setup.register_status == NOTIFY_STATUS_OK) {
		watched_token = setup.token;
		setup.monitor_status = notify_monitor_file(setup.token, (char *)path, PATH_WATCH_FLAGS);
	}
	if (setup.register_status != NOTIFY_STATUS_OK || setup.monitor_status != NOTIFY_STATUS_OK)
		goto report_setup;

	memset(&phase, 0, sizeof(phase));
	if (settle_quiet(&phase, ARM_QUIET_MS, EVENT_TIMEOUT_MS) != 0) goto report_setup;
	setup.setup_callbacks = atomic_load_explicit(&callback_count, memory_order_relaxed);
	setup.setup_check_changes = phase.check_changes;
	if (write_byte(result_fd, 'R') != 0 || write_all(result_fd, &setup, sizeof(setup)) != 0)
		goto cleanup;

	for (;;) {
		uint32_t callback_base, wrong_base;
		if (read_byte_timeout(command_fd, &command, 60000) != 0) goto cleanup;
		if (command == 'X') {
			status = 0;
			break;
		}
		if (command != 'A') goto cleanup;
		memset(&phase, 0, sizeof(phase));
		if (settle_quiet(&phase, ARM_QUIET_MS, EVENT_TIMEOUT_MS) != 0) goto cleanup;
		callback_base = atomic_load_explicit(&callback_count, memory_order_relaxed);
		wrong_base = atomic_load_explicit(&wrong_token_count, memory_order_relaxed);
		if (write_byte(result_fd, 'A') != 0) goto cleanup;
		if (read_byte_timeout(command_fd, &command, 60000) != 0) goto cleanup;
		if ((command != 'Q') && (command != 'E')) goto cleanup;
		if (collect_phase(command == 'E', callback_base, wrong_base, &phase) != 0 ||
		    send_phase_report(result_fd, &phase) != 0) goto cleanup;
	}

cleanup:
	if (setup.token != NOTIFY_TOKEN_INVALID) {
		/* A retry can briefly close the old set before reopening its parent. */
		uint64_t parent_deadline = monotonic_ms() + 1500;
		while (status == 0 && have_base && has_open_inode(&base_stat) == 0 &&
		    monotonic_ms() < parent_deadline) pause_briefly();
		if (status == 0 && (!have_base || has_open_inode(&base_stat) != 1)) {
			fprintf(stderr, "blocked watcher did not hold its accessible parent\n");
			status = 1;
		}
		if (notify_cancel(setup.token) != NOTIFY_STATUS_OK) status = 1;
		if (status == 0 && has_open_inode(&base_stat) != 0) {
			fprintf(stderr, "cancel returned with the parent still open\n");
			status = 1;
		}
	}
	if (callback_queue != NULL) {
		dispatch_sync(callback_queue, ^{});
		if (status == 0) {
			uint32_t before = atomic_load_explicit(&callback_count, memory_order_relaxed);
			uint64_t until = monotonic_ms() + 1300;
			while (monotonic_ms() < until) pause_briefly();
			dispatch_sync(callback_queue, ^{});
			if (atomic_load_explicit(&callback_count, memory_order_relaxed) != before ||
			    has_open_inode(&base_stat) != 0) {
				fprintf(stderr, "canceled watcher resumed work\n");
				status = 1;
			}
		}
		dispatch_release(callback_queue);
		callback_queue = NULL;
	}
	if (setup.token != NOTIFY_TOKEN_INVALID && status != 0) status = 1;
	close(command_fd);
	close(result_fd);
	return status;

report_setup:
	(void)write_byte(result_fd, 'F');
	(void)write_all(result_fd, &setup, sizeof(setup));
	goto cleanup;
}

static int
set_cloexec(int fd)
{
	int flags = fcntl(fd, F_GETFD);
	return flags < 0 ? -1 : fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
}

static int
arm_child(struct child_process *child)
{
	char marker;
	if (write_byte(child->command_fd, 'A') != 0 ||
	    read_byte_timeout(child->result_fd, &marker, PHASE_TIMEOUT_MS) != 0 || marker != 'A')
		return -1;
	return 0;
}

static int
finish_phase(struct child_process *child, char mode, struct phase_report *phase)
{
	char marker;
	if (write_byte(child->command_fd, mode) != 0 ||
	    read_byte_timeout(child->result_fd, &marker, PHASE_TIMEOUT_MS) != 0 || marker != 'P' ||
	    read_all_timeout(child->result_fd, phase, sizeof(*phase), PHASE_TIMEOUT_MS) != 0)
		return -1;
	return 0;
}

static int
wait_for_child(pid_t pid, int *status)
{
	uint64_t deadline = monotonic_ms() + CHILD_EXIT_TIMEOUT_MS;
	while (monotonic_ms() < deadline) {
		pid_t result = waitpid(pid, status, WNOHANG);
		if (result == pid) return 0;
		if (result < 0 && errno != EINTR) return -1;
		pause_briefly();
	}
	errno = ETIMEDOUT;
	return -1;
}

static int
create_owned_file(const char *path, uid_t uid, gid_t gid)
{
	int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
	if (fd < 0) return -1;
	if (fchown(fd, uid, gid) != 0 || fchmod(fd, 0644) != 0 ||
	    write_all(fd, "before\n", 7) != 0 || fsync(fd) != 0) {
		int saved_errno = errno;
		close(fd);
		unlink(path);
		errno = saved_errno;
		return -1;
	}
	return close(fd);
}

static int
open_append_file(const char *path)
{
	return open(path, O_WRONLY | O_APPEND | O_NOFOLLOW);
}

static int
append_through_open_fd(int fd)
{
	return write_all(fd, "hidden-change\n", 14) == 0 ? fsync(fd) : -1;
}

static int
report_phase(const char *label, const struct phase_report *phase,
	int expect_event, int expect_quiet)
{
	if (phase->api_errors != 0 || phase->wrong_tokens != 0) {
		fprintf(stderr, "%s: notify_check errors %u, wrong callback tokens %u\n",
		    label, phase->api_errors, phase->wrong_tokens);
		return -1;
	}
	if (expect_event && (phase->event_seen == 0 || phase->callbacks == 0)) {
		fprintf(stderr, "%s: expected event, saw %u callback(s) and %u check change(s)\n",
		    label, phase->callbacks, phase->check_changes);
		return -1;
	}
	if (expect_quiet && (phase->callbacks != 0 || phase->check_changes != 0)) {
		fprintf(stderr, "%s: hidden change was visible (%u callback(s), %u check change(s))\n",
		    label, phase->callbacks, phase->check_changes);
		return -1;
	}
	return 0;
}

static int
parent_main(const char *executable)
{
	struct passwd *root_user = getpwnam("root");
	struct passwd *test_user;
	char base_template[] = "/tmp/finch-notify-path-permission.XXXXXX";
	char locked_dir[PATH_SIZE] = { 0 };
	char target_path[PATH_SIZE] = { 0 };
	char name[NAME_SIZE];
	char command_fd_arg[20], result_fd_arg[20], uid_arg[32], gid_arg[32];
	char marker = '\0';
	char *base_dir = NULL;
	struct child_process child = { .pid = -1, .command_fd = -1, .result_fd = -1 };
	struct setup_report setup;
	struct phase_report phase;
	uid_t uid;
	gid_t gid;
	unsigned int nonce = arc4random();
	int target_fd = -1, command_pipe[2] = { -1, -1 }, result_pipe[2] = { -1, -1 };
	int child_status = 0, failed = 0;

	alarm(75);
	signal(SIGPIPE, SIG_IGN);
	if (root_user == NULL || root_user->pw_uid != 0 || geteuid() != 0) {
		fprintf(stderr, "run this guest test as root\n");
		return 1;
	}
	test_user = getpwnam("finchtest");
	if (test_user == NULL || test_user->pw_uid == 0) {
		fprintf(stderr, "the separate finchtest account is required\n");
		return 1;
	}
	uid = test_user->pw_uid;
	gid = test_user->pw_gid;
	base_dir = mkdtemp(base_template);
	if (base_dir == NULL ||
	    snprintf(locked_dir, sizeof(locked_dir), "%s/locked", base_template) >= (int)sizeof(locked_dir) ||
	    snprintf(target_path, sizeof(target_path), "%s/locked/target", base_template) >= (int)sizeof(target_path)) {
		fprintf(stderr, "could not create the private test paths: %s\n", strerror(errno));
		failed = 1;
		goto cleanup;
	}
	if (chown(base_template, uid, gid) != 0 || chmod(base_template, 0700) != 0 ||
	    mkdir(locked_dir, 0700) != 0 || chown(locked_dir, uid, gid) != 0 ||
	    chmod(locked_dir, 0700) != 0 || create_owned_file(target_path, uid, gid) != 0) {
		fprintf(stderr, "could not prepare the owned test tree: %s\n", strerror(errno));
		failed = 1;
		goto cleanup;
	}
	target_fd = open_append_file(target_path);
	if (target_fd < 0 || chmod(locked_dir, 0000) != 0) {
		fprintf(stderr, "could not hide the owned test directory: %s\n", strerror(errno));
		failed = 1;
		goto cleanup;
	}
	(void)snprintf(name, sizeof(name),
	    "user.uid.%u.org.finch.test.notify-path-permission.%ld.%08x",
	    (unsigned int)uid, (long)getpid(), nonce);
	if (pipe(command_pipe) != 0 || pipe(result_pipe) != 0) {
		fprintf(stderr, "could not create child pipes: %s\n", strerror(errno));
		failed = 1;
		goto cleanup;
	}
	if (set_cloexec(command_pipe[1]) != 0 || set_cloexec(result_pipe[0]) != 0) {
		fprintf(stderr, "could not protect child pipe ends: %s\n", strerror(errno));
		failed = 1;
		goto cleanup;
	}
	(void)snprintf(command_fd_arg, sizeof(command_fd_arg), "%d", command_pipe[0]);
	(void)snprintf(result_fd_arg, sizeof(result_fd_arg), "%d", result_pipe[1]);
	(void)snprintf(uid_arg, sizeof(uid_arg), "%u", (unsigned int)uid);
	(void)snprintf(gid_arg, sizeof(gid_arg), "%u", (unsigned int)gid);
	child.pid = fork();
	if (child.pid < 0) {
		fprintf(stderr, "could not start the nonroot child: %s\n", strerror(errno));
		failed = 1;
		goto cleanup;
	}
	if (child.pid == 0) {
		close(command_pipe[1]); close(result_pipe[0]);
		close(target_fd);
		execlp(executable, executable, "--child", command_fd_arg, result_fd_arg,
		    name, target_path, uid_arg, gid_arg, (char *)NULL);
		_exit(127);
	}
	close(command_pipe[0]); command_pipe[0] = -1;
	close(result_pipe[1]); result_pipe[1] = -1;
	child.command_fd = command_pipe[1]; command_pipe[1] = -1;
	child.result_fd = result_pipe[0]; result_pipe[0] = -1;
	if (read_byte_timeout(child.result_fd, &marker, START_TIMEOUT_MS) != 0 ||
	    read_all_timeout(child.result_fd, &setup, sizeof(setup), START_TIMEOUT_MS) != 0 || marker != 'R') {
		fprintf(stderr, "nonroot watcher did not finish setup (marker %c): %s\n", marker, strerror(errno));
		failed = 1;
		goto cleanup;
	}
	if (setup.identity_error != 0 || setup.uid != uid || setup.effective_uid != uid ||
	    setup.register_status != NOTIFY_STATUS_OK || setup.monitor_status != NOTIFY_STATUS_OK ||
	    setup.token < 0) {
		fprintf(stderr, "nonroot watcher setup failed (identity %d, register %u, monitor %u)\n",
		    setup.identity_error, setup.register_status, setup.monitor_status);
		failed = 1;
		goto cleanup;
	}

	/* Grant the initially hidden path. No parent folder is changed. */
	if (arm_child(&child) != 0 || chmod(locked_dir, 0700) != 0 ||
	    finish_phase(&child, 'E', &phase) != 0 ||
	    report_phase("initial access restore", &phase, 1, 0) != 0) {
		fprintf(stderr, "initially denied path did not become watchable: %s\n", strerror(errno));
		failed = 1;
	}

	/* Remove search permission, then let the child settle before the hidden write. */
	if (arm_child(&child) != 0 || chmod(locked_dir, 0000) != 0 ||
	    finish_phase(&child, 'Q', &phase) != 0) {
		fprintf(stderr, "could not complete the directory-access loss phase: %s\n", strerror(errno));
		failed = 1;
		goto stop_child;
	}

	/* Keep using the already-open file so root does not traverse the hidden path. */
	if (arm_child(&child) != 0 || append_through_open_fd(target_fd) != 0 ||
	    finish_phase(&child, 'Q', &phase) != 0 ||
	    report_phase("hidden target write", &phase, 0, 1) != 0) {
		fprintf(stderr, "the hidden target change was not quiet: %s\n", strerror(errno));
		failed = 1;
	}

	if (arm_child(&child) != 0 || chmod(locked_dir, 0700) != 0 ||
	    finish_phase(&child, 'E', &phase) != 0 ||
	    report_phase("access restored after loss", &phase, 1, 0) != 0) {
		fprintf(stderr, "watch did not resume when directory access returned: %s\n", strerror(errno));
		failed = 1;
	}

	if (arm_child(&child) != 0 || append_through_open_fd(target_fd) != 0 ||
	    finish_phase(&child, 'E', &phase) != 0 ||
	    report_phase("write after access returned", &phase, 1, 0) != 0) {
		fprintf(stderr, "watch did not report a target write after access returned: %s\n", strerror(errno));
		failed = 1;
	}

	/* Stop while access is denied, so any retry work must be canceled too. */
	if (arm_child(&child) != 0 || chmod(locked_dir, 0000) != 0 ||
	    finish_phase(&child, 'Q', &phase) != 0) {
		fprintf(stderr, "could not block access before cancel\n");
		failed = 1;
	}

stop_child:
	if (child.command_fd >= 0) {
		(void)write_byte(child.command_fd, 'X');
		close(child.command_fd); child.command_fd = -1;
	}
	if (child.result_fd >= 0) { close(child.result_fd); child.result_fd = -1; }
	if (child.pid > 0) {
		if (wait_for_child(child.pid, &child_status) != 0) {
			(void)kill(child.pid, SIGKILL);
			while (waitpid(child.pid, &child_status, 0) < 0 && errno == EINTR) {}
			fprintf(stderr, "nonroot watcher did not stop in time\n");
			failed = 1;
		} else if (!WIFEXITED(child_status) || WEXITSTATUS(child_status) != 0) {
			fprintf(stderr, "nonroot watcher exited with status %d\n", child_status);
			failed = 1;
		}
		child.pid = -1;
	}

cleanup:
	if (child.pid > 0) {
		(void)kill(child.pid, SIGKILL);
		while (waitpid(child.pid, &child_status, 0) < 0 && errno == EINTR) {}
	}
	if (child.command_fd >= 0) close(child.command_fd);
	if (child.result_fd >= 0) close(child.result_fd);
	if (command_pipe[0] >= 0) close(command_pipe[0]);
	if (command_pipe[1] >= 0) close(command_pipe[1]);
	if (result_pipe[0] >= 0) close(result_pipe[0]);
	if (result_pipe[1] >= 0) close(result_pipe[1]);
	if (target_fd >= 0) close(target_fd);
	if (locked_dir[0] != '\0') (void)chmod(locked_dir, 0700);
	if (target_path[0] != '\0') (void)unlink(target_path);
	if (locked_dir[0] != '\0') (void)rmdir(locked_dir);
	if (base_dir != NULL) (void)rmdir(base_dir);
	alarm(0);
	if (failed) return 1;
	puts("notify-path-permission: PASS (hidden writes stayed quiet; access restore woke the same watcher; cancel stopped blocked work)");
	return 0;
}

int
main(int argc, char **argv)
{
	alarm(75);
	signal(SIGPIPE, SIG_IGN);
	if (argc == 8 && strcmp(argv[1], "--child") == 0) {
		int command_fd, result_fd;
		uid_t uid;
		gid_t gid;
		if (parse_fd(argv[2], &command_fd) != 0 || parse_fd(argv[3], &result_fd) != 0 ||
		    command_fd == result_fd || strlen(argv[4]) >= NAME_SIZE ||
		    strlen(argv[5]) >= PATH_SIZE || argv[5][0] != '/' ||
		    parse_uid(argv[6], &uid) != 0 || parse_gid(argv[7], &gid) != 0) {
			fprintf(stderr, "invalid notify-path-permission child arguments\n");
			return 2;
		}
		return watcher_child(command_fd, result_fd, argv[4], argv[5], uid, gid);
	}
	if (argc != 1) {
		fprintf(stderr, "usage: %s [internal child arguments]\n", argv[0]);
		return 2;
	}
	return parent_main(argv[0]);
}
