/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Finch guest test for notifyd's user.uid.<uid> access rules.
 * Run as root in the VM. This uses a private name for this run and never
 * changes notifyd's configuration or the VM's files.
 */
#include <dispatch/dispatch.h>
#include <errno.h>
#include <grp.h>
#include <inttypes.h>
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
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define CHILD_WAIT_MS 5000
#define CHILD_EXIT_WAIT_MS 2000
#define QUIET_WAIT_NS (500ull * 1000000ull)
#define EVENT_WAIT_NS (3000ull * 1000000ull)
#define CHILD_STATE 0x4e4f544946594143ull
#define NAME_BUFFER_SIZE 192

struct child_result {
	uid_t uid;
	uid_t effective_uid;
	int identity_errno;
	int own_register_status;
	int denied_register_status;
	int denied_token;
	int post_status;
	int set_state_status;
	int get_state_status;
	uint64_t state;
	int own_cancel_status;
	int denied_cancel_status;
};

static dispatch_semaphore_t event_semaphore;
static atomic_uint event_count;

static int
write_result(int fd, const struct child_result *result)
{
	const char *bytes = (const char *)result;
	size_t left = sizeof(*result);

	while (left != 0) {
		ssize_t written = write(fd, bytes, left);
		if (written < 0 && errno == EINTR) continue;
		if (written <= 0) return -1;
		bytes += written;
		left -= (size_t)written;
	}
	return 0;
}

