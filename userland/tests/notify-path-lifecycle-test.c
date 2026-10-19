/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Finch guest test for notifyd path-watch delivery, isolation, and cleanup.
 * Run as root in the VM. All watched paths live below a private temp folder.
 */
#include <arpa/inet.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <limits.h>
#include <mach/mach.h>
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

/* notify_monitor_file is private SPI and is not in the public SDK header. */
extern uint32_t notify_monitor_file(int token, char *path, int flags);

#define PATH_WATCH_FLAGS 0x3ff /* Apple notify_pathwatch.c uses PATH_NODE_ALL. */
#define MODE_CHECK (1u << 0)
#define MODE_DISPATCH (1u << 1)
#define MODE_FD (1u << 2)
#define MODE_PORT (1u << 3)
#define MODE_SIGNAL (1u << 4)
#define MODE_ALL (MODE_CHECK | MODE_DISPATCH | MODE_FD | MODE_PORT | MODE_SIGNAL)
#define EXTRA_REGULAR_SENTINEL (1u << 5)
#define EXTRA_SYMLINK_SENTINEL (1u << 6)
#define CHILD_START_TIMEOUT_MS 6000
#define CHILD_STOP_TIMEOUT_MS 3000
#define EVENT_TIMEOUT_MS 3500
#define EVENT_QUIET_MS 300
#define NO_EVENT_QUIET_MS 600
#define SETUP_QUIET_MS 600
#define OBSERVER_QUIET_MS 600
#define NAME_SIZE 192
#define PATH_SIZE 1024
#define EVENT_POLL_NS (10ull * 1000000ull)

enum { REGULAR_GROUP = 0, SYMLINK_GROUP = 1, GROUP_COUNT = 2 };

struct group_setup {
	uint32_t register_status[6];
	uint32_t monitor_status[5];
	uint32_t initial_check_status;
	int initial_check_value;
	uint32_t setup_event_mask;
	uint32_t setup_extra_mask;
};

struct setup_report {
	int identity_error;
	uid_t uid;
	uid_t effective_uid;
	struct group_setup group[GROUP_COUNT];
};

struct event_report {
	uint32_t expected_mask;
	uint32_t received_mask;
	uint32_t unexpected_mask;
	uint32_t wrong_value_mask;
	uint32_t api_error_mask;
};

struct event_snapshot {
	unsigned int dispatch[GROUP_COUNT];
	unsigned int sentinel[GROUP_COUNT];
	sig_atomic_t signal[GROUP_COUNT];
};

struct cancel_report {
	uint32_t status[GROUP_COUNT][6];
	int regular_fd_closed;
	int symlink_fd_closed;
};

struct observer_report {
	uint32_t register_status[GROUP_COUNT];
	unsigned int dispatch_events[GROUP_COUNT];
	uid_t uid;
	uid_t effective_uid;
	int identity_error;
};

struct watcher_group {
	const char *name;
	const char *path;
	int check_token;
	int dispatch_token;
	int fd_token;
	int port_token;
	int signal_token;
	int sentinel_token;
	int notify_fd;
	mach_port_t notify_port;
	int signal_number;
	unsigned int active_mask;
	int sentinel_active;
};

struct child_process {
	pid_t pid;
	int command_fd;
	int result_fd;
};

static struct watcher_group groups[GROUP_COUNT];
static dispatch_queue_t callback_queue;
static atomic_uint dispatch_events[GROUP_COUNT];
static atomic_uint sentinel_events[GROUP_COUNT];
static atomic_uint dispatch_wrong_token[GROUP_COUNT];
static atomic_uint sentinel_wrong_token[GROUP_COUNT];
static atomic_uint observer_events[GROUP_COUNT];
static volatile sig_atomic_t signal_events[GROUP_COUNT];
static int observer_tokens[GROUP_COUNT] = { NOTIFY_TOKEN_INVALID, NOTIFY_TOKEN_INVALID };

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
parse_u64(const char *text, unsigned long long *value)
{
	char *end = NULL;
	unsigned long long parsed;

	if (text == NULL || text[0] == '\0' || text[0] == '-') return -1;
	errno = 0;
	parsed = strtoull(text, &end, 10);
	if (errno != 0 || end == text || *end != '\0') return -1;
	*value = parsed;
	return 0;
}

static int
parse_fd(const char *text, int *fd)
{
	unsigned long long value;
	if (parse_u64(text, &value) != 0 || value > INT_MAX) return -1;
	*fd = (int)value;
	return 0;
}

static int
parse_uid(const char *text, uid_t *uid)
{
	unsigned long long value;
	uid_t parsed;
	if (parse_u64(text, &value) != 0) return -1;
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
	if (parse_u64(text, &value) != 0) return -1;
	parsed = (gid_t)value;
	if ((unsigned long long)parsed != value) return -1;
	*gid = parsed;
	return 0;
}

static int
text_argument_ok(const char *text, size_t limit)
{
	return text != NULL && text[0] != '\0' && strlen(text) < limit;
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
	struct timespec pause = { .tv_sec = 0, .tv_nsec = (long)EVENT_POLL_NS };
	while (nanosleep(&pause, &pause) != 0 && errno == EINTR) {}
}

static void
wait_dispatch_queue(void)
{
	if (callback_queue != NULL) dispatch_sync(callback_queue, ^{});
}

static void
record_signal(int signal_number)
{
	if (signal_number == SIGUSR1) signal_events[REGULAR_GROUP]++;
	else if (signal_number == SIGUSR2) signal_events[SYMLINK_GROUP]++;
}

static int
install_signal_handlers(void)
{
	struct sigaction action;
	memset(&action, 0, sizeof(action));
	action.sa_handler = record_signal;
	sigemptyset(&action.sa_mask);
	action.sa_flags = SA_RESTART;
	return sigaction(SIGUSR1, &action, NULL) == 0 &&
	    sigaction(SIGUSR2, &action, NULL) == 0 ? 0 : -1;
}

static void
initialize_group(struct watcher_group *group, const char *name, const char *path,
	int signal_number)
{
	memset(group, 0, sizeof(*group));
	group->name = name;
	group->path = path;
	group->check_token = NOTIFY_TOKEN_INVALID;
	group->dispatch_token = NOTIFY_TOKEN_INVALID;
	group->fd_token = NOTIFY_TOKEN_INVALID;
	group->port_token = NOTIFY_TOKEN_INVALID;
	group->signal_token = NOTIFY_TOKEN_INVALID;
	group->sentinel_token = NOTIFY_TOKEN_INVALID;
	group->notify_fd = -1;
	group->notify_port = MACH_PORT_NULL;
	group->signal_number = signal_number;
}

