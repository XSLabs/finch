/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CoreFoundation calls and constants apps use that swift-corelibs-foundation lacks:
 * the version number, preferences in containers and forced values, XML entity escaping,
 * bidirectional levels of attributed strings (ICU's, as Apple's), hyphenation (none
 * yet), URL promises, quick class checks, and a few keys.
 */
#include <CoreFoundation/CoreFoundation.h>
#include "ForFoundationOnly.h"
#import <objc/runtime.h>
#include <pthread.h>
extern SInt32 _CFBundleCurrentArchitecture(void);
extern CFStringRef _CFPreferencesGetByHostIdentifierString(void);
extern CFPreferencesDomainRef _CFPreferencesDomainCreate(CFTypeRef context, const _CFPreferencesDomainCallBacks *callbacks);
extern CFTypeRef _CFPreferencesDomainCreateValueForKey(CFPreferencesDomainRef domain, CFStringRef key);
extern void _CFPreferencesDomainSet(CFPreferencesDomainRef domain, CFStringRef key, CFTypeRef value);
extern Boolean _CFPreferencesDomainSynchronize(CFPreferencesDomainRef domain);
extern const _CFPreferencesDomainCallBacks __kCFXMLPropertyListDomainCallBacks;

#define FINCH_EXPORT __attribute__((visibility("default")))

FINCH_EXPORT double kCFCoreFoundationVersionNumber = 4424.10;
FINCH_EXPORT const CFStringRef _kCFURLFinderInfoKey = CFSTR("_NSURLFinderInfoKey");
FINCH_EXPORT const CFStringRef kCFNumberFormatterMinGroupingDigits = CFSTR("kCFNumberFormatterMinGroupingDigitsKey");
FINCH_EXPORT const CFStringRef kCFUserNotificationAlertHeaderKey = CFSTR("AlertHeader");
FINCH_EXPORT const CFStringRef kCFUserNotificationAlertMessageKey = CFSTR("AlertMessage");

/* Finch runs one executable architecture on the machine. */
FINCH_EXPORT cpu_type_t
_CFBundleGetPreferredExecutableArchitecture(CFBundleRef bundle)
{
    (void)bundle;
    return (cpu_type_t)_CFBundleCurrentArchitecture();
}

/* --- preferences --- */

static CFPreferencesDomainRef container_preferences_domain(CFStringRef applicationID, CFStringRef user, CFStringRef host,
                                                             CFStringRef container);

/* (Finch has no managed preferences: nothing is forced) */
FINCH_EXPORT Boolean
CFPreferencesAppValueIsForced(CFStringRef key, CFStringRef applicationID)
{
    return false;
}

/* A container owns a separate preferences file under its Library folder. */
FINCH_EXPORT CFPropertyListRef
_CFPreferencesCopyValueWithContainer(CFStringRef key, CFStringRef applicationID, CFStringRef user, CFStringRef host,
                                     CFStringRef container)
{
    if (!container)
        return CFPreferencesCopyValue(key, applicationID, user, host);
    CFPreferencesDomainRef domain = container_preferences_domain(applicationID, user, host, container);
    return domain ? _CFPreferencesDomainCreateValueForKey(domain, key) : NULL;
}

FINCH_EXPORT void
_CFPreferencesSetValueWithContainer(CFStringRef key, CFPropertyListRef value, CFStringRef applicationID, CFStringRef user,
                                    CFStringRef host, CFStringRef container)
{
    if (!container) {
        CFPreferencesSetValue(key, value, applicationID, user, host);
        return;
    }
    CFPreferencesDomainRef domain = container_preferences_domain(applicationID, user, host, container);
    if (domain)
        _CFPreferencesDomainSet(domain, key, value);
}

FINCH_EXPORT Boolean
_CFPreferencesSynchronizeWithContainer(CFStringRef applicationID, CFStringRef user, CFStringRef host, CFStringRef container)
{
    if (!container)
        return CFPreferencesSynchronize(applicationID, user, host);
    CFPreferencesDomainRef domain = container_preferences_domain(applicationID, user, host, container);
    return domain ? _CFPreferencesDomainSynchronize(domain) : false;
}

