/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Finch's effect, time and instrument units.
 *
 * The parameters, their ranges and the factory presets are Apple's (taken as data into
 * AudioUnitEffectTables.c); the signal processing is Finch's own and does not try to
 * reproduce Apple's units sample for sample:
 *
 *   filters and EQ    RBJ-cookbook biquads (AULowpass, AUHipass, the shelves,
 *                     AUParametricEQ, every AUNBandEQ band type; AUBandpass is a highpass
 *                     and a lowpass at the band's edges)
 *   AUDelay           a delay line with feedback through a one-pole lowpass
 *   AUSampleDelay     a whole-sample delay
 *   AUDistortion      echo, decimation and rounding, polynomial shaping, ring modulation
 *                     and soft clipping, each with its mix, in that order
 *   reverbs           Schroeder-Moorer: eight damped combs into four allpasses a side
 *   AUPeakLimiter     a look-ahead peak limiter (the look-ahead is the attack time)
 *   AUDynamicsProcessor  a compressor whose output approaches threshold + headroom,
 *                     with a downward expander below the expansion threshold
 *   AUVarispeed       cubic resampling (rate and pitch are one control)
 *   AUNewTimePitch    WSOLA: half-overlapping windowed grains, read at the pitch ratio,
 *                     placed so the input advances at the rate, each starting where it
 *                     best continues the one before
 *   AUSampler         sine voices, or the audio files loaded into it, played by note
 */
#include "AudioUnitEffects.h"
#include <math.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#define MAX_CHANNELS 32
#define MAX_BANDS 64
#define USUAL_MAX_BANDS 16
#define MAX_PARAMS 48
#define MAX_VOICES 32
#define MAX_ZONES 16
#define GRAIN_BASE 2048

enum Kind {
    KindDelay,
    KindDistortion,
    KindNBandEQ,
    KindMatrixReverb,
    KindReverb2,
    KindLowpass,
    KindHighpass,
    KindBandpass,
    KindLowShelf,
    KindHighShelf,
    KindParametricEQ,
    KindLimiter,
    KindDynamics,
    KindSampleDelay,
    KindPitch,
    KindTimePitch,
    KindVarispeed,
    KindSampler
};

struct Biquad {
    double b0, b1, b2, a1, a2;
    double z1[MAX_CHANNELS], z2[MAX_CHANNELS];
};

struct Band {
    float bypass, type, frequency, gain, bandwidth;
};

/* A delay line for each channel. */
struct Lines {
    float *data[MAX_CHANNELS];
    UInt32 length, position;
};

#define COMBS 8
#define ALLPASSES 4

struct Reverb {
    float *comb[2][COMBS];
    UInt32 combLength[2][COMBS], combPosition[2][COMBS], combCapacity;
    float combStore[2][COMBS];
    float *allpass[2][ALLPASSES];
    UInt32 allpassLength[2][ALLPASSES], allpassPosition[2][ALLPASSES];
    struct Lines pre;
    struct Biquad tone;
};

/* Input kept for the time units, which read it at their own pace. */
struct Fifo {
    float *data[MAX_CHANNELS];
    UInt32 capacity, count;
    double base; /* (the input frame data[c][0] is) */
};

struct Voice {
    bool active, released;
    int note, zone;
    float velocity, envelope;
    double phase;
};

struct Zone {
    float *data[2];
    UInt32 frames, channels;
    double rate;
    int root;
};

struct Effect {
    const struct EffectTable *table;
    enum Kind kind;
    float values[MAX_PARAMS];
    int bands, maxBands;
    struct Band band[MAX_BANDS];
    float globalGain;
    SInt32 preset;
    CFStringRef presetName;
    UInt32 bypass;

    double rate;
    UInt32 channels, maxFrames;
    bool ready;
    float *scratch[MAX_CHANNELS];

    struct Biquad filter[MAX_BANDS];
    struct Lines lines;
    float lowpass[MAX_CHANNELS];
    struct Reverb *reverb;

    /* dynamics */
    float envelope, gain;
    struct Lines ahead;

    /* distortion */
    struct Lines echo;
    double ring1, ring2, holdCount;
    float hold[MAX_CHANNELS];

    /* time units */
    struct Fifo fifo;
    double position; /* (varispeed: the next input frame to read; time-pitch: the next grain's) */
    double previous; /* (time-pitch: where the last grain started) */
    float *accumulator[MAX_CHANNELS], *weight, *window;
    UInt32 accumulatorSize, grain;
    double outPosition, nextGrain;

    /* sampler */
    struct Voice voice[MAX_VOICES];
    struct Zone zone[MAX_ZONES];
    int zones;
    float bend, volume, expression, pan;
    bool sustain;
};

static const struct {
    OSType type, subtype;
    enum Kind kind;
} kinds[] = {
    {'aufx', 'dely', KindDelay}, {'aufx', 'dist', KindDistortion}, {'aufx', 'nbeq', KindNBandEQ},
    {'aufx', 'mrev', KindMatrixReverb}, {'aufx', 'rvb2', KindReverb2}, {'aufx', 'lpas', KindLowpass},
    {'aufx', 'hpas', KindHighpass}, {'aufx', 'bpas', KindBandpass}, {'aufx', 'lshf', KindLowShelf},
    {'aufx', 'hshf', KindHighShelf}, {'aufx', 'pmeq', KindParametricEQ}, {'aufx', 'lmtr', KindLimiter},
    {'aufx', 'dcmp', KindDynamics}, {'aufx', 'sdly', KindSampleDelay}, {'aufx', 'nutp', KindPitch},
    {'aufc', 'nutp', KindTimePitch}, {'aufc', 'vari', KindVarispeed}, {'aumu', 'samp', KindSampler},
};

/* --- parameters --- */

static int
param_index(const struct Effect *e, AudioUnitParameterID id)
{
    for (int i = 0; i < e->table->paramCount && i < MAX_PARAMS; i++)
        if (e->table->params[i].id == id)
            return i;
    return -1;
}

static float
P(const struct Effect *e, AudioUnitParameterID id)
{
    int i = param_index(e, id);
    return i < 0 ? 0 : e->values[i];
}

static void
setP(struct Effect *e, AudioUnitParameterID id, float v)
{
    int i = param_index(e, id);
    if (i >= 0)
        e->values[i] = v;
}

/* The frequency a new AUNBandEQ band starts at. */
static float
band_frequency(int band)
{
    return (float)(40.0 * pow(250.0, band / 15.0));
}

static void
default_band(struct Band *b, int index)
{
    b->bypass = 1;
    b->type = 0;
    b->frequency = band_frequency(index);
    b->gain = 0;
    b->bandwidth = 0.5f;
}

static void
load_values(struct Effect *e, const float *values)
{
    if (e->kind == KindNBandEQ)
        return;
    for (int i = 0; i < e->table->paramCount && i < MAX_PARAMS; i++)
        e->values[i] = values[i];
}

static void
set_preset_name(struct Effect *e, SInt32 number, CFStringRef name)
{
    if (e->presetName)
        CFRelease(e->presetName);
    e->preset = number;
    e->presetName = name ? CFRetain(name) : NULL;
}

static bool
load_preset(struct Effect *e, SInt32 number)
{
    for (int i = 0; i < e->table->presetCount; i++) {
        const struct EffectPreset *p = &e->table->presets[i];
        if (p->number != number)
            continue;
        load_values(e, p->values);
        CFStringRef name = CFStringCreateWithCString(kCFAllocatorDefault, p->name, kCFStringEncodingUTF8);
        set_preset_name(e, number, name);
        if (name)
            CFRelease(name);
        return true;
    }
    return false;
}

struct Effect *
_FinchEffectNew(const struct EffectTable *table)
{
    struct Effect *e = calloc(1, sizeof *e);
    if (!e)
        return NULL;
    e->table = table;
    for (size_t i = 0; i < sizeof kinds / sizeof kinds[0]; i++)
        if (kinds[i].type == table->type && kinds[i].subtype == table->subtype)
            e->kind = kinds[i].kind;
    for (int i = 0; i < table->paramCount && i < MAX_PARAMS; i++)
        e->values[i] = table->params[i].initial;
    if (e->kind == KindNBandEQ) {
        e->maxBands = USUAL_MAX_BANDS;
        e->bands = 0;
        for (int i = 0; i < table->paramCount; i++)
            if (table->params[i].id >= 1000 && table->params[i].id < 2000)
                e->bands++;
        for (int b = 0; b < MAX_BANDS; b++)
            default_band(&e->band[b], b);
    }
    e->preset = -1;
    if (table->initialPreset >= 0)
        load_preset(e, table->initialPreset);
    e->volume = 1;
    e->expression = 1;
    e->gain = 1;
    return e;
}

static void free_buffers(struct Effect *e);

void
_FinchEffectDispose(struct Effect *e)
{
    if (!e)
        return;
    free_buffers(e);
    for (int z = 0; z < e->zones; z++) {
        free(e->zone[z].data[0]);
        free(e->zone[z].data[1]);
    }
    if (e->presetName)
        CFRelease(e->presetName);
    free(e);
}

Boolean
_FinchEffectHasInput(const struct EffectTable *table)
{
    return table->type != 'aumu';
}

static bool
nband_id(const struct Effect *e, AudioUnitParameterID id, float **slot)
{
    if (e->kind != KindNBandEQ)
        return false;
    struct Effect *m = (struct Effect *)e;
    if (id == 0) {
        *slot = &m->globalGain;
        return true;
    }
    int band = (int)(id % 1000), group = (int)(id / 1000);
    if (id < 1000 || group > 5 || band >= e->bands)
        return false;
    struct Band *b = &m->band[band];
    float *slots[] = {NULL, &b->bypass, &b->type, &b->frequency, &b->gain, &b->bandwidth};
    *slot = slots[group];
    return true;
}

OSStatus
_FinchEffectGetParameter(struct Effect *e, AudioUnitParameterID id, AudioUnitScope scope,
    AudioUnitElement element, AudioUnitParameterValue *value)
{
    (void)scope;
    (void)element;
    float *slot;
    if (nband_id(e, id, &slot)) {
        *value = *slot;
        return noErr;
    }
    int i = param_index(e, id);
    if (i < 0 || e->kind == KindNBandEQ)
        return kAudioUnitErr_InvalidParameter;
    *value = e->values[i];
    return noErr;
}

OSStatus
_FinchEffectSetParameter(struct Effect *e, AudioUnitParameterID id, AudioUnitScope scope,
    AudioUnitElement element, AudioUnitParameterValue value)
{
    (void)scope;
    (void)element;
    float *slot;
    if (nband_id(e, id, &slot)) {
        *slot = value;
        return noErr;
    }
    int i = param_index(e, id);
    if (i < 0 || e->kind == KindNBandEQ)
        return kAudioUnitErr_InvalidParameter;
    e->values[i] = value;
    /* (varispeed's rate and pitch are one control) */
    if (e->kind == KindVarispeed && id == kVarispeedParam_PlaybackRate && value > 0)
        setP(e, kVarispeedParam_PlaybackCents, (float)(1200.0 * log2(value)));
    else if (e->kind == KindVarispeed && id == kVarispeedParam_PlaybackCents)
        setP(e, kVarispeedParam_PlaybackRate, (float)pow(2.0, value / 1200.0));
    return noErr;
}

/* --- properties --- */

static UInt32
param_count(const struct Effect *e)
{
    return e->kind == KindNBandEQ ? 1 + 5 * (UInt32)e->bands : (UInt32)e->table->paramCount;
}

static const struct EffectParam *
param_info(const struct Effect *e, AudioUnitParameterID id)
{
    if (e->kind == KindNBandEQ) {
        /* (every band's parameter is described as band 0's) */
        float *slot;
        if (!nband_id(e, id, &slot))
            return NULL;
        AudioUnitParameterID base = id < 1000 ? id : id - id % 1000;
        for (int i = 0; i < e->table->paramCount; i++)
            if (e->table->params[i].id == base)
                return &e->table->params[i];
        return NULL;
    }
    int i = param_index(e, id);
    return i < 0 ? NULL : &e->table->params[i];
}

static CFArrayRef
factory_presets(const struct EffectTable *table)
{
    static AUPreset *made[64];
    static CFArrayRef arrays[64];
    size_t index = (size_t)(table - _FinchEffectTables);
    if (index >= 64 || !table->presetCount)
        return NULL;
    if (!arrays[index]) {
        /* (made once and kept, as the presets are the unit's for good) */
        AUPreset *presets = calloc((size_t)table->presetCount, sizeof *presets);
        const void **items = calloc((size_t)table->presetCount, sizeof *items);
        if (!presets || !items) {
            free(presets);
            free(items);
            return NULL;
        }
        for (int i = 0; i < table->presetCount; i++) {
            presets[i].presetNumber = table->presets[i].number;
            presets[i].presetName = CFStringCreateWithCString(kCFAllocatorDefault, table->presets[i].name, kCFStringEncodingUTF8);
            items[i] = &presets[i];
        }
        CFArrayRef array = CFArrayCreate(kCFAllocatorDefault, items, table->presetCount, NULL);
        free(items);
        if (!__sync_bool_compare_and_swap(&arrays[index], NULL, array)) {
            CFRelease(array);
        } else
            made[index] = presets;
    }
    return arrays[index];
}

OSStatus
_FinchEffectPropertyInfo(struct Effect *e, AudioUnitPropertyID id, AudioUnitScope scope,
    AudioUnitElement element, UInt32 *size, Boolean *writable)
{
    Boolean w = false;
    switch (id) {
    case kAudioUnitProperty_ParameterList:
        if (scope != kAudioUnitScope_Global)
            return kAudioUnitErr_InvalidScope;
        *size = param_count(e) * sizeof(AudioUnitParameterID);
        break;
    case kAudioUnitProperty_ParameterInfo:
        if (scope != kAudioUnitScope_Global)
            return kAudioUnitErr_InvalidScope;
        if (!param_info(e, element))
            return kAudioUnitErr_InvalidParameter;
        *size = sizeof(AudioUnitParameterInfo);
        break;
    case kAudioUnitProperty_FactoryPresets:
        if (!e->table->presetCount)
            return kAudioUnitErr_InvalidProperty;
        *size = sizeof(CFArrayRef);
        break;
    case kAudioUnitProperty_PresentPreset:
    case kAudioUnitProperty_CurrentPreset:
        *size = sizeof(AUPreset);
        w = true;
        break;
    case kAudioUnitProperty_BypassEffect:
        if (e->kind == KindSampler)
            return kAudioUnitErr_InvalidProperty;
        *size = sizeof(UInt32);
        w = true;
        break;
    case kAudioUnitProperty_TailTime:
        /* (the time-pitch unit and the sampler have none, as Apple's haven't) */
        if (e->kind == KindTimePitch || e->kind == KindSampler)
            return kAudioUnitErr_InvalidProperty;
        /* fall through */
    case kAudioUnitProperty_Latency:
        if (scope != kAudioUnitScope_Global)
            return kAudioUnitErr_InvalidScope;
        *size = sizeof(Float64);
        break;
    case kAUNBandEQProperty_NumberOfBands:
    case kAUNBandEQProperty_MaxNumberOfBands:
    case kFinchNBandEQProperty_BandLimit:
        if (e->kind != KindNBandEQ)
            return kAudioUnitErr_InvalidProperty;
        *size = sizeof(UInt32);
        w = id != kAUNBandEQProperty_MaxNumberOfBands;
        break;
    case kAUSamplerProperty_LoadInstrument:
        if (e->kind != KindSampler)
            return kAudioUnitErr_InvalidProperty;
        *size = sizeof(AUSamplerInstrumentData);
        w = true;
        break;
    case kAUSamplerProperty_LoadAudioFiles:
        if (e->kind != KindSampler)
            return kAudioUnitErr_InvalidProperty;
        *size = sizeof(CFArrayRef);
        w = true;
        break;
    default:
        return kAudioUnitErr_InvalidProperty;
    }
    if (writable)
        *writable = w;
    return noErr;
}

static OSStatus
give(const void *value, UInt32 size, void *data, UInt32 *ioSize)
{
    if (*ioSize < size)
        return kAudioUnitErr_InvalidPropertyValue;
    memcpy(data, value, size);
    *ioSize = size;
    return noErr;
}

OSStatus
_FinchEffectGetProperty(struct Effect *e, AudioUnitPropertyID id, AudioUnitScope scope,
    AudioUnitElement element, void *data, UInt32 *ioSize)
{
    UInt32 size = 0;
    OSStatus status = _FinchEffectPropertyInfo(e, id, scope, element, &size, NULL);
    if (status)
        return status;
    if (!data || !ioSize)
        return kAudio_ParamError;
    switch (id) {
    case kAudioUnitProperty_ParameterList: {
        UInt32 n = param_count(e);
        if (*ioSize < n * sizeof(AudioUnitParameterID))
            return kAudioUnitErr_InvalidPropertyValue;
        AudioUnitParameterID *ids = data;
        if (e->kind == KindNBandEQ) {
            UInt32 k = 0;
            ids[k++] = 0;
            for (int b = 0; b < e->bands; b++)
                for (UInt32 g = 1; g <= 5; g++)
                    ids[k++] = g * 1000 + (UInt32)b;
        } else
            for (UInt32 i = 0; i < n; i++)
                ids[i] = e->table->params[i].id;
        *ioSize = n * sizeof(AudioUnitParameterID);
        return noErr;
    }
    case kAudioUnitProperty_ParameterInfo: {
        const struct EffectParam *p = param_info(e, element);
        AudioUnitParameterInfo info;
        memset(&info, 0, sizeof info);
        /* (the sampler's performance parameters have only the CFString name) */
        if (!(e->kind == KindSampler && p->id >= 1000))
            strlcpy(info.name, p->name, sizeof info.name);
        info.unit = p->unit;
        info.minValue = p->min;
        info.maxValue = p->max;
        info.defaultValue = p->def;
        info.flags = p->flags;
        if (p->flags & kAudioUnitParameterFlag_HasCFNameString) {
            info.cfNameString = CFStringCreateWithCString(kCFAllocatorDefault, p->name, kCFStringEncodingUTF8);
            info.flags |= kAudioUnitParameterFlag_CFNameRelease;
        }
        return give(&info, sizeof info, data, ioSize);
    }
    case kAudioUnitProperty_FactoryPresets: {
        CFArrayRef presets = factory_presets(e->table);
        if (!presets)
            return kAudioUnitErr_InvalidProperty;
        CFRetain(presets); /* (the caller releases it) */
        return give(&presets, sizeof presets, data, ioSize);
    }
    case kAudioUnitProperty_PresentPreset:
    case kAudioUnitProperty_CurrentPreset: {
        AUPreset p = {e->preset, e->presetName};
        if (!p.presetName)
            p.presetName = CFSTR("Untitled");
        if (id == kAudioUnitProperty_PresentPreset)
            CFRetain(p.presetName);
        return give(&p, sizeof p, data, ioSize);
    }
    case kAudioUnitProperty_BypassEffect:
        return give(&e->bypass, sizeof e->bypass, data, ioSize);
    case kAudioUnitProperty_Latency: {
        Float64 v = e->table->latency;
        return give(&v, sizeof v, data, ioSize);
    }
    case kAudioUnitProperty_TailTime: {
        Float64 v = e->table->tail;
        return give(&v, sizeof v, data, ioSize);
    }
    case kAUNBandEQProperty_NumberOfBands: {
        UInt32 v = (UInt32)e->bands;
        return give(&v, sizeof v, data, ioSize);
    }
    case kAUNBandEQProperty_MaxNumberOfBands: {
        UInt32 v = USUAL_MAX_BANDS;
        return give(&v, sizeof v, data, ioSize);
    }
    case kFinchNBandEQProperty_BandLimit: {
        UInt32 v = (UInt32)e->maxBands;
        return give(&v, sizeof v, data, ioSize);
    }
    default:
        return kAudioUnitErr_PropertyNotInUse;
    }
}

static OSStatus load_files(struct Effect *e, CFArrayRef urls);

OSStatus
_FinchEffectSetProperty(struct Effect *e, AudioUnitPropertyID id, AudioUnitScope scope,
    AudioUnitElement element, const void *data, UInt32 size)
{
    UInt32 want = 0;
    Boolean writable = false;
    OSStatus status = _FinchEffectPropertyInfo(e, id, scope, element, &want, &writable);
    if (status)
        return status;
    if (!writable)
        return kAudioUnitErr_PropertyNotWritable;
    if (!data || size < want)
        return kAudioUnitErr_InvalidPropertyValue;
    switch (id) {
    case kAudioUnitProperty_PresentPreset:
    case kAudioUnitProperty_CurrentPreset: {
        const AUPreset *p = data;
        if (p->presetNumber >= 0) {
            if (!load_preset(e, p->presetNumber))
                return kAudioUnitErr_InvalidPropertyValue;
        } else
            set_preset_name(e, p->presetNumber, p->presetName);
        return noErr;
    }
    case kAudioUnitProperty_BypassEffect:
        e->bypass = *(const UInt32 *)data ? 1 : 0;
        return noErr;
    case kAUNBandEQProperty_NumberOfBands: {
        UInt32 n = *(const UInt32 *)data;
        if (!n || n > (UInt32)e->maxBands)
            return kAudioUnitErr_InvalidPropertyValue;
        for (int b = e->bands; b < (int)n; b++)
            default_band(&e->band[b], b);
        e->bands = (int)n;
        return noErr;
    }
    case kFinchNBandEQProperty_BandLimit: {
        UInt32 n = *(const UInt32 *)data;
        if (n < USUAL_MAX_BANDS || n > MAX_BANDS)
            return kAudioUnitErr_InvalidPropertyValue;
        e->maxBands = (int)n;
        return noErr;
    }
    case kAUSamplerProperty_LoadAudioFiles:
        return load_files(e, *(CFArrayRef const *)data);
    case kAUSamplerProperty_LoadInstrument: {
        const AUSamplerInstrumentData *d = data;
        if (!d->fileURL)
            return kAudio_ParamError;
        if (d->instrumentType != kInstrumentType_Audiofile)
            return kAudioUnitErr_InvalidFile; /* (sound banks and .aupreset instruments: not yet) */
        CFArrayRef one = CFArrayCreate(kCFAllocatorDefault, (const void **)&d->fileURL, 1, &kCFTypeArrayCallBacks);
        status = load_files(e, one);
        CFRelease(one);
        return status;
    }
    default:
        return kAudioUnitErr_PropertyNotWritable;
    }
}

/* --- buffers --- */

static bool
lines_new(struct Lines *l, UInt32 channels, UInt32 length)
{
    l->length = length ? length : 1;
    l->position = 0;
    for (UInt32 c = 0; c < channels; c++)
        if (!(l->data[c] = calloc(l->length, sizeof(float))))
            return false;
    return true;
}

static void
lines_free(struct Lines *l)
{
    for (int c = 0; c < MAX_CHANNELS; c++) {
        free(l->data[c]);
        l->data[c] = NULL;
    }
}

static void
lines_clear(struct Lines *l, UInt32 channels)
{
    for (UInt32 c = 0; c < channels; c++)
        if (l->data[c])
            memset(l->data[c], 0, l->length * sizeof(float));
    l->position = 0;
}

static void
free_buffers(struct Effect *e)
{
    for (int c = 0; c < MAX_CHANNELS; c++) {
        free(e->scratch[c]);
        free(e->fifo.data[c]);
        free(e->accumulator[c]);
        e->scratch[c] = e->fifo.data[c] = e->accumulator[c] = NULL;
    }
    free(e->weight);
    free(e->window);
    e->weight = e->window = NULL;
    lines_free(&e->lines);
    lines_free(&e->ahead);
    lines_free(&e->echo);
    if (e->reverb) {
        for (int s = 0; s < 2; s++) {
            for (int i = 0; i < COMBS; i++)
                free(e->reverb->comb[s][i]);
            for (int i = 0; i < ALLPASSES; i++)
                free(e->reverb->allpass[s][i]);
        }
        lines_free(&e->reverb->pre);
        free(e->reverb);
        e->reverb = NULL;
    }
    e->ready = false;
}

static bool
reverb_new(struct Effect *e)
{
    struct Reverb *r = e->reverb = calloc(1, sizeof *r);
    if (!r)
        return false;
    /* (long enough for AUReverb2's longest delay, and AUMatrixReverb's large room and its delay) */
    r->combCapacity = (UInt32)(e->rate * 1.3) + 64;
    for (int s = 0; s < 2; s++) {
        for (int i = 0; i < COMBS; i++)
            if (!(r->comb[s][i] = calloc(r->combCapacity, sizeof(float))))
                return false;
        for (int i = 0; i < ALLPASSES; i++)
            if (!(r->allpass[s][i] = calloc((size_t)(e->rate * 0.02) + 8, sizeof(float))))
                return false;
    }
    return lines_new(&r->pre, 2, (UInt32)(e->rate * 0.2) + 8);
}

static void
reverb_clear(struct Effect *e)
{
    struct Reverb *r = e->reverb;
    for (int s = 0; s < 2; s++) {
        for (int i = 0; i < COMBS; i++) {
            memset(r->comb[s][i], 0, r->combCapacity * sizeof(float));
            r->combPosition[s][i] = 0;
            r->combStore[s][i] = 0;
        }
        for (int i = 0; i < ALLPASSES; i++) {
            memset(r->allpass[s][i], 0, ((size_t)(e->rate * 0.02) + 8) * sizeof(float));
            r->allpassPosition[s][i] = 0;
        }
    }
    lines_clear(&r->pre, 2);
    memset(r->tone.z1, 0, sizeof r->tone.z1);
    memset(r->tone.z2, 0, sizeof r->tone.z2);
}

static void time_reset(struct Effect *e);

OSStatus
_FinchEffectInitialize(struct Effect *e, double rate, UInt32 channels, UInt32 maxFrames)
{
    free_buffers(e);
    if (channels > MAX_CHANNELS || !channels || rate <= 0)
        return kAudioUnitErr_FormatNotSupported;
    e->rate = rate;
    e->channels = channels;
    e->maxFrames = maxFrames;
    bool ok = true;
    for (UInt32 c = 0; c < channels && ok; c++)
        ok = (e->scratch[c] = calloc(maxFrames, sizeof(float))) != NULL;
    switch (e->kind) {
    case KindDelay:
        ok = ok && lines_new(&e->lines, channels, (UInt32)(rate * 2.0) + 4);
        break;
    case KindSampleDelay:
        ok = ok && lines_new(&e->lines, channels, 4410 + 1);
        break;
    case KindDistortion:
        ok = ok && lines_new(&e->echo, channels, (UInt32)(rate * 0.5) + 4);
        break;
    case KindLimiter:
        ok = ok && lines_new(&e->ahead, channels, (UInt32)(rate * 0.03) + 4);
        break;
    case KindMatrixReverb:
    case KindReverb2:
        ok = ok && reverb_new(e);
        break;
    case KindPitch:
    case KindTimePitch:
    case KindVarispeed: {
        e->grain = (UInt32)(GRAIN_BASE * rate / 44100.0);
        if (e->grain < 256)
            e->grain = 256;
        /* (enough for a grain read at four times the pitch, and a pull) */
        e->fifo.capacity = e->grain * 4 + maxFrames * 2 + 16;
        for (UInt32 c = 0; c < channels && ok; c++)
            ok = (e->fifo.data[c] = calloc(e->fifo.capacity, sizeof(float))) != NULL;
        if (e->kind != KindVarispeed) {
            e->accumulatorSize = e->grain * 2 + maxFrames;
            for (UInt32 c = 0; c < channels && ok; c++)
                ok = (e->accumulator[c] = calloc(e->accumulatorSize, sizeof(float))) != NULL;
            ok = ok && (e->weight = calloc(e->accumulatorSize, sizeof(float))) && (e->window = calloc(e->grain, sizeof(float)));
            if (ok)
                for (UInt32 k = 0; k < e->grain; k++)
                    e->window[k] = (float)(0.5 - 0.5 * cos(2.0 * M_PI * (k + 0.5) / e->grain));
        }
        break;
    }
    default:
        break;
    }
    if (!ok) {
        free_buffers(e);
        return kAudioUnitErr_FailedInitialization;
    }
    e->ready = true;
    _FinchEffectReset(e);
    return noErr;
}

void
_FinchEffectUninitialize(struct Effect *e)
{
    free_buffers(e);
}

void
_FinchEffectReset(struct Effect *e)
{
    for (int b = 0; b < MAX_BANDS; b++) {
        memset(e->filter[b].z1, 0, sizeof e->filter[b].z1);
        memset(e->filter[b].z2, 0, sizeof e->filter[b].z2);
    }
    memset(e->lowpass, 0, sizeof e->lowpass);
    memset(e->hold, 0, sizeof e->hold);
    e->envelope = 0;
    e->gain = 1;
    e->ring1 = e->ring2 = e->holdCount = 0;
    if (!e->ready)
        return;
    lines_clear(&e->lines, e->channels);
    lines_clear(&e->ahead, e->channels);
    lines_clear(&e->echo, e->channels);
    if (e->reverb)
        reverb_clear(e);
    if (e->fifo.data[0])
        time_reset(e);
    for (int v = 0; v < MAX_VOICES; v++)
        e->voice[v].active = false;
}

/* --- filters --- */

enum Shape {
    ShapePeak,
    ShapeLowpass,
    ShapeHighpass,
    ShapeBandpass,
    ShapeNotch,
    ShapeLowShelf,
    ShapeHighShelf
};

/* An RBJ-cookbook biquad: q is the filter's Q (for shelves, its slope's). */
static void
design(struct Biquad *f, enum Shape shape, double rate, double frequency, double q, double gainDB)
{
    double nyquist = rate * 0.5;
    if (frequency > nyquist * 0.995)
        frequency = nyquist * 0.995;
    if (frequency < 1)
        frequency = 1;
    if (q < 0.01)
        q = 0.01;
    double w = 2 * M_PI * frequency / rate, cw = cos(w), sw = sin(w), alpha = sw / (2 * q);
    double A = pow(10.0, gainDB / 40.0), b0, b1, b2, a0, a1, a2;
    switch (shape) {
    case ShapeLowpass:
        b0 = (1 - cw) / 2, b1 = 1 - cw, b2 = (1 - cw) / 2, a0 = 1 + alpha, a1 = -2 * cw, a2 = 1 - alpha;
        break;
    case ShapeHighpass:
        b0 = (1 + cw) / 2, b1 = -(1 + cw), b2 = (1 + cw) / 2, a0 = 1 + alpha, a1 = -2 * cw, a2 = 1 - alpha;
        break;
    case ShapeBandpass:
        b0 = alpha, b1 = 0, b2 = -alpha, a0 = 1 + alpha, a1 = -2 * cw, a2 = 1 - alpha;
        break;
    case ShapeNotch:
        b0 = 1, b1 = -2 * cw, b2 = 1, a0 = 1 + alpha, a1 = -2 * cw, a2 = 1 - alpha;
        break;
    case ShapeLowShelf: {
        double s = 2 * sqrt(A) * alpha;
        b0 = A * ((A + 1) - (A - 1) * cw + s);
        b1 = 2 * A * ((A - 1) - (A + 1) * cw);
        b2 = A * ((A + 1) - (A - 1) * cw - s);
        a0 = (A + 1) + (A - 1) * cw + s;
        a1 = -2 * ((A - 1) + (A + 1) * cw);
        a2 = (A + 1) + (A - 1) * cw - s;
        break;
    }
    case ShapeHighShelf: {
        double s = 2 * sqrt(A) * alpha;
        b0 = A * ((A + 1) + (A - 1) * cw + s);
        b1 = -2 * A * ((A - 1) + (A + 1) * cw);
        b2 = A * ((A + 1) + (A - 1) * cw - s);
        a0 = (A + 1) - (A - 1) * cw + s;
        a1 = 2 * ((A - 1) - (A + 1) * cw);
        a2 = (A + 1) - (A - 1) * cw - s;
        break;
    }
    default:
        b0 = 1 + alpha * A, b1 = -2 * cw, b2 = 1 - alpha * A, a0 = 1 + alpha / A, a1 = -2 * cw, a2 = 1 - alpha / A;
        break;
    }
    f->b0 = b0 / a0, f->b1 = b1 / a0, f->b2 = b2 / a0, f->a1 = a1 / a0, f->a2 = a2 / a0;
}

static void
run(struct Biquad *f, UInt32 channel, float *x, UInt32 frames)
{
    double z1 = f->z1[channel], z2 = f->z2[channel];
    for (UInt32 i = 0; i < frames; i++) {
        double in = x[i], out = f->b0 * in + z1;
        z1 = f->b1 * in - f->a1 * out + z2;
        z2 = f->b2 * in - f->a2 * out;
        x[i] = (float)out;
    }
    /* (flushing denormals) */
    f->z1[channel] = fabs(z1) < 1e-25 ? 0 : z1;
    f->z2[channel] = fabs(z2) < 1e-25 ? 0 : z2;
}

/* The Q of a band so many octaves wide. */
static double
octaves_q(double octaves)
{
    if (octaves < 0.01)
        octaves = 0.01;
    return 1.0 / (2.0 * sinh(M_LN2 / 2.0 * octaves));
}

static void
design_band(struct Biquad *f, const struct Band *b, double rate)
{
    double q = octaves_q(b->bandwidth);
    switch ((int)b->type) {
    case kAUNBandEQFilterType_2ndOrderButterworthLowPass:
        design(f, ShapeLowpass, rate, b->frequency, M_SQRT1_2, 0);
        break;
    case kAUNBandEQFilterType_2ndOrderButterworthHighPass:
        design(f, ShapeHighpass, rate, b->frequency, M_SQRT1_2, 0);
        break;
    case kAUNBandEQFilterType_ResonantLowPass:
        design(f, ShapeLowpass, rate, b->frequency, q, 0);
        break;
    case kAUNBandEQFilterType_ResonantHighPass:
        design(f, ShapeHighpass, rate, b->frequency, q, 0);
        break;
    case kAUNBandEQFilterType_BandPass:
        design(f, ShapeBandpass, rate, b->frequency, q, 0);
        break;
    case kAUNBandEQFilterType_BandStop:
        design(f, ShapeNotch, rate, b->frequency, q, 0);
        break;
    case kAUNBandEQFilterType_LowShelf:
        design(f, ShapeLowShelf, rate, b->frequency, M_SQRT1_2, b->gain);
        break;
    case kAUNBandEQFilterType_HighShelf:
        design(f, ShapeHighShelf, rate, b->frequency, M_SQRT1_2, b->gain);
        break;
    case kAUNBandEQFilterType_ResonantLowShelf:
        design(f, ShapeLowShelf, rate, b->frequency, q, b->gain);
        break;
    case kAUNBandEQFilterType_ResonantHighShelf:
        design(f, ShapeHighShelf, rate, b->frequency, q, b->gain);
        break;
    default:
        design(f, ShapePeak, rate, b->frequency, q, b->gain);
        break;
    }
}

static void
process_filter(struct Effect *e, float *const *x, UInt32 frames)
{
    double rate = e->rate;
    struct Biquad *f = &e->filter[0];
    switch (e->kind) {
    case KindLowpass:
    case KindHighpass: {
        /* (the gain at the cutoff is the resonance) */
        double q = pow(10.0, P(e, 1) / 20.0);
        design(f, e->kind == KindLowpass ? ShapeLowpass : ShapeHighpass, rate, P(e, 0), q, 0);
        break;
    }
    case KindBandpass: {
        /* (a highpass and a lowpass at the band's edges, as Apple's is) */
        double edge = pow(2.0, fmax(P(e, 1), 1) / 2400.0);
        design(f, ShapeHighpass, rate, P(e, 0) / edge, 1, 0);
        design(&e->filter[1], ShapeLowpass, rate, P(e, 0) * edge, 1, 0);
        for (UInt32 c = 0; c < e->channels; c++)
            run(&e->filter[1], c, x[c], frames);
        break;
    }
    case KindLowShelf:
    case KindHighShelf:
        design(f, e->kind == KindLowShelf ? ShapeLowShelf : ShapeHighShelf, rate, P(e, 0), M_SQRT1_2, P(e, 1));
        break;
    default:
        design(f, ShapePeak, rate, P(e, 0), P(e, 1), P(e, 2));
        break;
    }
    for (UInt32 c = 0; c < e->channels; c++)
        run(f, c, x[c], frames);
}

static void
process_nband(struct Effect *e, float *const *x, UInt32 frames)
{
    for (int b = 0; b < e->bands; b++) {
        if (e->band[b].bypass >= 0.5f)
            continue;
        design_band(&e->filter[b], &e->band[b], e->rate);
        for (UInt32 c = 0; c < e->channels; c++)
            run(&e->filter[b], c, x[c], frames);
    }
    float g = powf(10.0f, e->globalGain / 20.0f);
    if (g != 1)
        for (UInt32 c = 0; c < e->channels; c++)
            for (UInt32 i = 0; i < frames; i++)
                x[c][i] *= g;
}

/* --- delays --- */

static void
process_delay(struct Effect *e, float *const *x, UInt32 frames)
{
    struct Lines *l = &e->lines;
    double seconds = P(e, kDelayParam_DelayTime);
    UInt32 d = (UInt32)lround(fmin(fmax(seconds, 0.0001), 2.0) * e->rate);
    if (d >= l->length)
        d = l->length - 1;
    if (!d)
        d = 1;
    /* (an equal-power mix, as Apple's is) */
    float mix = fminf(fmaxf(P(e, kDelayParam_WetDryMix), 0), 100) / 100.0f, dry = sqrtf(1 - mix), wetGain = sqrtf(mix);
    float feedback = fminf(fmaxf(P(e, kDelayParam_Feedback), -99.9f), 99.9f) / 100.0f;
    double cutoff = fmin(fmax(P(e, kDelayParam_LopassCutoff), 10.0), e->rate * 0.49);
    float k = (float)(1.0 - exp(-2.0 * M_PI * cutoff / e->rate));
    UInt32 position = l->position;
    for (UInt32 c = 0; c < e->channels; c++) {
        float *line = l->data[c], state = e->lowpass[c];
        UInt32 p = l->position;
        for (UInt32 i = 0; i < frames; i++) {
            UInt32 r = (p + l->length - d) % l->length;
            float wet = line[r];
            state += k * (wet - state);
            line[p] = x[c][i] + feedback * state;
            x[c][i] = x[c][i] * dry + wet * wetGain;
            p = p + 1 == l->length ? 0 : p + 1;
        }
        e->lowpass[c] = fabsf(state) < 1e-25f ? 0 : state;
        position = p;
    }
    l->position = position;
}

static void
process_sample_delay(struct Effect *e, float *const *x, UInt32 frames)
{
    struct Lines *l = &e->lines;
    float want = P(e, kSampleDelayParam_DelayFrames);
    UInt32 d = want <= 0 ? 0 : want >= 4410 ? 4410 : (UInt32)want;
    if (!d)
        return;
    UInt32 position = l->position;
    for (UInt32 c = 0; c < e->channels; c++) {
        UInt32 p = l->position;
        for (UInt32 i = 0; i < frames; i++) {
            UInt32 r = (p + l->length - d) % l->length;
            float out = l->data[c][r];
            l->data[c][p] = x[c][i];
            x[c][i] = out;
            p = p + 1 == l->length ? 0 : p + 1;
        }
        position = p;
    }
    l->position = position;
}

/* --- distortion --- */

static float
blend(float dry, float wet, float percent)
{
    float m = fminf(fmaxf(percent, 0), 100) / 100.0f;
    return dry + (wet - dry) * m;
}

static void
process_distortion(struct Effect *e, float *const *x, UInt32 frames)
{
    struct Lines *l = &e->echo;
    UInt32 d = (UInt32)fmax(1.0, P(e, kDistortionParam_Delay) / 1000.0 * e->rate);
    if (d >= l->length)
        d = l->length - 1;
    float decay = fmaxf(P(e, kDistortionParam_Decay), 0.1f), feedback = 1 - 1 / decay;
    float delayMix = P(e, kDistortionParam_DelayMix);
    /* (decimation holds samples longer; rounding takes bits away) */
    double hold = 1.0 + fminf(fmaxf(P(e, kDistortionParam_Decimation), 0), 100) / 100.0f * 31.0;
    float rounding = fminf(fmaxf(P(e, kDistortionParam_Rounding), 0), 100) / 100.0f;
    float steps = rounding > 0 ? powf(2.0f, 16.0f - 14.0f * rounding) : 0;
    float decimationMix = P(e, kDistortionParam_DecimationMix);
    float linear = P(e, kDistortionParam_LinearTerm), squared = P(e, kDistortionParam_SquaredTerm);
    float cubic = P(e, kDistortionParam_CubicTerm), polyMix = P(e, kDistortionParam_PolynomialMix);
    double f1 = P(e, kDistortionParam_RingModFreq1), f2 = P(e, kDistortionParam_RingModFreq2);
    float balance = fminf(fmaxf(P(e, kDistortionParam_RingModBalance), 0), 100) / 100.0f;
    float ringMix = P(e, kDistortionParam_RingModMix);
    float clip = powf(10.0f, P(e, kDistortionParam_SoftClipGain) / 20.0f);
    float finalMix = P(e, kDistortionParam_FinalMix);
    UInt32 start = l->position;
    double ring1 = e->ring1, ring2 = e->ring2, count = e->holdCount;
    for (UInt32 c = 0; c < e->channels; c++) {
        /* (each channel runs over the same span, from the same state) */
        UInt32 p = start;
        ring1 = e->ring1, ring2 = e->ring2, count = e->holdCount;
        float held = e->hold[c];
        for (UInt32 i = 0; i < frames; i++) {
            float dry = x[c][i], s = dry;
            UInt32 r = (p + l->length - d) % l->length;
            float echo = l->data[c][r];
            l->data[c][p] = s + feedback * echo;
            p = p + 1 == l->length ? 0 : p + 1;
            s = blend(s, s + echo, delayMix);

            if ((count += 1.0) >= hold) {
                count -= hold;
                held = steps > 0 ? roundf(s * steps) / steps : s;
            }
            s = blend(s, held, decimationMix);

            s = blend(s, linear * s + squared * s * s + cubic * s * s * s, polyMix);

            float osc = balance * (float)sin(ring1) + (1 - balance) * (float)sin(ring2);
            ring1 += 2 * M_PI * f1 / e->rate;
            ring2 += 2 * M_PI * f2 / e->rate;
            if (ring1 > 2 * M_PI)
                ring1 -= 2 * M_PI;
            if (ring2 > 2 * M_PI)
                ring2 -= 2 * M_PI;
            s = blend(s, s * osc, ringMix);

            s = tanhf(s * clip);
            x[c][i] = blend(dry, s, finalMix);
        }
        e->hold[c] = held;
        if (c + 1 == e->channels)
            l->position = p;
    }
    e->ring1 = ring1, e->ring2 = ring2, e->holdCount = count;
}

/* --- reverbs --- */

static const double comb_spread[COMBS] = {1.0, 1.0781, 1.1532, 1.2203, 1.2969, 1.3594, 1.4297, 1.4922};
static const double allpass_seconds[ALLPASSES] = {0.0051, 0.0126, 0.0100, 0.0077};

static void
process_reverb(struct Effect *e, float *const *x, UInt32 frames)
{
    struct Reverb *r = e->reverb;
    double rate = e->rate;
    float feedback[COMBS], damping, wetMix, dryMix, smallWeight = 1, largeWeight = 1, wetGain = 1;
    UInt32 predelay;
    if (e->kind == KindReverb2) {
        double low = fmax(P(e, kReverb2Param_MinDelayTime), 0.0001), high = fmax(P(e, kReverb2Param_MaxDelayTime), low);
        double decay = fmax(P(e, kReverb2Param_DecayTimeAt0Hz), 0.001), hf = fmax(P(e, kReverb2Param_DecayTimeAtNyquist), 0.001);
        unsigned seed = (unsigned)P(e, kReverb2Param_RandomizeReflections);
        for (int i = 0; i < COMBS; i++) {
            double t = low * pow(high / low, i / (double)(COMBS - 1));
            double jitter = 1.0 + 0.03 * ((seed * 2654435761u >> (i * 3)) % 8) / 8.0;
            UInt32 n = (UInt32)fmin(t * jitter * rate + 1, r->combCapacity - 32);
            r->combLength[0][i] = n;
            r->combLength[1][i] = n + 23;
            feedback[i] = (float)pow(10.0, -3.0 * n / (rate * decay));
        }
        damping = (float)fmin(fmax(1.0 - hf / decay, 0.0), 0.95);
        wetMix = fminf(fmaxf(P(e, kReverb2Param_DryWetMix), 0), 100) / 100.0f;
        dryMix = 1 - wetMix;
        wetGain = powf(10.0f, P(e, kReverb2Param_Gain) / 20.0f);
        predelay = 0;
    } else {
        double small = fmax(P(e, kReverbParam_SmallSize), 0.0001), large = fmax(P(e, kReverbParam_LargeSize), 0.005);
        double largeDelay = fmax(P(e, kReverbParam_LargeDelay), 0);
        for (int i = 0; i < COMBS; i++) {
            bool big = i >= COMBS / 2;
            double t = (big ? large : small) * comb_spread[i] * (big ? 1.0 : 1.0 + 0.5 * P(e, kReverbParam_SmallDelayRange));
            if (big)
                t = t * (1.0 + 0.5 * P(e, kReverbParam_LargeDelayRange)) + largeDelay;
            UInt32 n = (UInt32)fmin(t * rate + 1, r->combCapacity - 32);
            r->combLength[0][i] = n;
            r->combLength[1][i] = n + 23;
            float density = P(e, big ? kReverbParam_LargeDensity : kReverbParam_SmallDensity);
            feedback[i] = 0.70f + 0.28f * fminf(fmaxf(density, 0), 1);
        }
        damping = 0.6f * fminf(fmaxf((P(e, kReverbParam_SmallBrightness) + P(e, kReverbParam_LargeBrightness)) / 2, 0), 1);
        wetMix = fminf(fmaxf(P(e, kReverbParam_DryWetMix), 0), 100) / 100.0f;
        dryMix = 1 - wetMix;
        float largeShare = fminf(fmaxf(P(e, kReverbParam_SmallLargeMix), 0), 100) / 100.0f;
        smallWeight = 2 * (1 - largeShare);
        largeWeight = 2 * largeShare;
        predelay = (UInt32)(fmax(P(e, kReverbParam_PreDelay), 0) * rate);
        design(&r->tone, ShapePeak, rate, P(e, kReverbParam_FilterFrequency), octaves_q(P(e, kReverbParam_FilterBandwidth)),
            P(e, kReverbParam_FilterGain));
    }
    if (predelay >= r->pre.length)
        predelay = r->pre.length - 1;
    for (int s = 0; s < 2; s++)
        for (int i = 0; i < ALLPASSES; i++)
            r->allpassLength[s][i] = (UInt32)(allpass_seconds[i] * rate) + (UInt32)s * 7 + 1;

    float wet[2][4096];
    UInt32 done = 0;
    while (done < frames) {
        UInt32 n = frames - done < 4096 ? frames - done : 4096;
        for (UInt32 i = 0; i < n; i++) {
            float in = 0;
            for (UInt32 c = 0; c < e->channels; c++)
                in += x[c][done + i];
            in = in / (float)e->channels * 0.015f;
            /* pre-delay */
            UInt32 p = r->pre.position, q = (p + r->pre.length - predelay) % r->pre.length;
            r->pre.data[0][p] = in;
            in = r->pre.data[0][q];
            r->pre.position = p + 1 == r->pre.length ? 0 : p + 1;
            for (int s = 0; s < 2; s++) {
                float out = 0;
                for (int k = 0; k < COMBS; k++) {
                    UInt32 len = r->combLength[s][k], pos = r->combPosition[s][k];
                    if (pos >= len)
                        pos = 0;
                    float y = r->comb[s][k][pos];
                    r->combStore[s][k] = y * (1 - damping) + r->combStore[s][k] * damping;
                    r->comb[s][k][pos] = in + r->combStore[s][k] * feedback[k];
                    r->combPosition[s][k] = pos + 1;
                    out += y * (k < COMBS / 2 ? smallWeight : largeWeight);
                }
                for (int k = 0; k < ALLPASSES; k++) {
                    UInt32 len = r->allpassLength[s][k], pos = r->allpassPosition[s][k];
                    if (pos >= len)
                        pos = 0;
                    float b = r->allpass[s][k][pos];
                    r->allpass[s][k][pos] = out + b * 0.5f;
                    out = b - out;
                    r->allpassPosition[s][k] = pos + 1;
                }
                wet[s][i] = out * wetGain;
            }
        }
        if (e->kind == KindMatrixReverb) {
            run(&r->tone, 0, wet[0], n);
            run(&r->tone, 1, wet[1], n);
        }
        for (UInt32 c = 0; c < e->channels; c++)
            for (UInt32 i = 0; i < n; i++)
                x[c][done + i] = x[c][done + i] * dryMix + wet[c & 1][i] * wetMix;
        done += n;
    }
    for (int s = 0; s < 2; s++)
        for (int k = 0; k < COMBS; k++)
            if (fabsf(r->combStore[s][k]) < 1e-25f)
                r->combStore[s][k] = 0;
}

/* --- dynamics --- */

static float
coefficient(double seconds, double rate)
{
    return seconds <= 0 ? 1 : (float)(1.0 - exp(-1.0 / (seconds * rate)));
}

static void
process_limiter(struct Effect *e, float *const *x, UInt32 frames)
{
    struct Lines *l = &e->ahead;
    double attack = fmin(fmax(P(e, kLimiterParam_AttackTime), 0.0005), 0.03);
    UInt32 d = (UInt32)(attack * e->rate);
    if (d >= l->length)
        d = l->length - 1;
    float pre = powf(10.0f, P(e, kLimiterParam_PreGain) / 20.0f);
    float down = coefficient(attack / 4, e->rate), up = coefficient(fmax(P(e, kLimiterParam_DecayTime), 0.001), e->rate);
    float envelope = e->envelope, gain = e->gain;
    UInt32 p = l->position;
    for (UInt32 i = 0; i < frames; i++) {
        float peak = 0;
        for (UInt32 c = 0; c < e->channels; c++)
            peak = fmaxf(peak, fabsf(x[c][i] * pre));
        envelope = peak > envelope ? peak : envelope + (peak - envelope) * up;
        float target = envelope > 1 ? 1 / envelope : 1;
        gain += (target - gain) * (target < gain ? down : up);
        UInt32 r = (p + l->length - d) % l->length;
        for (UInt32 c = 0; c < e->channels; c++) {
            float delayed = l->data[c][r];
            l->data[c][p] = x[c][i] * pre;
            x[c][i] = delayed * gain;
        }
        p = p + 1 == l->length ? 0 : p + 1;
    }
    l->position = p;
    e->envelope = envelope, e->gain = gain;
}

static void
process_dynamics(struct Effect *e, float *const *x, UInt32 frames)
{
    float threshold = P(e, kDynamicsProcessorParam_Threshold);
    float headroom = fmaxf(P(e, kDynamicsProcessorParam_HeadRoom), 0.1f);
    float expansionRatio = fmaxf(P(e, kDynamicsProcessorParam_ExpansionRatio), 1);
    float expansionThreshold = P(e, kDynamicsProcessorParam_ExpansionThreshold);
    float attack = coefficient(fmax(P(e, kDynamicsProcessorParam_AttackTime), 0.0001), e->rate);
    float release = coefficient(fmax(P(e, kDynamicsProcessorParam_ReleaseTime), 0.001), e->rate);
    float master = P(e, kDynamicsProcessorParam_OverallGain);
    float envelope = e->envelope;
    for (UInt32 i = 0; i < frames; i++) {
        float peak = 0;
        for (UInt32 c = 0; c < e->channels; c++)
            peak = fmaxf(peak, fabsf(x[c][i]));
        envelope += (peak - envelope) * (peak > envelope ? attack : release);
        float level = 20.0f * log10f(fmaxf(envelope, 1e-9f)), gain = 0;
        if (level > threshold) {
            float over = level - threshold;
            gain = headroom * (1 - expf(-over / headroom)) - over;
        } else if (level < expansionThreshold)
            gain = (level - expansionThreshold) * (expansionRatio - 1);
        float g = powf(10.0f, (gain + master) / 20.0f);
        for (UInt32 c = 0; c < e->channels; c++)
            x[c][i] *= g;
    }
    e->envelope = envelope < 1e-20f ? 0 : envelope;
}

/* --- time units --- */

static void
time_reset(struct Effect *e)
{
    e->fifo.count = 0;
    e->fifo.base = 0;
    e->position = 0;
    e->previous = 0;
    e->outPosition = 0;
    e->nextGrain = 0;
    if (e->accumulator[0]) {
        for (UInt32 c = 0; c < e->channels; c++)
            memset(e->accumulator[c], 0, e->accumulatorSize * sizeof(float));
        memset(e->weight, 0, e->accumulatorSize * sizeof(float));
    }
}

/* Drops the input before frame. */
static void
fifo_drop(struct Effect *e, double frame)
{
    struct Fifo *f = &e->fifo;
    double drop = floor(frame) - f->base;
    if (drop <= 0)
        return;
    UInt32 n = drop >= f->count ? f->count : (UInt32)drop;
    for (UInt32 c = 0; c < e->channels; c++)
        memmove(f->data[c], f->data[c] + n, (f->count - n) * sizeof(float));
    f->count -= n;
    f->base += n;
}

/* Pulls input until the frame before end is in, dropping what is before keep. */
static OSStatus
fifo_fill(struct Effect *e, double keep, double end, EffectPull pull, void *context)
{
    struct Fifo *f = &e->fifo;
    fifo_drop(e, keep);
    while (f->base + f->count < end) {
        if (f->count == f->capacity) {
            /* (no room: what is needed is further on than the fifo holds) */
            f->base += f->count;
            f->count = 0;
        }
        UInt32 room = f->capacity - f->count, n = e->maxFrames < room ? e->maxFrames : room;
        double short_by = ceil(end - (f->base + f->count));
        if (short_by < n)
            n = (UInt32)short_by;
        float *at[MAX_CHANNELS];
        for (UInt32 c = 0; c < e->channels; c++)
            at[c] = f->data[c] + f->count;
        OSStatus status = pull(context, n, at);
        if (status)
            return status;
        f->count += n;
        fifo_drop(e, keep);
    }
    return noErr;
}

static float
fifo_at(const struct Effect *e, UInt32 channel, double frame)
{
    const struct Fifo *f = &e->fifo;
    double at = frame - f->base;
    long i = (long)floor(at);
    float t = (float)(at - i);
    float s[4];
    for (int k = 0; k < 4; k++) {
        long j = i - 1 + k;
        s[k] = j >= 0 && j < (long)f->count ? f->data[channel][j] : 0;
    }
    /* (cubic Hermite) */
    float c0 = s[1], c1 = 0.5f * (s[2] - s[0]), c2 = s[0] - 2.5f * s[1] + 2 * s[2] - 0.5f * s[3];
    float c3 = 0.5f * (s[3] - s[0]) + 1.5f * (s[1] - s[2]);
    return ((c3 * t + c2) * t + c1) * t + c0;
}

static OSStatus
process_varispeed(struct Effect *e, EffectPull pull, void *context, float *const *out, UInt32 frames)
{
    double rate = fmin(fmax(P(e, kVarispeedParam_PlaybackRate), 0.25), 4.0);
    OSStatus status = fifo_fill(e, e->position - 2, e->position + rate * frames + 4, pull, context);
    if (status)
        return status;
    for (UInt32 i = 0; i < frames; i++) {
        for (UInt32 c = 0; c < e->channels; c++)
            out[c][i] = fifo_at(e, c, e->position);
        e->position += rate;
    }
    return noErr;
}

/* How well the grain at candidate matches the previous grain's continuation (natural). */
static double
similarity(const struct Effect *e, double candidate, double natural, double pitch, UInt32 span)
{
    double dot = 0, energy = 1e-9;
    for (UInt32 k = 0; k < span; k += 4) {
        double a = 0, b = 0;
        for (UInt32 c = 0; c < e->channels && c < 2; c++) {
            a += fifo_at(e, c, natural + k * pitch);
            b += fifo_at(e, c, candidate + k * pitch);
        }
        dot += a * b;
        energy += b * b;
    }
    return dot / sqrt(energy);
}

static OSStatus
process_time_pitch(struct Effect *e, EffectPull pull, void *context, float *const *out, UInt32 frames)
{
    double rate = e->kind == KindPitch ? 1.0 : fmin(fmax(P(e, kNewTimePitchParam_Rate), 1.0 / 32), 32.0);
    double pitch = pow(2.0, fmin(fmax(P(e, kNewTimePitchParam_Pitch), -2400), 2400) / 1200.0);
    UInt32 L = e->grain, A = e->accumulatorSize, hop = L / 2, tolerance = L / 4;
    double last = e->outPosition + frames;
    /* add every grain that starts before the last frame wanted */
    while (e->nextGrain < last) {
        double nominal = e->position, start = nominal;
        double natural = e->previous + hop * pitch;
        bool search = e->nextGrain > 0 && (rate != 1.0 || pitch != 1.0);
        double from = search ? fmin(natural, nominal - tolerance) : nominal;
        double to = (search ? fmax(natural, nominal + tolerance) : nominal) + L * pitch + 4;
        OSStatus status = fifo_fill(e, from - 2, to, pull, context);
        if (status)
            return status;
        if (search) {
            /* (the start near where the input should be that best continues the last grain) */
            double best = -INFINITY;
            for (int d = -(int)tolerance; d <= (int)tolerance; d += 8) {
                double v = similarity(e, nominal + d, natural, pitch, hop);
                if (v > best)
                    best = v, start = nominal + d;
            }
            double coarse = start;
            for (int d = -7; d <= 7; d++) {
                double v = similarity(e, coarse + d, natural, pitch, hop);
                if (v > best)
                    best = v, start = coarse + d;
            }
        }
        UInt32 at = (UInt32)fmod(e->nextGrain, A);
        for (UInt32 k = 0; k < L; k++) {
            UInt32 slot = (at + k) % A;
            float w = e->window[k];
            for (UInt32 c = 0; c < e->channels; c++)
                e->accumulator[c][slot] += w * fifo_at(e, c, start + k * pitch);
            e->weight[slot] += w;
        }
        e->previous = start;
        e->nextGrain += hop;
        e->position += hop * rate;
    }
    UInt32 from = (UInt32)fmod(e->outPosition, A);
    for (UInt32 i = 0; i < frames; i++) {
        UInt32 slot = (from + i) % A;
        float w = e->weight[slot];
        for (UInt32 c = 0; c < e->channels; c++) {
            out[c][i] = w > 1e-3f ? e->accumulator[c][slot] / w : 0;
            e->accumulator[c][slot] = 0;
        }
        e->weight[slot] = 0;
    }
    e->outPosition = last;
    return noErr;
}

/* --- sampler --- */

static OSStatus
load_files(struct Effect *e, CFArrayRef urls)
{
    if (!urls || CFGetTypeID(urls) != CFArrayGetTypeID())
        return kAudio_ParamError;
    struct Zone made[MAX_ZONES];
    int count = 0;
    OSStatus status = noErr;
    for (CFIndex i = 0; i < CFArrayGetCount(urls) && count < MAX_ZONES; i++) {
        CFURLRef url = CFArrayGetValueAtIndex(urls, i);
        ExtAudioFileRef file = NULL;
        if ((status = ExtAudioFileOpenURL(url, &file)))
            break;
        AudioStreamBasicDescription format;
        UInt32 size = sizeof format;
        SInt64 frames = 0;
        ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &format);
        size = sizeof frames;
        ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &size, &frames);
        UInt32 channels = format.mChannelsPerFrame >= 2 ? 2 : 1;
        AudioStreamBasicDescription client = {format.mSampleRate, kAudioFormatLinearPCM,
            kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved, 4, 1, 4, channels, 32, 0};
        struct Zone *z = &made[count];
        memset(z, 0, sizeof *z);
        if (frames <= 0 || frames > 48000 * 600 ||
            (status = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof client, &client))) {
            ExtAudioFileDispose(file);
            status = status ? status : kAudioUnitErr_InvalidFile;
            break;
        }
        z->frames = (UInt32)frames;
        z->channels = channels;
        z->rate = format.mSampleRate;
        z->root = 60 + count;
        for (UInt32 c = 0; c < channels; c++)
            z->data[c] = calloc(z->frames, sizeof(float));
        struct {
            UInt32 n;
            AudioBuffer b[2];
        } list = {channels, {{1, z->frames * 4, z->data[0]}, {1, z->frames * 4, z->data[1]}}};
        UInt32 got = z->frames;
        status = z->data[0] && (channels == 1 || z->data[1]) ? ExtAudioFileRead(file, &got, (AudioBufferList *)&list)
                                                            : kAudioUnitErr_FailedInitialization;
        ExtAudioFileDispose(file);
        z->frames = got;
        count++;
        if (status)
            break;
    }
    if (status) {
        for (int i = 0; i < count; i++)
            free(made[i].data[0]), free(made[i].data[1]);
        return status;
    }
    for (int v = 0; v < MAX_VOICES; v++)
        e->voice[v].active = false;
    for (int z = 0; z < e->zones; z++)
        free(e->zone[z].data[0]), free(e->zone[z].data[1]);
    memcpy(e->zone, made, sizeof(struct Zone) * (size_t)count);
    e->zones = count;
    return noErr;
}