static void
dispatch_handler(int group_index, int token)
{
	if (groups[group_index].dispatch_token != token)
		atomic_fetch_add_explicit(&dispatch_wrong_token[group_index], 1, memory_order_relaxed);
	else
		atomic_fetch_add_explicit(&dispatch_events[group_index], 1, memory_order_relaxed);
}

static void
sentinel_handler(int group_index, int token)
{
	if (groups[group_index].sentinel_token != token)
		atomic_fetch_add_explicit(&sentinel_wrong_token[group_index], 1, memory_order_relaxed);
	else
		atomic_fetch_add_explicit(&sentinel_events[group_index], 1, memory_order_relaxed);
}

static void
observer_handler(int group_index, int token)
{
	if (observer_tokens[group_index] == token)
		atomic_fetch_add_explicit(&observer_events[group_index], 1, memory_order_relaxed);
}

static int
register_group(struct watcher_group *group, int group_index, struct group_setup *setup)
{
	int check_value = -1;

	setup->register_status[0] = notify_register_check(group->name, &group->check_token);
	setup->register_status[1] = notify_register_dispatch(group->name,
	    &group->dispatch_token, callback_queue, ^(int token) {
		dispatch_handler(group_index, token);
	    });
	setup->register_status[2] = notify_register_file_descriptor(group->name,
	    &group->notify_fd, 0, &group->fd_token);
	setup->register_status[3] = notify_register_mach_port(group->name,
	    &group->notify_port, 0, &group->port_token);
	setup->register_status[4] = notify_register_signal(group->name,
	    group->signal_number, &group->signal_token);
	setup->register_status[5] = notify_register_dispatch(group->name,
	    &group->sentinel_token, callback_queue, ^(int token) {
		sentinel_handler(group_index, token);
	    });

	setup->initial_check_status = notify_check(group->check_token, &check_value);
	setup->initial_check_value = check_value;

	if (setup->register_status[0] == NOTIFY_STATUS_OK)
		setup->monitor_status[0] = notify_monitor_file(group->check_token,
		    (char *)group->path, PATH_WATCH_FLAGS);
	if (setup->register_status[1] == NOTIFY_STATUS_OK)
		setup->monitor_status[1] = notify_monitor_file(group->dispatch_token,
		    (char *)group->path, PATH_WATCH_FLAGS);
	if (setup->register_status[2] == NOTIFY_STATUS_OK)
		setup->monitor_status[2] = notify_monitor_file(group->fd_token,
		    (char *)group->path, PATH_WATCH_FLAGS);
	if (setup->register_status[3] == NOTIFY_STATUS_OK)
		setup->monitor_status[3] = notify_monitor_file(group->port_token,
		    (char *)group->path, PATH_WATCH_FLAGS);
	if (setup->register_status[4] == NOTIFY_STATUS_OK)
		setup->monitor_status[4] = notify_monitor_file(group->signal_token,
		    (char *)group->path, PATH_WATCH_FLAGS);

	if (setup->register_status[0] == NOTIFY_STATUS_OK) group->active_mask |= MODE_CHECK;
	if (setup->register_status[1] == NOTIFY_STATUS_OK) group->active_mask |= MODE_DISPATCH;
	if (setup->register_status[2] == NOTIFY_STATUS_OK) group->active_mask |= MODE_FD;
	if (setup->register_status[3] == NOTIFY_STATUS_OK) group->active_mask |= MODE_PORT;
	if (setup->register_status[4] == NOTIFY_STATUS_OK) group->active_mask |= MODE_SIGNAL;
	group->sentinel_active = setup->register_status[5] == NOTIFY_STATUS_OK;

	for (unsigned int i = 0; i < 6; i++) {
		if (setup->register_status[i] != NOTIFY_STATUS_OK) return -1;
	}
	if (setup->initial_check_status != NOTIFY_STATUS_OK || check_value != 1) return -1;
	for (unsigned int i = 0; i < 5; i++) {
		if (setup->monitor_status[i] != NOTIFY_STATUS_OK) return -1;
	}
	return 0;
}

static int
check_group(struct watcher_group *group, uint32_t *event_mask, uint32_t *error_mask)
{
	int check = 0;
	uint64_t state = 0;
	uint32_t status;

	if ((group->active_mask & MODE_CHECK) == 0) return 0;
	status = notify_get_state(group->check_token, &state);
	if (status != NOTIFY_STATUS_OK) {
		*error_mask |= MODE_CHECK;
		return -1;
	}
	status = notify_check(group->check_token, &check);
	if (status != NOTIFY_STATUS_OK) {
		*error_mask |= MODE_CHECK;
		return -1;
	}
	if (check) *event_mask |= MODE_CHECK;
	return 0;
}

static int
take_fd_event(struct watcher_group *group, uint32_t *event_mask, uint32_t *wrong_mask,
	uint32_t *error_mask)
{
	struct pollfd descriptor;
	uint32_t value = 0;
	ssize_t count;
	int status;

	if ((group->active_mask & MODE_FD) == 0) return 0;
	descriptor.fd = group->notify_fd;
	descriptor.events = POLLIN | POLLHUP;
	descriptor.revents = 0;
	status = poll(&descriptor, 1, 0);
	if (status < 0) {
		if (errno == EINTR) return 0;
		*error_mask |= MODE_FD;
		return -1;
	}
	if (status == 0 || (descriptor.revents & POLLIN) == 0) return 0;
	do {
		count = read(group->notify_fd, &value, sizeof(value));
	} while (count < 0 && errno == EINTR);
	if (count != sizeof(value)) {
		*error_mask |= MODE_FD;
		return -1;
	}
	*event_mask |= MODE_FD;
	if (ntohl(value) != (uint32_t)group->fd_token) *wrong_mask |= MODE_FD;
	return 0;
}

static int
take_port_event(struct watcher_group *group, uint32_t *event_mask, uint32_t *wrong_mask,
	uint32_t *error_mask)
{
	mach_msg_empty_rcv_t message;
	kern_return_t status;

	if ((group->active_mask & MODE_PORT) == 0) return 0;
	memset(&message, 0, sizeof(message));
	status = mach_msg(&message.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT,
	    0, sizeof(message), group->notify_port, 0, MACH_PORT_NULL);
	if (status == MACH_RCV_TIMED_OUT) return 0;
	if (status != KERN_SUCCESS) {
		*error_mask |= MODE_PORT;
		return -1;
	}
	*event_mask |= MODE_PORT;
	if (message.header.msgh_id != group->port_token) *wrong_mask |= MODE_PORT;
	return 0;
}

