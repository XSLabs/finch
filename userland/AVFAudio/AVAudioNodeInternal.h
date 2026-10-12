/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* What AVAudioEngine.m's nodes share with the nodes in other files (AVAudioUnit.m). */
#import <AVFAudio/AVFAudio.h>
#import <AudioToolbox/AudioToolbox.h>

/* An input bus's connection. */
typedef struct {
    AVAudioNode *source;
    AVAudioNodeBus bus;
    AVAudioFormat *format;
} Link;

/* The mixing parameters a source node carries to its mixer. */
typedef struct {
    float volume, pan, rate, reverbBlend, obstruction, occlusion;
    AVAudio3DPoint position;
    AVAudio3DMixingRenderingAlgorithm algorithm;
    AVAudio3DMixingSourceMode sourceMode;
    AVAudio3DMixingPointSourceInHeadMode inHeadMode;
} Mixing;

@interface AVAudioNode () {
@public
    AVAudioEngine *_engine;
    NSUInteger _inputs, _outputs;
    Link _in[64];
    NSMutableDictionary *_outFormats; /* bus -> format */
    NSMutableDictionary *_taps;       /* bus -> FinchTap */
    AVAudioTime *_lastRender;
    /* (the bus rendered this cycle, kept for the other destinations) */
    AVAudioFramePosition _cachedAt;
    AVAudioPCMBuffer *_cached[8];
    Mixing _mixing;
}
- (OSStatus)_render:(AVAudioPCMBuffer *)out bus:(AVAudioNodeBus)bus at:(AVAudioFramePosition)time;
- (OSStatus)_pull:(AVAudioNodeBus)bus frames:(AVAudioFrameCount)frames at:(AVAudioFramePosition)time into:(AVAudioPCMBuffer **)out;
- (AVAudioFormat *)_defaultOutputFormat;
- (void)_wasConnected;
@end

static inline AVAudioFormat *
standard(double rate, AVAudioChannelCount channels)
{
    return [[[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:channels ? channels : 1] autorelease];
}

static inline void
zero(AVAudioPCMBuffer *b, AVAudioFrameCount frames)
{
    b.frameLength = frames;
    const AudioBufferList *abl = b.audioBufferList;
    for (UInt32 i = 0; i < abl->mNumberBuffers; i++)
        memset(abl->mBuffers[i].mData, 0, abl->mBuffers[i].mDataByteSize);
}

/* The input bus's source rendered (nil when nothing is connected). */
OSStatus finch_pull_input(AVAudioNode *node, AVAudioNodeBus bus, AVAudioFrameCount frames, AVAudioFramePosition time,
    AVAudioPCMBuffer **out);
AVAudioMixingDestination *finch_destination(AVAudioNode *source, AVAudioNode *mixer, AVAudioNodeBus bus);

/* --- mixing parameters, on every node that can feed a mixer --- */

#define MIXING_ACCESSORS                                                                                       \
    -(float)volume { return _mixing.volume; }                                                                  \
    -(void)setVolume : (float)v { _mixing.volume = v < 0 ? 0 : v; }                                            \
    -(float)pan { return _mixing.pan; }                                                                        \
    -(void)setPan : (float)v { _mixing.pan = v < -1 ? -1 : v > 1 ? 1 : v; }                                    \
    -(float)rate { return _mixing.rate; }                                                                      \
    -(void)setRate : (float)v { _mixing.rate = v; }                                                            \
    -(float)reverbBlend { return _mixing.reverbBlend; }                                                        \
    -(void)setReverbBlend : (float)v { _mixing.reverbBlend = v; }                                              \
    -(float)obstruction { return _mixing.obstruction; }                                                        \
    -(void)setObstruction : (float)v { _mixing.obstruction = v; }                                              \
    -(float)occlusion { return _mixing.occlusion; }                                                            \
    -(void)setOcclusion : (float)v { _mixing.occlusion = v; }                                                  \
    -(AVAudio3DPoint)position { return _mixing.position; }                                                     \
    -(void)setPosition : (AVAudio3DPoint)v { _mixing.position = v; }                                           \
    -(AVAudio3DMixingRenderingAlgorithm)renderingAlgorithm { return _mixing.algorithm; }                       \
    -(void)setRenderingAlgorithm : (AVAudio3DMixingRenderingAlgorithm)v { _mixing.algorithm = v; }             \
    -(AVAudio3DMixingSourceMode)sourceMode { return _mixing.sourceMode; }                                      \
    -(void)setSourceMode : (AVAudio3DMixingSourceMode)v { _mixing.sourceMode = v; }                            \
    -(AVAudio3DMixingPointSourceInHeadMode)pointSourceInHeadMode { return _mixing.inHeadMode; }                \
    -(void)setPointSourceInHeadMode : (AVAudio3DMixingPointSourceInHeadMode)v { _mixing.inHeadMode = v; }      \
    -(AVAudioMixingDestination *)destinationForMixer : (AVAudioNode *)mixer bus : (AVAudioNodeBus)bus          \
    {                                                                                                          \
        return finch_destination(self, mixer, bus);                                                            \
    }

@interface AVAudioMixingDestination ()
- (instancetype)_initWithSource:(AVAudioNode *)source point:(AVAudioConnectionPoint *)point;
@end

