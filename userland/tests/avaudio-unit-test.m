/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * AVAudioUnit and the units AVFAudio names: what they say of themselves, their
 * properties and how those stand for the audio units' parameters, and what they do in an
 * engine's graph, in terms coarse enough that Finch's processing and Apple's agree.
 */
#import <AVFAudio/AVFAudio.h>
#include <math.h>

static const char *
fourcc(OSType v)
{
    static char b[4][5];
    static int n;
    char *o = b[n++ & 3];
    o[0] = (char)(v >> 24), o[1] = (char)(v >> 16), o[2] = (char)(v >> 8), o[3] = (char)v, o[4] = 0;
    return o;
}

static const char *
format(AVAudioFormat *f)
{
    NSString *s = [f.description stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"%p", f] withString:@"F"];
    return s.UTF8String;
}

static float
param(AVAudioUnit *u, AudioUnitParameterID id)
{
    AudioUnitParameterValue v = -999;
    AudioUnitGetParameter(u.audioUnit, id, kAudioUnitScope_Global, 0, &v);
    return v;
}

static void
describe(const char *label, AVAudioUnit *u)
{
    AudioComponentDescription d = u.audioComponentDescription;
    printf("%s: %s %s %s %s \"%s\" by \"%s\" version %lu\n", label, object_getClassName(u), fourcc(d.componentType),
        fourcc(d.componentSubType), fourcc(d.componentManufacturer), u.name.UTF8String, u.manufacturerName.UTF8String,
        (unsigned long)u.version);
    printf("  inputs %lu outputs %lu unit %s latency %g\n", (unsigned long)u.numberOfInputs, (unsigned long)u.numberOfOutputs,
        u.audioUnit ? "yes" : "no", u.latency);
    /* (Apple's raises for the input format of a unit with no inputs) */
    if (u.numberOfInputs)
        printf("  in %s\n", format([u inputFormatForBus:0]));
    printf("  out %s\n", format([u outputFormatForBus:0]));
    if ([u respondsToSelector:@selector(bypass)])
        printf("  bypass %d\n", [(id)u bypass]);
}