static uint32_t
collect_group_events(int group_index, unsigned int *last_dispatch,
	unsigned int *last_sentinel, sig_atomic_t *last_signal,
	uint32_t *wrong_mask, uint32_t *error_mask)
{
	struct watcher_group *group = &groups[group_index];
	uint32_t events = 0;
	unsigned int current;

	if ((group->active_mask & MODE_CHECK) != 0)
		(void)check_group(group, &events, error_mask);

	if ((group->active_mask & MODE_DISPATCH) != 0) {
		wait_dispatch_queue();
		current = atomic_load_explicit(&dispatch_events[group_index], memory_order_relaxed);
		if (atomic_load_explicit(&dispatch_wrong_token[group_index], memory_order_relaxed) != 0)
			*wrong_mask |= MODE_DISPATCH;
		if (current > *last_dispatch) events |= MODE_DISPATCH;
		*last_dispatch = current;
	}

	if ((group->active_mask & MODE_FD) != 0)
		(void)take_fd_event(group, &events, wrong_mask, error_mask);
	if ((group->active_mask & MODE_PORT) != 0)
		(void)take_port_event(group, &events, wrong_mask, error_mask);

	if ((group->active_mask & MODE_SIGNAL) != 0) {
		current = (unsigned int)signal_events[group_index];
		if ((sig_atomic_t)current > *last_signal) events |= MODE_SIGNAL;
		*last_signal = (sig_atomic_t)current;
	}

	if (group->sentinel_active) {
		wait_dispatch_queue();
		current = atomic_load_explicit(&sentinel_events[group_index], memory_order_relaxed);
		if (atomic_load_explicit(&sentinel_wrong_token[group_index], memory_order_relaxed) != 0)
			*wrong_mask |= group_index == REGULAR_GROUP ? EXTRA_REGULAR_SENTINEL : EXTRA_SYMLINK_SENTINEL;
		if (current > *last_sentinel) {
			*wrong_mask |= group_index == REGULAR_GROUP ? EXTRA_REGULAR_SENTINEL : EXTRA_SYMLINK_SENTINEL;
		}
		*last_sentinel = current;
	}

	return events;
}

static void
snapshot_counters(struct event_snapshot *snapshot)
{
	wait_dispatch_queue();
	for (int i = 0; i < GROUP_COUNT; i++) {
		snapshot->dispatch[i] = atomic_load_explicit(&dispatch_events[i], memory_order_relaxed);
		snapshot->sentinel[i] = atomic_load_explicit(&sentinel_events[i], memory_order_relaxed);
		snapshot->signal[i] = signal_events[i];
	}
}

static int
wait_for_event(char command, const struct event_snapshot *snapshot,
	struct event_report *report)
{
	int selected = command == 'R' ? REGULAR_GROUP : SYMLINK_GROUP;
	unsigned int dispatch_last[GROUP_COUNT];
	unsigned int sentinel_last[GROUP_COUNT];
	sig_atomic_t signal_last[GROUP_COUNT];
	uint64_t deadline = monotonic_ns() + (uint64_t)EVENT_TIMEOUT_MS * 1000000ull;
	uint64_t quiet_since = 0;
	uint64_t quiet_length = (uint64_t)(groups[selected].active_mask == 0 ?
	    NO_EVENT_QUIET_MS : EVENT_QUIET_MS) * 1000000ull;
	unsigned int expected = groups[selected].active_mask;

	memset(report, 0, sizeof(*report));
	report->expected_mask = expected;
	memcpy(dispatch_last, snapshot->dispatch, sizeof(dispatch_last));
	memcpy(sentinel_last, snapshot->sentinel, sizeof(sentinel_last));
	memcpy(signal_last, snapshot->signal, sizeof(signal_last));

	for (;;) {
		uint32_t events[GROUP_COUNT] = { 0, 0 };
		uint32_t wrong = 0;
		uint32_t errors = 0;
		uint64_t now;
		int new_event = 0;

		for (int i = 0; i < GROUP_COUNT; i++) {
			events[i] = collect_group_events(i, &dispatch_last[i],
			    &sentinel_last[i], &signal_last[i], &wrong, &errors);
			if (i == selected) report->received_mask |= events[i];
			else report->unexpected_mask |= events[i];
			if (events[i] != 0) new_event = 1;
		}
		report->wrong_value_mask |= wrong;
		report->api_error_mask |= errors;
		if (wrong != 0) report->unexpected_mask |= wrong &
		    (EXTRA_REGULAR_SENTINEL | EXTRA_SYMLINK_SENTINEL);

		now = monotonic_ns();
		if (expected == 0 || (report->received_mask & expected) == expected) {
			if (quiet_since == 0) quiet_since = now;
			if (!new_event && now - quiet_since >= quiet_length) break;
		} else {
			quiet_since = 0;
		}

		if (now >= deadline) break;
		pause_briefly();
	}

	wait_dispatch_queue();
	return (report->received_mask & expected) == expected &&
	    report->unexpected_mask == 0 && report->wrong_value_mask == 0 &&
	    report->api_error_mask == 0 ? 0 : -1;
}

static uint32_t
cancel_group_mode(struct watcher_group *group, unsigned int mode)
{
	int *token = NULL;
	uint32_t status;

	if (mode == MODE_CHECK) token = &group->check_token;
	else if (mode == MODE_DISPATCH) token = &group->dispatch_token;
	else if (mode == MODE_FD) token = &group->fd_token;
	else if (mode == MODE_PORT) token = &group->port_token;
	else if (mode == MODE_SIGNAL) token = &group->signal_token;
	if (token == NULL || *token == NOTIFY_TOKEN_INVALID) return NOTIFY_STATUS_INVALID_TOKEN;
	status = notify_cancel(*token);
	if (status == NOTIFY_STATUS_OK) {
		*token = NOTIFY_TOKEN_INVALID;
		group->active_mask &= ~mode;
	}
	return status;
}

static void
cancel_everything(struct cancel_report *report)
{
	static const unsigned int modes[] = { MODE_CHECK, MODE_DISPATCH, MODE_FD, MODE_PORT, MODE_SIGNAL };
	memset(report, 0, sizeof(*report));
	for (int g = 0; g < GROUP_COUNT; g++) {
		for (unsigned int i = 0; i < sizeof(modes) / sizeof(modes[0]); i++) {
			unsigned int mode = modes[i];
			if ((groups[g].active_mask & mode) != 0) {
				report->status[g][i] = cancel_group_mode(&groups[g], mode);
			} else {
				report->status[g][i] = NOTIFY_STATUS_OK;
			}
		}
		if (groups[g].sentinel_active) {
			int *token = &groups[g].sentinel_token;
			uint32_t status = notify_cancel(*token);
			if (status != NOTIFY_STATUS_OK) report->status[g][5] = status;
			else {
				*token = NOTIFY_TOKEN_INVALID;
				groups[g].sentinel_active = 0;
				report->status[g][5] = NOTIFY_STATUS_OK;
			}
		} else {
			report->status[g][5] = NOTIFY_STATUS_OK;
		}
	}
	wait_dispatch_queue();
	if (groups[REGULAR_GROUP].notify_fd >= 0) {
		errno = 0;
		report->regular_fd_closed = fcntl(groups[REGULAR_GROUP].notify_fd, F_GETFD) < 0 && errno == EBADF;
	}
	if (groups[SYMLINK_GROUP].notify_fd >= 0) {
		errno = 0;
		report->symlink_fd_closed = fcntl(groups[SYMLINK_GROUP].notify_fd, F_GETFD) < 0 && errno == EBADF;
	}
}

