/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * ColorSync's devices: what's registered (displays, printers, scanners, cameras), each
 * with its factory profiles (one per mode, one the default) and any custom profiles the
 * user chose in their place. The registry is the com.apple.ColorSync.Devices
 * preferences, so every process sees one; the main display is always there, with sRGB
 * as its factory profile, until something registers it otherwise. Profile URLs are kept
 * as strings (a property list holds no URLs) and handed back as URLs.
 */
#include "ColorSyncInternal.h"
#include <dlfcn.h>

static const CFStringRef kDomain = CFSTR("com.apple.ColorSync.Devices");
static const CFStringRef kDevicesKey = CFSTR("Devices");

CFUUIDRef CGDisplayCreateUUIDFromDisplayID(uint32_t displayID);

/* Devices by "class UUID": their registration, with custom profiles under CustomProfiles. */
static CFMutableDictionaryRef
copy_registry(void)
{
    CFPreferencesAppSynchronize(kDomain);
    CFPropertyListRef saved = CFPreferencesCopyAppValue(kDevicesKey, kDomain);
    CFMutableDictionaryRef r = saved && CFGetTypeID(saved) == CFDictionaryGetTypeID()
                                   ? CFDictionaryCreateMutableCopy(NULL, 0, (CFDictionaryRef)saved)
                                   : CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                               &kCFTypeDictionaryValueCallBacks);
    if (saved)
        CFRelease(saved);
    return r;
}

static void
save_registry(CFDictionaryRef r)
{
    CFPreferencesSetAppValue(kDevicesKey, r, kDomain);
    CFPreferencesAppSynchronize(kDomain);
}

static CFStringRef
device_key(CFStringRef deviceClass, CFUUIDRef deviceID)
{
    CFStringRef u = CFUUIDCreateString(NULL, deviceID);
    CFStringRef k = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@ %@"), deviceClass, u);
    CFRelease(u);
    return k;
}

static void
post(CFStringRef name, CFStringRef deviceClass, CFUUIDRef deviceID)
{
    CFNotificationCenterRef c = CFNotificationCenterGetDistributedCenter();
    if (!c)
        return;
    const void *keys[] = {kColorSyncDeviceClass, kColorSyncDeviceID};
    CFStringRef u = CFUUIDCreateString(NULL, deviceID);
    const void *values[] = {deviceClass, u};
    CFDictionaryRef info = CFDictionaryCreate(NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks,
                                              &kCFTypeDictionaryValueCallBacks);
    CFNotificationCenterPostNotification(c, name, NULL, info, true);
    CFRelease(info);
    CFRelease(u);
}

/* A localized description dictionary's string (en_US, else any). */
static CFStringRef
pick_description(CFTypeRef d)
{
    if (!d)
        return NULL;
    if (CFGetTypeID(d) == CFStringGetTypeID())
        return (CFStringRef)d;
    if (CFGetTypeID(d) != CFDictionaryGetTypeID() || !CFDictionaryGetCount((CFDictionaryRef)d))
        return NULL;
    CFStringRef s = CFDictionaryGetValue((CFDictionaryRef)d, CFSTR("en_US"));
    if (!s)
        s = CFDictionaryGetValue((CFDictionaryRef)d, CFSTR("en"));
    if (!s) {
        const void *v;
        CFDictionaryGetKeysAndValues((CFDictionaryRef)d, NULL, &v);
        s = v;
    }
    return s && CFGetTypeID(s) == CFStringGetTypeID() ? s : NULL;
}

