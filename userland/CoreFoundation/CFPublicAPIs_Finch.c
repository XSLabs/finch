/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* CoreFoundation public C entry points that are newer than the pinned
 * swift-corelibs source. */
#include <CoreFoundation/CoreFoundation.h>
#include <malloc/_malloc_type.h>
#include <stdint.h>

#define FINCH_EXPORT CF_EXPORT

static Boolean
uses_system_allocator(CFAllocatorRef allocator)
{
    if (!allocator)
        allocator = CFAllocatorGetDefault();
    return allocator == kCFAllocatorSystemDefault;
}

FINCH_EXPORT void *
CFAllocatorAllocateTyped(CFAllocatorRef allocator, CFIndex size, unsigned long long descriptor, CFOptionFlags hint)
{
    if (size <= 0)
        return NULL;
    if (uses_system_allocator(allocator))
        return malloc_type_malloc((size_t)size, (malloc_type_id_t)descriptor);
    return CFAllocatorAllocate(allocator, size, hint);
}

FINCH_EXPORT void *
CFAllocatorReallocateTyped(CFAllocatorRef allocator, void *ptr, CFIndex newsize, unsigned long long descriptor, CFOptionFlags hint)
{
    if (newsize <= 0 || (!ptr && newsize <= 0))
        return CFAllocatorReallocate(allocator, ptr, newsize, hint);
    if (!ptr)
        return CFAllocatorAllocateTyped(allocator, newsize, descriptor, hint);
    if (uses_system_allocator(allocator))
        return malloc_type_realloc(ptr, (size_t)newsize, (malloc_type_id_t)descriptor);
    return CFAllocatorReallocate(allocator, ptr, newsize, hint);
}

FINCH_EXPORT void *
CFAllocatorAllocateBytes(CFAllocatorRef allocator, CFIndex size, CFOptionFlags hint)
{
    return CFAllocatorAllocateTyped(allocator, size, 0, hint);
}

FINCH_EXPORT void *
CFAllocatorReallocateBytes(CFAllocatorRef allocator, void *ptr, CFIndex newsize, CFOptionFlags hint)
{
    return CFAllocatorReallocateTyped(allocator, ptr, newsize, 0, hint);
}

/* The pinned CF already has the validator and its error reporting; this is
 * the va_list entry point used by newer SDK clients. */
extern CFStringRef CFStringCreateStringWithValidatedFormat(CFAllocatorRef, CFDictionaryRef, CFStringRef, CFStringRef, va_list,
    CFErrorRef *);
extern CFStringRef CFBundleCopyLocalizedStringForLocalization(CFBundleRef, CFStringRef, CFStringRef, CFStringRef, CFStringRef);

FINCH_EXPORT CFStringRef
CFStringCreateStringWithValidatedFormatAndArguments(CFAllocatorRef allocator, CFDictionaryRef options, CFStringRef validSpecifiers,
    CFStringRef format, va_list arguments, CFErrorRef *error)
{
    return CFStringCreateStringWithValidatedFormat(allocator, options, validSpecifiers, format, arguments, error);
}

/* Pass an explicit preference list through the same matcher and table reader
 * used by CFBundle's established localization APIs. */
FINCH_EXPORT CFStringRef
CFBundleCopyLocalizedStringForLocalizations(CFBundleRef bundle, CFStringRef key, CFStringRef value, CFStringRef tableName,
    CFArrayRef localizations)
{
    if (!bundle || !key)
        return NULL;
    if (!localizations || CFArrayGetCount(localizations) == 0)
        return CFBundleCopyLocalizedString(bundle, key, value, tableName);

    CFArrayRef available = CFBundleCopyBundleLocalizations(bundle);
    CFArrayRef matched = available ? CFBundleCopyLocalizationsForPreferences(available, localizations) : NULL;
    CFStringRef result = NULL;
    if (matched && CFArrayGetCount(matched) > 0) {
        CFStringRef localization = (CFStringRef)CFArrayGetValueAtIndex(matched, 0);
        result = CFBundleCopyLocalizedStringForLocalization(bundle, key, value, tableName, localization);
    } else {
        result = CFBundleCopyLocalizedString(bundle, key, value, tableName);
    }
    if (matched)
        CFRelease(matched);
    if (available)
        CFRelease(available);
    return result;
}

#define STRING_CONSTANT(name, value) FINCH_EXPORT const CFStringRef name = CFSTR(value)

STRING_CONSTANT(kCFBanglaCalendar, "bangla");
STRING_CONSTANT(kCFDangiCalendar, "dangi");
STRING_CONSTANT(kCFGujaratiCalendar, "gujarati");
STRING_CONSTANT(kCFKannadaCalendar, "kannada");
STRING_CONSTANT(kCFMalayalamCalendar, "malayalam");
STRING_CONSTANT(kCFMarathiCalendar, "marathi");
STRING_CONSTANT(kCFOdiaCalendar, "odia");
STRING_CONSTANT(kCFTamilCalendar, "tamil");
STRING_CONSTANT(kCFTeluguCalendar, "telugu");
STRING_CONSTANT(kCFVietnameseCalendar, "vietnamese");
STRING_CONSTANT(kCFVikramCalendar, "vikram");

/* These keys are data only. The notification calls themselves need the
 * UserNotification service, which Finch does not provide. */
STRING_CONSTANT(kCFUserNotificationAlertTopMostKey, "AlertTopMost");
STRING_CONSTANT(kCFUserNotificationAlternateButtonTitleKey, "AlternateButtonTitle");
STRING_CONSTANT(kCFUserNotificationCheckBoxTitlesKey, "CheckBoxTitles");
STRING_CONSTANT(kCFUserNotificationDefaultButtonTitleKey, "DefaultButtonTitle");
STRING_CONSTANT(kCFUserNotificationIconURLKey, "IconURL");
STRING_CONSTANT(kCFUserNotificationKeyboardTypesKey, "KeyboardTypes");
STRING_CONSTANT(kCFUserNotificationLocalizationURLKey, "LocalizationURL");
STRING_CONSTANT(kCFUserNotificationOtherButtonTitleKey, "OtherButtonTitle");
STRING_CONSTANT(kCFUserNotificationPopUpSelectionKey, "PopUpSelection");
STRING_CONSTANT(kCFUserNotificationPopUpTitlesKey, "PopUpTitles");
STRING_CONSTANT(kCFUserNotificationProgressIndicatorValueKey, "ProgressIndicatorValue");
STRING_CONSTANT(kCFUserNotificationSoundURLKey, "SoundURL");
STRING_CONSTANT(kCFUserNotificationTextFieldTitlesKey, "TextFieldTitles");
STRING_CONSTANT(kCFUserNotificationTextFieldValuesKey, "TextFieldValues");
