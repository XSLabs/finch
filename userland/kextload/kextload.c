/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * kextload: start a kext that is already in the boot kernel collection. On
 * macOS kextload asks kernelmanagerd, which Finch doesn't have; Finch's asks
 * the kernel directly ("LoadFromKC", libkern/kext_request_keys.h), which
 * starts the kext and sends its personalities for matching. mount_msdos and
 * the other filesystem helpers run it to load their filesystem.
 *
 *   kextload [-q] kext-path | -b bundle-id ...
 *   kextload -l     list the boot collection's kexts: started, bundle id, path
 *
 * A path names the kext by its OSBundlePath in the collection
 * (/System/Library/Extensions/msdosfs.kext), or by its own Info.plist if it is
 * there. Root only; signed with com.apple.private.security.only-bootkc-management.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFUnserialize.h>
#include <mach/mach.h>
#include <mach/host_priv.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define PREDICATE "Kext Request Predicate"
#define ARGUMENTS "Kext Request Arguments"

static bool quiet;

/* Send a request; the response (a property list) or NULL. */
static CFPropertyListRef request(CFDictionaryRef dict, kern_return_t *opResult)
{
	mach_port_t host = MACH_PORT_NULL;
	*opResult = KERN_FAILURE;
	if (host_get_host_priv_port(mach_host_self(), &host) != KERN_SUCCESS || host == MACH_PORT_NULL) {
		fprintf(stderr, "kextload: must be run as root\n");
		return NULL;
	}
	CFDataRef data = CFPropertyListCreateData(NULL, dict, kCFPropertyListXMLFormat_v1_0, 0, NULL);
	if (!data)
		return NULL;
	/* The kernel parses it as a C string. */
	CFMutableDataRef terminated = CFDataCreateMutableCopy(NULL, 0, data);
	CFRelease(data);
	CFDataAppendBytes(terminated, (const UInt8 *)"", 1);
	vm_offset_t response = 0, log = 0;
	mach_msg_type_number_t responseLength = 0, logLength = 0;
	kern_return_t kr = kext_request(host, 0, (vm_offset_t)CFDataGetBytePtr(terminated),
	    (mach_msg_type_number_t)CFDataGetLength(terminated), &response, &responseLength, &log, &logLength,
	    opResult);
	CFRelease(terminated);
	if (log)
		vm_deallocate(mach_task_self(), log, logLength);
	if (kr != KERN_SUCCESS) {
		fprintf(stderr, "kextload: kext_request: %s\n", mach_error_string(kr));
		*opResult = kr;
		return NULL;
	}
	/* The kernel's XML (OSSerialize: IDs, sized integers), as IOKit reads it. */
	CFPropertyListRef plist = NULL;
	if (response && responseLength) {
		/* (or its binary form, which starts with 0xd3) */
		if (responseLength >= 4 && *(const uint32_t *)response == 0x000000d3)
			plist = IOCFUnserializeBinary((const char *)response, responseLength, NULL, 0, NULL);
		else
			plist = IOCFUnserialize((const char *)response, NULL, 0, NULL);
		vm_deallocate(mach_task_self(), response, responseLength);
	}
	return plist;
}

static CFDictionaryRef makeRequest(const char *predicate, CFDictionaryRef arguments)
{
	CFStringRef p = CFStringCreateWithCString(NULL, predicate, kCFStringEncodingUTF8);
	CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
	    &kCFTypeDictionaryValueCallBacks);
	CFDictionarySetValue(d, CFSTR(PREDICATE), p);
	if (arguments)
		CFDictionarySetValue(d, CFSTR(ARGUMENTS), arguments);
	CFRelease(p);
	return d;
}

/* The boot collection's kexts, as the kernel describes them. */
static CFArrayRef copyCollection(void)
{
	/* Only what's needed (the full records carry each kext's Mach-O headers). */
	const void *keys[] = { kCFBundleIdentifierKey, CFSTR("OSBundlePath"), CFSTR("OSBundleStarted") };
	CFArrayRef infoKeys = CFArrayCreate(NULL, keys, 3, &kCFTypeArrayCallBacks);
	const void *k[] = { CFSTR("Collection Type"), CFSTR("Kext Request Info Keys") },
	    *v[] = { CFSTR("Primary"), infoKeys };
	CFDictionaryRef args = CFDictionaryCreate(NULL, k, v, 2, &kCFTypeDictionaryKeyCallBacks,
	    &kCFTypeDictionaryValueCallBacks);
	CFRelease(infoKeys);
	CFDictionaryRef req = makeRequest("Get Kexts in Collection", args);
	CFRelease(args);
	kern_return_t op;
	CFPropertyListRef reply = request(req, &op);
	CFRelease(req);
	/* A dictionary by bundle id: its records. */
	CFArrayRef kexts = NULL;
	if (reply && CFGetTypeID(reply) == CFDictionaryGetTypeID()) {
		CFIndex n = CFDictionaryGetCount(reply);
		const void **values = calloc((size_t)(n ? n : 1), sizeof(*values));
		CFDictionaryGetKeysAndValues(reply, NULL, values);
		kexts = CFArrayCreate(NULL, values, n, &kCFTypeArrayCallBacks);
		free(values);
	} else if (reply && CFGetTypeID(reply) == CFArrayGetTypeID())
		kexts = CFRetain(reply);
	if (reply)
		CFRelease(reply);
	if (!kexts)
		fprintf(stderr, "kextload: the kernel didn't list its collection (0x%x)\n", op);
	return kexts;
}

static void printString(CFTypeRef s)
{
	char text[PATH_MAX] = "-";
	if (s && CFGetTypeID(s) == CFStringGetTypeID())
		CFStringGetCString(s, text, sizeof(text), kCFStringEncodingUTF8);
	printf("%s", text);
}

