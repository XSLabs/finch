/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Mount Finch's pre-initialized APFS data volume before ordinary startup.
 * This program never creates or repairs a filesystem or provisions account data.
 */
#include "data-volume-policy.h"
#include "data-volume-process.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define CONFIG_PATH "/private/etc/finch/data-volume"
#define MOUNT_PATH "/private/var/rw"
#define MOUNT_APFS "/sbin/mount_apfs"
#define UMOUNT "/sbin/umount"
#define FSCK_APFS "/System/Library/Filesystems/apfs.fs/Contents/Resources/fsck_apfs"
#define UUID_PROPERTY "UUID"
#define BSD_NAME_PROPERTY "BSD Name"
#define WAIT_SECONDS 30
#define STABLE_SCANS 3
#define POLL_NANOSECONDS 200000000L
#define FSCK_TIMEOUT_MILLISECONDS 120000
#define MOUNT_TIMEOUT_MILLISECONDS 30000
#define UMOUNT_TIMEOUT_MILLISECONDS 30000

struct volume_match {
	unsigned int count;
	bool invalid;
	char bsd_name[32];
};

static void
report(const char *message)
{
	fprintf(stderr, "finch-data-volume: %s\n", message);
}

static int
open_directory_component(int parent, const char *name, struct stat *result)
{
	int fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
	struct stat st;

	if (fd < 0)
		return -1;
	if (fstat(fd, &st) != 0 || !S_ISDIR(st.st_mode) || st.st_uid != 0 ||
	    st.st_gid != 0 || (st.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
		close(fd);
		errno = EPERM;
		return -1;
	}
	if (result)
		*result = st;
	return fd;
}

static int
open_mount_directory(void)
{
	int root = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
	int current = -1;
	const char *const parts[] = { "private", "var", "rw" };

	if (root < 0)
		return -1;
	current = root;
	for (size_t i = 0; i < sizeof(parts) / sizeof(parts[0]); i++) {
		int next = open_directory_component(current, parts[i], NULL);
		close(current);
		if (next < 0) {
			return -1;
		}
		current = next;
	}
	return current;
}

static int
read_config_uuid(uuid_t expected)
{
	int root = -1, private_dir = -1, etc_dir = -1, finch_dir = -1, fd = -1;
	struct stat st;
	unsigned char bytes[40];
	size_t used = 0;
	int result = -1;

	root = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
	if (root < 0)
		goto done;
	private_dir = open_directory_component(root, "private", NULL);
	if (private_dir < 0)
		goto done;
	etc_dir = open_directory_component(private_dir, "etc", NULL);
	if (etc_dir < 0)
		goto done;
	finch_dir = open_directory_component(etc_dir, "finch", NULL);
	if (finch_dir < 0)
		goto done;
	fd = openat(finch_dir, "data-volume",
	    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
	if (fd < 0 || fstat(fd, &st) != 0 || !finch_dv_valid_config_stat(&st)) {
		errno = EPERM;
		goto done;
	}
	for (;;) {
		ssize_t n;
		if (used == sizeof(bytes)) {
			unsigned char extra;
			n = read(fd, &extra, 1);
			if (n != 0)
				goto done;
			break;
		}
		n = read(fd, bytes + used, sizeof(bytes) - used);
		if (n < 0 && errno == EINTR)
			continue;
		if (n < 0)
			goto done;
		if (n == 0)
			break;
		used += (size_t)n;
	}
	if (finch_dv_parse_uuid_line(bytes, used, expected) != 0) {
		errno = EINVAL;
		goto done;
	}
	result = 0;

done:
	if (fd >= 0)
		close(fd);
	if (finch_dir >= 0)
		close(finch_dir);
	if (etc_dir >= 0)
		close(etc_dir);
	if (private_dir >= 0)
		close(private_dir);
	if (root >= 0)
		close(root);
	if (result != 0)
		report("the UUID setting is missing or unsafe");
	return result;
}

static bool
service_is_on_virtio_block(io_service_t service)
{
	io_registry_entry_t current = service;
	bool found = false;

	IOObjectRetain(current);
	for (unsigned int depth = 0; depth < 64; depth++) {
		io_registry_entry_t parent = IO_OBJECT_NULL;
		if (IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) != KERN_SUCCESS)
			break;
		IOObjectRelease(current);
		current = parent;
		if (IOObjectConformsTo(current, "AppleVirtIOBlockStorageDevice")) {
			found = true;
			break;
		}
	}
	IOObjectRelease(current);
	return found;
}

static bool
read_registry_uuid(io_service_t service, uuid_t result)
{
	CFTypeRef value = IORegistryEntryCreateCFProperty(service, CFSTR(UUID_PROPERTY),
	    kCFAllocatorDefault, 0);
	char text[64];
	bool ok = false;

	if (value && CFGetTypeID(value) == CFStringGetTypeID() &&
	    CFStringGetCString((CFStringRef)value, text, sizeof(text), kCFStringEncodingUTF8) &&
	    uuid_parse(text, result) == 0)
		ok = true;
	if (value)
		CFRelease(value);
	return ok;
}

static bool
read_registry_bsd_name(io_service_t service, char *result, size_t result_size)
{
	CFTypeRef value = IORegistryEntryCreateCFProperty(service, CFSTR(BSD_NAME_PROPERTY),
	    kCFAllocatorDefault, 0);
	bool ok = false;

	if (value && CFGetTypeID(value) == CFStringGetTypeID() &&
	    CFStringGetCString((CFStringRef)value, result, (CFIndex)result_size,
	    kCFStringEncodingUTF8) && finch_dv_valid_bsd_name(result))
		ok = true;
	if (value)
		CFRelease(value);
	return ok;
}

static int
scan_registry(const uuid_t expected, struct volume_match *match)
{
	CFMutableDictionaryRef matching = IOServiceMatching("AppleAPFSVolume");
	io_iterator_t iterator = IO_OBJECT_NULL;
	IOReturn kr;

	memset(match, 0, sizeof(*match));
	if (!matching)
		return -1;
	kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator);
	if (kr != KERN_SUCCESS)
		return -1;
	for (io_service_t service = IOIteratorNext(iterator); service != IO_OBJECT_NULL;
	    service = IOIteratorNext(iterator)) {
		uuid_t actual;
		if (read_registry_uuid(service, actual) && uuid_compare(actual, expected) == 0) {
			match->count++;
			if (!service_is_on_virtio_block(service) ||
			    !read_registry_bsd_name(service, match->bsd_name, sizeof(match->bsd_name)))
				match->invalid = true;
		}
		IOObjectRelease(service);
	}
	IOObjectRelease(iterator);
	return 0;
}

