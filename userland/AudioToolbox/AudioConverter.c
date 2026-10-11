/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Audio sample conversion, Finch's. PCM and G.711 need no external codec.
   Integer paths preserve bits; float paths follow the host's rounding and clipping. */
#include <AudioToolbox/AudioToolbox.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

struct OpaqueAudioConverter {
    AudioStreamBasicDescription input, output;
    SInt32 *map;
    UInt32 complexity, quality, primeMethod, dithering, ditherDepth;
    Boolean hasDitherDepth, unbuffered;
    Float64 initialPhase;
    UInt32 srcRadius, srcTaps;
    Float64 *srcFilter;
    Float64 *srcSamples;
    Float64 *ditherError;
    UInt32 srcFrames;
    UInt64 srcBaseFrame, srcTotalFrames, srcOutputFrame;
    Boolean srcEOF;
    UInt32 random;
    AudioBufferList *inputList, *outputList;
};

#define SRC_PHASES 1024
#define SRC_QUEUE_FRAMES 384
#define SRC_CALLBACK_FRAMES 256
#define SRC_MAX_RADIUS 64

static bool
planar(const AudioStreamBasicDescription *a)
{
    return (a->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
}

static UInt32
sample_bytes(const AudioStreamBasicDescription *a)
{
    return a->mBytesPerFrame / (planar(a) ? 1 : a->mChannelsPerFrame);
}

static bool
valid_format(const AudioStreamBasicDescription *a)
{
    if (!a->mChannelsPerFrame || a->mChannelsPerFrame > 1024 || !isfinite(a->mSampleRate) || a->mSampleRate <= 0)
        return false;
    UInt32 channels = planar(a) ? 1 : a->mChannelsPerFrame;
    if (a->mFramesPerPacket != 1 || a->mBytesPerFrame != a->mBytesPerPacket)
        return false;
    if (a->mFormatID == kAudioFormatULaw || a->mFormatID == kAudioFormatALaw)
        return !a->mFormatFlags && a->mBitsPerChannel == 8 && a->mBytesPerFrame == channels;
    if (a->mFormatID != kAudioFormatLinearPCM)
        return false;
    UInt32 bits = a->mBitsPerChannel;
    UInt32 bytes = sample_bytes(a);
    if (!bytes || bytes > 8 || a->mBytesPerFrame % (planar(a) ? 1 : a->mChannelsPerFrame))
        return false;
    UInt32 containerBits = bytes * 8;
    if (bits > containerBits)
        return false;
    if (a->mFormatFlags & kAudioFormatFlagIsFloat) {
        if ((bits != 32 && bits != 64) || bits != containerBits ||
            !(a->mFormatFlags & kAudioFormatFlagIsPacked) || (a->mFormatFlags & kAudioFormatFlagIsSignedInteger))
            return false;
    } else if (!bits || bits > 32 ||
        ((a->mFormatFlags & kAudioFormatFlagIsPacked) && (bits % 8 || bits != containerBits)) ||
        ((a->mFormatFlags & kAudioFormatFlagIsAlignedHigh) &&
            ((a->mFormatFlags & kAudioFormatFlagIsPacked) || bits == containerBits))) {
        return false;
    }
    UInt32 allowed = kAudioFormatFlagIsFloat | kAudioFormatFlagIsBigEndian | kAudioFormatFlagIsSignedInteger |
        kAudioFormatFlagIsPacked | kAudioFormatFlagIsAlignedHigh | kAudioFormatFlagIsNonInterleaved;
    return !(a->mFormatFlags & ~allowed) && a->mBytesPerFrame == channels * bytes;
}

static AudioBufferList *
new_buffer_list(UInt32 count)
{
    if (!count)
        return NULL;
    AudioBufferList *list = calloc(1, sizeof(AudioBufferList) + (count - 1) * sizeof(AudioBuffer));
    if (list)
        list->mNumberBuffers = count;
    return list;
}

static Float64
sinc(Float64 x)
{
    if (fabs(x) < 1e-12)
        return 1.0;
    return sin(M_PI * x) / (M_PI * x);
}

static OSStatus
build_src_filter(AudioConverterRef c)
{
    if (c->input.mSampleRate == c->output.mSampleRate ||
        c->complexity == kAudioConverterSampleRateConverterComplexity_Linear) {
        free(c->srcFilter);
        c->srcFilter = NULL;
        c->srcRadius = 1;
        c->srcTaps = 2;
        return noErr;
    }
    UInt32 radius = c->complexity == kAudioConverterSampleRateConverterComplexity_Mastering ? SRC_MAX_RADIUS :
        c->quality >= kAudioConverterQuality_Max ? SRC_MAX_RADIUS :
        c->quality >= kAudioConverterQuality_High ? 48 :
        c->quality >= kAudioConverterQuality_Medium ? 32 :
        c->quality >= kAudioConverterQuality_Low ? 24 : 16;
    UInt32 taps = radius * 2;
    if ((uint64_t)(SRC_PHASES + 1) * taps > SIZE_MAX / sizeof(Float64))
        return -108;
    Float64 *filter = malloc((size_t)(SRC_PHASES + 1) * taps * sizeof(*filter));
    if (!filter)
        return -108;
    Float64 ratio = c->output.mSampleRate / c->input.mSampleRate;
    Float64 cutoff = 0.475 * fmin(1.0, ratio);
    for (UInt32 phase = 0; phase <= SRC_PHASES; phase++) {
        Float64 fraction = (Float64)phase / SRC_PHASES;
        Float64 sum = 0;
        for (UInt32 tap = 0; tap < taps; tap++) {
            Float64 distance = (Float64)((SInt32)tap - (SInt32)radius + 1) - fraction;
            Float64 window = 0;
            if (fabs(distance) <= radius) {
                Float64 position = distance / radius;
                window = 0.42 + 0.5 * cos(M_PI * position) + 0.08 * cos(2.0 * M_PI * position);
            }
            Float64 weight = 2.0 * cutoff * sinc(2.0 * cutoff * distance) * window;
            filter[(size_t)phase * taps + tap] = weight;
            sum += weight;
        }
        if (sum != 0)
            for (UInt32 tap = 0; tap < taps; tap++)
                filter[(size_t)phase * taps + tap] /= sum;
    }
    free(c->srcFilter);
    c->srcFilter = filter;
    c->srcRadius = radius;
    c->srcTaps = taps;
    return noErr;
}

OSStatus
AudioConverterNew(const AudioStreamBasicDescription *input, const AudioStreamBasicDescription *output, AudioConverterRef *result)
{
    if (!input || !output || !result)
        return -50;
    *result = NULL;
    if (!valid_format(input) || !valid_format(output))
        return kAudioConverterErr_FormatNotSupported;
    AudioConverterRef c = calloc(1, sizeof(*c));
    if (!c)
        return -108;
    c->map = calloc(output->mChannelsPerFrame, sizeof(*c->map));
    c->ditherError = calloc(output->mChannelsPerFrame, sizeof(*c->ditherError));
    if (!c->map || !c->ditherError) {
        free(c->ditherError);
        free(c->map);
        free(c);
        return -108;
    }
    c->input = *input;
    c->output = *output;
    c->complexity = kAudioConverterSampleRateConverterComplexity_Normal;
    c->quality = kAudioConverterQuality_Medium;
    c->primeMethod = kConverterPrimeMethod_Normal;
    c->random = UINT32_C(0x6d2b79f5);
    UInt32 inputBuffers = planar(input) ? input->mChannelsPerFrame : 1;
    UInt32 outputBuffers = planar(output) ? output->mChannelsPerFrame : 1;
    c->inputList = new_buffer_list(inputBuffers);
    c->outputList = new_buffer_list(outputBuffers);
    if (input->mSampleRate != output->mSampleRate)
        c->srcSamples = calloc((size_t)SRC_QUEUE_FRAMES * input->mChannelsPerFrame, sizeof(*c->srcSamples));
    if (!c->inputList || !c->outputList ||
        (input->mSampleRate != output->mSampleRate && !c->srcSamples)) {
        free(c->inputList);
        free(c->outputList);
        free(c->srcSamples);
        free(c->ditherError);
        free(c->map);
        free(c);
        return -108;
    }
    OSStatus status = build_src_filter(c);
    if (status) {
        free(c->inputList);
        free(c->outputList);
        free(c->srcSamples);
        free(c->ditherError);
        free(c->map);
        free(c);
        return status;
    }
    for (UInt32 i = 0; i < output->mChannelsPerFrame; i++)
        c->map[i] = i < input->mChannelsPerFrame ? (SInt32)i :
            (input->mChannelsPerFrame == 1 && output->mChannelsPerFrame == 2 ? 0 : -1);
    *result = c;
    return noErr;
}

OSStatus
AudioConverterNewSpecific(const AudioStreamBasicDescription *input, const AudioStreamBasicDescription *output,
    UInt32 count, const AudioClassDescription *descriptions, AudioConverterRef *result)
{
    if (count && !descriptions)
        return -50;
    return AudioConverterNew(input, output, result);
}

OSStatus
AudioConverterNewWithOptions(const AudioStreamBasicDescription *input, const AudioStreamBasicDescription *output,
    AudioConverterOptions options, AudioConverterRef *result)
{
    if (options & ~kAudioConverterOption_Unbuffered)
        return -50;
    if ((options & kAudioConverterOption_Unbuffered) &&
        (!input || !output || input->mSampleRate != output->mSampleRate))
        return -50;
    OSStatus status = AudioConverterNew(input, output, result);
    if (!status && result && *result)
        (*result)->unbuffered = (options & kAudioConverterOption_Unbuffered) != 0;
    return status;
}

OSStatus
AudioConverterDispose(AudioConverterRef c)
{
    if (!c)
        return -50;
    free(c->inputList);
    free(c->outputList);
    free(c->srcSamples);
    free(c->srcFilter);
    free(c->ditherError);
    free(c->map);
    free(c);
    return noErr;
}

OSStatus
AudioConverterReset(AudioConverterRef c)
{
    if (!c)
        return -50;
    c->srcFrames = 0;
    c->srcBaseFrame = 0;
    c->srcTotalFrames = 0;
    c->srcOutputFrame = 0;
    c->srcEOF = false;
    c->random = UINT32_C(0x6d2b79f5);
    memset(c->ditherError, 0, c->output.mChannelsPerFrame * sizeof(*c->ditherError));
    return noErr;
}

static int
law_decode(UInt8 value, bool alaw)
{
    if (alaw) {
        value ^= 0x55;
        int exponent = (value >> 4) & 7;
        int magnitude = (value & 15) * 16 + (exponent ? 0x108 : 8);
        if (exponent > 1)
            magnitude <<= exponent - 1;
        return value & 0x80 ? magnitude : -magnitude;
    }
    value = ~value;
    int magnitude = (((value & 15) << 3) + 0x84) << ((value >> 4) & 7);
    magnitude -= 0x84;
    return value & 0x80 ? -magnitude : magnitude;
}

static UInt8
law_encode(int value, bool alaw)
{
    int magnitude = value < 0 ? -value : value;
    if (alaw) {
        if (magnitude > 32767)
            magnitude = 32767;
        int exponent = 0;
        for (int limit = 0x100; magnitude >= limit && exponent < 7; limit <<= 1)
            exponent++;
        int mantissa = (magnitude >> (exponent ? exponent + 3 : 4)) & 15;
        return ((exponent << 4) | mantissa) ^ (value < 0 ? 0x55 : 0xd5);
    }
    /* The host maps the negative saturation interval to 0x02, not 0x00. */
    if (value <= -31612)
        return 2;
    if (magnitude > 32635)
        magnitude = 32635;
    magnitude += 0x84;
    int exponent = 7;
    for (int mask = 0x4000; exponent && !(magnitude & mask); mask >>= 1)
        exponent--;
    return ~((value < 0 ? 0x80 : 0) | (exponent << 4) | ((magnitude >> (exponent + 3)) & 15));
}

static double
read_sample(const AudioStreamBasicDescription *a, const UInt8 *p)
{
    if (a->mFormatID != kAudioFormatLinearPCM)
        return law_decode(*p, a->mFormatID == kAudioFormatALaw) / 32768.0;
    UInt32 bytes = sample_bytes(a);
    uint64_t bits = 0;
    for (UInt32 i = 0; i < bytes; i++)
        bits |= (uint64_t)p[i] << (8 * ((a->mFormatFlags & kAudioFormatFlagIsBigEndian) ? bytes - i - 1 : i));
    if (a->mFormatFlags & kAudioFormatFlagIsFloat) {
        if (bytes == 4) {
            uint32_t word = (uint32_t)bits;
            float value;
            memcpy(&value, &word, sizeof(value));
            return value;
        }
        double value;
        memcpy(&value, &bits, sizeof(value));
        return value;
    }
    UInt32 shift = (a->mFormatFlags & kAudioFormatFlagIsAlignedHigh) ? bytes * 8 - a->mBitsPerChannel : 0;
    uint64_t mask = (UINT64_C(1) << a->mBitsPerChannel) - 1;
    uint64_t raw = (bits >> shift) & mask;
    int64_t midpoint = INT64_C(1) << (a->mBitsPerChannel - 1);
    int64_t value = (int64_t)raw;
    if (!(a->mFormatFlags & kAudioFormatFlagIsSignedInteger))
        value -= midpoint;
    else if (raw & (uint64_t)midpoint)
        value -= (int64_t)(UINT64_C(1) << a->mBitsPerChannel);
    return (double)value / (double)midpoint;
}

static void
write_sample(AudioConverterRef c, const AudioStreamBasicDescription *source,
    const AudioStreamBasicDescription *a, UInt32 channel, UInt8 *p, double value)
{
    uint64_t bits;
    UInt32 bytes = sample_bytes(a);
    if (a->mFormatID != kAudioFormatLinearPCM) {
        double scaled = round(value * 32768.0);
        int sample = isnan(scaled) ? 0 : scaled >= 32767 ? 32767 : scaled <= -32768 ? -32768 : (int)scaled;
        *p = law_encode(sample, a->mFormatID == kAudioFormatALaw);
        return;
    }
    if (a->mFormatFlags & kAudioFormatFlagIsFloat) {
        if (bytes == 4) {
            float sample = (float)value;
            uint32_t word;
            memcpy(&word, &sample, sizeof(word));
            bits = word;
        } else {
            memcpy(&bits, &value, sizeof(bits));
        }
    } else {
        double midpoint = ldexp(1.0, a->mBitsPerChannel - 1);
        /* The 32-bit integer path rounds through single precision on the host. */
        if ((source->mFormatFlags & kAudioFormatFlagIsFloat) && a->mBitsPerChannel == 32)
            value = (float)value;
        double scaled = value * midpoint;
        if (c->dithering && a->mBitsPerChannel) {
            UInt32 depth = c->hasDitherDepth ? c->ditherDepth : a->mBitsPerChannel;
            double step = ldexp(1.0, (int)a->mBitsPerChannel - (int)depth);
            c->random = c->random * UINT32_C(1664525) + UINT32_C(1013904223);
            double first = (double)(c->random >> 8) / 16777216.0;
            c->random = c->random * UINT32_C(1664525) + UINT32_C(1013904223);
            double second = (double)(c->random >> 8) / 16777216.0;
            scaled += (first - second) * step;
            if (c->dithering == kDitherAlgorithm_NoiseShaping)
                scaled += 0.85 * c->ditherError[channel];
        }
        double unquantized = scaled;
        bool sourceFloat = (source->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
        if (sourceFloat && a->mBitsPerChannel == 16)
            scaled = round(scaled);
        else if (!sourceFloat && source->mBitsPerChannel == 16 && a->mBitsPerChannel == 8)
            scaled = floor(scaled);
        else
            scaled = floor(scaled + 0.5);
        int64_t sample = isnan(scaled) ? 0 : scaled >= midpoint ? (int64_t)midpoint - 1 :
            scaled <= -midpoint ? -(int64_t)midpoint : (int64_t)scaled;
        if (c->dithering == kDitherAlgorithm_NoiseShaping)
            c->ditherError[channel] = fmax(-1.0, fmin(1.0, unquantized - sample));
        if (!(a->mFormatFlags & kAudioFormatFlagIsSignedInteger))
            sample += (int64_t)midpoint;
        uint64_t mask = (UINT64_C(1) << a->mBitsPerChannel) - 1;
        UInt32 shift = (a->mFormatFlags & kAudioFormatFlagIsAlignedHigh) ? bytes * 8 - a->mBitsPerChannel : 0;
        bits = ((uint64_t)sample & mask) << shift;
    }
    for (UInt32 i = 0; i < bytes; i++)
        p[i] = (UInt8)(bits >> (8 * ((a->mFormatFlags & kAudioFormatFlagIsBigEndian) ? bytes - i - 1 : i)));
}

static bool
valid_buffers(const AudioStreamBasicDescription *a, const AudioBufferList *list, UInt32 frames)
{
    if (!list || list->mNumberBuffers != (planar(a) ? a->mChannelsPerFrame : 1))
        return false;
    uint64_t bytes = (uint64_t)frames * a->mBytesPerFrame;
    for (UInt32 i = 0; i < list->mNumberBuffers; i++)
        if (list->mBuffers[i].mNumberChannels != (planar(a) ? 1 : a->mChannelsPerFrame) ||
            list->mBuffers[i].mDataByteSize < bytes || (bytes && !list->mBuffers[i].mData))
            return false;
    return true;
}

OSStatus
AudioConverterConvertComplexBuffer(AudioConverterRef c, UInt32 frames, const AudioBufferList *input, AudioBufferList *output)
{
    if (!c || !valid_buffers(&c->input, input, frames) || !valid_buffers(&c->output, output, frames))
        return -50;
    if (c->input.mSampleRate != c->output.mSampleRate)
        return -50;
    for (UInt32 frame = 0; frame < frames; frame++) {
        for (UInt32 channel = 0; channel < c->output.mChannelsPerFrame; channel++) {
            SInt32 from = c->map[channel];
            double sample = 0;
            if (from >= 0) {
                const UInt8 *p = input->mBuffers[planar(&c->input) ? from : 0].mData;
                p += (size_t)frame * c->input.mBytesPerFrame + (planar(&c->input) ? 0 : from * sample_bytes(&c->input));
                sample = read_sample(&c->input, p);
            }
            UInt8 *p = output->mBuffers[planar(&c->output) ? channel : 0].mData;
            p += (size_t)frame * c->output.mBytesPerFrame +
                (planar(&c->output) ? 0 : channel * sample_bytes(&c->output));
            write_sample(c, &c->input, &c->output, channel, p, sample);
        }
    }
    for (UInt32 i = 0; i < output->mNumberBuffers; i++)
        output->mBuffers[i].mDataByteSize = frames * c->output.mBytesPerFrame;
    return noErr;
}

OSStatus
AudioConverterConvertBuffer(AudioConverterRef c, UInt32 inputBytes, const void *input, UInt32 *outputBytes, void *output)
{
    if (!c || !input || !outputBytes || !output || planar(&c->input) || planar(&c->output))
        return -50;
    if (!*outputBytes)
        return kAudioConverterErr_InvalidOutputSize;
    UInt32 frames = inputBytes / c->input.mBytesPerFrame;
    if ((uint64_t)frames * c->output.mBytesPerFrame > *outputBytes)
        return kAudioConverterErr_InvalidInputSize;
    AudioBufferList in = {1, {{c->input.mChannelsPerFrame, inputBytes, (void *)input}}};
    AudioBufferList out = {1, {{c->output.mChannelsPerFrame, *outputBytes, output}}};
    OSStatus status = AudioConverterConvertComplexBuffer(c, frames, &in, &out);
    if (!status)
        *outputBytes = out.mBuffers[0].mDataByteSize;
    return status;
}

OSStatus
AudioConverterGetPropertyInfo(AudioConverterRef c, AudioConverterPropertyID property, UInt32 *size, Boolean *writable)
{
    if (!c)
        return -50;
    UInt32 n;
    Boolean write = false;
    switch (property) {
        case kAudioConverterPropertyMinimumInputBufferSize:
        case kAudioConverterPropertyMinimumOutputBufferSize:
        case kAudioConverterPropertyMaximumInputPacketSize:
        case kAudioConverterPropertyMaximumOutputPacketSize:
        case kAudioConverterPropertyCalculateInputBufferSize:
        case kAudioConverterPropertyCalculateOutputBufferSize:
        case kAudioConverterSampleRateConverterComplexity:
        case kAudioConverterSampleRateConverterQuality:
        case kAudioConverterPrimeMethod:
        case kAudioConverterPropertyDithering:
        case kAudioConverterPropertyDitherBitDepth: n = sizeof(UInt32); write = property !=
            kAudioConverterPropertyMinimumInputBufferSize && property != kAudioConverterPropertyMinimumOutputBufferSize &&
            property != kAudioConverterPropertyMaximumInputPacketSize && property != kAudioConverterPropertyMaximumOutputPacketSize &&
            property != kAudioConverterPropertyCalculateInputBufferSize && property != kAudioConverterPropertyCalculateOutputBufferSize;
            break;
        case kAudioConverterSampleRateConverterInitialPhase: n = sizeof(Float64); write = true; break;
        case kAudioConverterPrimeInfo: n = sizeof(AudioConverterPrimeInfo); break;
        case kAudioConverterCurrentInputStreamDescription:
        case kAudioConverterCurrentOutputStreamDescription: n = sizeof(AudioStreamBasicDescription); break;
        case kAudioConverterChannelMap: n = c->output.mChannelsPerFrame * sizeof(SInt32); write = true; break;
        default: return kAudioConverterErr_PropertyNotSupported;
    }
    if (size)
        *size = n;
    if (writable)
        *writable = write;
    return noErr;
}

OSStatus
AudioConverterGetProperty(AudioConverterRef c, AudioConverterPropertyID property, UInt32 *size, void *data)
{
    if (!c || !size || !data)
        return -50;
    UInt32 need;
    OSStatus status = AudioConverterGetPropertyInfo(c, property, &need, NULL);
    if (status)
        return status;
    bool scalar = property != kAudioConverterChannelMap && property != kAudioConverterCurrentInputStreamDescription &&
        property != kAudioConverterCurrentOutputStreamDescription && property != kAudioConverterPrimeInfo;
    if (*size < need || (!scalar && *size != need))
        return kAudioConverterErr_BadPropertySizeError;
    UInt32 value = 0;
    switch (property) {
        case kAudioConverterCurrentInputStreamDescription: memcpy(data, &c->input, need); return noErr;
        case kAudioConverterCurrentOutputStreamDescription: memcpy(data, &c->output, need); return noErr;
        case kAudioConverterChannelMap: memcpy(data, c->map, need); *size = need; return noErr;
        case kAudioConverterSampleRateConverterInitialPhase: memcpy(data, &c->initialPhase, need); return noErr;
        case kAudioConverterSampleRateConverterComplexity: value = c->complexity; break;
        case kAudioConverterSampleRateConverterQuality: value = c->quality; break;
        case kAudioConverterPrimeMethod: value = c->primeMethod; break;
        case kAudioConverterPrimeInfo: {
            AudioConverterPrimeInfo info = {0, 0};
            memcpy(data, &info, sizeof(info));
            return noErr;
        }
        case kAudioConverterPropertyDithering: value = c->dithering; break;
        case kAudioConverterPropertyDitherBitDepth:
            if (!c->hasDitherDepth)
                return kAudioConverterErr_PropertyNotSupported;
            value = c->ditherDepth;
            break;
        case kAudioConverterPropertyMinimumInputBufferSize:
        case kAudioConverterPropertyMaximumInputPacketSize: value = c->input.mBytesPerFrame; break;
        case kAudioConverterPropertyMinimumOutputBufferSize:
        case kAudioConverterPropertyMaximumOutputPacketSize: value = c->output.mBytesPerFrame; break;
        case kAudioConverterPropertyCalculateInputBufferSize: {
            memcpy(&value, data, sizeof(value));
            UInt64 outputFrames = ((UInt64)value + c->output.mBytesPerFrame - 1) / c->output.mBytesPerFrame;
            long double scaled = (long double)outputFrames * c->input.mSampleRate / c->output.mSampleRate;
            UInt64 extra = c->input.mSampleRate != c->output.mSampleRate && c->srcRadius != 1 ? c->srcRadius / 2 : 0;
            UInt64 maximum = UINT32_MAX / c->input.mBytesPerFrame;
            if (!isfinite(scaled) || scaled < 0 || maximum < extra || ceill(scaled) > maximum - extra)
                return -50;
            UInt64 inputFrames = (UInt64)ceill(scaled) + extra;
            UInt64 result = inputFrames * c->input.mBytesPerFrame;
            if (result > UINT32_MAX)
                return -50;
            value = (UInt32)result;
            break;
        }
        case kAudioConverterPropertyCalculateOutputBufferSize: {
            memcpy(&value, data, sizeof(value));
            if (c->input.mSampleRate != c->output.mSampleRate) {
                value = 0;
                break;
            }
            UInt64 inputFrames = ((UInt64)value + c->input.mBytesPerFrame - 1) / c->input.mBytesPerFrame;
            UInt64 result = inputFrames * c->output.mBytesPerFrame;
            if (result > UINT32_MAX)
                return -50;
            value = (UInt32)result;
            break;
        }
        default: return kAudioConverterErr_PropertyNotSupported;
    }
    memcpy(data, &value, sizeof(value));
    return noErr;
}

OSStatus
AudioConverterSetProperty(AudioConverterRef c, AudioConverterPropertyID property, UInt32 size, const void *data)
{
    if (!c || !data)
        return -50;
    if (property == kAudioConverterChannelMap) {
        if (size != c->output.mChannelsPerFrame * sizeof(SInt32))
            return kAudioConverterErr_BadPropertySizeError;
        const SInt32 *map = data;
        for (UInt32 i = 0; i < c->output.mChannelsPerFrame; i++)
            if (map[i] < -1 || map[i] >= (SInt32)c->input.mChannelsPerFrame)
                return -50;
        memcpy(c->map, map, size);
        return noErr;
    }
    if (property == kAudioConverterSampleRateConverterInitialPhase) {
        if (size != sizeof(Float64))
            return kAudioConverterErr_BadPropertySizeError;
        Float64 phase;
        memcpy(&phase, data, sizeof(phase));
        if (!isfinite(phase) || phase < 0 || phase >= 1)
            return -50;
        c->initialPhase = phase;
        return AudioConverterReset(c);
    }
    if (size != sizeof(UInt32))
        return kAudioConverterErr_BadPropertySizeError;
    UInt32 value;
    memcpy(&value, data, sizeof(value));
    switch (property) {
        case kAudioConverterSampleRateConverterComplexity:
        case kAudioConverterSampleRateConverterQuality: {
            UInt32 oldComplexity = c->complexity, oldQuality = c->quality;
            if (property == kAudioConverterSampleRateConverterComplexity) {
                /* This filter is symmetric, so it cannot promise minimum phase. */
                if (value == kAudioConverterSampleRateConverterComplexity_MinimumPhase)
                    return kAudioConverterErr_OperationNotSupported;
                if (value != kAudioConverterSampleRateConverterComplexity_Linear &&
                    value != kAudioConverterSampleRateConverterComplexity_Normal &&
                    value != kAudioConverterSampleRateConverterComplexity_Mastering)
                    return -50;
                c->complexity = value;
            } else {
                if (value > kAudioConverterQuality_Max)
                    return -50;
                c->quality = value;
            }
            OSStatus status = build_src_filter(c);
            if (status) {
                c->complexity = oldComplexity;
                c->quality = oldQuality;
                build_src_filter(c);
                return status;
            }
            return AudioConverterReset(c);
        }
        case kAudioConverterPrimeMethod:
            if (value > kConverterPrimeMethod_None)
                return -50;
            c->primeMethod = value;
            return AudioConverterReset(c);
        case kAudioConverterPropertyDithering:
            if (value > kDitherAlgorithm_NoiseShaping)
                return -50;
            c->dithering = value;
            return AudioConverterReset(c);
        case kAudioConverterPropertyDitherBitDepth:
            if (!value || value > c->output.mBitsPerChannel)
                return -50;
            c->ditherDepth = value;
            c->hasDitherDepth = true;
            return noErr;
        default: return kAudioConverterErr_PropertyNotSupported;
    }
}

static Float64
src_sample(AudioConverterRef c, SInt64 frame, UInt32 channel)
{
    if (frame < 0 || (UInt64)frame < c->srcBaseFrame || (UInt64)frame >= c->srcTotalFrames)
        return 0;
    UInt64 offset = (UInt64)frame - c->srcBaseFrame;
    if (offset >= c->srcFrames)
        return 0;
    return c->srcSamples[(size_t)offset * c->input.mChannelsPerFrame + channel];
}

static void
src_compact_to(AudioConverterRef c, UInt64 first)
{
    if (first <= c->srcBaseFrame)
        return;
    UInt64 drop = first - c->srcBaseFrame;
    if (drop > c->srcFrames)
        drop = c->srcFrames;
    c->srcFrames -= (UInt32)drop;
    if (c->srcFrames)
        memmove(c->srcSamples, c->srcSamples + (size_t)drop * c->input.mChannelsPerFrame,
            (size_t)c->srcFrames * c->input.mChannelsPerFrame * sizeof(*c->srcSamples));
    c->srcBaseFrame += drop;
    if (!c->srcFrames && c->srcBaseFrame < first)
        c->srcBaseFrame = first;
}

static bool
src_position(AudioConverterRef c, UInt64 *center, Float64 *fraction)
{
    long double position = c->initialPhase + (long double)c->srcOutputFrame *
        c->input.mSampleRate / c->output.mSampleRate;
    if (!isfinite((double)position) || position < 0 || position > (long double)INT64_MAX - SRC_MAX_RADIUS)
        return false;
    *center = (UInt64)floorl(position);
    *fraction = (Float64)(position - *center);
    return true;
}

static UInt64
src_output_limit(AudioConverterRef c)
{
    long double count = (long double)c->srcTotalFrames * c->output.mSampleRate / c->input.mSampleRate;
    if (!isfinite((double)count) || count >= (long double)UINT64_MAX)
        return UINT64_MAX;
    return (UInt64)floorl(count);
}

static OSStatus
src_append(AudioConverterRef c, UInt32 frames)
{
    UInt64 center;
    Float64 fraction;
    if (!src_position(c, &center, &fraction))
        return kAudioConverterErr_InvalidInputSize;
    (void)fraction;
    UInt64 first = center > c->srcRadius ? center - c->srcRadius : 0;
    src_compact_to(c, first);
    for (UInt32 frame = 0; frame < frames; frame++) {
        if (c->srcTotalFrames == UINT64_MAX)
            return kAudioConverterErr_InvalidInputSize;
        UInt64 absolute = c->srcTotalFrames++;
        if (absolute < first)
            continue;
        if (c->srcFrames == SRC_QUEUE_FRAMES)
            return kAudioConverterErr_InvalidInputSize;
        if (!c->srcFrames)
            c->srcBaseFrame = absolute;
        for (UInt32 channel = 0; channel < c->input.mChannelsPerFrame; channel++) {
            const UInt8 *data = c->inputList->mBuffers[planar(&c->input) ? channel : 0].mData;
            data += (size_t)frame * c->input.mBytesPerFrame +
                (planar(&c->input) ? 0 : channel * sample_bytes(&c->input));
            c->srcSamples[(size_t)c->srcFrames * c->input.mChannelsPerFrame + channel] =
                read_sample(&c->input, data);
        }
        c->srcFrames++;
    }
    return noErr;
}

static void
src_output_frame(AudioConverterRef c, AudioBufferList *output, UInt32 frame, UInt64 center, Float64 fraction)
{
    UInt32 phase = (UInt32)(fraction * SRC_PHASES);
    Float64 blend = fraction * SRC_PHASES - phase;
    for (UInt32 channel = 0; channel < c->output.mChannelsPerFrame; channel++) {
        Float64 sample = 0;
        SInt32 from = c->map[channel];
        if (from >= 0) {
            if (!c->srcFilter) {
                Float64 a = src_sample(c, (SInt64)center, (UInt32)from);
                Float64 b = src_sample(c, (SInt64)center + 1, (UInt32)from);
                sample = a + (b - a) * fraction;
            } else {
                Float64 weightSum = 0;
                const Float64 *first = c->srcFilter + (size_t)phase * c->srcTaps;
                const Float64 *second = first + c->srcTaps;
                for (UInt32 tap = 0; tap < c->srcTaps; tap++) {
                    SInt64 index = (SInt64)center + (SInt64)tap - (SInt64)c->srcRadius + 1;
                    Float64 weight = first[tap] + (second[tap] - first[tap]) * blend;
                    if (index >= 0 && (UInt64)index < c->srcTotalFrames &&
                        (UInt64)index >= c->srcBaseFrame && (UInt64)index - c->srcBaseFrame < c->srcFrames) {
                        sample += src_sample(c, index, (UInt32)from) * weight;
                        weightSum += weight;
                    }
                }
                if (weightSum != 0)
                    sample /= weightSum;
            }
        }
        UInt8 *data = output->mBuffers[planar(&c->output) ? channel : 0].mData;
        data += (size_t)frame * c->output.mBytesPerFrame +
            (planar(&c->output) ? 0 : channel * sample_bytes(&c->output));
        write_sample(c, &c->input, &c->output, channel, data, sample);
    }
}

static OSStatus
fill_src(AudioConverterRef c, AudioConverterComplexInputDataProc callback, void *user,
    UInt32 requested, AudioBufferList *output, UInt32 *written)
{
    UInt32 done = 0;
    OSStatus status = noErr;
    while (done < requested) {
        UInt64 center;
        Float64 fraction;
        if (!src_position(c, &center, &fraction)) {
            status = kAudioConverterErr_InvalidInputSize;
            break;
        }
        if (c->srcEOF && c->srcOutputFrame >= src_output_limit(c))
            break;
        bool ready = c->srcEOF || center + c->srcRadius < c->srcTotalFrames;
        if (ready) {
            src_output_frame(c, output, done, center, fraction);
            done++;
            c->srcOutputFrame++;
            UInt64 nextCenter;
            Float64 nextFraction;
            if (src_position(c, &nextCenter, &nextFraction))
                src_compact_to(c, nextCenter > c->srcRadius ? nextCenter - c->srcRadius : 0);
            continue;
        }
        c->inputList->mNumberBuffers = planar(&c->input) ? c->input.mChannelsPerFrame : 1;
        for (UInt32 i = 0; i < c->inputList->mNumberBuffers; i++)
            c->inputList->mBuffers[i] = (AudioBuffer){planar(&c->input) ? 1 : c->input.mChannelsPerFrame, 0, NULL};
        UInt64 needed = center + c->srcRadius + 1 - c->srcTotalFrames;
        UInt32 frames = needed > SRC_CALLBACK_FRAMES ? SRC_CALLBACK_FRAMES : (UInt32)needed;
        UInt32 requestedFrames = frames;
        AudioStreamPacketDescription *inputDescriptions = NULL;
        status = callback(c, &frames, c->inputList, &inputDescriptions, user);
        if (status)
            break;
        if (!frames) {
            c->srcEOF = true;
            continue;
        }
        if (frames > requestedFrames || !valid_buffers(&c->input, c->inputList, frames)) {
            status = kAudioConverterErr_InvalidInputSize;
            break;
        }
        status = src_append(c, frames);
        if (status)
            break;
    }
    *written = done;
    return status;
}

static OSStatus
fill_pcm(AudioConverterRef c, AudioConverterComplexInputDataProc callback, void *user,
    UInt32 requested, AudioBufferList *output, UInt32 *written)
{
    UInt32 done = 0;
    OSStatus status = noErr;
    while (done < requested) {
        c->inputList->mNumberBuffers = planar(&c->input) ? c->input.mChannelsPerFrame : 1;
        for (UInt32 i = 0; i < c->inputList->mNumberBuffers; i++)
            c->inputList->mBuffers[i] = (AudioBuffer){planar(&c->input) ? 1 : c->input.mChannelsPerFrame, 0, NULL};
        UInt32 frames = requested - done;
        AudioStreamPacketDescription *inputDescriptions = NULL;
        status = callback(c, &frames, c->inputList, &inputDescriptions, user);
        if (status || !frames)
            break;
        if (frames > requested - done || !valid_buffers(&c->input, c->inputList, frames)) {
            status = kAudioConverterErr_InvalidInputSize;
            break;
        }
        c->outputList->mNumberBuffers = output->mNumberBuffers;
        for (UInt32 i = 0; i < output->mNumberBuffers; i++) {
            c->outputList->mBuffers[i] = output->mBuffers[i];
            c->outputList->mBuffers[i].mData = (UInt8 *)output->mBuffers[i].mData +
                (size_t)done * c->output.mBytesPerFrame;
            c->outputList->mBuffers[i].mDataByteSize -= done * c->output.mBytesPerFrame;
        }
        status = AudioConverterConvertComplexBuffer(c, frames, c->inputList, c->outputList);
        if (status)
            break;
        done += frames;
    }
    *written = done;
    return status;
}

static void
finish_fill(AudioConverterRef c, UInt32 done, UInt32 *packets, AudioBufferList *output,
    AudioStreamPacketDescription *descriptions)
{
    (void)descriptions;
    *packets = done;
    for (UInt32 i = 0; i < output->mNumberBuffers; i++)
        output->mBuffers[i].mDataByteSize = done * c->output.mBytesPerFrame;
}

OSStatus
AudioConverterFillComplexBuffer(AudioConverterRef c, AudioConverterComplexInputDataProc callback, void *user,
    UInt32 *packets, AudioBufferList *output, AudioStreamPacketDescription *descriptions)
{
    if (!c || !callback || !packets || !valid_buffers(&c->output, output, *packets))
        return -50;
    if (c->unbuffered)
        return kAudioConverterErr_OperationNotSupported;
    UInt32 requested = *packets, done = 0;
    OSStatus status = c->input.mSampleRate == c->output.mSampleRate ?
        fill_pcm(c, callback, user, requested, output, &done) :
        fill_src(c, callback, user, requested, output, &done);
    finish_fill(c, done, packets, output, descriptions);
    return status;
}

OSStatus
AudioConverterFillComplexBufferRealtimeSafe(AudioConverterRef c, AudioConverterComplexInputDataProcRealtimeSafe callback,
    void *user, UInt32 *packets, AudioBufferList *output, AudioStreamPacketDescription *descriptions)
{
    if (!c || !callback)
        return -50;
    if (c->input.mFormatID != kAudioFormatLinearPCM || c->output.mFormatID != kAudioFormatLinearPCM)
        return kAudioConverterErr_OperationNotSupported;
    return AudioConverterFillComplexBuffer(c, (AudioConverterComplexInputDataProc)callback, user,
        packets, output, descriptions);
}

OSStatus
AudioConverterFillComplexBufferWithPacketDependencies(AudioConverterRef c, AudioConverterComplexInputDataProc callback,
    void *user, UInt32 *packets, AudioBufferList *output, AudioStreamPacketDescription *descriptions,
    AudioStreamPacketDependencyDescription *dependencies)
{
    if (!dependencies)
        return -50;
    return AudioConverterFillComplexBuffer(c, callback, user, packets, output, descriptions);
}

struct LegacyInput {
    AudioConverterInputDataProc callback;
    void *user;
};

static OSStatus
legacy_input(AudioConverterRef c, UInt32 *packets, AudioBufferList *data,
    AudioStreamPacketDescription **descriptions, void *user)
{
    (void)descriptions;
    struct LegacyInput *legacy = user;
    if (planar(&c->input))
        return kAudioConverterErr_OperationNotSupported;
    UInt32 bytes = *packets * c->input.mBytesPerFrame;
    void *samples = NULL;
    OSStatus status = legacy->callback(c, &bytes, &samples, legacy->user);
    if (status)
        return status;
    *packets = bytes / c->input.mBytesPerFrame;
    data->mNumberBuffers = 1;
    data->mBuffers[0] = (AudioBuffer){c->input.mChannelsPerFrame, bytes, samples};
    return noErr;
}

OSStatus
AudioConverterFillBuffer(AudioConverterRef c, AudioConverterInputDataProc callback, void *user,
    UInt32 *outputBytes, void *output)
{
    if (!c || !callback || !outputBytes || !output || planar(&c->input) || planar(&c->output))
        return -50;
    if (c->unbuffered || c->input.mSampleRate != c->output.mSampleRate)
        return kAudioConverterErr_OperationNotSupported;
    if (*outputBytes % c->output.mBytesPerFrame)
        return kAudioConverterErr_InvalidOutputSize;
    struct LegacyInput legacy = {callback, user};
    UInt32 packets = *outputBytes / c->output.mBytesPerFrame;
    AudioBufferList list = {1, {{c->output.mChannelsPerFrame, *outputBytes, output}}};
    OSStatus status = AudioConverterFillComplexBuffer(c, legacy_input, &legacy, &packets, &list, NULL);
    *outputBytes = list.mBuffers[0].mDataByteSize;
    return status;
}
