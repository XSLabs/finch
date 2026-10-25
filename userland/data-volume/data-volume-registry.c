/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Find an APFS volume by UUID in the I/O registry, on a VirtIO block device. */
#include "data-volume-policy.h"
#include "data-volume-registry.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <string.h>

#define UUID_PROPERTY "UUID"
#define BSD_NAME_PROPERTY "BSD Name"

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

int
finch_dv_scan_registry(const uuid_t expected, struct finch_dv_volume_match *match)
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
