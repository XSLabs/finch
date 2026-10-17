// SPDX-License-Identifier: MIT OR Apache-2.0
#import <MediaAccessibility/MediaAccessibility.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#import <ImageIO/ImageIO.h>
#import <dispatch/dispatch.h>
#include <math.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

const CFStringRef kMACaptionAppearanceSettingsChangedNotification = CFSTR("kMACaptionAppearanceSettingsChangedNotification");
const CFStringRef kMAAudibleMediaSettingsChangedNotification = CFSTR("kMAAudibleMediaSettingsChangedNotification");
CFStringRef const MAMediaCharacteristicDescribesMusicAndSoundForAccessibility = CFSTR("describes-music-and-sound-for-accessibility");
CFStringRef const MAMediaCharacteristicTranscribesSpokenDialogForAccessibility = CFSTR("transcribes-spoken-dialog-for-accessibility");
CFStringRef const MAMediaCharacteristicDescribesVideoForAccessibility = CFSTR("describes-video-for-accessibility");

static CFStringRef const kPreferencesDomain = CFSTR("com.apple.Accessibility");
static CFStringRef const kMediaDomain = CFSTR("com.apple.mediaaccessibility");
static CFStringRef const kProfileClassic = CFSTR("MACaptionProfile-Classic");
static CFStringRef const kProfileLargeText = CFSTR("MACaptionProfile-LargeText");
static CFStringRef const kProfileOutlineText = CFSTR("MACaptionProfile-OutlineText");
static CFStringRef const kProfileDefault = CFSTR("MACaptionProfile-Default");
static _Thread_local CFStringRef gProfileOverride;
static CFTypeRef MAReadPreference(CFStringRef key);

typedef enum {
    MAProfileKindDefault,
    MAProfileKindClassic,
    MAProfileKindLargeText,
    MAProfileKindOutlineText
} MAProfileKind;

static MAProfileKind MAProfileKindForID(CFStringRef profileID)
{
    if (profileID && CFEqual(profileID, kProfileClassic)) return MAProfileKindClassic;
    if (profileID && CFEqual(profileID, kProfileLargeText)) return MAProfileKindLargeText;
    if (profileID && CFEqual(profileID, kProfileOutlineText)) return MAProfileKindOutlineText;
    return MAProfileKindDefault;
}

static MAProfileKind MAProfileForDomain(MACaptionAppearanceDomain domain)
{
    if (domain != kMACaptionAppearanceDomainUser) return MAProfileKindDefault;
    if (gProfileOverride) return MAProfileKindForID(gProfileOverride);
    CFTypeRef value = MAReadPreference(CFSTR("CaptioningActiveProfileID"));
    MAProfileKind kind = value && CFGetTypeID(value) == CFStringGetTypeID() ?
        MAProfileKindForID((CFStringRef)value) : MAProfileKindDefault;
    if (value) CFRelease(value);
    return kind;
}

static CFStringRef MAProfileName(CFStringRef profileID)
{
    if (profileID && CFEqual(profileID, kProfileClassic)) return CFSTR("Classic");
    if (profileID && CFEqual(profileID, kProfileLargeText)) return CFSTR("Large Text");
    if (profileID && CFEqual(profileID, kProfileOutlineText)) return CFSTR("Outline Text");
    if (profileID && CFEqual(profileID, kProfileDefault)) return CFSTR("Transparent Background");
    return NULL;
}

