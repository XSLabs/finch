/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Script Manager locale calls backed by CoreFoundation's locale data. */
#include "CarbonCore_Finch.h"
#include <CoreFoundation/CFLocale.h>
#include <CarbonCore/MacLocales.h>
#include <CarbonCore/UnicodeUtilities.h>

#define FINCH_LOCALE_MAGIC 0x466e4c63u

struct OpaqueLocaleRef {
    UInt32 magic;
    CFLocaleRef value;
    char identifier[256];
};

static const char *const locale_operation_ids[] = {
    "af", "am", "ar", "as", "az", "be", "bg", "blo", "bn", "bo", "br", "bs", "bs.Cy",
    "ca", "ceb", "chr", "cs", "cy", "da", "de", "dsb", "dz", "ee", "el", "en", "eo",
    "es", "et", "fa", "ff", "ff-adl", "fi", "fil", "fo", "fr", "fy", "ga", "gl", "gu",
    "ha", "haw", "he", "hi", "hr", "hsb", "hu", "hy", "id", "ig", "is", "it", "ja",
    "ka", "kk.Cy", "kk.Ar", "kl", "km", "kn", "ko", "kok", "ku", "ky", "lb", "lij", "lkt",
    "ln", "lo", "lt", "lv", "mk", "ml", "mn", "mr", "ms.La", "mt", "my", "nb", "ne",
    "nl", "nn", "nb", "nso", "om", "or", "pa", "pa", "pl", "ps", "pt", "ro", "ru", "sa",
    "se", "si", "sk", "sl", "smn", "sq", "sr", "sr", "sr.La", "st", "sv", "sw", "ta", "te",
    "th", "tk", "tn", "to", "tr", "ug", "uk", "ur", "uz", "vi", "wae", "wo", "xh", "yi",
    "yo", "zh", "zh.Ha-S", "zh.Ha-S_CN", "zh_SG", "zh.Ha-T", "zh_HK", "zh_MO", "zh.Ha-T_TW", "zu"
};

static Boolean
locale_operation_supported(LocaleOperationClass operation)
{
    return operation == kUnicodeCollationClass || operation == kUnicodeTextBreakClass;
}

static Boolean
locale_copy_cstring(CFStringRef string, char *buffer, size_t size)
{
    return string && CFStringGetCString(string, buffer, (CFIndex)size, kCFStringEncodingUTF8);
}