static int list(void)
{
	CFArrayRef kexts = copyCollection();
	if (!kexts)
		return 1;
	for (CFIndex i = 0; i < CFArrayGetCount(kexts); i++) {
		CFDictionaryRef kext = CFArrayGetValueAtIndex(kexts, i);
		if (CFGetTypeID(kext) != CFDictionaryGetTypeID())
			continue;
		printf("%s ", CFDictionaryGetValue(kext, CFSTR("OSBundleStarted")) == kCFBooleanTrue ? "started" : "-");
		printString(CFDictionaryGetValue(kext, kCFBundleIdentifierKey));
		printf(" ");
		printString(CFDictionaryGetValue(kext, CFSTR("OSBundlePath")));
		printf("\n");
	}
	CFRelease(kexts);
	return 0;
}

/* The bundle id of the kext at this path: its Info.plist, or the collection's record. */
static CFStringRef identifierForPath(const char *path)
{
	char plistPath[PATH_MAX];
	snprintf(plistPath, sizeof(plistPath), "%s/Contents/Info.plist", path);
	CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)plistPath, (CFIndex)strlen(plistPath),
	    false);
	CFReadStreamRef stream = url ? CFReadStreamCreateWithFile(NULL, url) : NULL;
	CFStringRef identifier = NULL;
	if (stream && CFReadStreamOpen(stream)) {
		CFPropertyListRef info = CFPropertyListCreateWithStream(NULL, stream, 0, kCFPropertyListImmutable, NULL,
		    NULL);
		CFReadStreamClose(stream);
		if (info && CFGetTypeID(info) == CFDictionaryGetTypeID()) {
			CFTypeRef value = CFDictionaryGetValue(info, kCFBundleIdentifierKey);
			if (value && CFGetTypeID(value) == CFStringGetTypeID())
				identifier = CFRetain(value);
		}
		if (info)
			CFRelease(info);
	}
	if (stream)
		CFRelease(stream);
	if (url)
		CFRelease(url);
	if (identifier)
		return identifier;

	/* Not on disk: the kexts in the boot collection, by OSBundlePath. */
	CFArrayRef kexts = copyCollection();
	CFStringRef wanted = CFStringCreateWithCString(NULL, path, kCFStringEncodingUTF8);
	if (kexts && CFGetTypeID(kexts) == CFArrayGetTypeID()) {
		for (CFIndex i = 0; i < CFArrayGetCount(kexts) && !identifier; i++) {
			CFDictionaryRef kext = CFArrayGetValueAtIndex(kexts, i);
			if (CFGetTypeID(kext) != CFDictionaryGetTypeID())
				continue;
			CFTypeRef bundlePath = CFDictionaryGetValue(kext, CFSTR("OSBundlePath"));
			CFTypeRef id = CFDictionaryGetValue(kext, kCFBundleIdentifierKey);
			/* The collection records where it was linked from (a KDK's
			   /System/Library/Extensions/NAME.kext): the same path, or one
			   ending in it. */
			if (bundlePath && id && CFGetTypeID(bundlePath) == CFStringGetTypeID() &&
			    CFGetTypeID(id) == CFStringGetTypeID() &&
			    (CFEqual(bundlePath, wanted) || CFStringHasSuffix(bundlePath, wanted)))
				identifier = CFRetain(id);
		}
	}
	if (kexts)
		CFRelease(kexts);
	CFRelease(wanted);
	return identifier;
}

static int load(CFStringRef identifier)
{
	const void *k[] = { kCFBundleIdentifierKey }, *v[] = { identifier };
	CFDictionaryRef args = CFDictionaryCreate(NULL, k, v, 1, &kCFTypeDictionaryKeyCallBacks,
	    &kCFTypeDictionaryValueCallBacks);
	CFDictionaryRef req = makeRequest("LoadFromKC", args);
	CFRelease(args);
	kern_return_t op;
	CFPropertyListRef response = request(req, &op);
	CFRelease(req);
	if (response)
		CFRelease(response);
	char name[256];
	CFStringGetCString(identifier, name, sizeof(name), kCFStringEncodingUTF8);
	if (op != KERN_SUCCESS) {
		fprintf(stderr, "kextload: %s can't be loaded (0x%x)\n", name, op);
		return 1;
	}
	if (!quiet)
		printf("%s loaded\n", name);
	return 0;
}

int main(int argc, char **argv)
{
	int ch, status = 0;
	CFMutableArrayRef identifiers = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	while ((ch = getopt(argc, argv, "qlb:")) != -1) {
		if (ch == 'l')
			return list();
		if (ch == 'q')
			quiet = true;
		else if (ch == 'b') {
			CFStringRef id = CFStringCreateWithCString(NULL, optarg, kCFStringEncodingUTF8);
			CFArrayAppendValue(identifiers, id);
			CFRelease(id);
		} else {
			fprintf(stderr, "usage: kextload [-q] kext-path | -b bundle-id ...\n");
			return 2;
		}
	}
	for (int i = optind; i < argc; i++) {
		CFStringRef id = identifierForPath(argv[i]);
		if (!id) {
			fprintf(stderr, "kextload: %s isn't in the kernel collection\n", argv[i]);
			status = 1;
			continue;
		}
		CFArrayAppendValue(identifiers, id);
		CFRelease(id);
	}
	if (CFArrayGetCount(identifiers) == 0 && status == 0) {
		fprintf(stderr, "usage: kextload [-q] kext-path | -b bundle-id ...\n");
		return 2;
	}
	for (CFIndex i = 0; i < CFArrayGetCount(identifiers); i++)
		status |= load(CFArrayGetValueAtIndex(identifiers, i));
	CFRelease(identifiers);
	return status;
}
