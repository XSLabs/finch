/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Finch's QuickTime and ISO base media file reader. Boxes (atoms) are read from the
 * file's bytes as ISO/IEC 14496-12 and Apple's QuickTime File Format describe them:
 * 'ftyp', 'moov' with 'mvhd', each 'trak' ('tkhd', 'edts'/'elst', 'mdia' with 'mdhd',
 * 'hdlr' and the sample table: 'stsd', 'stts', 'ctts', 'stss', 'stsc', 'stsz'/'stz2',
 * 'stco'/'co64'), 'udta' and 'meta' ('keys' and 'ilst', in QuickTime's and iTunes'
 * forms). Sample descriptions become CoreMedia format descriptions; QuickTime's legacy
 * constant-bit-rate audio tables (a "sample" per frame) are read as frames of the
 * description's size. Sizes of 1 (64-bit) and 0 (to the end) are honoured; anything
 * malformed ends the box it's in.
 */
#import "AVFMovie.h"
#include <AudioToolbox/AudioToolbox.h>

@implementation AVFMetadataEntry
@end

@implementation AVFTrack
- (void)dealloc
{
    free(samples);
    free(edits);
}
@end

#pragma mark - Reading boxes

typedef struct {
    const uint8_t *p;
    size_t n;
} Span;

static uint32_t
be16(const uint8_t *p)
{
    return (uint32_t)p[0] << 8 | p[1];
}

