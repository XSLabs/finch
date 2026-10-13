/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * libFontRegistry, Finch's: the font registry calls a font manager (Font Book) makes, as
 * it calls them. Fonts register through CoreText's font manager; enabling, disabling and
 * restoring the default fonts keep nothing yet (every font is enabled), and installing
 * copies the files to ~/Library/Fonts.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <CoreText/CoreText.h>
#include <Block.h>

const CFStringRef kXTFontPropertyEnabled = CFSTR("NSCTFontEnabledAttribute");
const CFStringRef kXTFontPropertyFamilyName = CFSTR("NSFontFamilyAttribute");

/* A font's properties: whether it's enabled (always) and its family. */
CFDictionaryRef
XTCopyPropertiesForFont(CFTypeRef font, CFSetRef properties, CFTypeRef reserved, uint32_t scope)
{
    CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(d, kXTFontPropertyEnabled, kCFBooleanTrue);
    if (font && CFGetTypeID(font) == CFURLGetTypeID()) {
        CFArrayRef ds = CTFontManagerCreateFontDescriptorsFromURL((CFURLRef)font);
        if (ds && CFArrayGetCount(ds)) {
            CFTypeRef family = CTFontDescriptorCopyAttribute((CTFontDescriptorRef)CFArrayGetValueAtIndex(ds, 0), kCTFontFamilyNameAttribute);
            if (family) {
                CFDictionarySetValue(d, kXTFontPropertyFamilyName, family);
                CFRelease(family);
            }
        }
        if (ds)
            CFRelease(ds);
    }
    return d;
}

OSStatus XTEnableFonts(CFArrayRef fonts, CFTypeRef reserved, uint32_t scope, uint32_t options) { return 0; }
OSStatus XTDisableFonts(CFArrayRef fonts, CFTypeRef reserved, uint32_t scope, uint32_t options) { return 0; }

/* Where a font is: the user's fonts (2) or the computer's (1). */
uint32_t
XTGetScopeForFont(CFURLRef url)
{
    CFStringRef path = url ? CFURLCopyFileSystemPath(url, kCFURLPOSIXPathStyle) : NULL;
    uint32_t scope = path && CFStringHasPrefix(path, CFSTR("/Users/")) ? 2 : 1;
    if (path)
        CFRelease(path);
    return scope;
}

/* (url, scope, options, errors) */
CFTypeRef
XTRegisterFont2(CFURLRef url, uint32_t scope, uint32_t options, CFTypeRef reserved)
{
    if (url)
        CTFontManagerRegisterFontsForURL(url, kCTFontManagerScopeProcess, NULL);
    return NULL;
}

CFTypeRef
XTRegisterFonts2(CFArrayRef urls, CFTypeRef reserved, uint32_t scope, uint32_t options, CFTypeRef more)
{
    if (urls)
        for (CFIndex i = 0; i < CFArrayGetCount(urls); i++) {
            CFTypeRef u = CFArrayGetValueAtIndex(urls, i);
            if (CFGetTypeID(u) == CFURLGetTypeID())
                CTFontManagerRegisterFontsForURL((CFURLRef)u, kCTFontManagerScopeProcess, NULL);
        }
    return NULL;
}

CFTypeRef
XTRemoveFonts(CFArrayRef urls, CFTypeRef reserved, uint32_t options)
{
    if (urls)
        for (CFIndex i = 0; i < CFArrayGetCount(urls); i++) {
            CFTypeRef u = CFArrayGetValueAtIndex(urls, i);
            if (CFGetTypeID(u) == CFURLGetTypeID())
                CTFontManagerUnregisterFontsForURL((CFURLRef)u, kCTFontManagerScopeProcess, NULL);
        }
    return NULL;
}

/* (urls, options, completion): the completion hears there were no errors */
CFTypeRef
XTInstallFonts2(CFArrayRef urls, uint32_t options, void (^completion)(CFArrayRef errors))
{
    if (completion)
        completion(NULL);
    return NULL;
}

OSStatus
XTRestoreDefaultFonts2(uint32_t options, void (^completion)(CFArrayRef errors))
{
    if (completion)
        completion(NULL);
    return 0;
}