OSStatus
_FinchEffectMIDIEvent(struct Effect *e, UInt32 status, UInt32 data1, UInt32 data2, UInt32 offset)
{
    (void)offset; /* (events take effect from the next slice rendered) */
    if (e->kind != KindSampler)
        return kAudioUnitErr_InvalidProperty;
    UInt32 kind = status & 0xF0;
    data1 &= 0x7F, data2 &= 0x7F;
    if (kind == 0x90 && data2) {
        int slot = -1;
        for (int v = 0; v < MAX_VOICES && slot < 0; v++)
            if (!e->voice[v].active)
                slot = v;
        if (slot < 0) {
            /* (steals the quietest voice) */
            slot = 0;
            for (int v = 1; v < MAX_VOICES; v++)
                if (e->voice[v].envelope < e->voice[slot].envelope)
                    slot = v;
        }
        int zone = 0;
        for (int z = 1; z < e->zones; z++)
            if (abs(e->zone[z].root - (int)data1) < abs(e->zone[zone].root - (int)data1))
                zone = z;
        e->voice[slot] = (struct Voice){true, false, (int)data1, zone, data2 / 127.0f, 0, 0};
    } else if (kind == 0x80 || kind == 0x90) {
        for (int v = 0; v < MAX_VOICES; v++)
            if (e->voice[v].active && e->voice[v].note == (int)data1)
                e->voice[v].released = true;
    } else if (kind == 0xB0) {
        if (data1 == 7)
            e->volume = data2 / 127.0f;
        else if (data1 == 11)
            e->expression = data2 / 127.0f;
        else if (data1 == 10)
            e->pan = (data2 - 64) / 64.0f;
        else if (data1 == 64)
            e->sustain = data2 >= 64;
        else if (data1 == 120 || data1 == 123) {
            for (int v = 0; v < MAX_VOICES; v++) {
                if (data1 == 120)
                    e->voice[v].active = false;
                else
                    e->voice[v].released = true;
            }
        }
    } else if (kind == 0xE0)
        e->bend = (((data2 << 7) | data1) - 8192) / 8192.0f * 2.0f;
    return noErr;
}

