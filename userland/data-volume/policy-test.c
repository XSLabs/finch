/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "data-volume-policy.h"

#include <stdio.h>
#include <string.h>

static unsigned int checks;
static unsigned int failures;

#define CHECK(expression) do { \
	checks++; \
	if (!(expression)) { \
		fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #expression); \
		failures++; \
	} \
} while (0)

static void
test_uuid_lines(void)
{
	uuid_t parsed, expected;
	static const char good[] = "b33ca319-c67f-4e1b-a36c-9071a24c4633\n";
	static const char upper[] = "B33CA319-C67F-4E1B-A36C-9071A24C4633";
	static const char extra[] = "b33ca319-c67f-4e1b-a36c-9071a24c4633\n\n";
	static const char nul[] = "b33ca319-c67f-4e1b-a36c-9071a24c4633\0";

	uuid_parse("b33ca319-c67f-4e1b-a36c-9071a24c4633", expected);
	CHECK(finch_dv_parse_uuid_line(good, sizeof(good) - 1, parsed) == 0);
	CHECK(uuid_compare(parsed, expected) == 0);
	CHECK(finch_dv_parse_uuid_line(upper, sizeof(upper) - 1, parsed) == 0);
	CHECK(uuid_compare(parsed, expected) == 0);
	CHECK(finch_dv_parse_uuid_line(upper, 35, parsed) != 0);
	CHECK(finch_dv_parse_uuid_line(extra, sizeof(extra) - 1, parsed) != 0);
	CHECK(finch_dv_parse_uuid_line(nul, sizeof(nul) - 1, parsed) != 0);
	CHECK(finch_dv_parse_uuid_line("not-a-uuid", 10, parsed) != 0);
	CHECK(finch_dv_parse_uuid_line(NULL, 0, parsed) != 0);
}

static void
test_bsd_names(void)
{
	CHECK(finch_dv_valid_bsd_name("disk1s1"));
	CHECK(finch_dv_valid_bsd_name("disk12s5s1"));
	CHECK(!finch_dv_valid_bsd_name("disk1"));
	CHECK(!finch_dv_valid_bsd_name("disk1s"));
	CHECK(!finch_dv_valid_bsd_name("/dev/disk1s1"));
	CHECK(!finch_dv_valid_bsd_name("disk1s1/../../etc/passwd"));
	CHECK(!finch_dv_valid_bsd_name("diskxs1"));
	CHECK(!finch_dv_valid_bsd_name("rdisk1s1"));
}

static struct stat
regular_stat(uid_t uid, gid_t gid, nlink_t links, mode_t mode, dev_t device)
{
	struct stat st;
	memset(&st, 0, sizeof(st));
	st.st_mode = S_IFREG | mode;
	st.st_uid = uid;
	st.st_gid = gid;
	st.st_nlink = links;
	st.st_dev = device;
	return st;
}

static void
test_file_rules(void)
{
	struct stat st = regular_stat(0, 0, 1, 0644, 9);
	CHECK(finch_dv_valid_config_stat(&st));
	st.st_mode = S_IFREG | 0664;
	CHECK(!finch_dv_valid_config_stat(&st));
	st = regular_stat(501, 0, 1, 0644, 9);
	CHECK(!finch_dv_valid_config_stat(&st));
	st = regular_stat(0, 0, 2, 0644, 9);
	CHECK(!finch_dv_valid_config_stat(&st));

	st = regular_stat(0, 0, 1, 0600, 9);
	CHECK(finch_dv_valid_account_stat(&st, "master.passwd", 9));
	CHECK(!finch_dv_valid_account_stat(&st, "passwd", 9));
	st.st_mode = S_IFREG | 0644;
	CHECK(finch_dv_valid_account_stat(&st, "passwd", 9));
	CHECK(finch_dv_valid_account_stat(&st, "group", 9));
	CHECK(!finch_dv_valid_account_stat(&st, "other", 9));
	CHECK(!finch_dv_valid_account_stat(&st, "group", 10));
	st.st_mode = S_IFREG | 0664;
	CHECK(!finch_dv_valid_account_stat(&st, "group", 9));
	st = regular_stat(0, 0, 2, 0644, 9);
	CHECK(!finch_dv_valid_account_stat(&st, "passwd", 9));
}

