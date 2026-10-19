/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Check that notifyd path watches still use direct delivery when the client
 * has not started dispatch. Run as root in the Finch VM; children use finchtest.
 */
#include <arpa/inet.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <limits.h>
#include <mach/mach.h>
#include <notify.h>
#include <notify_private.h>
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
#include <stdbool.h>

/* Private libdispatch query used only to prove the direct client is unthreaded. */
extern bool _dispatch_is_multithreaded(void);

#define PATH_NODE_ALL 0x3ff
#define MODE_FILE (1u << 0)
#define MODE_SIGNAL (1u << 1)
#define MODE_PORT (1u << 2)
#define MODE_ALL (MODE_FILE | MODE_SIGNAL | MODE_PORT)
#define NAME_SIZE 192
#define PATH_SIZE 1024
#define CHILD_START_TIMEOUT_MS 6000
#define CHILD_RESULT_TIMEOUT_MS 6000
#define CHILD_EXIT_TIMEOUT_MS 3000
#define EVENT_TIMEOUT_MS 4000
#define EVENT_QUIET_MS 250
#define SETUP_QUIET_MS 500
#define OBSERVER_QUIET_MS 600
#define POLL_NS (10ull * 1000000ull)

struct child_process {
	pid_t pid;
	int command_fd;
	int result_fd;
};

struct watcher_setup {
	int identity_error;
	uid_t uid;
	uid_t effective_uid;
	int multithreaded_before_file;
	int multithreaded_before_signal;
	int register_status[3];
	int monitor_status[3];
	int token[3];
};

struct event_result {
	uint32_t expected_mask;
	uint32_t received_mask;
	uint32_t wrong_token_mask;
	uint32_t api_error_mask;
	uint32_t signal_count;
};

struct cancel_result {
	uint32_t status[3];
	int file_fd_closed;
};

struct observer_result {
	int identity_error;
	uid_t uid;
	uid_t effective_uid;
	uint32_t register_status;
	uint32_t callback_count;
	uint32_t wrong_token_count;
};

struct watcher_state {
	int file_token;
	int signal_token;
	int port_token;
	int file_fd;
	mach_port_t port;
	int signal_number;
	sig_atomic_t signal_baseline;
};

static volatile sig_atomic_t signal_count;
static dispatch_queue_t observer_queue;
static atomic_uint observer_callback_count;
static atomic_uint observer_wrong_token_count;
static int observer_token = NOTIFY_TOKEN_INVALID;
static int observer_expected_token = NOTIFY_TOKEN_INVALID;

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
read_byte_timeout(int fd, char *byte, int timeout_ms)
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
	return write_all(fd, &byte, sizeof(byte));
}

static int
parse_unsigned(const char *text, unsigned long long max, unsigned long long *value)
{
	char *end = NULL;
	unsigned long long parsed;

	if (text == NULL || text[0] == '\0' || text[0] == '-') return -1;
	errno = 0;
	parsed = strtoull(text, &end, 10);
	if (errno != 0 || end == text || *end != '\0' || parsed > max) return -1;
	*value = parsed;
	return 0;
}

static int
parse_fd(const char *text, int *fd)
{
	unsigned long long value;
	if (parse_unsigned(text, INT_MAX, &value) != 0) return -1;
	*fd = (int)value;
	return 0;
}

static int
parse_uid(const char *text, uid_t *uid)
{
	unsigned long long value;
	uid_t parsed;
	if (parse_unsigned(text, ULLONG_MAX, &value) != 0) return -1;
	parsed = (uid_t)value;
	if ((unsigned long long)parsed != value) return -1;
	*uid = parsed;
	return 0;
}

static int
parse_gid(const char *text, gid_t *gid)
{
	unsigned long long value;
	gid_t parsed;
	if (parse_unsigned(text, ULLONG_MAX, &value) != 0) return -1;
	parsed = (gid_t)value;
	if ((unsigned long long)parsed != value) return -1;
	*gid = parsed;
	return 0;
}

static int
valid_text(const char *text, size_t max)
{
	return text != NULL && text[0] != '\0' && strlen(text) < max;
}

static uint64_t
monotonic_ns(void)
{
	struct timespec now;
	if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0;
	return (uint64_t)now.tv_sec * 1000000000ull + (uint64_t)now.tv_nsec;
}

static void
pause_briefly(void)
{
	struct timespec pause = { .tv_sec = 0, .tv_nsec = (long)POLL_NS };
	while (nanosleep(&pause, &pause) != 0 && errno == EINTR) {}
}