static int
find_volume(const uuid_t expected, char *bsd_name, size_t bsd_size)
{
	struct timespec start, now, delay = { .tv_sec = 0, .tv_nsec = POLL_NANOSECONDS };
	char previous[32] = { 0 };
	unsigned int stable = 0;

	if (clock_gettime(CLOCK_MONOTONIC, &start) != 0)
		return -1;
	for (;;) {
		struct volume_match match;
		if (scan_registry(expected, &match) != 0) {
			report("could not read the I/O registry");
			return -1;
		}
		if (match.count > 1) {
			report("more than one APFS volume has the configured UUID");
			return -1;
		}
		if (match.count == 1 && !match.invalid) {
			if (strcmp(previous, match.bsd_name) == 0)
				stable++;
			else {
				strlcpy(previous, match.bsd_name, sizeof(previous));
				stable = 1;
			}
			if (stable >= STABLE_SCANS) {
				if (strlcpy(bsd_name, match.bsd_name, bsd_size) >= bsd_size)
					return -1;
				return 0;
			}
		} else {
			previous[0] = '\0';
			stable = 0;
		}
		if (clock_gettime(CLOCK_MONOTONIC, &now) != 0)
			return -1;
		if (now.tv_sec - start.tv_sec >= WAIT_SECONDS) {
			report("the configured APFS volume did not appear within 30 seconds");
			return -1;
		}
		(void)nanosleep(&delay, NULL);
	}
}

static int
check_device_nodes(const char *bsd_name, char *block_path, size_t block_size,
    char *raw_path, size_t raw_size)
{
	struct stat block_st, raw_st;

	if (!finch_dv_valid_bsd_name(bsd_name) ||
	    snprintf(block_path, block_size, "/dev/%s", bsd_name) >= (int)block_size ||
	    snprintf(raw_path, raw_size, "/dev/r%s", bsd_name) >= (int)raw_size)
		return -1;
	if (lstat(block_path, &block_st) != 0 || !S_ISBLK(block_st.st_mode) ||
	    block_st.st_uid != 0 || lstat(raw_path, &raw_st) != 0 ||
	    !S_ISCHR(raw_st.st_mode) || raw_st.st_uid != 0) {
		report("the selected disk nodes are missing or have the wrong type");
		return -1;
	}
	return 0;
}

