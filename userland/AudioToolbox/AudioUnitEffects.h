/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Finch's effect, format-converter and instrument units (AUDelay, AUNBandEQ,
 * AUNewTimePitch, AUSampler and the rest), behind AudioUnit.c's component calls.
 * Audio inside is deinterleaved 32-bit float, as Apple's effects take it.
 */
#ifndef FINCH_AUDIOUNITEFFECTS_H
#define FINCH_AUDIOUNITEFFECTS_H

#include <AudioToolbox/AudioToolbox.h>

/* Lets AVAudioUnitEQ have more bands than AUNBandEQ allows anyone else (up to 64), as
   Apple's does. Finch's own; AVAudioUnit.m has it too. */
#define kFinchNBandEQProperty_BandLimit 0x666e626c /* 'fnbl' */

struct EffectParam {
    AudioUnitParameterID id;
    const char *name;
    AudioUnitParameterUnit unit;
    float min, max, def, initial;
    UInt32 flags;
};

struct EffectPreset {
    SInt32 number;
    const char *name;
    const float *values; /* (one for each of the table's parameters, in order) */
};

struct EffectTable {
    OSType type, subtype;
    const char *name;
    UInt32 version;
    double latency, tail;
    int paramCount;
    const struct EffectParam *params;
    int presetCount;
    const struct EffectPreset *presets;
    SInt32 initialPreset;
};

/* The units' parameters and presets, as Apple's have them (AudioUnitEffectTables.c). */
extern const struct EffectTable _FinchEffectTables[];
extern const size_t _FinchEffectTableCount;

/* Renders the unit's input into channels (frames of each). */
typedef OSStatus (*EffectPull)(void *context, UInt32 frames, float *const *channels);

struct Effect;

struct Effect *_FinchEffectNew(const struct EffectTable *table);
void _FinchEffectDispose(struct Effect *effect);
Boolean _FinchEffectHasInput(const struct EffectTable *table);
OSStatus _FinchEffectInitialize(struct Effect *effect, double rate, UInt32 channels, UInt32 maxFrames);
void _FinchEffectUninitialize(struct Effect *effect);
void _FinchEffectReset(struct Effect *effect);
OSStatus _FinchEffectGetParameter(struct Effect *effect, AudioUnitParameterID id, AudioUnitScope scope,
    AudioUnitElement element, AudioUnitParameterValue *value);
OSStatus _FinchEffectSetParameter(struct Effect *effect, AudioUnitParameterID id, AudioUnitScope scope,
    AudioUnitElement element, AudioUnitParameterValue value);
/* kAudioUnitErr_InvalidProperty for the properties AudioUnit.c answers itself. */
OSStatus _FinchEffectPropertyInfo(struct Effect *effect, AudioUnitPropertyID id, AudioUnitScope scope,
    AudioUnitElement element, UInt32 *size, Boolean *writable);
OSStatus _FinchEffectGetProperty(struct Effect *effect, AudioUnitPropertyID id, AudioUnitScope scope,
    AudioUnitElement element, void *data, UInt32 *size);
OSStatus _FinchEffectSetProperty(struct Effect *effect, AudioUnitPropertyID id, AudioUnitScope scope,
    AudioUnitElement element, const void *data, UInt32 size);
OSStatus _FinchEffectRender(struct Effect *effect, EffectPull pull, void *context, UInt32 frames,
    float *const *out);
OSStatus _FinchEffectMIDIEvent(struct Effect *effect, UInt32 status, UInt32 data1, UInt32 data2, UInt32 offset);

#endif
