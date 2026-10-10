/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Writes what Apple's AudioToolbox on this Mac answers for the table-like AudioFormat
   properties, as a binary property list: each channel layout tag's name, simple name,
   channel labels and bitmap; each channel label's names; the layout tags for each
   number of channels; and each format ID's name and the format info it fills in at a
   few rates and channel counts. Run by tools/audiotoolbox/gen-audio-format.sh. */
#include <AudioToolbox/AudioToolbox.h>
#include <stdio.h>

static void
set_string(CFMutableDictionaryRef d, CFStringRef key, CFStringRef value)
{
    if (value)
        CFDictionarySetValue(d, key, value);
}

static void
set_int(CFMutableDictionaryRef d, CFStringRef key, long long v)
{
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberLongLongType, &v);
    CFDictionarySetValue(d, key, n);
    CFRelease(n);
}

static CFStringRef
copy_name(AudioFormatPropertyID property, UInt32 size, const void *specifier)
{
    CFStringRef s = NULL;
    UInt32 n = sizeof s;
    return AudioFormatGetProperty(property, size, specifier, &n, &s) ? NULL : s;
}

int
main(int argc, char **argv)
{
    CFMutableDictionaryRef out = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    /* layouts */
    const AudioChannelLayoutTag tags[] = {kAudioChannelLayoutTag_AAC_3_0,kAudioChannelLayoutTag_AAC_4_0,kAudioChannelLayoutTag_AAC_5_0,kAudioChannelLayoutTag_AAC_5_1,kAudioChannelLayoutTag_AAC_6_0,kAudioChannelLayoutTag_AAC_6_1,kAudioChannelLayoutTag_AAC_7_0,kAudioChannelLayoutTag_AAC_7_1,kAudioChannelLayoutTag_AAC_7_1_B,kAudioChannelLayoutTag_AAC_7_1_C,kAudioChannelLayoutTag_AAC_Octagonal,kAudioChannelLayoutTag_AAC_Quadraphonic,kAudioChannelLayoutTag_AC3_1_0_1,kAudioChannelLayoutTag_AC3_2_1_1,kAudioChannelLayoutTag_AC3_3_0,kAudioChannelLayoutTag_AC3_3_0_1,kAudioChannelLayoutTag_AC3_3_1,kAudioChannelLayoutTag_AC3_3_1_1,kAudioChannelLayoutTag_Ambisonic_B_Format,kAudioChannelLayoutTag_Atmos_5_1_2,kAudioChannelLayoutTag_Atmos_5_1_4,kAudioChannelLayoutTag_Atmos_7_1_2,kAudioChannelLayoutTag_Atmos_7_1_4,kAudioChannelLayoutTag_Atmos_9_1_6,kAudioChannelLayoutTag_AudioUnit_4,kAudioChannelLayoutTag_AudioUnit_5,kAudioChannelLayoutTag_AudioUnit_5_0,kAudioChannelLayoutTag_AudioUnit_5_1,kAudioChannelLayoutTag_AudioUnit_6,kAudioChannelLayoutTag_AudioUnit_6_0,kAudioChannelLayoutTag_AudioUnit_6_1,kAudioChannelLayoutTag_AudioUnit_7_0,kAudioChannelLayoutTag_AudioUnit_7_0_Front,kAudioChannelLayoutTag_AudioUnit_7_1,kAudioChannelLayoutTag_AudioUnit_7_1_Front,kAudioChannelLayoutTag_AudioUnit_8,kAudioChannelLayoutTag_Binaural,kAudioChannelLayoutTag_Cube,kAudioChannelLayoutTag_DTS_3_1,kAudioChannelLayoutTag_DTS_4_1,kAudioChannelLayoutTag_DTS_6_0_A,kAudioChannelLayoutTag_DTS_6_0_B,kAudioChannelLayoutTag_DTS_6_0_C,kAudioChannelLayoutTag_DTS_6_1_A,kAudioChannelLayoutTag_DTS_6_1_B,kAudioChannelLayoutTag_DTS_6_1_C,kAudioChannelLayoutTag_DTS_6_1_D,kAudioChannelLayoutTag_DTS_7_0,kAudioChannelLayoutTag_DTS_7_1,kAudioChannelLayoutTag_DTS_8_0_A,kAudioChannelLayoutTag_DTS_8_0_B,kAudioChannelLayoutTag_DTS_8_1_A,kAudioChannelLayoutTag_DTS_8_1_B,kAudioChannelLayoutTag_DVD_0,kAudioChannelLayoutTag_DVD_1,kAudioChannelLayoutTag_DVD_10,kAudioChannelLayoutTag_DVD_11,kAudioChannelLayoutTag_DVD_12,kAudioChannelLayoutTag_DVD_13,kAudioChannelLayoutTag_DVD_14,kAudioChannelLayoutTag_DVD_15,kAudioChannelLayoutTag_DVD_16,kAudioChannelLayoutTag_DVD_17,kAudioChannelLayoutTag_DVD_18,kAudioChannelLayoutTag_DVD_19,kAudioChannelLayoutTag_DVD_2,kAudioChannelLayoutTag_DVD_20,kAudioChannelLayoutTag_DVD_3,kAudioChannelLayoutTag_DVD_4,kAudioChannelLayoutTag_DVD_5,kAudioChannelLayoutTag_DVD_6,kAudioChannelLayoutTag_DVD_7,kAudioChannelLayoutTag_DVD_8,kAudioChannelLayoutTag_DVD_9,kAudioChannelLayoutTag_EAC_6_0_A,kAudioChannelLayoutTag_EAC_7_0_A,kAudioChannelLayoutTag_EAC3_6_1_A,kAudioChannelLayoutTag_EAC3_6_1_B,kAudioChannelLayoutTag_EAC3_6_1_C,kAudioChannelLayoutTag_EAC3_7_1_A,kAudioChannelLayoutTag_EAC3_7_1_B,kAudioChannelLayoutTag_EAC3_7_1_C,kAudioChannelLayoutTag_EAC3_7_1_D,kAudioChannelLayoutTag_EAC3_7_1_E,kAudioChannelLayoutTag_EAC3_7_1_F,kAudioChannelLayoutTag_EAC3_7_1_G,kAudioChannelLayoutTag_EAC3_7_1_H,kAudioChannelLayoutTag_Emagic_Default_7_1,kAudioChannelLayoutTag_Hexagonal,kAudioChannelLayoutTag_ITU_1_0,kAudioChannelLayoutTag_ITU_2_0,kAudioChannelLayoutTag_ITU_2_1,kAudioChannelLayoutTag_ITU_2_2,kAudioChannelLayoutTag_ITU_3_0,kAudioChannelLayoutTag_ITU_3_1,kAudioChannelLayoutTag_ITU_3_2,kAudioChannelLayoutTag_ITU_3_2_1,kAudioChannelLayoutTag_ITU_3_4_1,kAudioChannelLayoutTag_Logic_4_0_A,kAudioChannelLayoutTag_Logic_4_0_B,kAudioChannelLayoutTag_Logic_4_0_C,kAudioChannelLayoutTag_Logic_5_0_A,kAudioChannelLayoutTag_Logic_5_0_B,kAudioChannelLayoutTag_Logic_5_0_C,kAudioChannelLayoutTag_Logic_5_0_D,kAudioChannelLayoutTag_Logic_5_1_A,kAudioChannelLayoutTag_Logic_5_1_B,kAudioChannelLayoutTag_Logic_5_1_C,kAudioChannelLayoutTag_Logic_5_1_D,kAudioChannelLayoutTag_Logic_6_0_A,kAudioChannelLayoutTag_Logic_6_0_B,kAudioChannelLayoutTag_Logic_6_0_C,kAudioChannelLayoutTag_Logic_6_1_A,kAudioChannelLayoutTag_Logic_6_1_B,kAudioChannelLayoutTag_Logic_6_1_C,kAudioChannelLayoutTag_Logic_6_1_D,kAudioChannelLayoutTag_Logic_7_1_A,kAudioChannelLayoutTag_Logic_7_1_B,kAudioChannelLayoutTag_Logic_7_1_C,kAudioChannelLayoutTag_Logic_7_1_SDDS_A,kAudioChannelLayoutTag_Logic_7_1_SDDS_B,kAudioChannelLayoutTag_Logic_7_1_SDDS_C,kAudioChannelLayoutTag_Logic_Atmos_5_1_2,kAudioChannelLayoutTag_Logic_Atmos_5_1_4,kAudioChannelLayoutTag_Logic_Atmos_7_1_2,kAudioChannelLayoutTag_Logic_Atmos_7_1_4_A,kAudioChannelLayoutTag_Logic_Atmos_7_1_4_B,kAudioChannelLayoutTag_Logic_Atmos_7_1_6,kAudioChannelLayoutTag_Logic_Mono,kAudioChannelLayoutTag_Logic_Quadraphonic,kAudioChannelLayoutTag_Logic_Stereo,kAudioChannelLayoutTag_MatrixStereo,kAudioChannelLayoutTag_MidSide,kAudioChannelLayoutTag_Mono,kAudioChannelLayoutTag_MPEG_1_0,kAudioChannelLayoutTag_MPEG_2_0,kAudioChannelLayoutTag_MPEG_3_0_A,kAudioChannelLayoutTag_MPEG_3_0_B,kAudioChannelLayoutTag_MPEG_4_0_A,kAudioChannelLayoutTag_MPEG_4_0_B,kAudioChannelLayoutTag_MPEG_5_0_A,kAudioChannelLayoutTag_MPEG_5_0_B,kAudioChannelLayoutTag_MPEG_5_0_C,kAudioChannelLayoutTag_MPEG_5_0_D,kAudioChannelLayoutTag_MPEG_5_0_E,kAudioChannelLayoutTag_MPEG_5_1_A,kAudioChannelLayoutTag_MPEG_5_1_B,kAudioChannelLayoutTag_MPEG_5_1_C,kAudioChannelLayoutTag_MPEG_5_1_D,kAudioChannelLayoutTag_MPEG_5_1_E,kAudioChannelLayoutTag_MPEG_6_1_A,kAudioChannelLayoutTag_MPEG_6_1_B,kAudioChannelLayoutTag_MPEG_7_1_A,kAudioChannelLayoutTag_MPEG_7_1_B,kAudioChannelLayoutTag_MPEG_7_1_C,kAudioChannelLayoutTag_MPEG_7_1_D,kAudioChannelLayoutTag_Octagonal,kAudioChannelLayoutTag_Ogg_3_0,kAudioChannelLayoutTag_Ogg_4_0,kAudioChannelLayoutTag_Ogg_5_0,kAudioChannelLayoutTag_Ogg_5_1,kAudioChannelLayoutTag_Ogg_6_1,kAudioChannelLayoutTag_Ogg_7_1,kAudioChannelLayoutTag_Pentagonal,kAudioChannelLayoutTag_Quadraphonic,kAudioChannelLayoutTag_SMPTE_DTV,kAudioChannelLayoutTag_Stereo,kAudioChannelLayoutTag_StereoHeadphones,kAudioChannelLayoutTag_TMH_10_2_full,kAudioChannelLayoutTag_TMH_10_2_std,kAudioChannelLayoutTag_WAVE_2_1,kAudioChannelLayoutTag_WAVE_3_0,kAudioChannelLayoutTag_WAVE_4_0_A,kAudioChannelLayoutTag_WAVE_4_0_B,kAudioChannelLayoutTag_WAVE_5_0_A,kAudioChannelLayoutTag_WAVE_5_0_B,kAudioChannelLayoutTag_WAVE_5_1_A,kAudioChannelLayoutTag_WAVE_5_1_B,kAudioChannelLayoutTag_WAVE_6_1,kAudioChannelLayoutTag_WAVE_7_1,kAudioChannelLayoutTag_XY};
    CFMutableArrayRef layouts = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    for (size_t i = 0; i < sizeof tags / sizeof tags[0]; i++) {
        CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        set_int(d, CFSTR("tag"), tags[i]);
        AudioChannelLayout l = {tags[i], 0, 0, {}};
        set_string(d, CFSTR("name"), copy_name(kAudioFormatProperty_ChannelLayoutName, sizeof l, &l));
        set_string(d, CFSTR("simpleName"), copy_name(kAudioFormatProperty_ChannelLayoutSimpleName, sizeof l, &l));
        UInt32 bitmap = 0, size = 4;
        if (!AudioFormatGetProperty(kAudioFormatProperty_BitmapForLayoutTag, 4, &tags[i], &size, &bitmap))
            set_int(d, CFSTR("bitmap"), bitmap);
        UInt32 full = 0;
        if (!AudioFormatGetPropertyInfo(kAudioFormatProperty_ChannelLayoutForTag, 4, &tags[i], &full) && full) {
            AudioChannelLayout *f = malloc(full);
            if (!AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutForTag, 4, &tags[i], &full, f)) {
                CFMutableArrayRef labels = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
                for (UInt32 k = 0; k < f->mNumberChannelDescriptions; k++) {
                    long long label = f->mChannelDescriptions[k].mChannelLabel;
                    CFNumberRef n = CFNumberCreate(NULL, kCFNumberLongLongType, &label);
                    CFArrayAppendValue(labels, n);
                    CFRelease(n);
                }
                CFDictionarySetValue(d, CFSTR("labels"), labels);
                CFRelease(labels);
            }
            free(f);
        }
        CFArrayAppendValue(layouts, d);
        CFRelease(d);
    }
    CFDictionarySetValue(out, CFSTR("layouts"), layouts);
    /* labels */
    CFMutableArrayRef labels = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    for (UInt32 label = 0; label < 0x20000; label = label < 1000 ? label + 1 : label == 1000 ? 0x10000 : label + 1) {
        if (label >= 0x10000 + 64)
            break;
        AudioChannelDescription desc = {label, 0, {0, 0, 0}};
        CFStringRef name = copy_name(kAudioFormatProperty_ChannelName, sizeof desc, &desc);
        CFStringRef shortName = copy_name(kAudioFormatProperty_ChannelShortName, sizeof desc, &desc);
        if (!name && !shortName)
            continue;
        CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        set_int(d, CFSTR("label"), label);
        set_string(d, CFSTR("name"), name);
        set_string(d, CFSTR("shortName"), shortName);
        CFArrayAppendValue(labels, d);
        CFRelease(d);
    }
    CFDictionarySetValue(out, CFSTR("labels"), labels);
    /* tags for each number of channels */
    CFMutableArrayRef byCount = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    for (UInt32 n = 0; n <= 32; n++) {
        UInt32 size = 0;
        CFMutableArrayRef list = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
        if (!AudioFormatGetPropertyInfo(kAudioFormatProperty_TagsForNumberOfChannels, 4, &n, &size) && size) {
            AudioChannelLayoutTag *t = malloc(size);
            if (!AudioFormatGetProperty(kAudioFormatProperty_TagsForNumberOfChannels, 4, &n, &size, t))
                for (UInt32 i = 0; i < size / 4; i++) {
                    long long v = t[i];
                    CFNumberRef num = CFNumberCreate(NULL, kCFNumberLongLongType, &v);
                    CFArrayAppendValue(list, num);
                    CFRelease(num);
                }
            free(t);
        }
        CFArrayAppendValue(byCount, list);
        CFRelease(list);
    }
    CFDictionarySetValue(out, CFSTR("tagsForChannels"), byCount);
    /* formats */
    const AudioFormatID formats[] = {kAudioFormat60958AC3,kAudioFormatAC3,kAudioFormatAES3,kAudioFormatALaw,kAudioFormatAMR,kAudioFormatAMR_WB,kAudioFormatAPAC,kAudioFormatAppleIMA4,kAudioFormatAppleLossless,kAudioFormatAudible,kAudioFormatEnhancedAC3,kAudioFormatFLAC,kAudioFormatiLBC,kAudioFormatLinearPCM,kAudioFormatMACE3,kAudioFormatMACE6,kAudioFormatMPEG4AAC,kAudioFormatMPEG4AAC_ELD,kAudioFormatMPEG4AAC_ELD_SBR,kAudioFormatMPEG4AAC_ELD_V2,kAudioFormatMPEG4AAC_HE,kAudioFormatMPEG4AAC_HE_V2,kAudioFormatMPEG4AAC_LD,kAudioFormatMPEG4AAC_Spatial,kAudioFormatMPEG4CELP,kAudioFormatMPEG4HVXC,kAudioFormatMPEG4TwinVQ,kAudioFormatMPEGD_USAC,kAudioFormatMPEGLayer1,kAudioFormatMPEGLayer2,kAudioFormatMPEGLayer3,kAudioFormatOpus,kAudioFormatQDesign,kAudioFormatQDesign2,kAudioFormatQUALCOMM,kAudioFormatULaw};
    const Float64 rates[] = {8000, 16000, 22050, 24000, 32000, 44100, 48000, 96000};
    CFMutableArrayRef fs = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    for (size_t i = 0; i < sizeof formats / sizeof formats[0]; i++) {
        CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        set_int(d, CFSTR("format"), formats[i]);
        AudioStreamBasicDescription probe = {44100, formats[i], 0, 0, 0, 0, 2, 0, 0};
        CFStringRef name = copy_name(kAudioFormatProperty_FormatName, sizeof probe, &probe);
        set_string(d, CFSTR("name"), name);
        UInt32 vbr = 0, size = 4;
        if (!AudioFormatGetProperty(kAudioFormatProperty_FormatIsVBR, sizeof probe, &probe, &size, &vbr))
            set_int(d, CFSTR("vbr"), vbr);
        CFMutableArrayRef infos = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
        for (size_t r = 0; r < sizeof rates / sizeof rates[0]; r++)
            for (UInt32 ch = 1; ch <= 2; ch++) {
                AudioStreamBasicDescription a = {rates[r], formats[i], 0, 0, 0, 0, ch, 0, 0};
                size = sizeof a;
                if (AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, NULL, &size, &a))
                    continue;
                CFMutableDictionaryRef info = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
                set_int(info, CFSTR("rate"), (long long)rates[r]);
                set_int(info, CFSTR("channels"), ch);
                set_int(info, CFSTR("flags"), a.mFormatFlags);
                set_int(info, CFSTR("bytesPerPacket"), a.mBytesPerPacket);
                set_int(info, CFSTR("framesPerPacket"), a.mFramesPerPacket);
                set_int(info, CFSTR("bytesPerFrame"), a.mBytesPerFrame);
                set_int(info, CFSTR("bitsPerChannel"), a.mBitsPerChannel);
                CFArrayAppendValue(infos, info);
                CFRelease(info);
            }
        CFDictionarySetValue(d, CFSTR("info"), infos);
        CFRelease(infos);
        CFArrayAppendValue(fs, d);
        CFRelease(d);
    }
    CFDictionarySetValue(out, CFSTR("formats"), fs);
    /* the codecs it decodes and encodes */
    UInt32 size = 0;
    const AudioFormatPropertyID lists[] = {kAudioFormatProperty_DecodeFormatIDs, kAudioFormatProperty_EncodeFormatIDs};
    const CFStringRef listNames[] = {CFSTR("decodes"), CFSTR("encodes")};
    for (int k = 0; k < 2; k++) {
        CFMutableArrayRef ids = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
        if (!AudioFormatGetPropertyInfo(lists[k], 0, NULL, &size) && size) {
            UInt32 *v = malloc(size);
            AudioFormatGetProperty(lists[k], 0, NULL, &size, v);
            for (UInt32 i = 0; i < size / 4; i++) {
                long long x = v[i];
                CFNumberRef n = CFNumberCreate(NULL, kCFNumberLongLongType, &x);
                CFArrayAppendValue(ids, n);
                CFRelease(n);
            }
            free(v);
        }
        CFDictionarySetValue(out, listNames[k], ids);
        CFRelease(ids);
    }
    CFDataRef data = CFPropertyListCreateData(NULL, out, kCFPropertyListBinaryFormat_v1_0, 0, NULL);
    FILE *fp = fopen(argv[1], "wb");
    fwrite(CFDataGetBytePtr(data), 1, (size_t)CFDataGetLength(data), fp);
    fclose(fp);
    fprintf(stderr, "%ld layouts, %ld labels, %ld formats, %ld bytes\n", (long)CFArrayGetCount(layouts), (long)CFArrayGetCount(labels),
            (long)CFArrayGetCount(fs), (long)CFDataGetLength(data));
    return 0;
}