static int
drop_to_test_user(uid_t uid, gid_t gid, struct setup_report *report)
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

static int
watcher_setup(struct setup_report *setup, const char *regular_name,
	const char *symlink_name, const char *regular_path, const char *symlink_path,
	uid_t uid, gid_t gid)
{
	int status = -1;
	uint64_t setup_deadline;

	memset(setup, 0, sizeof(*setup));
	for (int i = 0; i < GROUP_COUNT; i++) {
		atomic_init(&dispatch_events[i], 0);
		atomic_init(&sentinel_events[i], 0);
		atomic_init(&dispatch_wrong_token[i], 0);
		atomic_init(&sentinel_wrong_token[i], 0);
		signal_events[i] = 0;
	}
	callback_queue = dispatch_queue_create("org.finch.test.notify-path-lifecycle", DISPATCH_QUEUE_SERIAL);
	if (callback_queue == NULL || install_signal_handlers() != 0) {
		setup->identity_error = ENOMEM;
		goto cleanup;
	}
	if (drop_to_test_user(uid, gid, setup) != 0) goto cleanup;
	initialize_group(&groups[REGULAR_GROUP], regular_name, regular_path, SIGUSR1);
	initialize_group(&groups[SYMLINK_GROUP], symlink_name, symlink_path, SIGUSR2);
	if (register_group(&groups[REGULAR_GROUP], REGULAR_GROUP, &setup->group[REGULAR_GROUP]) != 0 ||
	    register_group(&groups[SYMLINK_GROUP], SYMLINK_GROUP, &setup->group[SYMLINK_GROUP]) != 0) {
		setup->identity_error = EPROTO;
		goto cleanup;
	}

	setup_deadline = monotonic_ns() + (uint64_t)SETUP_QUIET_MS * 1000000ull;
	while (monotonic_ns() < setup_deadline) pause_briefly();
	wait_dispatch_queue();
	for (int i = 0; i < GROUP_COUNT; i++) {
		struct watcher_group *group = &groups[i];
		uint32_t events = 0;
		uint32_t errors = 0;
		uint32_t wrong = 0;
		unsigned int dispatch_last = 0;
		unsigned int sentinel_last = 0;
		sig_atomic_t signal_last = 0;
		(void)collect_group_events(i, &dispatch_last, &sentinel_last,
		    &signal_last, &wrong, &errors);
		if (group->sentinel_active && atomic_load_explicit(&sentinel_events[i], memory_order_relaxed) != 0)
			setup->group[i].setup_extra_mask |= i == REGULAR_GROUP ? EXTRA_REGULAR_SENTINEL : EXTRA_SYMLINK_SENTINEL;
		if (atomic_load_explicit(&dispatch_events[i], memory_order_relaxed) != 0)
			setup->group[i].setup_event_mask |= MODE_DISPATCH;
		if (atomic_load_explicit(&dispatch_wrong_token[i], memory_order_relaxed) != 0)
			setup->group[i].setup_event_mask |= MODE_DISPATCH;
		if (signal_events[i] != 0) setup->group[i].setup_event_mask |= MODE_SIGNAL;
		if (wrong != 0 || errors != 0) setup->group[i].setup_event_mask |= wrong | errors;
		(void)check_group(group, &events, &errors);
		if (events != 0) setup->group[i].setup_event_mask |= events;
		(void)take_fd_event(group, &events, &wrong, &errors);
		(void)take_port_event(group, &events, &wrong, &errors);
		if (events != 0 || wrong != 0 || errors != 0)
			setup->group[i].setup_event_mask |= events | wrong | errors;
	}
	status = 0;

cleanup:
	if (status != 0) {
		struct cancel_report ignored;
		cancel_everything(&ignored);
	}
	return status;
}

static int
watcher_child(int command_fd, int result_fd, const char *regular_name,
	const char *symlink_name, const char *regular_path, const char *symlink_path,
	uid_t uid, gid_t gid)
{
	struct setup_report setup;
	struct cancel_report canceled;
	int group_fd_closed[GROUP_COUNT] = {0};
	char command;
	int status = 1;

	alarm(70);
	if (watcher_setup(&setup, regular_name, symlink_name, regular_path,
	    symlink_path, uid, gid) != 0) {
		(void)write_byte(result_fd, 'F');
		(void)write_all(result_fd, &setup, sizeof(setup));
		goto cleanup;
	}
	for (int i = 0; i < GROUP_COUNT; i++) {
		if (setup.group[i].setup_event_mask != 0 || setup.group[i].setup_extra_mask != 0) {
			(void)write_byte(result_fd, 'F');
			(void)write_all(result_fd, &setup, sizeof(setup));
			goto cleanup;
		}
	}
	if (write_byte(result_fd, 'R') != 0 || write_all(result_fd, &setup, sizeof(setup)) != 0)
		goto cleanup;

	for (;;) {
		if (read_byte_with_timeout(command_fd, &command, 60000) != 0) goto cleanup;
		if (command == 'R' || command == 'S') {
			struct event_snapshot snapshot;
			struct event_report event;
			char trigger;
			snapshot_counters(&snapshot);
			if (write_byte(result_fd, 'A') != 0 ||
			    read_byte_with_timeout(command_fd, &trigger, 60000) != 0 || trigger != 'G')
				goto cleanup;
			(void)wait_for_event(command, &snapshot, &event);
			if (write_all(result_fd, &event, sizeof(event)) != 0) goto cleanup;
		} else if (command == 'D' || command == 'd') {
			uint32_t cancel_status;
			int group_index = command == 'D' ? REGULAR_GROUP : SYMLINK_GROUP;
			cancel_status = cancel_group_mode(&groups[group_index], MODE_DISPATCH);
			wait_dispatch_queue();
			atomic_store_explicit(&dispatch_events[group_index], 0, memory_order_relaxed);
			atomic_store_explicit(&dispatch_wrong_token[group_index], 0, memory_order_relaxed);
			if (write_all(result_fd, &cancel_status, sizeof(cancel_status)) != 0) goto cleanup;
		} else if (command == 'C' || command == 'X') {
			struct cancel_report cancel_result;
			int group_index = command == 'C' ? REGULAR_GROUP : SYMLINK_GROUP;
			struct watcher_group *group = &groups[group_index];
			static const unsigned int modes[] = { MODE_CHECK, MODE_DISPATCH, MODE_FD, MODE_PORT, MODE_SIGNAL };
			memset(&cancel_result, 0, sizeof(cancel_result));
			for (unsigned int i = 0; i < sizeof(modes) / sizeof(modes[0]); i++) {
				if ((group->active_mask & modes[i]) != 0)
					cancel_result.status[group_index][i] = cancel_group_mode(group, modes[i]);
				else cancel_result.status[group_index][i] = NOTIFY_STATUS_OK;
			}
			/* Check at cancellation, before a later watch can reuse this number. */
			errno = 0;
			group_fd_closed[group_index] = group->notify_fd >= 0 &&
			    fcntl(group->notify_fd, F_GETFD) < 0 && errno == EBADF;
			cancel_result.regular_fd_closed = group_fd_closed[REGULAR_GROUP];
			cancel_result.symlink_fd_closed = group_fd_closed[SYMLINK_GROUP];
			wait_dispatch_queue();
			if (write_all(result_fd, &cancel_result, sizeof(cancel_result)) != 0) goto cleanup;
		} else if (command == 'Q') {
			cancel_everything(&canceled);
			if (write_all(result_fd, &canceled, sizeof(canceled)) != 0) goto cleanup;
			status = 0;
			break;
		} else {
			goto cleanup;
		}
	}

cleanup:
	if (status != 0) {
		cancel_everything(&canceled);
	}
	close(command_fd);
	close(result_fd);
	return status;
}

