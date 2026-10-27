/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-coresymbolication-test (guest only; tools/vm/test-zprint.sh): Finch's
 * CoreSymbolication finds the running kernel's file and places it where the
 * kernel says it is. Checks the kernel owner (name, path, UUID = kern.uuid),
 * its __TEXT and __TEXT_EXEC where the kernel reports its header and code
 * (OSKextCopyLoadedKextInfo's __kernel__), the header's own symbol there, and a function's symbol found
 * from inside it. Addresses given as arguments are symbolicated too.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <CoreSymbolication/CoreSymbolication.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <uuid/uuid.h>

CFDictionaryRef OSKextCopyLoadedKextInfo(CFArrayRef kextIdentifiers, CFArrayRef infoKeys);

static int failures;

static void check(const char *what, bool ok)
{
	printf("%s: %s\n", what, ok ? "pass" : "FAIL");
	if (!ok)
		failures++;
}

/* A number the kernel reports about itself (OSBundleLoadAddress, OSBundleExecLoadAddress). */
static uint64_t kernel_value(CFStringRef name)
{
	const void *id = CFSTR("__kernel__"), *key = name;
	CFArrayRef ids = CFArrayCreate(NULL, &id, 1, &kCFTypeArrayCallBacks);
	CFArrayRef keys = CFArrayCreate(NULL, &key, 1, &kCFTypeArrayCallBacks);
	CFDictionaryRef info = OSKextCopyLoadedKextInfo(ids, keys);
	uint64_t a = 0;
	CFDictionaryRef k = info ? CFDictionaryGetValue(info, id) : NULL;
	CFNumberRef n = k ? CFDictionaryGetValue(k, key) : NULL;
	if (n)
		CFNumberGetValue(n, kCFNumberSInt64Type, &a);
	return a;
}

int main(int argc, char **argv)
{
	setvbuf(stdout, NULL, _IOLBF, 0);
	CSSymbolicatorRef sym = CSSymbolicatorCreateWithMachKernel();
	check("a kernel symbolicator", !CSIsNull(sym));
	if (CSIsNull(sym))
		return 1;
	uint64_t header = kernel_value(CFSTR("OSBundleLoadAddress"));
	check("the kernel reports its header", header != 0);

	CSSymbolOwnerRef owner = CSSymbolicatorGetSymbolOwnerWithAddressAtTime(sym, header, kCSNow);
	check("the header is in the kernel", !CSIsNull(owner) && !strcmp(CSSymbolOwnerGetName(owner), "kernel"));
	printf("kernel file: %s\n", CSSymbolOwnerGetPath(owner));
	char text[64] = "";
	size_t size = sizeof(text);
	uuid_t running, file;
	sysctlbyname("kern.uuid", text, &size, NULL, 0);
	uuid_parse(text, running);
	memcpy(file, CSSymbolOwnerGetCFUUIDBytes(owner), sizeof(file));
	check("the file is the running kernel", !uuid_compare(running, file));

	__block CSRange textRange = { 0, 0 }, execRange = { 0, 0 };
	size_t segments = CSSymbolOwnerForeachSegment(owner, ^(CSSegmentRef s) {
		if (!strcmp(CSRegionGetName(s), "__TEXT SEGMENT"))
			textRange = CSRegionGetRange(s);
		else if (!strcmp(CSRegionGetName(s), "__TEXT_EXEC SEGMENT"))
			execRange = CSRegionGetRange(s);
	});
	printf("segments: %zu; __TEXT 0x%llx +0x%llx; __TEXT_EXEC 0x%llx +0x%llx\n", segments,
	    textRange.location, textRange.length, execRange.location, execRange.length);
	check("__TEXT is where the kernel's header is", textRange.location == header);
	check("__TEXT_EXEC is where the kernel's code is",
	    execRange.length && execRange.location == kernel_value(CFSTR("OSBundleExecLoadAddress")));

	CSSymbolRef first = CSSymbolicatorGetSymbolWithAddressAtTime(sym, header, kCSNow);
	check("the header's symbol is _mh_execute_header",
	    !CSIsNull(first) && !strcmp(CSSymbolGetMangledName(first), "__mh_execute_header"));

	/* A function: one from the middle of __TEXT_EXEC, found again from inside it. */
	CSSymbolRef fn = CSSymbolicatorGetSymbolWithAddressAtTime(sym, execRange.location + execRange.length / 2, kCSNow);
	CSRange r = CSSymbolGetRange(fn);
	CSSymbolRef again = CSIsNull(fn) ? kCSNull : CSSymbolicatorGetSymbolWithAddressAtTime(sym, r.location + r.length / 2,
	    kCSNow);
	check("a function's symbol, found from inside it", !CSIsNull(again) && !strcmp(CSSymbolGetName(again), CSSymbolGetName(fn)));
	printf("function: %s at 0x%llx +0x%llx\n", CSIsNull(fn) ? "-" : CSSymbolGetName(fn), r.location, r.length);
	check("nothing outside the kernel", CSIsNull(CSSymbolicatorGetSymbolWithAddressAtTime(sym, 0x1000, kCSNow)));

	for (int i = 1; i < argc; i++) {
		mach_vm_address_t a = strtoull(argv[i], NULL, 0);
		CSSymbolRef s = CSSymbolicatorGetSymbolWithAddressAtTime(sym, a, kCSNow);
		printf("0x%llx: %s\n", a, CSIsNull(s) ? "(none)" : CSSymbolGetName(s));
	}
	CSRelease(sym);
	printf("coresymbolication-test: %d failed\n", failures);
	return failures != 0;
}
