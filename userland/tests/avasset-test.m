/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * AVFoundation's assets: a QuickTime movie the test writes itself (six 'jpeg' frames at
 * 6 fps, a second of 16-bit stereo PCM, user-data metadata: title,
 * artist, date, comment), read as an AVURLAsset: duration, the movie's and the
 * tracks' properties, format descriptions, metadata in each key space, loading by key,
 * and errors for a missing file and for one that isn't a movie. Compared with Apple's.
 */
#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include "avmovie.h"

/* A frame's bytes: a JPEG's markers around fixed filler (the asset only reads sizes and
   places, so both systems read the same file). */
static NSData *
jpeg_frame(int i)
{
    NSMutableData *d = [NSMutableData dataWithLength:700 + (NSUInteger)i * 37];
    uint8_t *b = d.mutableBytes;
    for (NSUInteger k = 0; k < d.length; k++)
        b[k] = (uint8_t)(k * 31 + (NSUInteger)i);
    b[0] = 0xFF, b[1] = 0xD8, b[d.length - 2] = 0xFF, b[d.length - 1] = 0xD9;
    return d;
}

static NSData *
build_movie(void)
{
    NSMutableArray *frames = [NSMutableArray array];
    for (int i = 0; i < 6; i++)
        [frames addObject:jpeg_frame(i)];
    return build_movie_with_frames(frames);
}

#pragma mark - Reading it

static NSString *
time_string(CMTime t)
{
    if (CMTIME_IS_INVALID(t))
        return @"invalid";
    if (CMTIME_IS_INDEFINITE(t))
        return @"indefinite";
    return [NSString stringWithFormat:@"%lld/%d", t.value, t.timescale];
}

static NSString *
fourcc_string(FourCharCode c)
{
    char s[5] = {(char)(c >> 24), (char)(c >> 16), (char)(c >> 8), (char)c, 0};
    return @(s);
}

static void
print_item(AVMetadataItem *m)
{
    id v = m.value;
    NSString *vs = [v isKindOfClass:[NSData class]] ? [NSString stringWithFormat:@"%lu bytes", (unsigned long)[v length]]
                                                     : [v description];
    printf("    %s key %s keySpace %s common %s value %s (%s) dataType %s locale %s\n", m.identifier.UTF8String,
        [m.key description].UTF8String, m.keySpace.UTF8String, m.commonKey.UTF8String, vs.UTF8String,
        [v isKindOfClass:[NSString class]] ? "string" : [v isKindOfClass:[NSData class]] ? "data" : [v isKindOfClass:[NSNumber class]] ? "number" : "other", m.dataType.UTF8String, m.locale.localeIdentifier.UTF8String);
}

static void
wait_for(BOOL *done)
{
    for (int i = 0; i < 500 && !*done; i++)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}