static int
observer_child(int command_fd, int result_fd, const char *regular_name,
	const char *symlink_name, uid_t uid, gid_t gid)
{
	struct observer_report report;
	char command;
	int status = 1;
	uint64_t quiet_deadline;

	alarm(85);
	memset(&report, 0, sizeof(report));
	atomic_init(&observer_events[REGULAR_GROUP], 0);
	atomic_init(&observer_events[SYMLINK_GROUP], 0);
	callback_queue = dispatch_queue_create("org.finch.test.notify-path-observer", DISPATCH_QUEUE_SERIAL);
	if (callback_queue == NULL || setgroups(1, &gid) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		report.identity_error = errno != 0 ? errno : ENOMEM;
		goto report_setup_failure;
	}
	report.uid = getuid();
	report.effective_uid = geteuid();
	if (report.uid != uid || report.effective_uid != uid) {
		report.identity_error = EPERM;
		goto report_setup_failure;
	}
	report.register_status[REGULAR_GROUP] = notify_register_dispatch(regular_name,
	    &observer_tokens[REGULAR_GROUP], callback_queue, ^(int token) {
		observer_handler(REGULAR_GROUP, token);
	    });
	report.register_status[SYMLINK_GROUP] = notify_register_dispatch(symlink_name,
	    &observer_tokens[SYMLINK_GROUP], callback_queue, ^(int token) {
		observer_handler(SYMLINK_GROUP, token);
	    });
	if (report.register_status[REGULAR_GROUP] != NOTIFY_STATUS_OK ||
	    report.register_status[SYMLINK_GROUP] != NOTIFY_STATUS_OK) goto report_setup_failure;
	quiet_deadline = monotonic_ns() + (uint64_t)SETUP_QUIET_MS * 1000000ull;
	while (monotonic_ns() < quiet_deadline) pause_briefly();
	wait_dispatch_queue();
	if (atomic_load_explicit(&observer_events[REGULAR_GROUP], memory_order_relaxed) != 0 ||
	    atomic_load_explicit(&observer_events[SYMLINK_GROUP], memory_order_relaxed) != 0)
		goto report_setup_failure;
	if (write_byte(result_fd, 'R') != 0 || write_all(result_fd, &report, sizeof(report)) != 0)
		goto cleanup;
	if (read_byte_with_timeout(command_fd, &command, 60000) != 0 || command != 'Q') goto cleanup;
	quiet_deadline = monotonic_ns() + (uint64_t)OBSERVER_QUIET_MS * 1000000ull;
	while (monotonic_ns() < quiet_deadline) pause_briefly();
	wait_dispatch_queue();
	report.dispatch_events[REGULAR_GROUP] = atomic_load_explicit(&observer_events[REGULAR_GROUP], memory_order_relaxed);
	report.dispatch_events[SYMLINK_GROUP] = atomic_load_explicit(&observer_events[SYMLINK_GROUP], memory_order_relaxed);
	if (write_byte(result_fd, 'D') != 0 || write_all(result_fd, &report, sizeof(report)) != 0) goto cleanup;
	status = report.dispatch_events[REGULAR_GROUP] == 0 &&
	    report.dispatch_events[SYMLINK_GROUP] == 0 ? 0 : 1;
	goto cleanup;

report_setup_failure:
	(void)write_byte(result_fd, 'F');
	(void)write_all(result_fd, &report, sizeof(report));
cleanup:
	for (int i = 0; i < GROUP_COUNT; i++) {
		if (observer_tokens[i] != NOTIFY_TOKEN_INVALID)
			(void)notify_cancel(observer_tokens[i]);
		observer_tokens[i] = NOTIFY_TOKEN_INVALID;
	}
	close(command_fd);
	close(result_fd);
	return status;
}

static int
make_child_file(const char *path, uid_t uid, gid_t gid, const char *contents)
{
	int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0644);
	int saved_errno;
	if (fd < 0) return -1;
	if (fchown(fd, uid, gid) != 0 || fchmod(fd, 0644) != 0 ||
	    write_all(fd, contents, strlen(contents)) != 0 || fsync(fd) != 0) {
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
	if (write_all(fd, "append\n", 7) != 0 || fsync(fd) != 0) {
		saved_errno = errno;
		close(fd);
		errno = saved_errno;
		return -1;
	}
	return close(fd);
}

static int
replace_symlink(const char *temporary_link, const char *link_path, const char *target)
{
	if (unlink(temporary_link) != 0 && errno != ENOENT) return -1;
	if (symlink(target, temporary_link) != 0) return -1;
	if (rename(temporary_link, link_path) != 0) {
		int saved_errno = errno;
		unlink(temporary_link);
		errno = saved_errno;
		return -1;
	}
	return 0;
}

static int
set_cloexec(int fd)
{
	int flags = fcntl(fd, F_GETFD);
	return flags < 0 ? -1 : fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
}