static int
run_checked_program(const char *path, char *const arguments[],
	unsigned int timeout_milliseconds, const char *failure_message)
{
	enum finch_dv_process_result result = finch_dv_run_program(path, arguments,
	    timeout_milliseconds);
	if (result == FINCH_DV_PROCESS_OK)
		return 0;
	if (result == FINCH_DV_PROCESS_TIMEOUT)
		report("a helper command timed out and was stopped");
	else if (result == FINCH_DV_PROCESS_REAP_TIMEOUT)
		report("a timed-out helper process did not stop within the cleanup limit");
	else if (result == FINCH_DV_PROCESS_SIGNALED)
		report("a helper command stopped because of a signal");
	else if (result == FINCH_DV_PROCESS_SYSTEM_ERROR)
		report("could not start or wait for a helper command");
	report(failure_message);
	return -1;
}

static int
verify_mounted_uuid(const char *path, const uuid_t expected)
{
	struct {
		uint32_t length;
		uuid_t uuid;
	} __attribute__((aligned(4), packed)) attributes;
	struct attrlist list = { .bitmapcount = ATTR_BIT_MAP_COUNT,
	    .volattr = ATTR_VOL_INFO | ATTR_VOL_UUID };

	memset(&attributes, 0, sizeof(attributes));
	if (getattrlist(path, &list, &attributes, sizeof(attributes), 0) != 0 ||
	    attributes.length < sizeof(attributes) || uuid_compare(attributes.uuid, expected) != 0) {
		report("the mounted filesystem UUID does not match the setting");
		return -1;
	}
	return 0;
}

static int
verify_mounted_volume(const char *block_path, const uuid_t expected,
	bool expect_readonly)
{
	int mount_fd = open_mount_directory();
	struct statfs fs;

	if (mount_fd < 0) {
		report("the mount folder is missing or unsafe");
		return -1;
	}
	if (fstatfs(mount_fd, &fs) != 0 ||
	    !finch_dv_valid_mount_stat(&fs, block_path, MOUNT_PATH, expect_readonly)) {
		close(mount_fd);
		report("the mounted filesystem source, type, or safety flags are wrong");
		return -1;
	}
	close(mount_fd);
	return verify_mounted_uuid(MOUNT_PATH, expected);
}

static bool
mount_is_present(void)
{
	int mount_fd = open_mount_directory();
	struct statfs fs;
	bool present = false;

	if (mount_fd >= 0) {
		present = fstatfs(mount_fd, &fs) == 0 &&
		    strcmp(fs.f_mntonname, MOUNT_PATH) == 0;
		close(mount_fd);
	}
	return present;
}

static int
unmount_data_volume(void)
{
	char *arguments[] = { (char *)UMOUNT, (char *)MOUNT_PATH, NULL };
	if (run_checked_program(UMOUNT, arguments, UMOUNT_TIMEOUT_MILLISECONDS,
	    "could not unmount the data volume") != 0) {
		report("the data volume may still be mounted after cleanup failed");
		return -1;
	}
	return 0;
}

static void unmount_partial_mount(void);

static int
mount_data_volume(const char *block_path, bool readonly)
{
	char *readonly_options = "rdonly,owners,nosuid,nodev,nobrowse";
	char *writable_options = "owners,nosuid,nodev,nobrowse";
	char *arguments[] = { (char *)MOUNT_APFS, "-o",
	    readonly ? readonly_options : writable_options, (char *)block_path,
	    (char *)MOUNT_PATH, NULL };
	const char *message = readonly ? "the read-only APFS mount failed" :
	    "the writable APFS mount failed";

	if (run_checked_program(MOUNT_APFS, arguments, MOUNT_TIMEOUT_MILLISECONDS,
	    message) != 0) {
		unmount_partial_mount();
		return -1;
	}
	return 0;
}

static int
confirm_volume(const uuid_t expected, const char *bsd_name)
{
	struct volume_match match;
	if (scan_registry(expected, &match) != 0 || match.count != 1 || match.invalid ||
	    strcmp(match.bsd_name, bsd_name) != 0) {
		report("the APFS volume changed while it was checked");
		return -1;
	}
	return 0;
}

static void
unmount_partial_mount(void)
{
	if (mount_is_present())
		(void)unmount_data_volume();
}

