/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-avaudio-engine-test: AVAudioTime and AVAudioEngine's offline manual rendering,
 * run against Apple's AVFAudio and Finch's to compare (tools/host-tests.sh): players
 * (timed and looping buffers, interrupts, files, completions, player and node times),
 * the mixer (volume, pan, sums, rates), source and sink nodes, taps, connection points
 * and the manual rendering errors.
 */
#import <AVFAudio/AVFAudio.h>
#include <dlfcn.h>
#include <stdio.h>
#include <unistd.h>

/* (completions and taps arrive on another thread: a moment to let them) */
#define SETTLE() usleep(100000)

static void
times(void)
{
    AVAudioTime *a = [AVAudioTime timeWithHostTime:24000000], *b = [AVAudioTime timeWithSampleTime:4410 atRate:44100];
    AVAudioTime *c = [AVAudioTime timeWithHostTime:24000000 sampleTime:100 atRate:48000];
    for (AVAudioTime *t in @[ a, b, c ])
        printf("time: host valid %d sample valid %d host %llu sample %lld rate %g\n", t.hostTimeValid, t.sampleTimeValid, t.hostTime, t.sampleTime, t.sampleRate);
    AVAudioTime *x = [b extrapolateTimeFromAnchor:c];
    printf("extrapolated: %d %llu %lld %g\n", x.hostTimeValid, x.hostTime, x.sampleTime, x.sampleRate);
    x = [[AVAudioTime timeWithSampleTime:200 atRate:48000] extrapolateTimeFromAnchor:c];
    printf("extrapolated: %llu\n", x.hostTime);
    printf("host only from anchor: %s\n", [a extrapolateTimeFromAnchor:c] ? "a time" : "nil");
    printf("seconds %g host %llu\n", [AVAudioTime secondsForHostTime:24000000], [AVAudioTime hostTimeForSeconds:1.5]);
    AudioTimeStamp ts = c.audioTimeStamp;
    printf("stamp flags %u sample %g host %llu\n", (unsigned)ts.mFlags, ts.mSampleTime, ts.mHostTime);
    printf("equal %d\n", [c isEqual:[AVAudioTime timeWithHostTime:24000000 sampleTime:100 atRate:48000]]);
}

