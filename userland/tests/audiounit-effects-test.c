/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The effect, time and instrument audio units: what they describe of themselves
 * (parameters, presets, latency, formats), compared with Apple's, and what they do to a
 * signal, in terms coarse enough that Finch's own processing and Apple's agree (a filter
 * attenuates, a pitch shift doubles the frequency, a delay delays).
 */
#include <AudioToolbox/AudioToolbox.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

#define RATE 44100.0
#define SLICE 512

static const OSType units[][2] = {
    {'aufx', 'dely'}, {'aufx', 'dist'}, {'aufx', 'nbeq'}, {'aufx', 'mrev'}, {'aufx', 'rvb2'},
    {'aufx', 'lpas'}, {'aufx', 'hpas'}, {'aufx', 'bpas'}, {'aufx', 'lshf'}, {'aufx', 'hshf'},
    {'aufx', 'pmeq'}, {'aufx', 'lmtr'}, {'aufx', 'dcmp'}, {'aufx', 'sdly'}, {'aufx', 'nutp'},
    {'aufc', 'nutp'}, {'aufc', 'vari'}, {'aumu', 'samp'},
};

static const char *
fourcc(OSType v)
{
    static char b[4][5];
    static int n;
    char *o = b[n++ & 3];
    o[0] = (char)(v >> 24), o[1] = (char)(v >> 16), o[2] = (char)(v >> 8), o[3] = (char)v, o[4] = 0;
    return o;
}

static AudioUnit
make(OSType type, OSType subtype)
{
    AudioComponentDescription d = {type, subtype, kAudioUnitManufacturer_Apple, 0, 0};
    AudioComponent c = AudioComponentFindNext(NULL, &d);
    AudioUnit u = NULL;
    if (!c || AudioComponentInstanceNew(c, &u))
        return NULL;
    return u;
}

/* --- what the units say of themselves --- */