static void
record_signal(int signal_number)
{
	if (signal_number == SIGUSR1) signal_count++;
}

static int
install_signal_handler(void)
{
	struct sigaction action;
	memset(&action, 0, sizeof(action));
	action.sa_handler = record_signal;
	sigemptyset(&action.sa_mask);
	action.sa_flags = SA_RESTART;
	return sigaction(SIGUSR1, &action, NULL);
}

static int
drop_to_user(uid_t uid, gid_t gid, struct watcher_setup *report)
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
initialize_watcher(struct watcher_state *watcher)
{
	memset(watcher, 0, sizeof(*watcher));
	watcher->file_token = NOTIFY_TOKEN_INVALID;
	watcher->signal_token = NOTIFY_TOKEN_INVALID;
	watcher->port_token = NOTIFY_TOKEN_INVALID;
	watcher->file_fd = -1;
	watcher->port = MACH_PORT_NULL;
	watcher->signal_number = SIGUSR1;
}

static int
cancel_watcher(struct watcher_state *watcher, struct cancel_result *result)
{
	int *tokens[3] = { &watcher->file_token, &watcher->signal_token, &watcher->port_token };
	memset(result, 0, sizeof(*result));
	for (int i = 0; i < 3; i++) {
		if (*tokens[i] == NOTIFY_TOKEN_INVALID) {
			result->status[i] = NOTIFY_STATUS_OK;
			continue;
		}
		result->status[i] = notify_cancel(*tokens[i]);
		if (result->status[i] == NOTIFY_STATUS_OK) {
			*tokens[i] = NOTIFY_TOKEN_INVALID;
			if (i == 2) watcher->port = MACH_PORT_NULL;
		}
	}
	if (watcher->file_fd >= 0) {
		errno = 0;
		result->file_fd_closed = fcntl(watcher->file_fd, F_GETFD) < 0 && errno == EBADF;
	}
	return result->status[0] == NOTIFY_STATUS_OK &&
	    result->status[1] == NOTIFY_STATUS_OK &&
	    result->status[2] == NOTIFY_STATUS_OK ? 0 : -1;
}

static int
receive_fd_event(struct watcher_state *watcher, struct event_result *result,
	int *activity)
{
	struct pollfd descriptor;
	uint32_t value = 0;
	ssize_t count;
	int status;

	if (watcher->file_token == NOTIFY_TOKEN_INVALID || watcher->file_fd < 0) return 0;
	descriptor.fd = watcher->file_fd;
	descriptor.events = POLLIN | POLLHUP;
	descriptor.revents = 0;
	status = poll(&descriptor, 1, 0);
	if (status < 0) {
		if (errno == EINTR) return 0;
		result->api_error_mask |= MODE_FILE;
		return -1;
	}
	if (status == 0 || (descriptor.revents & POLLIN) == 0) return 0;
	do {
		count = read(watcher->file_fd, &value, sizeof(value));
	} while (count < 0 && errno == EINTR);
	if (count != sizeof(value)) {
		result->api_error_mask |= MODE_FILE;
		return -1;
	}
	*activity = 1;
	result->received_mask |= MODE_FILE;
	if (ntohl(value) != (uint32_t)watcher->file_token)
		result->wrong_token_mask |= MODE_FILE;
	return 0;
}

static int
receive_port_event(struct watcher_state *watcher, struct event_result *result,
	int *activity)
{
	mach_msg_empty_rcv_t message;
	kern_return_t status;

	if (watcher->port_token == NOTIFY_TOKEN_INVALID || watcher->port == MACH_PORT_NULL)
		return 0;
	memset(&message, 0, sizeof(message));
	status = mach_msg(&message.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT,
	    0, sizeof(message), watcher->port, 0, MACH_PORT_NULL);
	if (status == MACH_RCV_TIMED_OUT) return 0;
	if (status != KERN_SUCCESS) {
		result->api_error_mask |= MODE_PORT;
		return -1;
	}
	*activity = 1;
	result->received_mask |= MODE_PORT;
	if (message.header.msgh_id != watcher->port_token)
		result->wrong_token_mask |= MODE_PORT;
	return 0;
}