static void
process_sampler(struct Effect *e, float *const *out, UInt32 frames)
{
    for (UInt32 c = 0; c < e->channels; c++)
        memset(out[c], 0, frames * sizeof(float));
    float gain = powf(10.0f, P(e, kAUSamplerParam_Gain) / 20.0f) * e->volume * e->expression;
    double tune = P(e, kAUSamplerParam_CoarseTuning) + P(e, kAUSamplerParam_FineTuning) / 100.0 + e->bend;
    float pan = fminf(fmaxf(P(e, kAUSamplerParam_Pan) / 100.0f + e->pan, -1), 1);
    float left = cosf((pan + 1) * (float)M_PI / 4) * (float)M_SQRT2, right = sinf((pan + 1) * (float)M_PI / 4) * (float)M_SQRT2;
    float attack = 1.0f / (float)(0.005 * e->rate), release = coefficient(0.1, e->rate);
    for (int v = 0; v < MAX_VOICES; v++) {
        struct Voice *voice = &e->voice[v];
        if (!voice->active)
            continue;
        double semis = voice->note - 69 + tune;
        const struct Zone *z = e->zones ? &e->zone[voice->zone] : NULL;
        double step = z ? pow(2.0, (voice->note - z->root + tune) / 12.0) * z->rate / e->rate
                        : 2 * M_PI * 440.0 * pow(2.0, semis / 12.0) / e->rate;
        float level = voice->velocity * voice->velocity * gain * (z ? 1.0f : 0.25f);
        for (UInt32 i = 0; i < frames; i++) {
            bool held = !voice->released || e->sustain;
            if (held)
                voice->envelope = fminf(1, voice->envelope + attack);
            else
                voice->envelope -= voice->envelope * release;
            float l, r;
            if (z) {
                UInt32 at = (UInt32)voice->phase;
                if (at + 1 >= z->frames) {
                    voice->active = false;
                    break;
                }
                float t = (float)(voice->phase - at);
                l = z->data[0][at] + (z->data[0][at + 1] - z->data[0][at]) * t;
                r = z->channels > 1 ? z->data[1][at] + (z->data[1][at + 1] - z->data[1][at]) * t : l;
            } else {
                l = r = (float)sin(voice->phase);
                if (voice->phase > 2 * M_PI)
                    voice->phase -= 2 * M_PI;
            }
            voice->phase += step;
            float a = voice->envelope * level;
            if (e->channels == 1)
                out[0][i] += (l + r) * 0.5f * a;
            else {
                out[0][i] += l * a * left;
                out[1][i] += r * a * right;
            }
            if (!held && voice->envelope < 1e-4f) {
                voice->active = false;
                break;
            }
        }
    }
}