static void
describe(OSType type, OSType subtype)
{
    AudioComponentDescription d = {type, subtype, kAudioUnitManufacturer_Apple, 0, 0};
    AudioComponent c = AudioComponentFindNext(NULL, &d);
    if (!c) {
        printf("%s %s: missing\n", fourcc(type), fourcc(subtype));
        return;
    }
    CFStringRef name = NULL;
    AudioComponentCopyName(c, &name);
    char text[256] = "";
    if (name) {
        CFStringGetCString(name, text, sizeof text, kCFStringEncodingUTF8);
        CFRelease(name);
    }
    UInt32 version = 0;
    AudioComponentGetVersion(c, &version);
    printf("%s %s: \"%s\" version 0x%x\n", fourcc(type), fourcc(subtype), text, version);
    AudioUnit u = make(type, subtype);
    UInt32 size = 0;
    AudioUnitGetPropertyInfo(u, kAudioUnitProperty_ParameterList, kAudioUnitScope_Global, 0, &size, NULL);
    AudioUnitParameterID ids[256];
    AudioUnitGetProperty(u, kAudioUnitProperty_ParameterList, kAudioUnitScope_Global, 0, ids, &size);
    for (UInt32 i = 0; i < size / sizeof ids[0]; i++) {
        AudioUnitParameterInfo info;
        UInt32 isize = sizeof info;
        memset(&info, 0, sizeof info);
        OSStatus e = AudioUnitGetProperty(u, kAudioUnitProperty_ParameterInfo, kAudioUnitScope_Global, ids[i], &info, &isize);
        char pname[256] = "";
        if (info.cfNameString) {
            CFStringGetCString(info.cfNameString, pname, sizeof pname, kCFStringEncodingUTF8);
            if (info.flags & kAudioUnitParameterFlag_CFNameRelease)
                CFRelease(info.cfNameString);
        }
        AudioUnitParameterValue v = 0;
        AudioUnitGetParameter(u, ids[i], kAudioUnitScope_Global, 0, &v);
        printf("  param %u \"%s\" (%.20s) unit %u %g..%g default %g now %g flags %08x %d\n", ids[i], pname, info.name,
            info.unit, info.minValue, info.maxValue, info.defaultValue, v,
            info.flags & ~kAudioUnitParameterFlag_CFNameRelease, (int)e);
    }
    CFArrayRef presets = NULL;
    size = sizeof presets;
    if (!AudioUnitGetProperty(u, kAudioUnitProperty_FactoryPresets, kAudioUnitScope_Global, 0, &presets, &size)) {
        printf("  presets:");
        for (CFIndex i = 0; i < CFArrayGetCount(presets); i++) {
            const AUPreset *p = CFArrayGetValueAtIndex(presets, i);
            CFStringGetCString(p->presetName, text, sizeof text, kCFStringEncodingUTF8);
            printf(" %d=%s;", (int)p->presetNumber, text);
        }
        printf("\n");
        CFRelease(presets);
    }
    AUPreset present = {0, NULL};
    size = sizeof present;
    OSStatus e = AudioUnitGetProperty(u, kAudioUnitProperty_PresentPreset, kAudioUnitScope_Global, 0, &present, &size);
    if (!e && present.presetNumber >= 0) {
        CFStringGetCString(present.presetName, text, sizeof text, kCFStringEncodingUTF8);
        printf("  present preset %d %s\n", (int)present.presetNumber, text);
    } else
        printf("  present preset %d (%d)\n", e ? 0 : (int)present.presetNumber, (int)e);
    Float64 latency = -1, tail = -1;
    size = sizeof latency;
    AudioUnitGetProperty(u, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &latency, &size);
    size = sizeof tail;
    e = AudioUnitGetProperty(u, kAudioUnitProperty_TailTime, kAudioUnitScope_Global, 0, &tail, &size);
    printf("  latency %.4f tail %s\n", latency, e ? "error" : type == 'aufx' && subtype == 'dely' ? "(varies)" : "set");
    UInt32 bypass = 9;
    size = sizeof bypass;
    e = AudioUnitGetProperty(u, kAudioUnitProperty_BypassEffect, kAudioUnitScope_Global, 0, &bypass, &size);
    printf("  bypass %u (%d)\n", e ? 9 : bypass, (int)e);
    UInt32 inputs = 9, outputs = 9;
    size = sizeof inputs;
    AudioUnitGetProperty(u, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &inputs, &size);
    size = sizeof outputs;
    AudioUnitGetProperty(u, kAudioUnitProperty_ElementCount, kAudioUnitScope_Output, 0, &outputs, &size);
    AudioStreamBasicDescription f;
    size = sizeof f;
    AudioUnitGetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &f, &size);
    printf("  inputs %u outputs %u format %g Hz %u ch flags %x bits %u\n", inputs, outputs, f.mSampleRate,
        f.mChannelsPerFrame, f.mFormatFlags, f.mBitsPerChannel);
    if (subtype == 'nbeq') {
        UInt32 n = 0, max = 0;
        size = sizeof n;
        AudioUnitGetProperty(u, kAUNBandEQProperty_NumberOfBands, kAudioUnitScope_Global, 0, &n, &size);
        size = sizeof max;
        AudioUnitGetProperty(u, kAUNBandEQProperty_MaxNumberOfBands, kAudioUnitScope_Global, 0, &max, &size);
        printf("  bands %u max %u\n", n, max);
        n = 12;
        e = AudioUnitSetProperty(u, kAUNBandEQProperty_NumberOfBands, kAudioUnitScope_Global, 0, &n, sizeof n);
        size = 0;
        AudioUnitGetPropertyInfo(u, kAudioUnitProperty_ParameterList, kAudioUnitScope_Global, 0, &size, NULL);
        printf("  12 bands: %d, %u parameters\n", (int)e, size / 4);
        n = 17;
        printf("  17 bands: %d\n", (int)AudioUnitSetProperty(u, kAUNBandEQProperty_NumberOfBands, kAudioUnitScope_Global, 0, &n, sizeof n));
    }
    AudioComponentInstanceDispose(u);
}

/* --- what they do to a signal --- */

typedef struct {
    int kind; /* 0 sine, 1 impulse, 2 silence */
    double frequency, amplitude;
    double at;
    double pulled, half; /* (frames pulled, and pulled when half the output was rendered) */
} Source;