static pthread_mutex_t containerDomainLock = PTHREAD_MUTEX_INITIALIZER;
static CFMutableDictionaryRef containerDomains;

static CFPreferencesDomainRef
container_preferences_domain(CFStringRef applicationID, CFStringRef user, CFStringRef host, CFStringRef container)
{
    if (!applicationID || !user || !host || !container || CFEqual(user, kCFPreferencesAnyUser))
        return NULL;

    CFStringRef hostID = NULL;
    Boolean byHost = CFEqual(host, kCFPreferencesCurrentHost);
    if (byHost)
        hostID = _CFPreferencesGetByHostIdentifierString();
    else if (!CFEqual(host, kCFPreferencesAnyHost))
        hostID = host;

    CFURLRef containerURL = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, container, kCFURLPOSIXPathStyle, true);
    if (!containerURL)
        return NULL;
    CFURLRef preferencesURL = CFURLCreateWithFileSystemPathRelativeToBase(kCFAllocatorDefault, CFSTR("Library/Preferences"),
                                                                           kCFURLPOSIXPathStyle, true, containerURL);
    CFRelease(containerURL);
    if (!preferencesURL)
        return NULL;

    if (byHost) {
        CFURLRef byHostURL = CFURLCreateWithFileSystemPathRelativeToBase(kCFAllocatorDefault, CFSTR("ByHost"),
                                                                         kCFURLPOSIXPathStyle, true, preferencesURL);
        CFRelease(preferencesURL);
        preferencesURL = byHostURL;
        if (!preferencesURL)
            return NULL;
    }

    CFStringRef fileName = hostID ? CFStringCreateWithFormat(kCFAllocatorDefault, NULL, CFSTR("%@.%@.plist"),
                                                              applicationID, hostID)
                                  : CFStringCreateWithFormat(kCFAllocatorDefault, NULL, CFSTR("%@.plist"), applicationID);
    CFURLRef fileURL = fileName ? CFURLCreateWithFileSystemPathRelativeToBase(kCFAllocatorDefault, fileName,
                                                                              kCFURLPOSIXPathStyle, false, preferencesURL)
                                : NULL;
    if (fileName)
        CFRelease(fileName);
    CFRelease(preferencesURL);
    if (!fileURL)
        return NULL;

    CFStringRef cacheKey = CFURLCopyFileSystemPath(fileURL, kCFURLPOSIXPathStyle);
    CFPreferencesDomainRef domain = NULL;
    pthread_mutex_lock(&containerDomainLock);
    if (!containerDomains)
        containerDomains = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
                                                      &kCFTypeDictionaryValueCallBacks);
    domain = (CFPreferencesDomainRef)CFDictionaryGetValue(containerDomains, cacheKey);
    if (!domain) {
        domain = _CFPreferencesDomainCreate(fileURL, &__kCFXMLPropertyListDomainCallBacks);
        if (domain) {
            CFDictionarySetValue(containerDomains, cacheKey, domain);
            CFRelease(domain);
            domain = (CFPreferencesDomainRef)CFDictionaryGetValue(containerDomains, cacheKey);
        }
    }
    pthread_mutex_unlock(&containerDomainLock);
    CFRelease(cacheKey);
    CFRelease(fileURL);
    return domain;
}

static Boolean
container_boolean_value(CFPropertyListRef value, Boolean *valid)
{
    Boolean localValid = false;
    if (!valid)
        valid = &localValid;
    if (!value) {
        *valid = false;
        return false;
    }
    CFTypeID type = CFGetTypeID(value);
    if (type == CFStringGetTypeID()) {
        if (CFStringCompare((CFStringRef)value, CFSTR("true"), kCFCompareCaseInsensitive) == kCFCompareEqualTo ||
            CFStringCompare((CFStringRef)value, CFSTR("YES"), kCFCompareCaseInsensitive) == kCFCompareEqualTo) {
            *valid = true;
            return true;
        }
        if (CFStringCompare((CFStringRef)value, CFSTR("false"), kCFCompareCaseInsensitive) == kCFCompareEqualTo ||
            CFStringCompare((CFStringRef)value, CFSTR("NO"), kCFCompareCaseInsensitive) == kCFCompareEqualTo) {
            *valid = true;
            return false;
        }
        *valid = false;
        return false;
    }
    if (type == CFNumberGetTypeID()) {
        if (CFNumberIsFloatType((CFNumberRef)value)) {
            *valid = false;
            return false;
        }
        int number = 0;
        *valid = true;
        CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &number);
        return number != 0;
    }
    if (type == CFBooleanGetTypeID()) {
        *valid = true;
        return value == kCFBooleanTrue;
    }
    *valid = false;
    return false;
}