/* Turn the old Script Manager spelling (zh.Ha-T_TW) into a CFLocale ID. */
static CFLocaleRef
locale_create_cf_value(const char *identifier)
{
    char normalized[256] = {0};
    const char *dot = strchr(identifier, '.');
    const char *underscore = strchr(identifier, '_');
    const char *dash = strchr(identifier, '-');
    const char *end = identifier + strlen(identifier);
    const char *languageEnd = end;
    if (dot && dot < languageEnd) languageEnd = dot;
    if (underscore && underscore < languageEnd) languageEnd = underscore;
    if (dash && dash < languageEnd) languageEnd = dash;
    size_t languageLength = (size_t)(languageEnd - identifier);
    if (!languageLength || languageLength >= sizeof normalized) return NULL;
    memcpy(normalized, identifier, languageLength);
    size_t used = languageLength;

    const char *regionStart = underscore ? underscore + 1 : NULL;
    if (dot) {
        const char *scriptStart = dot + 1;
        const char *scriptEnd = scriptStart;
        while (*scriptEnd && *scriptEnd != '-' && *scriptEnd != '_') scriptEnd++;
        size_t scriptLength = (size_t)(scriptEnd - scriptStart);
        const char *script = NULL;
        if (scriptLength == 2 && !memcmp(scriptStart, "Cy", 2)) script = "Cyrl";
        else if (scriptLength == 2 && !memcmp(scriptStart, "Ar", 2)) script = "Arab";
        else if (scriptLength == 2 && !memcmp(scriptStart, "La", 2)) script = "Latn";
        else if (scriptLength == 2 && !memcmp(scriptStart, "Ha", 2)) {
            script = scriptEnd[0] == '-' && scriptEnd[1] == 'S' ? "Hans" : "Hant";
        }
        if (script) {
            used += (size_t)snprintf(normalized + used, sizeof normalized - used, "-%s", script);
        }
        if (scriptEnd[0] == '-' && (scriptEnd[1] == 'S' || scriptEnd[1] == 'T'))
            regionStart = strchr(scriptEnd, '_');
    } else if (dash && dash < (underscore ? underscore : end)) {
        /* A language variant such as ff-adl is a script choice for CFLocale. */
        const char *variant = dash + 1;
        if (!strcmp(variant, "adl")) used += (size_t)snprintf(normalized + used, sizeof normalized - used, "-Adlm");
        else used += (size_t)snprintf(normalized + used, sizeof normalized - used, "-%s", variant);
    } else if (underscore) {
        const char *firstEnd = strchr(underscore + 1, '_');
        if (!firstEnd) firstEnd = end;
        size_t tokenLength = (size_t)(firstEnd - (underscore + 1));
        if (tokenLength == 4 && isalpha((unsigned char)underscore[1])) {
            char script[5];
            memcpy(script, underscore + 1, 4);
            script[0] = (char)toupper((unsigned char)script[0]);
            script[1] = (char)tolower((unsigned char)script[1]);
            script[2] = (char)tolower((unsigned char)script[2]);
            script[3] = (char)tolower((unsigned char)script[3]);
            used += (size_t)snprintf(normalized + used, sizeof normalized - used, "-%s", script);
            regionStart = *firstEnd == '_' ? firstEnd + 1 : NULL;
        }
    }
    if (regionStart && *regionStart) {
        size_t regionLength = strcspn(regionStart, "_@");
        if (regionLength && used + regionLength + 2 < sizeof normalized) {
            normalized[used++] = '_';
            memcpy(normalized + used, regionStart, regionLength);
            used += regionLength;
            normalized[used] = 0;
        }
    }

    CFStringRef string = CFStringCreateWithCString(NULL, normalized, kCFStringEncodingUTF8);
    if (!string) return NULL;
    CFStringRef canonical = CFLocaleCreateCanonicalLocaleIdentifierFromString(NULL, string);
    CFRelease(string);
    if (!canonical) return NULL;
    CFLocaleRef locale = CFLocaleCreate(NULL, canonical);
    CFRelease(canonical);
    return locale;
}

static LocaleRef
locale_wrap(CFLocaleRef value, const char *identifier)
{
    if (!value || !identifier) return NULL;
    struct OpaqueLocaleRef *locale = calloc(1, sizeof *locale);
    if (!locale) {
        CFRelease(value);
        return NULL;
    }
    locale->magic = FINCH_LOCALE_MAGIC;
    locale->value = value;
    strlcpy(locale->identifier, identifier, sizeof locale->identifier);
    return (LocaleRef)locale;
}

FINCH_HIDDEN CFLocaleRef
_FinchLocaleValue(LocaleRef locale)
{
    struct OpaqueLocaleRef *object = (struct OpaqueLocaleRef *)locale;
    return object && object->magic == FINCH_LOCALE_MAGIC ? object->value : NULL;
}

OSStatus
LocaleRefFromLocaleString(const char localeString[], LocaleRef *out)
{
    if (!localeString || !out) return paramErr;
    *out = NULL;
    CFStringRef string = CFStringCreateWithCString(NULL, localeString, kCFStringEncodingUTF8);
    if (!string) return paramErr;
    CFStringRef canonical = CFLocaleCreateCanonicalLocaleIdentifierFromString(NULL, string);
    CFRelease(string);
    char identifier[256];
    if (!locale_copy_cstring(canonical, identifier, sizeof identifier)) {
        if (canonical) CFRelease(canonical);
        return paramErr;
    }
    CFLocaleRef value = CFLocaleCreate(NULL, canonical);
    CFRelease(canonical);
    if (!value) return memFullErr;
    *out = locale_wrap(value, identifier);
    return *out ? noErr : memFullErr;
}

