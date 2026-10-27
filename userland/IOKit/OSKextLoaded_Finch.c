/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * OSKextCopyLoadedKextInfo (IOKitUser's kext.subproj, which Finch doesn't
 * build): the loaded kexts as the kernel describes them, a dictionary by
 * bundle identifier. It asks the kernel directly ("Get Loaded Kext Info",
 * libkern/kext_request_keys.h), which any process may ask; the identifiers
 * and info keys, when given, narrow the answer, as Apple's do. zprint names
 * its memory sites with it.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFUnserialize.h>
#include <mach/mach.h>
#include <mach/host_priv.h>

CFDictionaryRef OSKextCopyLoadedKextInfo(CFArrayRef kextIdentifiers, CFArrayRef infoKeys);

CFDictionaryRef
OSKextCopyLoadedKextInfo(CFArrayRef kextIdentifiers, CFArrayRef infoKeys)
{
    CFMutableDictionaryRef arguments = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    if (kextIdentifiers && CFArrayGetCount(kextIdentifiers))
        CFDictionarySetValue(arguments, CFSTR("CFBundleIdentifier"), kextIdentifiers);
    if (infoKeys && CFArrayGetCount(infoKeys))
        CFDictionarySetValue(arguments, CFSTR("Kext Request Info Keys"), infoKeys);
    const void *k[] = { CFSTR("Kext Request Predicate"), CFSTR("Kext Request Arguments") },
        *v[] = { CFSTR("Get Loaded Kext Info"), arguments };
    CFDictionaryRef request = CFDictionaryCreate(NULL, k, v, 2, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    CFRelease(arguments);
    CFDataRef xml = CFPropertyListCreateData(NULL, request, kCFPropertyListXMLFormat_v1_0, 0, NULL);
    CFRelease(request);
    if (!xml)
        return NULL;
    /* The kernel parses it as a C string. */
    CFMutableDataRef terminated = CFDataCreateMutableCopy(NULL, 0, xml);
    CFRelease(xml);
    CFDataAppendBytes(terminated, (const UInt8 *)"", 1);

    vm_offset_t response = 0, log = 0;
    mach_msg_type_number_t responseLength = 0, logLength = 0;
    kern_return_t op = KERN_FAILURE;
    kern_return_t kr = kext_request(mach_host_self(), 0, (vm_offset_t)CFDataGetBytePtr(terminated),
        (mach_msg_type_number_t)CFDataGetLength(terminated), &response, &responseLength, &log, &logLength, &op);
    CFRelease(terminated);
    if (log)
        vm_deallocate(mach_task_self(), log, logLength);
    CFTypeRef plist = NULL;
    if (kr == KERN_SUCCESS && op == KERN_SUCCESS && response && responseLength) {
        /* (the kernel's binary serialization starts with 0xd3) */
        if (responseLength >= 4 && *(const uint32_t *)response == 0x000000d3)
            plist = IOCFUnserializeBinary((const char *)response, responseLength, NULL, 0, NULL);
        else
            plist = IOCFUnserialize((const char *)response, NULL, 0, NULL);
    }
    if (response)
        vm_deallocate(mach_task_self(), response, responseLength);
    if (plist && CFGetTypeID(plist) != CFDictionaryGetTypeID()) {
        CFRelease(plist);
        plist = NULL;
    }
    return plist;
}
