/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Guest-only test for the FinchSandbox fixed-profile kernel proof.
 * The VM runner must list this as an exit-check test; do not run it on the host.
 */
#include <errno.h>
#include <aio.h>
#include <fcntl.h>
#include <pwd.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <security/mac.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define FINCH_SANDBOX_POLICY "FinchSandbox"
#define FINCH_SANDBOX_PROFILE_DENY_READ 1
#define FINCH_SANDBOX_PROFILE_DENY_WRITE 2
#define AIO_WAIT_TIMEOUT_MS 3000
#define AIO_CLEANUP_TIMEOUT_MS 1000

static int
apply_profile(int profile)
{
	return __mac_syscall(FINCH_SANDBOX_POLICY, profile, NULL);
}

static int
is_denied(int error)
{
	return error == EACCES || error == EPERM;
}

static int
check_clear_is_blocked(void)
{
	char clear_label_text[] = "finch_sandbox/0";
	struct mac clear_label = {
		.m_buflen = sizeof(clear_label_text),
		.m_string = clear_label_text,
	};

	errno = 0;
	if (__mac_set_proc(&clear_label) != -1 || errno != EPERM) {
		fprintf(stderr, "clearing the profile was not rejected with EPERM (errno %d)\n", errno);
		return 1;
	}
	return 0;
}

static int
check_denied_open(const char *path, int flags)
{
	int fd;

	errno = 0;
	fd = open(path, flags);
	if (fd >= 0) {
		fprintf(stderr, "open with flags %d was allowed\n", flags);
		close(fd);
		return 1;
	}
	return is_denied(errno) ? 0 : 1;
}

static int
check_read_denied(int fd, const char *path)
{
	char byte;
	ssize_t result;

	(void)lseek(fd, 0, SEEK_SET);
	errno = 0;
	result = read(fd, &byte, sizeof(byte));
	if (result != -1 || !is_denied(errno)) {
		fprintf(stderr, "read from an open file returned %zd (errno %d)\n", result, errno);
		return 1;
	}
	if (check_denied_open(path, O_RDONLY) != 0) {
		return 1;
	}
	return 0;
}

static int
check_write_denied(int fd, const char *path)
{
	char byte = 'x';
	ssize_t result;

	(void)lseek(fd, 0, SEEK_SET);
	errno = 0;
	result = write(fd, &byte, sizeof(byte));
	if (result != -1 || !is_denied(errno)) {
		fprintf(stderr, "write to an open file returned %zd (errno %d)\n", result, errno);
		return 1;
	}
	if (check_denied_open(path, O_WRONLY) != 0) {
		return 1;
	}
	return 0;
}

/* Wait only for a fixed amount of real time, even if a signal interrupts us. */
static int
wait_for_aio(const struct aiocb *request, unsigned int timeout_ms)
{
	const struct aiocb *requests[] = { request };
	struct timespec deadline;
	struct timespec now;

	if (clock_gettime(CLOCK_MONOTONIC, &deadline) != 0) {
		return -1;
	}
	deadline.tv_sec += timeout_ms / 1000;
	deadline.tv_nsec += (long)(timeout_ms % 1000) * 1000000L;
	if (deadline.tv_nsec >= 1000000000L) {
		deadline.tv_sec++;
		deadline.tv_nsec -= 1000000000L;
	}

	for (;;) {
		struct timespec remaining;
		int request_error = aio_error(request);

		if (request_error != EINPROGRESS) {
			return request_error;
		}
		if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
			return -1;
		}
		remaining.tv_sec = deadline.tv_sec - now.tv_sec;
		remaining.tv_nsec = deadline.tv_nsec - now.tv_nsec;
		if (remaining.tv_nsec < 0) {
			remaining.tv_sec--;
			remaining.tv_nsec += 1000000000L;
		}
		if (remaining.tv_sec < 0 ||
		    (remaining.tv_sec == 0 && remaining.tv_nsec == 0)) {
			errno = ETIMEDOUT;
			return -1;
		}
		if (aio_suspend(requests, 1, &remaining) == 0) {
			continue;
		}
		if (errno == EINTR || errno == EAGAIN) {
			continue;
		}
		return -1;
	}
}