OSStatus
LocaleRefFromLangOrRegionCode(LangCode language, RegionCode region, LocaleRef *out)
{
    if (!out) return paramErr;
    *out = NULL;
    CFLocaleRef value;
    CFStringRef identifier = NULL;
    if (language == langUnspecified) {
        value = CFLocaleCopyCurrent();
        if (value) identifier = (CFStringRef)CFRetain((CFTypeRef)CFLocaleGetIdentifier(value));
    } else {
        identifier = CFLocaleCreateCanonicalLocaleIdentifierFromScriptManagerCodes(NULL, language, region);
        value = identifier ? CFLocaleCreate(NULL, identifier) : NULL;
    }
    if (!value || !identifier) {
        if (value) CFRelease(value);
        if (identifier) CFRelease(identifier);
        return paramErr;
    }
    char text[256];
    Boolean converted = locale_copy_cstring(identifier, text, sizeof text);
    CFRelease(identifier);
    if (!converted) {
        CFRelease(value);
        return memFullErr;
    }
    *out = locale_wrap(value, text);
    return *out ? noErr : memFullErr;
}

static char *
locale_part(const char *identifier, LocalePartMask partMask, char *out, size_t outSize)
{
    if (!outSize) return NULL;
    out[0] = 0;
    if (partMask == kLocaleAllPartsMask) return strlcpy(out, identifier, outSize) < outSize ? out : NULL;
    const char *dot = strchr(identifier, '.');
    const char *underscore = strchr(identifier, '_');
    const char *at = strchr(identifier, '@');
    const char *end = identifier + strlen(identifier);
    const char *languageEnd = end;
    if (dot && dot < languageEnd) languageEnd = dot;
    if (underscore && underscore < languageEnd) languageEnd = underscore;
    if (at && at < languageEnd) languageEnd = at;
    const char *dash = memchr(identifier, '-', (size_t)(languageEnd - identifier));
    if (dash && dash < languageEnd) languageEnd = dash;
    const char *start = NULL;
    size_t length = 0;
    char prefix = 0;
    switch (partMask) {
    case kLocaleLanguageMask:
        start = identifier;
        length = (size_t)(languageEnd - identifier);
        break;
    case kLocaleLanguageVariantMask:
        if (dash) { start = dash; length = (size_t)((underscore && underscore > dash ? underscore : end) - dash); }
        break;
    case kLocaleScriptMask:
        if (dot) { start = dot + 1; const char *finish = start; while (*finish && *finish != '-' && *finish != '_') finish++; prefix = '.'; length = (size_t)(finish - start); }
        break;
    case kLocaleScriptVariantMask:
        if (dot) {
            const char *variant = strchr(dot + 1, '-');
            if (variant) { start = variant; const char *finish = start; while (*finish && *finish != '_') finish++; prefix = '.'; length = (size_t)(finish - start); }
        }
        break;
    case kLocaleRegionMask:
        if (underscore) { start = underscore + 1; const char *finish = start; while (*finish && *finish != '_' && *finish != '@') finish++; prefix = '_'; length = (size_t)(finish - start); }
        break;
    case kLocaleRegionVariantMask:
        if (at) { start = at + 1; length = strlen(start); prefix = '@'; }
        break;
    default:
        return NULL;
    }
    if (!start || !length) return out;
    size_t offset = prefix ? 1 : 0;
    if (length + offset + 1 > outSize) return NULL;
    if (prefix) out[0] = prefix;
    memcpy(out + offset, start, length);
    out[offset + length] = 0;
    return out;
}

OSStatus
LocaleRefGetPartString(LocaleRef localeRef, LocalePartMask partMask, ByteCount maxStringLen, char partString[])
{
    if (!localeRef || !partString || !maxStringLen) return paramErr;
    struct OpaqueLocaleRef *locale = (struct OpaqueLocaleRef *)localeRef;
    if (locale->magic != FINCH_LOCALE_MAGIC) return paramErr;
    if (!locale_part(locale->identifier, partMask, partString, maxStringLen)) {
        partString[0] = 0;
        return memFullErr;
    }
    return noErr;
}

