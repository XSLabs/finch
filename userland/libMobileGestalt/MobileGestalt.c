/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * libMobileGestalt, Finch's: answers to questions about the device, by name, read from
 * the machine itself when they're asked: the model (sysctl), the OS version and build
 * (SystemVersion.plist), the serial number and device ID (the platform expert, through
 * IOKit; the device ID from the device tree's chip IDs), disk usage (statfs), the screen scale and CPU architecture. A question Finch
 * has no answer to gets none (NULL, false, the default), as an unknown one does on a Mac.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/sysctl.h>

#define MG_EXPORT __attribute__((visibility("default")))

MG_EXPORT const CFStringRef kMGQDiskUsageTotalDataAvailable = CFSTR("TotalDataAvailable");
MG_EXPORT const CFStringRef kMGQDiskUsageTotalDataCapacity = CFSTR("TotalDataCapacity");
MG_EXPORT const CFStringRef kMGQDiskUsageTotalDiskCapacity = CFSTR("TotalDiskCapacity");
MG_EXPORT const CFStringRef kMGQDiskUsageTotalSystemAvailable = CFSTR("TotalSystemAvailable");
MG_EXPORT const CFStringRef kMGQDiskUsageTotalSystemCapacity = CFSTR("TotalSystemCapacity");

extern CFDictionaryRef _CFCopySystemVersionDictionary(void);

static CFStringRef
sysctl_string(const char *name)
{
    char buf[256];
    size_t len = sizeof buf;
    if (sysctlbyname(name, buf, &len, NULL, 0) != 0 || !len)
        return NULL;
    buf[sizeof buf - 1] = 0;
    return CFStringCreateWithCString(kCFAllocatorDefault, buf, kCFStringEncodingUTF8);
}

static CFTypeRef
platform_property(CFStringRef key)
{
    io_service_t expert = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"));
    if (!expert)
        return NULL;
    CFTypeRef v = IORegistryEntryCreateCFProperty(expert, key, kCFAllocatorDefault, 0);
    IOObjectRelease(expert);
    return v;
}

/* An Apple silicon Mac's device ID: its chip and unique chip ID (ECID), from the device
   tree; the platform UUID where the device tree has neither. */
static CFStringRef
device_id(void)
{
    io_registry_entry_t chosen = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/chosen");
    CFStringRef id = NULL;
    if (chosen) {
        CFDataRef chip = IORegistryEntryCreateCFProperty(chosen, CFSTR("chip-id"), kCFAllocatorDefault, 0);
        CFDataRef ecid = IORegistryEntryCreateCFProperty(chosen, CFSTR("unique-chip-id"), kCFAllocatorDefault, 0);
        if (chip && ecid && CFGetTypeID(chip) == CFDataGetTypeID() && CFGetTypeID(ecid) == CFDataGetTypeID() &&
            CFDataGetLength(chip) >= 4 && CFDataGetLength(ecid) >= 8) {
            uint32_t c;
            uint64_t e;
            memcpy(&c, CFDataGetBytePtr(chip), 4);
            memcpy(&e, CFDataGetBytePtr(ecid), 8);
            id = CFStringCreateWithFormat(kCFAllocatorDefault, NULL, CFSTR("%08X-%016llX"), c, (unsigned long long)e);
        }
        if (chip)
            CFRelease(chip);
        if (ecid)
            CFRelease(ecid);
        IOObjectRelease(chosen);
    }
    return id ?: (CFStringRef)platform_property(CFSTR("IOPlatformUUID"));
}

static CFTypeRef
version_value(CFStringRef key)
{
    CFDictionaryRef d = _CFCopySystemVersionDictionary();
    if (!d)
        return NULL;
    CFTypeRef v = CFDictionaryGetValue(d, key);
    if (v)
        CFRetain(v);
    CFRelease(d);
    return v;
}

static CFNumberRef
number64(long long v)
{
    return CFNumberCreate(kCFAllocatorDefault, kCFNumberLongLongType, &v);
}

static CFDictionaryRef
disk_usage(void)
{
    struct statfs root, data;
    if (statfs("/", &root) != 0)
        return NULL;
    if (statfs("/System/Volumes/Data", &data) != 0)
        data = root;
    CFStringRef keys[] = {kMGQDiskUsageTotalDiskCapacity, kMGQDiskUsageTotalSystemCapacity, kMGQDiskUsageTotalSystemAvailable,
        kMGQDiskUsageTotalDataCapacity, kMGQDiskUsageTotalDataAvailable};
    CFNumberRef values[] = {number64((long long)root.f_blocks * root.f_bsize), number64((long long)root.f_blocks * root.f_bsize),
        number64((long long)root.f_bavail * root.f_bsize), number64((long long)data.f_blocks * data.f_bsize),
        number64((long long)data.f_bavail * data.f_bsize)};
    CFDictionaryRef d = CFDictionaryCreate(kCFAllocatorDefault, (const void **)keys, (const void **)values, 5,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    for (int i = 0; i < 5; i++)
        CFRelease(values[i]);
    return d;
}

static Boolean
is(CFStringRef key, const char *name)
{
    return CFStringCompare(key, CFStringCreateWithCStringNoCopy(NULL, name, kCFStringEncodingUTF8, kCFAllocatorNull), 0) ==
           kCFCompareEqualTo;
}

MG_EXPORT CFTypeRef
MGCopyAnswer(CFStringRef question)
{
    if (!question)
        return NULL;
    if (is(question, "DeviceClass") || is(question, "DeviceName"))
        return CFRetain(CFSTR("Mac"));
    if (is(question, "ProductType"))
        return sysctl_string("hw.model");
    if (is(question, "ProductVersion"))
        return version_value(CFSTR("ProductVersion"));
    if (is(question, "BuildVersion"))
        return version_value(CFSTR("ProductBuildVersion"));
    if (is(question, "ProductName"))
        return version_value(CFSTR("ProductName"));
    if (is(question, "SerialNumber"))
        return platform_property(CFSTR("IOPlatformSerialNumber"));
    if (is(question, "UniqueDeviceID"))
        return device_id();
    if (is(question, "CPUArchitecture"))
        return CFRetain(CFSTR("arm64e"));
    if (is(question, "main-screen-scale")) {
        float scale = 2.0f;
        return CFNumberCreate(kCFAllocatorDefault, kCFNumberFloat32Type, &scale);
    }
    if (is(question, "DiskUsage"))
        return disk_usage();
    return NULL;
}

MG_EXPORT CFTypeRef
MGCopyAnswerWithError(CFStringRef question, CFDictionaryRef options, int *error)
{
    CFTypeRef v = MGCopyAnswer(question);
    if (error)
        *error = v ? 0 : 1;
    return v;
}

MG_EXPORT Boolean
MGGetBoolAnswer(CFStringRef question)
{
    CFTypeRef v = MGCopyAnswer(question);
    Boolean b = v && CFGetTypeID(v) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)v);
    if (v)
        CFRelease(v);
    return b;
}

MG_EXPORT SInt32
MGGetSInt32Answer(CFStringRef question, SInt32 defaultValue)
{
    CFTypeRef v = MGCopyAnswer(question);
    SInt32 n = defaultValue;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID())
        CFNumberGetValue((CFNumberRef)v, kCFNumberSInt32Type, &n);
    if (v)
        CFRelease(v);
    return n;
}

MG_EXPORT CFStringRef
MGGetStringAnswer(CFStringRef question)
{
    CFTypeRef v = MGCopyAnswer(question);
    if (v && CFGetTypeID(v) != CFStringGetTypeID()) {
        CFRelease(v);
        return NULL;
    }
    return (CFStringRef)v;
}

/* The current device, as an opaque handle, and what it can do (no WAPI on a Mac). */
static const int current_device = 1;

MG_EXPORT const void *
MobileGestalt_get_current_device(void)
{
    return &current_device;
}

MG_EXPORT Boolean
MobileGestalt_get_wapiCapability(const void *device)
{
    return false;
}