static OSStatus
source(void *refcon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time, UInt32 bus, UInt32 frames,
    AudioBufferList *data)
{
    (void)flags, (void)time, (void)bus;
    Source *s = refcon;
    for (UInt32 i = 0; i < frames; i++) {
        double t = s->at + i;
        float v = s->kind == 0 ? (float)(s->amplitude * sin(2 * M_PI * s->frequency * t / RATE))
                  : s->kind == 1 ? (t == 0 ? 1.0f : 0.0f) : 0.0f;
        for (UInt32 b = 0; b < data->mNumberBuffers; b++)
            ((float *)data->mBuffers[b].mData)[i] = v;
    }
    s->at += frames;
    s->pulled += frames;
    return noErr;
}

/* Renders total frames of the unit's left channel into out. */
static OSStatus
render(AudioUnit u, Source *s, float *out, UInt32 total)
{
    if (s) {
        AURenderCallbackStruct cb = {source, s};
        AudioUnitSetProperty(u, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb);
    }
    OSStatus e = AudioUnitInitialize(u);
    if (e)
        return e;
    float left[SLICE], right[SLICE];
    struct {
        UInt32 n;
        AudioBuffer b[2];
    } list;
    AudioTimeStamp ts = {0};
    ts.mFlags = kAudioTimeStampSampleTimeValid;
    for (UInt32 done = 0; done < total; done += SLICE) {
        list.n = 2;
        list.b[0] = (AudioBuffer){1, sizeof left, left};
        list.b[1] = (AudioBuffer){1, sizeof right, right};
        AudioUnitRenderActionFlags flags = 0;
        if ((e = AudioUnitRender(u, &flags, &ts, 0, SLICE, (AudioBufferList *)&list)))
            return e;
        memcpy(out + done, list.b[0].mData, SLICE * sizeof(float));
        ts.mSampleTime += SLICE;
        if (s && done + SLICE == total / 2)
            s->half = s->pulled;
    }
    return noErr;
}

static double
rms(const float *x, UInt32 from, UInt32 to)
{
    double sum = 0;
    for (UInt32 i = from; i < to; i++)
        sum += (double)x[i] * x[i];
    return sqrt(sum / (to - from));
}

static double
peak(const float *x, UInt32 from, UInt32 to)
{
    double m = 0;
    for (UInt32 i = from; i < to; i++)
        m = fmax(m, fabs(x[i]));
    return m;
}

/* The frequency, from upward zero crossings. */
static double
frequency(const float *x, UInt32 from, UInt32 to)
{
    int first = -1, last = -1, crossings = 0;
    for (UInt32 i = from + 1; i < to; i++)
        if (x[i - 1] < 0 && x[i] >= 0) {
            if (first < 0)
                first = (int)i;
            last = (int)i;
            crossings++;
        }
    return crossings > 1 ? (crossings - 1) * RATE / (last - first) : 0;
}

static double
decibels(double ratio)
{
    return 20 * log10(ratio);
}

#define TOTAL 32768
static float out[TOTAL];

