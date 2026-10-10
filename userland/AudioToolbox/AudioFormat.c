/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * AudioToolbox's AudioFormat properties, Finch's: what a format is (its name, its
 * fields filled in, whether its packets vary), channel layouts (names, their channels,
 * bitmaps, the layouts for a number of channels, equivalence, maps between two) and
 * the codecs Finch has. The tables (AudioFormatTables.c) hold Apple's values; the
 * answers are made here. Linear PCM's names and fields are worked out, as Apple's are.
 */
#include <AudioToolbox/AudioToolbox.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

extern const unsigned char _FinchAudioFormatTables[];
extern const size_t _FinchAudioFormatTablesSize;

static CFDictionaryRef tables;
static CFMutableDictionaryRef layoutsByTag, labelsByLabel, formatsByID;

static void
load(void)
{
    CFDataRef data = CFDataCreateWithBytesNoCopy(NULL, _FinchAudioFormatTables, (CFIndex)_FinchAudioFormatTablesSize, kCFAllocatorNull);
    tables = CFPropertyListCreateWithData(NULL, data, kCFPropertyListImmutable, NULL, NULL);
    CFRelease(data);
    layoutsByTag = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    labelsByLabel = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    formatsByID = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    struct {
        CFStringRef list, key;
        CFMutableDictionaryRef into;
    } maps[] = {{CFSTR("layouts"), CFSTR("tag"), layoutsByTag}, {CFSTR("labels"), CFSTR("label"), labelsByLabel}, {CFSTR("formats"), CFSTR("format"), formatsByID}};
    for (int m = 0; m < 3; m++) {
        CFArrayRef a = tables ? CFDictionaryGetValue(tables, maps[m].list) : NULL;
        for (CFIndex i = 0; a && i < CFArrayGetCount(a); i++) {
            CFDictionaryRef d = CFArrayGetValueAtIndex(a, i);
            CFDictionarySetValue(maps[m].into, CFDictionaryGetValue(d, maps[m].key), d);
        }
    }
}

static CFDictionaryRef
entry(CFMutableDictionaryRef *map, long long key)
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, load);
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberLongLongType, &key);
    CFDictionaryRef d = CFDictionaryGetValue(*map, n);
    CFRelease(n);
    return d;
}

static long long
get_int(CFDictionaryRef d, CFStringRef key, long long otherwise)
{
    CFNumberRef n = d ? CFDictionaryGetValue(d, key) : NULL;
    long long v;
    return n && CFNumberGetValue(n, kCFNumberLongLongType, &v) ? v : otherwise;
}

/* --- formats --- */

static bool
is_pcm(const AudioStreamBasicDescription *a)
{
    return a->mFormatID == kAudioFormatLinearPCM;
}

/* Linear PCM's fields filled in, as Apple's fills them: a packed format's frame and packet
   sizes from its bits and channels; one frame a packet. */
