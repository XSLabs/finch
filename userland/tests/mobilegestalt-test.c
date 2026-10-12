/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * libMobileGestalt's answers on a Mac: device class, product, versions, architecture,
 * screen scale, disk usage, the device ID's shape (never its value), and the typed
 * getters; compared with Apple's.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>

extern CFTypeRef MGCopyAnswer(CFStringRef);
extern Boolean MGGetBoolAnswer(CFStringRef);
extern CFStringRef MGGetStringAnswer(CFStringRef);
extern const void *MobileGestalt_get_current_device(void);
extern Boolean MobileGestalt_get_wapiCapability(const void *);
extern const CFStringRef kMGQDiskUsageTotalDiskCapacity;

int
main(void)
{
    printf("MobileGestalt\n");
    const char *keys[] = {"DeviceClass", "ProductType", "ProductVersion", "BuildVersion", "ProductName", "CPUArchitecture",
        "main-screen-scale", "NoSuchKey"};
    for (int i = 0; i < 8; i++) {
        CFStringRef key = CFStringCreateWithCString(NULL, keys[i], kCFStringEncodingUTF8);
        CFTypeRef v = MGCopyAnswer(key);
        char b[200] = "(null)";
        if (v && CFGetTypeID(v) == CFStringGetTypeID())
            CFStringGetCString(v, b, sizeof b, kCFStringEncodingUTF8);
        else if (v && CFGetTypeID(v) == CFNumberGetTypeID()) {
            double x;
            CFNumberGetValue(v, kCFNumberDoubleType, &x);
            snprintf(b, sizeof b, "%g", x);
        }
        printf("%s: %s\n", keys[i], b);
        CFRelease(key);
    }
    CFStringRef id = MGCopyAnswer(CFSTR("UniqueDeviceID"));
    printf("device ID: length %ld, dash at 8 %d\n", id ? CFStringGetLength(id) : 0L, id ? CFStringGetCharacterAtIndex(id, 8) == '-' : 0);
    CFStringRef serial = MGCopyAnswer(CFSTR("SerialNumber"));
    printf("serial present: %d\n", serial != NULL);
    CFDictionaryRef usage = MGCopyAnswer(CFSTR("DiskUsage"));
    printf("disk usage has capacity: %d\n",
        usage && CFGetTypeID(usage) == CFDictionaryGetTypeID() && CFDictionaryGetValue(usage, kMGQDiskUsageTotalDiskCapacity) != NULL);
    /* (Apple's MGGetSInt32Answer aborts on a key it doesn't know) */
    CFStringRef deviceClass = MGGetStringAnswer(CFSTR("DeviceClass"));
    char cls[32] = "";
    if (deviceClass)
        CFStringGetCString(deviceClass, cls, sizeof cls, kCFStringEncodingUTF8);
    printf("getters: unknown bool %d, unknown string %s, device class %s\n", MGGetBoolAnswer(CFSTR("NoSuchKey")),
        MGGetStringAnswer(CFSTR("NoSuchKey")) ? "set" : "null", cls);
    const void *device = MobileGestalt_get_current_device();
    printf("device: %d wapi %d\n", device != NULL, MobileGestalt_get_wapiCapability(device));
    return 0;
}
