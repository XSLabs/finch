/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * AVAudioEngine and its nodes, Finch's.
 *
 * The graph is pulled from the output node: each node renders an output bus by
 * pulling its inputs, a node feeding several destinations rendering once a cycle.
 * Inside the graph audio is deinterleaved 32-bit float. The mixer converts each input
 * to its output's rate and channels, applies the input's volume and pan as Apple's
 * does (equal power, except that a centred mono input goes to both sides at full
 * level; a stereo input's pan is a balance), sums, and applies its output volume.
 *
 * Offline manual rendering renders on the caller's thread. Real-time rendering has no
 * audio device to play through yet, so a started engine renders on a timer at the
 * output's rate and the audio goes nowhere: players, taps and completion handlers run
 * as they would.
 */
#import <AVFAudio/AVFAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#import <Block.h>
#include <dispatch/dispatch.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

NSString *const AVAudioEngineConfigurationChangeNotification = @"AVAudioEngineConfigurationChangeNotification";

#define kSilentChunk 512

@class FinchAudioEngineGraph;

/* --- connection points --- */

@implementation AVAudioConnectionPoint

- (instancetype)initWithNode:(AVAudioNode *)node bus:(AVAudioNodeBus)bus
{
    if ((self = [super init])) {
        _node = node; /* (weak, as Apple's) */
        _bus = bus;
    }
    return self;
}

- (AVAudioNode *)node
{
    return _node;
}

- (AVAudioNodeBus)bus
{
    return _bus;
}

@end

/* --- nodes --- */

/* An input bus's connection. */
typedef struct {
    AVAudioNode *source;
    AVAudioNodeBus bus;
    AVAudioFormat *format;
} Link;

/* A tap: frames gathered until there are bufferSize of them. */
@interface FinchTap : NSObject {
@public
    AVAudioNodeTapBlock block;
    AVAudioFrameCount size;
    AVAudioFormat *format;
    AVAudioPCMBuffer *pending;
    AVAudioFramePosition start;
}
@end

@implementation FinchTap
- (void)dealloc
{
    Block_release(block);
    [format release];
    [pending release];
    [super dealloc];
}
@end

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

static AVAudioFormat *
standard(double rate, AVAudioChannelCount channels)
{
    return [[[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:channels ? channels : 1] autorelease];
}

static void
zero(AVAudioPCMBuffer *b, AVAudioFrameCount frames)
{
    b.frameLength = frames;
    const AudioBufferList *abl = b.audioBufferList;
    for (UInt32 i = 0; i < abl->mNumberBuffers; i++)
        memset(abl->mBuffers[i].mData, 0, abl->mBuffers[i].mDataByteSize);
}

@implementation AVAudioNode

- (instancetype)init
{
    if ((self = [super init])) {
        _outFormats = [NSMutableDictionary new];
        _taps = [NSMutableDictionary new];
        _cachedAt = -1;
        _mixing.volume = 1;
        _mixing.rate = 1;
        _mixing.algorithm = AVAudio3DMixingRenderingAlgorithmEqualPowerPanning;
        _mixing.sourceMode = AVAudio3DMixingSourceModeSpatializeIfMono;
        _mixing.inHeadMode = AVAudio3DMixingPointSourceInHeadModeMono;
    }
    return self;
}

- (void)dealloc
{
    for (NSUInteger i = 0; i < 64; i++)
        [_in[i].format release];
    for (int i = 0; i < 8; i++)
        [_cached[i] release];
    [_outFormats release];
    [_taps release];
    [_lastRender release];
    [super dealloc];
}

- (AVAudioEngine *)engine
{
    return _engine;
}

- (NSUInteger)numberOfInputs
{
    return _inputs;
}

- (NSUInteger)numberOfOutputs
{
    return _outputs;
}

- (AVAudioTime *)lastRenderTime
{
    return _engine && _engine.running ? _lastRender : nil;
}

- (NSTimeInterval)latency
{
    return 0;
}

- (NSTimeInterval)outputPresentationLatency
{
    return 0;
}

- (AUAudioUnit *)AUAudioUnit
{
    return nil;
}

- (void)reset
{
}

- (AVAudioFormat *)_defaultOutputFormat
{
    return standard(44100, 2);
}

- (AVAudioFormat *)inputFormatForBus:(AVAudioNodeBus)bus
{
    if (bus < 64 && _in[bus].format)
        return _in[bus].format;
    return [self _defaultOutputFormat];
}

- (AVAudioFormat *)outputFormatForBus:(AVAudioNodeBus)bus
{
    AVAudioFormat *f = _outFormats[@(bus)];
    return f ? f : [self _defaultOutputFormat];
}

- (NSString *)nameForInputBus:(AVAudioNodeBus)bus
{
    return nil;
}

- (NSString *)nameForOutputBus:(AVAudioNodeBus)bus
{
    return nil;
}

- (void)_wasConnected
{
}

- (void)installTapOnBus:(AVAudioNodeBus)bus bufferSize:(AVAudioFrameCount)bufferSize format:(AVAudioFormat *)format block:(AVAudioNodeTapBlock)tapBlock
{
    if (_taps[@(bus)])
        [NSException raise:NSInternalInconsistencyException format:@"required condition is false: nullptr == Tap()"];
    FinchTap *t = [FinchTap new];
    t->block = Block_copy(tapBlock);
    t->format = [(format ? format : [self outputFormatForBus:bus]) retain];
    /* (a size from 100 to 400 ms of audio, as Apple's takes it) */
    double rate = t->format.sampleRate > 0 ? t->format.sampleRate : 44100;
    AVAudioFrameCount least = (AVAudioFrameCount)(rate * 0.1), most = (AVAudioFrameCount)(rate * 0.4);
    t->size = bufferSize < least ? least : bufferSize > most ? most : bufferSize;
    t->start = -1;
    _taps[@(bus)] = t;
    [t release];
}

- (void)removeTapOnBus:(AVAudioNodeBus)bus
{
    [_taps removeObjectForKey:@(bus)];
}

/* What the node puts out on a bus (subclasses render; a plain node renders silence). */
- (OSStatus)_render:(AVAudioPCMBuffer *)out bus:(AVAudioNodeBus)bus at:(AVAudioFramePosition)time
{
    zero(out, out.frameCapacity);
    return noErr;
}

static dispatch_queue_t
tap_queue(void)
{
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      q = dispatch_queue_create("org.finch.AVAudioNode.taps", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

/* Feeds a tap the frames rendered on its bus. */
static void
feed_tap(FinchTap *t, AVAudioPCMBuffer *b, AVAudioFramePosition time)
{
    AVAudioFrameCount have = b.frameLength, at = 0;
    while (at < have) {
        if (!t->pending) {
            t->pending = [[AVAudioPCMBuffer alloc] initWithPCMFormat:b.format frameCapacity:t->size];
            t->pending.frameLength = 0;
            t->start = time + at;
        }
        AVAudioFrameCount room = t->size - t->pending.frameLength, n = have - at < room ? have - at : room;
        for (AVAudioChannelCount c = 0; c < b.format.channelCount; c++)
            memcpy(t->pending.floatChannelData[c] + t->pending.frameLength, b.floatChannelData[c] + at, n * sizeof(float));
        t->pending.frameLength += n;
        at += n;
        if (t->pending.frameLength == t->size) {
            /* (delivered on another thread, as Apple's are) */
            AVAudioPCMBuffer *full = t->pending;
            AVAudioTime *when = [[AVAudioTime timeWithSampleTime:t->start atRate:b.format.sampleRate] retain];
            AVAudioNodeTapBlock block = Block_copy(t->block);
            t->pending = nil;
            dispatch_async(tap_queue(), ^{
              block(full, when);
              [full release];
              [when release];
              Block_release(block);
            });
        }
    }
}

/* A bus's output this cycle, rendered once whoever asks. */
- (OSStatus)_pull:(AVAudioNodeBus)bus frames:(AVAudioFrameCount)frames at:(AVAudioFramePosition)time into:(AVAudioPCMBuffer **)out
{
    if (bus >= 8)
        return kAudioUnitErr_InvalidElement;
    if (_cachedAt != time) {
        for (int i = 0; i < 8; i++)
            if (_cached[i])
                _cached[i].frameLength = 0;
        _cachedAt = time;
    }
    AVAudioFormat *f = [self outputFormatForBus:bus];
    if (!_cached[bus] || _cached[bus].frameCapacity < frames || ![_cached[bus].format isEqual:f]) {
        [_cached[bus] release];
        _cached[bus] = [[AVAudioPCMBuffer alloc] initWithPCMFormat:f frameCapacity:frames > 4096 ? frames : 4096];
    }
    AVAudioPCMBuffer *b = _cached[bus];
    if (b.frameLength != frames) {
        b.frameLength = frames;
        OSStatus e = [self _render:b bus:bus at:time];
        if (e)
            return e;
        b.frameLength = frames;
        [_lastRender release];
        _lastRender = [[AVAudioTime timeWithSampleTime:time + frames atRate:f.sampleRate] retain];
        FinchTap *t = _taps[@(bus)];
        if (t)
            feed_tap(t, b, time);
    }
    *out = b;
    return noErr;
}

/* The input bus's source rendered (or silence when nothing is connected). */
static OSStatus
pull_input(AVAudioNode *node, AVAudioNodeBus bus, AVAudioFrameCount frames, AVAudioFramePosition time, AVAudioPCMBuffer **out)
{
    if (bus >= 64 || !node->_in[bus].source) {
        *out = nil;
        return noErr;
    }
    return [node->_in[bus].source _pull:node->_in[bus].bus frames:frames at:time into:out];
}

@end

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

static AVAudioMixingDestination *
finch_destination(AVAudioNode *source, AVAudioNode *mixer, AVAudioNodeBus bus)
{
    if (![mixer isKindOfClass:[AVAudioMixerNode class]] || bus >= 64 || mixer->_in[bus].source != source)
        return nil;
    AVAudioConnectionPoint *p = [[[AVAudioConnectionPoint alloc] initWithNode:mixer bus:bus] autorelease];
    return [[[AVAudioMixingDestination alloc] _initWithSource:source point:p] autorelease];
}

/* A destination stands for the source's parameters at one mixer (one set, here, for all of them). */
@implementation AVAudioMixingDestination {
    AVAudioNode *_source;
    AVAudioConnectionPoint *_point;
}

- (instancetype)_initWithSource:(AVAudioNode *)source point:(AVAudioConnectionPoint *)point
{
    if ((self = [super init])) {
        _source = [source retain];
        _point = [point retain];
    }
    return self;
}

- (void)dealloc
{
    [_source release];
    [_point release];
    [super dealloc];
}

- (AVAudioConnectionPoint *)connectionPoint
{
    return _point;
}

- (AVAudioMixingDestination *)destinationForMixer:(AVAudioNode *)mixer bus:(AVAudioNodeBus)bus
{
    return nil;
}

- (float)volume { return [(AVAudioNode<AVAudioMixing> *)_source volume]; }
- (void)setVolume:(float)v { [(AVAudioNode<AVAudioMixing> *)_source setVolume:v]; }
- (float)pan { return [(AVAudioNode<AVAudioMixing> *)_source pan]; }
- (void)setPan:(float)v { [(AVAudioNode<AVAudioMixing> *)_source setPan:v]; }
- (float)rate { return [(AVAudioNode<AVAudioMixing> *)_source rate]; }
- (void)setRate:(float)v { [(AVAudioNode<AVAudioMixing> *)_source setRate:v]; }
- (float)reverbBlend { return [(AVAudioNode<AVAudioMixing> *)_source reverbBlend]; }
- (void)setReverbBlend:(float)v { [(AVAudioNode<AVAudioMixing> *)_source setReverbBlend:v]; }
- (float)obstruction { return [(AVAudioNode<AVAudioMixing> *)_source obstruction]; }
- (void)setObstruction:(float)v { [(AVAudioNode<AVAudioMixing> *)_source setObstruction:v]; }
- (float)occlusion { return [(AVAudioNode<AVAudioMixing> *)_source occlusion]; }
- (void)setOcclusion:(float)v { [(AVAudioNode<AVAudioMixing> *)_source setOcclusion:v]; }
- (AVAudio3DPoint)position { return [(AVAudioNode<AVAudioMixing> *)_source position]; }
- (void)setPosition:(AVAudio3DPoint)v { [(AVAudioNode<AVAudioMixing> *)_source setPosition:v]; }
- (AVAudio3DMixingRenderingAlgorithm)renderingAlgorithm { return [(AVAudioNode<AVAudioMixing> *)_source renderingAlgorithm]; }
- (void)setRenderingAlgorithm:(AVAudio3DMixingRenderingAlgorithm)v { [(AVAudioNode<AVAudioMixing> *)_source setRenderingAlgorithm:v]; }
- (AVAudio3DMixingSourceMode)sourceMode { return [(AVAudioNode<AVAudioMixing> *)_source sourceMode]; }
- (void)setSourceMode:(AVAudio3DMixingSourceMode)v { [(AVAudioNode<AVAudioMixing> *)_source setSourceMode:v]; }
- (AVAudio3DMixingPointSourceInHeadMode)pointSourceInHeadMode { return [(AVAudioNode<AVAudioMixing> *)_source pointSourceInHeadMode]; }
- (void)setPointSourceInHeadMode:(AVAudio3DMixingPointSourceInHeadMode)v { [(AVAudioNode<AVAudioMixing> *)_source setPointSourceInHeadMode:v]; }

@end

/* --- the mixer --- */

/* A rate converter for one mixer input: pulls its source as it needs frames. */
@interface FinchRateStage : NSObject {
@public
    AudioConverterRef converter;
    AVAudioNode *mixer;
    AVAudioNodeBus bus;
    AVAudioFormat *from, *to;
    AVAudioPCMBuffer *held;
    AVAudioFramePosition sourceTime;
}
@end

@implementation FinchRateStage
- (void)dealloc
{
    if (converter)
        AudioConverterDispose(converter);
    [from release];
    [to release];
    [held release];
    [super dealloc];
}
@end

static OSStatus
rate_input(AudioConverterRef c, UInt32 *packets, AudioBufferList *data, AudioStreamPacketDescription **descs, void *info)
{
    FinchRateStage *s = info;
    AVAudioFrameCount want = *packets > 4096 ? 4096 : *packets;
    AVAudioPCMBuffer *got = nil;
    OSStatus e = pull_input(s->mixer, s->bus, want, s->sourceTime, &got);
    if (e)
        return e;
    s->sourceTime += want;
    [s->held release];
    s->held = [got retain];
    for (UInt32 i = 0; i < data->mNumberBuffers; i++) {
        data->mBuffers[i].mData = got ? got.floatChannelData[i] : NULL;
        data->mBuffers[i].mDataByteSize = got ? want * sizeof(float) : 0;
    }
    *packets = got ? want : 0;
    return noErr;
}

@implementation AVAudioMixerNode {
    float _outputVolume;
    NSMutableDictionary *_stages; /* bus -> FinchRateStage */
    AVAudioPCMBuffer *_scratch;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _inputs = 64;
        _outputs = 1;
        _outputVolume = 1;
        _stages = [NSMutableDictionary new];
    }
    return self;
}

- (void)dealloc
{
    [_stages release];
    [_scratch release];
    [super dealloc];
}

MIXING_ACCESSORS

- (float)outputVolume
{
    return _outputVolume;
}

- (void)setOutputVolume:(float)v
{
    _outputVolume = v < 0 ? 0 : v;
}

- (NSUInteger)numberOfInputs
{
    NSUInteger n = 8;
    for (AVAudioNodeBus b = 0; b < 64; b++)
        if (_in[b].source && b + 1 > n)
            n = b + 1;
    return n;
}

- (AVAudioNodeBus)nextAvailableInputBus
{
    for (AVAudioNodeBus b = 0; b < 64; b++)
        if (!_in[b].source)
            return b;
    return 64;
}

- (void)reset
{
    [_stages removeAllObjects];
}

/* One input, in its own format, brought to the output's rate. */
- (OSStatus)_input:(AVAudioNodeBus)bus frames:(AVAudioFrameCount)frames at:(AVAudioFramePosition)time into:(AVAudioPCMBuffer **)out
{
    AVAudioFormat *in = _in[bus].format, *outFormat = [self outputFormatForBus:0];
    if (!in || in.sampleRate == outFormat.sampleRate)
        return pull_input(self, bus, frames, time, out);
    FinchRateStage *s = _stages[@(bus)];
    AVAudioFormat *target = standard(outFormat.sampleRate, in.channelCount);
    if (!s || ![s->from isEqual:in] || ![s->to isEqual:target]) {
        s = [[FinchRateStage new] autorelease];
        s->from = [in retain];
        s->to = [target retain];
        s->mixer = self;
        s->bus = bus;
        s->sourceTime = (AVAudioFramePosition)llround(time * in.sampleRate / outFormat.sampleRate);
        if (AudioConverterNew(in.streamDescription, target.streamDescription, &s->converter))
            return kAudioUnitErr_FormatNotSupported;
        _stages[@(bus)] = s;
    }
    if (!_scratch || _scratch.frameCapacity < frames || ![_scratch.format isEqual:target]) {
        [_scratch release];
        _scratch = [[AVAudioPCMBuffer alloc] initWithPCMFormat:target frameCapacity:frames > 4096 ? frames : 4096];
    }
    UInt32 n = frames;
    OSStatus e = AudioConverterFillComplexBuffer(s->converter, rate_input, s, &n, _scratch.mutableAudioBufferList, NULL);
    if (e)
        return e;
    for (UInt32 c = 0; c < target.channelCount; c++)
        if (n < frames)
            memset(_scratch.floatChannelData[c] + n, 0, (frames - n) * sizeof(float));
    _scratch.frameLength = frames;
    *out = _scratch;
    return noErr;
}

- (OSStatus)_render:(AVAudioPCMBuffer *)out bus:(AVAudioNodeBus)bus at:(AVAudioFramePosition)time
{
    AVAudioFrameCount frames = out.frameLength;
    AVAudioChannelCount outChannels = out.format.channelCount;
    zero(out, frames);
    for (AVAudioNodeBus b = 0; b < 64; b++) {
        if (!_in[b].source)
            continue;
        AVAudioPCMBuffer *in = nil;
        OSStatus e = [self _input:b frames:frames at:time into:&in];
        if (e)
            return e;
        if (!in)
            continue;
        const Mixing *m = &_in[b].source->_mixing;
        AVAudioChannelCount inChannels = in.format.channelCount;
        float gains[2] = {m->volume, m->volume};
        if (inChannels == 1 && outChannels == 2) {
            /* (equal power, but a centred source goes to both sides at full level, as with Apple's) */
            if (m->pan != 0) {
                double theta = (m->pan + 1) * M_PI / 4;
                gains[0] *= (float)cos(theta);
                gains[1] *= (float)sin(theta);
            }
            for (AVAudioFrameCount i = 0; i < frames; i++) {
                float v = in.floatChannelData[0][i];
                out.floatChannelData[0][i] += v * gains[0];
                out.floatChannelData[1][i] += v * gains[1];
            }
            continue;
        }
        if (inChannels >= 2 && outChannels >= 2) {
            /* (a balance) */
            if (m->pan > 0)
                gains[0] *= 1 - m->pan;
            if (m->pan < 0)
                gains[1] *= 1 + m->pan;
        }
        for (AVAudioChannelCount c = 0; c < outChannels; c++) {
            /* (a mono input fills every output channel; otherwise channel to channel) */
            AVAudioChannelCount from = inChannels == 1 ? 0 : c;
            if (from >= inChannels)
                continue;
            float g = c < 2 ? gains[c] : m->volume;
            for (AVAudioFrameCount i = 0; i < frames; i++)
                out.floatChannelData[c][i] += in.floatChannelData[from][i] * g;
        }
    }
    if (_outputVolume != 1)
        for (AVAudioChannelCount c = 0; c < outChannels; c++)
            for (AVAudioFrameCount i = 0; i < frames; i++)
                out.floatChannelData[c][i] *= _outputVolume;
    return noErr;
}

@end

/* --- the player --- */

static dispatch_queue_t
completion_queue(void)
{
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      q = dispatch_queue_create("org.finch.AVAudioPlayerNode.completions", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

/* Something scheduled: a buffer, or a stretch of a file. */
@interface FinchScheduled : NSObject {
@public
    AVAudioPCMBuffer *buffer;
    AVAudioFile *file;
    AVAudioFramePosition fileStart;
    AVAudioFrameCount fileFrames;
    AVAudioFramePosition when; /* (player sample time it starts at, or -1: after what's before it) */
    AVAudioPlayerNodeBufferOptions options;
    AVAudioPlayerNodeCompletionCallbackType callbackType;
    AVAudioNodeCompletionHandler handler;
    AVAudioPlayerNodeCompletionHandler typedHandler;
    AVAudioFrameCount done;
}
@end

@implementation FinchScheduled
- (AVAudioFrameCount)frames
{
    return buffer ? buffer.frameLength : fileFrames;
}
/* (handlers are called on another thread, as Apple's are, not from inside the render) */
- (void)complete
{
    AVAudioNodeCompletionHandler h = handler;
    AVAudioPlayerNodeCompletionHandler t = typedHandler;
    AVAudioPlayerNodeCompletionCallbackType type = callbackType;
    handler = nil, typedHandler = nil;
    if (!h && !t)
        return;
    dispatch_async(completion_queue(), ^{
      if (h) {
          h();
          Block_release(h);
      }
      if (t) {
          t(type);
          Block_release(t);
      }
    });
}
- (void)dealloc
{
    if (handler)
        Block_release(handler);
    if (typedHandler)
        Block_release(typedHandler);
    [buffer release];
    [file release];
    [super dealloc];
}
@end

@implementation AVAudioPlayerNode {
    NSMutableArray *_queue;
    BOOL _playing;
    AVAudioFramePosition _startNodeTime; /* (node time when player time was 0; -1 until the first render) */
    AVAudioFramePosition _playerTime, _cursor;
    AVAudioPCMBuffer *_fileChunk;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _outputs = 1;
        _queue = [NSMutableArray new];
        _startNodeTime = -1;
    }
    return self;
}

- (void)dealloc
{
    [_queue release];
    [_fileChunk release];
    [super dealloc];
}

MIXING_ACCESSORS

- (BOOL)isPlaying
{
    return _playing;
}

- (void)_schedule:(FinchScheduled *)s at:(AVAudioTime *)when
{
    s->when = when && when.sampleTimeValid ? when.sampleTime : -1;
    if (s->options & AVAudioPlayerNodeBufferInterrupts) {
        for (FinchScheduled *old in _queue)
            [old complete];
        [_queue removeAllObjects];
    } else if (s->options & AVAudioPlayerNodeBufferInterruptsAtLoop) {
        for (FinchScheduled *old in _queue)
            old->options &= ~AVAudioPlayerNodeBufferLoops;
    }
    [_queue addObject:s];
}

- (void)scheduleBuffer:(AVAudioPCMBuffer *)buffer completionHandler:(AVAudioNodeCompletionHandler)completionHandler
{
    [self scheduleBuffer:buffer atTime:nil options:0 completionHandler:completionHandler];
}

- (void)scheduleBuffer:(AVAudioPCMBuffer *)buffer completionCallbackType:(AVAudioPlayerNodeCompletionCallbackType)callbackType
     completionHandler:(AVAudioPlayerNodeCompletionHandler)completionHandler
{
    [self scheduleBuffer:buffer atTime:nil options:0 completionCallbackType:callbackType completionHandler:completionHandler];
}

- (void)scheduleBuffer:(AVAudioPCMBuffer *)buffer atTime:(AVAudioTime *)when options:(AVAudioPlayerNodeBufferOptions)options
     completionHandler:(AVAudioNodeCompletionHandler)completionHandler
{
    FinchScheduled *s = [[FinchScheduled new] autorelease];
    s->buffer = [buffer retain];
    s->options = options;
    s->handler = completionHandler ? Block_copy(completionHandler) : NULL;
    [self _schedule:s at:when];
}

- (void)scheduleBuffer:(AVAudioPCMBuffer *)buffer atTime:(AVAudioTime *)when options:(AVAudioPlayerNodeBufferOptions)options
    completionCallbackType:(AVAudioPlayerNodeCompletionCallbackType)callbackType completionHandler:(AVAudioPlayerNodeCompletionHandler)completionHandler
{
    FinchScheduled *s = [[FinchScheduled new] autorelease];
    s->buffer = [buffer retain];
    s->options = options;
    s->callbackType = callbackType;
    s->typedHandler = completionHandler ? Block_copy(completionHandler) : NULL;
    [self _schedule:s at:when];
}

- (void)scheduleSegment:(AVAudioFile *)file startingFrame:(AVAudioFramePosition)startFrame frameCount:(AVAudioFrameCount)numberFrames
                 atTime:(AVAudioTime *)when completionHandler:(AVAudioNodeCompletionHandler)completionHandler
{
    FinchScheduled *s = [[FinchScheduled new] autorelease];
    s->file = [file retain];
    s->fileStart = startFrame;
    s->fileFrames = numberFrames;
    s->handler = completionHandler ? Block_copy(completionHandler) : NULL;
    [self _schedule:s at:when];
}

- (void)scheduleSegment:(AVAudioFile *)file startingFrame:(AVAudioFramePosition)startFrame frameCount:(AVAudioFrameCount)numberFrames
                 atTime:(AVAudioTime *)when completionCallbackType:(AVAudioPlayerNodeCompletionCallbackType)callbackType
      completionHandler:(AVAudioPlayerNodeCompletionHandler)completionHandler
{
    FinchScheduled *s = [[FinchScheduled new] autorelease];
    s->file = [file retain];
    s->fileStart = startFrame;
    s->fileFrames = numberFrames;
    s->callbackType = callbackType;
    s->typedHandler = completionHandler ? Block_copy(completionHandler) : NULL;
    [self _schedule:s at:when];
}

- (void)scheduleFile:(AVAudioFile *)file atTime:(AVAudioTime *)when completionHandler:(AVAudioNodeCompletionHandler)completionHandler
{
    [self scheduleSegment:file startingFrame:0 frameCount:(AVAudioFrameCount)file.length atTime:when completionHandler:completionHandler];
}

- (void)scheduleFile:(AVAudioFile *)file atTime:(AVAudioTime *)when completionCallbackType:(AVAudioPlayerNodeCompletionCallbackType)callbackType
    completionHandler:(AVAudioPlayerNodeCompletionHandler)completionHandler
{
    [self scheduleSegment:file startingFrame:0 frameCount:(AVAudioFrameCount)file.length atTime:when completionCallbackType:callbackType
        completionHandler:completionHandler];
}

- (void)prepareWithFrameCount:(AVAudioFrameCount)frameCount
{
}

- (void)play
{
    [self playAtTime:nil];
}

- (void)playAtTime:(AVAudioTime *)when
{
    if (_playing)
        return;
    _playing = YES;
    _startNodeTime = when && when.sampleTimeValid ? when.sampleTime - _playerTime : -1;
}

- (void)pause
{
    _playing = NO;
}

- (void)stop
{
    _playing = NO;
    NSArray *pending = [[_queue copy] autorelease];
    [_queue removeAllObjects];
    for (FinchScheduled *s in pending)
        [s complete];
    _playerTime = _cursor = 0;
    _startNodeTime = -1;
}

- (void)reset
{
    [self stop];
}

- (AVAudioTime *)nodeTimeForPlayerTime:(AVAudioTime *)playerTime
{
    if (!_playing || _startNodeTime < 0 || !playerTime.sampleTimeValid)
        return nil;
    return [AVAudioTime timeWithSampleTime:playerTime.sampleTime + _startNodeTime atRate:playerTime.sampleRate];
}

- (AVAudioTime *)playerTimeForNodeTime:(AVAudioTime *)nodeTime
{
    if (!_playing || _startNodeTime < 0 || !nodeTime.sampleTimeValid)
        return nil;
    return [AVAudioTime timeWithSampleTime:nodeTime.sampleTime - _startNodeTime atRate:nodeTime.sampleRate];
}

/* Copies count frames of s, from its frame at, into out at offset. */
- (void)_copy:(FinchScheduled *)s from:(AVAudioFrameCount)at count:(AVAudioFrameCount)count into:(AVAudioPCMBuffer *)out offset:(AVAudioFrameCount)offset
{
    AVAudioPCMBuffer *src = s->buffer;
    AVAudioFrameCount srcAt = at;
    if (s->file) {
        if (!_fileChunk || _fileChunk.frameCapacity < count || ![_fileChunk.format isEqual:s->file.processingFormat]) {
            [_fileChunk release];
            _fileChunk = [[AVAudioPCMBuffer alloc] initWithPCMFormat:s->file.processingFormat frameCapacity:count > 4096 ? count : 4096];
        }
        s->file.framePosition = s->fileStart + at;
        [s->file readIntoBuffer:_fileChunk frameCount:count error:nil];
        src = _fileChunk;
        srcAt = 0;
        count = count < _fileChunk.frameLength ? count : _fileChunk.frameLength;
    }
    AVAudioChannelCount channels = out.format.channelCount < src.format.channelCount ? out.format.channelCount : src.format.channelCount;
    for (AVAudioChannelCount c = 0; c < channels; c++)
        memcpy(out.floatChannelData[c] + offset, src.floatChannelData[c] + srcAt, count * sizeof(float));
}

- (OSStatus)_render:(AVAudioPCMBuffer *)out bus:(AVAudioNodeBus)bus at:(AVAudioFramePosition)time
{
    AVAudioFrameCount frames = out.frameLength;
    zero(out, frames);
    if (!_playing)
        return noErr;
    if (_startNodeTime < 0)
        _startNodeTime = time - _playerTime;
    AVAudioFramePosition first = time - _startNodeTime;
    if (first + frames <= 0) {
        return noErr;
    }
    AVAudioFrameCount offset = first < 0 ? (AVAudioFrameCount)-first : 0;
    AVAudioFramePosition now = first + offset;
    while (offset < frames && _queue.count) {
        FinchScheduled *s = _queue[0];
        AVAudioFramePosition start = s->when >= 0 ? s->when : _cursor;
        if (s->when < 0 && start < now - s->done)
            start = now - s->done;
        if (start > now) {
            AVAudioFramePosition gap = start - now;
            if (gap >= frames - offset)
                break;
            offset += (AVAudioFrameCount)gap;
            now += gap;
        }
        AVAudioFrameCount total = s.frames, left = total - s->done, n = frames - offset < left ? frames - offset : left;
        if (n)
            [self _copy:s from:s->done count:n into:out offset:offset];
        s->done += n;
        offset += n;
        now += n;
        if (s->done >= total) {
            if (s->options & AVAudioPlayerNodeBufferLoops) {
                s->done = 0;
                s->when = -1;
                _cursor = now;
                if (!total)
                    break;
                continue;
            }
            _cursor = now;
            [[s retain] autorelease];
            [_queue removeObjectAtIndex:0];
            [s complete];
        }
    }
    _playerTime = first + frames;
    return noErr;
}

@end

/* --- source and sink nodes --- */

@implementation AVAudioSourceNode {
    AVAudioSourceNodeRenderBlock _block;
    AVAudioFormat *_format;
}

- (instancetype)initWithRenderBlock:(AVAudioSourceNodeRenderBlock)block
{
    if ((self = [super init])) {
        _outputs = 1;
        _block = Block_copy(block);
    }
    return self;
}

- (instancetype)initWithFormat:(AVAudioFormat *)format renderBlock:(AVAudioSourceNodeRenderBlock)block
{
    if ((self = [super init])) {
        _outputs = 1;
        _block = Block_copy(block);
        _format = [format retain];
        if (format)
            _outFormats[@0] = format;
    }
    return self;
}

- (void)dealloc
{
    Block_release(_block);
    [_format release];
    [super dealloc];
}

MIXING_ACCESSORS

- (OSStatus)_render:(AVAudioPCMBuffer *)out bus:(AVAudioNodeBus)bus at:(AVAudioFramePosition)time
{
    AVAudioFrameCount frames = out.frameLength;
    zero(out, frames);
    AudioTimeStamp ts = {0};
    ts.mSampleTime = (Float64)time;
    ts.mFlags = kAudioTimeStampSampleTimeValid;
    BOOL silence = NO;
    AudioBufferList *abl = out.mutableAudioBufferList;
    for (UInt32 i = 0; i < abl->mNumberBuffers; i++)
        abl->mBuffers[i].mDataByteSize = frames * out.format.streamDescription->mBytesPerFrame;
    OSStatus e = _block(&silence, &ts, frames, abl);
    out.frameLength = frames;
    if (silence)
        zero(out, frames);
    return e;
}

@end

@implementation AVAudioSinkNode {
    AVAudioSinkNodeReceiverBlock _block;
}

- (instancetype)initWithReceiverBlock:(AVAudioSinkNodeReceiverBlock)block
{
    if ((self = [super init])) {
        _inputs = 1;
        _block = Block_copy(block);
    }
    return self;
}

- (void)dealloc
{
    Block_release(_block);
    [super dealloc];
}

/* (pulled by the engine each cycle, though nothing is connected to its output) */
- (OSStatus)_receive:(AVAudioFrameCount)frames at:(AVAudioFramePosition)time
{
    AVAudioPCMBuffer *in = nil;
    OSStatus e = pull_input(self, 0, frames, time, &in);
    if (e || !in)
        return e;
    AudioTimeStamp ts = {0};
    ts.mSampleTime = (Float64)time;
    ts.mFlags = kAudioTimeStampSampleTimeValid;
    return _block(&ts, frames, in.audioBufferList);
}

@end

/* --- input and output --- */

@implementation AVAudioIONode

- (NSTimeInterval)presentationLatency
{
    return 0;
}

- (AudioUnit)audioUnit
{
    return NULL;
}

- (BOOL)isVoiceProcessingEnabled
{
    return NO;
}

- (BOOL)setVoiceProcessingEnabled:(BOOL)enabled error:(NSError **)outError
{
    if (!enabled)
        return YES;
    if (outError)
        *outError = [NSError errorWithDomain:NSOSStatusErrorDomain code:kAudioUnitErr_NoConnection userInfo:nil];
    return NO;
}

@end

@implementation AVAudioOutputNode {
    CASpatialAudioExperience *_experience;
}

- (instancetype)_init
{
    if ((self = [super init]))
        _inputs = 1;
    return self;
}

- (void)dealloc
{
    [_experience release];
    [super dealloc];
}

- (CASpatialAudioExperience *)intendedSpatialExperience
{
    return _experience;
}

- (void)setIntendedSpatialExperience:(CASpatialAudioExperience *)e
{
    [_experience autorelease];
    _experience = [e copy];
}

- (OSStatus)_render:(AVAudioPCMBuffer *)out bus:(AVAudioNodeBus)bus at:(AVAudioFramePosition)time
{
    AVAudioPCMBuffer *in = nil;
    AVAudioFrameCount frames = out.frameLength;
    OSStatus e = pull_input(self, 0, frames, time, &in);
    if (e)
        return e;
    zero(out, frames);
    if (in)
        for (AVAudioChannelCount c = 0; c < out.format.channelCount && c < in.format.channelCount; c++)
            memcpy(out.floatChannelData[c], in.floatChannelData[c], frames * sizeof(float));
    return noErr;
}

@end

@implementation AVAudioInputNode {
    AVAudioIONodeInputBlock _inputBlock;
    AVAudioFormat *_manualFormat;
    BOOL _bypassed, _agc, _muted;
    AVAudioVoiceProcessingOtherAudioDuckingConfiguration _ducking;
}

- (instancetype)_init
{
    if ((self = [super init]))
        _outputs = 1;
    return self;
}

- (void)dealloc
{
    if (_inputBlock)
        Block_release(_inputBlock);
    [_manualFormat release];
    [super dealloc];
}

MIXING_ACCESSORS

- (BOOL)setManualRenderingInputPCMFormat:(AVAudioFormat *)format inputBlock:(AVAudioIONodeInputBlock)block
{
    if (!format || !block || !_engine.isInManualRenderingMode)
        return NO;
    if (_inputBlock)
        Block_release(_inputBlock);
    _inputBlock = Block_copy(block);
    [_manualFormat release];
    _manualFormat = [format retain];
    _outFormats[@0] = format;
    return YES;
}

- (BOOL)isVoiceProcessingBypassed { return _bypassed; }
- (void)setVoiceProcessingBypassed:(BOOL)v { _bypassed = v; }
- (BOOL)isVoiceProcessingAGCEnabled { return _agc; }
- (void)setVoiceProcessingAGCEnabled:(BOOL)v { _agc = v; }
- (BOOL)isVoiceProcessingInputMuted { return _muted; }
- (void)setVoiceProcessingInputMuted:(BOOL)v { _muted = v; }
- (BOOL)setMutedSpeechActivityEventListener:(void (^)(AVAudioVoiceProcessingSpeechActivityEvent))listenerBlock { return NO; }
- (AVAudioVoiceProcessingOtherAudioDuckingConfiguration)voiceProcessingOtherAudioDuckingConfiguration { return _ducking; }
- (void)setVoiceProcessingOtherAudioDuckingConfiguration:(AVAudioVoiceProcessingOtherAudioDuckingConfiguration)v { _ducking = v; }

/* (the caller's input in manual rendering; with no input device otherwise, silence) */
- (OSStatus)_render:(AVAudioPCMBuffer *)out bus:(AVAudioNodeBus)bus at:(AVAudioFramePosition)time
{
    AVAudioFrameCount frames = out.frameLength;
    zero(out, frames);
    if (!_inputBlock)
        return noErr;
    const AudioBufferList *in = _inputBlock(frames);
    if (!in)
        return noErr;
    for (UInt32 i = 0; i < in->mNumberBuffers && i < out.format.channelCount; i++) {
        UInt32 n = in->mBuffers[i].mDataByteSize < frames * sizeof(float) ? in->mBuffers[i].mDataByteSize : frames * (UInt32)sizeof(float);
        memcpy(out.floatChannelData[i], in->mBuffers[i].mData, n);
    }
    return noErr;
}

@end

/* --- the engine --- */

@interface AVAudioEngine () {
    NSMutableSet *_nodes;
    AVAudioOutputNode *_output;
    AVAudioInputNode *_input;
    AVAudioMixerNode *_mixer;
    BOOL _running, _manual, _autoShutdown;
    AVAudioEngineManualRenderingMode _mode;
    AVAudioFormat *_manualFormat;
    AVAudioFrameCount _maxFrames;
    AVAudioFramePosition _sampleTime;
    AVAudioPCMBuffer *_renderBuffer;
    MusicSequence _sequence;
    dispatch_source_t _clock;
    dispatch_queue_t _queue;
}
@end

@implementation AVAudioEngine

- (instancetype)init
{
    if ((self = [super init])) {
        _nodes = [NSMutableSet new];
        _output = [[AVAudioOutputNode alloc] _init];
        [self attachNode:_output];
        _queue = dispatch_queue_create("org.finch.AVAudioEngine.render", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc
{
    [self stop];
    for (AVAudioNode *n in _nodes)
        n->_engine = nil;
    [_nodes release];
    [_output release];
    [_input release];
    [_mixer release];
    [_manualFormat release];
    [_renderBuffer release];
    dispatch_release(_queue);
    [super dealloc];
}

- (NSSet *)attachedNodes
{
    return [[_nodes copy] autorelease];
}

- (void)attachNode:(AVAudioNode *)node
{
    if (!node || [_nodes containsObject:node])
        return;
    if (node->_engine && node->_engine != self)
        [NSException raise:NSInternalInconsistencyException format:@"required condition is false: !nodeimpl->HasEngineImpl()"];
    [_nodes addObject:node];
    node->_engine = self;
}

- (void)detachNode:(AVAudioNode *)node
{
    if (![_nodes containsObject:node])
        return;
    [self disconnectNodeInput:node];
    [self disconnectNodeOutput:node];
    node->_engine = nil;
    [_nodes removeObject:node];
}

/* The format the engine's output runs at: the manual rendering format, or the device's. */
- (AVAudioFormat *)_outputFormat
{
    return _manual ? _manualFormat : standard(44100, 2);
}

- (void)connect:(AVAudioNode *)node1 to:(AVAudioNode *)node2 fromBus:(AVAudioNodeBus)bus1 toBus:(AVAudioNodeBus)bus2 format:(AVAudioFormat *)format
{
    AVAudioConnectionPoint *p = [[[AVAudioConnectionPoint alloc] initWithNode:node2 bus:bus2] autorelease];
    [self connect:node1 toConnectionPoints:@[ p ] fromBus:bus1 format:format];
}

- (void)connect:(AVAudioNode *)node1 to:(AVAudioNode *)node2 format:(AVAudioFormat *)format
{
    AVAudioNodeBus bus = [node2 isKindOfClass:[AVAudioMixerNode class]] ? ((AVAudioMixerNode *)node2).nextAvailableInputBus : 0;
    [self connect:node1 to:node2 fromBus:0 toBus:bus format:format];
}

- (void)connect:(AVAudioNode *)sourceNode toConnectionPoints:(NSArray<AVAudioConnectionPoint *> *)destNodes fromBus:(AVAudioNodeBus)sourceBus
         format:(AVAudioFormat *)format
{
    if (![_nodes containsObject:sourceNode])
        [NSException raise:NSInternalInconsistencyException format:@"required condition is false: IsNodeAttached(node1)"];
    /* (no format: the source's output format as it stands) */
    AVAudioFormat *f = format ? format : [sourceNode outputFormatForBus:sourceBus];
    if (sourceNode == _mixer || [sourceNode isKindOfClass:[AVAudioOutputNode class]])
        f = format ? format : [self _outputFormat];
    sourceNode->_outFormats[@(sourceBus)] = f;
    [self disconnectNodeOutput:sourceNode bus:sourceBus];
    for (AVAudioConnectionPoint *p in destNodes) {
        AVAudioNode *d = p.node;
        if (!d || p.bus >= 64 || ![_nodes containsObject:d])
            continue;
        [self disconnectNodeInput:d bus:p.bus];
        d->_in[p.bus].source = sourceNode;
        d->_in[p.bus].bus = sourceBus;
        d->_in[p.bus].format = [f retain];
        [d _wasConnected];
    }
}

- (void)disconnectNodeInput:(AVAudioNode *)node bus:(AVAudioNodeBus)bus
{
    if (bus >= 64 || !node->_in[bus].source)
        return;
    node->_in[bus].source = nil;
    [node->_in[bus].format release];
    node->_in[bus].format = nil;
}

- (void)disconnectNodeInput:(AVAudioNode *)node
{
    for (AVAudioNodeBus b = 0; b < 64; b++)
        [self disconnectNodeInput:node bus:b];
}

- (void)disconnectNodeOutput:(AVAudioNode *)node bus:(AVAudioNodeBus)bus
{
    for (AVAudioNode *d in _nodes)
        for (AVAudioNodeBus b = 0; b < 64; b++)
            if (d->_in[b].source == node && d->_in[b].bus == bus)
                [self disconnectNodeInput:d bus:b];
}

- (void)disconnectNodeOutput:(AVAudioNode *)node
{
    for (AVAudioNodeBus b = 0; b < 8; b++)
        [self disconnectNodeOutput:node bus:b];
}

- (AVAudioConnectionPoint *)inputConnectionPointForNode:(AVAudioNode *)node inputBus:(AVAudioNodeBus)bus
{
    if (bus >= 64 || !node->_in[bus].source)
        return nil;
    return [[[AVAudioConnectionPoint alloc] initWithNode:node->_in[bus].source bus:node->_in[bus].bus] autorelease];
}

- (NSArray<AVAudioConnectionPoint *> *)outputConnectionPointsForNode:(AVAudioNode *)node outputBus:(AVAudioNodeBus)bus
{
    NSMutableArray *points = [NSMutableArray array];
    for (AVAudioNode *d in _nodes)
        for (AVAudioNodeBus b = 0; b < 64; b++)
            if (d->_in[b].source == node && d->_in[b].bus == bus)
                [points addObject:[[[AVAudioConnectionPoint alloc] initWithNode:d bus:b] autorelease]];
    return points;
}

- (AVAudioOutputNode *)outputNode
{
    return _output;
}

- (AVAudioInputNode *)inputNode
{
    if (!_input) {
        _input = [[AVAudioInputNode alloc] _init];
        [self attachNode:_input];
    }
    return _input;
}

/* (made on first use, connected to the output at its format) */
- (AVAudioMixerNode *)mainMixerNode
{
    if (!_mixer) {
        _mixer = [AVAudioMixerNode new];
        [self attachNode:_mixer];
        [self connect:_mixer to:_output format:[self _outputFormat]];
    }
    return _mixer;
}

- (MusicSequence)musicSequence
{
    return _sequence;
}

- (void)setMusicSequence:(MusicSequence)s
{
    _sequence = s;
}

- (BOOL)isRunning
{
    return _running;
}

- (BOOL)isAutoShutdownEnabled
{
    return _autoShutdown;
}

- (void)setAutoShutdownEnabled:(BOOL)v
{
    _autoShutdown = v;
}

- (void)prepare
{
}

/* One cycle: the output's input pulled for frames, and the sinks. */
- (OSStatus)_renderCycle:(AVAudioFrameCount)frames into:(AVAudioPCMBuffer *)out
{
    AVAudioFormat *f = [self _outputFormat];
    if (!_renderBuffer || _renderBuffer.frameCapacity < frames || ![_renderBuffer.format isEqual:f]) {
        [_renderBuffer release];
        _renderBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:f frameCapacity:frames > 4096 ? frames : 4096];
    }
    AVAudioPCMBuffer *b = nil;
    OSStatus e = [_output _pull:0 frames:frames at:_sampleTime into:&b];
    for (AVAudioNode *n in [[_nodes copy] autorelease])
        if ([n isKindOfClass:[AVAudioSinkNode class]])
            [(AVAudioSinkNode *)n _receive:frames at:_sampleTime];
    _sampleTime += frames;
    if (e)
        return e;
    if (out) {
        /* (into the caller's buffer, in its format) */
        if ([out.format isEqual:b.format]) {
            for (AVAudioChannelCount c = 0; c < out.format.channelCount; c++)
                memcpy(out.floatChannelData[c], b.floatChannelData[c], frames * sizeof(float));
        } else {
            AudioConverterRef conv = NULL;
            if (AudioConverterNew(b.format.streamDescription, out.format.streamDescription, &conv))
                return kAudioUnitErr_FormatNotSupported;
            UInt32 inBytes = frames * b.format.streamDescription->mBytesPerFrame, outBytes = frames * out.format.streamDescription->mBytesPerFrame;
            e = AudioConverterConvertComplexBuffer(conv, frames, b.audioBufferList, out.mutableAudioBufferList);
            (void)inBytes, (void)outBytes;
            AudioConverterDispose(conv);
        }
        out.frameLength = frames;
    }
    return e;
}

- (BOOL)startAndReturnError:(NSError **)outError
{
    if (_running)
        return YES;
    if (!_manual && !_mixer && !_output->_in[0].source && ![self _hasSinks]) {
        /* (nothing to render: Apple's starts all the same) */
    }
    _running = YES;
    if (!_manual) {
        /* (no device to play through yet: the output's rate kept by a timer, the audio dropped) */
        AVAudioFormat *f = [self _outputFormat];
        uint64_t interval = (uint64_t)(kSilentChunk / f.sampleRate * NSEC_PER_SEC);
        _clock = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
        dispatch_source_set_timer(_clock, dispatch_time(DISPATCH_TIME_NOW, (int64_t)interval), interval, interval / 10);
        __block AVAudioEngine *engine = self;
        dispatch_source_set_event_handler(_clock, ^{
          [engine _renderCycle:kSilentChunk into:nil];
        });
        dispatch_resume(_clock);
    }
    return YES;
}

- (BOOL)_hasSinks
{
    for (AVAudioNode *n in _nodes)
        if ([n isKindOfClass:[AVAudioSinkNode class]])
            return YES;
    return NO;
}

- (void)_stopClock
{
    if (_clock) {
        dispatch_source_cancel(_clock);
        dispatch_sync(_queue, ^{
                      });
        dispatch_release(_clock);
        _clock = NULL;
    }
}

- (void)pause
{
    [self _stopClock];
    _running = NO;
}

- (void)stop
{
    [self _stopClock];
    _running = NO;
    for (AVAudioNode *n in _nodes)
        if ([n isKindOfClass:[AVAudioPlayerNode class]])
            [(AVAudioPlayerNode *)n stop];
}

- (void)reset
{
    for (AVAudioNode *n in _nodes)
        [n reset];
}

/* --- manual rendering --- */

- (BOOL)enableManualRenderingMode:(AVAudioEngineManualRenderingMode)mode format:(AVAudioFormat *)pcmFormat
                maximumFrameCount:(AVAudioFrameCount)maximumFrameCount error:(NSError **)outError
{
    if (!pcmFormat) {
        if (outError)
            *outError = [NSError errorWithDomain:NSOSStatusErrorDomain code:AVAudioEngineManualRenderingErrorInitialized userInfo:nil];
        return NO;
    }
    _manual = YES;
    _mode = mode;
    [_manualFormat release];
    _manualFormat = [pcmFormat retain];
    _maxFrames = maximumFrameCount;
    _sampleTime = 0;
    /* (the output, and the mixer feeding it, now at the manual format) */
    _output->_outFormats[@0] = pcmFormat;
    if (_mixer)
        [self connect:_mixer to:_output format:pcmFormat];
    return YES;
}

- (void)disableManualRenderingMode
{
    if (_running)
        return;
    _manual = NO;
    [_output->_outFormats removeObjectForKey:@0];
    if (_mixer)
        [self connect:_mixer to:_output format:[self _outputFormat]];
}

- (BOOL)isInManualRenderingMode
{
    return _manual;
}

- (AVAudioEngineManualRenderingMode)manualRenderingMode
{
    return _mode;
}

- (AVAudioFormat *)manualRenderingFormat
{
    return _manual ? _manualFormat : [self _outputFormat];
}

- (AVAudioFrameCount)manualRenderingMaximumFrameCount
{
    return _maxFrames;
}

- (AVAudioFramePosition)manualRenderingSampleTime
{
    return _sampleTime;
}

- (AVAudioEngineManualRenderingStatus)renderOffline:(AVAudioFrameCount)numberOfFrames toBuffer:(AVAudioPCMBuffer *)buffer error:(NSError **)outError
{
    OSStatus e = noErr;
    if (!_manual)
        e = AVAudioEngineManualRenderingErrorInvalidMode;
    else if (!_running)
        e = AVAudioEngineManualRenderingErrorNotRunning;
    else if (numberOfFrames > _maxFrames || numberOfFrames > buffer.frameCapacity)
        e = kAudio_ParamError;
    if (!e)
        e = [self _renderCycle:numberOfFrames into:buffer];
    if (e) {
        if (outError)
            *outError = [NSError errorWithDomain:NSOSStatusErrorDomain code:e userInfo:nil];
        return AVAudioEngineManualRenderingStatusError;
    }
    return AVAudioEngineManualRenderingStatusSuccess;
}

- (AVAudioEngineManualRenderingBlock)manualRenderingBlock
{
    __block AVAudioEngine *engine = self;
    return [[^AVAudioEngineManualRenderingStatus(AVAudioFrameCount frames, AudioBufferList *outBuffer, OSStatus *outError) {
      AVAudioPCMBuffer *b = [[[AVAudioPCMBuffer alloc] initWithPCMFormat:engine->_manualFormat bufferListNoCopy:outBuffer deallocator:nil] autorelease];
      NSError *err = nil;
      AVAudioEngineManualRenderingStatus st = [engine renderOffline:frames toBuffer:b error:&err];
      if (outError)
          *outError = err ? (OSStatus)err.code : noErr;
      return st;
    } copy] autorelease];
}

/* --- MIDI connections (no MIDI nodes yet: recorded, nothing sent) --- */

- (void)connectMIDI:(AVAudioNode *)sourceNode to:(AVAudioNode *)destinationNode format:(AVAudioFormat *)format block:(AUMIDIOutputEventBlock)tapBlock
{
}

- (void)connectMIDI:(AVAudioNode *)sourceNode to:(AVAudioNode *)destinationNode format:(AVAudioFormat *)format eventListBlock:(AUMIDIEventListBlock)tapBlock
{
}

- (void)connectMIDI:(AVAudioNode *)sourceNode toNodes:(NSArray<AVAudioNode *> *)destinationNodes format:(AVAudioFormat *)format block:(AUMIDIOutputEventBlock)tapBlock
{
}

- (void)connectMIDI:(AVAudioNode *)sourceNode toNodes:(NSArray<AVAudioNode *> *)destinationNodes format:(AVAudioFormat *)format
     eventListBlock:(AUMIDIEventListBlock)tapBlock
{
}

- (void)disconnectMIDI:(AVAudioNode *)sourceNode from:(AVAudioNode *)destinationNode
{
}

- (void)disconnectMIDI:(AVAudioNode *)sourceNode fromNodes:(NSArray<AVAudioNode *> *)destinationNodes
{
}

- (void)disconnectMIDIInput:(AVAudioNode *)node
{
}

- (void)disconnectMIDIOutput:(AVAudioNode *)node
{
}

@end
