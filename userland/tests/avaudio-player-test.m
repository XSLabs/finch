/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-avaudio-player-test: AVAudioPlayer, run against Apple's AVFAudio and Finch's
 * to compare (tools/host-tests.sh): a sound from a file and from memory, its duration,
 * format and settings, seeking, pausing, playing to the end (the delegate told on the
 * main thread), loops, and the errors for missing and unreadable sounds.
 */
#import <AVFAudio/AVFAudio.h>
#include <dlfcn.h>
#include <stdio.h>
#include <unistd.h>

@interface Listener : NSObject <AVAudioPlayerDelegate>
@end

@implementation Listener
- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)p successfully:(BOOL)ok
{
    printf("  finished %d on main %d time %.3f playing %d\n", ok, [NSThread isMainThread], p.currentTime, p.playing);
    CFRunLoopStop(CFRunLoopGetMain());
}
@end

static NSURL *
make_sound(const char *name, double rate, AVAudioChannelCount channels, AVAudioFrameCount frames)
{
    NSString *path = [NSString stringWithFormat:@"/tmp/finch-avaudio-player-test.%d.%s", (int)getpid(), name];
    NSURL *u = [NSURL fileURLWithPath:path];
    AVAudioFormat *f = [[[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16 sampleRate:rate channels:channels interleaved:YES] autorelease];
    NSError *e = nil;
    AVAudioFile *file = [[AVAudioFile alloc] initForWriting:u settings:f.settings commonFormat:AVAudioPCMFormatInt16 interleaved:YES error:&e];
    AVAudioPCMBuffer *b = [[[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat frameCapacity:frames] autorelease];
    b.frameLength = frames;
    [file writeFromBuffer:b error:&e];
    [file release];
    return u;
}

static void
describe(const char *label, AVAudioPlayer *p)
{
    printf("%s: duration %.4f channels %lu volume %g pan %g rate %g enableRate %d loops %ld playing %d time %g url %d data %d\n", label, p.duration,
           (unsigned long)p.numberOfChannels, p.volume, p.pan, p.rate, p.enableRate, (long)p.numberOfLoops, p.playing, p.currentTime, p.url != nil,
           p.data != nil);
    printf("  format %u ch %g Hz common %ld interleaved %d\n", p.format.channelCount, p.format.sampleRate, (long)p.format.commonFormat,
           p.format.interleaved);
    NSArray *keys = [p.settings.allKeys sortedArrayUsingSelector:@selector(compare:)];
    printf("  settings:");
    for (NSString *k in keys)
        printf(" %s=%s", k.UTF8String, [p.settings[k] description].UTF8String);
    printf("\n");
}

int
main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        Dl_info info;
        dladdr((void *)[AVAudioPlayer class], &info);
        printf("%s\n", info.dli_fname);
        NSURL *u = make_sound("short.wav", 8000, 2, 2000);
        NSError *e = nil;
        AVAudioPlayer *p = [[[AVAudioPlayer alloc] initWithContentsOfURL:u error:&e] autorelease];
        printf("init %d error %ld\n", p != nil, (long)e.code);
        describe("file", p);
        p.currentTime = 0.1;
        printf("seek %.4f", p.currentTime);
        p.currentTime = 5;
        printf(" past the end %.4f", p.currentTime);
        p.currentTime = -1;
        printf(" before the start %.4f\n", p.currentTime);
        p.volume = 2;
        p.pan = -3;
        p.rate = 9;
        printf("volume %g pan %g rate %g\n", p.volume, p.pan, p.rate);
        p.volume = 1;
        p.pan = 0;
        p.rate = 1;
        printf("prepare %d\n", [p prepareToPlay]);
        p.meteringEnabled = YES;
        [p updateMeters];
        printf("meters before playing %g %g\n", [p peakPowerForChannel:0], [p averagePowerForChannel:0]);
        Listener *l = [[Listener new] autorelease];
        p.delegate = l;
        printf("play %d playing %d\n", [p play], p.playing);
        [p pause];
        printf("paused: playing %d\n", p.playing);
        printf("play again %d\n", [p play]);
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 3, false);
        printf("after: playing %d time %g\n", p.playing, p.currentTime);
        p.numberOfLoops = 1;
        [p play];
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.3, false);
        printf("looping: playing %d\n", p.playing);
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 3, false);
        [p stop];
        printf("stopped: playing %d\n", p.playing);

        AVAudioPlayer *d = [[[AVAudioPlayer alloc] initWithData:[NSData dataWithContentsOfURL:u] error:&e] autorelease];
        describe("data", d);
        AVAudioPlayer *mono = [[[AVAudioPlayer alloc] initWithContentsOfURL:make_sound("mono.caf", 44100, 1, 4410) error:&e] autorelease];
        describe("caf", mono);
        AVAudioPlayer *bad = [[AVAudioPlayer alloc] initWithData:[NSData dataWithBytes:"junkjunkjunk" length:12] error:&e];
        printf("junk: %d error %ld %s\n", bad != nil, (long)e.code, e.domain.UTF8String);
        AVAudioPlayer *missing = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:@"/tmp/finch-no-such-sound.wav"] error:&e];
        printf("missing: %d error %ld %s\n", missing != nil, (long)e.code, e.domain.UTF8String);
    }
    return 0;
}