OSStatus
LocaleOperationCountLocales(LocaleOperationClass operation, ItemCount *localeCount)
{
    if (!localeCount || !locale_operation_supported(operation)) return paramErr;
    *localeCount = sizeof locale_operation_ids / sizeof locale_operation_ids[0];
    return noErr;
}

OSStatus
LocaleOperationGetLocales(LocaleOperationClass operation, ItemCount maxLocaleCount, ItemCount *actualLocaleCount,
                          LocaleAndVariant localeVariantList[])
{
    if (!locale_operation_supported(operation) || (maxLocaleCount && !localeVariantList)) return paramErr;
    ItemCount total = sizeof locale_operation_ids / sizeof locale_operation_ids[0];
    ItemCount count = total < maxLocaleCount ? total : maxLocaleCount;
    for (ItemCount i = 0; i < count; i++) {
        CFLocaleRef value = locale_create_cf_value(locale_operation_ids[i]);
        if (!value) return memFullErr;
        localeVariantList[i].locale = locale_wrap(value, locale_operation_ids[i]);
        if (!localeVariantList[i].locale) return memFullErr;
        localeVariantList[i].opVariant = 0;
    }
    if (actualLocaleCount) *actualLocaleCount = count;
    return noErr;
}

static CFStringRef
locale_component(CFLocaleRef locale, CFStringRef key)
{
    CFStringRef value = CFLocaleGetValue(locale, key);
    return value && CFGetTypeID(value) == CFStringGetTypeID() ? value : NULL;
}

static Boolean
locale_component_equal(CFLocaleRef locale, CFStringRef key, CFStringRef wanted)
{
    CFStringRef value = locale_component(locale, key);
    return value && CFStringCompare(value, wanted, kCFCompareCaseInsensitive) == kCFCompareEqualTo;
}

static LangCode
locale_language_code(CFStringRef language)
{
    for (LangCode code = 0; code <= 151; code++) {
        CFStringRef identifier = CFLocaleCreateCanonicalLocaleIdentifierFromScriptManagerCodes(NULL, code, verUS);
        CFLocaleRef candidate = identifier ? CFLocaleCreate(NULL, identifier) : NULL;
        Boolean matches = candidate && locale_component_equal(candidate, kCFLocaleLanguageCode, language);
        if (candidate) CFRelease(candidate);
        if (identifier) CFRelease(identifier);
        if (matches) return code;
    }
    return langUnspecified;
}

static RegionCode
locale_region_code(CFStringRef country)
{
    for (RegionCode code = 0; code <= 108; code++) {
        CFStringRef identifier = CFLocaleCreateCanonicalLocaleIdentifierFromScriptManagerCodes(NULL, langEnglish, code);
        CFLocaleRef candidate = identifier ? CFLocaleCreate(NULL, identifier) : NULL;
        Boolean matches = candidate && locale_component_equal(candidate, kCFLocaleCountryCode, country);
        if (candidate) CFRelease(candidate);
        if (identifier) CFRelease(identifier);
        if (matches) return code;
    }
    return -1;
}

OSStatus
LocaleStringToLangAndRegionCodes(const char localeString[], LangCode *language, RegionCode *region)
{
    if (!localeString || (!language && !region)) return paramErr;
    CFStringRef string = CFStringCreateWithCString(NULL, localeString, kCFStringEncodingUTF8);
    if (!string) return paramErr;
    CFStringRef identifier = CFLocaleCreateCanonicalLocaleIdentifierFromString(NULL, string);
    CFRelease(string);
    if (!identifier) return paramErr;
    CFLocaleRef locale = CFLocaleCreate(NULL, identifier);
    CFRelease(identifier);
    if (!locale) return paramErr;
    if (language) {
        CFStringRef value = locale_component(locale, kCFLocaleLanguageCode);
        *language = value ? locale_language_code(value) : langUnspecified;
    }
    if (region) {
        CFStringRef value = locale_component(locale, kCFLocaleCountryCode);
        *region = value ? locale_region_code(value) : -1;
    }
    CFRelease(locale);
    return noErr;
}