static void
fill_pcm(AudioStreamBasicDescription *a)
{
    a->mFramesPerPacket = 1;
    if (a->mFormatFlags & kAudioFormatFlagIsPacked) {
        UInt32 channels = (a->mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? 1 : a->mChannelsPerFrame;
        a->mBytesPerFrame = channels * ((a->mBitsPerChannel + 7) / 8);
        a->mBytesPerPacket = a->mBytesPerFrame;
    }
}

/* A codec's defaults (frames a packet and the rest) at its rate and channels. */
static OSStatus
fill_codec(AudioStreamBasicDescription *a)
{
    CFDictionaryRef f = entry(&formatsByID, a->mFormatID);
    if (!f)
        return kAudioFormatUnsupportedDataFormatError;
    CFArrayRef infos = CFDictionaryGetValue(f, CFSTR("info"));
    CFDictionaryRef best = NULL;
    for (CFIndex i = 0; infos && i < CFArrayGetCount(infos); i++) {
        CFDictionaryRef info = CFArrayGetValueAtIndex(infos, i);
        if (get_int(info, CFSTR("rate"), -1) == (long long)a->mSampleRate &&
            get_int(info, CFSTR("channels"), -1) == (long long)(a->mChannelsPerFrame > 2 ? 2 : a->mChannelsPerFrame ? a->mChannelsPerFrame : 2))
            best = info;
    }
    /* (a rate not in the table: the defaults at 44.1 kHz, if the codec has them there) */
    for (CFIndex i = 0; !best && a->mSampleRate == 0 && infos && i < CFArrayGetCount(infos); i++)
        if (get_int(CFArrayGetValueAtIndex(infos, i), CFSTR("rate"), -1) == 44100)
            best = CFArrayGetValueAtIndex(infos, i);
    if (!best)
        return '!dat'; /* (a rate the codec doesn't have, as Apple's answers) */
    if (!a->mFormatFlags)
        a->mFormatFlags = (UInt32)get_int(best, CFSTR("flags"), 0);
    if (!a->mBytesPerPacket)
        a->mBytesPerPacket = (UInt32)get_int(best, CFSTR("bytesPerPacket"), 0);
    if (!a->mFramesPerPacket)
        a->mFramesPerPacket = (UInt32)get_int(best, CFSTR("framesPerPacket"), 0);
    if (!a->mBytesPerFrame)
        a->mBytesPerFrame = (UInt32)get_int(best, CFSTR("bytesPerFrame"), 0);
    if (!a->mBitsPerChannel)
        a->mBitsPerChannel = (UInt32)get_int(best, CFSTR("bitsPerChannel"), 0);
    return noErr;
}

static void
append_rate(CFMutableStringRef s, Float64 rate)
{
    if (rate == (long long)rate)
        CFStringAppendFormat(s, NULL, CFSTR(", %lld Hz"), (long long)rate);
    else
        CFStringAppendFormat(s, NULL, CFSTR(", %g Hz"), rate);
}

static CFStringRef
copy_format_name(const AudioStreamBasicDescription *a)
{
    CFMutableStringRef s = CFStringCreateMutable(NULL, 0);
    if (is_pcm(a)) {
        bool flt = a->mFormatFlags & kAudioFormatFlagIsFloat, big = a->mFormatFlags & kAudioFormatFlagIsBigEndian;
        CFStringAppendFormat(s, NULL, CFSTR("Linear PCM, %u bit "), (unsigned)a->mBitsPerChannel);
        if (a->mBitsPerChannel > 8)
            CFStringAppend(s, big ? CFSTR("big-endian ") : CFSTR("little-endian "));
        CFStringAppend(s, flt ? CFSTR("floating point") : (a->mFormatFlags & kAudioFormatFlagIsSignedInteger) ? CFSTR("signed integer")
                                                                                                          : CFSTR("unsigned integer"));
    } else {
        CFDictionaryRef f = entry(&formatsByID, a->mFormatID);
        CFStringRef full = f ? CFDictionaryGetValue(f, CFSTR("name")) : NULL;
        if (!full) {
            CFRelease(s);
            return NULL;
        }
        /* (the codec's part of the name the table has for two channels at 44.1 kHz) */
        CFRange tail = CFStringFind(full, CFSTR(", 2 channels"), kCFCompareBackwards);
        CFStringRef codec = tail.location != kCFNotFound ? CFStringCreateWithSubstring(NULL, full, CFRangeMake(0, tail.location)) : CFRetain(full);
        CFStringAppend(s, codec);
        CFRelease(codec);
    }
    CFStringAppendFormat(s, NULL, CFSTR(", %u channels"), (unsigned)a->mChannelsPerFrame);
    if (a->mSampleRate > 0)
        append_rate(s, a->mSampleRate);
    return s;
}

/* --- channel layouts --- */

static UInt32
channels_in_tag(AudioChannelLayoutTag tag)
{
    return tag & 0xffff;
}

/* The tag a layout comes to (its own, or that of its bitmap). */
static AudioChannelLayoutTag
tag_of(const AudioChannelLayout *l)
{
    if (l->mChannelLayoutTag != kAudioChannelLayoutTag_UseChannelBitmap)
        return l->mChannelLayoutTag;
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, load);
    CFArrayRef layouts = CFDictionaryGetValue(tables, CFSTR("layouts"));
    for (CFIndex i = 0; i < CFArrayGetCount(layouts); i++) {
        CFDictionaryRef d = CFArrayGetValueAtIndex(layouts, i);
        if (get_int(d, CFSTR("bitmap"), -1) == l->mChannelBitmap)
            return (AudioChannelLayoutTag)get_int(d, CFSTR("tag"), 0);
    }
    return l->mChannelLayoutTag;
}