static void
filters(void)
{
    struct {
        OSType subtype;
        double frequency;
        AudioUnitParameterID id;
        float value;
        const char *what;
    } cases[] = {
        {'lpas', 5000, 0, 500, "lowpass 500 Hz on 5 kHz"},
        {'lpas', 100, 0, 5000, "lowpass 5 kHz on 100 Hz"},
        {'hpas', 100, 0, 5000, "highpass 5 kHz on 100 Hz"},
        {'hpas', 5000, 0, 500, "highpass 500 Hz on 5 kHz"},
        {'bpas', 5000, 0, 5000, "bandpass at 5 kHz on 5 kHz"},
        {'bpas', 200, 0, 5000, "bandpass at 5 kHz on 200 Hz"},
        {'lshf', 50, 1, 12, "low shelf +12 dB on 50 Hz"},
        {'hshf', 18000, 1, -12, "high shelf -12 dB on 18 kHz"},
        {'pmeq', 2000, 2, 12, "parametric +12 dB at 2 kHz"},
    };
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        AudioUnit u = make('aufx', cases[i].subtype);
        AudioUnitSetParameter(u, cases[i].id, kAudioUnitScope_Global, 0, cases[i].value, 0);
        Source s = {0, cases[i].frequency, 0.5, 0, 0, 0};
        OSStatus e = render(u, &s, out, TOTAL);
        double db = decibels(rms(out, TOTAL / 2, TOTAL) / (0.5 / M_SQRT2));
        const char *verdict = db < -15 ? "cut" : db > 9 ? "boosted" : db < -9 ? "cut 9-15 dB" : fabs(db) < 1.5 ? "passed" : "partly";
        printf("%s: %s (%d)\n", cases[i].what, verdict, (int)e);
        AudioComponentInstanceDispose(u);
    }
    /* N-band EQ */
    AudioUnit u = make('aufx', 'nbeq');
    AudioUnitSetParameter(u, kAUNBandEQParam_BypassBand + 0, kAudioUnitScope_Global, 0, 0, 0);
    AudioUnitSetParameter(u, kAUNBandEQParam_Frequency + 0, kAudioUnitScope_Global, 0, 1000, 0);
    AudioUnitSetParameter(u, kAUNBandEQParam_Gain + 0, kAudioUnitScope_Global, 0, 12, 0);
    Source s = {0, 1000, 0.25, 0, 0, 0};
    render(u, &s, out, TOTAL);
    printf("nbeq +12 dB band at 1 kHz: %+.0f dB\n", decibels(rms(out, TOTAL / 2, TOTAL) / (0.25 / M_SQRT2)));
    AudioUnitUninitialize(u);
    AudioUnitSetParameter(u, kAUNBandEQParam_FilterType + 0, kAudioUnitScope_Global, 0, kAUNBandEQFilterType_2ndOrderButterworthLowPass, 0);
    AudioUnitSetParameter(u, kAUNBandEQParam_Frequency + 0, kAudioUnitScope_Global, 0, 300, 0);
    AudioUnitSetParameter(u, kAUNBandEQParam_GlobalGain, kAudioUnitScope_Global, 0, -6, 0);
    s = (Source){0, 5000, 0.25, 0, 0, 0};
    render(u, &s, out, TOTAL);
    printf("nbeq lowpass 300 Hz on 5 kHz: %s\n", decibels(rms(out, TOTAL / 2, TOTAL) / (0.25 / M_SQRT2)) < -30 ? "cut" : "not cut");
    AudioUnitUninitialize(u);
    AudioUnitSetParameter(u, kAUNBandEQParam_BypassBand + 0, kAudioUnitScope_Global, 0, 1, 0);
    s = (Source){0, 5000, 0.25, 0, 0, 0};
    render(u, &s, out, TOTAL);
    printf("nbeq bands bypassed, -6 dB global: %+.1f dB\n", decibels(rms(out, TOTAL / 2, TOTAL) / (0.25 / M_SQRT2)));
    AudioComponentInstanceDispose(u);
}

