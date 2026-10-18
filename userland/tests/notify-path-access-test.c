/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Finch guest test for notifyd path-watch access checks.
 * Run as root in the VM. All watched paths live under one temporary folder.
 */
#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <limits.h>
#include <notify.h>
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

/* This exported function is private and is not declared in notify.h. */
extern uint32_t notify_monitor_file(int token, char *path, int flags);

#define CHILD_READY_WAIT_MS 5000
#define CHILD_RESULT_WAIT_MS 6000
#define CHILD_EXIT_WAIT_MS 2000
#define SETUP_DRAIN_NS (500ull * 1000000ull)
#define EVENT_WAIT_NS (3000ull * 1000000ull)
#define QUIET_WAIT_NS (750ull * 1000000ull)
#define PATH_NODE_ALL 0x3ff
#define NAME_BUFFER_SIZE 192
#define PATH_BUFFER_SIZE 1024

struct child_result {
	uid_t uid;
	uid_t effective_uid;
	int identity_errno;
	int private_open_errno;
	int private_register_status;
	int readable_register_status;
	int private_monitor_status;
	int readable_monitor_status;
	unsigned int setup_private_events;
	unsigned int setup_readable_events;
	unsigned int private_events_after_change;
	unsigned int readable_events_after_change;
	int readable_open_errno;
	char readable_first_byte;
	int command_errno;
	int private_cancel_status;
	int readable_cancel_status;
};

static dispatch_semaphore_t event_semaphore;
static dispatch_queue_t event_queue;
static atomic_uint private_event_count;
static atomic_uint readable_event_count;

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
read_all(int fd, void *buffer, size_t size)
{
	char *bytes = buffer;

	while (size != 0) {
		ssize_t got = read(fd, bytes, size);
		if (got < 0 && errno == EINTR) continue;
		if (got <= 0) return -1;
		bytes += got;
		size -= (size_t)got;
	}
	return 0;
}

static int
read_byte_with_timeout(int fd, char *byte, int timeout_ms)
{
	struct pollfd descriptor = { .fd = fd, .events = POLLIN | POLLHUP };
	int status;
	ssize_t got;

	do {
		status = poll(&descriptor, 1, timeout_ms);
	} while (status < 0 && errno == EINTR);
	if (status < 0) return -1;
	if (status == 0) {
		errno = ETIMEDOUT;
		return -1;
	}
	do {
		got = read(fd, byte, 1);
	} while (got < 0 && errno == EINTR);
	if (got == 1) return 0;
	if (got == 0) errno = EPIPE;
	return -1;
}

static int
write_byte(int fd, char byte)
{
	return write_all(fd, &byte, 1);
}

static int
wait_for_child(pid_t child, int *status)
{
	struct timespec pause = { .tv_sec = 0, .tv_nsec = 10 * 1000 * 1000 };
	for (int i = 0; i < CHILD_EXIT_WAIT_MS / 10; i++) {
		pid_t waited = waitpid(child, status, WNOHANG);
		if (waited == child) return 0;
		if (waited < 0 && errno != EINTR) return -1;
		(void)nanosleep(&pause, NULL);
	}
	errno = ETIMEDOUT;
	return -1;
}

static int
parse_unsigned_argument(const char *text, unsigned long long maximum,
	unsigned long long *value)
{
	char *end = NULL;
	unsigned long long parsed;

	if (text == NULL || text[0] == '\0' || text[0] == '-') return -1;
	errno = 0;
	parsed = strtoull(text, &end, 10);
	if (errno != 0 || end == text || *end != '\0' || parsed > maximum) return -1;
	*value = parsed;
	return 0;
}

static int
parse_fd_argument(const char *text, int *fd)
{
	unsigned long long value;

	if (parse_unsigned_argument(text, INT_MAX, &value) != 0) return -1;
	*fd = (int)value;
	return 0;
}

static int
parse_uid_argument(const char *text, uid_t *uid)
{
	unsigned long long value;
	uid_t parsed;

	if (parse_unsigned_argument(text, ULLONG_MAX, &value) != 0) return -1;
	parsed = (uid_t)value;
	if ((unsigned long long)parsed != value) return -1;
	*uid = parsed;
	return 0;
}