/* A container is a path, with its own Library/Preferences domain. */
FINCH_EXPORT CFPropertyListRef
_CFPreferencesCopyAppValueWithContainer(CFStringRef key, CFStringRef applicationID, CFStringRef container)
{
    if (!container)
        return CFPreferencesCopyAppValue(key, applicationID);
    CFPreferencesDomainRef domain = container_preferences_domain(applicationID, kCFPreferencesCurrentUser,
                                                                    kCFPreferencesAnyHost, container);
    return domain ? _CFPreferencesDomainCreateValueForKey(domain, key) : NULL;
}

FINCH_EXPORT Boolean
_CFPreferencesGetAppBooleanValueWithContainer(CFStringRef key, CFStringRef applicationID, CFStringRef container,
                                             Boolean *keyExistsAndHasValidFormat)
{
    if (!container)
        return CFPreferencesGetAppBooleanValue(key, applicationID, keyExistsAndHasValidFormat);
    CFPropertyListRef value = _CFPreferencesCopyAppValueWithContainer(key, applicationID, container);
    Boolean result = container_boolean_value(value, keyExistsAndHasValidFormat);
    if (value)
        CFRelease(value);
    return result;
}

FINCH_EXPORT void
_CFPreferencesSetAppValueWithContainer(CFStringRef key, CFPropertyListRef value, CFStringRef applicationID,
                                       CFStringRef container)
{
    if (!container) {
        CFPreferencesSetAppValue(key, value, applicationID);
        return;
    }
    CFPreferencesDomainRef domain = container_preferences_domain(applicationID, kCFPreferencesCurrentUser,
                                                                    kCFPreferencesAnyHost, container);
    if (domain)
        _CFPreferencesDomainSet(domain, key, value);
}

/* (no supplemental, rapid security response, version installed) */
FINCH_EXPORT CFDictionaryRef
_CFCopySupplementalVersionDictionary(void)
{
    return NULL;
}

/* (a promised item's URL is the item's own: Finch keeps no placeholders) */
FINCH_EXPORT CFURLRef
_CFURLPromiseCopyPhysicalURL(CFURLRef url)
{
    return url ? (CFURLRef)CFRetain(url) : NULL;
}

/* --- quick class checks --- */

FINCH_EXPORT Boolean _NSIsNSArray(id o) { return [o isKindOfClass:objc_getClass("NSArray")]; }
FINCH_EXPORT Boolean _NSIsNSDictionary(id o) { return [o isKindOfClass:objc_getClass("NSDictionary")]; }
FINCH_EXPORT Boolean _NSIsNSNumber(id o) { return [o isKindOfClass:objc_getClass("NSNumber")]; }

/* --- XML entities --- */

/* &, <, >, " and ' written as entities, and any characters in the dictionary (character
   string to entity name) as theirs. */
FINCH_EXPORT CFStringRef
CFXMLCreateStringByEscapingEntities(CFAllocatorRef allocator, CFStringRef string, CFDictionaryRef entitiesDictionary)
{
    if (!string)
        return NULL;
    CFMutableStringRef out = CFStringCreateMutable(allocator, 0);
    CFIndex n = CFStringGetLength(string);
    for (CFIndex i = 0; i < n; i++) {
        UniChar c = CFStringGetCharacterAtIndex(string, i);
        const char *e = c == '&' ? "&amp;" : c == '<' ? "&lt;" : c == '>' ? "&gt;" : c == '"' ? "&quot;" : c == '\'' ? "&apos;" : NULL;
        if (e) {
            CFStringAppendCString(out, e, kCFStringEncodingASCII);
            continue;
        }
        CFStringRef ch = CFStringCreateWithCharacters(allocator, &c, 1);
        CFStringRef name = entitiesDictionary ? (CFStringRef)CFDictionaryGetValue(entitiesDictionary, ch) : NULL;
        if (name) {
            CFStringAppend(out, CFSTR("&"));
            CFStringAppend(out, name);
            CFStringAppend(out, CFSTR(";"));
        } else
            CFStringAppendCharacters(out, &c, 1);
        CFRelease(ch);
    }
    return out;
}