static void
delays(void)
{
    AudioUnit u = make('aufx', 'dely');
    AudioUnitSetParameter(u, kDelayParam_DelayTime, kAudioUnitScope_Global, 0, 0.01f, 0);
    AudioUnitSetParameter(u, kDelayParam_Feedback, kAudioUnitScope_Global, 0, 0, 0);
    AudioUnitSetParameter(u, kDelayParam_WetDryMix, kAudioUnitScope_Global, 0, 100, 0);
    AudioUnitSetParameter(u, kDelayParam_LopassCutoff, kAudioUnitScope_Global, 0, 22050, 0);
    Source s = {1, 0, 0, 0, 0, 0};
    render(u, &s, out, 4096);
    UInt32 at = 0;
    for (UInt32 i = 0; i < 4096; i++)
        if (fabsf(out[i]) > fabsf(out[at]))
            at = i;
    printf("delay 10 ms, all wet: impulse at %u, before %s\n", at, peak(out, 0, at > 3 ? at - 3 : 0) < 1e-4 ? "silent" : "not silent");
    AudioUnitUninitialize(u);
    AudioUnitSetParameter(u, kDelayParam_WetDryMix, kAudioUnitScope_Global, 0, 0, 0);
    s = (Source){0, 440, 0.5, 0, 0, 0};
    render(u, &s, out, 4096);
    float expect[4096];
    for (int i = 0; i < 4096; i++)
        expect[i] = (float)(0.5 * sin(2 * M_PI * 440 * i / RATE));
    double diff = 0;
    for (int i = 0; i < 4096; i++)
        diff = fmax(diff, fabs(out[i] - expect[i]));
    printf("delay all dry: %s\n", diff < 1e-4 ? "unchanged" : "changed");
    AudioComponentInstanceDispose(u);

    u = make('aufx', 'sdly');
    AudioUnitSetParameter(u, kSampleDelayParam_DelayFrames, kAudioUnitScope_Global, 0, 100, 0);
    s = (Source){1, 0, 0, 0, 0, 0};
    render(u, &s, out, 1024);
    at = 0;
    for (UInt32 i = 0; i < 1024; i++)
        if (out[i] != 0 && !at)
            at = i;
    printf("sample delay 100: impulse at %u value %g\n", at, out[at]);
    AudioComponentInstanceDispose(u);
}

static void
others(void)
{
    /* bypass passes the input through unchanged */
    AudioUnit u = make('aufx', 'dist');
    UInt32 on = 1;
    AudioUnitSetProperty(u, kAudioUnitProperty_BypassEffect, kAudioUnitScope_Global, 0, &on, sizeof on);
    Source s = {0, 440, 0.5, 0, 0, 0};
    render(u, &s, out, 4096);
    double diff = 0;
    for (int i = 0; i < 4096; i++)
        diff = fmax(diff, fabs(out[i] - 0.5 * sin(2 * M_PI * 440 * i / RATE)));
    printf("distortion bypassed: %s\n", diff < 1e-4 ? "unchanged" : "changed");
    on = 0;
    AudioUnitSetProperty(u, kAudioUnitProperty_BypassEffect, kAudioUnitScope_Global, 0, &on, sizeof on);
    render(u, &s, out, 4096);
    printf("distortion: %s\n", rms(out, 0, 4096) > 0.01 ? "sound" : "silence");
    AudioComponentInstanceDispose(u);

    const OSType reverbs[] = {'mrev', 'rvb2'};
    for (int r = 0; r < 2; r++) {
        u = make('aufx', reverbs[r]);
        AudioUnitSetParameter(u, 0, kAudioUnitScope_Global, 0, 100, 0);
        s = (Source){1, 0, 0, 0, 0, 0};
        render(u, &s, out, TOTAL);
        printf("%s impulse, all wet: tail at 0.2 s %s, at 0.6 s quieter %s\n", fourcc(reverbs[r]),
            rms(out, 8820, 9820) > 1e-5 ? "yes" : "no", rms(out, 26460, 27460) < rms(out, 8820, 9820) ? "yes" : "no");
        AudioComponentInstanceDispose(u);
    }

    u = make('aufx', 'lmtr');
    s = (Source){0, 440, 4.0, 0, 0, 0};
    render(u, &s, out, TOTAL);
    printf("limiter on amplitude 4: peak under 1.1 %s\n", peak(out, TOTAL / 2, TOTAL) < 1.1 ? "yes" : "no");
    AudioComponentInstanceDispose(u);

    u = make('aufx', 'dcmp');
    s = (Source){0, 440, 1.0, 0, 0, 0};
    render(u, &s, out, TOTAL);
    double loud = rms(out, TOTAL / 2, TOTAL);
    printf("dynamics on 0 dBFS: compressed %s\n", decibels(loud / M_SQRT1_2) < -3 ? "yes" : "no");
    AudioComponentInstanceDispose(u);
}