static int
start_child(const char *executable, const char *mode, const char *regular_name,
	const char *symlink_name, const char *regular_path, const char *symlink_path,
	uid_t uid, gid_t gid, struct child_process *child, char *ready_marker,
	void *startup_report, size_t startup_report_size)
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
		    result_fd_arg, regular_name, symlink_name, regular_path,
		    symlink_path, uid_arg, gid_arg, (char *)NULL);
		_exit(127);
	}
	close(command_pipe[0]);
	close(result_pipe[1]);
	child->pid = pid;
	child->command_fd = command_pipe[1];
	child->result_fd = result_pipe[0];
	if (read_byte_with_timeout(child->result_fd, ready_marker, CHILD_START_TIMEOUT_MS) != 0 ||
	    read_all(child->result_fd, startup_report, startup_report_size) != 0) return -1;
	return 0;

fail:
	if (command_pipe[0] >= 0) close(command_pipe[0]);
	if (command_pipe[1] >= 0) close(command_pipe[1]);
	if (result_pipe[0] >= 0) close(result_pipe[0]);
	if (result_pipe[1] >= 0) close(result_pipe[1]);
	return -1;
}

static int
send_child_command(struct child_process *child, char command)
{
	return write_byte(child->command_fd, command);
}

static int
wait_for_child(pid_t pid, int *status)
{
	struct timespec pause = { .tv_sec = 0, .tv_nsec = 10 * 1000 * 1000 };
	for (int i = 0; i < CHILD_STOP_TIMEOUT_MS / 10; i++) {
		pid_t waited = waitpid(pid, status, WNOHANG);
		if (waited == pid) return 0;
		if (waited < 0 && errno != EINTR) return -1;
		(void)nanosleep(&pause, NULL);
	}
	errno = ETIMEDOUT;
	return -1;
}

static int
arm_event(struct child_process *watcher, char group, const char *description)
{
	char marker = '\0';
	if (send_child_command(watcher, group) != 0 ||
	    read_byte_with_timeout(watcher->result_fd, &marker, CHILD_STOP_TIMEOUT_MS) != 0 ||
	    marker != 'A') {
		fprintf(stderr, "%s: watcher could not arm its event counters\n", description);
		return -1;
	}
	return 0;
}

static int
run_event(struct child_process *watcher, char group, uint32_t expected_mask,
	const char *description)
{
	struct event_report event;
	(void)group;
	if (send_child_command(watcher, 'G') != 0 ||
	    read_all(watcher->result_fd, &event, sizeof(event)) != 0) {
		fprintf(stderr, "%s: watcher did not return an event result\n", description);
		return -1;
	}
	if (event.expected_mask != expected_mask || event.received_mask != expected_mask ||
	    event.unexpected_mask != 0 || event.wrong_value_mask != 0 || event.api_error_mask != 0) {
		fprintf(stderr, "%s: expected 0x%x, received 0x%x, unexpected 0x%x, wrong 0x%x, errors 0x%x\n",
		    description, expected_mask, event.received_mask, event.unexpected_mask,
		    event.wrong_value_mask, event.api_error_mask);
		return -1;
	}
	return 0;
}

static int
expect_cancel_statuses(const struct cancel_report *report, int group_index)
{
	for (int i = 0; i < 6; i++) {
		if (report->status[group_index][i] != NOTIFY_STATUS_OK) {
			fprintf(stderr, "notify_cancel failed for group %d item %d (status %u)\n",
			    group_index, i, report->status[group_index][i]);
			return -1;
		}
	}
	return 0;
}

