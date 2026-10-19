/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Check that cancel drops a path-watch callback that was already queued.
 * Run as root in the Finch VM. All watched files live in a private temp dir.
 */
#include <dispatch/dispatch.h>
#include <notify.h>
#include <notify_private.h>

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define PATH_NODE_ALL 0x3ff
#define EVENT_TIMEOUT_MS 5000
#define SETUP_QUIET_MS 300
#define CANCEL_CLOSE_TIMEOUT_MS 3000
#define QUEUE_TIMEOUT_MS 5000
#define QUEUE_QUIET_MS 250
#define POLL_NS (10ull * 1000000ull)
#define BLOCKER_TIMEOUT_NS (45ull * NSEC_PER_SEC)

static atomic_uint callback_count;
static atomic_int blocker_timed_out;
static dispatch_semaphore_t blocker_entered;
static dispatch_semaphore_t blocker_release;

static int failures;

#define FAIL(message) do { \
	fprintf(stderr, "FAIL: %s\n", (message)); \
	failures++; \
} while (0)

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
wait_semaphore(dispatch_semaphore_t semaphore, int timeout_ms)
{
	dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW,
		(int64_t)timeout_ms * NSEC_PER_MSEC);
	return dispatch_semaphore_wait(semaphore, deadline) == 0 ? 0 : -1;
}

static int
write_byte(const char *path, char value)
{
	int fd = open(path, O_WRONLY | O_APPEND);
	if (fd < 0) return -1;
	ssize_t written;
	do {
		written = write(fd, &value, sizeof(value));
	} while (written < 0 && errno == EINTR);
	if (written != (ssize_t)sizeof(value))
	{
		int saved_errno = (written < 0) ? errno : EIO;
		(void)close(fd);
		errno = saved_errno;
		return -1;
	}
	if (fsync(fd) != 0)
	{
		int saved_errno = errno;
		(void)close(fd);
		errno = saved_errno;
		return -1;
	}
	if (close(fd) != 0) return -1;
	return 0;
}

static int
wait_for_check_change(int token, int timeout_ms)
{
	uint64_t deadline = monotonic_ms() + (uint64_t)timeout_ms;
	while (monotonic_ms() < deadline)
	{
		int changed = 0;
		uint32_t status = notify_check(token, &changed);
		if (status != NOTIFY_STATUS_OK)
		{
			fprintf(stderr, "notify_check failed with status %u\n", status);
			return -1;
		}
		if (changed) return 0;
		pause_briefly();
	}
	errno = ETIMEDOUT;
	return -1;
}

/* Clear setup noise, then require a quiet span before the deliberate writes. */
static int
wait_for_quiet(int token, int quiet_ms, int timeout_ms)
{
	uint64_t now = monotonic_ms();
	uint64_t deadline = now + (uint64_t)timeout_ms;
	uint64_t quiet_since = now;
	while (now < deadline)
	{
		int changed = 0;
		uint32_t status = notify_check(token, &changed);
		if (status != NOTIFY_STATUS_OK)
		{
			fprintf(stderr, "notify_check failed with status %u\n", status);
			return -1;
		}
		if (changed) quiet_since = now;
		else if (now - quiet_since >= (uint64_t)quiet_ms) return 0;
		pause_briefly();
		now = monotonic_ms();
	}
	errno = ETIMEDOUT;
	return -1;
}

static int
has_open_file(dev_t device, ino_t inode)
{
	long limit = sysconf(_SC_OPEN_MAX);
	if (limit < 0) limit = getdtablesize();
	if (limit < 0) return -1;
	if (limit > 65536) limit = 65536;
	for (int fd = 0; fd < limit; fd++)
	{
		struct stat current;
		if (fstat(fd, &current) == 0 && current.st_dev == device && current.st_ino == inode)
			return 1;
	}
	return 0;
}

static int
wait_for_file_state(dev_t device, ino_t inode, int should_be_open, int timeout_ms)
{
	uint64_t deadline = monotonic_ms() + (uint64_t)timeout_ms;
	while (monotonic_ms() < deadline)
	{
		int open_now = has_open_file(device, inode);
		if (open_now < 0) return -1;
		if (open_now == should_be_open) return 0;
		pause_briefly();
	}
	errno = ETIMEDOUT;
	return -1;
}

static int
queue_marker(dispatch_queue_t queue)
{
	dispatch_semaphore_t marker = dispatch_semaphore_create(0);
	if (marker == NULL) return -1;
	/* The queued block may outlive a failed wait. Keep its own reference. */
	dispatch_retain(marker);
	dispatch_async(queue, ^{
		dispatch_semaphore_signal(marker);
		dispatch_release(marker);
	});
	int result = wait_semaphore(marker, QUEUE_TIMEOUT_MS);
	dispatch_release(marker);
	return result;
}

