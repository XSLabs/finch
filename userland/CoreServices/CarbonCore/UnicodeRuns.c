/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Unicode-to-text runs backed by CoreFoundation's public text encodings. */
#include "CarbonCore_Finch.h"
#include <CoreFoundation/CFString.h>

#define UNICODE_RUN_MAGIC 0x466e5572u

struct OpaqueUnicodeToTextRunInfo {
    UInt32 magic;
    ItemCount count;
    TextEncoding *encodings;
    UnicodeToTextFallbackUPP fallback;
    OptionBits fallbackOptions;
    LogicalAddress fallbackInfo;
};

static CFStringEncoding
run_encoding(TextEncoding encoding)
{
    TextEncodingBase base = GetTextEncodingBase(encoding);
    if (base == kTextEncodingUnicodeDefault || base == kTextEncodingUnicodeV2_0 ||
        base == kTextEncodingUnicodeV3_0 || (base >= kTextEncodingUnicodeV1_1 && base <= kTextEncodingUnicodeV10_0)) {
        TextEncodingFormat format = GetTextEncodingFormat(encoding);
        if (format == kUnicodeUTF8Format)
            return kCFStringEncodingUTF8;
        if (format == kUnicode32BitFormat)
            return kCFStringEncodingUTF32LE;
        return kCFStringEncodingUTF16LE;
    }
    return (CFStringEncoding)base;
}

static Boolean
run_encoding_available(TextEncoding encoding)
{
    return CFStringIsEncodingAvailable(run_encoding(encoding));
}

static OSStatus
run_create(const TextEncoding *encodings, ItemCount count, UnicodeToTextRunInfo *out)
{
    if (!out || !encodings || count == 0 || count > SIZE_MAX / sizeof *encodings)
        return paramErr;
    *out = NULL;
    struct OpaqueUnicodeToTextRunInfo *info = calloc(1, sizeof *info);
    if (!info)
        return memFullErr;
    info->encodings = malloc((size_t)count * sizeof *info->encodings);
    if (!info->encodings) {
        free(info);
        return memFullErr;
    }
    for (ItemCount i = 0; i < count; i++) {
        if (!run_encoding_available(encodings[i])) {
            free(info->encodings);
            free(info);
            return paramErr;
        }
        info->encodings[i] = encodings[i];
    }
    info->magic = UNICODE_RUN_MAGIC;
    info->count = count;
    *out = info;
    return noErr;
}

OSStatus
CreateUnicodeToTextRunInfo(ItemCount count, const UnicodeMapping mappings[], UnicodeToTextRunInfo *out)
{
    if (!mappings || !count)
        return paramErr;
    TextEncoding *encodings = malloc((size_t)count * sizeof *encodings);
    if (!encodings)
        return memFullErr;
    for (ItemCount i = 0; i < count; i++) {
        if (mappings[i].unicodeEncoding != kTextEncodingUnicodeDefault &&
            mappings[i].unicodeEncoding != kTextEncodingUnicodeV2_0 &&
            mappings[i].unicodeEncoding != kTextEncodingUnicodeV3_0) {
            free(encodings);
            return paramErr;
        }
        encodings[i] = mappings[i].otherEncoding;
    }
    OSStatus status = run_create(encodings, count, out);
    free(encodings);
    return status;
}

OSStatus
CreateUnicodeToTextRunInfoByEncoding(ItemCount count, const TextEncoding encodings[], UnicodeToTextRunInfo *out)
{
    return run_create(encodings, count, out);
}

OSStatus
CreateUnicodeToTextRunInfoByScriptCode(ItemCount count, const ScriptCode scripts[], UnicodeToTextRunInfo *out)
{
    if (!scripts || !count)
        return paramErr;
    TextEncoding *encodings = malloc((size_t)count * sizeof *encodings);
    if (!encodings)
        return memFullErr;
    for (ItemCount i = 0; i < count; i++) {
        if (GetTextEncodingFromScriptInfo(scripts[i], kTextLanguageDontCare, kTextRegionDontCare, &encodings[i]) != noErr) {
            free(encodings);
            return paramErr;
        }
    }
    OSStatus status = run_create(encodings, count, out);
    free(encodings);
    return status;
}