int
main(void)
{
    @autoreleasepool {
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"avasset-%d", getpid()]];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL *url = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"test.mov"]];
        [build_movie() writeToURL:url atomically:YES];

        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{AVURLAssetPreferPreciseDurationAndTimingKey : @YES}];
        printf("asset: duration %s precise %d playable %d readable %d exportable %d composable %d compatible with AirPlay %d\n",
            time_string(asset.duration).UTF8String, asset.providesPreciseDurationAndTiming, asset.playable, asset.readable,
            asset.exportable, asset.composable, asset.compatibleWithAirPlayVideo);
        printf("  rate %.2f volume %.2f transform identity %d natural size %s creation %s lyrics %s\n", asset.preferredRate,
            asset.preferredVolume, CGAffineTransformIsIdentity(asset.preferredTransform),
            NSStringFromSize(asset.naturalSize).UTF8String, [asset.creationDate.value description].UTF8String,
            asset.lyrics.UTF8String);
        printf("  tracks %lu: video %lu audio %lu, track 2 is audio %d, track 9 %p\n", (unsigned long)asset.tracks.count,
            (unsigned long)[asset tracksWithMediaType:AVMediaTypeVideo].count,
            (unsigned long)[asset tracksWithMediaType:AVMediaTypeAudio].count,
            [[asset trackWithTrackID:2].mediaType isEqualToString:AVMediaTypeAudio], [asset trackWithTrackID:9]);
        printf("  visual tracks %lu, audible %lu, legible %lu\n",
            (unsigned long)[asset tracksWithMediaCharacteristic:AVMediaCharacteristicVisual].count,
            (unsigned long)[asset tracksWithMediaCharacteristic:AVMediaCharacteristicAudible].count,
            (unsigned long)[asset tracksWithMediaCharacteristic:AVMediaCharacteristicLegible].count);
        printf("  metadata formats: %s\n", [asset.availableMetadataFormats componentsJoinedByString:@" "].UTF8String);
        printf("  common metadata:\n");
        for (AVMetadataItem *m in asset.commonMetadata)
            print_item(m);
        printf("  user data:\n");
        for (AVMetadataItem *m in [asset metadataForFormat:AVMetadataFormatQuickTimeUserData])
            print_item(m);
        NSArray *titles = [AVMetadataItem metadataItemsFromArray:asset.commonMetadata withKey:AVMetadataCommonKeyTitle
                                                        keySpace:AVMetadataKeySpaceCommon];
        printf("  titles by common key: %lu %s\n", (unsigned long)titles.count, [[titles.firstObject stringValue] UTF8String]);
        NSArray *byID = [AVMetadataItem metadataItemsFromArray:asset.metadata
                                              filteredByIdentifier:AVMetadataIdentifierQuickTimeUserDataArtist];
        printf("  artists by identifier: %lu\n", (unsigned long)byID.count);

        for (AVAssetTrack *t in asset.tracks) {
            printf("track %d %s: enabled %d playable %d self-contained %d decodable %d\n", t.trackID, t.mediaType.UTF8String,
                t.enabled, t.playable, t.selfContained, t.decodable);
            printf("  time range %s+%s natural size %s frame rate %.2f data rate %.0f sample data %lld timescale %d\n",
                time_string(t.timeRange.start).UTF8String, time_string(t.timeRange.duration).UTF8String,
                NSStringFromSize(t.naturalSize).UTF8String, t.nominalFrameRate, t.estimatedDataRate,
                t.totalSampleDataLength, t.naturalTimeScale);
            printf("  min frame duration %s language %s extended %s volume %.2f transform identity %d segments %lu\n",
                time_string(t.minFrameDuration).UTF8String, t.languageCode.UTF8String, t.extendedLanguageTag.UTF8String,
                t.preferredVolume, CGAffineTransformIsIdentity(t.preferredTransform), (unsigned long)t.segments.count);
            printf("  characteristics: visual %d audible %d frame based %d\n", [t hasMediaCharacteristic:AVMediaCharacteristicVisual],
                [t hasMediaCharacteristic:AVMediaCharacteristicAudible],
                [t hasMediaCharacteristic:AVMediaCharacteristicFrameBased]);
            for (id f in t.formatDescriptions) {
                CMFormatDescriptionRef fd = (__bridge CMFormatDescriptionRef)f;
                printf("  format %s/%s", fourcc_string(CMFormatDescriptionGetMediaType(fd)).UTF8String,
                    fourcc_string(CMFormatDescriptionGetMediaSubType(fd)).UTF8String);
                if (CMFormatDescriptionGetMediaType(fd) == kCMMediaType_Video) {
                    CMVideoDimensions dim = CMVideoFormatDescriptionGetDimensions(fd);
                    printf(" %dx%d", dim.width, dim.height);
                } else {
                    const AudioStreamBasicDescription *a = CMAudioFormatDescriptionGetStreamBasicDescription(fd);
                    if (a)
                        printf(" %.0f Hz %u ch %u bits flags %u bytes/frame %u", a->mSampleRate, a->mChannelsPerFrame,
                            a->mBitsPerChannel, a->mFormatFlags, a->mBytesPerFrame);
                }
                printf("\n");
            }
            AVAssetTrackSegment *seg = t.segments.firstObject;
            printf("  segment: empty %d source %s target %s\n", seg.empty, time_string(seg.timeMapping.source.duration).UTF8String,
                time_string(seg.timeMapping.target.duration).UTF8String);
            printf("  track metadata %lu, formats %s\n", (unsigned long)t.metadata.count,
                [t.availableMetadataFormats componentsJoinedByString:@" "].UTF8String);
        }

        /* loading by key */
        AVURLAsset *fresh = [AVURLAsset URLAssetWithURL:url options:nil];
        NSError *err = nil;
        printf("before loading: duration %ld\n", (long)[fresh statusOfValueForKey:@"duration" error:&err]);
        __block BOOL done = NO;
        [fresh loadValuesAsynchronouslyForKeys:@[ @"duration", @"tracks", @"bogusKey" ] completionHandler:^{
            done = YES;
        }];
        wait_for(&done);
        NSError *e1 = nil, *e2 = nil;
        AVKeyValueStatus s1 = [fresh statusOfValueForKey:@"tracks" error:&e1];
        AVKeyValueStatus s2 = [fresh statusOfValueForKey:@"bogusKey" error:&e2];
        printf("after loading: tracks %ld, bogus %ld (%s %ld)\n", (long)s1, (long)s2, e2.domain.UTF8String, (long)e2.code);

        /* missing and not a movie */
        AVURLAsset *missing = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:@"/nonexistent/x.mov"] options:nil];
        done = NO;
        [missing loadValuesAsynchronouslyForKeys:@[ @"tracks" ] completionHandler:^{
            done = YES;
        }];
        wait_for(&done);
        NSError *me = nil;
        AVKeyValueStatus ms = [missing statusOfValueForKey:@"tracks" error:&me];
        printf("missing: status %ld domain %s code %ld tracks %lu playable %d\n", (long)ms, me.domain.UTF8String, (long)me.code,
            (unsigned long)missing.tracks.count, missing.playable);
        NSURL *junk = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"junk.mov"]];
        [[@"this is not a movie at all" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:junk atomically:YES];
        AVURLAsset *bad = [AVURLAsset URLAssetWithURL:junk options:nil];
        done = NO;
        [bad loadValuesAsynchronouslyForKeys:@[ @"tracks" ] completionHandler:^{
            done = YES;
        }];
        wait_for(&done);
        NSError *be = nil;
        AVKeyValueStatus bs = [bad statusOfValueForKey:@"tracks" error:&be];
        printf("not a movie: status %ld domain %s code %ld\n", (long)bs, be.domain.UTF8String, (long)be.code);

        printf("types: %lu audiovisual, mov %d mp4 %d m4a %d jpeg %d\n", (unsigned long)[AVURLAsset audiovisualTypes].count,
            [AVURLAsset isPlayableExtendedMIMEType:@"video/quicktime"], [AVURLAsset isPlayableExtendedMIMEType:@"video/mp4"],
            [AVURLAsset isPlayableExtendedMIMEType:@"audio/mp4"], [AVURLAsset isPlayableExtendedMIMEType:@"image/jpeg"]);
        CGRect fit = AVMakeRectWithAspectRatioInsideRect(CGSizeMake(16, 9), CGRectMake(10, 20, 100, 100));
        printf("aspect fit: %s\n", NSStringFromRect(fit).UTF8String);
        [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
    }
    return 0;
}