static int
parse_gid_argument(const char *text, gid_t *gid)
{
	unsigned long long value;
	gid_t parsed;

	if (parse_unsigned_argument(text, ULLONG_MAX, &value) != 0) return -1;
	parsed = (gid_t)value;
	if ((unsigned long long)parsed != value) return -1;
	*gid = parsed;
	return 0;
}

static int
valid_text_argument(const char *text, size_t maximum)
{
	return text != NULL && text[0] != '\0' && strlen(text) < maximum;
}

static void
initialize_child_result(struct child_result *result)
{
	memset(result, 0, sizeof(*result));
	result->private_open_errno = -1;
	result->private_register_status = -1;
	result->readable_register_status = -1;
	result->private_monitor_status = -1;
	result->readable_monitor_status = -1;
	result->readable_open_errno = -1;
	result->command_errno = 0;
	result->private_cancel_status = -1;
	result->readable_cancel_status = -1;
}

static void
wait_for_setup_quiet(void)
{
	dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t)SETUP_DRAIN_NS);
	while (dispatch_semaphore_wait(event_semaphore, deadline) == 0) {
		/* Drain setup-time revoke/delete events before the mutation check. */
	}
	dispatch_sync(event_queue, ^{});
}

static void
wait_for_mutation_events(void)
{
	dispatch_time_t event_deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t)EVENT_WAIT_NS);
	while (atomic_load_explicit(&readable_event_count, memory_order_relaxed) == 0) {
		if (dispatch_semaphore_wait(event_semaphore, event_deadline) != 0) break;
	}

	/* Keep watching the private path for a quiet window after the allowed path
	 * proves that notifyd delivered a real filesystem event. */
	dispatch_time_t quiet_deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t)QUIET_WAIT_NS);
	while (dispatch_semaphore_wait(event_semaphore, quiet_deadline) == 0) {
		/* Count every callback until the same quiet deadline expires. */
	}
	dispatch_sync(event_queue, ^{});
}