static AVAudioEngine *
offline(void)
{
    AVAudioEngine *e = [AVAudioEngine new];
    AVAudioFormat *fmt = [[[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2] autorelease];
    NSError *err = nil;
    if (![e enableManualRenderingMode:AVAudioEngineManualRenderingModeOffline format:fmt maximumFrameCount:256 error:&err])
        printf("manual failed %ld\n", (long)err.code);
    return e;
}

static AVAudioPCMBuffer *
ramp(AVAudioFormat *f, AVAudioFrameCount n, float scale)
{
    AVAudioPCMBuffer *b = [[[AVAudioPCMBuffer alloc] initWithPCMFormat:f frameCapacity:n] autorelease];
    b.frameLength = n;
    for (AVAudioChannelCount c = 0; c < f.channelCount; c++)
        for (AVAudioFrameCount i = 0; i < n; i++)
            b.floatChannelData[c][i] = (i + 1) * scale * (c ? -1 : 1);
    return b;
}

static void
render(AVAudioEngine *e, AVAudioFrameCount frames, int shown)
{
    AVAudioPCMBuffer *out = [[[AVAudioPCMBuffer alloc] initWithPCMFormat:e.manualRenderingFormat frameCapacity:256] autorelease];
    NSError *err = nil;
    AVAudioEngineManualRenderingStatus st = [e renderOffline:frames toBuffer:out error:&err];
    printf("  render %ld len %u time %lld\n", (long)st, out.frameLength, (long long)e.manualRenderingSampleTime);
    for (AVAudioChannelCount c = 0; c < out.format.channelCount; c++) {
        printf("  ch%u:", c);
        for (int i = 0; i < shown && i < (int)out.frameLength; i++)
            printf(" %.4f", out.floatChannelData[c][i]);
        printf("\n");
    }
}

static AVAudioFormat *
mono(double rate)
{
    return [[[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:1] autorelease];
}

static void
players(void)
{
    AVAudioEngine *e = offline();
    AVAudioPlayerNode *p = [[AVAudioPlayerNode new] autorelease];
    [e attachNode:p];
    [e connect:p to:e.mainMixerNode format:mono(48000)];
    printf("player: inputs %lu outputs %lu, mixer inputs %lu outputs %lu, attached %lu\n", (unsigned long)p.numberOfInputs, (unsigned long)p.numberOfOutputs,
           (unsigned long)e.mainMixerNode.numberOfInputs, (unsigned long)e.mainMixerNode.numberOfOutputs, (unsigned long)e.attachedNodes.count);
    __block int done = 0;
    [p scheduleBuffer:ramp(mono(48000), 16, 1 / 16.0f) atTime:[AVAudioTime timeWithSampleTime:4 atRate:48000] options:0 completionHandler:^{
      done++;
    }];
    [p scheduleBuffer:ramp(mono(48000), 4, 0.25f) completionHandler:^{
      done += 10;
    }];
    NSError *err = nil;
    printf("start %d\n", [e startAndReturnError:&err]);
    printf("playing before %d\n", p.playing);
    [p play];
    printf("playing %d\n", p.playing);
    render(e, 32, 28);
    SETTLE();
    printf("  completions %d\n", done);
    AVAudioTime *last = p.lastRenderTime;
    printf("  last render %lld, player time %lld, node time for player 5 %lld\n", last.sampleTime, [p playerTimeForNodeTime:last].sampleTime,
           [p nodeTimeForPlayerTime:[AVAudioTime timeWithSampleTime:5 atRate:48000]].sampleTime);
    /* (volume and pan changed while playing ramp in Apple's; not compared here) */
    /* The player timeline is at sample 32; leave eight frames before this buffer. */
    [p scheduleBuffer:ramp(mono(48000), 8, 0.125f) atTime:[AVAudioTime timeWithSampleTime:40 atRate:48000] options:0 completionHandler:nil];
    render(e, 16, 12);
    [p pause];
    printf("paused: playing %d player time %s\n", p.playing, [p playerTimeForNodeTime:p.lastRenderTime] ? "some" : "nil");
    /* The player timeline is at sample 48; pausing keeps this timestamp fixed. */
    [p scheduleBuffer:ramp(mono(48000), 4, 0.25f) atTime:[AVAudioTime timeWithSampleTime:48 atRate:48000] options:0 completionHandler:^{
      done += 100;
    }];
    render(e, 8, 8);
    [p play];
    render(e, 8, 8);
    SETTLE();
    printf("  completions %d\n", done);
    /* loops and interrupts */
    [p stop];
    [p scheduleBuffer:ramp(mono(48000), 3, 0.25f) atTime:nil options:AVAudioPlayerNodeBufferLoops completionHandler:^{
      done += 1000;
    }];
    [p play];
    render(e, 10, 10);
    SETTLE();
    printf("  completions %d\n", done);
    [p scheduleBuffer:ramp(mono(48000), 4, 0.25f) completionHandler:^{
      done += 10000;
    }];
    [p stop];
    SETTLE();
    printf("stopped: completions %d playing %d\n", done, p.playing);
    [e stop];
    [e release];
}

static void
run(float pan, AVAudioChannelCount channels, float mixerVolume, int count, double rate)
{
    AVAudioEngine *e = offline();
    AVAudioFormat *src = [[[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:channels] autorelease];
    for (int k = 0; k < count; k++) {
        AVAudioPlayerNode *p = [[AVAudioPlayerNode new] autorelease];
        [e attachNode:p];
        [e connect:p to:e.mainMixerNode format:src];
        AVAudioPCMBuffer *b = [[[AVAudioPCMBuffer alloc] initWithPCMFormat:src frameCapacity:64] autorelease];
        b.frameLength = 64;
        for (AVAudioChannelCount c = 0; c < channels; c++)
            for (int i = 0; i < 64; i++)
                b.floatChannelData[c][i] = c ? -0.25f : 0.5f;
        [p scheduleBuffer:b completionHandler:nil];
    }
    e.mainMixerNode.outputVolume = mixerVolume;
    [e startAndReturnError:nil];
    for (AVAudioNode *n in e.attachedNodes)
        if ([n isKindOfClass:[AVAudioPlayerNode class]]) {
            [(AVAudioPlayerNode *)n play];
            ((AVAudioPlayerNode *)n).pan = pan;
        }
    AVAudioPCMBuffer *out = [[[AVAudioPCMBuffer alloc] initWithPCMFormat:e.manualRenderingFormat frameCapacity:64] autorelease];
    [e renderOffline:16 toBuffer:out error:nil];
    printf("mix pan %g channels %u volume %g sources %d rate %g: L %.6f R %.6f\n", pan, channels, mixerVolume, count, rate, out.floatChannelData[0][8],
           out.floatChannelData[1][8]);
    [e stop];
    [e release];
}

static void
mixing(void)
{
    float pans[] = {0, 0.05f, 0.25f, 0.5f, -0.5f, 0.9f, 1, -1};
    for (int i = 0; i < 8; i++)
        run(pans[i], 1, 1, 1, 48000);
    run(0, 2, 1, 1, 48000);
    run(-1, 2, 1, 1, 48000);
    run(0.5f, 2, 1, 1, 48000);
    run(0, 1, 0.5f, 1, 48000);
    run(0, 1, 1, 3, 48000);
    AVAudioEngine *e = offline();
    printf("mixer next bus %u volume %g\n", (unsigned)e.mainMixerNode.nextAvailableInputBus, e.mainMixerNode.outputVolume);
    AVAudioPlayerNode *p = [[AVAudioPlayerNode new] autorelease];
    [e attachNode:p];
    [e connect:p to:e.mainMixerNode format:mono(48000)];
    printf("after one: next bus %u\n", (unsigned)e.mainMixerNode.nextAvailableInputBus);
    AVAudioConnectionPoint *in = [e inputConnectionPointForNode:e.mainMixerNode inputBus:0];
    NSArray *outs = [e outputConnectionPointsForNode:p outputBus:0];
    printf("connections: in from player %d bus %u, outs %lu to mixer %d\n", in.node == p, (unsigned)in.bus, (unsigned long)outs.count,
           outs.count && [outs[0] node] == e.mainMixerNode);
    AVAudioMixingDestination *d = [p destinationForMixer:e.mainMixerNode bus:0];
    d.volume = 0.25f;
    printf("destination: %d bus %u volume %g, wrong bus %s\n", d.connectionPoint.node == e.mainMixerNode, (unsigned)d.connectionPoint.bus, d.volume,
           [p destinationForMixer:e.mainMixerNode bus:3] ? "some" : "nil");
    [e disconnectNodeOutput:p];
    printf("disconnected: in %s outs %lu\n", [e inputConnectionPointForNode:e.mainMixerNode inputBus:0] ? "some" : "nil",
           (unsigned long)[e outputConnectionPointsForNode:p outputBus:0].count);
    [e detachNode:p];
    printf("detached: engine %s attached %lu\n", p.engine ? "some" : "nil", (unsigned long)e.attachedNodes.count);
    [e release];
}

static void
nodes(void)
{
    AVAudioEngine *e = offline();
    __block int calls = 0;
    AVAudioSourceNode *s = [[[AVAudioSourceNode alloc] initWithRenderBlock:^OSStatus(BOOL *silence, const AudioTimeStamp *ts, AVAudioFrameCount n,
                                                                                    AudioBufferList *abl) {
      calls++;
      for (UInt32 b = 0; b < abl->mNumberBuffers; b++)
          for (AVAudioFrameCount i = 0; i < n; i++)
              ((float *)abl->mBuffers[b].mData)[i] = (float)(ts->mSampleTime + i) / 100;
      return noErr;
    }] autorelease];
    [e attachNode:s];
    [e connect:s to:e.mainMixerNode format:mono(48000)];
    __block double received = 0;
    __block int sinkCalls = 0;
    AVAudioSinkNode *sink = [[[AVAudioSinkNode alloc] initWithReceiverBlock:^OSStatus(const AudioTimeStamp *ts, AVAudioFrameCount n, const AudioBufferList *abl) {
      sinkCalls++;
      received += ((float *)abl->mBuffers[0].mData)[n - 1];
      return noErr;
    }] autorelease];
    printf("sink: inputs %lu outputs %lu\n", (unsigned long)sink.numberOfInputs, (unsigned long)sink.numberOfOutputs);
    __block int taps = 0;
    __block AVAudioFrameCount tapped = 0;
    [e.mainMixerNode installTapOnBus:0 bufferSize:24 format:nil block:^(AVAudioPCMBuffer *b, AVAudioTime *when) {
      taps++;
      tapped += b.frameLength;
    }];
    [e startAndReturnError:nil];
    render(e, 16, 6);
    render(e, 16, 6);
    for (int i = 0; i < 40; i++)
        [e renderOffline:256 toBuffer:[[[AVAudioPCMBuffer alloc] initWithPCMFormat:e.manualRenderingFormat frameCapacity:256] autorelease] error:nil];
    SETTLE();
    printf("  source calls %d, taps %d (%u frames)\n", calls, taps, tapped);
    [e.mainMixerNode removeTapOnBus:0];
    [e stop];
    printf("render stopped: %ld\n", (long)[e renderOffline:16 toBuffer:[[[AVAudioPCMBuffer alloc] initWithPCMFormat:e.manualRenderingFormat frameCapacity:64] autorelease] error:nil]);
    NSError *err = nil;
    [e startAndReturnError:nil];
    AVAudioPCMBuffer *small = [[[AVAudioPCMBuffer alloc] initWithPCMFormat:e.manualRenderingFormat frameCapacity:8] autorelease];
    printf("render more than capacity: %ld\n", (long)[e renderOffline:16 toBuffer:small error:&err]);
    printf("enable while running: %d\n", [e enableManualRenderingMode:AVAudioEngineManualRenderingModeOffline format:e.manualRenderingFormat maximumFrameCount:64 error:&err]);
    [e stop];
    [e release];
    AVAudioEngine *plain = [[AVAudioEngine new] autorelease];
    printf("plain engine: manual %d, renders %ld\n", plain.isInManualRenderingMode,
           (long)[plain renderOffline:16 toBuffer:[[[AVAudioPCMBuffer alloc] initWithPCMFormat:mono(48000) frameCapacity:64] autorelease] error:nil]);
    (void)sinkCalls, (void)received;
}

int
main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        Dl_info info;
        dladdr((void *)[AVAudioEngine class], &info);
        printf("%s\n", info.dli_fname);
        times();
        players();
        mixing();
        nodes();
    }
    return 0;
}