static void
time_units(void)
{
    struct {
        OSType type, subtype;
        AudioUnitParameterID id;
        float value;
        const char *what;
    } cases[] = {
        {'aufc', 'vari', kVarispeedParam_PlaybackRate, 2, "varispeed rate 2"},
        {'aufc', 'vari', kVarispeedParam_PlaybackRate, 0.5f, "varispeed rate 0.5"},
        {'aufc', 'nutp', kNewTimePitchParam_Rate, 2, "time-pitch rate 2"},
        {'aufc', 'nutp', kNewTimePitchParam_Rate, 0.5f, "time-pitch rate 0.5"},
        {'aufc', 'nutp', kNewTimePitchParam_Pitch, 1200, "time-pitch pitch +1200"},
        {'aufc', 'nutp', kNewTimePitchParam_Pitch, -1200, "time-pitch pitch -1200"},
        {'aufx', 'nutp', kNewTimePitchParam_Pitch, 700, "pitch +700"},
    };
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        AudioUnit u = make(cases[i].type, cases[i].subtype);
        AudioUnitSetParameter(u, cases[i].id, kAudioUnitScope_Global, 0, cases[i].value, 0);
        Source s = {0, 440, 0.5, 0, 0, 0};
        OSStatus e = render(u, &s, out, TOTAL);
        double f = frequency(out, TOTAL / 2, TOTAL);
        printf("%s: %d, input per output %.1f, frequency %.0f Hz (x%.2f)\n", cases[i].what, (int)e,
            (s.pulled - s.half) / (TOTAL / 2), round(f / 10) * 10, f / 440);
        AudioComponentInstanceDispose(u);
    }
    AudioUnit u = make('aufc', 'vari');
    AudioUnitSetParameter(u, kVarispeedParam_PlaybackRate, kAudioUnitScope_Global, 0, 2, 0);
    AudioUnitParameterValue v = 0;
    AudioUnitGetParameter(u, kVarispeedParam_PlaybackCents, kAudioUnitScope_Global, 0, &v);
    printf("varispeed rate 2: pitch %g\n", v);
    AudioUnitSetParameter(u, kVarispeedParam_PlaybackCents, kAudioUnitScope_Global, 0, -1200, 0);
    AudioUnitGetParameter(u, kVarispeedParam_PlaybackRate, kAudioUnitScope_Global, 0, &v);
    printf("varispeed pitch -1200: rate %g\n", v);
    AudioComponentInstanceDispose(u);
}

static void
sampler(void)
{
    AudioUnit u = make('aumu', 'samp');
    OSStatus e = render(u, NULL, out, 4096);
    printf("sampler, no notes: %d %s\n", (int)e, peak(out, 0, 4096) == 0 ? "silent" : "sound");
    MusicDeviceMIDIEvent(u, 0x90, 69, 127, 0);
    AudioTimeStamp ts = {0};
    ts.mFlags = kAudioTimeStampSampleTimeValid;
    float left[SLICE], right[SLICE];
    for (UInt32 done = 0; done < TOTAL; done += SLICE) {
        struct {
            UInt32 n;
            AudioBuffer b[2];
        } list = {2, {{1, sizeof left, left}, {1, sizeof right, right}}};
        AudioUnitRenderActionFlags flags = 0;
        AudioUnitRender(u, &flags, &ts, 0, SLICE, (AudioBufferList *)&list);
        memcpy(out + done, left, sizeof left);
        ts.mSampleTime += SLICE;
        if (done == TOTAL / 2)
            MusicDeviceMIDIEvent(u, 0x80, 69, 0, 0);
    }
    printf("sampler note 69: %s, frequency %.0f Hz\n", rms(out, 4096, TOTAL / 2) > 0.001 ? "sound" : "silence",
        round(frequency(out, 4096, TOTAL / 2) / 10) * 10);
    printf("sampler after note off: %s\n", rms(out, TOTAL - 4096, TOTAL) < rms(out, 4096, TOTAL / 2) / 10 ? "faded" : "still sounding");
    AudioComponentInstanceDispose(u);
}

int
main(void)
{
    for (size_t i = 0; i < sizeof units / sizeof units[0]; i++)
        describe(units[i][0], units[i][1]);
    filters();
    delays();
    others();
    time_units();
    sampler();
    return 0;
}
