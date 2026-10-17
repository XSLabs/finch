/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* The older Unicode text-break and type-select helpers, backed by CFString. */
#include "CarbonCore_Finch.h"
#include <CoreFoundation/CFStringTokenizer.h>

#define TEXT_BREAK_MAGIC 0x466e5462u
#define TYPE_SELECT_MAGIC 0x466e5473u
#define TYPE_SELECT_TIMEOUT 1.5

struct OpaqueTextBreakLocatorRef {
    UInt32 magic;
    CFLocaleRef locale;
    UCTextBreakType supported;
};

struct OpaqueUCTypeSelectRef {
    UInt32 magic;
    CFLocaleRef locale;
    UCCollateOptions options;
    CFMutableStringRef buffer;
    double lastEventTime;
};

static CFStringCompareFlags
collation_flags(UCCollateOptions options, Boolean localized)
{
    CFStringCompareFlags flags = localized ? kCFCompareLocalized : 0;
    if (options & kUCCollateCaseInsensitiveMask)
        flags |= kCFCompareCaseInsensitive;
    if (options & kUCCollateDiacritInsensitiveMask)
        flags |= kCFCompareDiacriticInsensitive;
    if (options & kUCCollateWidthInsensitiveMask)
        flags |= kCFCompareWidthInsensitive;
    if (options & kUCCollateDigitsAsNumberMask)
        flags |= kCFCompareNumerically;
    return flags;
}

static CFStringRef
text_from_chars(const UniChar *chars, UniCharCount length)
{
    if (!chars && length)
        return NULL;
    return CFStringCreateWithCharacters(NULL, chars, length);
}

OSStatus
UCCompareTextNoLocale(UCCollateOptions options, const UniChar *text1Ptr, UniCharCount text1Length,
                      const UniChar *text2Ptr, UniCharCount text2Length, Boolean *equivalent, SInt32 *order)
{
    if ((!text1Ptr && text1Length) || (!text2Ptr && text2Length))
        return paramErr;
    CFStringRef a = text_from_chars(text1Ptr, text1Length);
    CFStringRef b = text_from_chars(text2Ptr, text2Length);
    if (!a || !b) {
        if (a) CFRelease(a);
        if (b) CFRelease(b);
        return memFullErr;
    }
    CFComparisonResult result = CFStringCompare(a, b, collation_flags(options, false));
    if (equivalent)
        *equivalent = result == kCFCompareEqualTo;
    if (order)
        *order = result == kCFCompareLessThan ? -1 : result == kCFCompareGreaterThan ? 1 : 0;
    CFRelease(a);
    CFRelease(b);
    return noErr;
}

OSStatus
UCCreateTextBreakLocator(LocaleRef locale, LocaleOperationVariant opVariant, UCTextBreakType breakTypes,
                         TextBreakLocatorRef *breakRef)
{
    if (!breakRef)
        return paramErr;
    if (locale && !_FinchLocaleValue(locale))
        return paramErr;
    struct OpaqueTextBreakLocatorRef *locator = calloc(1, sizeof *locator);
    if (!locator)
        return memFullErr;
    locator->magic = TEXT_BREAK_MAGIC;
    CFLocaleRef value = locale ? _FinchLocaleValue(locale) : CFLocaleCopyCurrent();
    locator->locale = value ? (CFLocaleRef)CFRetain(value) : NULL;
    locator->supported = breakTypes;
    *breakRef = locator;
    return noErr;
}

OSStatus
UCDisposeTextBreakLocator(TextBreakLocatorRef *breakRef)
{
    if (!breakRef || !*breakRef || (*breakRef)->magic != TEXT_BREAK_MAGIC)
        return paramErr;
    struct OpaqueTextBreakLocatorRef *locator = *breakRef;
    if (locator->locale)
        CFRelease(locator->locale);
    locator->magic = 0;
    free(locator);
    *breakRef = NULL;
    return noErr;
}

static CFOptionFlags
tokenizer_unit(UCTextBreakType type)
{
    if (type == kUCTextBreakWordMask)
        return kCFStringTokenizerUnitWord;
    if (type == kUCTextBreakLineMask)
        return kCFStringTokenizerUnitLineBreak;
    if (type == kUCTextBreakParagraphMask)
        return kCFStringTokenizerUnitParagraph;
    return 0;
}