static void
check_canceled_apis(int token, char *path)
{
	uint64_t state = 0;
	int changed = 0;
	if (notify_is_valid_token(token)) FAIL("canceled token still looks valid");
	if (notify_check(token, &changed) != NOTIFY_STATUS_INVALID_TOKEN)
		FAIL("notify_check accepted a canceled token");
	uint32_t peek_value = 0;
	if (notify_peek(token, &peek_value) != NOTIFY_STATUS_INVALID_TOKEN)
		FAIL("notify_peek accepted a canceled token");
	if (notify_get_state(token, &state) != NOTIFY_STATUS_INVALID_TOKEN)
		FAIL("notify_get_state accepted a canceled token");
	if (notify_set_state(token, 1) != NOTIFY_STATUS_INVALID_TOKEN)
		FAIL("notify_set_state accepted a canceled token");
	if (notify_suspend(token) != NOTIFY_STATUS_INVALID_TOKEN)
		FAIL("notify_suspend accepted a canceled token");
	if (notify_resume(token) != NOTIFY_STATUS_INVALID_TOKEN)
		FAIL("notify_resume accepted a canceled token");
	if (notify_monitor_file(token, path, PATH_NODE_ALL) != NOTIFY_STATUS_INVALID_TOKEN)
		FAIL("notify_monitor_file accepted a canceled token");
}

