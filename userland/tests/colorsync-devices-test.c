/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * ColorSync's device registry: a printer registered with two factory profiles, what
 * ColorSyncDeviceCopyDeviceInfo and ColorSyncIterateDeviceProfiles say of it, a custom
 * profile chosen and taken away, the device profile it gives, and unregistering. Only
 * this test's device is printed (the host's own displays vary). Compared with Apple's.
 */
#include <ColorSync/ColorSync.h>
#include <stdio.h>

static CFUUIDRef device;

static void
show(const char *label, CFTypeRef v)
{
    if (!v) {
        printf("%s: (none)\n", label);
        return;
    }
    if (CFGetTypeID(v) == CFURLGetTypeID())
        v = CFURLGetString(v);
    if (CFGetTypeID(v) == CFBooleanGetTypeID()) {
        printf("%s: %d\n", label, CFBooleanGetValue(v));
        return;
    }
    if (CFGetTypeID(v) == CFUUIDGetTypeID()) {
        printf("%s: %s\n", label, CFEqual(v, device) ? "this device" : "another");
        return;
    }
    char buf[512];
    if (CFGetTypeID(v) == CFStringGetTypeID() && CFStringGetCString(v, buf, sizeof buf, kCFStringEncodingUTF8))
        printf("%s: %s\n", label, buf);
    else
        printf("%s: (%s)\n", label, CFGetTypeID(v) == CFDictionaryGetTypeID() ? "dictionary" : "other");
}

static bool
each(CFDictionaryRef info, void *userInfo)
{
    if (!CFEqual(CFDictionaryGetValue(info, kColorSyncDeviceID), device))
        return true;
    printf("profile:\n");
    CFStringRef keys[] = {kColorSyncDeviceClass, kColorSyncDeviceDescription, kColorSyncDeviceModeDescription,
                          kColorSyncDeviceProfileID, kColorSyncDeviceProfileURL, kColorSyncDeviceProfileIsFactory,
                          kColorSyncDeviceProfileIsDefault, kColorSyncDeviceProfileIsCurrent, kColorSyncProfileUserScope,
                          kColorSyncProfileHostScope};
    for (size_t i = 0; i < sizeof keys / sizeof *keys; i++) {
        char k[64];
        CFStringGetCString(keys[i], k, sizeof k, kCFStringEncodingUTF8);
        char label[80];
        snprintf(label, sizeof label, "  %s", k);
        show(label, CFDictionaryGetValue(info, keys[i]));
    }
    (*(int *)userInfo)++;
    return true;
}

