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

#pragma mark - Writing a movie

static void
be32(NSMutableData *d, uint32_t v)
{
    uint8_t b[4] = {(uint8_t)(v >> 24), (uint8_t)(v >> 16), (uint8_t)(v >> 8), (uint8_t)v};
    [d appendBytes:b length:4];
}

static void
be16(NSMutableData *d, uint16_t v)
{
    uint8_t b[2] = {(uint8_t)(v >> 8), (uint8_t)v};
    [d appendBytes:b length:2];
}

static void
be64(NSMutableData *d, uint64_t v)
{
    be32(d, (uint32_t)(v >> 32));
    be32(d, (uint32_t)v);
}

static void
fourcc(NSMutableData *d, const char *s)
{
    [d appendBytes:s length:4];
}

static void
zeros(NSMutableData *d, NSUInteger n)
{
    [d increaseLengthBy:n];
}

/* A box: its size, type and body. */
static NSData *
box(const char *type, NSData *body)
{
    NSMutableData *d = [NSMutableData data];
    be32(d, (uint32_t)(8 + body.length));
    fourcc(d, type);
    [d appendData:body];
    return d;
}

static NSData *
boxes(const char *type, NSArray<NSData *> *children)
{
    NSMutableData *body = [NSMutableData data];
    for (NSData *c in children)
        [body appendData:c];
    return box(type, body);
}

static void
matrix(NSMutableData *d)
{
    uint32_t m[9] = {0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x40000000};
    for (int i = 0; i < 9; i++)
        be32(d, m[i]);
}

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