OSStatus
UCFindTextBreak(TextBreakLocatorRef breakRef, UCTextBreakType breakType, UCTextBreakOptions options,
                const UniChar *textPtr, UniCharCount textLength, UniCharArrayOffset startOffset,
                UniCharArrayOffset *breakOffset)
{
    if (!breakRef || breakRef->magic != TEXT_BREAK_MAGIC || !breakOffset ||
        ((!textPtr && textLength) || startOffset > textLength || !(breakRef->supported & breakType) ||
         (breakType & (breakType - 1))))
        return paramErr;
    CFStringRef text = text_from_chars(textPtr, textLength);
    if (!text)
        return memFullErr;
    CFIndex offset = startOffset;
    Boolean backwards = (options & kUCTextBreakGoBackwardsMask) != 0;
    if (breakType == kUCTextBreakCharMask) {
        if (backwards && offset > 0)
            offset--;
        else if (!backwards && offset < textLength) {
            UniChar c = CFStringGetCharacterAtIndex(text, offset++);
            if (CFStringIsSurrogateHighCharacter(c) && offset < textLength &&
                CFStringIsSurrogateLowCharacter(CFStringGetCharacterAtIndex(text, offset)))
                offset++;
        }
    } else if (breakType == kUCTextBreakClusterMask) {
        if (textLength) {
            CFIndex index = offset == textLength && backwards ? offset - 1 : offset;
            if (index < textLength) {
                CFRange range = CFStringGetRangeOfComposedCharactersAtIndex(text, index);
                offset = backwards ? range.location : range.location + range.length;
            }
        }
    } else {
        CFOptionFlags unit = tokenizer_unit(breakType);
        if (!unit) {
            CFRelease(text);
            return paramErr;
        }
        CFStringTokenizerRef tokenizer = CFStringTokenizerCreate(NULL, text, CFRangeMake(0, textLength), unit,
                                                                  breakRef->locale);
        if (!tokenizer) {
            CFRelease(text);
            return memFullErr;
        }
        CFStringTokenizerGoToTokenAtIndex(tokenizer, offset < textLength ? offset : textLength - (textLength != 0));
        CFRange range = CFStringTokenizerGetCurrentTokenRange(tokenizer);
        if (range.location != kCFNotFound)
            offset = backwards ? range.location : range.location + range.length;
        else
            offset = backwards ? 0 : textLength;
        CFRelease(tokenizer);
    }
    *breakOffset = (UniCharArrayOffset)offset;
    CFRelease(text);
    return noErr;
}

static Boolean
valid_selector(UCTypeSelectRef ref)
{
    return ref && ref->magic == TYPE_SELECT_MAGIC;
}

OSStatus
UCTypeSelectCreateSelector(LocaleRef locale, LocaleOperationVariant opVariant, UCCollateOptions options,
                           UCTypeSelectRef *newSelector)
{
    if (!newSelector || (locale && !_FinchLocaleValue(locale)))
        return paramErr;
    struct OpaqueUCTypeSelectRef *selector = calloc(1, sizeof *selector);
    if (!selector)
        return memFullErr;
    selector->magic = TYPE_SELECT_MAGIC;
    selector->locale = locale ? (CFLocaleRef)CFRetain(_FinchLocaleValue(locale)) : CFLocaleCopyCurrent();
    selector->options = options;
    selector->buffer = CFStringCreateMutable(NULL, 0);
    if (!selector->buffer) {
        if (selector->locale) CFRelease(selector->locale);
        free(selector);
        return memFullErr;
    }
    *newSelector = selector;
    return noErr;
}

OSStatus
UCTypeSelectFlushSelectorData(UCTypeSelectRef ref)
{
    if (!valid_selector(ref))
        return paramErr;
    CFStringDelete(ref->buffer, CFRangeMake(0, CFStringGetLength(ref->buffer)));
    ref->lastEventTime = 0;
    return noErr;
}

OSStatus
UCTypeSelectReleaseSelector(UCTypeSelectRef *ref)
{
    if (!ref || !valid_selector(*ref))
        return paramErr;
    struct OpaqueUCTypeSelectRef *selector = *ref;
    CFRelease(selector->buffer);
    if (selector->locale) CFRelease(selector->locale);
    selector->magic = 0;
    free(selector);
    *ref = NULL;
    return noErr;
}

Boolean
UCTypeSelectWouldResetBuffer(UCTypeSelectRef inRef, CFStringRef inText, double inEventTime)
{
    if (!valid_selector(inRef))
        return false;
    if (inRef->lastEventTime && inEventTime - inRef->lastEventTime > TYPE_SELECT_TIMEOUT)
        return true;
    if (!inText)
        return false;
    return CFStringFind(inText, CFSTR("\b"), 0).location != kCFNotFound ||
           CFStringFind(inText, CFSTR("\r"), 0).location != kCFNotFound ||
           CFStringFind(inText, CFSTR("\n"), 0).location != kCFNotFound ||
           CFStringFind(inText, CFSTR("\x1b"), 0).location != kCFNotFound;
}

OSStatus
UCTypeSelectAddKeyToSelector(UCTypeSelectRef inRef, CFStringRef inText, double inEventTime, Boolean *updateFlag)
{
    if (!valid_selector(inRef) || !inText || !updateFlag)
        return paramErr;
    *updateFlag = false;
    if (UCTypeSelectWouldResetBuffer(inRef, inText, inEventTime)) {
        UCTypeSelectFlushSelectorData(inRef);
        inRef->lastEventTime = inEventTime;
        return noErr;
    }
    if (inRef->lastEventTime && inEventTime - inRef->lastEventTime > TYPE_SELECT_TIMEOUT)
        UCTypeSelectFlushSelectorData(inRef);
    CFStringAppend(inRef->buffer, inText);
    inRef->lastEventTime = inEventTime;
    *updateFlag = CFStringGetLength(inText) != 0;
    return noErr;
}