static void
cleanup_aio_request(int fd, const struct aiocb *request, const char *description)
{
	int request_error = aio_error(request);

	if (request_error == EINPROGRESS) {
		(void)aio_cancel(fd, (struct aiocb *)request);
		(void)wait_for_aio(request, AIO_CLEANUP_TIMEOUT_MS);
		request_error = aio_error(request);
	}
	if (request_error == EINPROGRESS) {
		fprintf(stderr, "%s did not stop before the cleanup timeout\n",
		    description);
		(void)fflush(stderr);
		_exit(70);
	}
	(void)aio_return((struct aiocb *)request);
}

static int
check_aio_denied(int fd, int write_request, const char *description)
{
	struct aiocb request;
	char byte = write_request ? 'x' : '\x7f';
	int submit_result;
	int submit_error;
	int request_error;
	ssize_t result;

	memset(&request, 0, sizeof(request));
	request.aio_fildes = fd;
	request.aio_buf = &byte;
	request.aio_nbytes = sizeof(byte);
	request.aio_offset = 0;
	request.aio_sigevent.sigev_notify = SIGEV_NONE;
	errno = 0;
	submit_result = write_request ? aio_write(&request) : aio_read(&request);
	submit_error = errno;
	if (submit_result != 0) {
		fprintf(stderr, "%s could not be queued (result %d, errno %d)\n",
		    description, submit_result, submit_error);
		return 1;
	}

	request_error = wait_for_aio(&request, AIO_WAIT_TIMEOUT_MS);
	if (request_error == -1) {
		int wait_error = errno;

		cleanup_aio_request(fd, &request, description);
		fprintf(stderr, "%s wait failed (errno %d: %s)\n", description,
		    wait_error, strerror(wait_error));
		return 1;
	}
	result = aio_return(&request);
	/* Darwin reports the operation error through aio_error, but aio_return
	 * still returns the byte count completed before that error. The vnode
	 * denial happens before I/O, so the expected count is zero. */
	if (!is_denied(request_error) || result != 0) {
		fprintf(stderr, "%s completed with result %zd (error %d)\n",
		    description, result, request_error);
		return 1;
	}
	if (!write_request && byte != '\x7f') {
		fprintf(stderr, "%s changed its buffer despite reading no bytes\n",
		    description);
		return 1;
	}
	return 0;
}

static int
check_denied_mapping(int fd, int prot, int flags, const char *description)
{
	void *mapping;

	errno = 0;
	mapping = mmap(NULL, 1, prot, flags, fd, 0);
	if (mapping != MAP_FAILED) {
		fprintf(stderr, "%s mapping was allowed\n", description);
		(void)munmap(mapping, 1);
		return 1;
	}
	if (!is_denied(errno)) {
		fprintf(stderr, "%s mapping failed with unexpected errno %d\n",
		    description, errno);
		return 1;
	}
	return 0;
}

static int
check_write_mapping_denied(int fd)
{
	void *mapping;
	volatile char first_byte;
	int result;
	int error;

	if (check_denied_mapping(fd, PROT_READ | PROT_WRITE, MAP_SHARED,
	    "shared writable file") != 0 ||
	    check_denied_mapping(fd, PROT_READ | PROT_WRITE, MAP_PRIVATE,
	    "private writable file") != 0) {
		return 1;
	}

	/* A read-only map must not be able to gain write access later. */
	mapping = mmap(NULL, 1, PROT_READ, MAP_SHARED, fd, 0);
	if (mapping == MAP_FAILED) {
		fprintf(stderr, "read-only file mapping failed with errno %d\n",
		    errno);
		return 1;
	}
	first_byte = ((volatile char *)mapping)[0];
	(void)first_byte;
	errno = 0;
	result = mprotect(mapping, 1, PROT_READ | PROT_WRITE);
	error = errno;
	if (munmap(mapping, 1) != 0) {
		fprintf(stderr, "could not remove the read-only file mapping\n");
		return 1;
	}
	if (result != -1 || !is_denied(error)) {
		fprintf(stderr, "mprotect added write access (result %d, errno %d)\n",
		    result, error);
		return 1;
	}
	return 0;
}