/* A URL (or a path or URL string) as the string the registry keeps. */
static CFStringRef
url_string(CFTypeRef u)
{
    if (!u)
        return NULL;
    CFURLRef url = NULL;
    if (CFGetTypeID(u) == CFURLGetTypeID())
        url = CFURLCopyAbsoluteURL((CFURLRef)u);
    else if (CFGetTypeID(u) == CFStringGetTypeID() && CFStringHasPrefix((CFStringRef)u, CFSTR("/")))
        url = CFURLCreateWithFileSystemPath(NULL, (CFStringRef)u, kCFURLPOSIXPathStyle, false);
    else if (CFGetTypeID(u) == CFStringGetTypeID())
        return CFStringCreateCopy(NULL, (CFStringRef)u);
    if (!url)
        return NULL;
    CFStringRef s = CFStringCreateCopy(NULL, CFURLGetString(url));
    CFRelease(url);
    return s;
}

static CFURLRef
string_url(CFTypeRef s)
{
    return s && CFGetTypeID(s) == CFStringGetTypeID() ? CFURLCreateWithString(NULL, (CFStringRef)s, NULL) : NULL;
}

/* The main display: always known, sRGB its factory profile. */
static uint32_t
main_display_id(void)
{
    uint32_t (*f)(void) = (uint32_t (*)(void))dlsym(RTLD_DEFAULT, "CGMainDisplayID");
    return f ? f() : 1;
}