static void
units(void)
{
    AVAudioUnitDelay *d = [AVAudioUnitDelay new];
    describe("delay", d);
    printf("  time %g feedback %g lowpass %g mix %g\n", d.delayTime, d.feedback, d.lowPassCutoff, d.wetDryMix);
    d.delayTime = 10;
    d.feedback = 200;
    d.wetDryMix = 150;
    printf("  set out of range: %g %g %g, unit %g %g %g\n", d.delayTime, d.feedback, d.wetDryMix, param(d, kDelayParam_DelayTime),
        param(d, kDelayParam_Feedback), param(d, kDelayParam_WetDryMix));
    AudioUnitSetParameter(d.audioUnit, kDelayParam_DelayTime, kAudioUnitScope_Global, 0, 0.25f, 0);
    AudioUnitSetParameter(d.audioUnit, kDelayParam_LopassCutoff, kAudioUnitScope_Global, 0, 900, 0);
    printf("  unit set: time %g (kept) lowpass %g (unit's)\n", d.delayTime, d.lowPassCutoff);
    d.bypass = YES;
    UInt32 bypass = 0, size = sizeof bypass;
    AudioUnitGetProperty(d.audioUnit, kAudioUnitProperty_BypassEffect, kAudioUnitScope_Global, 0, &bypass, &size);
    printf("  bypass %d unit %u\n", d.bypass, bypass);

    AVAudioUnitDistortion *x = [AVAudioUnitDistortion new];
    describe("distortion", x);
    printf("  pregain %g mix %g\n", x.preGain, x.wetDryMix);
    x.preGain = 3;
    [x loadFactoryPreset:AVAudioUnitDistortionPresetMultiEcho1];
    printf("  after preset: pregain %g (kept) mix %g (preset's)\n", x.preGain, x.wetDryMix);

    AVAudioUnitReverb *r = [AVAudioUnitReverb new];
    describe("reverb", r);
    AUPreset present = {0, NULL};
    size = sizeof present;
    AudioUnitGetProperty(r.audioUnit, kAudioUnitProperty_PresentPreset, kAudioUnitScope_Global, 0, &present, &size);
    printf("  mix %g preset %d %s\n", r.wetDryMix, (int)present.presetNumber, [(__bridge NSString *)present.presetName UTF8String]);
    [r loadFactoryPreset:AVAudioUnitReverbPresetCathedral];
    printf("  cathedral: mix %g\n", r.wetDryMix);
    r.wetDryMix = 30;
    [r loadFactoryPreset:AVAudioUnitReverbPresetPlate];
    printf("  set 30 then plate: mix %g\n", r.wetDryMix);

    AVAudioUnitTimePitch *tp = [AVAudioUnitTimePitch new];
    describe("time-pitch", tp);
    printf("  rate %g pitch %g overlap %g\n", tp.rate, tp.pitch, tp.overlap);
    tp.rate = 100;
    tp.pitch = 99999;
    tp.overlap = 0;
    printf("  set: %g %g %g unit %g %g %g\n", tp.rate, tp.pitch, tp.overlap, param(tp, kNewTimePitchParam_Rate),
        param(tp, kNewTimePitchParam_Pitch), param(tp, kNewTimePitchParam_Smoothness));

    AVAudioUnitVarispeed *v = [AVAudioUnitVarispeed new];
    describe("varispeed", v);
    v.rate = 2;
    printf("  rate %g unit pitch %g\n", v.rate, param(v, kVarispeedParam_PlaybackCents));

    AVAudioUnitSampler *s = [AVAudioUnitSampler new];
    describe("sampler", s);
    printf("  gain %g pan %g tuning %g volume %g\n", s.overallGain, s.stereoPan, s.globalTuning, s.volume);
    s.overallGain = -6;
    s.globalTuning = 150;
    s.stereoPan = 30;
    printf("  set: gain %g coarse %g fine %g pan %g master %g\n", param(s, kAUSamplerParam_Gain), param(s, kAUSamplerParam_CoarseTuning),
        param(s, kAUSamplerParam_FineTuning), param(s, kAUSamplerParam_Pan), s.masterGain);
    NSError *error = nil;
    BOOL ok = [s loadAudioFilesAtURLs:@[ [NSURL fileURLWithPath:@"/nonexistent.wav"] ] error:&error];
    printf("  load missing file: %d %s %ld\n", ok, error.domain.UTF8String, (long)error.code);
    error = nil;
    ok = [s loadSoundBankInstrumentAtURL:[NSURL fileURLWithPath:@"/nonexistent.sf2"] program:0 bankMSB:0x79 bankLSB:0 error:&error];
    printf("  load missing bank: %d %s %ld\n", ok, error.domain.UTF8String, (long)error.code);
}

static void
eq(void)
{
    AVAudioUnitEQ *e = [AVAudioUnitEQ new];
    describe("eq", e);
    printf("  bands %lu global %g\n", (unsigned long)e.bands.count, e.globalGain);
    const NSUInteger counts[] = {3, 10, 20};
    for (int i = 0; i < 3; i++) {
        e = [[AVAudioUnitEQ alloc] initWithNumberOfBands:counts[i]];
        UInt32 n = 0, size = sizeof n;
        AudioUnitGetProperty(e.audioUnit, kAUNBandEQProperty_NumberOfBands, kAudioUnitScope_Global, 0, &n, &size);
        printf("  %lu bands (unit %u):", (unsigned long)counts[i], n);
        for (AVAudioUnitEQFilterParameters *b in e.bands)
            printf(" %.1f", b.frequency);
        printf("\n");
    }
    AVAudioUnitEQFilterParameters *b = e.bands[1];
    printf("  band: type %ld bandwidth %g gain %g bypass %d\n", (long)b.filterType, b.bandwidth, b.gain, b.bypass);
    b.filterType = AVAudioUnitEQFilterTypeHighShelf;
    b.bypass = NO;
    b.gain = 6;
    b.frequency = 50000;
    printf("  set: unit type %g bypass %g gain %g frequency %g\n", param(e, kAUNBandEQParam_FilterType + 1),
        param(e, kAUNBandEQParam_BypassBand + 1), param(e, kAUNBandEQParam_Gain + 1), param(e, kAUNBandEQParam_Frequency + 1));
}