static void
test_directory_rules(void)
{
	struct stat st;
	memset(&st, 0, sizeof(st));
	st.st_mode = S_IFDIR | 0755;
	st.st_uid = 0;
	st.st_gid = 0;
	st.st_dev = 42;
	CHECK(finch_dv_valid_directory_stat(&st, 42));
	CHECK(!finch_dv_valid_directory_stat(&st, 43));
	st.st_mode = S_IFDIR | 0777;
	CHECK(!finch_dv_valid_directory_stat(&st, 42));
	st.st_mode = S_IFDIR | 0755;
	st.st_uid = 501;
	CHECK(!finch_dv_valid_directory_stat(&st, 42));
	st.st_uid = 0;
	st.st_mode = S_IFREG | 0755;
	CHECK(!finch_dv_valid_directory_stat(&st, 42));
}

static void
test_mount_rules(void)
{
	struct statfs fs;
	memset(&fs, 0, sizeof(fs));
	strlcpy(fs.f_fstypename, "apfs", sizeof(fs.f_fstypename));
	strlcpy(fs.f_mntonname, "/private/var/rw", sizeof(fs.f_mntonname));
	strlcpy(fs.f_mntfromname, "/dev/disk2s1", sizeof(fs.f_mntfromname));
	fs.f_flags = MNT_NOSUID | MNT_NODEV | MNT_DONTBROWSE;
	CHECK(finch_dv_valid_mount_stat(&fs, "/dev/disk2s1", "/private/var/rw", false));
	strlcpy(fs.f_mntfromname, "disk2s1", sizeof(fs.f_mntfromname));
	CHECK(finch_dv_valid_mount_stat(&fs, "/dev/disk2s1", "/private/var/rw", false));
	fs.f_flags |= MNT_RDONLY;
	CHECK(finch_dv_valid_mount_stat(&fs, "/dev/disk2s1", "/private/var/rw", true));
	CHECK(!finch_dv_valid_mount_stat(&fs, "/dev/disk2s1", "/private/var/rw", false));
	fs.f_flags &= ~MNT_RDONLY;
	fs.f_flags |= MNT_IGNORE_OWNERSHIP;
	CHECK(!finch_dv_valid_mount_stat(&fs, "/dev/disk2s1", "/private/var/rw", false));
	fs.f_flags &= ~MNT_IGNORE_OWNERSHIP;
	fs.f_flags &= ~MNT_NOSUID;
	CHECK(!finch_dv_valid_mount_stat(&fs, "/dev/disk2s1", "/private/var/rw", false));
	fs.f_flags |= MNT_NOSUID;
	fs.f_flags &= ~MNT_NODEV;
	CHECK(!finch_dv_valid_mount_stat(&fs, "/dev/disk2s1", "/private/var/rw", false));
	fs.f_flags |= MNT_NODEV;
	fs.f_flags &= ~MNT_DONTBROWSE;
	CHECK(!finch_dv_valid_mount_stat(&fs, "/dev/disk2s1", "/private/var/rw", false));
	fs.f_flags |= MNT_DONTBROWSE;
	strlcpy(fs.f_fstypename, "hfs", sizeof(fs.f_fstypename));
	CHECK(!finch_dv_valid_mount_stat(&fs, "/dev/disk2s1", "/private/var/rw", false));
	strlcpy(fs.f_fstypename, "apfs", sizeof(fs.f_fstypename));
	strlcpy(fs.f_mntonname, "/", sizeof(fs.f_mntonname));
	CHECK(!finch_dv_valid_mount_stat(&fs, "/dev/disk2s1", "/private/var/rw", false));
	strlcpy(fs.f_mntonname, "/private/var/rw", sizeof(fs.f_mntonname));
	strlcpy(fs.f_mntfromname, "/dev/disk3s1", sizeof(fs.f_mntfromname));
	CHECK(!finch_dv_valid_mount_stat(&fs, "/dev/disk2s1", "/private/var/rw", false));
}

int
main(void)
{
	test_uuid_lines();
	test_bsd_names();
	test_file_rules();
	test_directory_rules();
	test_mount_rules();
	if (failures) {
		fprintf(stderr, "%u of %u policy checks failed\n", failures, checks);
		return 1;
	}
	printf("%u data-volume policy checks passed\n", checks);
	return 0;
}