static int
child_main(int command_fd, int result_fd, char *private_name, char *readable_name,
	char *private_path, char *readable_path, uid_t test_uid, gid_t test_gid)
{
	struct child_result result;
	int private_token = NOTIFY_TOKEN_INVALID;
	int readable_token = NOTIFY_TOKEN_INVALID;
	int private_fd;
	int readable_fd;
	char command;
	int exit_status = 1;
	int ready_sent = 0;

	alarm(20);
	initialize_child_result(&result);
	atomic_init(&private_event_count, 0);
	atomic_init(&readable_event_count, 0);
	event_semaphore = dispatch_semaphore_create(0);
	event_queue = dispatch_queue_create("org.finch.test.notify-path-access", DISPATCH_QUEUE_SERIAL);
	if (event_semaphore == NULL || event_queue == NULL) {
		result.identity_errno = ENOMEM;
		goto report;
	}

	/* Drop every root group as well as the root user before calling notifyd. */
	if (setgroups(1, &test_gid) != 0 || setgid(test_gid) != 0 ||
	    setuid(test_uid) != 0) {
		result.identity_errno = errno;
		goto report;
	}
	result.uid = getuid();
	result.effective_uid = geteuid();
	if (result.uid != test_uid || result.effective_uid != test_uid) {
		result.identity_errno = EPERM;
		goto done;
	}

	private_fd = open(private_path, O_RDONLY);
	result.private_open_errno = private_fd < 0 ? errno : 0;
	if (private_fd >= 0) close(private_fd);

	result.private_register_status = (int)notify_register_dispatch(private_name,
	    &private_token, event_queue, ^(int token) {
		(void)token;
		atomic_fetch_add_explicit(&private_event_count, 1, memory_order_relaxed);
		dispatch_semaphore_signal(event_semaphore);
	});
	result.readable_register_status = (int)notify_register_dispatch(readable_name,
	    &readable_token, event_queue, ^(int token) {
		(void)token;
		atomic_fetch_add_explicit(&readable_event_count, 1, memory_order_relaxed);
		dispatch_semaphore_signal(event_semaphore);
	});
	if (result.private_register_status == NOTIFY_STATUS_OK) {
		result.private_monitor_status = (int)notify_monitor_file(private_token,
		    private_path, PATH_NODE_ALL);
	}
	if (result.readable_register_status == NOTIFY_STATUS_OK) {
		result.readable_monitor_status = (int)notify_monitor_file(readable_token,
		    readable_path, PATH_NODE_ALL);
	}
	if (result.identity_errno != 0 || result.private_open_errno != EACCES ||
	    result.private_register_status != NOTIFY_STATUS_OK ||
	    result.readable_register_status != NOTIFY_STATUS_OK ||
	    result.private_monitor_status != NOTIFY_STATUS_OK ||
	    result.readable_monitor_status != NOTIFY_STATUS_OK) {
		goto report;
	}

	/* The path watcher can report setup-time revoke/delete events. Record and
	 * drain them before root changes either test path. */
	wait_for_setup_quiet();
	result.setup_private_events = atomic_load_explicit(&private_event_count, memory_order_relaxed);
	result.setup_readable_events = atomic_load_explicit(&readable_event_count, memory_order_relaxed);
	atomic_store_explicit(&private_event_count, 0, memory_order_relaxed);
	atomic_store_explicit(&readable_event_count, 0, memory_order_relaxed);
	if (write_byte(result_fd, 'R') != 0) goto done;
	ready_sent = 1;

	if (read_byte_with_timeout(command_fd, &command, CHILD_READY_WAIT_MS) != 0) {
		result.command_errno = errno != 0 ? errno : EPIPE;
		goto report;
	}
	if (command != 'C') {
		result.command_errno = EPROTO;
		goto report;
	}

	readable_fd = open(readable_path, O_RDONLY);
	result.readable_open_errno = readable_fd < 0 ? errno : 0;
	if (readable_fd >= 0) {
		if (read_all(readable_fd, &result.readable_first_byte, 1) != 0)
			result.readable_open_errno = errno != 0 ? errno : EIO;
		close(readable_fd);
	}

	wait_for_mutation_events();
	result.private_events_after_change = atomic_load_explicit(&private_event_count, memory_order_relaxed);
	result.readable_events_after_change = atomic_load_explicit(&readable_event_count, memory_order_relaxed);
	if (private_token != NOTIFY_TOKEN_INVALID)
		result.private_cancel_status = (int)notify_cancel(private_token);
	if (readable_token != NOTIFY_TOKEN_INVALID)
		result.readable_cancel_status = (int)notify_cancel(readable_token);
	dispatch_sync(event_queue, ^{});
	result.private_events_after_change = atomic_load_explicit(&private_event_count, memory_order_relaxed);
	result.readable_events_after_change = atomic_load_explicit(&readable_event_count, memory_order_relaxed);

	if (result.readable_open_errno == 0 && result.readable_first_byte == 'r' &&
	    result.readable_events_after_change > 0 &&
	    result.private_events_after_change == 0 &&
	    result.private_cancel_status == NOTIFY_STATUS_OK &&
	    result.readable_cancel_status == NOTIFY_STATUS_OK) {
		exit_status = 0;
	}

report:
	/* F carries a failed setup result. D carries the final result after the
	 * parent has seen R and allowed the two path changes. */
	if (write_byte(result_fd, ready_sent ? 'D' : 'F') != 0) exit_status = 1;
	if (write_all(result_fd, &result, sizeof(result)) != 0) exit_status = 1;
done:
	close(command_fd);
	close(result_fd);
	return exit_status;
}