static int
read_result(int fd, struct child_result *result)
{
	char *bytes = (char *)result;
	size_t left = sizeof(*result);

	while (left != 0) {
		ssize_t got = read(fd, bytes, left);
		if (got < 0 && errno == EINTR) continue;
		if (got <= 0) return -1;
		bytes += got;
		left -= (size_t)got;
	}
	return 0;
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

static void
initialize_child_result(struct child_result *result)
{
	memset(result, 0, sizeof(*result));
	result->own_register_status = -1;
	result->denied_register_status = -1;
	result->denied_token = NOTIFY_TOKEN_INVALID;
	result->post_status = -1;
	result->set_state_status = -1;
	result->get_state_status = -1;
	result->own_cancel_status = -1;
	result->denied_cancel_status = -1;
}

static int
child_main(int start_fd, int result_fd, const char *target_name,
    const char *own_name, uid_t test_uid, gid_t test_gid)
{
	alarm(20);
	struct child_result result;
	char start;
	int own_token = NOTIFY_TOKEN_INVALID;
	int denied_token = NOTIFY_TOKEN_INVALID;
	uint64_t state = 0;
	int exit_status = 1;

	initialize_child_result(&result);

	if (read(start_fd, &start, sizeof(start)) != sizeof(start) || start != 'G') {
		result.identity_errno = EPIPE;
		goto done;
	}
	close(start_fd);

	/* Drop every root group as well as the root user before calling notifyd. */
	if (setgroups(1, &test_gid) != 0 || setgid(test_gid) != 0 ||
	    setuid(test_uid) != 0) {
		result.identity_errno = errno;
		goto done;
	}
	result.uid = getuid();
	result.effective_uid = geteuid();
	if (result.uid != test_uid || result.effective_uid != test_uid) {
		result.identity_errno = EPERM;
		goto done;
	}

	/* The child's own name is a positive control for its UID-based access. */
	result.own_register_status = (int)notify_register_check(own_name, &own_token);
	result.denied_register_status = (int)notify_register_check(target_name, &denied_token);
	result.denied_token = denied_token;

	/* A one-way post can report success even when notifyd drops it. */
	result.post_status = (int)notify_post(target_name);

	/* This server call waits behind the post on the same connection. */
	if (own_token != NOTIFY_TOKEN_INVALID) {
		result.set_state_status = (int)notify_set_state(own_token, CHILD_STATE);
		result.get_state_status = (int)notify_get_state(own_token, &state);
		result.state = state;
		result.own_cancel_status = (int)notify_cancel(own_token);
	}
	if (denied_token != NOTIFY_TOKEN_INVALID) {
		result.denied_cancel_status = (int)notify_cancel(denied_token);
	}

	if (result.own_register_status == NOTIFY_STATUS_OK &&
	    result.denied_register_status == NOTIFY_STATUS_NOT_AUTHORIZED &&
	    result.denied_token == NOTIFY_TOKEN_INVALID &&
	    result.post_status == NOTIFY_STATUS_OK &&
	    result.set_state_status == NOTIFY_STATUS_OK &&
	    result.get_state_status == NOTIFY_STATUS_OK &&
	    result.state == CHILD_STATE &&
	    result.own_cancel_status == NOTIFY_STATUS_OK &&
	    result.denied_cancel_status == -1) {
		exit_status = 0;
	}

done:
	if (write_result(result_fd, &result) != 0) exit_status = 1;
	close(result_fd);
	return exit_status;
}

static int
report_child_result(const struct child_result *result, int wait_status)
{
	int failed = 0;

	if (!WIFEXITED(wait_status) || WEXITSTATUS(wait_status) != 0) {
		fprintf(stderr, "child failed after it dropped to finchtest (wait status %d)\n",
		    wait_status);
		failed = 1;
	}
	if (result->identity_errno != 0 || result->uid != result->effective_uid) {
		fprintf(stderr, "child did not become finchtest (error %d, uid %u, euid %u)\n",
		    result->identity_errno, result->uid, result->effective_uid);
		failed = 1;
	}
	if (result->own_register_status != NOTIFY_STATUS_OK) {
		fprintf(stderr, "finchtest could not register its own name (status %d)\n",
		    result->own_register_status);
		failed = 1;
	}
	if (result->denied_register_status != NOTIFY_STATUS_NOT_AUTHORIZED ||
	    result->denied_token != NOTIFY_TOKEN_INVALID) {
		fprintf(stderr, "cross-user registration was not denied (status %d, token %d)\n",
		    result->denied_register_status, result->denied_token);
		failed = 1;
	}
	if (result->post_status != NOTIFY_STATUS_OK) {
		fprintf(stderr, "finchtest post call failed before notifyd could check it (status %d)\n",
		    result->post_status);
		failed = 1;
	}
	if (result->set_state_status != NOTIFY_STATUS_OK ||
	    result->get_state_status != NOTIFY_STATUS_OK || result->state != CHILD_STATE) {
		fprintf(stderr, "finchtest could not set and read its own state (set %d, get %d, value %llu)\n",
		    result->set_state_status, result->get_state_status,
		    (unsigned long long)result->state);
		failed = 1;
	}
	if (result->own_cancel_status != NOTIFY_STATUS_OK ||
	    result->denied_cancel_status != -1) {
		fprintf(stderr, "child registration cleanup failed (own %d, denied %d)\n",
		    result->own_cancel_status, result->denied_cancel_status);
		failed = 1;
	}
	return failed;
}

int
main(int argc, char **argv)
{
	alarm(45);
	signal(SIGPIPE, SIG_IGN);
	if (argc == 8 && strcmp(argv[1], "--child") == 0) {
		int start_fd;
		int result_fd;
		uid_t test_uid;
		gid_t test_gid;

		/* A fork child may inherit libnotify's OPT_DISABLE state. Exec starts
		 * a fresh process so these checks can exercise notifyd for real. */
		if (parse_fd_argument(argv[2], &start_fd) != 0 ||
		    parse_fd_argument(argv[3], &result_fd) != 0 ||
		    start_fd == result_fd ||
		    argv[4][0] == '\0' || strlen(argv[4]) >= NAME_BUFFER_SIZE ||
		    argv[5][0] == '\0' || strlen(argv[5]) >= NAME_BUFFER_SIZE ||
		    strcmp(argv[4], argv[5]) == 0 ||
		    parse_uid_argument(argv[6], &test_uid) != 0 ||
		    parse_gid_argument(argv[7], &test_gid) != 0) {
			fprintf(stderr, "invalid notify-access child arguments\n");
			return 2;
		}
		return child_main(start_fd, result_fd, argv[4], argv[5], test_uid, test_gid);
	}
	if (argc != 1) {
		fprintf(stderr, "usage: %s [--child start-fd result-fd target-name own-name uid gid]\n",
		    argv[0]);
		return 2;
	}

	struct passwd *root_user = getpwnam("root");
	uid_t root_uid;
	struct passwd *test_user;
	uid_t test_uid;
	gid_t test_gid;
	unsigned int nonce = arc4random();
	char target_name[NAME_BUFFER_SIZE];
	char own_name[NAME_BUFFER_SIZE];
	int start_pipe[2] = { -1, -1 };
	int result_pipe[2] = { -1, -1 };
	char start_fd_arg[16];
	char result_fd_arg[16];
	char test_uid_arg[32];
	char test_gid_arg[32];
	pid_t child = -1;
	int child_wait_status = 0;
	struct child_result child_result;
	int dispatch_token = NOTIFY_TOKEN_INVALID;
	int check_token = NOTIFY_TOKEN_INVALID;
	int failed = 0;
	int baseline = 0;
	int changed = -1;
	int status;
	dispatch_queue_t queue = NULL;

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
	if (test_uid == root_uid) {
		fprintf(stderr, "finchtest must have a different user ID from root\n");
		return 1;
	}
	if (geteuid() != root_uid) {
		fprintf(stderr, "run this test as root so it can check both users\n");
		return 1;
	}

	(void)snprintf(target_name, sizeof(target_name),
	    "user.uid.%u.org.finch.test.notify-access.%ld.%08x",
	    (unsigned int)root_uid, (long)getpid(), nonce);
	(void)snprintf(own_name, sizeof(own_name),
	    "user.uid.%u.org.finch.test.notify-access.%ld.%08x.child",
	    (unsigned int)test_uid, (long)getpid(), nonce);

	/* Start the fresh child before setting up the parent's notification queue. */
	if (pipe(start_pipe) != 0 || pipe(result_pipe) != 0) {
		fprintf(stderr, "could not create child pipes: %s\n", strerror(errno));
		return 1;
	}
	(void)snprintf(start_fd_arg, sizeof(start_fd_arg), "%d", start_pipe[0]);
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
		close(start_pipe[1]);
		close(result_pipe[0]);
		execlp(argv[0], argv[0], "--child", start_fd_arg, result_fd_arg,
		    target_name, own_name, test_uid_arg, test_gid_arg, (char *)NULL);
		int exec_error = errno;
		struct child_result result;
		initialize_child_result(&result);
		result.identity_errno = exec_error;
		(void)write_result(result_pipe[1], &result);
		close(result_pipe[1]);
		_exit(127);
	}
	close(start_pipe[0]);
	start_pipe[0] = -1;
	close(result_pipe[1]);
	result_pipe[1] = -1;

	event_semaphore = dispatch_semaphore_create(0);
	queue = dispatch_queue_create("org.finch.test.notify-access", DISPATCH_QUEUE_SERIAL);
	if (event_semaphore == NULL || queue == NULL) {
		fprintf(stderr, "could not create the notification wait objects\n");
		failed = 1;
		goto cleanup;
	}
	atomic_init(&event_count, 0);

	status = (int)notify_register_dispatch(target_name, &dispatch_token, queue, ^(int token) {
		(void)token;
		atomic_fetch_add_explicit(&event_count, 1, memory_order_relaxed);
		dispatch_semaphore_signal(event_semaphore);
	});
	if (status != NOTIFY_STATUS_OK) {
		fprintf(stderr, "root could not register the protected name (status %d)\n", status);
		failed = 1;
		goto cleanup;
	}
	status = (int)notify_register_check(target_name, &check_token);
	if (status != NOTIFY_STATUS_OK) {
		fprintf(stderr, "root could not register a check token (status %d)\n", status);
		failed = 1;
		goto cleanup;
	}
	status = (int)notify_check(check_token, &baseline);
	if (status != NOTIFY_STATUS_OK) {
		fprintf(stderr, "root could not read the initial notification count (status %d)\n",
		    status);
		failed = 1;
		goto cleanup;
	}

	if (write(start_pipe[1], "G", 1) != 1) {
		fprintf(stderr, "could not start the finchtest child: %s\n", strerror(errno));
		failed = 1;
		goto cleanup;
	}
	close(start_pipe[1]);
	start_pipe[1] = -1;

	struct pollfd child_output = { .fd = result_pipe[0], .events = POLLIN | POLLHUP };
	int poll_result = poll(&child_output, 1, CHILD_WAIT_MS);
	if (poll_result <= 0 || read_result(result_pipe[0], &child_result) != 0) {
		fprintf(stderr, "finchtest did not finish its notify checks within %d ms\n",
		    CHILD_WAIT_MS);
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

	/* The child's synchronous state read is a fence behind its one-way post. */
	changed = -1;
	status = (int)notify_check(check_token, &changed);
	if (status != NOTIFY_STATUS_OK || changed != 0) {
		fprintf(stderr, "finchtest changed root's protected notification (status %d, changed %d)\n",
		    status, changed);
		failed = 1;
	}
	if (dispatch_semaphore_wait(event_semaphore,
	    dispatch_time(DISPATCH_TIME_NOW, (int64_t)QUIET_WAIT_NS)) == 0) {
		fprintf(stderr, "finchtest's post reached root's notification listener\n");
		failed = 1;
	}
	if (atomic_load_explicit(&event_count, memory_order_relaxed) != 0) {
		fprintf(stderr, "root received a notification before the allowed post\n");
		failed = 1;
	}

	/* Root must still be able to post the same name and wake the listener. */
	unsigned int before_allowed_post = atomic_load_explicit(&event_count, memory_order_relaxed);
	status = (int)notify_post(target_name);
	if (status != NOTIFY_STATUS_OK) {
		fprintf(stderr, "root's positive-control post failed (status %d)\n", status);
		failed = 1;
	} else {
		dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t)EVENT_WAIT_NS);
		while (atomic_load_explicit(&event_count, memory_order_relaxed) == before_allowed_post &&
		       dispatch_semaphore_wait(event_semaphore, deadline) == 0) {
			/* Ignore any already queued signal until the new callback has run. */
		}
		if (atomic_load_explicit(&event_count, memory_order_relaxed) != before_allowed_post + 1) {
			fprintf(stderr, "root's allowed post did not produce exactly one callback\n");
			failed = 1;
		}
	}
	changed = -1;
	status = (int)notify_check(check_token, &changed);
	if (status != NOTIFY_STATUS_OK || changed != 1) {
		fprintf(stderr, "root's post did not update the shared notification count (status %d, changed %d)\n",
		    status, changed);
		failed = 1;
	}

cleanup:
	if (child > 0) {
		(void)kill(child, SIGKILL);
		while (waitpid(child, &child_wait_status, 0) < 0 && errno == EINTR) {}
	}
	if (start_pipe[0] >= 0) close(start_pipe[0]);
	if (start_pipe[1] >= 0) close(start_pipe[1]);
	if (result_pipe[0] >= 0) close(result_pipe[0]);
	if (result_pipe[1] >= 0) close(result_pipe[1]);
	if (dispatch_token != NOTIFY_TOKEN_INVALID &&
	    notify_cancel(dispatch_token) != NOTIFY_STATUS_OK) {
		fprintf(stderr, "could not cancel root's dispatch registration\n");
		failed = 1;
	}
	if (check_token != NOTIFY_TOKEN_INVALID &&
	    notify_cancel(check_token) != NOTIFY_STATUS_OK) {
		fprintf(stderr, "could not cancel root's check registration\n");
		failed = 1;
	}
	/* Keep callback wait objects alive until process exit. Cancellation can
	 * leave a previously submitted callback queued on the dispatch queue. */
	if (failed) return 1;
	puts("notify-access: PASS (finchtest cannot read or post root's protected name; root can post)");
	return 0;
}