static int
wait_for_direct_events(struct watcher_state *watcher, struct event_result *result,
	sig_atomic_t signal_baseline)
{
	uint64_t deadline = monotonic_ns() + (uint64_t)EVENT_TIMEOUT_MS * 1000000ull;
	uint64_t quiet_since = 0;
	sig_atomic_t last_signal_count = signal_baseline;

	memset(result, 0, sizeof(*result));
	result->expected_mask = MODE_ALL;
	for (;;) {
		int activity = 0;
		uint64_t now;
		if (receive_fd_event(watcher, result, &activity) != 0 ||
		    receive_port_event(watcher, result, &activity) != 0) return -1;
		if (signal_count > last_signal_count) {
			result->received_mask |= MODE_SIGNAL;
			result->signal_count = (uint32_t)(signal_count - signal_baseline);
			last_signal_count = signal_count;
			activity = 1;
		}
		if (result->api_error_mask != 0 || result->wrong_token_mask != 0) return -1;
		now = monotonic_ns();
		if (result->received_mask == MODE_ALL) {
			if (quiet_since == 0 || activity) quiet_since = now;
			if (!activity && now - quiet_since >= (uint64_t)EVENT_QUIET_MS * 1000000ull)
				return 0;
		} else {
			quiet_since = 0;
		}
		if (now >= deadline) return -1;
		pause_briefly();
	}
}

static int
wait_quiet_after_cancel(struct watcher_state *watcher, struct event_result *result)
{
	uint64_t deadline = monotonic_ns() + (uint64_t)OBSERVER_QUIET_MS * 1000000ull;
	memset(result, 0, sizeof(*result));
	result->expected_mask = 0;
	while (monotonic_ns() < deadline) {
		if (signal_count > watcher->signal_baseline) {
			result->received_mask |= MODE_SIGNAL;
			result->signal_count = (uint32_t)(signal_count - watcher->signal_baseline);
		}
		pause_briefly();
	}
	return result->received_mask == 0 ? 0 : -1;
}

static void
cleanup_watcher(struct watcher_state *watcher)
{
	struct cancel_result ignored;
	(void)cancel_watcher(watcher, &ignored);
	if (watcher->port != MACH_PORT_NULL) {
		(void)mach_port_destruct(mach_task_self(), watcher->port, 0, 0);
		watcher->port = MACH_PORT_NULL;
	}
}