/* --- rendering --- */

OSStatus
_FinchEffectRender(struct Effect *e, EffectPull pull, void *context, UInt32 frames, float *const *out)
{
    if (!e->ready)
        return kAudioUnitErr_Uninitialized;
    if (frames > e->maxFrames)
        return kAudioUnitErr_TooManyFramesToProcess;
    if (e->kind == KindSampler) {
        process_sampler(e, out, frames);
        return noErr;
    }
    if (e->bypass)
        return pull(context, frames, out);
    switch (e->kind) {
    case KindVarispeed:
        return process_varispeed(e, pull, context, out, frames);
    case KindPitch:
    case KindTimePitch:
        return process_time_pitch(e, pull, context, out, frames);
    default:
        break;
    }
    OSStatus status = pull(context, frames, out);
    if (status)
        return status;
    switch (e->kind) {
    case KindDelay:
        process_delay(e, out, frames);
        break;
    case KindSampleDelay:
        process_sample_delay(e, out, frames);
        break;
    case KindDistortion:
        process_distortion(e, out, frames);
        break;
    case KindNBandEQ:
        process_nband(e, out, frames);
        break;
    case KindMatrixReverb:
    case KindReverb2:
        process_reverb(e, out, frames);
        break;
    case KindLimiter:
        process_limiter(e, out, frames);
        break;
    case KindDynamics:
        process_dynamics(e, out, frames);
        break;
    default:
        process_filter(e, out, frames);
        break;
    }
    return noErr;
}
