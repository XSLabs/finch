/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Development VM image preparation, run as root inside the guest
 * (tools/vm/mkpersistent.sh). Not part of a release image.
 *
 *   finch-volume-setup system UUID
 *	Mount the system image volume with this UUID and give every file the
 *	owner and mode its manifest (/usr/share/finch/image-owners.txt in the same
 *	image) records. The image is built on the host without root, where files
 *	can't be given to root and setuid bits don't stick.
 *   finch-volume-setup data UUID SYSTEM-UUID
 *	Lay out a new, empty data volume: the account files (copied from the
 *	system image's /usr/share/finch/accounts), home folders and db. Refuses a
 *	volume that already has an accounts folder.
 *
 * Volumes are found by UUID on a VirtIO disk, as finch-data-volume finds them.
 */
#include "data-volume-process.h"
#include "data-volume-registry.h"

#include <errno.h>
#include <fcntl.h>
#include <fts.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define MOUNT_APFS "/sbin/mount_apfs"
#define UMOUNT "/sbin/umount"
#define SYSTEM_MOUNT "/private/tmp/finch-setup-system"
#define DATA_MOUNT "/private/tmp/finch-setup-data"
#define MANIFEST "usr/share/finch/image-owners.txt"
#define ACCOUNT_TEMPLATES "usr/share/finch/accounts"
#define WAIT_SECONDS 30
#define COMMAND_TIMEOUT_MILLISECONDS 30000

struct entry {
	char *path;		/* relative to the volume root; "." is the root */
	mode_t mode;
	uid_t uid;
	gid_t gid;
	bool seen;
};

static void
fail(const char *message)
{
	fprintf(stderr, "finch-volume-setup: %s\n", message);
	exit(1);
}

static void
fail_path(const char *message, const char *path)
{
	fprintf(stderr, "finch-volume-setup: %s: %s\n", message, path);
	exit(1);
}

static void
run(const char *path, char *const arguments[], const char *message)
{
	if (finch_dv_run_program(path, arguments, COMMAND_TIMEOUT_MILLISECONDS) !=
	    FINCH_DV_PROCESS_OK)
		fail(message);
}

/* The one VirtIO APFS volume with this UUID, waiting for the disk to appear. */
static void
find_volume(const uuid_t expected, char *bsd_name, size_t size)
{
	time_t start = time(NULL);
	for (;;) {
		struct finch_dv_volume_match match;
		if (finch_dv_scan_registry(expected, &match) != 0)
			fail("could not read the I/O registry");
		if (match.count > 1)
			fail("more than one APFS volume has that UUID");
		if (match.count == 1) {
			if (match.invalid)
				fail("the volume is not on a VirtIO disk");
			strlcpy(bsd_name, match.bsd_name, size);
			return;
		}
		if (time(NULL) - start >= WAIT_SECONDS)
			fail("no APFS volume with that UUID appeared");
		sleep(1);
	}
}

static void
mount_volume(const char *uuid_text, const char *mountpoint)
{
	uuid_t expected;
	char bsd_name[32], device[48];
	struct statfs fs;
	struct {
		uint32_t length;
		uuid_t uuid;
	} __attribute__((aligned(4), packed)) attributes;
	struct attrlist list = { .bitmapcount = ATTR_BIT_MAP_COUNT,
	    .volattr = ATTR_VOL_INFO | ATTR_VOL_UUID };

	if (uuid_parse(uuid_text, expected) != 0)
		fail("not a UUID");
	find_volume(expected, bsd_name, sizeof(bsd_name));
	snprintf(device, sizeof(device), "/dev/%s", bsd_name);
	if (mkdir(mountpoint, 0700) != 0)
		fail_path("cannot make a fresh mount folder", mountpoint);
	char *arguments[] = { MOUNT_APFS, "-o", "owners,nobrowse", device,
	    (char *)mountpoint, NULL };
	run(MOUNT_APFS, arguments, "the APFS mount failed");
	if (statfs(mountpoint, &fs) != 0 || strcmp(fs.f_fstypename, "apfs") != 0 ||
	    strcmp(fs.f_mntonname, mountpoint) != 0 ||
	    strcmp(fs.f_mntfromname, device) != 0 ||
	    (fs.f_flags & (MNT_RDONLY | MNT_IGNORE_OWNERSHIP)) != 0)
		fail("the volume mounted with the wrong source or flags");
	memset(&attributes, 0, sizeof(attributes));
	if (getattrlist(mountpoint, &list, &attributes, sizeof(attributes), 0) != 0 ||
	    attributes.length < sizeof(attributes) ||
	    uuid_compare(attributes.uuid, expected) != 0)
		fail("the mounted volume has a different UUID");
}

static void
unmount_volume(const char *mountpoint)
{
	char *arguments[] = { UMOUNT, (char *)mountpoint, NULL };
	sync();
	run(UMOUNT, arguments, "the unmount failed");
	rmdir(mountpoint);
}

static int
compare_entries(const void *a, const void *b)
{
	return strcmp(((const struct entry *)a)->path, ((const struct entry *)b)->path);
}

/* MODE UID GID PATH lines, the mode in octal, the path relative with no "..". */
static struct entry *
read_manifest(const char *root, size_t *count)
{
	char path[PATH_MAX];
	snprintf(path, sizeof(path), "%s/%s", root, MANIFEST);
	FILE *file = fopen(path, "r");
	if (!file)
		fail_path("cannot read the manifest", path);
	size_t capacity = 16384, n = 0;
	struct entry *entries = calloc(capacity, sizeof(*entries));
	char *line = NULL;
	size_t line_size = 0;
	ssize_t length;
	while ((length = getline(&line, &line_size, file)) > 0) {
		unsigned int mode;
		unsigned int uid, gid;
		int offset = 0;
		if (line[length - 1] == '\n')
			line[--length] = '\0';
		if (sscanf(line, "%o %u %u %n", &mode, &uid, &gid, &offset) != 3 || offset == 0 ||
		    mode > 07777)
			fail_path("malformed manifest line", line);
		const char *relative = line + offset;
		if (relative[0] == '\0' || relative[0] == '/' || strstr(relative, "..") != NULL)
			fail_path("unsafe manifest path", relative);
		if (n == capacity) {
			capacity *= 2;
			entries = realloc(entries, capacity * sizeof(*entries));
		}
		entries[n++] = (struct entry){ strdup(relative), mode, uid, gid, false };
	}
	free(line);
	fclose(file);
	qsort(entries, n, sizeof(*entries), compare_entries);
	for (size_t i = 1; i < n; i++)
		if (strcmp(entries[i - 1].path, entries[i].path) == 0)
			fail_path("manifest lists a path twice", entries[i].path);
	*count = n;
	return entries;
}

/* Walk without following links; every entry must be listed, and every listing found. */
static void
apply_manifest(const char *root)
{
	size_t count;
	struct entry *entries = read_manifest(root, &count);
	size_t root_length = strlen(root);
	char *roots[] = { (char *)root, NULL };
	FTS *tree = fts_open(roots, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, NULL);
	FTSENT *node;
	unsigned int changed = 0;

	if (!tree)
		fail("cannot walk the volume");
	errno = 0;
	while ((node = fts_read(tree)) != NULL) {
		if (node->fts_info == FTS_DP)
			continue;
		if (node->fts_info == FTS_ERR || node->fts_info == FTS_DNR ||
		    node->fts_info == FTS_NS)
			fail_path("cannot read", node->fts_path);
		const char *relative = node->fts_level == 0 ? "." :
		    node->fts_path + root_length + 1;
		struct entry key = { .path = (char *)relative };
		struct entry *e = bsearch(&key, entries, count, sizeof(*entries), compare_entries);
		if (!e)
			fail_path("not in the manifest", relative);
		e->seen = true;
		bool link = S_ISLNK(node->fts_statp->st_mode);
		/* chown clears setuid and setgid, so the mode goes on after it. */
		if (lchown(node->fts_accpath, e->uid, e->gid) != 0 ||
		    (!link && chmod(node->fts_accpath, e->mode) != 0))
			fail_path("cannot set the owner or mode", relative);
		changed++;
		errno = 0;
	}
	if (errno != 0)
		fail("the walk stopped early");
	fts_close(tree);
	for (size_t i = 0; i < count; i++)
		if (!entries[i].seen)
			fail_path("listed in the manifest but missing", entries[i].path);
	printf("finch-volume-setup: %u entries set from the manifest\n", changed);
}

static void
make_directory(const char *path, mode_t mode, uid_t uid, gid_t gid)
{
	if (mkdir(path, mode) != 0 || chown(path, uid, gid) != 0 || chmod(path, mode) != 0)
		fail_path("cannot make", path);
}

static void
copy_account_file(const char *system_root, const char *name, mode_t mode)
{
	char from[PATH_MAX], to[PATH_MAX], buffer[65536];
	snprintf(from, sizeof(from), "%s/%s/%s", system_root, ACCOUNT_TEMPLATES, name);
	snprintf(to, sizeof(to), DATA_MOUNT "/accounts/%s", name);
	int in = open(from, O_RDONLY | O_NOFOLLOW);
	int out = open(to, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
	ssize_t n;
	if (in < 0 || out < 0)
		fail_path("cannot copy the account file", name);
	while ((n = read(in, buffer, sizeof(buffer))) > 0)
		if (write(out, buffer, (size_t)n) != n)
			fail_path("cannot write the account file", name);
	if (n < 0 || fchown(out, 0, 0) != 0 || fchmod(out, mode) != 0 || fsync(out) != 0)
		fail_path("cannot finish the account file", name);
	close(in);
	close(out);
}

/* The folders rc's make_home gives a home on a RAM disk, with macOS's modes:
 * private to their owner, except Public and its Drop Box. */
static void
make_home(const char *home, mode_t mode, uid_t uid, gid_t gid)
{
	static const struct {
		const char *path;
		mode_t mode;
	} folders[] = {
		{"Desktop", 0700}, {"Documents", 0700}, {"Downloads", 0700},
		{"Movies", 0700}, {"Music", 0700}, {"Pictures", 0700},
		{"Public", 0755}, {"Public/Drop Box", 0733}, {"Library", 0700},
		{"Library/Application Support", 0700}, {"Library/Caches", 0700},
		{"Library/Preferences", 0700},
	};
	char path[PATH_MAX];
	make_directory(home, mode, uid, gid);
	for (size_t i = 0; i < sizeof(folders) / sizeof(folders[0]); i++) {
		snprintf(path, sizeof(path), "%s/%s", home, folders[i].path);
		make_directory(path, folders[i].mode, uid, gid);
	}
}

static void
lay_out_data(const char *system_root)
{
	struct stat st;
	if (lstat(DATA_MOUNT "/accounts", &st) == 0)
		fail("the data volume already has accounts; it is never set up twice");
	if (chown(DATA_MOUNT, 0, 0) != 0 || chmod(DATA_MOUNT, 0755) != 0)
		fail("cannot set the volume root's owner");
	make_directory(DATA_MOUNT "/accounts", 0755, 0, 0);
	make_directory(DATA_MOUNT "/Users", 0755, 0, 0);
	make_directory(DATA_MOUNT "/db", 0755, 0, 0);
	copy_account_file(system_root, "master.passwd", 0600);
	copy_account_file(system_root, "passwd", 0644);
	copy_account_file(system_root, "group", 0644);
	make_home(DATA_MOUNT "/root", 0750, 0, 0);
	/* the development image's test user (tools/vm/mkramdisk.sh) */
	make_home(DATA_MOUNT "/Users/finchtest", 0750, 501, 20);
	printf("finch-volume-setup: data volume laid out\n");
}

int
main(int argc, char **argv)
{
	if (geteuid() != 0)
		fail("run as root");
	if (argc == 3 && strcmp(argv[1], "system") == 0) {
		mount_volume(argv[2], SYSTEM_MOUNT);
		apply_manifest(SYSTEM_MOUNT);
		unmount_volume(SYSTEM_MOUNT);
		return 0;
	}
	if (argc == 4 && strcmp(argv[1], "data") == 0) {
		mount_volume(argv[3], SYSTEM_MOUNT);
		mount_volume(argv[2], DATA_MOUNT);
		lay_out_data(SYSTEM_MOUNT);
		unmount_volume(DATA_MOUNT);
		unmount_volume(SYSTEM_MOUNT);
		return 0;
	}
	fprintf(stderr, "usage: finch-volume-setup system UUID\n"
	    "       finch-volume-setup data UUID SYSTEM-UUID\n");
	return 2;
}
