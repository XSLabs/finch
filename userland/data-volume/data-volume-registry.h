/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_DATA_VOLUME_REGISTRY_H
#define FINCH_DATA_VOLUME_REGISTRY_H

#include <stdbool.h>
#include <uuid/uuid.h>

struct finch_dv_volume_match {
	unsigned int count;
	bool invalid;		/* a match not on a VirtIO disk, or without a disk name */
	char bsd_name[32];
};

/* Counts the registered APFS volumes with this UUID; 0 on success. */
int finch_dv_scan_registry(const uuid_t expected, struct finch_dv_volume_match *match);

#endif