static uint32_t
be32(const uint8_t *p)
{
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

static uint64_t
be64(const uint8_t *p)
{
    return (uint64_t)be32(p) << 32 | be32(p + 4);
}

static double
fixed1616(uint32_t v)
{
    return (int32_t)v / 65536.0;
}

static double
fixed0230(uint32_t v)
{
    return (int32_t)v / 1073741824.0;
}

/* The next box in span: its type and body; false at the end or on a malformed box. */
static bool
next_box(Span *s, uint32_t *type, Span *body)
{
    if (s->n < 8)
        return false;
    uint64_t size = be32(s->p);
    *type = be32(s->p + 4);
    size_t header = 8;
    if (size == 1) {
        if (s->n < 16)
            return false;
        size = be64(s->p + 8);
        header = 16;
    } else if (size == 0) {
        size = s->n;
    }
    if (size < header || size > s->n)
        return false;
    body->p = s->p + header;
    body->n = (size_t)size - header;
    s->p += size;
    s->n -= (size_t)size;
    return true;
}

static bool
find_box(Span s, uint32_t want, Span *out)
{
    uint32_t type;
    Span body;
    while (next_box(&s, &type, &body))
        if (type == want) {
            *out = body;
            return true;
        }
    return false;
}

static CGAffineTransform
read_matrix(const uint8_t *m)
{
    return CGAffineTransformMake(fixed1616(be32(m)), fixed1616(be32(m + 4)), fixed1616(be32(m + 12)), fixed1616(be32(m + 16)),
                                 fixed1616(be32(m + 24)), fixed1616(be32(m + 28)));
}

/* Macintosh language codes, as QuickTime's user data and old 'mdhd's give them. */
static NSString *
mac_language(uint32_t code)
{
    static NSString *const names[] = {@"en", @"fr", @"de", @"it", @"nl", @"sv", @"es", @"da", @"pt", @"no", @"he",
                                      @"ja", @"ar", @"fi", @"el", @"is", @"mt", @"tr", @"hr", @"zh-Hant", @"ur", @"hi",
                                      @"th", @"ko", @"lt", @"pl", @"hu", @"et", @"lv", @"se", @"fo", @"fa", @"ru",
                                      @"zh-Hans", @"nl-BE", @"ga", @"sq", @"ro", @"cs", @"sk", @"sl"};
    return code < sizeof names / sizeof names[0] ? names[code] : nil;
}

/* An 'mdhd' language: packed ISO 639-2/T letters, or a Macintosh code below 0x400. */
static NSString *
packed_language(uint32_t v)
{
    if (v < 0x400) {
        static NSString *const iso[] = {@"eng", @"fra", @"deu", @"ita", @"nld", @"swe", @"spa", @"dan", @"por", @"nor", @"heb", @"jpn"};
        return v < sizeof iso / sizeof iso[0] ? iso[v] : @"und";
    }
    char s[4] = {(char)(((v >> 10) & 0x1F) + 0x60), (char)(((v >> 5) & 0x1F) + 0x60), (char)((v & 0x1F) + 0x60), 0};
    return @(s);
}

NSString *
AVFKeyString(FourCharCode key)
{
    NSMutableString *s = [NSMutableString string];
    for (int i = 3; i >= 0; i--) {
        uint8_t c = (uint8_t)(key >> (i * 8));
        if (c >= 0x21 && c < 0x7F && c != '%' && c != '/')
            [s appendFormat:@"%c", c];
        else
            [s appendFormat:@"%%%02X", c];
    }
    return s;
}

#pragma mark - User data and metadata

static void
read_udta(Span s, NSMutableArray<AVFMetadataEntry *> *out)
{
    uint32_t type;
    Span body;
    while (next_box(&s, &type, &body)) {
        if (type == 'meta')
            continue;
        if ((type >> 24) == 0xA9) {
            /* international text: length, language, then the text, perhaps more than once */
            Span t = body;
            while (t.n >= 4) {
                uint32_t len = be16(t.p), lang = be16(t.p + 2);
                if (4 + len > t.n)
                    break;
                AVFMetadataEntry *e = [AVFMetadataEntry new];
                e->keySpace = @"udta";
                e->key = @((int32_t)type);
                e->value = [[NSString alloc] initWithBytes:t.p + 4 length:len encoding:NSUTF8StringEncoding]
                               ?: [[NSString alloc] initWithBytes:t.p + 4 length:len encoding:NSMacOSRomanStringEncoding];
                e->language = mac_language(lang);
                [out addObject:e];
                t.p += 4 + len;
                t.n -= 4 + len;
            }
        } else if (type != 'free' && type != 'skip' && type != 'hnti' && type != 'hinf') {
            AVFMetadataEntry *e = [AVFMetadataEntry new];
            e->keySpace = @"udta";
            e->key = @((int32_t)type);
            e->value = [NSData dataWithBytes:body.p length:body.n];
            [out addObject:e];
        }
    }
}

/* A 'data' box's value, by its well-known type. */
static id
data_value(Span d, NSString **dataType, NSString **language)
{
    if (d.n < 8)
        return nil;
    uint32_t wellKnown = be32(d.p) & 0xFFFFFF;
    uint32_t locale = be32(d.p + 4);
    const uint8_t *v = d.p + 8;
    size_t n = d.n - 8;
    if (locale && language) {
        uint32_t country = locale & 0xFFFF;
        (void)country;
    }
    switch (wellKnown) {
    case 1:
        *dataType = (__bridge NSString *)kCMMetadataBaseDataType_UTF8;
        return [[NSString alloc] initWithBytes:v length:n encoding:NSUTF8StringEncoding];
    case 2:
        *dataType = (__bridge NSString *)kCMMetadataBaseDataType_UTF16;
        return [[NSString alloc] initWithBytes:v length:n encoding:NSUTF16BigEndianStringEncoding];
    case 13:
        *dataType = (__bridge NSString *)kCMMetadataBaseDataType_JPEG;
        return [NSData dataWithBytes:v length:n];
    case 14:
        *dataType = (__bridge NSString *)kCMMetadataBaseDataType_PNG;
        return [NSData dataWithBytes:v length:n];
    case 21:
    case 22: {
        *dataType = (__bridge NSString *)(wellKnown == 21 ? kCMMetadataBaseDataType_SInt8 : kCMMetadataBaseDataType_UInt8);
        int64_t x = 0;
        for (size_t i = 0; i < n && i < 8; i++)
            x = x << 8 | v[i];
        if (wellKnown == 21 && n && n < 8 && (v[0] & 0x80))
            x -= (int64_t)1 << (n * 8);
        if (wellKnown == 21) {
            CFStringRef types[] = {kCMMetadataBaseDataType_SInt8, kCMMetadataBaseDataType_SInt16,
                                   kCMMetadataBaseDataType_SInt32, kCMMetadataBaseDataType_SInt64};
            *dataType = (__bridge NSString *)types[n <= 1 ? 0 : n <= 2 ? 1 : n <= 4 ? 2 : 3];
        } else {
            CFStringRef types[] = {kCMMetadataBaseDataType_UInt8, kCMMetadataBaseDataType_UInt16,
                                   kCMMetadataBaseDataType_UInt32, kCMMetadataBaseDataType_UInt64};
            *dataType = (__bridge NSString *)types[n <= 1 ? 0 : n <= 2 ? 1 : n <= 4 ? 2 : 3];
        }
        return @(x);
    }
    case 23:
        if (n >= 4) {
            uint32_t b = be32(v);
            float f;
            memcpy(&f, &b, 4);
            *dataType = (__bridge NSString *)kCMMetadataBaseDataType_Float32;
            return @(f);
        }
        return nil;
    case 24:
        if (n >= 8) {
            uint64_t b = be64(v);
            double f;
            memcpy(&f, &b, 8);
            *dataType = (__bridge NSString *)kCMMetadataBaseDataType_Float64;
            return @(f);
        }
        return nil;
    default:
        *dataType = (__bridge NSString *)kCMMetadataBaseDataType_RawData;
        return [NSData dataWithBytes:v length:n];
    }
}

/* 'meta': QuickTime's ('keys' and 'ilst' by key index, key space "mdta") or iTunes'
   ('ilst' by four-character code, key space "itsk"). ISO's has a version and flags. */
static void
read_meta(Span m, NSMutableArray<AVFMetadataEntry *> *out)
{
    Span probe;
    if (m.n >= 12 && !find_box(m, 'hdlr', &probe) && be32(m.p) == 0) {
        m.p += 4;
        m.n -= 4;
    }
    Span hdlr, keysBox, ilst;
    uint32_t handler = find_box(m, 'hdlr', &hdlr) && hdlr.n >= 12 ? be32(hdlr.p + 8) : 0;
    NSMutableArray *keys = [NSMutableArray array];
    if (find_box(m, 'keys', &keysBox) && keysBox.n >= 8) {
        uint32_t count = be32(keysBox.p + 4);
        Span s = {keysBox.p + 8, keysBox.n - 8};
        for (uint32_t i = 0; i < count; i++) {
            uint32_t ns;
            Span k;
            if (!next_box(&s, &ns, &k))
                break;
            [keys addObject:[[NSString alloc] initWithBytes:k.p length:k.n encoding:NSUTF8StringEncoding] ?: @""];
        }
    }
    if (!find_box(m, 'ilst', &ilst))
        return;
    uint32_t type;
    Span item;
    while (next_box(&ilst, &type, &item)) {
        Span d = item, data;
        uint32_t dt;
        while (next_box(&d, &dt, &data)) {
            if (dt != 'data')
                continue;
            AVFMetadataEntry *e = [AVFMetadataEntry new];
            NSString *dataType = nil, *language = nil;
            e->value = data_value(data, &dataType, &language);
            e->dataType = dataType;
            if (handler == 'mdta' && type >= 1 && type <= keys.count) {
                e->keySpace = @"mdta";
                e->key = keys[type - 1];
            } else {
                e->keySpace = @"itsk";
                e->key = @((int32_t)type);
            }
            if (e->value)
                [out addObject:e];
        }
    }
}

#pragma mark - Tracks

static NSError *
not_a_movie(void)
{
    return [NSError errorWithDomain:NSOSStatusErrorDomain code:-12848 userInfo:nil];
}

/* The samples, from the sample table's boxes. */
static void
read_sample_table(AVFTrack *t, Span stbl, bool quickTime)
{
    Span stsd, stts, ctts, stss, stsc, stsz, stco;
    bool haveCo64 = false;
    if (find_box(stbl, 'stsd', &stsd) && stsd.n >= 8) {
        uint32_t count = be32(stsd.p + 4);
        Span s = {stsd.p + 8, stsd.n - 8};
        for (uint32_t i = 0; i < count && s.n >= 8; i++) {
            size_t size = be32(s.p);
            if (size < 8 || size > s.n)
                break;
            FourCharCode codec = be32(s.p + 4);
            CMFormatDescriptionRef fd = NULL;
            if (t->handler == 'vide') {
                CMVideoFormatDescriptionCreateFromBigEndianImageDescriptionData(
                    NULL, s.p, size, kCFStringEncodingUTF8, quickTime ? NULL : kCMImageDescriptionFlavor_ISOFamily, &fd);
            } else if (t->handler == 'soun') {
                CMAudioFormatDescriptionCreateFromBigEndianSoundDescriptionData(
                    NULL, s.p, size, quickTime ? NULL : kCMSoundDescriptionFlavor_ISOFamily, &fd);
            }
            if (!fd) {
                CMMediaType mt = t->handler == 'vide' ? kCMMediaType_Video
                                 : t->handler == 'soun' ? kCMMediaType_Audio
                                 : t->handler == 'tmcd' ? kCMMediaType_TimeCode
                                 : t->handler == 'sbtl' ? kCMMediaType_Subtitle
                                 : t->handler == 'clcp' ? kCMMediaType_ClosedCaption
                                 : t->handler == 'meta' ? kCMMediaType_Metadata
                                 : t->handler == 'text' ? kCMMediaType_Text
                                                        : t->handler;
                CMFormatDescriptionCreate(NULL, mt, codec, NULL, &fd);
            }
            if (fd) {
                [t->formatDescriptions addObject:(__bridge id)fd];
                CFRelease(fd);
            }
            s.p += size;
            s.n -= size;
        }
    }
    if (!find_box(stbl, 'stsz', &stsz) && !find_box(stbl, 'stz2', &stsz))
        return;
    if (!find_box(stbl, 'stco', &stco)) {
        if (!find_box(stbl, 'co64', &stco))
            return;
        haveCo64 = true;
    }
    if (!find_box(stbl, 'stsc', &stsc) || !find_box(stbl, 'stts', &stts))
        return;
    bool compact = false;
    Span tmp;
    if (!find_box(stbl, 'stsz', &tmp))
        compact = true;
    if (stsz.n < 12)
        return;
    uint32_t uniform = compact ? 0 : be32(stsz.p + 4);
    uint32_t fieldSize = compact ? stsz.p[7] : 32;
    size_t count = be32(stsz.p + 8);
    if (!uniform && count * (fieldSize / 8.0) > stsz.n - 12)
        return;
    /* QuickTime's legacy audio tables count frames, each "sample" a frame */
    uint32_t legacyBytes = 0;
    if (t->handler == 'soun' && quickTime && [t->formatDescriptions count] && uniform == 1) {
        CMAudioFormatDescriptionRef fd = (__bridge CMAudioFormatDescriptionRef)t->formatDescriptions[0];
        const AudioStreamBasicDescription *a = CMAudioFormatDescriptionGetStreamBasicDescription(fd);
        if (a && a->mBytesPerFrame)
            legacyBytes = a->mBytesPerFrame;
    }
    t->samples = calloc(count ? count : 1, sizeof(AVFSample));
    t->sampleCount = count;
    for (size_t i = 0; i < count; i++) {
        uint32_t size = uniform;
        if (!uniform) {
            if (fieldSize == 32)
                size = be32(stsz.p + 12 + i * 4);
            else if (fieldSize == 16)
                size = be16(stsz.p + 12 + i * 2);
            else if (fieldSize == 8)
                size = stsz.p[12 + i];
            else
                size = (stsz.p[12 + i / 2] >> (i % 2 ? 0 : 4)) & 0xF;
        }
        if (legacyBytes)
            size = legacyBytes;
        t->samples[i].size = size;
        t->samples[i].sync = true;
        t->totalBytes += size;
    }
    /* chunks: where each sample is */
    uint32_t chunks = stco.n >= 8 ? be32(stco.p + 4) : 0;
    uint32_t entries = stsc.n >= 8 ? be32(stsc.p + 4) : 0;
    size_t sample = 0;
    for (uint32_t e = 0; e < entries && sample < count; e++) {
        const uint8_t *row = stsc.p + 8 + e * 12;
        if ((size_t)(row - stsc.p) + 12 > stsc.n)
            break;
        uint32_t first = be32(row), perChunk = be32(row + 4), desc = be32(row + 8);
        uint32_t last = e + 1 < entries && (size_t)(row + 12 - stsc.p) + 12 <= stsc.n ? be32(row + 12) - 1 : chunks;
        for (uint32_t c = first; c <= last && c >= 1 && c <= chunks && sample < count; c++) {
            uint64_t offset = haveCo64 ? be64(stco.p + 8 + (c - 1) * 8) : be32(stco.p + 8 + (c - 1) * 4);
            for (uint32_t k = 0; k < perChunk && sample < count; k++, sample++) {
                t->samples[sample].offset = offset;
                t->samples[sample].description = desc ? desc - 1 : 0;
                offset += t->samples[sample].size;
            }
        }
    }
    /* times */
    uint32_t sttsCount = stts.n >= 8 ? be32(stts.p + 4) : 0;
    int64_t dts = 0;
    sample = 0;
    for (uint32_t e = 0; e < sttsCount && sample < count && 8 + (e + 1) * 8 <= stts.n; e++) {
        uint32_t n = be32(stts.p + 8 + e * 8), delta = be32(stts.p + 12 + e * 8);
        for (uint32_t k = 0; k < n && sample < count; k++, sample++) {
            t->samples[sample].decodeTime = dts;
            t->samples[sample].duration = delta;
            dts += delta;
        }
    }
    if (find_box(stbl, 'ctts', &ctts) && ctts.n >= 8) {
        uint32_t n = be32(ctts.p + 4);
        sample = 0;
        for (uint32_t e = 0; e < n && sample < count && 8 + (e + 1) * 8 <= ctts.n; e++) {
            uint32_t c = be32(ctts.p + 8 + e * 8);
            int32_t off = (int32_t)be32(ctts.p + 12 + e * 8);
            for (uint32_t k = 0; k < c && sample < count; k++, sample++)
                t->samples[sample].compositionOffset = off;
        }
    }
    if (find_box(stbl, 'stss', &stss) && stss.n >= 8) {
        for (size_t i = 0; i < count; i++)
            t->samples[i].sync = false;
        uint32_t n = be32(stss.p + 4);
        for (uint32_t e = 0; e < n && 8 + (e + 1) * 4 <= stss.n; e++) {
            uint32_t s = be32(stss.p + 8 + e * 4);
            if (s >= 1 && s <= count)
                t->samples[s - 1].sync = true;
        }
    }
}

static AVFTrack *
read_track(Span trak, bool quickTime)
{
    AVFTrack *t = [AVFTrack new];
    t->formatDescriptions = [NSMutableArray array];
    t->userData = [NSMutableArray array];
    t->matrix = CGAffineTransformIdentity;
    t->language = @"und";
    t->selfContained = YES;
    Span tkhd, mdia, edts, udta;
    if (find_box(trak, 'tkhd', &tkhd) && tkhd.n >= 84) {
        uint32_t version = tkhd.p[0];
        t->flags = be32(tkhd.p) & 0xFFFFFF;
        const uint8_t *p = tkhd.p + 4;
        if (version == 1) {
            if (tkhd.n < 96)
                return nil;
            t->trackID = be32(p + 16);
            t->duration = be64(p + 24);
            p += 32;
        } else {
            t->trackID = be32(p + 8);
            t->duration = be32(p + 16);
            p += 20;
        }
        p += 8;
        t->layer = (int16_t)be16(p);
        t->alternateGroup = (int16_t)be16(p + 2);
        t->volume = (float)(int16_t)be16(p + 4) / 256;
        t->matrix = read_matrix(p + 8);
        t->dimensions = CGSizeMake(fixed1616(be32(p + 44)), fixed1616(be32(p + 48)));
    }
    if (find_box(trak, 'edts', &edts)) {
        Span elst;
        if (find_box(edts, 'elst', &elst) && elst.n >= 8) {
            uint32_t version = elst.p[0], n = be32(elst.p + 4);
            size_t entry = version == 1 ? 20 : 12;
            if (8 + n * entry <= elst.n) {
                t->edits = calloc(n ? n : 1, sizeof(AVFEdit));
                t->editCount = n;
                for (uint32_t i = 0; i < n; i++) {
                    const uint8_t *e = elst.p + 8 + i * entry;
                    if (version == 1) {
                        t->edits[i].duration = (int64_t)be64(e);
                        t->edits[i].mediaTime = (int64_t)be64(e + 8);
                        t->edits[i].rate = fixed1616(be32(e + 16));
                    } else {
                        t->edits[i].duration = be32(e);
                        t->edits[i].mediaTime = (int32_t)be32(e + 4);
                        t->edits[i].rate = fixed1616(be32(e + 8));
                    }
                }
            }
        }
    }
    if (find_box(trak, 'mdia', &mdia)) {
        Span mdhd, hdlr, minf;
        if (find_box(mdia, 'mdhd', &mdhd) && mdhd.n >= 24) {
            if (mdhd.p[0] == 1 && mdhd.n >= 36) {
                t->timescale = be32(mdhd.p + 20);
                t->mediaDuration = be64(mdhd.p + 24);
                t->language = packed_language(be16(mdhd.p + 32));
            } else {
                t->timescale = be32(mdhd.p + 12);
                t->mediaDuration = be32(mdhd.p + 16);
                t->language = packed_language(be16(mdhd.p + 20));
            }
        }
        if (find_box(mdia, 'hdlr', &hdlr) && hdlr.n >= 12)
            t->handler = be32(hdlr.p + 8);
        Span elng;
        if (find_box(mdia, 'elng', &elng) && elng.n > 4)
            t->extendedLanguage = [[NSString alloc] initWithBytes:elng.p + 4 length:strnlen((const char *)elng.p + 4, elng.n - 4)
                                                         encoding:NSUTF8StringEncoding];
        if (find_box(mdia, 'minf', &minf)) {
            Span dinf, stbl;
            if (find_box(minf, 'dinf', &dinf)) {
                Span dref;
                if (find_box(dinf, 'dref', &dref) && dref.n >= 16)
                    t->selfContained = (be32(dref.p + 8 + 8) & 1) != 0;
            }
            if (find_box(minf, 'stbl', &stbl))
                read_sample_table(t, stbl, quickTime);
        }
    }
    if (find_box(trak, 'udta', &udta))
        read_udta(udta, t->userData);
    return t;
}

@implementation AVFMovie

+ (instancetype)movieWithData:(NSData *)data error:(NSError **)error
{
    Span file = {data.bytes, data.length};
    AVFMovie *m = [AVFMovie new];
    m->data = data;
    m->quickTime = YES;
    m->rate = 1;
    m->volume = 1;
    m->matrix = CGAffineTransformIdentity;
    m->tracks = [NSMutableArray array];
    m->userData = [NSMutableArray array];
    m->metadata = [NSMutableArray array];
    Span ftyp, moov;
    if (find_box(file, 'ftyp', &ftyp) && ftyp.n >= 4) {
        m->majorBrand = be32(ftyp.p);
        m->quickTime = m->majorBrand == 'qt  ';
    }
    if (!find_box(file, 'moov', &moov)) {
        if (error)
            *error = not_a_movie();
        return nil;
    }
    Span mvhd, udta, meta;
    if (find_box(moov, 'mvhd', &mvhd) && mvhd.n >= 96) {
        const uint8_t *p = mvhd.p + 4;
        if (mvhd.p[0] == 1 && mvhd.n >= 108) {
            m->creationTime = be64(p);
            m->timescale = be32(p + 16);
            m->duration = be64(p + 20);
            p += 28;
        } else {
            m->creationTime = be32(p);
            m->timescale = be32(p + 8);
            m->duration = be32(p + 12);
            p += 16;
        }
        m->rate = fixed1616(be32(p));
        m->volume = (float)(int16_t)be16(p + 4) / 256;
        m->matrix = read_matrix(p + 16);
    } else {
        if (error)
            *error = not_a_movie();
        return nil;
    }
    uint32_t type;
    Span body;
    Span s = moov;
    while (next_box(&s, &type, &body))
        if (type == 'trak') {
            AVFTrack *t = read_track(body, m->quickTime);
            if (t)
                [m->tracks addObject:t];
        }
    if (find_box(moov, 'udta', &udta)) {
        read_udta(udta, m->userData);
        Span umeta;
        if (find_box(udta, 'meta', &umeta))
            read_meta(umeta, m->metadata);
    }
    if (find_box(moov, 'meta', &meta))
        read_meta(meta, m->metadata);
    (void)fixed0230;
    return m;
}

@end
