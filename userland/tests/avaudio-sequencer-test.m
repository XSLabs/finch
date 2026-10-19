/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Compare MIDI editing and timing through AVAudioSequencer. */
#import <AVFAudio/AVAudioSequencer.h>
#import <AVFAudio/AVMusicEvents.h>
#import <Foundation/Foundation.h>

int
main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        AVAudioSequencer *sequencer = [[AVAudioSequencer alloc] init];
        [sequencer setUserCallback:^(AVMusicTrack *track, NSData *userData, AVMusicTimeStamp timeStamp) {
            (void)track; (void)userData; (void)timeStamp;
        }];
        [sequencer setUserCallback:nil];
        AVMusicTrack *track = [sequencer createAndAppendTrack];
        track.offsetTime = 1.5;
        track.muted = YES;
        track.soloed = YES;
        track.loopRange = AVMakeBeatRange(2, 4);
        track.loopingEnabled = YES;
        track.numberOfLoops = 3;
        AVMIDINoteEvent *note = [[AVMIDINoteEvent alloc] initWithChannel:2 key:60 velocity:98 duration:2];
        [track addEvent:note atBeat:4];
        puts("AVAudioSequencer MIDI editing");
        printf("user callback %d\n", [sequencer respondsToSelector:@selector(setUserCallback:)]);
        printf("new tracks %lu tempo %d resolution %lu time %.2f/%.2f\n",
               (unsigned long)sequencer.tracks.count, sequencer.tempoTrack != nil,
               (unsigned long)sequencer.tempoTrack.timeResolution,
               [sequencer secondsForBeats:4], [sequencer beatsForSeconds:2]);
        AVBeatRange loop = track.loopRange;
        printf("track %.2f %.2f %d/%d %d %ld %.2f\n", track.offsetTime, track.lengthInBeats,
               track.muted, track.soloed, track.loopingEnabled, (long)track.numberOfLoops,
               loop.start + loop.length);
        __block NSUInteger events = 0;
        [track enumerateEventsInRange:AVMakeBeatRange(0, AVMusicTimeStampEndOfTrack) usingBlock:
            ^(AVMusicEvent *event, AVMusicTimeStamp *time, BOOL *removeEvent) {
                events++;
                if ([event isKindOfClass:[AVMIDINoteEvent class]]) {
                    AVMIDINoteEvent *midi = (AVMIDINoteEvent *)event;
                    midi.key = 61;
                    *time = 5;
                }
            }];
        printf("events %lu length %.2f\n", (unsigned long)events, track.lengthInBeats);
        AVMusicTrack *copy = [sequencer createAndAppendTrack];
        [copy copyEventsInRange:AVMakeBeatRange(0, AVMusicTimeStampEndOfTrack) fromTrack:track insertAtBeat:0];
        printf("copied tracks %lu length %.2f\n", (unsigned long)sequencer.tracks.count, copy.lengthInBeats);
        NSError *error = nil;
        NSData *data = [sequencer dataWithSMPTEResolution:0 error:&error];
        AVAudioSequencer *loaded = [[AVAudioSequencer alloc] init];
        BOOL loadedOK = [loaded loadFromData:data options:AVMusicSequenceLoadSMF_PreserveTracks error:&error];
        printf("midi %d %lu %ld\n", loadedOK, (unsigned long)loaded.tracks.count, (long)error.code);
        BOOL removed = [sequencer removeTrack:copy];
        printf("removed %d tracks %lu retained %.2f\n", removed,
               (unsigned long)sequencer.tracks.count, copy.lengthInBeats);
    }
    return 0;
}