static CFTypeRef MAReadPreference(CFStringRef key)
{
    CFTypeRef value = CFPreferencesCopyValue(key, kPreferencesDomain,
        kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
    if (!value)
        value = CFPreferencesCopyValue(key, kMediaDomain,
            kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
    if (!value)
        value = CFPreferencesCopyValue(key, kPreferencesDomain,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (!value)
        value = CFPreferencesCopyValue(key, kMediaDomain,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    return value;
}

static CFTypeRef MAReadFirstPreference(const char *const *keys)
{
    for (size_t i = 0; keys[i]; i++) {
        CFStringRef key = CFStringCreateWithCString(kCFAllocatorDefault, keys[i], kCFStringEncodingUTF8);
        CFTypeRef value = MAReadPreference(key);
        CFRelease(key);
        if (value) return value;
    }
    return NULL;
}

static CFIndex MAIntegerPreference(CFIndex fallback, const char *const *keys)
{
    CFTypeRef value = MAReadFirstPreference(keys);
    CFIndex result = fallback;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID())
        CFNumberGetValue((CFNumberRef)value, kCFNumberCFIndexType, &result);
    if (value) CFRelease(value);
    return result;
}

static CGFloat MAFloatPreference(CGFloat fallback, const char *const *keys)
{
    CFTypeRef value = MAReadFirstPreference(keys);
    CGFloat result = fallback;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID())
        CFNumberGetValue((CFNumberRef)value, kCFNumberCGFloatType, &result);
    if (value) CFRelease(value);
    return result;
}

static Boolean MABoolPreference(Boolean fallback, const char *const *keys)
{
    CFTypeRef value = MAReadFirstPreference(keys);
    Boolean result = fallback;
    if (value && CFGetTypeID(value) == CFBooleanGetTypeID())
        result = CFBooleanGetValue((CFBooleanRef)value);
    else if (value && CFGetTypeID(value) == CFNumberGetTypeID()) {
        int number = 0;
        CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &number);
        result = number != 0;
    }
    if (value) CFRelease(value);
    return result;
}

static void MAWritePreference(const char *keyName, CFTypeRef value)
{
    CFStringRef key = CFStringCreateWithCString(kCFAllocatorDefault, keyName, kCFStringEncodingUTF8);
    CFPreferencesSetValue(key, value, kPreferencesDomain,
        kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
    CFPreferencesAppSynchronize(kPreferencesDomain);
    CFRelease(key);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDistributedCenter(),
        kMACaptionAppearanceSettingsChangedNotification, NULL, NULL, true);
}

static void MASetIntegerPreference(const char *key, CFIndex number)
{
    CFNumberRef value = CFNumberCreate(kCFAllocatorDefault, kCFNumberCFIndexType, &number);
    MAWritePreference(key, value);
    CFRelease(value);
}

static CFArrayRef MACopyArrayPreference(CFIndex domain, const char *const *keys)
{
    if (domain != kMACaptionAppearanceDomainUser && domain != kMACaptionAppearanceDomainDefault)
        return CFArrayCreate(kCFAllocatorDefault, NULL, 0, &kCFTypeArrayCallBacks);
    CFTypeRef value = domain == kMACaptionAppearanceDomainUser ? MAReadFirstPreference(keys) : NULL;
    if (value && CFGetTypeID(value) == CFArrayGetTypeID())
        return value;
    if (value) CFRelease(value);
    return CFArrayCreate(kCFAllocatorDefault, NULL, 0, &kCFTypeArrayCallBacks);
}

CFArrayRef MACaptionAppearanceCopySelectedLanguages(MACaptionAppearanceDomain domain)
{
    static const char *const keys[] = {"CaptioningSelectedLanguages", "SelectedCaptionLanguages", "MACaptionAppearanceSelectedLanguages", NULL};
    if (domain == kMACaptionAppearanceDomainDefault)
        return CFLocaleCopyPreferredLanguages();
    return MACopyArrayPreference(domain, keys);
}

bool MACaptionAppearanceAddSelectedLanguage(MACaptionAppearanceDomain domain, CFStringRef language)
{
    if (domain != kMACaptionAppearanceDomainUser || !language || CFGetTypeID(language) != CFStringGetTypeID()) return false;
    CFStringRef canonical = CFLocaleCreateCanonicalLanguageIdentifierFromString(kCFAllocatorDefault, language);
    if (!canonical || CFStringGetLength(canonical) == 0) {
        if (canonical) CFRelease(canonical);
        return false;
    }
    CFArrayRef old = MACaptionAppearanceCopySelectedLanguages(domain);
    CFMutableArrayRef values = CFArrayCreateMutableCopy(kCFAllocatorDefault, 0, old);
    CFRelease(old);
    for (CFIndex i = CFArrayGetCount(values) - 1; i >= 0; i--) {
        CFTypeRef oldLanguage = CFArrayGetValueAtIndex(values, i);
        if (CFGetTypeID(oldLanguage) == CFStringGetTypeID() && CFStringCompare(oldLanguage, canonical, kCFCompareCaseInsensitive) == kCFCompareEqualTo)
            CFArrayRemoveValueAtIndex(values, i);
    }
    CFArrayInsertValueAtIndex(values, 0, canonical);
    MAWritePreference("CaptioningSelectedLanguages", values);
    CFRelease(values);
    CFRelease(canonical);
    return true;
}

MACaptionAppearanceDisplayType MACaptionAppearanceGetDisplayType(MACaptionAppearanceDomain domain)
{
    static const char *const keys[] = {"CaptionDisplayType", "CaptioningDisplayType", "MACaptionAppearanceDisplayType", NULL};
    return (MACaptionAppearanceDisplayType)MAIntegerPreference(kMACaptionAppearanceDisplayTypeAutomatic,
        domain == kMACaptionAppearanceDomainUser ? keys : (const char *const[]){NULL});
}

void MACaptionAppearanceSetDisplayType(MACaptionAppearanceDomain domain, MACaptionAppearanceDisplayType displayType)
{
    if (domain == kMACaptionAppearanceDomainUser && displayType >= kMACaptionAppearanceDisplayTypeForcedOnly && displayType <= kMACaptionAppearanceDisplayTypeAlwaysOn)
        MASetIntegerPreference("CaptionDisplayType", displayType);
}

CFArrayRef MACaptionAppearanceCopyPreferredCaptioningMediaCharacteristics(MACaptionAppearanceDomain domain)
{
    static const char *const keys[] = {"CaptioningPreferredMediaCharacteristics", "PreferredCaptioningMediaCharacteristics", NULL};
    return MACopyArrayPreference(domain, keys);
}

bool MACaptionAppearanceIsCustomized(MACaptionAppearanceDomain domain)
{
    static const char *const keys[] = {"CaptioningCustomized", "MACaptionAppearanceCustomized", NULL};
    return MABoolPreference(false, domain == kMACaptionAppearanceDomainUser ? keys : (const char *const[]){NULL});
}

static CGColorRef MACopyColor(MACaptionAppearanceDomain domain, MACaptionAppearanceBehavior *behavior,
    const char *const *keys, CGFloat red, CGFloat green, CGFloat blue, CGFloat alpha)
{
    if (behavior) *behavior = kMACaptionAppearanceBehaviorUseContentIfAvailable;
    CFTypeRef value = domain == kMACaptionAppearanceDomainUser ? MAReadFirstPreference(keys) : NULL;
    if (value && CFGetTypeID(value) == CFArrayGetTypeID() && CFArrayGetCount(value) >= 3) {
        CGFloat components[4] = {red, green, blue, alpha};
        for (CFIndex i = 0; i < 4 && i < CFArrayGetCount(value); i++) {
            CFTypeRef component = CFArrayGetValueAtIndex(value, i);
            if (CFGetTypeID(component) == CFNumberGetTypeID())
                CFNumberGetValue((CFNumberRef)component, kCFNumberCGFloatType, &components[i]);
        }
        CGColorRef color = CGColorCreateGenericRGB(components[0], components[1], components[2], components[3]);
        CFRelease(value);
        return color;
    }
    if (value) CFRelease(value);
    return CGColorCreateGenericRGB(red, green, blue, alpha);
}

CGColorRef MACaptionAppearanceCopyForegroundColor(MACaptionAppearanceDomain d, MACaptionAppearanceBehavior *b)
{
    static const char *const keys[] = {"CaptioningForegroundColor", "CaptionForegroundColor", NULL};
    return MACopyColor(d, b, keys, 1, 1, 1, 1);
}
CGColorRef MACaptionAppearanceCopyBackgroundColor(MACaptionAppearanceDomain d, MACaptionAppearanceBehavior *b)
{
    static const char *const keys[] = {"CaptioningBackgroundColor", "CaptionBackgroundColor", NULL};
    return MACopyColor(d, b, keys, 0, 0, 0, 1);
}
CGColorRef MACaptionAppearanceCopyWindowColor(MACaptionAppearanceDomain d, MACaptionAppearanceBehavior *b)
{
    static const char *const keys[] = {"CaptioningWindowColor", "CaptionWindowColor", NULL};
    return MACopyColor(d, b, keys, 0, 0, 0, 0);
}

static CGFloat MAOpacity(MACaptionAppearanceDomain domain, MACaptionAppearanceBehavior *behavior,
    CGFloat fallback, const char *const *keys)
{
    if (behavior) *behavior = kMACaptionAppearanceBehaviorUseContentIfAvailable;
    CGFloat value = domain == kMACaptionAppearanceDomainUser ? MAFloatPreference(fallback, keys) : fallback;
    return fmin(1.0, fmax(0.0, value));
}

CGFloat MACaptionAppearanceGetForegroundOpacity(MACaptionAppearanceDomain d, MACaptionAppearanceBehavior *b)
{
    static const char *const keys[] = {"CaptioningForegroundOpacity", "CaptionForegroundOpacity", NULL};
    return MAOpacity(d, b, 1.0, keys);
}
CGFloat MACaptionAppearanceGetBackgroundOpacity(MACaptionAppearanceDomain d, MACaptionAppearanceBehavior *b)
{
    static const char *const keys[] = {"CaptioningBackgroundOpacity", "CaptionBackgroundOpacity", NULL};
    CGFloat fallback = MAProfileForDomain(d) == MAProfileKindClassic ? 1.0 : 0.0;
    return MAOpacity(d, b, fallback, keys);
}
CGFloat MACaptionAppearanceGetWindowOpacity(MACaptionAppearanceDomain d, MACaptionAppearanceBehavior *b)
{
    static const char *const keys[] = {"CaptioningWindowOpacity", "CaptionWindowOpacity", NULL};
    return MAOpacity(d, b, 0.0, keys);
}
CGFloat MACaptionAppearanceGetWindowRoundedCornerRadius(MACaptionAppearanceDomain d, MACaptionAppearanceBehavior *b)
{
    static const char *const keys[] = {"CaptioningWindowCornerRadius", "CaptionWindowCornerRadius", NULL};
    if (b) *b = kMACaptionAppearanceBehaviorUseContentIfAvailable;
    return d == kMACaptionAppearanceDomainUser ? MAFloatPreference(0.0, keys) : 0.0;
}

CTFontDescriptorRef MACaptionAppearanceCopyFontDescriptorForStyle(MACaptionAppearanceDomain domain,
    MACaptionAppearanceBehavior *behavior, MACaptionAppearanceFontStyle style)
{
    static const char *const keys[] = {"CaptioningFontName", "CaptionFontName", NULL};
    if (behavior) *behavior = kMACaptionAppearanceBehaviorUseContentIfAvailable;
    CFTypeRef value = domain == kMACaptionAppearanceDomainUser ? MAReadFirstPreference(keys) : NULL;
    MAProfileKind profile = MAProfileForDomain(domain);
    CFStringRef fallback = profile == MAProfileKindClassic ? CFSTR(".AppleSystemUIFontMonospaced-Regular") :
        (profile == MAProfileKindLargeText || profile == MAProfileKindOutlineText ? CFSTR(".AppleSystemUIFont") : CFSTR(".AppleSystemUIFontMedium"));
    CFStringRef name = value && CFGetTypeID(value) == CFStringGetTypeID() ? (CFStringRef)value : fallback;
    CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithNameAndSize(name, 0);
    if (value) CFRelease(value);
    (void)style;
    return descriptor;
}

CGFloat MACaptionAppearanceGetRelativeCharacterSize(MACaptionAppearanceDomain d, MACaptionAppearanceBehavior *b)
{
    static const char *const keys[] = {"CaptioningRelativeCharacterSize", "CaptionRelativeCharacterSize", NULL};
    if (b) *b = kMACaptionAppearanceBehaviorUseContentIfAvailable;
    MAProfileKind profile = MAProfileForDomain(d);
    CGFloat fallback = profile == MAProfileKindLargeText || profile == MAProfileKindOutlineText ? 1.5 : 1.0;
    return d == kMACaptionAppearanceDomainUser ? MAFloatPreference(fallback, keys) : 1.0;
}

MACaptionAppearanceTextEdgeStyle MACaptionAppearanceGetTextEdgeStyle(MACaptionAppearanceDomain d, MACaptionAppearanceBehavior *b)
{
    static const char *const keys[] = {"CaptioningTextEdgeStyle", "CaptionTextEdgeStyle", NULL};
    if (b) *b = kMACaptionAppearanceBehaviorUseContentIfAvailable;
    MAProfileKind profile = MAProfileForDomain(d);
    MACaptionAppearanceTextEdgeStyle fallback = profile == MAProfileKindOutlineText ?
        kMACaptionAppearanceTextEdgeStyleUniform : kMACaptionAppearanceTextEdgeStyleNone;
    return (MACaptionAppearanceTextEdgeStyle)MAIntegerPreference(fallback,
        d == kMACaptionAppearanceDomainUser ? keys : (const char *const[]){NULL});
}

CFArrayRef MACaptionAppearanceCopyProfileIDs(void)
{
    const void *profiles[] = {kProfileClassic, kProfileLargeText, kProfileOutlineText, kProfileDefault};
    return CFArrayCreate(kCFAllocatorDefault, profiles, sizeof(profiles) / sizeof(profiles[0]), &kCFTypeArrayCallBacks);
}

void MACaptionAppearanceSetActiveProfileID(CFStringRef profileID)
{
    if (MAProfileName(profileID)) MAWritePreference("CaptioningActiveProfileID", profileID);
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnonnull"
CFStringRef MACaptionAppearanceCopyActiveProfileID(void)
{
    if (gProfileOverride) return CFRetain(gProfileOverride);
    CFTypeRef value = MAReadPreference(CFSTR("CaptioningActiveProfileID"));
    if (value && CFGetTypeID(value) == CFStringGetTypeID() && MAProfileName((CFStringRef)value)) return value;
    if (value) CFRelease(value);
    return CFRetain(kProfileDefault);
}

CFStringRef MACaptionAppearanceCopyProfileName(CFStringRef profileID)
{
    CFStringRef name = MAProfileName(profileID);
    return name ? CFRetain(name) : NULL;
}
#pragma clang diagnostic pop

void MACaptionAppearanceExecuteBlockForProfileID(CFStringRef profileID, void (^block)(void))
{
    if (!block) return;
    CFStringRef previous = gProfileOverride;
    if (profileID) gProfileOverride = CFRetain(profileID);
    else gProfileOverride = NULL;
    @try {
        block();
    } @finally {
        if (gProfileOverride) CFRelease(gProfileOverride);
        gProfileOverride = previous;
    }
}

CFArrayRef MAAudibleMediaCopyPreferredCharacteristics(void)
{
    static const char *const keys[] = {"AudibleMediaPreferredCharacteristics", "PreferredAudibleMediaCharacteristics", NULL};
    CFTypeRef value = MAReadFirstPreference(keys);
    if (value && CFGetTypeID(value) == CFArrayGetTypeID()) return value;
    if (value) CFRelease(value);
    return CFArrayCreate(kCFAllocatorDefault, NULL, 0, &kCFTypeArrayCallBacks);
}

void MACaptionAppearanceDidDisplayCaptions(CFArrayRef strings)
{
    (void)strings;
}

CFStringRef MAImageCaptioningCopyMetadataTagPath(void)
{
    return CFRetain(CFSTR("Iptc4xmpExt:ArtworkContentDescription"));
}

static CFStringRef MACopyCaptionFromMetadata(CGImageMetadataRef metadata)
{
    if (!metadata) return NULL;
    CGImageMetadataTagRef tag = CGImageMetadataCopyTagWithPath(metadata, NULL,
        CFSTR("Iptc4xmpExt:ArtworkContentDescription"));
    if (!tag) return NULL;
    CFTypeRef value = CGImageMetadataTagCopyValue(tag);
    CFRelease(tag);
    if (!value || CFGetTypeID(value) != CFStringGetTypeID()) {
        if (value) CFRelease(value);
        return NULL;
    }
    return value;
}

CFStringRef MAImageCaptioningCopyCaption(CFURLRef url, CFErrorRef *error)
{
    if (error) *error = NULL;
    if (!url) return NULL;
    CGImageSourceRef source = CGImageSourceCreateWithURL(url, NULL);
    if (!source) return NULL;
    CGImageMetadataRef metadata = CGImageSourceCopyMetadataAtIndex(source, 0, NULL);
    CFStringRef caption = MACopyCaptionFromMetadata(metadata);
    if (metadata) CFRelease(metadata);
    CFRelease(source);
    return caption;
}

bool MAImageCaptioningSetCaption(CFURLRef url, CFStringRef caption, CFErrorRef *error)
{
    if (error) *error = NULL;
    if (!url || !caption || CFGetTypeID(caption) != CFStringGetTypeID()) return false;
    CGImageSourceRef source = CGImageSourceCreateWithURL(url, NULL);
    if (!source || CGImageSourceGetCount(source) == 0) {
        if (source) CFRelease(source);
        return false;
    }
    CFStringRef type = CGImageSourceGetType(source);
    CFStringRef pathString = CFURLCopyFileSystemPath(url, kCFURLPOSIXPathStyle);
    char path[PATH_MAX] = {0}, temporary[PATH_MAX] = {0};
    bool ok = pathString && CFStringGetCString(pathString, path, sizeof(path), kCFStringEncodingUTF8);
    if (ok && snprintf(temporary, sizeof(temporary), "%s.finch-caption-XXXXXX", path) >= (int)sizeof(temporary))
        ok = false;
    struct stat original;
    bool haveOriginal = ok && stat(path, &original) == 0;
    int fd = ok ? mkstemp(temporary) : -1;
    if (fd < 0) ok = false;
    if (fd >= 0 && haveOriginal) fchmod(fd, original.st_mode & 07777);
    if (fd >= 0) close(fd);
    CFURLRef destinationURL = ok ? CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault,
        (const UInt8 *)temporary, strlen(temporary), false) : NULL;
    CGImageDestinationRef destination = destinationURL ? CGImageDestinationCreateWithURL(destinationURL, type,
        CGImageSourceGetCount(source), NULL) : NULL;
    CGImageMetadataRef metadata = CGImageSourceCopyMetadataAtIndex(source, 0, NULL);
    CGMutableImageMetadataRef writable = metadata ? CGImageMetadataCreateMutableCopy(metadata) : CGImageMetadataCreateMutable();
    CGImageMetadataTagRef tag = CGImageMetadataTagCreate(CFSTR("http://iptc.org/std/Iptc4xmpExt/2008-02-29/"),
        CFSTR("Iptc4xmpExt"), CFSTR("ArtworkContentDescription"), kCGImageMetadataTypeString, caption);
    ok = ok && destination && writable && tag &&
        CGImageMetadataSetTagWithPath(writable, NULL, CFSTR("Iptc4xmpExt:ArtworkContentDescription"), tag);
    if (ok) {
        CFStringRef metadataKey = kCGImageDestinationMetadata;
        const void *keys[] = {metadataKey};
        const void *values[] = {writable};
        CFDictionaryRef imageOptions = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        for (size_t i = 0; i < CGImageSourceGetCount(source); i++)
            CGImageDestinationAddImageFromSource(destination, source, i, i == 0 ? imageOptions : NULL);
        ok = CGImageDestinationFinalize(destination);
        CFRelease(imageOptions);
    }
    if (ok) {
        if (haveOriginal) chmod(temporary, original.st_mode & 07777);
        ok = rename(temporary, path) == 0;
    }
    if (!ok && temporary[0]) unlink(temporary);
    if (tag) CFRelease(tag);
    if (writable) CFRelease(writable);
    if (metadata) CFRelease(metadata);
    if (destination) CFRelease(destination);
    if (destinationURL) CFRelease(destinationURL);
    if (pathString) CFRelease(pathString);
    CFRelease(source);
    return ok;
}