static CFDictionaryRef
main_display_registration(void)
{
    CFURLRef url = CFURLCreateWithFileSystemPath(NULL, CFSTR("/System/Library/ColorSync/Profiles/sRGB Profile.icc"),
                                                 kCFURLPOSIXPathStyle, false);
    CFStringRef s = CFStringCreateCopy(NULL, CFURLGetString(url));
    CFRelease(url);
    const void *mk[] = {kColorSyncDeviceProfileURL, kColorSyncDeviceModeDescription};
    const void *mv[] = {s, CFSTR("Default")};
    CFDictionaryRef mode = CFDictionaryCreate(NULL, mk, mv, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    const void *fk[] = {kColorSyncDeviceDefaultProfileID, CFSTR("Default")};
    const void *fv[] = {CFSTR("Default"), mode};
    CFDictionaryRef factory = CFDictionaryCreate(NULL, fk, fv, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    const void *k[] = {kColorSyncDeviceDescription, kColorSyncFactoryProfiles, kColorSyncDeviceUserScope, kColorSyncDeviceHostScope};
    const void *v[] = {CFSTR("Display"), factory, kCFPreferencesAnyUser, kCFPreferencesCurrentHost};
    CFDictionaryRef d = CFDictionaryCreate(NULL, k, v, 4, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(s);
    CFRelease(mode);
    CFRelease(factory);
    return d;
}

/* Every device's stored record (the main display's added when it isn't registered). */
static CFMutableDictionaryRef
copy_devices(void)
{
    CFMutableDictionaryRef r = copy_registry();
    CFUUIDRef display = CGDisplayCreateUUIDFromDisplayID(main_display_id());
    CFStringRef key = device_key(kColorSyncDisplayDeviceClass, display);
    if (!CFDictionaryContainsKey(r, key)) {
        CFDictionaryRef reg = main_display_registration();
        CFMutableDictionaryRef rec = CFDictionaryCreateMutableCopy(NULL, 0, reg);
        CFStringRef u = CFUUIDCreateString(NULL, display);
        CFDictionarySetValue(rec, kColorSyncDeviceClass, kColorSyncDisplayDeviceClass);
        CFDictionarySetValue(rec, kColorSyncDeviceID, u);
        CFDictionarySetValue(r, key, rec);
        CFRelease(u);
        CFRelease(rec);
        CFRelease(reg);
    }
    CFRelease(key);
    CFRelease(display);
    return r;
}

bool
ColorSyncRegisterDevice(CFStringRef deviceClass, CFUUIDRef deviceID, CFDictionaryRef deviceInfo)
{
    if (!deviceClass || !deviceID || !deviceInfo)
        return false;
    CFDictionaryRef factory = CFDictionaryGetValue(deviceInfo, kColorSyncFactoryProfiles);
    if (!factory || CFGetTypeID(factory) != CFDictionaryGetTypeID())
        return false;
    CFMutableDictionaryRef rec = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFStringRef u = CFUUIDCreateString(NULL, deviceID);
    CFDictionarySetValue(rec, kColorSyncDeviceClass, deviceClass);
    CFDictionarySetValue(rec, kColorSyncDeviceID, u);
    CFRelease(u);
    CFStringRef desc = pick_description(CFDictionaryGetValue(deviceInfo, kColorSyncDeviceDescriptions));
    CFDictionarySetValue(rec, kColorSyncDeviceDescription, desc ? desc : CFSTR(""));
    CFTypeRef user = CFDictionaryGetValue(deviceInfo, kColorSyncDeviceUserScope);
    CFTypeRef host = CFDictionaryGetValue(deviceInfo, kColorSyncDeviceHostScope);
    CFDictionarySetValue(rec, kColorSyncDeviceUserScope, user ? user : kCFPreferencesAnyUser);
    CFDictionarySetValue(rec, kColorSyncDeviceHostScope, host ? host : kCFPreferencesCurrentHost);
    /* the factory profiles: each mode's URL and description, and the default's ID */
    CFMutableDictionaryRef modes = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFIndex n = CFDictionaryGetCount(factory);
    const void **keys = malloc(sizeof(void *) * (size_t)(n ? n : 1)), **values = malloc(sizeof(void *) * (size_t)(n ? n : 1));
    CFDictionaryGetKeysAndValues(factory, keys, values);
    for (CFIndex i = 0; i < n; i++) {
        if (CFEqual(keys[i], kColorSyncDeviceDefaultProfileID)) {
            CFDictionarySetValue(modes, keys[i], values[i]);
            continue;
        }
        if (CFGetTypeID(values[i]) != CFDictionaryGetTypeID())
            continue;
        CFStringRef url = url_string(CFDictionaryGetValue(values[i], kColorSyncDeviceProfileURL));
        CFStringRef mode = pick_description(CFDictionaryGetValue(values[i], kColorSyncDeviceModeDescriptions));
        if (!mode)
            mode = pick_description(CFDictionaryGetValue(values[i], kColorSyncDeviceModeDescription));
        CFMutableDictionaryRef m = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        if (url)
            CFDictionarySetValue(m, kColorSyncDeviceProfileURL, url);
        CFDictionarySetValue(m, kColorSyncDeviceModeDescription, mode ? mode : CFSTR(""));
        CFDictionarySetValue(modes, keys[i], m);
        CFRelease(m);
        if (url)
            CFRelease(url);
    }
    free(keys);
    free(values);
    CFDictionarySetValue(rec, kColorSyncFactoryProfiles, modes);
    CFRelease(modes);
    CFMutableDictionaryRef r = copy_registry();
    CFStringRef key = device_key(deviceClass, deviceID);
    /* re-registering keeps the user's choices */
    CFDictionaryRef old = CFDictionaryGetValue(r, key);
    CFTypeRef custom = old ? CFDictionaryGetValue(old, kColorSyncCustomProfiles) : NULL;
    if (custom)
        CFDictionarySetValue(rec, kColorSyncCustomProfiles, custom);
    CFDictionarySetValue(r, key, rec);
    save_registry(r);
    CFRelease(key);
    CFRelease(r);
    CFRelease(rec);
    post(kColorSyncDeviceRegisteredNotification, deviceClass, deviceID);
    return true;
}

bool
ColorSyncUnregisterDevice(CFStringRef deviceClass, CFUUIDRef deviceID)
{
    if (!deviceClass || !deviceID)
        return false;
    CFMutableDictionaryRef r = copy_registry();
    CFStringRef key = device_key(deviceClass, deviceID);
    bool had = CFDictionaryContainsKey(r, key);
    if (had) {
        CFDictionaryRemoveValue(r, key);
        save_registry(r);
        post(kColorSyncDeviceUnregisteredNotification, deviceClass, deviceID);
    }
    CFRelease(key);
    CFRelease(r);
    return had;
}

/* profileInfo: profile IDs to URLs (kCFNull takes a custom profile away), and scopes. */
bool
ColorSyncDeviceSetCustomProfiles(CFStringRef deviceClass, CFUUIDRef deviceID, CFDictionaryRef profileInfo)
{
    if (!deviceClass || !deviceID || !profileInfo)
        return false;
    CFMutableDictionaryRef devices = copy_devices();
    CFStringRef key = device_key(deviceClass, deviceID);
    CFDictionaryRef rec = CFDictionaryGetValue(devices, key);
    if (!rec) {
        CFRelease(key);
        CFRelease(devices);
        return false;
    }
    CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(NULL, 0, rec);
    CFDictionaryRef had = CFDictionaryGetValue(rec, kColorSyncCustomProfiles);
    CFMutableDictionaryRef custom = had ? CFDictionaryCreateMutableCopy(NULL, 0, had)
                                        : CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                                    &kCFTypeDictionaryValueCallBacks);
    CFIndex n = CFDictionaryGetCount(profileInfo);
    const void **keys = malloc(sizeof(void *) * (size_t)(n ? n : 1)), **values = malloc(sizeof(void *) * (size_t)(n ? n : 1));
    CFDictionaryGetKeysAndValues(profileInfo, keys, values);
    for (CFIndex i = 0; i < n; i++) {
        if (CFEqual(keys[i], kColorSyncProfileUserScope) || CFEqual(keys[i], kColorSyncProfileHostScope)) {
            CFDictionarySetValue(m, keys[i], values[i]);  /* the custom profiles' scope */
            continue;
        }
        if (values[i] == kCFNull) {
            CFDictionaryRemoveValue(custom, keys[i]);
            continue;
        }
        CFStringRef url = url_string(values[i]);
        if (url) {
            CFDictionarySetValue(custom, keys[i], url);
            CFRelease(url);
        }
    }
    free(keys);
    free(values);
    CFDictionarySetValue(m, kColorSyncCustomProfiles, custom);
    CFRelease(custom);
    CFMutableDictionaryRef r = copy_registry();
    CFDictionarySetValue(r, key, m);
    save_registry(r);
    CFRelease(r);
    CFRelease(m);
    CFRelease(key);
    CFRelease(devices);
    post(kColorSyncDeviceProfilesNotification, deviceClass, deviceID);
    return true;
}

/* A device's info as Apple's gives it: URLs as URLs, its ID a UUID. */
static CFDictionaryRef
info_from_record(CFDictionaryRef rec)
{
    CFMutableDictionaryRef d = CFDictionaryCreateMutableCopy(NULL, 0, rec);
    CFUUIDRef id = CFUUIDCreateFromString(NULL, CFDictionaryGetValue(rec, kColorSyncDeviceID));
    if (id) {
        CFDictionarySetValue(d, kColorSyncDeviceID, id);
        CFRelease(id);
    }
    CFDictionaryRef factory = CFDictionaryGetValue(rec, kColorSyncFactoryProfiles);
    if (factory) {
        CFMutableDictionaryRef f = CFDictionaryCreateMutableCopy(NULL, 0, factory);
        CFIndex n = CFDictionaryGetCount(factory);
        const void **keys = malloc(sizeof(void *) * (size_t)(n ? n : 1)), **values = malloc(sizeof(void *) * (size_t)(n ? n : 1));
        CFDictionaryGetKeysAndValues(factory, keys, values);
        for (CFIndex i = 0; i < n; i++) {
            if (CFGetTypeID(values[i]) != CFDictionaryGetTypeID())
                continue;
            CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(NULL, 0, values[i]);
            CFURLRef url = string_url(CFDictionaryGetValue(values[i], kColorSyncDeviceProfileURL));
            if (url) {
                CFDictionarySetValue(m, kColorSyncDeviceProfileURL, url);
                CFRelease(url);
            }
            CFDictionarySetValue(f, keys[i], m);
            CFRelease(m);
        }
        free(keys);
        free(values);
        CFDictionarySetValue(d, kColorSyncFactoryProfiles, f);
        CFRelease(f);
    }
    CFDictionaryRef custom = CFDictionaryGetValue(rec, kColorSyncCustomProfiles);
    if (custom) {
        CFMutableDictionaryRef c = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFIndex n = CFDictionaryGetCount(custom);
        const void **keys = malloc(sizeof(void *) * (size_t)(n ? n : 1)), **values = malloc(sizeof(void *) * (size_t)(n ? n : 1));
        CFDictionaryGetKeysAndValues(custom, keys, values);
        for (CFIndex i = 0; i < n; i++) {
            CFURLRef url = string_url(values[i]);
            if (url) {
                CFDictionarySetValue(c, keys[i], url);
                CFRelease(url);
            }
        }
        free(keys);
        free(values);
        if (CFDictionaryGetCount(c))
            CFDictionarySetValue(d, kColorSyncCustomProfiles, c);
        else
            CFDictionaryRemoveValue(d, kColorSyncCustomProfiles);
        CFRelease(c);
    }
    return d;
}

CFDictionaryRef
ColorSyncDeviceCopyDeviceInfo(CFStringRef deviceClass, CFUUIDRef devID)
{
    if (!deviceClass || !devID)
        return NULL;
    CFMutableDictionaryRef devices = copy_devices();
    CFStringRef key = device_key(deviceClass, devID);
    CFDictionaryRef rec = CFDictionaryGetValue(devices, key);
    CFDictionaryRef info = rec ? info_from_record(rec) : NULL;
    if (info) {
        /* (the custom profiles' scope is the registry's own) */
        CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(NULL, 0, info);
        CFDictionaryRemoveValue(m, kColorSyncProfileUserScope);
        CFDictionaryRemoveValue(m, kColorSyncProfileHostScope);
        CFRelease(info);
        info = m;
    }
    CFRelease(key);
    CFRelease(devices);
    return info;
}

/* Each device's profiles: its factory ones (current unless a custom one replaces it),
   then its custom ones. */
void
ColorSyncIterateDeviceProfiles(ColorSyncDeviceProfileIterateCallback callBack, void *userInfo)
{
    if (!callBack)
        return;
    CFMutableDictionaryRef devices = copy_devices();
    CFIndex n = CFDictionaryGetCount(devices);
    const void **recs = malloc(sizeof(void *) * (size_t)(n ? n : 1));
    CFDictionaryGetKeysAndValues(devices, NULL, recs);
    bool go = true;
    for (CFIndex i = 0; i < n && go; i++) {
        CFDictionaryRef info = info_from_record(recs[i]);
        CFDictionaryRef factory = CFDictionaryGetValue(info, kColorSyncFactoryProfiles);
        CFDictionaryRef custom = CFDictionaryGetValue(info, kColorSyncCustomProfiles);
        CFTypeRef def = factory ? CFDictionaryGetValue(factory, kColorSyncDeviceDefaultProfileID) : NULL;
        CFIndex fn = factory ? CFDictionaryGetCount(factory) : 0;
        const void **ids = malloc(sizeof(void *) * (size_t)(fn ? fn : 1)), **modes = malloc(sizeof(void *) * (size_t)(fn ? fn : 1));
        if (factory)
            CFDictionaryGetKeysAndValues(factory, ids, modes);
        CFTypeRef deviceUser = CFDictionaryGetValue(info, kColorSyncDeviceUserScope);
        CFTypeRef deviceHost = CFDictionaryGetValue(info, kColorSyncDeviceHostScope);
        CFTypeRef customUser = CFDictionaryGetValue(info, kColorSyncProfileUserScope);
        CFTypeRef customHost = CFDictionaryGetValue(info, kColorSyncProfileHostScope);
        /* each mode's factory profile, then the custom one that replaces it */
        for (CFIndex j = 0; j < fn && go; j++)
            for (int pass = 0; pass < 2 && go; pass++) {
                if (CFEqual(ids[j], kColorSyncDeviceDefaultProfileID) || CFGetTypeID(modes[j]) != CFDictionaryGetTypeID())
                    continue;
                CFURLRef customURL = custom ? CFDictionaryGetValue(custom, ids[j]) : NULL;
                if (pass == 1 && !customURL)
                    continue;
                bool isDefault = def && CFEqual(def, ids[j]);
                CFMutableDictionaryRef e = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                                     &kCFTypeDictionaryValueCallBacks);
                CFDictionarySetValue(e, kColorSyncDeviceClass, CFDictionaryGetValue(info, kColorSyncDeviceClass));
                CFDictionarySetValue(e, kColorSyncDeviceID, CFDictionaryGetValue(info, kColorSyncDeviceID));
                CFDictionarySetValue(e, kColorSyncDeviceDescription, CFDictionaryGetValue(info, kColorSyncDeviceDescription));
                CFStringRef mode = CFDictionaryGetValue(modes[j], kColorSyncDeviceModeDescription);
                CFDictionarySetValue(e, kColorSyncDeviceModeDescription, mode ? mode : CFSTR(""));
                CFDictionarySetValue(e, kColorSyncDeviceProfileID, ids[j]);
                CFURLRef url = pass ? customURL : CFDictionaryGetValue(modes[j], kColorSyncDeviceProfileURL);
                if (url)
                    CFDictionarySetValue(e, kColorSyncDeviceProfileURL, url);
                CFDictionarySetValue(e, kColorSyncDeviceProfileIsFactory, pass ? kCFBooleanFalse : kCFBooleanTrue);
                CFDictionarySetValue(e, kColorSyncDeviceProfileIsDefault,
                                     isDefault && (pass || !customURL) ? kCFBooleanTrue : kCFBooleanFalse);
                CFDictionarySetValue(e, kColorSyncDeviceProfileIsCurrent, pass || !customURL ? kCFBooleanTrue : kCFBooleanFalse);
                CFTypeRef user = pass ? customUser : deviceUser, host = pass ? customHost : deviceHost;
                CFDictionarySetValue(e, kColorSyncProfileHostScope, host ? host : kCFPreferencesCurrentHost);
                CFDictionarySetValue(e, kColorSyncProfileUserScope, user ? user : pass ? kCFPreferencesCurrentUser : kCFPreferencesAnyUser);
                go = callBack(e, userInfo);
                CFRelease(e);
            }
        free(ids);
        free(modes);
        CFRelease(info);
    }
    free(recs);
    CFRelease(devices);
}

/* The device's current profile for a mode (its default when profileID is NULL or the
   default's ID): a custom one if chosen, else the factory one. */
ColorSyncProfileRef
ColorSyncProfileCreateDeviceProfile(CFStringRef deviceClass, CFUUIDRef deviceID, CFTypeRef profileID)
{
    CFDictionaryRef info = ColorSyncDeviceCopyDeviceInfo(deviceClass, deviceID);
    if (!info)
        return NULL;
    CFDictionaryRef factory = CFDictionaryGetValue(info, kColorSyncFactoryProfiles);
    CFDictionaryRef custom = CFDictionaryGetValue(info, kColorSyncCustomProfiles);
    if (!profileID || CFEqual(profileID, kColorSyncDeviceDefaultProfileID))
        profileID = factory ? CFDictionaryGetValue(factory, kColorSyncDeviceDefaultProfileID) : NULL;
    CFURLRef url = profileID && custom ? CFDictionaryGetValue(custom, profileID) : NULL;
    if (!url && profileID && factory) {
        CFDictionaryRef mode = CFDictionaryGetValue(factory, profileID);
        if (mode && CFGetTypeID(mode) == CFDictionaryGetTypeID())
            url = CFDictionaryGetValue(mode, kColorSyncDeviceProfileURL);
    }
    ColorSyncProfileRef p = url ? ColorSyncProfileCreateWithURL(url, NULL) : NULL;
    CFRelease(info);
    return p;
}