static int
watcher_child(int command_fd, int result_fd, const char *name, const char *path,
	uid_t uid, gid_t gid)
{
	struct watcher_setup setup;
	struct watcher_state watcher;
	struct cancel_result canceled;
	char command = '\0';
	sig_atomic_t signal_baseline = 0;
	int status = 1;
	uint64_t setup_deadline;

	memset(&setup, 0, sizeof(setup));
	for (int i = 0; i < 3; i++) {
		setup.register_status[i] = -1;
		setup.monitor_status[i] = -1;
		setup.token[i] = NOTIFY_TOKEN_INVALID;
	}
	initialize_watcher(&watcher);
	if (install_signal_handler() != 0 || drop_to_user(uid, gid, &setup) != 0)
		goto setup_failed;

	/* Keep these calls first: the direct registrations must not start dispatch. */
	setup.multithreaded_before_file = _dispatch_is_multithreaded() ? 1 : 0;
	setup.register_status[0] = (int)notify_register_file_descriptor(name,
	    &watcher.file_fd, 0, &watcher.file_token);
	setup.token[0] = watcher.file_token;
	setup.multithreaded_before_signal = _dispatch_is_multithreaded() ? 1 : 0;
	setup.register_status[1] = (int)notify_register_signal(name,
	    watcher.signal_number, &watcher.signal_token);
	setup.token[1] = watcher.signal_token;
	setup.register_status[2] = (int)notify_register_mach_port(name,
	    &watcher.port, NOTIFY_NO_DISPATCH, &watcher.port_token);
	setup.token[2] = watcher.port_token;

	/* Register every direct token before the first path call can start work. */
	if (setup.register_status[0] == NOTIFY_STATUS_OK)
		setup.monitor_status[0] = (int)notify_monitor_file(watcher.file_token,
		    (char *)path, PATH_NODE_ALL);
	if (setup.register_status[1] == NOTIFY_STATUS_OK)
		setup.monitor_status[1] = (int)notify_monitor_file(watcher.signal_token,
		    (char *)path, PATH_NODE_ALL);
	if (setup.register_status[2] == NOTIFY_STATUS_OK)
		setup.monitor_status[2] = (int)notify_monitor_file(watcher.port_token,
		    (char *)path, PATH_NODE_ALL);
	for (int i = 0; i < 3; i++) {
		if (setup.register_status[i] != NOTIFY_STATUS_OK ||
		    setup.monitor_status[i] != NOTIFY_STATUS_OK) goto setup_failed;
	}
	if (setup.multithreaded_before_file || setup.multithreaded_before_signal)
		goto setup_failed;

	/* Let setup noise settle before the parent changes the file. */
	setup_deadline = monotonic_ns() + (uint64_t)SETUP_QUIET_MS * 1000000ull;
	while (monotonic_ns() < setup_deadline) pause_briefly();
	{
		struct event_result initial;
		int activity = 0;
		memset(&initial, 0, sizeof(initial));
		if (receive_fd_event(&watcher, &initial, &activity) != 0 ||
		    receive_port_event(&watcher, &initial, &activity) != 0 ||
		    (initial.received_mask & MODE_PORT) != 0) goto setup_failed;
		if (signal_count != 0 || initial.received_mask != 0 || initial.api_error_mask != 0)
			goto setup_failed;
	}
	setup.uid = getuid();
	setup.effective_uid = geteuid();
	if (write_byte(result_fd, 'R') != 0 || write_all(result_fd, &setup, sizeof(setup)) != 0)
		goto cleanup;

	for (;;) {
		if (read_byte_timeout(command_fd, &command, 60000) != 0) goto cleanup;
		if (command == 'A') {
			struct event_result initial;
			int activity = 0;
			memset(&initial, 0, sizeof(initial));
			if (receive_fd_event(&watcher, &initial, &activity) != 0 ||
			    receive_port_event(&watcher, &initial, &activity) != 0 || signal_count != 0 ||
			    initial.received_mask != 0 || initial.api_error_mask != 0) {
				(void)write_byte(result_fd, 'F');
				(void)write_all(result_fd, &initial, sizeof(initial));
				goto cleanup;
			}
			signal_baseline = signal_count;
			if (write_byte(result_fd, 'A') != 0) goto cleanup;
			if (read_byte_timeout(command_fd, &command, 60000) != 0 || command != 'G') goto cleanup;
			{
				struct event_result event;
				if (wait_for_direct_events(&watcher, &event, signal_baseline) != 0) status = 1;
				else status = 0;
				if (write_byte(result_fd, 'E') != 0 ||
				    write_all(result_fd, &event, sizeof(event)) != 0) goto cleanup;
			}
		} else if (command == 'C') {
			if (cancel_watcher(&watcher, &canceled) != 0) status = 1;
			watcher.signal_baseline = signal_count;
			if (write_byte(result_fd, 'C') != 0 ||
			    write_all(result_fd, &canceled, sizeof(canceled)) != 0) goto cleanup;
		} else if (command == 'Q') {
			struct event_result quiet;
			if (wait_quiet_after_cancel(&watcher, &quiet) != 0) status = 1;
			if (write_byte(result_fd, 'Q') != 0 ||
			    write_all(result_fd, &quiet, sizeof(quiet)) != 0) goto cleanup;
			break;
		} else {
			goto cleanup;
		}
	}
	status = status == 0 ? 0 : 1;
	goto cleanup;

setup_failed:
	setup.uid = getuid();
	setup.effective_uid = geteuid();
	(void)write_byte(result_fd, 'F');
	(void)write_all(result_fd, &setup, sizeof(setup));
cleanup:
	cleanup_watcher(&watcher);
	if (command_fd >= 0) close(command_fd);
	if (result_fd >= 0) close(result_fd);
	return status;
}

static void
observer_handler(int token)
{
	if (token == observer_expected_token)
		atomic_fetch_add_explicit(&observer_callback_count, 1, memory_order_relaxed);
	else
		atomic_fetch_add_explicit(&observer_wrong_token_count, 1, memory_order_relaxed);
}

static void
observer_wait_quiet(void)
{
	uint64_t deadline = monotonic_ns() + (uint64_t)OBSERVER_QUIET_MS * 1000000ull;
	while (monotonic_ns() < deadline) pause_briefly();
	dispatch_sync(observer_queue, ^{});
}

