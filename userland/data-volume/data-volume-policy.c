/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "data-volume-policy.h"

#include <string.h>

int
finch_dv_parse_uuid_line(const void *bytes, size_t length, uuid_t result)
{
	const unsigned char *line = bytes;
	char text[37];
	size_t text_length = length;

	if (!bytes || !result || (length != 36 && length != 37))
		return -1;
	if (length == 37) {
		if (line[36] != '\n')
			return -1;
		text_length--;
	}
	for (size_t i = 0; i < text_length; i++) {
		if (line[i] == '\n' || line[i] == '\r' || line[i] == '\0')
			return -1;
	}
	memcpy(text, line, 36);
	text[36] = '\0';
	return uuid_parse(text, result) == 0 ? 0 : -1;
}

bool
finch_dv_valid_bsd_name(const char *name)
{
	const unsigned char *p = (const unsigned char *)name;
	bool has_partition = false;

	if (!p || strncmp((const char *)p, "disk", 4) != 0)
		return false;
	p += 4;
	if (*p < '0' || *p > '9')
		return false;
	while (*p >= '0' && *p <= '9')
		p++;
	while (*p) {
		if (*p++ != 's' || *p < '0' || *p > '9')
			return false;
		has_partition = true;
		while (*p >= '0' && *p <= '9')
			p++;
	}
	return has_partition;
}

bool
finch_dv_valid_config_stat(const struct stat *st)
{
	return st && S_ISREG(st->st_mode) && st->st_uid == 0 && st->st_gid == 0 &&
	    st->st_nlink == 1 && (st->st_mode & (S_IWGRP | S_IWOTH)) == 0;
}

bool
finch_dv_valid_directory_stat(const struct stat *st, dev_t volume_device)
{
	return st && S_ISDIR(st->st_mode) && st->st_uid == 0 && st->st_gid == 0 &&
	    st->st_dev == volume_device && (st->st_mode & (S_IWGRP | S_IWOTH)) == 0;
}

bool
finch_dv_valid_account_stat(const struct stat *st, const char *name,
    dev_t volume_device)
{
	mode_t wanted;

	if (!st || !name || !S_ISREG(st->st_mode) || st->st_uid != 0 ||
	    st->st_gid != 0 || st->st_nlink != 1)
		return false;
	if (st->st_dev != volume_device)
		return false;
	if (strcmp(name, "master.passwd") == 0)
		wanted = 0600;
	else if (strcmp(name, "passwd") == 0 || strcmp(name, "group") == 0)
		wanted = 0644;
	else
		return false;
	return (st->st_mode & 07777) == wanted;
}

static bool
mount_source_matches(const char *actual, const char *device)
{
	const char *basename;

	if (!actual || !device)
		return false;
	if (strcmp(actual, device) == 0)
		return true;
	basename = strrchr(device, '/');
	basename = basename ? basename + 1 : device;
	return strcmp(actual, basename) == 0;
}

bool
finch_dv_valid_mount_stat(const struct statfs *st, const char *device,
    const char *mountpoint, bool expect_readonly)
{
	const long required_flags = MNT_NOSUID | MNT_NODEV | MNT_DONTBROWSE;

	return st && device && mountpoint &&
	    strcmp(st->f_fstypename, "apfs") == 0 &&
	    strcmp(st->f_mntonname, mountpoint) == 0 &&
	    mount_source_matches(st->f_mntfromname, device) &&
	    (((st->f_flags & MNT_RDONLY) != 0) == expect_readonly) &&
	    (st->f_flags & MNT_IGNORE_OWNERSHIP) == 0 &&
	    (st->f_flags & required_flags) == required_flags;
}