static int
drop_to_test_user(void)
{
	struct passwd *user;

	errno = 0;
	user = getpwnam("finchtest");
	if (user == NULL) {
		if (errno == 0) {
			errno = ENOENT;
		}
		return 1;
	}
	if (geteuid() != 0) {
		errno = EPERM;
		return 1;
	}
	if (setgroups(0, NULL) != 0 || setgid(user->pw_gid) != 0 ||
	    setuid(user->pw_uid) != 0) {
		return 1;
	}
	if (geteuid() != user->pw_uid) {
		errno = EPERM;
		return 1;
	}
	return 0;
}

static void
report_child_error(const char *stage, int result, int error)
{
	if (error == 0) {
		error = EIO;
	}
	fprintf(stderr, "%s failed (result %d, errno %d: %s)\n", stage,
	    result, error, strerror(error));
	(void)fflush(stderr);
}

static int
wait_for_child(const char *description, pid_t child)
{
	int status;
	pid_t result;

	do {
		result = waitpid(child, &status, 0);
	} while (result == -1 && errno == EINTR);
	if (result != child) {
		fprintf(stderr, "%s: waitpid failed: %s\n", description,
		    strerror(errno));
		return 126;
	}
	if (WIFEXITED(status)) {
		int exit_status = WEXITSTATUS(status);

		if (exit_status == 0) {
			return 0;
		}
		fprintf(stderr, "%s: child exited with status %d\n", description,
		    exit_status);
		return exit_status;
	}
	if (WIFSIGNALED(status)) {
		fprintf(stderr, "%s: child stopped by signal %d\n", description,
		    WTERMSIG(status));
		return 128 + WTERMSIG(status);
	}
	fprintf(stderr, "%s: child returned unexpected status 0x%x\n",
	    description, (unsigned int)status);
	return 125;
}