static int
observer_child(int command_fd, int result_fd, const char *name, uid_t uid, gid_t gid)
{
	struct observer_result result;
	char command = '\0';
	int status = 1;

	memset(&result, 0, sizeof(result));
	atomic_init(&observer_callback_count, 0);
	atomic_init(&observer_wrong_token_count, 0);
	if (setgroups(1, &gid) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		result.identity_error = errno;
		goto setup_failed;
	}
	result.uid = getuid();
	result.effective_uid = geteuid();
	if (result.uid != uid || result.effective_uid != uid) {
		result.identity_error = EPERM;
		goto setup_failed;
	}
	observer_queue = dispatch_queue_create("org.finch.test.notify-path-direct-observer",
	    DISPATCH_QUEUE_SERIAL);
	if (observer_queue == NULL) {
		result.identity_error = ENOMEM;
		goto setup_failed;
	}
	result.register_status = notify_register_dispatch(name, &observer_token,
	    observer_queue, ^(int token) { observer_handler(token); });
	result.callback_count = 0;
	observer_expected_token = observer_token;
	if (result.register_status != NOTIFY_STATUS_OK) goto setup_failed;
	observer_wait_quiet();
	result.callback_count = atomic_load_explicit(&observer_callback_count, memory_order_relaxed);
	result.wrong_token_count = atomic_load_explicit(&observer_wrong_token_count, memory_order_relaxed);
	if (result.callback_count != 0 || result.wrong_token_count != 0) goto setup_failed;
	if (write_byte(result_fd, 'R') != 0 || write_all(result_fd, &result, sizeof(result)) != 0)
		goto cleanup;

	if (read_byte_timeout(command_fd, &command, 60000) != 0 || command != 'S') goto cleanup;
	observer_wait_quiet();
	result.callback_count = atomic_load_explicit(&observer_callback_count, memory_order_relaxed);
	result.wrong_token_count = atomic_load_explicit(&observer_wrong_token_count, memory_order_relaxed);
	if (write_byte(result_fd, 'S') != 0 || write_all(result_fd, &result, sizeof(result)) != 0)
		goto cleanup;
	if (read_byte_timeout(command_fd, &command, 60000) != 0 || command != 'Q') goto cleanup;
	observer_wait_quiet();
	result.callback_count = atomic_load_explicit(&observer_callback_count, memory_order_relaxed);
	result.wrong_token_count = atomic_load_explicit(&observer_wrong_token_count, memory_order_relaxed);
	if (write_byte(result_fd, 'Q') != 0 || write_all(result_fd, &result, sizeof(result)) != 0)
		goto cleanup;
	status = result.callback_count == 0 && result.wrong_token_count == 0 ? 0 : 1;
	goto cleanup;

setup_failed:
	result.callback_count = atomic_load_explicit(&observer_callback_count, memory_order_relaxed);
	result.wrong_token_count = atomic_load_explicit(&observer_wrong_token_count, memory_order_relaxed);
	(void)write_byte(result_fd, 'F');
	(void)write_all(result_fd, &result, sizeof(result));
cleanup:
	if (observer_token != NOTIFY_TOKEN_INVALID) {
		(void)notify_cancel(observer_token);
		observer_token = NOTIFY_TOKEN_INVALID;
	}
	if (observer_queue != NULL) dispatch_sync(observer_queue, ^{});
	if (command_fd >= 0) close(command_fd);
	if (result_fd >= 0) close(result_fd);
	return status;
}

static int
set_cloexec(int fd)
{
	int flags = fcntl(fd, F_GETFD);
	return flags < 0 ? -1 : fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
}

static int
start_child(const char *executable, const char *mode, const char *name,
	const char *path, uid_t uid, gid_t gid, struct child_process *child,
	char *marker, void *setup_result, size_t setup_size)
{
	int command_pipe[2] = { -1, -1 };
	int result_pipe[2] = { -1, -1 };
	char command_fd_arg[20];
	char result_fd_arg[20];
	char uid_arg[32];
	char gid_arg[32];
	pid_t pid;

	if (pipe(command_pipe) != 0) return -1;
	if (pipe(result_pipe) != 0) goto fail;
	if (set_cloexec(command_pipe[1]) != 0 || set_cloexec(result_pipe[0]) != 0) goto fail;
	(void)snprintf(command_fd_arg, sizeof(command_fd_arg), "%d", command_pipe[0]);
	(void)snprintf(result_fd_arg, sizeof(result_fd_arg), "%d", result_pipe[1]);
	(void)snprintf(uid_arg, sizeof(uid_arg), "%u", (unsigned int)uid);
	(void)snprintf(gid_arg, sizeof(gid_arg), "%u", (unsigned int)gid);
	pid = fork();
	if (pid < 0) goto fail;
	if (pid == 0) {
		close(command_pipe[1]);
		close(result_pipe[0]);
		execlp(executable, executable, "--child", mode, command_fd_arg,
		    result_fd_arg, name, path, uid_arg, gid_arg, (char *)NULL);
		_exit(127);
	}
	close(command_pipe[0]);
	close(result_pipe[1]);
	child->pid = pid;
	child->command_fd = command_pipe[1];
	child->result_fd = result_pipe[0];
	if (read_byte_timeout(child->result_fd, marker, CHILD_START_TIMEOUT_MS) != 0 ||
	    read_all(child->result_fd, setup_result, setup_size) != 0) return -1;
	return 0;

fail:
	if (command_pipe[0] >= 0) close(command_pipe[0]);
	if (command_pipe[1] >= 0) close(command_pipe[1]);
	if (result_pipe[0] >= 0) close(result_pipe[0]);
	if (result_pipe[1] >= 0) close(result_pipe[1]);
	return -1;
}