static int
report_child_result(const struct child_result *result, int wait_status)
{
	int failed = 0;

	if (!WIFEXITED(wait_status) || WEXITSTATUS(wait_status) != 0) {
		fprintf(stderr, "finchtest path watcher exited with wait status %d\n", wait_status);
		failed = 1;
	}
	if (result->identity_errno != 0 || result->uid != result->effective_uid) {
		fprintf(stderr, "child did not become finchtest (error %d, uid %u, euid %u)\n",
		    result->identity_errno, result->uid, result->effective_uid);
		failed = 1;
	}
	if (result->private_open_errno != EACCES) {
		fprintf(stderr, "finchtest could open the root-only path (error %d)\n",
		    result->private_open_errno);
		failed = 1;
	}
	if (result->private_register_status != NOTIFY_STATUS_OK ||
	    result->readable_register_status != NOTIFY_STATUS_OK ||
	    result->private_monitor_status != NOTIFY_STATUS_OK ||
	    result->readable_monitor_status != NOTIFY_STATUS_OK) {
		fprintf(stderr, "path watch setup failed (register %d/%d, monitor %d/%d)\n",
		    result->private_register_status, result->readable_register_status,
		    result->private_monitor_status, result->readable_monitor_status);
		failed = 1;
	}
	if (result->command_errno != 0) {
		fprintf(stderr, "child did not receive the path-change signal (error %d)\n",
		    result->command_errno);
		failed = 1;
	}
	if (result->readable_open_errno != 0 || result->readable_first_byte != 'r') {
		fprintf(stderr, "finchtest could not read the allowed path (error %d, byte %d)\n",
		    result->readable_open_errno, (int)(unsigned char)result->readable_first_byte);
		failed = 1;
	}
	if (result->readable_events_after_change == 0) {
		fprintf(stderr, "allowed path change did not reach finchtest\n");
		failed = 1;
	}
	if (result->private_events_after_change != 0) {
		fprintf(stderr, "root-only path change reached finchtest (%u event(s))\n",
		    result->private_events_after_change);
		failed = 1;
	}
	if (result->private_cancel_status != NOTIFY_STATUS_OK ||
	    result->readable_cancel_status != NOTIFY_STATUS_OK) {
		fprintf(stderr, "child path watch cleanup failed (%d/%d)\n",
		    result->private_cancel_status, result->readable_cancel_status);
		failed = 1;
	}
	if (result->setup_private_events != 0 || result->setup_readable_events != 0) {
		fprintf(stderr, "path watch setup emitted callbacks before file changes (%u/%u); these were drained before the check\n",
		    result->setup_private_events, result->setup_readable_events);
	}
	return failed;
}

static int
make_child_directory(const char *path, uid_t uid, gid_t gid)
{
	if (mkdir(path, 0700) != 0) return -1;
	if (chown(path, uid, gid) != 0) return -1;
	if (chmod(path, 0700) != 0) return -1;
	return 0;
}

static int
append_private_file(const char *path)
{
	int fd = open(path, O_WRONLY | O_APPEND | O_NOFOLLOW);
	if (fd < 0) return -1;
	if (write_all(fd, "root update\n", 12) != 0 || fsync(fd) != 0) {
		int saved_errno = errno;
		close(fd);
		errno = saved_errno;
		return -1;
	}
	return close(fd);
}

static int
create_readable_file(const char *path)
{
	int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0644);
	if (fd < 0) return -1;
	if (fchmod(fd, 0644) != 0 || write_all(fd, "readable path\n", 14) != 0 || fsync(fd) != 0) {
		int saved_errno = errno;
		close(fd);
		unlink(path);
		errno = saved_errno;
		return -1;
	}
	return close(fd);
}

