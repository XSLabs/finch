/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Check track matching and empty chapter results on a movie without chapter tracks. */
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#include "avmovie.h"

static NSData *
frame(void)
{
    uint8_t bytes[16] = {0xFF, 0xD8, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 0xFF, 0xD9};
    return [NSData dataWithBytes:bytes length:sizeof(bytes)];
}

int
main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"avasset-compat-%d.mov", getpid()]];
        [build_movie_with_frames(@[frame(), frame(), frame(), frame(), frame(), frame()]) writeToFile:path atomically:YES];
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
        AVMutableComposition *composition = [AVMutableComposition composition];
        AVCompositionTrack *videoTarget = [composition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
        AVCompositionTrack *audioTarget = [composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
        AVAssetTrack *video = [asset compatibleTrackForCompositionTrack:videoTarget];
        AVAssetTrack *audio = [asset compatibleTrackForCompositionTrack:audioTarget];
        __block AVAssetTrackSegment *segment = nil;
        __block CMTime sampleTime = kCMTimeInvalid;
        __block NSArray *trackMetadata = nil;
        dispatch_semaphore_t trackDone = dispatch_semaphore_create(0);
        [video loadSegmentForTrackTime:CMTimeMake(1, 2) completionHandler:^(AVAssetTrackSegment *value, NSError *error) {
            segment = value;
            dispatch_semaphore_signal(trackDone);
        }];
        dispatch_semaphore_wait(trackDone, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
        dispatch_semaphore_t sampleDone = dispatch_semaphore_create(0);
        [video loadSamplePresentationTimeForTrackTime:CMTimeMake(1, 2) completionHandler:^(CMTime value, NSError *error) {
            sampleTime = value;
            dispatch_semaphore_signal(sampleDone);
        }];
        dispatch_semaphore_wait(sampleDone, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
        dispatch_semaphore_t metadataDone = dispatch_semaphore_create(0);
        [video loadMetadataForFormat:AVMetadataFormatQuickTimeUserData completionHandler:^(NSArray<AVMetadataItem *> *items, NSError *error) {
            trackMetadata = items;
            dispatch_semaphore_signal(metadataDone);
        }];
        dispatch_semaphore_wait(metadataDone, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
        __block AVAssetTrack *asyncVideo = nil;
        __block NSError *asyncError = nil;
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        [asset findCompatibleTrackForCompositionTrack:videoTarget completionHandler:^(AVAssetTrack *track, NSError *error) {
            asyncVideo = track;
            asyncError = error;
            dispatch_semaphore_signal(done);
        }];
        dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
        __block NSArray *chapterGroups = nil;
        __block NSError *chapterError = nil;
        dispatch_semaphore_t chaptersDone = dispatch_semaphore_create(0);
        [asset loadChapterMetadataGroupsBestMatchingPreferredLanguages:@[@"en"] completionHandler:^(NSArray<AVTimedMetadataGroup *> *groups, NSError *error) {
            chapterGroups = groups;
            chapterError = error;
            dispatch_semaphore_signal(chaptersDone);
        }];
        dispatch_semaphore_wait(chaptersDone, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
        puts("AVAsset track and chapter checks");
        printf("track match video %d/%s audio %d/%s async %d error %ld\n",
               video.trackID, video.mediaType.UTF8String, audio.trackID, audio.mediaType.UTF8String,
               asyncVideo == video, (long)asyncError.code);
        printf("chapters %lu error %ld\n", (unsigned long)chapterGroups.count, (long)chapterError.code);
        printf("track load segment %d empty %d duration %lld/%d sample %lld/%d metadata %lu\n",
               segment != nil, segment.empty, segment.timeMapping.target.duration.value,
               segment.timeMapping.target.duration.timescale, sampleTime.value, sampleTime.timescale,
               (unsigned long)trackMetadata.count);
        printf("associations %lu associated audio fallback %lu\n",
               (unsigned long)video.availableTrackAssociationTypes.count,
               (unsigned long)[video associatedTracksOfType:AVTrackAssociationTypeAudioFallback].count);
        __block CMPersistentTrackID unusedTrackID = kCMPersistentTrackID_Invalid;
        dispatch_semaphore_t unusedDone = dispatch_semaphore_create(0);
        [asset findUnusedTrackIDWithCompletionHandler:^(CMPersistentTrackID trackID, NSError *error) {
            unusedTrackID = error ? kCMPersistentTrackID_Invalid : trackID;
            dispatch_semaphore_signal(unusedDone);
        }];
        dispatch_semaphore_wait(unusedDone, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
        printf("unused track IDs asset %d async %d composition %d\n",
               asset.unusedTrackID, unusedTrackID, composition.unusedTrackID);
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    }
    return 0;
}