static int
send_command(struct child_process *child, char command)
{
	return write_byte(child->command_fd, command);
}

static int
wait_for_child(pid_t pid, int *status)
{
	struct timespec pause = { .tv_sec = 0, .tv_nsec = 10 * 1000 * 1000 };
	for (int i = 0; i < CHILD_EXIT_TIMEOUT_MS / 10; i++) {
		pid_t waited = waitpid(pid, status, WNOHANG);
		if (waited == pid) return 0;
		if (waited < 0 && errno != EINTR) return -1;
		(void)nanosleep(&pause, NULL);
	}
	errno = ETIMEDOUT;
	return -1;
}

static int
create_file(const char *path, uid_t uid, gid_t gid)
{
	int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0644);
	int saved_errno;
	if (fd < 0) return -1;
	if (fchown(fd, uid, gid) != 0 || fchmod(fd, 0644) != 0 ||
	    write_all(fd, "before\n", 7) != 0 || fsync(fd) != 0) {
		saved_errno = errno;
		close(fd);
		unlink(path);
		errno = saved_errno;
		return -1;
	}
	return close(fd);
}

static int
append_file(const char *path)
{
	int fd = open(path, O_WRONLY | O_APPEND | O_NOFOLLOW);
	int saved_errno;
	if (fd < 0) return -1;
	if (write_all(fd, "after\n", 6) != 0 || fsync(fd) != 0) {
		saved_errno = errno;
		close(fd);
		errno = saved_errno;
		return -1;
	}
	return close(fd);
}

