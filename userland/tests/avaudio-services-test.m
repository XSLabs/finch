/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-avaudio-services-test: AVAudioSession, AVAudioApplication, AVAudioRoutingArbiter
 * and speech synthesis on Finch, checked against what Finch should answer (Finch has no
 * audio devices or voices yet): the session's route and settings, muting, arbitration,
 * utterances, and a synthesizer working through utterances word by word.
 */
#import <AVFAudio/AVFAudio.h>
#import <objc/message.h>
#include <stdio.h>

@interface Listener : NSObject <AVSpeechSynthesizerDelegate>
@property (retain) NSMutableArray *events;
@end

@implementation Listener
- (void)speechSynthesizer:(AVSpeechSynthesizer *)s didStartSpeechUtterance:(AVSpeechUtterance *)u { [self.events addObject:[@"start " stringByAppendingString:u.speechString]]; }
- (void)speechSynthesizer:(AVSpeechSynthesizer *)s didFinishSpeechUtterance:(AVSpeechUtterance *)u
{
    [self.events addObject:[@"finish " stringByAppendingString:u.speechString]];
    if (!s.speaking)
        CFRunLoopStop(CFRunLoopGetMain());
}
- (void)speechSynthesizer:(AVSpeechSynthesizer *)s didCancelSpeechUtterance:(AVSpeechUtterance *)u { [self.events addObject:[@"cancel " stringByAppendingString:u.speechString]]; }
- (void)speechSynthesizer:(AVSpeechSynthesizer *)s didPauseSpeechUtterance:(AVSpeechUtterance *)u { [self.events addObject:@"pause"]; }
- (void)speechSynthesizer:(AVSpeechSynthesizer *)s didContinueSpeechUtterance:(AVSpeechUtterance *)u { [self.events addObject:@"continue"]; }
- (void)speechSynthesizer:(AVSpeechSynthesizer *)s willSpeakRangeOfSpeechString:(NSRange)r utterance:(AVSpeechUtterance *)u
{
    [self.events addObject:[NSString stringWithFormat:@"word %@", [u.speechString substringWithRange:r]]];
}
@end

int
main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        id s = [NSClassFromString(@"AVAudioSession") performSelector:@selector(sharedInstance)];
        printf("session %d category %s mode %s\n", s != nil, [[s valueForKey:@"category"] UTF8String], [[s valueForKey:@"mode"] UTF8String]);
        id route = [s valueForKey:@"currentRoute"];
        printf("route inputs %lu outputs %lu input available %s\n", (unsigned long)[[route valueForKey:@"inputs"] count],
               (unsigned long)[[route valueForKey:@"outputs"] count], [[s valueForKey:@"inputAvailable"] description].UTF8String);
        NSError *e = nil;
        BOOL ok = ((BOOL(*)(id, SEL, id, id *))objc_msgSend)(s, @selector(setCategory:error:), @"AVAudioSessionCategoryPlayback", &e);
        printf("set category %d now %s\n", ok, [[s valueForKey:@"category"] UTF8String]);
        ok = ((BOOL(*)(id, SEL, id, id *))objc_msgSend)(s, @selector(setCategory:error:), @"Nonsense", &e);
        printf("set nonsense %d error %ld\n", ok, (long)e.code);
        ok = ((BOOL(*)(id, SEL, BOOL, id *))objc_msgSend)(s, @selector(setActive:error:), YES, &e);
        printf("activate %d rate %s\n", ok, [[s valueForKey:@"sampleRate"] description].UTF8String);

        AVAudioApplication *a = [AVAudioApplication sharedInstance];
        printf("application muted %d permission %ld\n", a.inputMuted, (long)a.recordPermission);
        e = nil;
        printf("mute without a handler %d error %ld\n", [a setInputMuted:YES error:&e], (long)e.code);
        [a setInputMuteStateChangeHandler:^BOOL(BOOL mute) {
          return YES;
        } error:nil];
        printf("mute with a handler %d now %d\n", [a setInputMuted:YES error:&e], a.inputMuted);
        [a setInputMuted:NO error:nil];
        __block int answered = 0;
        [[AVAudioRoutingArbiter sharedRoutingArbiter] beginArbitrationWithCategory:AVAudioRoutingArbitrationCategoryPlayback
                                                                 completionHandler:^(BOOL changed, NSError *error) {
                                                                   printf("arbitration changed %d error %ld\n", changed, (long)error.code);
                                                                   answered = 1;
                                                                 }];
        for (int i = 0; i < 50 && !answered; i++)
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
        [[AVAudioRoutingArbiter sharedRoutingArbiter] leaveArbitration];

        printf("voices %lu, for en-US %s\n", (unsigned long)[AVSpeechSynthesisVoice speechVoices].count,
               [AVSpeechSynthesisVoice voiceWithLanguage:@"en-US"] ? "some" : "none");
        AVSpeechUtterance *u = [AVSpeechUtterance speechUtteranceWithString:@"Hello there, world"];
        printf("utterance rate %g pitch %g volume %g\n", u.rate, u.pitchMultiplier, u.volume);
        u.rate = 5;
        u.pitchMultiplier = 9;
        u.volume = -1;
        printf("clamped rate %g pitch %g volume %g\n", u.rate, u.pitchMultiplier, u.volume);
        u.rate = AVSpeechUtteranceMaximumSpeechRate;
        AVSpeechUtterance *ssml = [AVSpeechUtterance speechUtteranceWithSSMLRepresentation:@"<speak>Fast &amp; <break/>clear</speak>"];
        printf("ssml: %s, not ssml %s\n", ssml.speechString.UTF8String, [AVSpeechUtterance speechUtteranceWithSSMLRepresentation:@"plain"] ? "some" : "nil");
        AVSpeechUtterance *copy = [[u copy] autorelease];
        printf("copy %s rate %g\n", copy.speechString.UTF8String, copy.rate);

        AVSpeechSynthesizer *synth = [[AVSpeechSynthesizer new] autorelease];
        Listener *l = [[Listener new] autorelease];
        l.events = [NSMutableArray array];
        synth.delegate = l;
        AVSpeechUtterance *second = [AVSpeechUtterance speechUtteranceWithString:@"Two words"];
        second.rate = AVSpeechUtteranceMaximumSpeechRate;
        [synth speakUtterance:u];
        [synth speakUtterance:second];
        printf("speaking %d paused %d\n", synth.speaking, synth.paused);
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 10, false);
        printf("events: %s\n", [l.events componentsJoinedByString:@" | "].UTF8String);
        printf("after: speaking %d\n", synth.speaking);
        [l.events removeAllObjects];
        AVSpeechUtterance *third = [AVSpeechUtterance speechUtteranceWithString:@"one two three four"];
        third.rate = AVSpeechUtteranceMaximumSpeechRate;
        [synth speakUtterance:third];
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
        printf("pause %d paused %d\n", [synth pauseSpeakingAtBoundary:AVSpeechBoundaryImmediate], synth.paused);
        printf("continue %d\n", [synth continueSpeaking]);
        printf("stop %d\n", [synth stopSpeakingAtBoundary:AVSpeechBoundaryImmediate]);
        printf("stop again %d continue %d\n", [synth stopSpeakingAtBoundary:AVSpeechBoundaryImmediate], [synth continueSpeaking]);
        printf("events: %s\n", [l.events componentsJoinedByString:@" | "].UTF8String);
    }
    return 0;
}