OSStatus
DisposeUnicodeToTextRunInfo(UnicodeToTextRunInfo *runInfo)
{
    if (!runInfo || !*runInfo || (*runInfo)->magic != UNICODE_RUN_MAGIC)
        return paramErr;
    struct OpaqueUnicodeToTextRunInfo *info = *runInfo;
    info->magic = 0;
    free(info->encodings);
    free(info);
    *runInfo = NULL;
    return noErr;
}

OSStatus
ResetUnicodeToTextRunInfo(UnicodeToTextRunInfo runInfo)
{
    return runInfo && runInfo->magic == UNICODE_RUN_MAGIC ? noErr : paramErr;
}

OSStatus
SetFallbackUnicodeToTextRun(UnicodeToTextRunInfo runInfo, UnicodeToTextFallbackUPP fallback,
                            OptionBits options, LogicalAddress info)
{
    if (!runInfo || runInfo->magic != UNICODE_RUN_MAGIC ||
        (options & ~(kUnicodeFallbackSequencingMask | kUnicodeFallbackInterruptSafeMask)))
        return paramErr;
    runInfo->fallback = fallback;
    runInfo->fallbackOptions = options;
    runInfo->fallbackInfo = info;
    return noErr;
}

static CFIndex
next_scalar_end(CFStringRef string, CFIndex start)
{
    CFIndex end = start + 1;
    UniChar first = CFStringGetCharacterAtIndex(string, start);
    if (CFStringIsSurrogateHighCharacter(first) && end < CFStringGetLength(string) &&
        CFStringIsSurrogateLowCharacter(CFStringGetCharacterAtIndex(string, end)))
        end++;
    return end;
}

OSStatus
ConvertFromUnicodeToTextRun(UnicodeToTextRunInfo runInfo, ByteCount sourceLength, const UniChar source[],
                            OptionBits controlFlags, ItemCount offsetCount, const ByteOffset offsets[],
                            ItemCount *offsetOutCount, ByteOffset offsetOut[], ByteCount outputCapacity,
                            ByteCount *inputRead, ByteCount *outputLength, LogicalAddress output,
                            ItemCount runCapacity, ItemCount *runOutCount, TextEncodingRun runs[])
{
    if (!runInfo || runInfo->magic != UNICODE_RUN_MAGIC || (!source && sourceLength) ||
        (!output && outputCapacity) || (offsetCount && (!offsets || !offsetOut)) ||
        (runCapacity && !runs))
        return paramErr;
    /* Offsets need stateful source-to-output mapping, which this converter does not claim. */
    if (offsetCount)
        return paramErr;
    if (offsetOutCount)
        *offsetOutCount = 0;
    if (runOutCount)
        *runOutCount = 0;
    if (inputRead)
        *inputRead = 0;
    if (outputLength)
        *outputLength = 0;

    CFIndex units = (CFIndex)(sourceLength / sizeof(UniChar));
    CFStringRef text = CFStringCreateWithCharacters(NULL, source, units);
    if (!text)
        return memFullErr;
    CFIndex cursor = 0;
    ByteCount written = 0, read = 0;
    ItemCount madeRuns = 0;
    TextEncoding previous = 0;
    OSStatus status = noErr;
    while (cursor < units) {
        CFIndex end = next_scalar_end(text, cursor);
        CFRange range = CFRangeMake(cursor, end - cursor);
        UniChar scalar[2] = {0, 0};
        CFStringGetCharacters(text, range, scalar);
        CFStringRef piece = CFStringCreateWithCharacters(NULL, scalar, (CFIndex)(end - cursor));
        if (!piece) {
            status = memFullErr;
            break;
        }

        TextEncoding selected = 0;
        Boolean haveSelected = false;
        UInt8 bytes[16] = {0};
        CFIndex byteCount = 0;
        for (ItemCount i = 0; i < runInfo->count; i++) {
            CFIndex converted = 0;
            CFIndex amount = CFStringGetBytes(piece, CFRangeMake(0, end - cursor), run_encoding(runInfo->encodings[i]),
                                               0, false, bytes, sizeof bytes, &converted);
            if (converted == end - cursor && amount > 0) {
                selected = runInfo->encodings[i];
                haveSelected = true;
                byteCount = amount;
                break;
            }
        }

        if (!haveSelected && runInfo->fallback) {
            selected = runInfo->encodings[0];
            UnicodeMapping mapping = { kTextEncodingUnicodeDefault, selected, kUnicodeUseLatestMapping };
            ByteCount sourceConverted = 0, outputConverted = 0;
            OSStatus fallbackStatus = runInfo->fallback(scalar, (ByteCount)(end - cursor) * sizeof(UniChar),
                                                        &sourceConverted, bytes, sizeof bytes, &outputConverted,
                                                        runInfo->fallbackInfo, &mapping);
            if (fallbackStatus == noErr && sourceConverted == (ByteCount)(end - cursor) * sizeof(UniChar)) {
                haveSelected = true;
                byteCount = outputConverted;
            } else {
                selected = 0;
            }
        }
        if (!haveSelected && (controlFlags & kUnicodeUseFallbacksMask)) {
            selected = runInfo->encodings[0];
            haveSelected = true;
            bytes[0] = '?';
            byteCount = 1;
        }
        CFRelease(piece);
        if (!haveSelected) {
            status = kTECUnmappableElementErr;
            break;
        }
        if (written + (ByteCount)byteCount > outputCapacity) {
            status = kTECOutputBufferFullStatus;
            break;
        }
        if (madeRuns == 0 || selected != previous) {
            if (madeRuns >= runCapacity) {
                status = kTECArrayFullErr;
                break;
            }
            runs[madeRuns++] = (TextEncodingRun){ (ByteOffset)written, selected };
            previous = selected;
        }
        memcpy((UInt8 *)output + written, bytes, (size_t)byteCount);
        written += (ByteCount)byteCount;
        cursor = end;
        read = (ByteCount)cursor * sizeof(UniChar);
    }
    if (inputRead)
        *inputRead = read;
    if (outputLength)
        *outputLength = written;
    if (runOutCount)
        *runOutCount = madeRuns;
    CFRelease(text);
    return status;
}