static int
parent_main(const char *executable)
{
	struct passwd *root_record = getpwnam("root");
	struct passwd *test_user;
	struct child_process watcher = { .pid = -1, .command_fd = -1, .result_fd = -1 };
	struct child_process observer = { .pid = -1, .command_fd = -1, .result_fd = -1 };
	struct setup_report watcher_setup_result;
	struct observer_report observer_setup_result;
	struct observer_report observer_final_result;
	struct cancel_report cancel_result;
	char base_template[] = "/tmp/finch-notify-path-lifecycle.XXXXXX";
	char regular_path[PATH_SIZE] = { 0 };
	char moved_path[PATH_SIZE] = { 0 };
	char target_dir_path[PATH_SIZE] = { 0 };
	char target_a_path[PATH_SIZE] = { 0 };
	char target_b_path[PATH_SIZE] = { 0 };
	char symlink_path[PATH_SIZE] = { 0 };
	char temporary_link_path[PATH_SIZE] = { 0 };
	char regular_name[NAME_SIZE];
	char symlink_name[NAME_SIZE];
	char ready = '\0';
	char *base_dir = NULL;
	uid_t test_uid;
	uid_t root_uid;
	gid_t test_gid;
	unsigned int nonce = arc4random();
	int watcher_wait_status = 0;
	int observer_wait_status = 0;
	int failed = 0;
	int setup_ok = 1;

	alarm(90);
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
	    snprintf(regular_path, sizeof(regular_path), "%s/regular", base_template) >= (int)sizeof(regular_path) ||
	    snprintf(moved_path, sizeof(moved_path), "%s/moved", base_template) >= (int)sizeof(moved_path) ||
	    snprintf(target_dir_path, sizeof(target_dir_path), "%s/targets", base_template) >= (int)sizeof(target_dir_path) ||
	    snprintf(target_a_path, sizeof(target_a_path), "%s/targets/target-a", base_template) >= (int)sizeof(target_a_path) ||
	    snprintf(target_b_path, sizeof(target_b_path), "%s/targets/target-b", base_template) >= (int)sizeof(target_b_path) ||
	    snprintf(symlink_path, sizeof(symlink_path), "%s/link", base_template) >= (int)sizeof(symlink_path) ||
	    snprintf(temporary_link_path, sizeof(temporary_link_path), "%s/link-new", base_template) >= (int)sizeof(temporary_link_path)) {
		fprintf(stderr, "could not create test folder: %s\n", strerror(errno));
		failed = 1;
		goto cleanup;
	}
	if (chown(base_template, test_uid, test_gid) != 0 || chmod(base_template, 0700) != 0 ||
	    mkdir(target_dir_path, 0700) != 0 || chown(target_dir_path, test_uid, test_gid) != 0 ||
	    chmod(target_dir_path, 0700) != 0 ||
	    make_child_file(regular_path, test_uid, test_gid, "regular\n") != 0 ||
	    make_child_file(target_b_path, test_uid, test_gid, "target-b\n") != 0 ||
	    symlink(target_a_path, symlink_path) != 0) {
		fprintf(stderr, "could not prepare private test files and target folder: %s\n", strerror(errno));
		failed = 1;
		goto cleanup;
	}
	(void)snprintf(regular_name, sizeof(regular_name),
	    "user.uid.%u.org.finch.test.notify-path-lifecycle.%ld.%08x.regular",
	    (unsigned int)test_uid, (long)getpid(), nonce);
	(void)snprintf(symlink_name, sizeof(symlink_name),
	    "user.uid.%u.org.finch.test.notify-path-lifecycle.%ld.%08x.symlink",
	    (unsigned int)test_uid, (long)getpid(), nonce);

	if (start_child(executable, "observer", regular_name, symlink_name,
	    regular_path, symlink_path, test_uid, test_gid, &observer, &ready,
	    &observer_setup_result, sizeof(observer_setup_result)) != 0 || ready != 'R' ||
	    observer_setup_result.identity_error != 0 || observer_setup_result.uid != test_uid ||
	    observer_setup_result.effective_uid != test_uid ||
	    observer_setup_result.register_status[REGULAR_GROUP] != NOTIFY_STATUS_OK ||
	    observer_setup_result.register_status[SYMLINK_GROUP] != NOTIFY_STATUS_OK) {
		fprintf(stderr, "same-name observer could not start (marker %c, identity error %d, register %u/%u)\n",
		    ready, observer_setup_result.identity_error,
		    observer_setup_result.register_status[0], observer_setup_result.register_status[1]);
		failed = 1;
		goto cleanup;
	}
	ready = '\0';
	if (start_child(executable, "watcher", regular_name, symlink_name,
	    regular_path, symlink_path, test_uid, test_gid, &watcher, &ready,
	    &watcher_setup_result, sizeof(watcher_setup_result)) != 0 || ready != 'R' ||
	    watcher_setup_result.identity_error != 0 ||
	    watcher_setup_result.uid != test_uid || watcher_setup_result.effective_uid != test_uid) {
		fprintf(stderr, "path watcher could not start (marker %c, identity error %d)\n",
		    ready, watcher_setup_result.identity_error);
		failed = 1;
		goto cleanup;
	}
	for (int i = 0; i < GROUP_COUNT; i++) {
		if (watcher_setup_result.group[i].setup_event_mask != 0 ||
		    watcher_setup_result.group[i].setup_extra_mask != 0) {
			fprintf(stderr, "group %d received a callback during watch setup (0x%x/0x%x)\n",
			    i, watcher_setup_result.group[i].setup_event_mask,
			    watcher_setup_result.group[i].setup_extra_mask);
			setup_ok = 0;
		}
		for (int j = 0; j < 6; j++) {
			if (watcher_setup_result.group[i].register_status[j] != NOTIFY_STATUS_OK) setup_ok = 0;
		}
		for (int j = 0; j < 5; j++) {
			if (watcher_setup_result.group[i].monitor_status[j] != NOTIFY_STATUS_OK) setup_ok = 0;
		}
		if (watcher_setup_result.group[i].initial_check_status != NOTIFY_STATUS_OK ||
		    watcher_setup_result.group[i].initial_check_value != 1) setup_ok = 0;
	}
	if (!setup_ok) {
		fprintf(stderr, "one or more path-watch delivery modes failed setup\n");
		failed = 1;
		goto cleanup;
	}

	if (arm_event(&watcher, 'R', "write existing file") != 0 ||
	    append_file(regular_path) != 0 || run_event(&watcher, 'R', MODE_ALL, "write existing file") != 0)
		{ failed = 1; goto cleanup; }
	if (arm_event(&watcher, 'R', "rename watched file away") != 0 ||
	    rename(regular_path, moved_path) != 0 || run_event(&watcher, 'R', MODE_ALL, "rename watched file away") != 0)
		{ failed = 1; goto cleanup; }
	if (arm_event(&watcher, 'R', "rename watched file back") != 0 ||
	    rename(moved_path, regular_path) != 0 || run_event(&watcher, 'R', MODE_ALL, "rename watched file back") != 0)
		{ failed = 1; goto cleanup; }
	if (arm_event(&watcher, 'R', "delete watched file") != 0 ||
	    unlink(regular_path) != 0 || run_event(&watcher, 'R', MODE_ALL, "delete watched file") != 0)
		{ failed = 1; goto cleanup; }
	if (arm_event(&watcher, 'R', "recreate watched file") != 0 ||
	    make_child_file(regular_path, test_uid, test_gid, "recreated\n") != 0 ||
	    run_event(&watcher, 'R', MODE_ALL, "recreate watched file") != 0)
		{ failed = 1; goto cleanup; }

	if (send_child_command(&watcher, 'D') != 0 ||
	    read_all(watcher.result_fd, &cancel_result.status[0][1], sizeof(uint32_t)) != 0 ||
	    cancel_result.status[REGULAR_GROUP][1] != NOTIFY_STATUS_OK) {
		fprintf(stderr, "could not cancel the regular-file dispatch watcher\n");
		failed = 1;
		goto cleanup;
	}
	if (arm_event(&watcher, 'R', "write after dispatch watcher cancellation") != 0 ||
	    append_file(regular_path) != 0 ||
	    run_event(&watcher, 'R', MODE_CHECK | MODE_FD | MODE_PORT | MODE_SIGNAL,
	    "write after dispatch watcher cancellation") != 0) {
		failed = 1;
		goto cleanup;
	}

	if (send_child_command(&watcher, 'C') != 0 ||
	    read_all(watcher.result_fd, &cancel_result, sizeof(cancel_result)) != 0 ||
	    expect_cancel_statuses(&cancel_result, REGULAR_GROUP) != 0) {
		failed = 1;
		goto cleanup;
	}
	if (arm_event(&watcher, 'R', "write after all regular watchers were canceled") != 0 ||
	    append_file(regular_path) != 0 || run_event(&watcher, 'R', 0, "write after all regular watchers were canceled") != 0) {
		failed = 1;
		goto cleanup;
	}

	if (arm_event(&watcher, 'S', "create target of initially dangling watched symlink") != 0 ||
	    make_child_file(target_a_path, test_uid, test_gid, "target-a\n") != 0 ||
	    run_event(&watcher, 'S', MODE_ALL, "create target of initially dangling watched symlink") != 0)
		{ failed = 1; goto cleanup; }
	if (arm_event(&watcher, 'S', "write through watched symlink target") != 0 ||
	    append_file(target_a_path) != 0 || run_event(&watcher, 'S', MODE_ALL, "write through watched symlink target") != 0)
		{ failed = 1; goto cleanup; }
	if (arm_event(&watcher, 'S', "delete watched symlink target in separate folder") != 0 ||
	    unlink(target_a_path) != 0 || run_event(&watcher, 'S', MODE_ALL,
	    "delete watched symlink target in separate folder") != 0)
		{ failed = 1; goto cleanup; }
	if (arm_event(&watcher, 'S', "recreate watched symlink target in separate folder") != 0 ||
	    make_child_file(target_a_path, test_uid, test_gid, "target-a-recreated\n") != 0 ||
	    run_event(&watcher, 'S', MODE_ALL, "recreate watched symlink target in separate folder") != 0)
		{ failed = 1; goto cleanup; }
	if (arm_event(&watcher, 'S', "replace watched symlink") != 0 ||
	    replace_symlink(temporary_link_path, symlink_path, target_b_path) != 0 ||
	    run_event(&watcher, 'S', MODE_ALL, "replace watched symlink") != 0)
		{ failed = 1; goto cleanup; }
	if (arm_event(&watcher, 'S', "write through replacement symlink target") != 0 ||
	    append_file(target_b_path) != 0 || run_event(&watcher, 'S', MODE_ALL, "write through replacement symlink target") != 0)
		{ failed = 1; goto cleanup; }
	if (arm_event(&watcher, 'S', "delete watched symlink") != 0 ||
	    unlink(symlink_path) != 0 || run_event(&watcher, 'S', MODE_ALL, "delete watched symlink") != 0)
		{ failed = 1; goto cleanup; }
	if (arm_event(&watcher, 'S', "recreate watched symlink") != 0 ||
	    symlink(target_a_path, symlink_path) != 0 || run_event(&watcher, 'S', MODE_ALL, "recreate watched symlink") != 0)
		{ failed = 1; goto cleanup; }
	if (send_child_command(&watcher, 'd') != 0 ||
	    read_all(watcher.result_fd, &cancel_result.status[1][1], sizeof(uint32_t)) != 0 ||
	    cancel_result.status[SYMLINK_GROUP][1] != NOTIFY_STATUS_OK) {
		fprintf(stderr, "could not cancel the symlink dispatch watcher\n");
		failed = 1;
		goto cleanup;
	}
	if (arm_event(&watcher, 'S', "write after symlink dispatch watcher cancellation") != 0 ||
	    append_file(target_a_path) != 0 ||
	    run_event(&watcher, 'S', MODE_CHECK | MODE_FD | MODE_PORT | MODE_SIGNAL,
	    "write after symlink dispatch watcher cancellation") != 0) {
		failed = 1;
		goto cleanup;
	}

	if (send_child_command(&watcher, 'X') != 0 ||
	    read_all(watcher.result_fd, &cancel_result, sizeof(cancel_result)) != 0 ||
	    expect_cancel_statuses(&cancel_result, SYMLINK_GROUP) != 0 ||
	    !cancel_result.regular_fd_closed || !cancel_result.symlink_fd_closed) {
		fprintf(stderr, "path watcher cleanup failed or a notification file descriptor stayed open\n");
		failed = 1;
		goto cleanup;
	}
	if (arm_event(&watcher, 'S', "replace symlink after all watches were canceled") != 0 ||
	    replace_symlink(temporary_link_path, symlink_path, target_b_path) != 0 ||
	    run_event(&watcher, 'S', 0, "replace symlink after all watches were canceled") != 0) {
		failed = 1;
		goto cleanup;
	}

	if (send_child_command(&watcher, 'Q') != 0 ||
	    read_all(watcher.result_fd, &cancel_result, sizeof(cancel_result)) != 0) {
		fprintf(stderr, "watcher child did not clean up\n");
		failed = 1;
		goto cleanup;
	}
	if (send_child_command(&observer, 'Q') != 0 ||
	    read_byte_with_timeout(observer.result_fd, &ready, CHILD_STOP_TIMEOUT_MS) != 0 || ready != 'D' ||
	    read_all(observer.result_fd, &observer_final_result, sizeof(observer_final_result)) != 0) {
		fprintf(stderr, "same-name observer did not return its final result\n");
		failed = 1;
		goto cleanup;
	}
	if (observer_final_result.dispatch_events[REGULAR_GROUP] != 0 ||
	    observer_final_result.dispatch_events[SYMLINK_GROUP] != 0) {
		fprintf(stderr, "another client received private path events (%u/%u callback(s))\n",
		    observer_final_result.dispatch_events[0], observer_final_result.dispatch_events[1]);
		failed = 1;
		goto cleanup;
	}
	if (wait_for_child(watcher.pid, &watcher_wait_status) != 0 ||
	    !WIFEXITED(watcher_wait_status) || WEXITSTATUS(watcher_wait_status) != 0) {
		fprintf(stderr, "path watcher child failed to exit cleanly\n");
		failed = 1;
		goto cleanup;
	}
	watcher.pid = -1;
	if (wait_for_child(observer.pid, &observer_wait_status) != 0 ||
	    !WIFEXITED(observer_wait_status) || WEXITSTATUS(observer_wait_status) != 0) {
		fprintf(stderr, "observer child failed to exit cleanly\n");
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
	if (regular_path[0] != '\0') unlink(regular_path);
	if (moved_path[0] != '\0') unlink(moved_path);
	if (target_a_path[0] != '\0') unlink(target_a_path);
	if (target_b_path[0] != '\0') unlink(target_b_path);
	if (target_dir_path[0] != '\0') rmdir(target_dir_path);
	if (temporary_link_path[0] != '\0') unlink(temporary_link_path);
	if (symlink_path[0] != '\0') unlink(symlink_path);
	if (base_dir != NULL) rmdir(base_dir);
	if (failed) return 1;
	puts("notify-path-lifecycle: PASS (all delivery modes follow allowed file and symlink changes; canceled and unrelated clients stay quiet)");
	return 0;
}