static CFComparisonResult
selector_compare(struct OpaqueUCTypeSelectRef *selector, CFStringRef a, CFStringRef b)
{
    return CFStringCompareWithOptionsAndLocale(a, b, CFRangeMake(0, CFStringGetLength(a)),
                                                collation_flags(selector->options, true), selector->locale);
}

OSStatus
UCTypeSelectCompare(UCTypeSelectRef ref, CFStringRef inText, UCTypeSelectCompareResult *result)
{
    if (!valid_selector(ref) || !inText || !result)
        return paramErr;
    if (!CFStringGetLength(ref->buffer))
        return kUCTSNoKeysAddedToObjectErr;
    CFComparisonResult order = selector_compare(ref, ref->buffer, inText);
    *result = order == kCFCompareLessThan ? -1 : order == kCFCompareGreaterThan ? 1 : 0;
    return noErr;
}

static OSStatus
selector_find(UCTypeSelectRef ref, CFStringRef current, UInt32 listSize, void *listDataPtr, void *refcon,
              IndexToUCStringUPP userUPP, UInt32 *closestItem, Boolean seekNext)
{
    if (!valid_selector(ref) || !userUPP || !closestItem || !listSize)
        return paramErr;
    if (!CFStringGetLength(ref->buffer))
        return kUCTSNoKeysAddedToObjectErr;
    UInt32 limit = listSize == kUCTypeSelectMaxListSize ? 65536 : listSize;
    Boolean foundAny = false, foundMatch = false;
    UInt32 bestIndex = 0;
    CFStringRef bestString = NULL;
    CFIndex currentIndex = -1;
    for (UInt32 index = 0; index < limit; index++) {
        CFStringRef candidate = NULL;
        UCTypeSelectOptions options = 0;
        if (!userUPP(index, listDataPtr, refcon, &candidate, &options))
            break;
        if (!candidate)
            continue;
        foundAny = true;
        if (current && CFStringCompare(current, candidate, 0) == kCFCompareEqualTo)
            currentIndex = index;
        if (seekNext && current) {
            CFComparisonResult order = selector_compare(ref, current, candidate);
            if ((ref->magic == TYPE_SELECT_MAGIC) &&
                ((seekNext && order == kCFCompareLessThan) || (!seekNext && order == kCFCompareGreaterThan))) {
                if (!foundMatch || (seekNext ? selector_compare(ref, candidate, bestString) == kCFCompareLessThan
                                             : selector_compare(ref, candidate, bestString) == kCFCompareGreaterThan)) {
                    if (bestString && (options & kUCTSOptionsReleaseStringMask)) CFRelease(bestString);
                    bestString = candidate;
                    bestIndex = index;
                    foundMatch = true;
                    continue;
                }
            }
        } else {
            CFRange found = CFRangeMake(kCFNotFound, 0);
            Boolean hasPrefix = CFStringFindWithOptionsAndLocale(
                candidate, ref->buffer, CFRangeMake(0, CFStringGetLength(candidate)),
                kCFCompareAnchored | collation_flags(ref->options, true), ref->locale, &found);
            if (hasPrefix && found.location == 0) {
                bestIndex = index;
                foundMatch = true;
                if (options & kUCTSOptionsReleaseStringMask) CFRelease(candidate);
                break;
            }
            if (!foundMatch && selector_compare(ref, ref->buffer, candidate) != kCFCompareGreaterThan) {
                bestIndex = index;
                foundMatch = true;
            }
        }
        if (options & kUCTSOptionsReleaseStringMask)
            CFRelease(candidate);
    }
    if (bestString) {
        /* The selected callback value was kept while finding its neighbor. */
        CFRelease(bestString);
    }
    if (!foundAny)
        return kUCTSSearchListErr;
    if (!foundMatch && seekNext && currentIndex >= 0) {
        *closestItem = (UInt32)currentIndex;
        return noErr;
    }
    if (!foundMatch)
        return kUCTSSearchListErr;
    *closestItem = bestIndex;
    return noErr;
}

OSStatus
UCTypeSelectFindItem(UCTypeSelectRef ref, UInt32 listSize, void *listDataPtr, void *refcon,
                     IndexToUCStringUPP userUPP, UInt32 *closestItem)
{
    return selector_find(ref, NULL, listSize, listDataPtr, refcon, userUPP, closestItem, false);
}

OSStatus
UCTypeSelectWalkList(UCTypeSelectRef ref, CFStringRef currSelect, UCTSWalkDirection direction, UInt32 listSize,
                     void *listDataPtr, void *refcon, IndexToUCStringUPP userUPP, UInt32 *closestItem)
{
    if (!currSelect || direction > kUCTSDirectionPrevious)
        return paramErr;
    return selector_find(ref, currSelect, listSize, listDataPtr, refcon, userUPP, closestItem,
                         direction == kUCTSDirectionNext);
}
