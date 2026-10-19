/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_DATA_VOLUME_POLICY_H
#define FINCH_DATA_VOLUME_POLICY_H

#include <stdbool.h>
#include <stddef.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <uuid/uuid.h>

int finch_dv_parse_uuid_line(const void *bytes, size_t length, uuid_t result);
bool finch_dv_valid_bsd_name(const char *name);
bool finch_dv_valid_config_stat(const struct stat *st);
bool finch_dv_valid_directory_stat(const struct stat *st, dev_t volume_device);
bool finch_dv_valid_account_stat(const struct stat *st, const char *name,
    dev_t volume_device);
bool finch_dv_valid_mount_stat(const struct statfs *st, const char *device,
    const char *mountpoint, bool expect_readonly);

#endif