int
main(int argc, char **argv)
{
	alarm(90);
	signal(SIGPIPE, SIG_IGN);
	if (argc == 11 && strcmp(argv[1], "--child") == 0) {
		int command_fd;
		int result_fd;
		uid_t uid;
		gid_t gid;
		if ((strcmp(argv[2], "watcher") != 0 && strcmp(argv[2], "observer") != 0) ||
		    parse_fd(argv[3], &command_fd) != 0 || parse_fd(argv[4], &result_fd) != 0 ||
		    command_fd == result_fd || !text_argument_ok(argv[5], NAME_SIZE) ||
		    !text_argument_ok(argv[6], NAME_SIZE) || strcmp(argv[5], argv[6]) == 0 ||
		    !text_argument_ok(argv[7], PATH_SIZE) || !text_argument_ok(argv[8], PATH_SIZE) ||
		    strcmp(argv[7], argv[8]) == 0 || argv[7][0] != '/' || argv[8][0] != '/' ||
		    parse_uid(argv[9], &uid) != 0 || parse_gid(argv[10], &gid) != 0) {
			fprintf(stderr, "invalid notify-path-lifecycle child arguments\n");
			return 2;
		}
		if (strcmp(argv[2], "watcher") == 0)
			return watcher_child(command_fd, result_fd, argv[5], argv[6], argv[7], argv[8], uid, gid);
		return observer_child(command_fd, result_fd, argv[5], argv[6], uid, gid);
	}
	if (argc != 1) {
		fprintf(stderr, "usage: %s [--child watcher|observer command-fd result-fd regular-name symlink-name regular-path symlink-path uid gid]\n", argv[0]);
		return 2;
	}
	return parent_main(argv[0]);
}