int
main(void)
{
	char directory[] = "/tmp/finch-notify-path-cancel.XXXXXX";
	char path[PATH_MAX];
	char name[160];
	int token = NOTIFY_TOKEN_INVALID;
	int registered = 0;
	int canceled = 0;
	int blocker_started = 0;
	int blocker_unblocked = 0;
	int queue_drained = 0;
	int result = 1;
	int write_status;
	struct stat watched_file;
	dispatch_queue_t callback_queue = NULL;

	alarm(55);
	atomic_init(&callback_count, 0);
	atomic_init(&blocker_timed_out, 0);

	if (mkdtemp(directory) == NULL)
	{
		perror("mkdtemp");
		return 1;
	}
	if (snprintf(path, sizeof(path), "%s/watched.txt", directory) >= (int)sizeof(path))
	{
		FAIL("temporary file path was too long");
		goto cleanup;
	}
	int file_fd = open(path, O_CREAT | O_EXCL | O_WRONLY, 0600);
	if (file_fd < 0)
	{
		perror("create watched file");
		FAIL("could not create watched file");
		goto cleanup;
	}
	ssize_t initial_write = write(file_fd, "start", 5);
	int initial_close = close(file_fd);
	if (initial_write != 5 || initial_close != 0 || stat(path, &watched_file) != 0)
	{
		perror("prepare watched file");
		FAIL("could not prepare watched file");
		goto cleanup;
	}
	if (chmod(directory, 0700) != 0)
	{
		perror("chmod temporary directory");
		FAIL("could not protect temporary directory");
		goto cleanup;
	}
	if (snprintf(name, sizeof(name), "com.finch.notify.path.cancel.%ld.%08x",
		(long)getpid(), arc4random()) >= (int)sizeof(name))
	{
		FAIL("notification name was too long");
		goto cleanup;
	}

	callback_queue = dispatch_queue_create("com.finch.notify.path.cancel.test", DISPATCH_QUEUE_SERIAL);
	blocker_entered = dispatch_semaphore_create(0);
	blocker_release = dispatch_semaphore_create(0);
	if (callback_queue == NULL || blocker_entered == NULL || blocker_release == NULL)
	{
		FAIL("could not create callback queue");
		goto cleanup;
	}

	/* Hold the callback queue so a real event can queue work without running it. */
	dispatch_async(callback_queue, ^{
		dispatch_semaphore_signal(blocker_entered);
		dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, BLOCKER_TIMEOUT_NS);
		if (dispatch_semaphore_wait(blocker_release, deadline) != 0)
			atomic_store_explicit(&blocker_timed_out, 1, memory_order_relaxed);
	});
	blocker_started = 1;
	if (wait_semaphore(blocker_entered, QUEUE_TIMEOUT_MS) != 0)
	{
		FAIL("callback queue did not start its blocker");
		goto cleanup;
	}

	uint32_t status = notify_register_dispatch(name, &token, callback_queue, ^(int callback_token) {
		(void)callback_token;
		atomic_fetch_add_explicit(&callback_count, 1, memory_order_relaxed);
	});
	if (status != NOTIFY_STATUS_OK)
	{
		fprintf(stderr, "notify_register_dispatch failed with status %u\n", status);
		FAIL("could not register dispatch callback");
		goto cleanup;
	}
	registered = 1;
	status = notify_monitor_file(token, path, PATH_NODE_ALL);
	if (status != NOTIFY_STATUS_OK)
	{
		fprintf(stderr, "notify_monitor_file failed with status %u\n", status);
		FAIL("could not watch temporary file");
		goto cleanup;
	}
	if (wait_for_file_state(watched_file.st_dev, watched_file.st_ino, 1, EVENT_TIMEOUT_MS) != 0)
	{
		FAIL("path watcher did not open the watched file");
		goto cleanup;
	}
	if (wait_for_quiet(token, SETUP_QUIET_MS, EVENT_TIMEOUT_MS) != 0)
	{
		FAIL("path watcher did not settle before the test writes");
		goto cleanup;
	}

	/*
	 * Use the same token as the callback. A check watcher alone cannot prove a
	 * dispatch callback was queued. These two separate checks can: path events
	 * are handled in order, and each check sees that token's event count. By the
	 * time event two is visible, event one's callback has already been queued.
	 */
	write_status = write_byte(path, '1');
	if (write_status != 0 || wait_for_check_change(token, EVENT_TIMEOUT_MS) != 0)
	{
		perror("first watched-file change");
		FAIL("first file change did not reach notify_check");
		goto cleanup;
	}
	write_status = write_byte(path, '2');
	if (write_status != 0 || wait_for_check_change(token, EVENT_TIMEOUT_MS) != 0)
	{
		perror("second watched-file change");
		FAIL("second file change did not reach notify_check");
		goto cleanup;
	}

	status = notify_cancel(token);
	if (status != NOTIFY_STATUS_OK)
	{
		fprintf(stderr, "notify_cancel failed with status %u\n", status);
		FAIL("could not cancel path watch");
		goto cleanup;
	}
	canceled = 1;
	check_canceled_apis(token, path);
	int open_after_cancel = has_open_file(watched_file.st_dev, watched_file.st_ino);
	if (open_after_cancel != 0)
		FAIL("cancel returned before closing the path watch file descriptor");
	if (wait_for_file_state(watched_file.st_dev, watched_file.st_ino, 0,
		CANCEL_CLOSE_TIMEOUT_MS) != 0)
		FAIL("cancel did not close the path watch file descriptor");

	/* Release the queue, then wait until the already-queued wrapper has run. */
	dispatch_semaphore_signal(blocker_release);
	blocker_unblocked = 1;
	if (queue_marker(callback_queue) != 0)
		FAIL("callback queue did not reach its marker");
	else
		queue_drained = 1;
	if (!queue_drained || atomic_load_explicit(&callback_count, memory_order_relaxed) != 0)
		FAIL("a callback ran after its token was canceled");
	if (atomic_load_explicit(&blocker_timed_out, memory_order_relaxed) != 0)
		FAIL("callback queue blocker timed out before cancel finished");

	/* A second marker after a short quiet span catches late queued callbacks. */
	struct timespec quiet_pause = {
		.tv_sec = QUEUE_QUIET_MS / 1000,
		.tv_nsec = (long)(QUEUE_QUIET_MS % 1000) * 1000000L
	};
	while (nanosleep(&quiet_pause, &quiet_pause) != 0 && errno == EINTR) {}
	if (queue_marker(callback_queue) != 0)
		FAIL("callback queue did not reach its second marker");
	if (atomic_load_explicit(&callback_count, memory_order_relaxed) != 0)
		FAIL("a late callback ran after its token was canceled");

	if (failures == 0)
	{
		printf("PASS: canceled path-watch callbacks were dropped and resources closed\n");
		result = 0;
	}

cleanup:
	if (registered && !canceled)
	{
		(void)notify_cancel(token);
		canceled = 1;
	}
	if (blocker_started && !blocker_unblocked)
	{
		dispatch_semaphore_signal(blocker_release);
		blocker_unblocked = 1;
	}
	if (callback_queue != NULL && blocker_started && !queue_drained)
		queue_drained = queue_marker(callback_queue) == 0;
	if (failures != 0) result = 1;
	/* On a timeout, let process exit reclaim objects still used by queued work. */
	if (!blocker_started || queue_drained) {
		if (callback_queue != NULL) dispatch_release(callback_queue);
		if (blocker_entered != NULL) dispatch_release(blocker_entered);
		if (blocker_release != NULL) dispatch_release(blocker_release);
	}
	(void)unlink(path);
	(void)rmdir(directory);
	alarm(0);
	return result;
}