static int
run_baseline_check(int fd, const char *path)
{
	pid_t child = fork();

	if (child < 0) {
		return 1;
	}
	if (child == 0) {
		char byte;
		int new_fd;
		void *mapping;

		if (drop_to_test_user() != 0) {
			_exit(20);
		}
		(void)lseek(fd, 0, SEEK_SET);
		if (read(fd, &byte, sizeof(byte)) != 1) {
			_exit(21);
		}
		new_fd = open(path, O_RDONLY);
		if (new_fd < 0 || close(new_fd) != 0) {
			_exit(22);
		}
		new_fd = open(path, O_WRONLY);
		if (new_fd < 0) {
			_exit(23);
		}
		byte = 'b';
		if (write(new_fd, &byte, sizeof(byte)) != 1 || close(new_fd) != 0) {
			_exit(24);
		}
		mapping = mmap(NULL, 1, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
		if (mapping == MAP_FAILED) {
			_exit(25);
		}
		((volatile char *)mapping)[0] = 'm';
		if (munmap(mapping, 1) != 0) {
			_exit(26);
		}
		_exit(0);
	}
	return wait_for_child("baseline access check", child);
}

static int
run_read_profile_check(int fd, const char *path)
{
	pid_t child = fork();

	if (child < 0) {
		return 1;
	}
	if (child == 0) {
		pid_t forked;
		int result;
		int error;

		if (drop_to_test_user() != 0) {
			error = errno;
			report_child_error("deny-read: drop_to_test_user", 1, error);
			_exit(30);
		}
		errno = 0;
		result = apply_profile(FINCH_SANDBOX_PROFILE_DENY_READ);
		error = errno;
		if (result != 0) {
			report_child_error("deny-read: apply_profile", result, error);
			_exit(35);
		}
		if (check_read_denied(fd, path) != 0 ||
		    check_aio_denied(fd, 0, "deny-read AIO read") != 0 ||
		    check_denied_mapping(fd, PROT_READ, MAP_PRIVATE,
		    "read-only file") != 0 ||
		    check_denied_mapping(fd, PROT_NONE, MAP_PRIVATE,
		    "no-access file") != 0 ||
		    check_clear_is_blocked() != 0) {
			_exit(31);
		}
		errno = 0;
		if (apply_profile(FINCH_SANDBOX_PROFILE_DENY_WRITE) != -1 ||
		    errno != EPERM) {
			_exit(32);
		}

		forked = fork();
		if (forked < 0) {
			_exit(33);
		}
		if (forked == 0) {
			errno = 0;
			if (apply_profile(FINCH_SANDBOX_PROFILE_DENY_READ) != -1 ||
			    errno != EPERM || check_read_denied(fd, path) != 0) {
				_exit(34);
			}
			_exit(0);
		}
		_exit(wait_for_child("deny-read fork check", forked));
	}
	return wait_for_child("deny-read profile check", child);
}

static int
run_write_profile_check(int fd, const char *path, const char *self)
{
	char byte_before;
	char byte_after;
	ssize_t bytes_read;
	int child_status;
	pid_t child;

	/* Keep a parent-side copy to catch any AIO write that slips through. */
	bytes_read = pread(fd, &byte_before, sizeof(byte_before), 0);
	if (bytes_read != 1) {
		fprintf(stderr, "could not save the file byte before deny-write test\n");
		return 1;
	}
	child = fork();
	if (child < 0) {
		return 1;
	}
	if (child == 0) {
		pid_t forked;
		int result;
		int error;

		if (drop_to_test_user() != 0) {
			error = errno;
			report_child_error("deny-write: drop_to_test_user", 1, error);
			_exit(40);
		}
		errno = 0;
		result = apply_profile(FINCH_SANDBOX_PROFILE_DENY_WRITE);
		error = errno;
		if (result != 0) {
			report_child_error("deny-write: apply_profile", result, error);
			_exit(45);
		}
		if (check_write_denied(fd, path) != 0 ||
		    check_aio_denied(fd, 1, "deny-write AIO write") != 0 ||
		    check_write_mapping_denied(fd) != 0 ||
		    check_clear_is_blocked() != 0) {
			_exit(41);
		}
		errno = 0;
		if (apply_profile(FINCH_SANDBOX_PROFILE_DENY_READ) != -1 ||
		    errno != EPERM) {
			_exit(42);
		}

		forked = fork();
		if (forked < 0) {
			_exit(43);
		}
		if (forked == 0) {
			char fd_text[32];
			char *const args[] = { (char *)self, "--after-exec",
			    (char *)path, fd_text, NULL };

			(void)snprintf(fd_text, sizeof(fd_text), "%d", fd);
			execvp(self, args);
			_exit(44);
		}
		_exit(wait_for_child("deny-write exec inheritance check", forked));
	}
	child_status = wait_for_child("deny-write profile check", child);
	bytes_read = pread(fd, &byte_after, sizeof(byte_after), 0);
	if (bytes_read != 1) {
		fprintf(stderr, "could not check the file byte after deny-write test\n");
		return 1;
	}
	if (byte_after != byte_before) {
		fprintf(stderr, "deny-write AIO changed the file byte from '%c' to '%c'\n",
		    byte_before, byte_after);
		return 1;
	}
	return child_status;
}

static int
run_after_exec_check(const char *path, int fd)
{
	errno = 0;
	if (apply_profile(FINCH_SANDBOX_PROFILE_DENY_WRITE) != -1 || errno != EPERM) {
		return 50;
	}
	if (check_write_denied(fd, path) != 0) {
		return 51;
	}
	return 0;
}

int
main(int argc, char **argv)
{
	char path[] = "/tmp/finch-sandbox-proof-XXXXXX";
	const char seed[] = "finch sandbox test\n";
	const char *failed_stage = NULL;
	int fd;
	int status = 0;

	if (argc == 4 && strcmp(argv[1], "--after-exec") == 0) {
		return run_after_exec_check(argv[2], atoi(argv[3]));
	}
	if (geteuid() != 0) {
		return 2;
	}
	fd = mkstemp(path);
	if (fd < 0 || fchmod(fd, 0666) != 0 ||
	    write(fd, seed, sizeof(seed)) != (ssize_t)sizeof(seed) ||
	    fsync(fd) != 0) {
		if (fd >= 0) {
			close(fd);
			unlink(path);
		}
		return 3;
	}
	if (run_baseline_check(fd, path) != 0) {
		status = 4;
		failed_stage = "baseline access";
	} else if (run_read_profile_check(fd, path) != 0) {
		status = 5;
		failed_stage = "deny-read profile";
	} else if (run_write_profile_check(fd, path, argv[0]) != 0) {
		status = 6;
		failed_stage = "deny-write profile";
	}
	close(fd);
	unlink(path);
	if (status == 0) {
		puts("FinchSandbox enforcement proof passed");
	} else {
		fprintf(stderr, "FinchSandbox proof failed during %s (code %d)\n",
		    failed_stage, status);
	}
	return status;
}