/* The five XML entities, numeric character references, and the dictionary's (entity
   name to replacement); anything else is left as it is. */
FINCH_EXPORT CFStringRef
CFXMLCreateStringByUnescapingEntities(CFAllocatorRef allocator, CFStringRef string, CFDictionaryRef entitiesDictionary)
{
    if (!string)
        return NULL;
    CFMutableStringRef out = CFStringCreateMutable(allocator, 0);
    CFIndex n = CFStringGetLength(string);
    for (CFIndex i = 0; i < n; i++) {
        UniChar c = CFStringGetCharacterAtIndex(string, i);
        CFRange semi = c == '&' ? CFStringFind(string, CFSTR(";"), 0) : CFRangeMake(kCFNotFound, 0);
        if (c == '&') {
            CFRange rest = CFRangeMake(i + 1, n - i - 1);
            Boolean found = CFStringFindWithOptions(string, CFSTR(";"), rest, 0, &semi);
            if (found && semi.location - i - 1 > 0 && semi.location - i - 1 < 32) {
                CFStringRef name = CFStringCreateWithSubstring(allocator, string, CFRangeMake(i + 1, semi.location - i - 1));
                UniChar buf[32];
                CFIndex len = CFStringGetLength(name);
                CFStringGetCharacters(name, CFRangeMake(0, len), buf);
                CFStringRef replacement = NULL;
                UTF32Char code = 0;
                if (len > 1 && buf[0] == '#') {
                    Boolean hex = buf[1] == 'x' || buf[1] == 'X';
                    for (CFIndex k = hex ? 2 : 1; k < len; k++) {
                        UniChar d = buf[k];
                        int v = d >= '0' && d <= '9' ? d - '0' : hex && d >= 'a' && d <= 'f' ? d - 'a' + 10 : hex && d >= 'A' && d <= 'F' ? d - 'A' + 10 : -1;
                        if (v < 0) {
                            code = 0;
                            break;
                        }
                        code = code * (hex ? 16 : 10) + (UTF32Char)v;
                    }
                } else if (CFEqual(name, CFSTR("amp")))
                    replacement = CFSTR("&");
                else if (CFEqual(name, CFSTR("lt")))
                    replacement = CFSTR("<");
                else if (CFEqual(name, CFSTR("gt")))
                    replacement = CFSTR(">");
                else if (CFEqual(name, CFSTR("quot")))
                    replacement = CFSTR("\"");
                else if (CFEqual(name, CFSTR("apos")))
                    replacement = CFSTR("'");
                else if (entitiesDictionary)
                    replacement = (CFStringRef)CFDictionaryGetValue(entitiesDictionary, name);
                CFRelease(name);
                if (code > 0 && code <= 0x10FFFF) {
                    UniChar pair[2];
                    if (code > 0xFFFF) {
                        code -= 0x10000;
                        pair[0] = (UniChar)(0xD800 + (code >> 10));
                        pair[1] = (UniChar)(0xDC00 + (code & 0x3FF));
                        CFStringAppendCharacters(out, pair, 2);
                    } else {
                        pair[0] = (UniChar)code;
                        CFStringAppendCharacters(out, pair, 1);
                    }
                    i = semi.location;
                    continue;
                }
                if (replacement) {
                    CFStringAppend(out, replacement);
                    i = semi.location;
                    continue;
                }
            }
        }
        CFStringAppendCharacters(out, &c, 1);
    }
    return out;
}

/* --- text --- */

/* (no hyphenation dictionaries yet: no place to hyphenate) */
FINCH_EXPORT CFIndex
CFStringGetHyphenationLocationBeforeIndex(CFStringRef string, CFIndex location, CFRange limitRange, CFOptionFlags options,
                                          CFLocaleRef locale, UTF32Char *character)
{
    return kCFNotFound;
}