/* A layout's channel labels: its descriptions', its tag's or its bitmap's. */
static UInt32
labels_of(const AudioChannelLayout *l, AudioChannelLabel *out, UInt32 max)
{
    if (l->mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions) {
        UInt32 n = l->mNumberChannelDescriptions < max ? l->mNumberChannelDescriptions : max;
        for (UInt32 i = 0; i < n; i++)
            out[i] = l->mChannelDescriptions[i].mChannelLabel;
        return n;
    }
    if (l->mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelBitmap) {
        UInt32 n = 0;
        for (UInt32 bit = 0; bit < 32 && n < max; bit++)
            if (l->mChannelBitmap & (1u << bit))
                out[n++] = bit + 1;
        return n;
    }
    AudioChannelLayoutTag tag = l->mChannelLayoutTag;
    if ((tag & 0xffff0000) == kAudioChannelLayoutTag_DiscreteInOrder) {
        UInt32 n = channels_in_tag(tag) < max ? channels_in_tag(tag) : max;
        for (UInt32 i = 0; i < n; i++)
            out[i] = kAudioChannelLabel_Discrete_0 + i;
        return n;
    }
    CFDictionaryRef d = entry(&layoutsByTag, tag);
    CFArrayRef labels = d ? CFDictionaryGetValue(d, CFSTR("labels")) : NULL;
    if (!labels) {
        UInt32 n = channels_in_tag(tag) < max ? channels_in_tag(tag) : max;
        for (UInt32 i = 0; i < n; i++)
            out[i] = kAudioChannelLabel_Unused;
        return n;
    }
    UInt32 n = (UInt32)CFArrayGetCount(labels) < max ? (UInt32)CFArrayGetCount(labels) : max;
    for (UInt32 i = 0; i < n; i++) {
        long long v = 0;
        CFNumberGetValue(CFArrayGetValueAtIndex(labels, i), kCFNumberLongLongType, &v);
        out[i] = (AudioChannelLabel)v;
    }
    return n;
}

static AudioChannelLayout *
copy_full_layout(AudioChannelLayoutTag tag, UInt32 *sizeOut)
{
    AudioChannelLabel labels[64];
    AudioChannelLayout probe = {tag, 0, 0, {}};
    UInt32 n = labels_of(&probe, labels, 64);
    UInt32 size = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + sizeof(AudioChannelDescription) * (n ? n : 1));
    AudioChannelLayout *l = calloc(1, size);
    l->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
    l->mNumberChannelDescriptions = n;
    for (UInt32 i = 0; i < n; i++)
        l->mChannelDescriptions[i].mChannelLabel = labels[i];
    *sizeOut = size;
    return l;
}

static CFStringRef
copy_layout_name(const AudioChannelLayout *l, bool simple)
{
    AudioChannelLayoutTag tag = tag_of(l);
    CFDictionaryRef d = entry(&layoutsByTag, tag);
    CFStringRef name = d ? CFDictionaryGetValue(d, simple ? CFSTR("simpleName") : CFSTR("name")) : NULL;
    if (name)
        return CFRetain(name);
    if ((tag & 0xffff0000) == kAudioChannelLayoutTag_DiscreteInOrder)
        return CFStringCreateWithFormat(NULL, NULL, CFSTR("%u Discrete Channels"), (unsigned)channels_in_tag(tag));
    return NULL;
}

static CFStringRef
copy_label_name(AudioChannelLabel label, bool shortName)
{
    CFDictionaryRef d = entry(&labelsByLabel, label);
    CFStringRef name = d ? CFDictionaryGetValue(d, shortName ? CFSTR("shortName") : CFSTR("name")) : NULL;
    return name ? CFRetain(name) : NULL;
}

static UInt32
number_of_channels(const AudioChannelLayout *l)
{
    if (l->mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions)
        return l->mNumberChannelDescriptions;
    if (l->mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelBitmap)
        return (UInt32)__builtin_popcount(l->mChannelBitmap);
    return channels_in_tag(l->mChannelLayoutTag);
}

/* --- the properties --- */