static CFDictionaryRef
dict(const void **k, const void **v, CFIndex n)
{
    return CFDictionaryCreate(NULL, k, v, n, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}

static void
info(void)
{
    CFDictionaryRef d = ColorSyncDeviceCopyDeviceInfo(kColorSyncPrinterDeviceClass, device);
    printf("info: %s\n", d ? "yes" : "none");
    if (!d)
        return;
    show("  class", CFDictionaryGetValue(d, kColorSyncDeviceClass));
    show("  id", CFDictionaryGetValue(d, kColorSyncDeviceID));
    show("  description", CFDictionaryGetValue(d, kColorSyncDeviceDescription));
    CFDictionaryRef f = CFDictionaryGetValue(d, kColorSyncFactoryProfiles);
    show("  default id", f ? CFDictionaryGetValue(f, kColorSyncDeviceDefaultProfileID) : NULL);
    CFDictionaryRef plain = f ? CFDictionaryGetValue(f, CFSTR("Plain")) : NULL;
    show("  Plain mode", plain ? CFDictionaryGetValue(plain, kColorSyncDeviceModeDescription) : NULL);
    show("  Plain URL", plain ? CFDictionaryGetValue(plain, kColorSyncDeviceProfileURL) : NULL);
    CFDictionaryRef c = CFDictionaryGetValue(d, kColorSyncCustomProfiles);
    show("  custom Plain", c ? CFDictionaryGetValue(c, CFSTR("Plain")) : NULL);
    CFRelease(d);
}

static void
iterate(void)
{
    int n = 0;
    ColorSyncIterateDeviceProfiles(each, &n);
    printf("profiles: %d\n", n);
}

int
main(void)
{
    printf("colorsync devices\n");
    device = CFUUIDCreateFromString(NULL, CFSTR("6A1D3F2E-4B5C-4D6E-8F70-9A8B7C6D5E4F"));
    CFURLRef srgb = CFURLCreateWithFileSystemPath(NULL, CFSTR("/System/Library/ColorSync/Profiles/sRGB Profile.icc"),
                                                  kCFURLPOSIXPathStyle, false);
    CFURLRef gray = CFURLCreateWithFileSystemPath(NULL, CFSTR("/System/Library/ColorSync/Profiles/Generic Gray Profile.icc"),
                                                  kCFURLPOSIXPathStyle, false);
    CFURLRef rgb = CFURLCreateWithFileSystemPath(NULL, CFSTR("/System/Library/ColorSync/Profiles/Generic RGB Profile.icc"),
                                                 kCFURLPOSIXPathStyle, false);
    const void *dk[] = {CFSTR("en_US")};
    const void *dv1[] = {CFSTR("Plain Paper")}, *dv2[] = {CFSTR("Gray Paper")}, *dv3[] = {CFSTR("Test Printer")};
    CFDictionaryRef m1 = dict(dk, dv1, 1), m2 = dict(dk, dv2, 1), names = dict(dk, dv3, 1);
    const void *pk[] = {kColorSyncDeviceProfileURL, kColorSyncDeviceModeDescriptions};
    const void *p1[] = {srgb, m1}, *p2[] = {gray, m2};
    CFDictionaryRef plain = dict(pk, p1, 2), grayMode = dict(pk, p2, 2);
    const void *fk[] = {CFSTR("Plain"), CFSTR("Gray"), kColorSyncDeviceDefaultProfileID};
    const void *fv[] = {plain, grayMode, CFSTR("Plain")};
    CFDictionaryRef factory = dict(fk, fv, 3);
    const void *rk[] = {kColorSyncDeviceDescriptions, kColorSyncFactoryProfiles, kColorSyncDeviceUserScope, kColorSyncDeviceHostScope};
    const void *rv[] = {names, factory, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost};
    CFDictionaryRef reg = dict(rk, rv, 4);

    printf("unknown device's info: %s\n", ColorSyncDeviceCopyDeviceInfo(kColorSyncPrinterDeviceClass, device) ? "yes" : "none");
    printf("register: %d\n", ColorSyncRegisterDevice(kColorSyncPrinterDeviceClass, device, reg));
    info();
    iterate();

    const void *ck[] = {CFSTR("Plain"), kColorSyncProfileUserScope, kColorSyncProfileHostScope};
    const void *cv[] = {rgb, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost};
    CFDictionaryRef custom = dict(ck, cv, 3);
    printf("set custom: %d\n", ColorSyncDeviceSetCustomProfiles(kColorSyncPrinterDeviceClass, device, custom));
    info();
    iterate();
    ColorSyncProfileRef p = ColorSyncProfileCreateDeviceProfile(kColorSyncPrinterDeviceClass, device, CFSTR("Plain"));
    CFStringRef desc = p ? ColorSyncProfileCopyDescriptionString(p) : NULL;
    show("device profile (Plain)", desc);
    p = ColorSyncProfileCreateDeviceProfile(kColorSyncPrinterDeviceClass, device, CFSTR("Gray"));
    desc = p ? ColorSyncProfileCopyDescriptionString(p) : NULL;
    show("device profile (Gray)", desc);

    const void *nk[] = {CFSTR("Plain"), kColorSyncProfileUserScope, kColorSyncProfileHostScope};
    const void *nv[] = {kCFNull, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost};
    CFDictionaryRef none = dict(nk, nv, 3);
    printf("remove custom: %d\n", ColorSyncDeviceSetCustomProfiles(kColorSyncPrinterDeviceClass, device, none));
    info();

    printf("unregister: %d\n", ColorSyncUnregisterDevice(kColorSyncPrinterDeviceClass, device));
    info();
    iterate();
    return 0;
}