/* QuickTime's user-data text: length, language, then the text. */
static NSData *
udta_text(const char *type, NSString *text)
{
    NSData *utf8 = [text dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *body = [NSMutableData data];
    be16(body, (uint16_t)utf8.length);
    be16(body, 0); /* (English, Macintosh language code) */
    [body appendData:utf8];
    return box(type, body);
}

static NSData *
mvhd(uint32_t timescale, uint32_t duration, uint32_t nextTrack)
{
    NSMutableData *d = [NSMutableData data];
    be32(d, 0);                  /* version, flags */
    be32(d, 3600), be32(d, 3600); /* creation, modification */
    be32(d, timescale), be32(d, duration);
    be32(d, 0x10000);            /* rate */
    be16(d, 0x100);              /* volume */
    zeros(d, 10);
    matrix(d);
    zeros(d, 24);                /* preview, poster, selection, current time */
    be32(d, nextTrack);
    return box("mvhd", d);
}

static NSData *
tkhd(uint32_t trackID, uint32_t duration, uint16_t volume, uint32_t width, uint32_t height)
{
    NSMutableData *d = [NSMutableData data];
    be32(d, 0xF);                /* enabled, in movie, in preview, in poster */
    be32(d, 3600), be32(d, 3600);
    be32(d, trackID);
    be32(d, 0);
    be32(d, duration);
    zeros(d, 8);
    be16(d, 0), be16(d, 0);      /* layer, alternate group */
    be16(d, volume);
    be16(d, 0);
    matrix(d);
    be32(d, width << 16), be32(d, height << 16);
    return box("tkhd", d);
}

static NSData *
mdhd(uint32_t timescale, uint32_t duration)
{
    NSMutableData *d = [NSMutableData data];
    be32(d, 0);
    be32(d, 3600), be32(d, 3600);
    be32(d, timescale), be32(d, duration);
    be16(d, 0x55c4);             /* 'und' */
    be16(d, 0);
    return box("mdhd", d);
}

static NSData *
hdlr(const char *component, const char *subtype, NSString *name)
{
    NSMutableData *d = [NSMutableData data];
    be32(d, 0);
    fourcc(d, component);
    fourcc(d, subtype);
    zeros(d, 12);
    NSData *n = [name dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t len = (uint8_t)n.length;
    [d appendBytes:&len length:1];
    [d appendData:n];
    return box("hdlr", d);
}

static NSData *
dinf(void)
{
    NSMutableData *alis = [NSMutableData data];
    be32(alis, 1); /* self-contained */
    NSMutableData *dref = [NSMutableData data];
    be32(dref, 0), be32(dref, 1);
    [dref appendData:box("alis", alis)];
    return boxes("dinf", @[ box("dref", dref) ]);
}

static NSData *
full(const char *type, void (^fill)(NSMutableData *))
{
    NSMutableData *d = [NSMutableData data];
    be32(d, 0);
    fill(d);
    return box(type, d);
}

static NSData *
build_movie(void)
{
    NSMutableArray *frames = [NSMutableArray array];
    for (int i = 0; i < 6; i++)
        [frames addObject:jpeg_frame(i)];
    NSMutableData *audio = [NSMutableData data];
    for (int i = 0; i < 44100; i++) {
        int16_t s = (int16_t)(sin(i * 2 * M_PI * 440 / 44100) * 8000);
        [audio appendBytes:&s length:2];
        [audio appendBytes:&s length:2];
    }
    NSMutableData *ftypBody = [NSMutableData data];
    fourcc(ftypBody, "qt  ");
    be32(ftypBody, 0x200);
    fourcc(ftypBody, "qt  ");
    NSData *ftyp = box("ftyp", ftypBody);
    /* mdat: the frames, then the audio */
    NSMutableData *mdatBody = [NSMutableData data];
    for (NSData *f in frames)
        [mdatBody appendData:f];
    NSUInteger audioAt = mdatBody.length;
    [mdatBody appendData:audio];
    uint32_t videoOffset = (uint32_t)(ftyp.length + 8), audioOffset = (uint32_t)(ftyp.length + 8 + audioAt);

    /* the video track */
    NSMutableData *jpeg = [NSMutableData data];
    zeros(jpeg, 6), be16(jpeg, 1);
    be16(jpeg, 0), be16(jpeg, 0);
    fourcc(jpeg, "appl");
    be32(jpeg, 0), be32(jpeg, 512);
    be16(jpeg, 64), be16(jpeg, 48);
    be32(jpeg, 72 << 16), be32(jpeg, 72 << 16);
    be32(jpeg, 0), be16(jpeg, 1);
    uint8_t name[32] = {12, 'P', 'h', 'o', 't', 'o', ' ', '-', ' ', 'J', 'P', 'E', 'G'};
    [jpeg appendBytes:name length:32];
    be16(jpeg, 24), be16(jpeg, 0xFFFF);
    NSData *vstsd = full("stsd", ^(NSMutableData *d) {
        be32(d, 1);
        [d appendData:box("jpeg", jpeg)];
    });
    NSData *vstts = full("stts", ^(NSMutableData *d) {
        be32(d, 1), be32(d, 6), be32(d, 100);
    });
    NSData *vstsc = full("stsc", ^(NSMutableData *d) {
        be32(d, 1), be32(d, 1), be32(d, 6), be32(d, 1);
    });
    NSData *vstsz = full("stsz", ^(NSMutableData *d) {
        be32(d, 0), be32(d, 6);
        for (NSData *f in frames)
            be32(d, (uint32_t)f.length);
    });
    NSData *vstco = full("stco", ^(NSMutableData *d) {
        be32(d, 1), be32(d, videoOffset);
    });
    NSData *vmhd = box("vmhd", ({
                           NSMutableData *d = [NSMutableData data];
                           be32(d, 1), be16(d, 0x40), zeros(d, 6);
                           d;
                       }));
    NSData *vtrak = boxes("trak", @[
        tkhd(1, 600, 0, 64, 48),
        boxes("mdia", @[
            mdhd(600, 600), hdlr("mhlr", "vide", @"Video Handler"),
            boxes("minf", @[ vmhd, hdlr("dhlr", "alis", @"Data Handler"), dinf(),
                             boxes("stbl", @[ vstsd, vstts, vstsc, vstsz, vstco ]) ])
        ])
    ]);

    /* the audio track: a version 2 sound description of 16-bit little-endian PCM */
    NSMutableData *lpcm = [NSMutableData data];
    zeros(lpcm, 6), be16(lpcm, 1);
    be16(lpcm, 2), be16(lpcm, 0), be32(lpcm, 0);
    be16(lpcm, 3), be16(lpcm, 16), be16(lpcm, 0xFFFE), be16(lpcm, 0);
    be32(lpcm, 0x10000);
    be32(lpcm, 72);
    double rate = 44100;
    uint64_t rateBits;
    memcpy(&rateBits, &rate, 8);
    be64(lpcm, rateBits);
    be32(lpcm, 2);
    be32(lpcm, 0x7F000000);
    be32(lpcm, 16);
    be32(lpcm, 12); /* signed integer, packed (little-endian) */
    be32(lpcm, 4);
    be32(lpcm, 1);
    NSData *astsd = full("stsd", ^(NSMutableData *d) {
        be32(d, 1);
        [d appendData:box("lpcm", lpcm)];
    });
    NSData *astts = full("stts", ^(NSMutableData *d) {
        be32(d, 1), be32(d, 44100), be32(d, 1);
    });
    NSData *astsc = full("stsc", ^(NSMutableData *d) {
        be32(d, 1), be32(d, 1), be32(d, 44100), be32(d, 1);
    });
    NSData *astsz = full("stsz", ^(NSMutableData *d) {
        be32(d, 4), be32(d, 44100);
    });
    NSData *astco = full("stco", ^(NSMutableData *d) {
        be32(d, 1), be32(d, audioOffset);
    });
    NSData *smhd = full("smhd", ^(NSMutableData *d) {
        be32(d, 0);
    });
    NSData *atrak = boxes("trak", @[
        tkhd(2, 600, 0x100, 0, 0),
        boxes("mdia", @[
            mdhd(44100, 44100), hdlr("mhlr", "soun", @"Sound Handler"),
            boxes("minf", @[ smhd, hdlr("dhlr", "alis", @"Data Handler"), dinf(),
                             boxes("stbl", @[ astsd, astts, astsc, astsz, astco ]) ])
        ])
    ]);
    NSData *udta = boxes("udta", @[
        udta_text("\xa9nam", @"Finch Test Movie"), udta_text("\xa9" "ART", @"The Finch Project"),
        udta_text("\xa9" "day", @"2001-02-03T04:05:06Z"), udta_text("\xa9" "cmt", @"Six frames and a tone")
    ]);
    NSData *moov = boxes("moov", @[ mvhd(600, 600, 3), vtrak, atrak, udta ]);
    NSMutableData *file = [NSMutableData dataWithData:ftyp];
    [file appendData:box("mdat", mdatBody)];
    [file appendData:moov];
    return file;
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