/* What a property gives: its size, and (when out isn't NULL) the value written there. */
static OSStatus
answer(AudioFormatPropertyID property, UInt32 specifierSize, const void *specifier, UInt32 *size, void *out)
{
#define NEED(type)                                                                                    \
    do {                                                                                              \
        if (!specifier || specifierSize < sizeof(type))                                               \
            return kAudioFormatBadSpecifierSizeError;                                                 \
    } while (0)
#define GIVE(value)                                                                                   \
    do {                                                                                              \
        __typeof__(value) v_ = (value);                                                               \
        if (out) {                                                                                    \
            if (*size < sizeof v_)                                                                    \
                return kAudioFormatBadPropertySizeError;                                              \
            memcpy(out, &v_, sizeof v_);                                                              \
        }                                                                                             \
        *size = sizeof v_;                                                                            \
        return noErr;                                                                                 \
    } while (0)
    switch (property) {
    case kAudioFormatProperty_FormatInfo: {
        if (!out) {
            *size = sizeof(AudioStreamBasicDescription);
            return noErr;
        }
        if (*size < sizeof(AudioStreamBasicDescription))
            return kAudioFormatBadPropertySizeError;
        AudioStreamBasicDescription *a = out;
        if (is_pcm(a)) {
            fill_pcm(a);
            return noErr;
        }
        return fill_codec(a);
    }
    case kAudioFormatProperty_FormatName: {
        NEED(AudioStreamBasicDescription);
        CFStringRef name = copy_format_name(specifier);
        if (!name)
            return kAudioFormatUnsupportedDataFormatError;
        if (out && *size < sizeof name) {
            CFRelease(name);
            return kAudioFormatBadPropertySizeError;
        }
        if (out)
            *(CFStringRef *)out = name;
        else
            CFRelease(name);
        *size = sizeof name;
        return noErr;
    }
    case kAudioFormatProperty_FormatIsVBR: {
        NEED(AudioStreamBasicDescription);
        const AudioStreamBasicDescription *a = specifier;
        if (is_pcm(a))
            GIVE((UInt32)0);
        CFDictionaryRef f = entry(&formatsByID, a->mFormatID);
        if (!f)
            return kAudioFormatUnsupportedDataFormatError;
        GIVE((UInt32)get_int(f, CFSTR("vbr"), a->mBytesPerPacket == 0));
    }
    case kAudioFormatProperty_FormatIsExternallyFramed: {
        NEED(AudioStreamBasicDescription);
        const AudioStreamBasicDescription *a = specifier;
        GIVE((UInt32)(!is_pcm(a) && a->mBytesPerPacket == 0));
    }
    case kAudioFormatProperty_FormatIsEncrypted:
        NEED(AudioFormatID);
        GIVE((UInt32)0);
    case kAudioFormatProperty_ChannelLayoutName:
    case kAudioFormatProperty_ChannelLayoutSimpleName: {
        if (!specifier || specifierSize < offsetof(AudioChannelLayout, mChannelDescriptions))
            return kAudioFormatBadSpecifierSizeError;
        CFStringRef name = copy_layout_name(specifier, property == kAudioFormatProperty_ChannelLayoutSimpleName);
        if (!name)
            return kAudioFormatUnknownFormatError;
        if (out)
            *(CFStringRef *)out = name;
        else
            CFRelease(name);
        *size = sizeof name;
        return noErr;
    }
    case kAudioFormatProperty_ChannelName:
    case kAudioFormatProperty_ChannelShortName: {
        NEED(AudioChannelDescription);
        CFStringRef name = copy_label_name(((const AudioChannelDescription *)specifier)->mChannelLabel, property == kAudioFormatProperty_ChannelShortName);
        if (!name)
            return kAudioFormatUnknownFormatError;
        if (out)
            *(CFStringRef *)out = name;
        else
            CFRelease(name);
        *size = sizeof name;
        return noErr;
    }
    case kAudioFormatProperty_NumberOfChannelsForLayout: {
        if (!specifier || specifierSize < offsetof(AudioChannelLayout, mChannelDescriptions))
            return kAudioFormatBadSpecifierSizeError;
        GIVE(number_of_channels(specifier));
    }
    case kAudioFormatProperty_BitmapForLayoutTag: {
        NEED(AudioChannelLayoutTag);
        CFDictionaryRef d = entry(&layoutsByTag, *(const AudioChannelLayoutTag *)specifier);
        long long bitmap = get_int(d, CFSTR("bitmap"), -1);
        if (bitmap < 0)
            return kAudioFormatUnsupportedDataFormatError;
        GIVE((UInt32)bitmap);
    }
    case kAudioFormatProperty_ChannelLayoutForTag:
    case kAudioFormatProperty_ChannelLayoutForBitmap: {
        NEED(UInt32);
        AudioChannelLayoutTag tag = *(const UInt32 *)specifier;
        if (property == kAudioFormatProperty_ChannelLayoutForBitmap) {
            AudioChannelLayout b = {kAudioChannelLayoutTag_UseChannelBitmap, tag, 0, {}};
            tag = tag_of(&b);
            if (tag == kAudioChannelLayoutTag_UseChannelBitmap) {
                /* (a bitmap no tag has: its channels as descriptions) */
                UInt32 n = (UInt32)__builtin_popcount(*(const UInt32 *)specifier);
                UInt32 need = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + sizeof(AudioChannelDescription) * (n ? n : 1));
                if (out) {
                    if (*size < need)
                        return kAudioFormatBadPropertySizeError;
                    memset(out, 0, need);
                    AudioChannelLabel labels[32];
                    labels_of(&b, labels, 32);
                    AudioChannelLayout *l = out;
                    l->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
                    l->mNumberChannelDescriptions = n;
                    for (UInt32 i = 0; i < n; i++)
                        l->mChannelDescriptions[i].mChannelLabel = labels[i];
                }
                *size = need;
                return noErr;
            }
        }
        if (!entry(&layoutsByTag, tag) && (tag & 0xffff0000) != kAudioChannelLayoutTag_DiscreteInOrder &&
            (tag & 0xffff0000) != kAudioChannelLayoutTag_Unknown)
            return kAudioFormatUnknownFormatError;
        UInt32 need = 0;
        AudioChannelLayout *full = copy_full_layout(tag, &need);
        if (out) {
            if (*size < need) {
                free(full);
                return kAudioFormatBadPropertySizeError;
            }
            memcpy(out, full, need);
        }
        free(full);
        *size = need;
        return noErr;
    }
    case kAudioFormatProperty_TagsForNumberOfChannels: {
        NEED(UInt32);
        UInt32 n = *(const UInt32 *)specifier;
        static pthread_once_t once = PTHREAD_ONCE_INIT;
        pthread_once(&once, load);
        CFArrayRef byCount = CFDictionaryGetValue(tables, CFSTR("tagsForChannels"));
        CFArrayRef list = n < (UInt32)CFArrayGetCount(byCount) ? CFArrayGetValueAtIndex(byCount, n) : NULL;
        UInt32 count = list ? (UInt32)CFArrayGetCount(list) : 0;
        if (out) {
            if (*size < count * 4)
                return kAudioFormatBadPropertySizeError;
            for (UInt32 i = 0; i < count; i++) {
                long long v = 0;
                CFNumberGetValue(CFArrayGetValueAtIndex(list, i), kCFNumberLongLongType, &v);
                ((AudioChannelLayoutTag *)out)[i] = (AudioChannelLayoutTag)v;
            }
        }
        *size = count * 4;
        return noErr;
    }
    case kAudioFormatProperty_AreChannelLayoutsEquivalent: {
        if (!specifier || specifierSize < 2 * sizeof(AudioChannelLayout *))
            return kAudioFormatBadSpecifierSizeError;
        const AudioChannelLayout *const *pair = specifier;
        AudioChannelLabel a[64], b[64];
        UInt32 na = labels_of(pair[0], a, 64), nb = labels_of(pair[1], b, 64);
        GIVE((UInt32)(na == nb && !memcmp(a, b, sizeof a[0] * na)));
    }
    case kAudioFormatProperty_ValidateChannelLayout: {
        if (!specifier || specifierSize < offsetof(AudioChannelLayout, mChannelDescriptions))
            return kAudioFormatBadSpecifierSizeError;
        const AudioChannelLayout *l = specifier;
        if (l->mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions &&
            specifierSize < offsetof(AudioChannelLayout, mChannelDescriptions) + sizeof(AudioChannelDescription) * l->mNumberChannelDescriptions)
            return kAudioFormatBadSpecifierSizeError;
        if (out)
            *size = 0;
        return noErr;
    }
    case kAudioFormatProperty_ChannelMap: {
        /* (for each output channel, the input channel with its label, or -1) */
        if (!specifier || specifierSize < 2 * sizeof(AudioChannelLayout *))
            return kAudioFormatBadSpecifierSizeError;
        const AudioChannelLayout *const *pair = specifier;
        AudioChannelLabel in[64], outLabels[64];
        UInt32 ni = labels_of(pair[0], in, 64), no = labels_of(pair[1], outLabels, 64);
        if (out) {
            if (*size != no * sizeof(SInt32))
                return kAudioFormatBadPropertySizeError;
            for (UInt32 o = 0; o < no; o++) {
                SInt32 found = -1;
                for (UInt32 i = 0; i < ni && found < 0; i++)
                    if (in[i] == outLabels[o])
                        found = (SInt32)i;
                ((SInt32 *)out)[o] = found;
            }
        }
        *size = no * sizeof(SInt32);
        return noErr;
    }
    case kAudioFormatProperty_DecodeFormatIDs:
    case kAudioFormatProperty_EncodeFormatIDs: {
        /* (what Finch has: linear PCM and the G.711 laws) */
        static const UInt32 have[] = {kAudioFormatALaw, kAudioFormatLinearPCM, kAudioFormatULaw};
        if (out) {
            if (*size < sizeof have)
                return kAudioFormatBadPropertySizeError;
            memcpy(out, have, sizeof have);
        }
        *size = sizeof have;
        return noErr;
    }
    case kAudioFormatProperty_FormatList: {
        if (!specifier || specifierSize < sizeof(AudioFormatInfo))
            return kAudioFormatBadSpecifierSizeError;
        const AudioFormatInfo *info = specifier;
        AudioFormatListItem item = {info->mASBD,
                                    info->mASBD.mChannelsPerFrame == 1   ? kAudioChannelLayoutTag_Mono
                                    : info->mASBD.mChannelsPerFrame == 2 ? kAudioChannelLayoutTag_Stereo
                                                                         : kAudioChannelLayoutTag_Unknown | info->mASBD.mChannelsPerFrame};
        GIVE(item);
    }
    case kAudioFormatProperty_FirstPlayableFormatFromList: {
        if (!specifier || specifierSize < sizeof(AudioFormatListItem))
            return kAudioFormatBadSpecifierSizeError;
        GIVE((UInt32)0);
    }
    }
    return kAudioFormatUnsupportedPropertyError;