static int
parent_main(const char *executable)
{
	struct passwd *root_record = getpwnam("root");
	struct passwd *test_user;
	struct child_process watcher = { .pid = -1, .command_fd = -1, .result_fd = -1 };
	struct child_process observer = { .pid = -1, .command_fd = -1, .result_fd = -1 };
	struct watcher_setup watcher_setup_result;
	struct observer_result observer_setup_result;
	struct observer_result observer_after_write;
	struct observer_result observer_after_cancel;
	struct event_result event;
	struct cancel_result canceled;
	struct event_result quiet;
	char base_template[] = "/tmp/finch-notify-path-direct.XXXXXX";
	char path[PATH_SIZE] = { 0 };
	char name[NAME_SIZE];
	char marker = '\0';
	char *base_dir = NULL;
	uid_t test_uid;
	uid_t root_uid;
	gid_t test_gid;
	unsigned int nonce = arc4random();
	int watcher_wait_status = 0;
	int observer_wait_status = 0;
	int failed = 0;

	alarm(40);
	signal(SIGPIPE, SIG_IGN);
	if (root_record == NULL || root_record->pw_uid != 0 || geteuid() != 0) {
		fprintf(stderr, "run this guest test as root\n");
		return 1;
	}
	root_uid = root_record->pw_uid;
	test_user = getpwnam("finchtest");
	if (test_user == NULL || test_user->pw_uid == root_uid) {
		fprintf(stderr, "the separate finchtest account is required\n");
		return 1;
	}
	test_uid = test_user->pw_uid;
	test_gid = test_user->pw_gid;
	base_dir = mkdtemp(base_template);
	if (base_dir == NULL ||
	    snprintf(path, sizeof(path), "%s/watched", base_template) >= (int)sizeof(path)) {
		fprintf(stderr, "could not create private test folder: %s\n", strerror(errno));
		failed = 1;
		goto cleanup;
	}
	if (chown(base_template, test_uid, test_gid) != 0 || chmod(base_template, 0700) != 0 ||
	    create_file(path, test_uid, test_gid) != 0) {
		fprintf(stderr, "could not prepare private watched file: %s\n", strerror(errno));
		failed = 1;
		goto cleanup;
	}
	(void)snprintf(name, sizeof(name),
	    "user.uid.%u.org.finch.test.notify-path-direct.%ld.%08x",
	    (unsigned int)test_uid, (long)getpid(), nonce);

	if (start_child(executable, "observer", name, path, test_uid, test_gid,
	    &observer, &marker, &observer_setup_result, sizeof(observer_setup_result)) != 0 ||
	    marker != 'R' || observer_setup_result.identity_error != 0 ||
	    observer_setup_result.uid != test_uid || observer_setup_result.effective_uid != test_uid ||
	    observer_setup_result.register_status != NOTIFY_STATUS_OK) {
		fprintf(stderr, "same-name observer did not start (marker %c, status %u, error %d)\n",
		    marker, observer_setup_result.register_status, observer_setup_result.identity_error);
		failed = 1;
		goto cleanup;
	}
	marker = '\0';
	if (start_child(executable, "watcher", name, path, test_uid, test_gid,
	    &watcher, &marker, &watcher_setup_result, sizeof(watcher_setup_result)) != 0 ||
	    marker != 'R' || watcher_setup_result.identity_error != 0 ||
	    watcher_setup_result.uid != test_uid || watcher_setup_result.effective_uid != test_uid) {
		fprintf(stderr, "direct watcher did not start (marker %c, identity error %d)\n",
		    marker, watcher_setup_result.identity_error);
		failed = 1;
		goto cleanup;
	}
	if (watcher_setup_result.multithreaded_before_file != 0 ||
	    watcher_setup_result.multithreaded_before_signal != 0) {
		fprintf(stderr, "dispatch had started before direct FILE/SIGNAL registration (%d/%d)\n",
		    watcher_setup_result.multithreaded_before_file,
		    watcher_setup_result.multithreaded_before_signal);
		failed = 1;
		goto cleanup;
	}
	for (int i = 0; i < 3; i++) {
		if (watcher_setup_result.register_status[i] != NOTIFY_STATUS_OK ||
		    watcher_setup_result.monitor_status[i] != NOTIFY_STATUS_OK ||
		    watcher_setup_result.token[i] < 0) {
			fprintf(stderr, "direct watcher setup failed for mode %d (register %d, monitor %d, token %d)\n",
			    i, watcher_setup_result.register_status[i],
			    watcher_setup_result.monitor_status[i], watcher_setup_result.token[i]);
			failed = 1;
			goto cleanup;
		}
	}

	if (send_command(&watcher, 'A') != 0 ||
	    read_byte_timeout(watcher.result_fd, &marker, CHILD_RESULT_TIMEOUT_MS) != 0 || marker != 'A') {
		fprintf(stderr, "direct watcher was not ready for the file change\n");
		failed = 1;
		goto cleanup;
	}
	if (append_file(path) != 0 || send_command(&watcher, 'G') != 0 ||
	    read_byte_timeout(watcher.result_fd, &marker, EVENT_TIMEOUT_MS + CHILD_RESULT_TIMEOUT_MS) != 0 ||
	    marker != 'E' || read_all(watcher.result_fd, &event, sizeof(event)) != 0) {
		fprintf(stderr, "direct watcher did not return after the file change\n");
		failed = 1;
		goto cleanup;
	}
	if (event.expected_mask != MODE_ALL || event.received_mask != MODE_ALL ||
	    event.wrong_token_mask != 0 || event.api_error_mask != 0 || event.signal_count == 0) {
		fprintf(stderr, "direct delivery failed: received 0x%x, wrong tokens 0x%x, errors 0x%x, signals %u\n",
		    event.received_mask, event.wrong_token_mask, event.api_error_mask, event.signal_count);
		failed = 1;
		goto cleanup;
	}

	if (send_command(&observer, 'S') != 0 ||
	    read_byte_timeout(observer.result_fd, &marker, CHILD_RESULT_TIMEOUT_MS) != 0 || marker != 'S' ||
	    read_all(observer.result_fd, &observer_after_write, sizeof(observer_after_write)) != 0 ||
	    observer_after_write.callback_count != 0 || observer_after_write.wrong_token_count != 0) {
		fprintf(stderr, "unwatched same-name client received the private path change\n");
		failed = 1;
		goto cleanup;
	}

	if (send_command(&watcher, 'C') != 0 ||
	    read_byte_timeout(watcher.result_fd, &marker, CHILD_RESULT_TIMEOUT_MS) != 0 || marker != 'C' ||
	    read_all(watcher.result_fd, &canceled, sizeof(canceled)) != 0 ||
	    canceled.status[0] != NOTIFY_STATUS_OK || canceled.status[1] != NOTIFY_STATUS_OK ||
	    canceled.status[2] != NOTIFY_STATUS_OK || !canceled.file_fd_closed) {
		fprintf(stderr, "direct watcher cancel failed or left its file descriptor open\n");
		failed = 1;
		goto cleanup;
	}
	if (append_file(path) != 0 || send_command(&watcher, 'Q') != 0 ||
	    read_byte_timeout(watcher.result_fd, &marker, EVENT_TIMEOUT_MS + CHILD_RESULT_TIMEOUT_MS) != 0 ||
	    marker != 'Q' || read_all(watcher.result_fd, &quiet, sizeof(quiet)) != 0 ||
	    quiet.received_mask != 0 || quiet.wrong_token_mask != 0 || quiet.api_error_mask != 0) {
		fprintf(stderr, "a canceled direct watcher still received a path change\n");
		failed = 1;
		goto cleanup;
	}
	if (send_command(&observer, 'Q') != 0 ||
	    read_byte_timeout(observer.result_fd, &marker, CHILD_RESULT_TIMEOUT_MS) != 0 || marker != 'Q' ||
	    read_all(observer.result_fd, &observer_after_cancel, sizeof(observer_after_cancel)) != 0 ||
	    observer_after_cancel.callback_count != 0 || observer_after_cancel.wrong_token_count != 0) {
		fprintf(stderr, "unwatched same-name client received an event after cancellation\n");
		failed = 1;
		goto cleanup;
	}

	if (wait_for_child(watcher.pid, &watcher_wait_status) != 0 ||
	    !WIFEXITED(watcher_wait_status) || WEXITSTATUS(watcher_wait_status) != 0) {
		fprintf(stderr, "direct watcher did not exit cleanly\n");
		failed = 1;
		goto cleanup;
	}
	watcher.pid = -1;
	if (wait_for_child(observer.pid, &observer_wait_status) != 0 ||
	    !WIFEXITED(observer_wait_status) || WEXITSTATUS(observer_wait_status) != 0) {
		fprintf(stderr, "same-name observer did not exit cleanly\n");
		failed = 1;
		goto cleanup;
	}
	observer.pid = -1;

cleanup:
	if (watcher.pid > 0) {
		(void)kill(watcher.pid, SIGKILL);
		while (waitpid(watcher.pid, &watcher_wait_status, 0) < 0 && errno == EINTR) {}
	}
	if (observer.pid > 0) {
		(void)kill(observer.pid, SIGKILL);
		while (waitpid(observer.pid, &observer_wait_status, 0) < 0 && errno == EINTR) {}
	}
	if (watcher.command_fd >= 0) close(watcher.command_fd);
	if (watcher.result_fd >= 0) close(watcher.result_fd);
	if (observer.command_fd >= 0) close(observer.command_fd);
	if (observer.result_fd >= 0) close(observer.result_fd);
	if (path[0] != '\0') unlink(path);
	if (base_dir != NULL) rmdir(base_dir);
	if (failed) return 1;
	puts("notify-path-direct: PASS (direct FILE, SIGNAL, and PORT delivery uses the right tokens; canceled and unrelated clients stay quiet)");
	return 0;
}