OSStatus
ConvertFromUnicodeToScriptCodeRun(UnicodeToTextRunInfo runInfo, ByteCount sourceLength, const UniChar source[],
                                  OptionBits controlFlags, ItemCount offsetCount, const ByteOffset offsetArray[],
                                  ItemCount *offsetOutCount, ByteOffset offsetOut[], ByteCount outputCapacity,
                                  ByteCount *inputRead, ByteCount *outputLength, LogicalAddress output,
                                  ItemCount runCapacity, ItemCount *runOutCount, ScriptCodeRun scriptRuns[])
{
    if ((!source && sourceLength) || (runCapacity && !scriptRuns) || (offsetCount && !offsetArray))
        return paramErr;
    if (runCapacity > SIZE_MAX / sizeof(TextEncodingRun))
        return paramErr;
    TextEncodingRun *encodingRuns = runCapacity ? calloc((size_t)runCapacity, sizeof *encodingRuns) : NULL;
    if (runCapacity && !encodingRuns)
        return memFullErr;
    ItemCount encodingRunCount = 0;
    OSStatus status = ConvertFromUnicodeToTextRun(runInfo, sourceLength, source, controlFlags,
        offsetCount, offsetArray, offsetOutCount, offsetOut, outputCapacity, inputRead,
        outputLength, output, runCapacity, &encodingRunCount, encodingRuns);
    ItemCount converted = encodingRunCount < runCapacity ? encodingRunCount : runCapacity;
    for (ItemCount i = 0; i < converted; i++) {
        ScriptCode script = 0;
        OSStatus scriptStatus = GetScriptInfoFromTextEncoding(encodingRuns[i].textEncoding, &script, NULL);
        if (scriptStatus != noErr) {
            status = scriptStatus;
            converted = i;
            break;
        }
        scriptRuns[i].offset = encodingRuns[i].offset;
        scriptRuns[i].script = script;
    }
    if (runOutCount)
        *runOutCount = converted;
    free(encodingRuns);
    return status;
}