/* Finch ships no hyphenation dictionaries, so no locale has rules available. */
Boolean
CFStringIsHyphenationAvailableForLocale(CFLocaleRef locale)
{
    (void)locale;
    return false;
}

/* Apple's ICU, declared as CF declares what it uses. */
typedef struct UBiDi UBiDi;
typedef int UErrorCode;
extern UBiDi *ubidi_open(void);
extern void ubidi_close(UBiDi *b);
extern void ubidi_setPara(UBiDi *b, const UniChar *text, int32_t length, uint8_t paraLevel, uint8_t *embeddingLevels, UErrorCode *status);
extern const uint8_t *ubidi_getLevels(UBiDi *b, UErrorCode *status);
extern uint8_t ubidi_getParaLevel(const UBiDi *b);

/* Each character's embedding level, by the Unicode Bidi Algorithm, and its paragraph's
   resolved direction (0 left to right, 1 right to left), for a base direction (-1
   natural, 0 LTR, 1 RTL); true unless all of it is left to right at level 0. */
FINCH_EXPORT bool
CFAttributedStringGetBidiLevelsAndResolvedDirections(CFAttributedStringRef attributedString, CFRange range, int8_t baseDirection,
                                                     uint8_t *bidiLevels, uint8_t *baseDirections)
{
    if (!attributedString || range.length <= 0)
        return false;
    CFStringRef s = CFAttributedStringGetString(attributedString);
    UniChar *chars = malloc((size_t)range.length * sizeof(UniChar));
    if (!chars)
        return false;
    CFStringGetCharacters(s, range, chars);
    UBiDi *bidi = ubidi_open();
    UErrorCode status = 0;
    uint8_t level = baseDirection == 1 ? 1 : baseDirection == 0 ? 0 : 0xFE; /* (0xFE: UBIDI_DEFAULT_LTR) */
    ubidi_setPara(bidi, chars, (int32_t)range.length, level, NULL, &status);
    bool mixed = false;
    if (status <= 0) {
        const uint8_t *levels = ubidi_getLevels(bidi, &status);
        uint8_t para = ubidi_getParaLevel(bidi) & 1;
        for (CFIndex i = 0; i < range.length && levels; i++) {
            if (bidiLevels)
                bidiLevels[i] = levels[i];
            if (baseDirections)
                baseDirections[i] = para;
            if (levels[i])
                mixed = true;
        }
    }
    ubidi_close(bidi);
    free(chars);
    return mixed;
}

/* With a natural base direction, a paragraph is right to left when 40% or more of its
   words are (as Apple's decides); otherwise as above. */
FINCH_EXPORT bool
CFAttributedStringGetStatisticalWritingDirections(CFAttributedStringRef attributedString, CFRange range, int8_t baseDirection,
                                                  uint8_t *bidiLevels, uint8_t *baseDirections)
{
    if (baseDirection != -1 || !attributedString || range.length <= 0)
        return CFAttributedStringGetBidiLevelsAndResolvedDirections(attributedString, range, baseDirection, bidiLevels, baseDirections);
    CFStringRef s = CFAttributedStringGetString(attributedString);
    CFIndex words = 0, rtl = 0;
    Boolean inWord = false, wordRTL = false;
    for (CFIndex i = range.location; i <= range.location + range.length; i++) {
        UniChar c = i < range.location + range.length ? CFStringGetCharacterAtIndex(s, i) : ' ';
        Boolean space = c == ' ' || c == '\t' || c == '\n';
        if (!space) {
            if (!inWord)
                wordRTL = false;
            inWord = true;
            if ((c >= 0x0590 && c <= 0x08FF) || (c >= 0xFB1D && c <= 0xFDFF) || (c >= 0xFE70 && c <= 0xFEFF))
                wordRTL = true;
        } else if (inWord) {
            words++;
            rtl += wordRTL;
            inWord = false;
        }
    }
    int8_t base = words && rtl * 10 >= words * 4 ? 1 : 0;
    return CFAttributedStringGetBidiLevelsAndResolvedDirections(attributedString, range, base, bidiLevels, baseDirections);
}