#undef NEED
#undef GIVE
}

OSStatus
AudioFormatGetPropertyInfo(AudioFormatPropertyID inPropertyID, UInt32 inSpecifierSize, const void *inSpecifier, UInt32 *outPropertyDataSize)
{
    if (!outPropertyDataSize)
        return kAudioFormatBadPropertySizeError;
    UInt32 size = 0;
    /* (the size of what it would give: names are references, whose size is known without making them) */
    if (inPropertyID == kAudioFormatProperty_FormatName || inPropertyID == kAudioFormatProperty_ChannelLayoutName ||
        inPropertyID == kAudioFormatProperty_ChannelLayoutSimpleName || inPropertyID == kAudioFormatProperty_ChannelName ||
        inPropertyID == kAudioFormatProperty_ChannelShortName) {
        *outPropertyDataSize = sizeof(CFStringRef);
        return noErr;
    }
    OSStatus e = answer(inPropertyID, inSpecifierSize, inSpecifier, &size, NULL);
    if (!e)
        *outPropertyDataSize = size;
    return e;
}

OSStatus
AudioFormatGetProperty(AudioFormatPropertyID inPropertyID, UInt32 inSpecifierSize, const void *inSpecifier, UInt32 *ioPropertyDataSize,
                       void *outPropertyData)
{
    if (!ioPropertyDataSize)
        return kAudioFormatBadPropertySizeError;
    if (!outPropertyData)
        return AudioFormatGetPropertyInfo(inPropertyID, inSpecifierSize, inSpecifier, ioPropertyDataSize);
    return answer(inPropertyID, inSpecifierSize, inSpecifier, ioPropertyDataSize, outPropertyData);
}