static void
kinds(void)
{
    const AudioComponentDescription ds[] = {
        {'aufx', 'dely', 'appl', 0, 0},
        {'aufc', 'vari', 'appl', 0, 0},
        {'aumu', 'samp', 'appl', 0, 0},
        {'aufx', 'lpas', 'appl', 0, 0},
        {'aufx', 'zzzz', 'appl', 0, 0},
    };
    for (int i = 0; i < 5; i++) {
        __block int called = 0;
        OSType subtype = ds[i].componentSubType;
        [AVAudioUnit instantiateWithComponentDescription:ds[i] options:0 completionHandler:^(AVAudioUnit *u, NSError *e) {
          called = 1;
          printf("instantiate %s: %s %s error %ld\n", fourcc(subtype), u ? object_getClassName(u) : "nil",
              u.name.UTF8String, (long)e.code);
        }];
        if (!called)
            printf("instantiate %s: later\n", fourcc(ds[i].componentSubType));
    }
    @try {
        AVAudioUnitEffect *bogus = [[AVAudioUnitEffect alloc] initWithAudioComponentDescription:ds[4]];
        printf("bogus effect made %d\n", bogus != nil);
    } @catch (NSException *ex) {
        printf("bogus effect: %s: %s\n", ex.name.UTF8String, ex.reason.UTF8String);
    }
    AVAudioUnitEffect *plain = [AVAudioUnitEffect new];
    printf("plain effect: unit %s name %s\n", plain.audioUnit ? "yes" : "no", plain.name.UTF8String);
    AVAudioUnitMIDIInstrument *mi = [[AVAudioUnitMIDIInstrument alloc] initWithAudioComponentDescription:ds[2]];
    printf("instrument: inputs %lu outputs %lu volume %g pan %g\n", (unsigned long)mi.numberOfInputs, (unsigned long)mi.numberOfOutputs,
        mi.volume, mi.pan);
    AVAudioUnitEffect *lp = [[AVAudioUnitEffect alloc] initWithAudioComponentDescription:ds[3]];
    printf("lowpass effect: %s\n", lp.name.UTF8String);
}

/* --- in a graph --- */

static AVAudioFormat *stereo;

static double
rms(AVAudioPCMBuffer *b)
{
    double sum = 0;
    for (AVAudioFrameCount i = 0; i < b.frameLength; i++)
        sum += b.floatChannelData[0][i] * b.floatChannelData[0][i];
    return sqrt(sum / b.frameLength);
}

static double
frequency(const float *x, AVAudioFrameCount n)
{
    int first = -1, last = -1, crossings = 0;
    for (AVAudioFrameCount i = 1; i < n; i++)
        if (x[i - 1] < 0 && x[i] >= 0) {
            if (first < 0)
                first = (int)i;
            last = (int)i;
            crossings++;
        }
    return crossings > 1 ? (crossings - 1) * 44100.0 / (last - first) : 0;
}

static AVAudioPCMBuffer *
sine(double hz, AVAudioFrameCount frames)
{
    AVAudioPCMBuffer *b = [[AVAudioPCMBuffer alloc] initWithPCMFormat:stereo frameCapacity:frames];
    b.frameLength = frames;
    for (AVAudioFrameCount i = 0; i < frames; i++)
        b.floatChannelData[0][i] = b.floatChannelData[1][i] = (float)(0.5 * sin(2 * M_PI * hz * i / 44100.0));
    return b;
}