static int
verify_account_file(int accounts_fd, const char *name, dev_t volume_device)
{
	int fd = openat(accounts_fd, name,
	    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
	struct stat st;
	int result = -1;

	if (fd >= 0 && fstat(fd, &st) == 0 &&
	    finch_dv_valid_account_stat(&st, name, volume_device))
		result = 0;
	if (fd >= 0)
		close(fd);
	return result;
}

static int
verify_data_layout(void)
{
	int root_fd = -1, directory_fd = -1, accounts_fd = -1;
	struct stat root_st, st;
	int result = -1;
	const char *const directories[] = { "accounts", "Users", "db", "root" };
	const char *const account_files[] = { "master.passwd", "passwd", "group" };

	root_fd = open_mount_directory();
	if (root_fd < 0 || fstat(root_fd, &root_st) != 0 ||
	    !S_ISDIR(root_st.st_mode) || root_st.st_uid != 0 || root_st.st_gid != 0 ||
	    (root_st.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
		report("the data volume root is not a root-owned folder");
		goto done;
	}
	for (size_t i = 0; i < sizeof(directories) / sizeof(directories[0]); i++) {
		directory_fd = open_directory_component(root_fd, directories[i], &st);
		if (directory_fd < 0 || !finch_dv_valid_directory_stat(&st, root_st.st_dev)) {
			report("a required data folder is missing or unsafe");
			goto done;
		}
		if (strcmp(directories[i], "accounts") == 0) {
			accounts_fd = directory_fd;
			directory_fd = -1;
		}
		if (directory_fd >= 0) {
			close(directory_fd);
			directory_fd = -1;
		}
	}
	for (size_t i = 0; i < sizeof(account_files) / sizeof(account_files[0]); i++) {
		if (verify_account_file(accounts_fd, account_files[i], root_st.st_dev) != 0) {
			report("an account file is missing or has unsafe ownership, links, or mode");
			goto done;
		}
	}
	result = 0;

done:
	if (directory_fd >= 0)
		close(directory_fd);
	if (accounts_fd >= 0)
		close(accounts_fd);
	if (root_fd >= 0)
		close(root_fd);
	return result;
}

int
main(void)
{
	uuid_t expected;
	char bsd_name[32], block_path[PATH_MAX], raw_path[PATH_MAX];
	int mount_fd;
	struct statfs current_fs;

	if (geteuid() != 0) {
		report("must run as root");
		return 1;
	}
	if (read_config_uuid(expected) != 0 ||
	    find_volume(expected, bsd_name, sizeof(bsd_name)) != 0 ||
	    check_device_nodes(bsd_name, block_path, sizeof(block_path), raw_path,
	    sizeof(raw_path)) != 0)
		return 1;

	mount_fd = open_mount_directory();
	if (mount_fd < 0) {
		report("the mount folder is missing or unsafe");
		return 1;
	}
	if (fstatfs(mount_fd, &current_fs) != 0) {
		close(mount_fd);
		report("could not inspect the mount folder");
		return 1;
	}
	if (strcmp(current_fs.f_mntonname, MOUNT_PATH) == 0) {
		close(mount_fd);
		if (verify_mounted_volume(block_path, expected, false) != 0 ||
		    verify_data_layout() != 0)
			return 1;
		return 0;
	}
	close(mount_fd);

	char *fsck_arguments[] = { (char *)FSCK_APFS, "-n", "-W", raw_path, NULL };
	if (run_checked_program(FSCK_APFS, fsck_arguments, FSCK_TIMEOUT_MILLISECONDS,
	    "the read-only APFS check failed; the volume was not mounted") != 0)
		return 1;
	if (mount_data_volume(block_path, true) != 0)
		return 1;
	if (verify_mounted_volume(block_path, expected, true) != 0 ||
	    verify_data_layout() != 0) {
		(void)unmount_data_volume();
		return 1;
	}
	if (unmount_data_volume() != 0)
		return 1;
	if (confirm_volume(expected, bsd_name) != 0 ||
	    check_device_nodes(bsd_name, block_path, sizeof(block_path), raw_path,
	    sizeof(raw_path)) != 0)
		return 1;
	if (mount_data_volume(block_path, false) != 0)
		return 1;
	if (verify_mounted_volume(block_path, expected, false) != 0 ||
	    verify_data_layout() != 0) {
		(void)unmount_data_volume();
		return 1;
	}
	return 0;
}
