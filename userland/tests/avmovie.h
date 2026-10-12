/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * A QuickTime movie written by hand, for the AVFoundation tests: 'jpeg' video frames
 * at 6 fps, a second of 16-bit stereo PCM, and user data (title, artist, date,
 * comment). Both Apple's AVFoundation and Finch's read the same bytes.
 */
#import <Foundation/Foundation.h>
#include <math.h>


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

/* A QuickTime movie: the frames as 'jpeg' samples at 6 fps (64x48), a second of
   16-bit stereo PCM at 44.1 kHz (a 440 Hz tone), and user data. */
static NSData *
build_movie_with_frames(NSArray<NSData *> *frames)
{
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
        be32(d, 1), be32(d, (uint32_t)frames.count), be32(d, 100);
    });
    NSData *vstsc = full("stsc", ^(NSMutableData *d) {
        be32(d, 1), be32(d, 1), be32(d, (uint32_t)frames.count), be32(d, 1);
    });
    NSData *vstsz = full("stsz", ^(NSMutableData *d) {
        be32(d, 0), be32(d, (uint32_t)frames.count);
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