/* Plays a sine through the unit for slices of 4096 frames; reports what came out. */
static void
through(const char *label, AVAudioUnit *unit, double hz, int slices)
{
    AVAudioEngine *engine = [AVAudioEngine new];
    AVAudioPlayerNode *player = [AVAudioPlayerNode new];
    [engine attachNode:player];
    [engine attachNode:unit];
    [engine connect:player to:unit format:stereo];
    [engine connect:unit to:engine.mainMixerNode format:stereo];
    NSError *error = nil;
    [engine enableManualRenderingMode:AVAudioEngineManualRenderingModeOffline format:stereo maximumFrameCount:4096 error:&error];
    [player scheduleBuffer:sine(hz, 44100 * 8) completionHandler:nil];
    [engine startAndReturnError:&error];
    [player play];
    AVAudioPCMBuffer *out = [[AVAudioPCMBuffer alloc] initWithPCMFormat:stereo frameCapacity:4096];
    double level = 0, f = 0;
    AVAudioFramePosition t0 = 0;
    for (int k = 0; k < slices; k++) {
        [engine renderOffline:4096 toBuffer:out error:&error];
        if (k == slices / 2)
            t0 = [player playerTimeForNodeTime:player.lastRenderTime].sampleTime;
        if (k == slices - 1) {
            level = rms(out);
            f = frequency(out.floatChannelData[0], 4096);
        }
    }
    AVAudioFramePosition t1 = [player playerTimeForNodeTime:player.lastRenderTime].sampleTime;
    double ratio = (double)(t1 - t0) / (4096.0 * (slices - 1 - slices / 2));
    printf("%s: level %.2f frequency %.0f Hz, input per output %.1f\n", label, level, round(f / 10) * 10, ratio);
    [engine stop];
}

static void
graphs(void)
{
    stereo = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100 channels:2];
    through("no effect (mixer only)", [[AVAudioUnitEffect alloc] initWithAudioComponentDescription:(AudioComponentDescription){'aufx', 'sdly', 'appl', 0, 0}], 440, 8);
    AVAudioUnitDelay *d = [AVAudioUnitDelay new];
    d.wetDryMix = 0;
    through("delay, all dry", d, 440, 8);
    d = [AVAudioUnitDelay new];
    d.bypass = YES;
    through("delay, bypassed", d, 440, 8);
    AVAudioUnitEQ *e = [[AVAudioUnitEQ alloc] initWithNumberOfBands:1];
    e.bands[0].filterType = AVAudioUnitEQFilterTypeLowPass;
    e.bands[0].frequency = 200;
    e.bands[0].bypass = NO;
    through("eq lowpass 200 Hz on 5 kHz", e, 5000, 8);
    e = [[AVAudioUnitEQ alloc] initWithNumberOfBands:1];
    e.globalGain = -6;
    through("eq -6 dB", e, 440, 8);
    AVAudioUnitVarispeed *v = [AVAudioUnitVarispeed new];
    v.rate = 2;
    through("varispeed 2", v, 440, 12);
    AVAudioUnitTimePitch *tp = [AVAudioUnitTimePitch new];
    tp.rate = 2;
    through("time-pitch rate 2", tp, 440, 12);
    tp = [AVAudioUnitTimePitch new];
    tp.pitch = 1200;
    through("time-pitch pitch +1200", tp, 440, 12);

    AVAudioEngine *engine = [AVAudioEngine new];
    AVAudioUnitSampler *s = [AVAudioUnitSampler new];
    [engine attachNode:s];
    [engine connect:s to:engine.mainMixerNode format:stereo];
    NSError *error = nil;
    [engine enableManualRenderingMode:AVAudioEngineManualRenderingModeOffline format:stereo maximumFrameCount:4096 error:&error];
    [engine startAndReturnError:&error];
    AVAudioPCMBuffer *out = [[AVAudioPCMBuffer alloc] initWithPCMFormat:stereo frameCapacity:4096];
    [engine renderOffline:4096 toBuffer:out error:&error];
    printf("sampler, no note: %s\n", rms(out) == 0 ? "silent" : "sound");
    [s startNote:69 withVelocity:127 onChannel:0];
    [engine renderOffline:4096 toBuffer:out error:&error];
    [engine renderOffline:4096 toBuffer:out error:&error];
    printf("sampler, note 69: %s at %.0f Hz\n", rms(out) > 0.001 ? "sound" : "silent", round(frequency(out.floatChannelData[0], 4096) / 10) * 10);
    [s stopNote:69 onChannel:0];
    for (int k = 0; k < 8; k++)
        [engine renderOffline:4096 toBuffer:out error:&error];
    printf("sampler, note stopped: %s\n", rms(out) < 0.001 ? "faded" : "sounding");
    [engine stop];
}

int
main(void)
{
    @autoreleasepool {
        units();
        eq();
        kinds();
        graphs();
    }
    return 0;
}