int
main(int argc, char **argv)
{
	alarm(40);
	signal(SIGPIPE, SIG_IGN);
	if (argc == 9 && strcmp(argv[1], "--child") == 0) {
		int command_fd;
		int result_fd;
		uid_t uid;
		gid_t gid;
		if ((strcmp(argv[2], "watcher") != 0 && strcmp(argv[2], "observer") != 0) ||
		    parse_fd(argv[3], &command_fd) != 0 || parse_fd(argv[4], &result_fd) != 0 ||
		    command_fd == result_fd || !valid_text(argv[5], NAME_SIZE) ||
		    !valid_text(argv[6], PATH_SIZE) || argv[6][0] != '/' ||
		    parse_uid(argv[7], &uid) != 0) {
			fprintf(stderr, "invalid notify-path-direct child arguments\n");
			return 2;
		}
		if (parse_gid(argv[8], &gid) != 0) {
			fprintf(stderr, "invalid notify-path-direct child group\n");
			return 2;
		}
		if (strcmp(argv[2], "watcher") == 0)
			return watcher_child(command_fd, result_fd, argv[5], argv[6], uid, gid);
		return observer_child(command_fd, result_fd, argv[5], uid, gid);
	}
	if (argc != 1) {
		fprintf(stderr, "usage: %s [--child watcher|observer command-fd result-fd name path uid gid]\n", argv[0]);
		return 2;
	}
	return parent_main(argv[0]);
}