int
main(int argc, char **argv)
{
	alarm(45);
	signal(SIGPIPE, SIG_IGN);
	if (argc == 10 && strcmp(argv[1], "--child") == 0) {
		int command_fd;
		int result_fd;
		uid_t test_uid;
		gid_t test_gid;

		/* Libnotify disables its APIs in some fork children. Exec first so the
		 * watcher starts with fresh client state. */
		if (parse_fd_argument(argv[2], &command_fd) != 0 ||
		    parse_fd_argument(argv[3], &result_fd) != 0 ||
		    command_fd == result_fd ||
		    !valid_text_argument(argv[4], NAME_BUFFER_SIZE) ||
		    !valid_text_argument(argv[5], NAME_BUFFER_SIZE) ||
		    strcmp(argv[4], argv[5]) == 0 ||
		    !valid_text_argument(argv[6], PATH_BUFFER_SIZE) ||
		    !valid_text_argument(argv[7], PATH_BUFFER_SIZE) ||
		    strcmp(argv[6], argv[7]) == 0 ||
		    argv[6][0] != '/' || argv[7][0] != '/' ||
		    parse_uid_argument(argv[8], &test_uid) != 0 ||
		    parse_gid_argument(argv[9], &test_gid) != 0) {
			fprintf(stderr, "invalid notify-path-access child arguments\n");
			return 2;
		}
		return child_main(command_fd, result_fd, argv[4], argv[5], argv[6], argv[7],
		    test_uid, test_gid);
	}
	if (argc != 1) {
		fprintf(stderr, "usage: %s [--child command-fd result-fd private-name readable-name private-path readable-path uid gid]\n",
		    argv[0]);
		return 2;
	}

	struct passwd *root_user = getpwnam("root");
	uid_t root_uid;
	struct passwd *test_user;
	uid_t test_uid;
	gid_t test_gid;
	unsigned int nonce = arc4random();
	char base_template[] = "/tmp/finch-notify-path-access.XXXXXX";
	char *base_dir = NULL;
	char private_dir[PATH_BUFFER_SIZE] = { 0 };
	char readable_dir[PATH_BUFFER_SIZE] = { 0 };
	char private_path[PATH_BUFFER_SIZE] = { 0 };
	char readable_path[PATH_BUFFER_SIZE] = { 0 };
	char private_name[NAME_BUFFER_SIZE];
	char readable_name[NAME_BUFFER_SIZE];
	char command_fd_arg[16];
	char result_fd_arg[16];
	char test_uid_arg[32];
	char test_gid_arg[32];
	int command_pipe[2] = { -1, -1 };
	int result_pipe[2] = { -1, -1 };
	pid_t child = -1;
	int child_wait_status = 0;
	struct child_result child_result;
	char child_ready = '\0';
	int failed = 0;
	int private_fd = -1;

	if (root_user == NULL || root_user->pw_uid != 0) {
		fprintf(stderr, "the root account is required for this test\n");
		return 1;
	}
	root_uid = root_user->pw_uid;
	test_user = getpwnam("finchtest");
	if (test_user == NULL) {
		fprintf(stderr, "the finchtest account is required for this test\n");
		return 1;
	}
	test_uid = test_user->pw_uid;
	test_gid = test_user->pw_gid;
	if (test_uid == root_uid || geteuid() != root_uid) {
		fprintf(stderr, "run this test as root with a separate finchtest account\n");
		return 1;
	}

	base_dir = mkdtemp(base_template);
	if (base_dir == NULL ||
	    snprintf(private_dir, sizeof(private_dir), "%s/hidden", base_template) >= (int)sizeof(private_dir) ||
	    snprintf(readable_dir, sizeof(readable_dir), "%s/readable", base_template) >= (int)sizeof(readable_dir) ||
	    snprintf(private_path, sizeof(private_path), "%s/secret", private_dir) >= (int)sizeof(private_path) ||
	    snprintf(readable_path, sizeof(readable_path), "%s/created", readable_dir) >= (int)sizeof(readable_path)) {
		fprintf(stderr, "could not prepare temporary test paths: %s\n", strerror(errno));
		failed = 1;
		goto cleanup;
	}
	if (make_child_directory(private_dir, root_uid, 0) != 0 ||
	    make_child_directory(readable_dir, test_uid, test_gid) != 0 ||
	    chmod(base_template, 0755) != 0) {
		fprintf(stderr, "could not prepare test directories: %s\n", strerror(errno));
		failed = 1;
		goto cleanup;
	}
	private_fd = open(private_path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
	if (private_fd < 0 || write_all(private_fd, "private data\n", 13) != 0 ||
	    fsync(private_fd) != 0 || close(private_fd) != 0) {
		fprintf(stderr, "could not create root-only test file: %s\n", strerror(errno));
		if (private_fd >= 0) close(private_fd);
		private_fd = -1;
		failed = 1;
		goto cleanup;
	}
	private_fd = -1;
	(void)snprintf(private_name, sizeof(private_name),
	    "user.uid.%u.org.finch.test.notify-path-access.%ld.%08x.private",
	    (unsigned int)test_uid, (long)getpid(), nonce);
	(void)snprintf(readable_name, sizeof(readable_name),
	    "user.uid.%u.org.finch.test.notify-path-access.%ld.%08x.readable",
	    (unsigned int)test_uid, (long)getpid(), nonce);

	if (pipe(command_pipe) != 0 || pipe(result_pipe) != 0) {
		fprintf(stderr, "could not create child pipes: %s\n", strerror(errno));
		failed = 1;
		goto cleanup;
	}
	(void)snprintf(command_fd_arg, sizeof(command_fd_arg), "%d", command_pipe[0]);
	(void)snprintf(result_fd_arg, sizeof(result_fd_arg), "%d", result_pipe[1]);
	(void)snprintf(test_uid_arg, sizeof(test_uid_arg), "%u", (unsigned int)test_uid);
	(void)snprintf(test_gid_arg, sizeof(test_gid_arg), "%u", (unsigned int)test_gid);
	child = fork();
	if (child < 0) {
		fprintf(stderr, "could not start finchtest child: %s\n", strerror(errno));
		failed = 1;
		goto cleanup;
	}
	if (child == 0) {
		close(command_pipe[1]);
		close(result_pipe[0]);
		execlp(argv[0], argv[0], "--child", command_fd_arg, result_fd_arg,
		    private_name, readable_name, private_path, readable_path,
		    test_uid_arg, test_gid_arg, (char *)NULL);
		int exec_error = errno;
		(void)exec_error;
		_exit(127);
	}
	close(command_pipe[0]);
	command_pipe[0] = -1;
	close(result_pipe[1]);
	result_pipe[1] = -1;

	if (read_byte_with_timeout(result_pipe[0], &child_ready, CHILD_READY_WAIT_MS) != 0) {
		fprintf(stderr, "finchtest did not finish path-watch setup within %d ms\n",
		    CHILD_READY_WAIT_MS);
		failed = 1;
		goto cleanup;
	}
	if (child_ready == 'R') {
		if (append_private_file(private_path) != 0 || create_readable_file(readable_path) != 0) {
			fprintf(stderr, "root could not change the temporary test files: %s\n", strerror(errno));
			failed = 1;
			goto cleanup;
		}
		if (write_byte(command_pipe[1], 'C') != 0) {
			fprintf(stderr, "could not resume finchtest path checks: %s\n", strerror(errno));
			failed = 1;
			goto cleanup;
		}
	} else if (child_ready != 'F') {
		fprintf(stderr, "finchtest sent an invalid path-watch setup response\n");
		failed = 1;
		goto cleanup;
	}

	if (child_ready == 'R' &&
	    (read_byte_with_timeout(result_pipe[0], &child_ready, CHILD_RESULT_WAIT_MS) != 0 ||
	    child_ready != 'D')) {
		fprintf(stderr, "finchtest did not return path-watch results within %d ms\n",
		    CHILD_RESULT_WAIT_MS);
		failed = 1;
		goto cleanup;
	}
	if (read_all(result_pipe[0], &child_result, sizeof(child_result)) != 0) {
		fprintf(stderr, "finchtest sent an incomplete path-watch result\n");
		failed = 1;
		goto cleanup;
	}
	if (wait_for_child(child, &child_wait_status) != 0) {
		fprintf(stderr, "finchtest did not exit within %d ms\n", CHILD_EXIT_WAIT_MS);
		failed = 1;
		goto cleanup;
	}
	child = -1;
	failed |= report_child_result(&child_result, child_wait_status);

cleanup:
	if (child > 0) {
		(void)kill(child, SIGKILL);
		while (waitpid(child, &child_wait_status, 0) < 0 && errno == EINTR) {}
	}
	if (command_pipe[0] >= 0) close(command_pipe[0]);
	if (command_pipe[1] >= 0) close(command_pipe[1]);
	if (result_pipe[0] >= 0) close(result_pipe[0]);
	if (result_pipe[1] >= 0) close(result_pipe[1]);
	if (private_fd >= 0) close(private_fd);
	if (readable_path[0] != '\0') unlink(readable_path);
	if (private_path[0] != '\0') unlink(private_path);
	if (readable_dir[0] != '\0') rmdir(readable_dir);
	if (private_dir[0] != '\0') rmdir(private_dir);
	if (base_dir != NULL) rmdir(base_dir);
	if (failed) return 1;
	puts("notify-path-access: PASS (finchtest cannot watch the root-only path; it can watch and read a new allowed file)");
	return 0;
}
