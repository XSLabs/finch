/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Word 97 documents (.doc, NSDocFormatTextDocumentType), read and written, from
 * Microsoft's published format ([MS-DOC], [MS-CFB], [MS-OLEPS]).
 *
 * A .doc is a compound file (a FAT file system in a file) holding the
 * WordDocument stream (the FIB, which says where everything is, then the
 * text and the pages of character and paragraph properties, FKPs) and a
 * table stream (the piece table mapping the text's characters to where they
 * are, the stylesheet, the font table, the document's properties), with the
 * summary information property sets beside them.
 *
 * Written as Apple's writer writes it: the text in one Unicode piece; each
 * run's font, size, bold, italic, strikethrough, outline, underline, super-
 * and subscript, highlight, colour, kerning and baseline offset; each
 * paragraph's alignment, indents, spacing, line height, tab stops and
 * direction; a fixed stylesheet (Normal, Default Paragraph Font); title,
 * author and the other document attributes in the property sets. Read back
 * as Apple's reader reads it, and Word's documents too: pieces in 8-bit or
 * Unicode text, styles and their inheritance, fields (their results, and a
 * link for HYPERLINK), the first section's page size and margins.
 */
#import "UIFoundationInternal.h"

#pragma mark - Bytes

static uint16_t
rd16(const uint8_t *p)
{
    return (uint16_t)(p[0] | p[1] << 8);
}

static uint32_t
rd32(const uint8_t *p)
{
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static void
put16(NSMutableData *d, uint16_t v)
{
    uint8_t b[2] = {(uint8_t)v, (uint8_t)(v >> 8)};
    [d appendBytes:b length:2];
}

static void
put32(NSMutableData *d, uint32_t v)
{
    uint8_t b[4] = {(uint8_t)v, (uint8_t)(v >> 8), (uint8_t)(v >> 16), (uint8_t)(v >> 24)};
    [d appendBytes:b length:4];
}

static void
put8(NSMutableData *d, uint8_t v)
{
    [d appendBytes:&v length:1];
}

static void
set16(NSMutableData *d, NSUInteger at, uint16_t v)
{
    uint8_t b[2] = {(uint8_t)v, (uint8_t)(v >> 8)};
    [d replaceBytesInRange:NSMakeRange(at, 2) withBytes:b];
}

static void
set32(NSMutableData *d, NSUInteger at, uint32_t v)
{
    uint8_t b[4] = {(uint8_t)v, (uint8_t)(v >> 8), (uint8_t)(v >> 16), (uint8_t)(v >> 24)};
    [d replaceBytesInRange:NSMakeRange(at, 4) withBytes:b];
}

static void
pad_to(NSMutableData *d, NSUInteger multiple)
{
    NSUInteger n = [d length] % multiple;
    if (n)
        [d increaseLengthBy:multiple - n];
}

#pragma mark - Compound files ([MS-CFB])

enum {
    CFB_FREE = 0xFFFFFFFF, CFB_END = 0xFFFFFFFE, CFB_FAT = 0xFFFFFFFD, CFB_DIFAT = 0xFFFFFFFC,
};

/* The streams of a compound file by name, or nil when it isn't one. */
static NSDictionary<NSString *, NSData *> *
cfb_streams(NSData *data)
{
    const uint8_t *d = [data bytes];
    NSUInteger n = [data length];
    static const uint8_t magic[8] = {0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1};
    if (n < 512 || memcmp(d, magic, 8))
        return nil;
    unsigned shift = rd16(d + 30), minishift = rd16(d + 32);
    if (shift != 9 && shift != 12)
        return nil;
    NSUInteger ssz = 1u << shift, mssz = 1u << minishift;
    uint32_t nfat = rd32(d + 44), dir0 = rd32(d + 48), cutoff = rd32(d + 56);
    uint32_t minifat0 = rd32(d + 60), difat0 = rd32(d + 68), ndifat = rd32(d + 72);
    NSUInteger nsectors = (n - ssz) / ssz;
    const uint8_t *(^sector)(uint32_t) = ^const uint8_t *(uint32_t s) {
        NSUInteger at = ssz + (NSUInteger)s * ssz;
        return s < nsectors ? d + at : NULL;
    };
    /* the FAT's sectors: 109 in the header, the rest in the DIFAT chain */
    NSMutableData *fatSectors = [NSMutableData data];
    for (uint32_t i = 0; i < 109 && i < nfat; i++) {
        uint32_t s = rd32(d + 76 + 4 * i);
        [fatSectors appendBytes:&s length:4];
    }
    uint32_t ds = difat0;
    for (uint32_t k = 0; k < ndifat && ds < CFB_DIFAT; k++) {
        const uint8_t *p = sector(ds);
        if (!p)
            break;
        for (NSUInteger i = 0; i + 1 < ssz / 4 && [fatSectors length] / 4 < nfat; i++) {
            uint32_t s = rd32(p + 4 * i);
            [fatSectors appendBytes:&s length:4];
        }
        ds = rd32(p + ssz - 4);
    }
    NSMutableData *fatData = [NSMutableData data];
    const uint32_t *fs = [fatSectors bytes];
    for (NSUInteger i = 0; i < [fatSectors length] / 4; i++) {
        const uint8_t *p = sector(fs[i]);
        if (p)
            [fatData appendBytes:p length:ssz];
    }
    NSUInteger fatCount = [fatData length] / 4;
    const uint8_t *fat = [fatData bytes];
    NSData *(^chain)(uint32_t, NSUInteger) = ^NSData *(uint32_t start, NSUInteger limit) {
        NSMutableData *out = [NSMutableData data];
        uint32_t s = start;
        NSUInteger guard = 0;
        while (s < CFB_DIFAT && s < fatCount && guard++ <= nsectors) {
            const uint8_t *p = sector(s);
            if (!p)
                break;
            [out appendBytes:p length:ssz];
            if (limit && [out length] >= limit)
                break;
            s = rd32(fat + 4 * s);
        }
        return out;
    };
    NSData *dir = chain(dir0, 0);
    const uint8_t *dp = [dir bytes];
    NSUInteger nentries = [dir length] / 128;
    if (!nentries || dp[66] != 5)
        return nil;
    NSData *ministream = chain(rd32(dp + 116), 0);
    NSData *minifatData = minifat0 < CFB_DIFAT ? chain(minifat0, 0) : [NSData data];
    const uint8_t *minifat = [minifatData bytes];
    NSUInteger minifatCount = [minifatData length] / 4;
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSUInteger i = 1; i < nentries; i++) {
        const uint8_t *e = dp + 128 * i;
        if (e[66] != 2)
            continue;
        NSUInteger nameLen = MIN((NSUInteger)rd16(e + 64), (NSUInteger)64);
        NSString *name = [[[NSString alloc] initWithBytes:e length:nameLen >= 2 ? nameLen - 2 : 0
                                                 encoding:NSUTF16LittleEndianStringEncoding] autorelease];
        uint32_t start = rd32(e + 116);
        uint64_t size = rd32(e + 120);
        if (shift == 12)
            size |= (uint64_t)rd32(e + 124) << 32;
        NSData *stream;
        if (size < cutoff) {
            NSMutableData *m = [NSMutableData data];
            uint32_t s = start;
            NSUInteger guard = 0;
            while (s < CFB_DIFAT && s < minifatCount && guard++ <= minifatCount) {
                NSUInteger at = (NSUInteger)s * mssz;
                if (at + mssz > [ministream length])
                    break;
                [m appendBytes:(const uint8_t *)[ministream bytes] + at length:mssz];
                s = rd32(minifat + 4 * s);
            }
            stream = m;
        } else {
            stream = chain(start, (NSUInteger)size);
        }
        if ([stream length] > size)
            stream = [stream subdataWithRange:NSMakeRange(0, (NSUInteger)size)];
        if (name)
            out[name] = stream;
    }
    return out;
}

/* A compound file of streams, as Apple's writer makes one: 512-byte sectors, each
   stream at least 4096 bytes long so none goes in the mini stream, the streams in
   a little tree under the root (Word's document class). */
static NSData *
cfb_file(NSArray<NSString *> *names, NSArray<NSData *> *streams)
{
    enum { SSZ = 512 };
    NSMutableData *body = [NSMutableData data];
    NSMutableArray *starts = [NSMutableArray array], *counts = [NSMutableArray array];
    NSMutableArray *padded = [NSMutableArray array];
    for (NSData *s in streams) {
        NSMutableData *p = [[s mutableCopy] autorelease];
        if ([p length] < 4096)
            [p setLength:4096];
        pad_to(p, SSZ);
        [starts addObject:@([body length] / SSZ)];
        [counts addObject:@([p length] / SSZ)];
        [body appendData:p];
        [padded addObject:p];
    }
    /* the directory: the root, then the streams */
    NSUInteger nentries = 1 + [names count];
    NSUInteger dirSectors = (nentries * 128 + SSZ - 1) / SSZ;
    uint32_t dirStart = (uint32_t)([body length] / SSZ);
    /* the tree, by Apple's: names ordered by length, then case-insensitively; each
       stream the right child of the one before, the middle one the root's child */
    NSMutableArray *order = [NSMutableArray array];
    for (NSUInteger i = 0; i < [names count]; i++)
        [order addObject:@(i)];
    [order sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        NSString *x = names[[a unsignedIntegerValue]], *y = names[[b unsignedIntegerValue]];
        if ([x length] != [y length])
            return [x length] < [y length] ? NSOrderedAscending : NSOrderedDescending;
        return [[x uppercaseString] compare:[y uppercaseString]];
    }];
    NSUInteger count = [order count];
    uint32_t left[16], right[16];
    for (NSUInteger i = 0; i < count; i++)
        left[i] = right[i] = CFB_FREE;
    NSUInteger mid = count / 2;
    /* below the middle one: a chain to the left; above it: a chain to the right */
    for (NSUInteger k = mid; k > 0; k--)
        left[[order[k] unsignedIntegerValue]] = (uint32_t)[order[k - 1] unsignedIntegerValue] + 1;
    for (NSUInteger k = mid; k + 1 < count; k++)
        right[[order[k] unsignedIntegerValue]] = (uint32_t)[order[k + 1] unsignedIntegerValue] + 1;
    NSMutableData *dir = [NSMutableData dataWithLength:dirSectors * SSZ];
    uint8_t *dp = [dir mutableBytes];
    for (NSUInteger i = 0; i < dirSectors * SSZ / 128; i++) {
        uint8_t *e = dp + 128 * i;
        memset(e + 68, 0xFF, 12);  /* no siblings or child */
    }
    void (^entry)(NSUInteger, NSString *, uint8_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t) =
        ^(NSUInteger i, NSString *name, uint8_t type, uint32_t l, uint32_t r, uint32_t child, uint32_t start, uint32_t size) {
            uint8_t *e = dp + 128 * i;
            NSUInteger len = MIN([name length], (NSUInteger)31);
            for (NSUInteger k = 0; k < len; k++) {
                unichar c = [name characterAtIndex:k];
                e[2 * k] = (uint8_t)c, e[2 * k + 1] = (uint8_t)(c >> 8);
            }
            e[64] = (uint8_t)((len + 1) * 2), e[65] = 0;
            e[66] = type;
            e[67] = 1;  /* black */
            uint8_t *p = e + 68;
            p[0] = (uint8_t)l, p[1] = (uint8_t)(l >> 8), p[2] = (uint8_t)(l >> 16), p[3] = (uint8_t)(l >> 24);
            p += 4;
            p[0] = (uint8_t)r, p[1] = (uint8_t)(r >> 8), p[2] = (uint8_t)(r >> 16), p[3] = (uint8_t)(r >> 24);
            p += 4;
            p[0] = (uint8_t)child, p[1] = (uint8_t)(child >> 8), p[2] = (uint8_t)(child >> 16), p[3] = (uint8_t)(child >> 24);
            p = e + 116;
            p[0] = (uint8_t)start, p[1] = (uint8_t)(start >> 8), p[2] = (uint8_t)(start >> 16), p[3] = (uint8_t)(start >> 24);
            p = e + 120;
            p[0] = (uint8_t)size, p[1] = (uint8_t)(size >> 8), p[2] = (uint8_t)(size >> 16), p[3] = (uint8_t)(size >> 24);
        };
    entry(0, @"Root Entry", 5, CFB_FREE, CFB_FREE, count ? (uint32_t)[order[mid] unsignedIntegerValue] + 1 : CFB_FREE, CFB_END, 0);
    static const uint8_t wordClass[16] = {0x06, 0x09, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00,
                                          0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46};
    memcpy(dp + 80, wordClass, 16);
    for (NSUInteger i = 0; i < count; i++)
        entry(i + 1, names[i], 2, left[i], right[i], CFB_FREE, (uint32_t)[starts[i] unsignedIntegerValue],
              (uint32_t)[[padded[i] self] length]);
    /* (the entries record the streams' padded sizes, as Apple's do) */
    [body appendData:dir];
    /* the FAT, after everything it maps, and the DIFAT sectors for any past 109 */
    NSUInteger dataSectors = [body length] / SSZ;
    NSUInteger fatSectors = 1, difatSectors = 0;
    for (;;) {
        difatSectors = fatSectors > 109 ? (fatSectors - 109 + 126) / 127 : 0;
        NSUInteger need = (dataSectors + fatSectors + difatSectors + 127) / 128;
        if (need <= fatSectors)
            break;
        fatSectors = need;
    }
    NSUInteger total = dataSectors + fatSectors + difatSectors;
    NSMutableData *fat = [NSMutableData dataWithLength:fatSectors * SSZ];
    memset([fat mutableBytes], 0xFF, [fat length]);
    void (^link)(NSUInteger, uint32_t) = ^(NSUInteger s, uint32_t next) { set32(fat, s * 4, next); };
    for (NSUInteger i = 0; i < count; i++) {
        NSUInteger s0 = [starts[i] unsignedIntegerValue], c = [counts[i] unsignedIntegerValue];
        for (NSUInteger k = 0; k < c; k++)
            link(s0 + k, k + 1 < c ? (uint32_t)(s0 + k + 1) : CFB_END);
    }
    for (NSUInteger k = 0; k < dirSectors; k++)
        link(dirStart + k, k + 1 < dirSectors ? (uint32_t)(dirStart + k + 1) : CFB_END);
    for (NSUInteger k = 0; k < fatSectors; k++)
        link(dataSectors + k, CFB_FAT);
    for (NSUInteger k = 0; k < difatSectors; k++)
        link(dataSectors + fatSectors + k, CFB_DIFAT);
    (void)total;
    NSMutableData *difat = [NSMutableData dataWithLength:difatSectors * SSZ];
    memset([difat mutableBytes], 0xFF, [difat length]);
    for (NSUInteger k = 109; k < fatSectors; k++) {
        NSUInteger idx = k - 109, sec = idx / 127, slot = idx % 127;
        set32(difat, sec * SSZ + slot * 4, (uint32_t)(dataSectors + k));
    }
    for (NSUInteger sec = 0; sec < difatSectors; sec++)
        set32(difat, sec * SSZ + 127 * 4, sec + 1 < difatSectors ? (uint32_t)(dataSectors + fatSectors + sec + 1) : CFB_END);
    /* the header */
    NSMutableData *h = [NSMutableData dataWithLength:SSZ];
    static const uint8_t magic[8] = {0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1};
    [h replaceBytesInRange:NSMakeRange(0, 8) withBytes:magic];
    set16(h, 24, 0x003E);  /* minor version */
    set16(h, 26, 0x0003);  /* major version: 512-byte sectors */
    set16(h, 28, 0xFFFE);  /* little-endian */
    set16(h, 30, 9);
    set16(h, 32, 6);
    set32(h, 44, (uint32_t)fatSectors);
    set32(h, 48, dirStart);
    set32(h, 56, 4096);
    set32(h, 60, CFB_END);  /* no mini FAT */
    set32(h, 64, 0);
    set32(h, 68, difatSectors ? (uint32_t)(dataSectors + fatSectors) : CFB_END);
    set32(h, 72, (uint32_t)difatSectors);
    for (NSUInteger k = 0; k < 109; k++)
        set32(h, 76 + 4 * k, k < fatSectors ? (uint32_t)(dataSectors + k) : CFB_FREE);
    NSMutableData *file = [NSMutableData dataWithData:h];
    [file appendData:body];
    [file appendData:fat];
    [file appendData:difat];
    return file;
}

#pragma mark - Property sets ([MS-OLEPS])

enum { PID_CODEPAGE = 1, PID_TITLE = 2, PID_SUBJECT = 3, PID_AUTHOR = 4, PID_KEYWORDS = 5, PID_COMMENTS = 6,
       PID_LASTAUTHOR = 8, PID_CREATE_DTM = 12, PID_LASTSAVE_DTM = 13, PID_COMPANY = 15, PID_COPYRIGHT = 169 };
enum { VT_I2 = 2, VT_LPSTR = 30, VT_LPWSTR = 31, VT_FILETIME = 64 };

static const uint8_t SummaryFMTID[16] = {0xE0, 0x85, 0x9F, 0xF2, 0xF9, 0x4F, 0x68, 0x10,
                                         0xAB, 0x91, 0x08, 0x00, 0x2B, 0x27, 0xB3, 0xD9};
static const uint8_t DocSummaryFMTID[16] = {0x02, 0xD5, 0xCD, 0xD5, 0x9C, 0x2E, 0x1B, 0x10,
                                            0x93, 0x97, 0x08, 0x00, 0x2B, 0x2C, 0xF9, 0xAE};

/* A property set of strings (UTF-8, as Apple's writer has them), by property id. */
static NSData *
property_set(const uint8_t fmtid[16], NSDictionary<NSNumber *, NSString *> *strings)
{
    NSArray *ids = [[strings allKeys] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableData *values = [NSMutableData data];
    NSMutableArray *offsets = [NSMutableArray array];
    NSUInteger n = 1 + [ids count];
    NSUInteger head = 8 + 8 * n;
    [offsets addObject:@(head + [values length])];
    put32(values, VT_I2), put16(values, 0xFDE9), put16(values, 0);  /* code page: UTF-8 */
    for (NSNumber *pid in ids) {
        [offsets addObject:@(head + [values length])];
        NSData *bytes = [strings[pid] dataUsingEncoding:NSUTF8StringEncoding];
        put32(values, VT_LPSTR);
        put32(values, (uint32_t)[bytes length] + 1);
        [values appendData:bytes];
        put8(values, 0);
        pad_to(values, 4);
    }
    NSMutableData *section = [NSMutableData data];
    put32(section, (uint32_t)(head + [values length]));
    put32(section, (uint32_t)n);
    put32(section, PID_CODEPAGE), put32(section, (uint32_t)[offsets[0] unsignedIntegerValue]);
    for (NSUInteger i = 0; i < [ids count]; i++)
        put32(section, (uint32_t)[ids[i] unsignedIntValue]), put32(section, (uint32_t)[offsets[i + 1] unsignedIntegerValue]);
    [section appendData:values];
    NSMutableData *d = [NSMutableData data];
    put16(d, 0xFFFE), put16(d, 0);
    put32(d, 0x00010A04);  /* the OS version Apple's writer gives */
    [d increaseLengthBy:16];  /* no class */
    put32(d, 1);
    [d appendBytes:fmtid length:16];
    put32(d, 48);
    [d appendData:section];
    return d;
}

/* A property set's strings and dates, by property id. */
static NSDictionary<NSNumber *, id> *
read_property_set(NSData *data)
{
    const uint8_t *d = [data bytes];
    NSUInteger n = [data length];
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    if (n < 48 || rd16(d) != 0xFFFE)
        return out;
    uint32_t off = rd32(d + 44);
    if (off + 8 > n)
        return out;
    const uint8_t *s = d + off;
    NSUInteger size = MIN((NSUInteger)rd32(s), n - off);
    uint32_t count = rd32(s + 4);
    NSStringEncoding enc = NSWindowsCP1252StringEncoding;
    for (int pass = 0; pass < 2; pass++)
        for (uint32_t i = 0; i < count && 8 + 8 * (NSUInteger)i + 8 <= size; i++) {
            uint32_t pid = rd32(s + 8 + 8 * i), po = rd32(s + 12 + 8 * i);
            if (po + 8 > size)
                continue;
            uint32_t type = rd32(s + po) & 0xFFFF;
            if (pass == 0) {
                if (pid == PID_CODEPAGE && type == VT_I2) {
                    uint16_t cp = rd16(s + po + 4);
                    if (cp == 0xFDE9)
                        enc = NSUTF8StringEncoding;
                    else if (cp == 1200)
                        enc = NSUTF16LittleEndianStringEncoding;
                    else if (cp == 10000)
                        enc = NSMacOSRomanStringEncoding;
                }
                continue;
            }
            if (type == VT_LPSTR) {
                uint32_t len = rd32(s + po + 4);
                if (po + 8 + len > size)
                    continue;
                NSUInteger l = len;
                while (l && s[po + 8 + l - 1] == 0)
                    l--;
                NSString *str = [[[NSString alloc] initWithBytes:s + po + 8 length:l encoding:enc] autorelease];
                if (str)
                    out[@(pid)] = str;
            } else if (type == VT_LPWSTR) {
                uint32_t len = rd32(s + po + 4);
                if (po + 8 + 2 * (NSUInteger)len > size)
                    continue;
                NSUInteger l = len;
                while (l && !rd16(s + po + 8 + 2 * (l - 1)))
                    l--;
                NSString *str = [[[NSString alloc] initWithBytes:s + po + 8 length:2 * l
                                                        encoding:NSUTF16LittleEndianStringEncoding] autorelease];
                if (str)
                    out[@(pid)] = str;
            } else if (type == VT_FILETIME) {
                uint64_t ft = (uint64_t)rd32(s + po + 4) | (uint64_t)rd32(s + po + 8) << 32;
                if (ft)
                    out[@(pid)] = [NSDate dateWithTimeIntervalSince1970:(double)ft / 1e7 - 11644473600.0];
            }
        }
    return out;
}

#pragma mark - Word's colours and dates

/* Word's 16 colours (ico), from 1 */
static const uint8_t IcoRGB[17][3] = {
    {0, 0, 0}, {0, 0, 0}, {0, 0, 255}, {0, 255, 255}, {0, 255, 0}, {255, 0, 255}, {255, 0, 0},
    {255, 255, 0}, {255, 255, 255}, {0, 0, 128}, {0, 128, 128}, {0, 128, 0}, {128, 0, 128},
    {128, 0, 0}, {128, 128, 0}, {128, 128, 128}, {192, 192, 192},
};

static uint8_t
nearest_ico(int r, int g, int b)
{
    uint8_t best = 1;
    long bestd = LONG_MAX;
    for (uint8_t i = 1; i <= 16; i++) {
        long dr = r - IcoRGB[i][0], dg = g - IcoRGB[i][1], db = b - IcoRGB[i][2];
        long dist = dr * dr + dg * dg + db * db;
        if (dist < bestd)
            bestd = dist, best = i;
    }
    return best;
}

/* A colour's bytes as Apple's writer gives them: in calibrated (generic) RGB. */
static BOOL
color_bytes(id color, int rgb[3])
{
    CGColorRef cg = color ? UIFCGColor(color) : NULL;
    if (!cg)
        return NO;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceGenericRGB);
    CGColorRef conv = CGColorCreateCopyByMatchingToColorSpace(space, kCGRenderingIntentDefault, cg, NULL);
    CGColorSpaceRelease(space);
    BOOL ok = NO;
    if (conv && CGColorGetNumberOfComponents(conv) >= 3) {
        const CGFloat *c = CGColorGetComponents(conv);
        for (int i = 0; i < 3; i++)
            rgb[i] = (int)lround(MAX(0, MIN(1, c[i])) * 255);
        ok = YES;
    }
    if (conv)
        CGColorRelease(conv);
    return ok;
}

static id
calibrated(int r, int g, int b)
{
    return [UIFClass("NSColor") colorWithCalibratedRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:1];
}

/* A DTTM (local time, minutes) for a date, and back. */
static uint32_t
dttm_of(NSDate *date)
{
    NSDateComponents *c = [[NSCalendar currentCalendar]
        components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitHour | NSCalendarUnitMinute |
                   NSCalendarUnitWeekday
          fromDate:date];
    return (uint32_t)([c minute] & 63) | (uint32_t)([c hour] & 31) << 6 | (uint32_t)([c day] & 31) << 11 |
           (uint32_t)([c month] & 15) << 16 | (uint32_t)(([c year] - 1900) & 511) << 20 |
           (uint32_t)(([c weekday] - 1) & 7) << 29;
}

static NSDate *
date_of_dttm(uint32_t v)
{
    if (!v)
        return nil;
    NSDateComponents *c = [[[NSDateComponents alloc] init] autorelease];
    [c setMinute:v & 63];
    [c setHour:(v >> 6) & 31];
    [c setDay:(v >> 11) & 31];
    [c setMonth:(v >> 16) & 15];
    [c setYear:1900 + ((v >> 20) & 511)];
    return [[NSCalendar currentCalendar] dateFromComponents:c];
}

#pragma mark - Writing

enum { CocoaMagic = 0x6464 };  /* wMagicCreated, wMagicRevised: Cocoa's writer */

/* the attribute names, as AppKit spells them */
static NSString *const FontKey = @"NSFont", *const ColorKey = @"NSColor", *const BackKey = @"NSBackgroundColor",
                       *const UnderlineKey = @"NSUnderline", *const StrikeKey = @"NSStrikethrough",
                       *const SuperKey = @"NSSuperScript", *const KernKey = @"NSKern",
                       *const BaselineKey = @"NSBaselineOffset", *const StrokeKey = @"NSStrokeWidth",
                       *const ParagraphKey = @"NSParagraphStyle";

static void
sprm8(NSMutableData *g, uint16_t op, uint8_t v)
{
    put16(g, op), put8(g, v);
}

static void
sprm16(NSMutableData *g, uint16_t op, uint16_t v)
{
    put16(g, op), put16(g, v);
}

static NSUInteger
font_index(NSMutableArray<NSString *> *fonts, NSString *family)
{
    NSUInteger i = [fonts indexOfObject:family];
    if (i == NSNotFound) {
        [fonts addObject:family];
        i = [fonts count] - 1;
    }
    return i;
}

/* A run's properties, as Apple's writer gives them. */
static NSData *
chpx_of(NSDictionary *a, NSMutableArray<NSString *> *fonts)
{
    NSMutableData *g = [NSMutableData data];
    NSFont *font = a[FontKey] ?: UIFDefaultFont();
    CTFontRef ct = (CTFontRef)font;
    NSString *family = [(NSString *)CTFontCopyFamilyName(ct) autorelease] ?: @"Helvetica";
    /* a shipped stand-in is written by the font it stands in for */
    NSString *apple = UIFAppleFontName([(NSString *)CTFontCopyPostScriptName(ct) autorelease]);
    if (apple) {
        CTFontRef af = CTFontCreateWithName((CFStringRef)apple, 12, NULL);
        NSString *af_family = af ? [(NSString *)CTFontCopyFamilyName(af) autorelease] : nil;
        if (af)
            CFRelease(af);
        if ([af_family length] && ![af_family isEqualToString:family] && UIFFontAlias(af_family))
            family = af_family;
    }
    uint16_t ftc = (uint16_t)font_index(fonts, family);
    CTFontSymbolicTraits traits = CTFontGetSymbolicTraits(ct);
    sprm16(g, 0x4A4F, ftc);
    sprm16(g, 0x4A51, ftc);
    sprm16(g, 0x4A43, (uint16_t)lround(CTFontGetSize(ct) * 2));
    if (traits & kCTFontTraitBold)
        sprm8(g, 0x0835, 1);
    if (traits & kCTFontTraitItalic)
        sprm8(g, 0x0836, 1);
    if ([a[StrikeKey] integerValue])
        sprm8(g, 0x0837, 1);
    if ([a[StrokeKey] doubleValue] > 0)
        sprm8(g, 0x0838, 1);
    NSInteger super = [a[SuperKey] integerValue];
    if (super)
        sprm8(g, 0x2A48, super > 0 ? 1 : 2);
    int rgb[3];
    if (a[BackKey] && color_bytes(a[BackKey], rgb))
        sprm8(g, 0x2A0C, nearest_ico(rgb[0], rgb[1], rgb[2]));
    NSInteger u = [a[UnderlineKey] integerValue];
    if (u) {
        uint8_t kul = 1;
        if (u & 0x8000)
            kul = 2;  /* by word */
        else if ((u & 0xff) == 0x09)
            kul = 3;  /* double */
        else if ((u & 0xff) == 0x02)
            kul = 6;  /* thick */
        else if (u & 0x0100)
            kul = 4;  /* dotted */
        sprm8(g, 0x2A3E, kul);
    }
    if (a[ColorKey] && color_bytes(a[ColorKey], rgb)) {
        sprm8(g, 0x2A42, nearest_ico(rgb[0], rgb[1], rgb[2]));
        put16(g, 0x6870);
        uint8_t cv[4] = {(uint8_t)rgb[0], (uint8_t)rgb[1], (uint8_t)rgb[2], 0};
        [g appendBytes:cv length:4];
    }
    double kern = [a[KernKey] doubleValue];
    if (kern)
        sprm16(g, 0x8840, (uint16_t)(int16_t)lround(kern * 20));
    double base = [a[BaselineKey] doubleValue];
    if (base)
        sprm16(g, 0x4845, (uint16_t)(int16_t)lround(base * 2));
    return g;
}

static uint16_t
twips(CGFloat points)
{
    return (uint16_t)(int16_t)lround(points * 20);
}

/* A paragraph's properties, as Apple's writer gives them (without the style index). */
static NSData *
papx_of(NSParagraphStyle *ps)
{
    NSMutableData *g = [NSMutableData data];
    if (!ps)
        ps = [NSParagraphStyle defaultParagraphStyle];
    NSTextAlignment al = [ps alignment];
    if (al == NSTextAlignmentCenter)
        sprm8(g, 0x2403, 1);
    else if (al == NSTextAlignmentRight)
        sprm8(g, 0x2403, 2);
    else if (al == NSTextAlignmentJustified)
        sprm8(g, 0x2403, 3);
    CGFloat head = [ps headIndent], first = [ps firstLineHeadIndent], tail = [ps tailIndent];
    if (head)
        sprm16(g, 0x840F, twips(head));
    if (first != head)
        sprm16(g, 0x8411, twips(first - head));
    if (tail < 0)
        sprm16(g, 0x840E, twips(-tail));
    if ([ps paragraphSpacingBefore])
        sprm16(g, 0xA413, twips([ps paragraphSpacingBefore]));
    if ([ps paragraphSpacing])
        sprm16(g, 0xA414, twips([ps paragraphSpacing]));
    CGFloat minH = [ps minimumLineHeight], maxH = [ps maximumLineHeight];
    if (minH > 0) {
        put16(g, 0x6412);
        put16(g, minH == maxH ? (uint16_t)(-(int16_t)twips(minH)) : twips(minH));
        put16(g, 0);
    }
    if ([ps baseWritingDirection] == NSWritingDirectionRightToLeft)
        sprm8(g, 0x2441, 1);
    NSArray<NSTextTab *> *tabs = [ps tabStops];
    if ([tabs count]) {
        NSUInteger n = MIN([tabs count], (NSUInteger)64);
        put16(g, 0xC60D);
        put8(g, (uint8_t)(2 + 3 * n));
        put8(g, 0);  /* none deleted */
        put8(g, (uint8_t)n);
        for (NSUInteger i = 0; i < n; i++)
            put16(g, twips([tabs[i] location]));
        for (NSUInteger i = 0; i < n; i++)
            put8(g, [tabs[i] tabStopType] == NSDecimalTabStopType ? 3 : 0);
    }
    return g;
}

/* Runs of character or paragraph properties over the text (fc ranges), as FKP pages:
   Apple's layout, each property's bytes from the page's end down. */
typedef struct {
    uint32_t fcStart, fcEnd;
    NSData *grpprl;
} FkpRun;

static NSData *
fkp_pages(FkpRun *runs, NSUInteger n, BOOL paragraphs, uint32_t firstPage, NSMutableData *bin)
{
    NSMutableData *pages = [NSMutableData data];
    NSMutableArray *starts = [NSMutableArray array], *pns = [NSMutableArray array];
    NSUInteger i = 0;
    while (i < n) {
        uint8_t page[512];
        memset(page, 0, sizeof page);
        NSUInteger count = 0, top = 511;
        NSUInteger entry = paragraphs ? 13 : 1;
        uint8_t offsets[128];
        while (i + count < n) {
            NSData *g = runs[i + count].grpprl;
            NSUInteger size = paragraphs ? 2 + 2 * ((2 + [g length] + 1) / 2) : ([g length] ? 1 + [g length] : 0);
            NSUInteger newTop = size ? ((top - size) & ~(NSUInteger)1) : top;
            NSUInteger header = 4 * (count + 2) + entry * (count + 1);
            if (size > top || header > newTop || count == 127)
                break;
            if (size) {
                uint8_t *p = page + newTop;
                if (paragraphs) {
                    NSUInteger len = 2 + [g length];
                    p[0] = 0, p[1] = (uint8_t)((len + 1) / 2);
                    p[2] = 0, p[3] = 0;  /* istd 0, Normal */
                    memcpy(p + 4, [g bytes], [g length]);
                } else {
                    p[0] = (uint8_t)[g length];
                    memcpy(p + 1, [g bytes], [g length]);
                }
            }
            offsets[count] = (uint8_t)(size ? newTop / 2 : 0);
            top = newTop;
            count++;
        }
        if (!count)
            count = 1, offsets[0] = 0;  /* (a run too big for a page: written without properties) */
        for (NSUInteger k = 0; k <= count; k++) {
            uint32_t fc = k < count ? runs[i + k].fcStart : runs[i + count - 1].fcEnd;
            page[4 * k] = (uint8_t)fc, page[4 * k + 1] = (uint8_t)(fc >> 8), page[4 * k + 2] = (uint8_t)(fc >> 16),
            page[4 * k + 3] = (uint8_t)(fc >> 24);
        }
        for (NSUInteger k = 0; k < count; k++)
            page[4 * (count + 1) + entry * k] = offsets[k];
        page[511] = (uint8_t)count;
        [starts addObject:@(runs[i].fcStart)];
        [pns addObject:@(firstPage + [pages length] / 512)];
        [pages appendBytes:page length:512];
        i += count;
    }
    for (NSNumber *fc in starts)
        put32(bin, [fc unsignedIntValue]);
    put32(bin, n ? runs[n - 1].fcEnd : 0);
    for (NSNumber *pn in pns)
        put32(bin, [pn unsignedIntValue]);
    return pages;
}

static NSData *
font_table(NSArray<NSString *> *fonts)
{
    NSMutableData *t = [NSMutableData data];
    put16(t, (uint16_t)[fonts count]);
    put16(t, 0);
    for (NSString *name in fonts) {
        NSUInteger len = MIN([name length], (NSUInteger)31);
        put8(t, (uint8_t)(39 + 2 * (len + 1)));
        put8(t, 0x06);   /* variable pitch, TrueType */
        put16(t, 400);   /* weight */
        put8(t, [name isEqualToString:@"Symbol"] ? 2 : 0);
        put8(t, 0);
        [t increaseLengthBy:10 + 24];  /* panose, font signature */
        for (NSUInteger i = 0; i < len; i++)
            put16(t, [name characterAtIndex:i]);
        put16(t, 0);
    }
    return t;
}

/* The stylesheet Apple's writer gives every document: Normal (the fourth font, 12
   points, US English) and Default Paragraph Font. */
static NSData *
stylesheet(void)
{
    NSMutableData *s = [NSMutableData data];
    put16(s, 18);
    put16(s, 15), put16(s, 10), put16(s, 1), put16(s, 0x69), put16(s, 15), put16(s, 2);
    put16(s, 3), put16(s, 3), put16(s, 3);
    void (^std)(uint16_t, uint16_t, uint16_t, uint16_t, NSString *, NSData *, NSData *) =
        ^(uint16_t sti, uint16_t stk, uint16_t cupx, uint16_t next, NSString *name, NSData *papx, NSData *chpx) {
            NSMutableData *e = [NSMutableData data];
            put16(e, sti | 0x4000);
            put16(e, stk | 0xFFF0);  /* no base style */
            put16(e, cupx | next << 4);
            put16(e, 0);  /* bchUpe, set below */
            put16(e, 0);
            put16(e, (uint16_t)[name length]);
            for (NSUInteger i = 0; i < [name length]; i++)
                put16(e, [name characterAtIndex:i]);
            put16(e, 0);
            for (NSData *upx in papx ? @[ papx, chpx ] : @[ chpx ]) {
                put16(e, (uint16_t)[upx length]);
                [e appendData:upx];
                pad_to(e, 2);
            }
            set16(e, 6, (uint16_t)[e length]);
            put16(s, (uint16_t)[e length]);
            [s appendData:e];
        };
    NSMutableData *normalPapx = [NSMutableData data];
    put16(normalPapx, 0);
    NSMutableData *normalChpx = [NSMutableData data];
    sprm16(normalChpx, 0x4A43, 24);
    sprm16(normalChpx, 0x4A4F, 3);
    sprm16(normalChpx, 0x4A50, 3);
    sprm16(normalChpx, 0x4A51, 3);
    sprm16(normalChpx, 0x486D, 0x0409);
    std(0, 1, 2, 0, @"Normal", normalPapx, normalChpx);
    for (int i = 1; i < 10; i++)
        put16(s, 0);
    std(0x41, 2, 1, 10, @"Default Paragraph Font", nil, [NSData data]);
    for (int i = 11; i < 15; i++)
        put16(s, 0);
    return s;
}

/* The document's properties: Word's defaults as Apple's writer gives them, with the
   dates and view. */
static NSData *
document_properties(NSDictionary *attrs)
{
    NSMutableData *d = [NSMutableData dataWithLength:544];
    uint8_t *p = [d mutableBytes];
    static const struct { uint16_t at; uint8_t v; } bytes[] = {
        {0x00, 0x20}, {0x02, 0x04}, {0x04, 0x30}, {0x05, 0x08}, {0x06, 0x88}, {0x07, 0x18},
        {0x09, 0xF0}, {0x0A, 0xD0}, {0x0B, 0x02},                 /* dxaTab: half an inch */
        {0x0E, 0x68}, {0x0F, 0x01},                               /* dxaHotZ */
        {0x20, 0x01},                                             /* nRevision */
        {0x2E, 0x01}, {0x30, 0x01}, {0x34, 0x04}, {0x36, 0x03}, {0x37, 0x10}, {0x38, 0x01},
        {0x44, 0x01}, {0x46, 0x01}, {0x4A, 0x01},
        {0x52, 0x20}, {0x53, 0x03},                               /* zoom 100% */
        {0x55, 0xF0}, {0x56, 0x10},
        {0x190, 0xA5}, {0x191, 0x06}, {0x192, 0xC0}, {0x193, 0x07}, {0x194, 0xB4}, {0x196, 0xB4},
        {0x198, 0x80}, {0x19A, 0x12}, {0x19B, 0x30},
        {0x1EE, 0x02}, {0x1F2, 0x22}, {0x1F3, 0x04}, {0x1FE, 0xF0}, {0x1FF, 0x10}, {0x200, 0x08},
    };
    for (size_t i = 0; i < sizeof bytes / sizeof bytes[0]; i++)
        p[bytes[i].at] = bytes[i].v;
    /* the dates (Apple's writer gives 9 December 2002 when it isn't told) */
    NSDate *created = attrs[NSCreationTimeDocumentAttribute], *modified = attrs[NSModificationTimeDocumentAttribute];
    set32(d, 0x14, [created isKindOfClass:[NSDate class]] ? dttm_of(created) : 0x266C4BDA);
    set32(d, 0x18, [modified isKindOfClass:[NSDate class]] ? dttm_of(modified) : 0x266C4BDA);
    /* page layout view */
    if ([attrs[NSViewModeDocumentAttribute] integerValue] == 1)
        p[0x52] |= 1;
    return d;
}

/* The text as Word has it, UTF-16, and which character each came from. */
static void
word_text(NSString *s, NSMutableData *text, NSMutableData *sources)
{
    NSUInteger n = [s length];
    for (NSUInteger i = 0; i < n; i++) {
        unichar c = [s characterAtIndex:i];
        if (c == NSAttachmentCharacter)
            continue;
        if (c == '\n' || c == '\r' || c == 0x2029)
            c = 0x0D;
        else if (c == 0x2028)
            c = 0x0B;
        put16(text, c);
        uint32_t src = (uint32_t)i;
        [sources appendBytes:&src length:4];
    }
    /* as Apple's: an empty document is a space */
    if (![text length]) {
        put16(text, ' ');
        uint32_t src = 0;
        [sources appendBytes:&src length:4];
    }
    /* the last paragraph ends with a mark, its last character's run */
    const uint16_t *t = [text bytes];
    NSUInteger len = [text length] / 2;
    if (!len || t[len - 1] != 0x0D) {
        put16(text, 0x0D);
        uint32_t src = n ? (uint32_t)(n - 1) : 0;
        [sources appendBytes:&src length:4];
    }
}

UIF_HIDDEN NSData *
UIFWriteWordDocument(NSAttributedString *whole, NSRange range, NSDictionary *docAttrs)
{
    NSAttributedString *as = [whole attributedSubstringFromRange:range];
    NSString *string = [as string];
    NSMutableData *text = [NSMutableData data], *sources = [NSMutableData data];
    word_text(string, text, sources);
    NSUInteger ccp = [text length] / 2;
    const uint32_t *src = [sources bytes];
    const uint16_t *chars = [text bytes];
    NSMutableArray<NSString *> *fonts = [NSMutableArray arrayWithObjects:@"Times New Roman", @"Symbol", @"Arial", nil];
    const uint32_t fcMin = 0x600;
    NSDictionary *(^attrsAt)(NSUInteger) = ^NSDictionary *(NSUInteger k) {
        return [string length] ? [as attributesAtIndex:src[k] effectiveRange:NULL] : @{};
    };
    /* character runs: consecutive characters with the same properties */
    FkpRun *chp = calloc(ccp + 1, sizeof(FkpRun));
    NSUInteger nchp = 0;
    for (NSUInteger k = 0; k < ccp; k++) {
        NSData *g = chpx_of(attrsAt(k), fonts);
        uint32_t fc = fcMin + 2 * (uint32_t)k;
        if (nchp && [chp[nchp - 1].grpprl isEqualToData:g]) {
            chp[nchp - 1].fcEnd = fc + 2;
        } else {
            chp[nchp].fcStart = fc, chp[nchp].fcEnd = fc + 2, chp[nchp].grpprl = g;
            nchp++;
        }
    }
    /* paragraphs: each to its mark, with its first character's style */
    FkpRun *pap = calloc(ccp + 1, sizeof(FkpRun));
    NSUInteger npap = 0, paraStart = 0;
    for (NSUInteger k = 0; k < ccp; k++) {
        if (chars[k] != 0x0D)
            continue;
        pap[npap].fcStart = fcMin + 2 * (uint32_t)paraStart;
        pap[npap].fcEnd = fcMin + 2 * (uint32_t)(k + 1);
        pap[npap].grpprl = papx_of(attrsAt(paraStart)[ParagraphKey]);
        npap++;
        paraStart = k + 1;
    }
    while ([fonts count] < 4)
        [fonts addObject:@"Helvetica"];  /* Normal's font */
    /* WordDocument: the FIB, the text, then the property pages */
    NSMutableData *wd = [NSMutableData dataWithLength:fcMin];
    [wd appendData:text];
    pad_to(wd, 512);
    NSMutableData *chpBin = [NSMutableData data], *papBin = [NSMutableData data];
    [wd appendData:fkp_pages(chp, nchp, NO, (uint32_t)([wd length] / 512), chpBin)];
    [wd appendData:fkp_pages(pap, npap, YES, (uint32_t)([wd length] / 512), papBin)];
    free(chp);
    free(pap);
    uint32_t cbMac = (uint32_t)[wd length];
    /* the table stream */
    NSMutableData *table = [NSMutableData data];
    NSUInteger *fc = calloc(108, sizeof(NSUInteger)), *lcb = calloc(108, sizeof(NSUInteger));
    void (^place)(int, NSData *) = ^(int index, NSData *part) {
        fc[index] = [table length], lcb[index] = [part length];
        [table appendData:part];
    };
    NSData *stsh = stylesheet();
    place(1, stsh);
    fc[0] = fc[1], lcb[0] = lcb[1];
    NSMutableData *sed = [NSMutableData data];
    put32(sed, 0), put32(sed, (uint32_t)ccp);
    put16(sed, 0), put32(sed, 0xFFFFFFFF), put16(sed, 0), put32(sed, 0xFFFFFFFF);  /* no section properties */
    place(6, sed);
    place(12, chpBin);
    place(13, papBin);
    NSMutableData *clx = [NSMutableData data];
    put8(clx, 2), put32(clx, 16);
    put32(clx, 0), put32(clx, (uint32_t)ccp);
    put16(clx, 0), put32(clx, fcMin), put16(clx, 0);  /* one Unicode piece */
    place(33, clx);
    place(15, font_table(fonts));
    place(31, document_properties(docAttrs));
    /* the FIB */
    uint8_t *f = [wd mutableBytes];
    (void)f;
    set16(wd, 0x00, 0xA5EC);
    set16(wd, 0x02, 0x00C1);
    set16(wd, 0x0A, 0x12F0);  /* table stream 1Table, extended characters */
    set16(wd, 0x0C, 0x00BF);
    ((uint8_t *)[wd mutableBytes])[0x12] = 1;     /* written on a Mac */
    ((uint8_t *)[wd mutableBytes])[0x13] = 0x11;
    set16(wd, 0x14, 0x0100), set16(wd, 0x16, 0x0100);
    set32(wd, 0x18, fcMin), set32(wd, 0x1C, fcMin + 2 * (uint32_t)ccp);
    set16(wd, 0x20, 14);
    /* the creator's mark: Cocoa's, which Apple's reader reads as its own (not converted) */
    set16(wd, 0x22, CocoaMagic), set16(wd, 0x24, CocoaMagic);
    NSUInteger o = 0x22 + 28;
    set16(wd, o, 22);
    set32(wd, o + 2, cbMac);
    set32(wd, o + 2 + 4 * 3, (uint32_t)ccp);
    set32(wd, o + 2 + 4 * 11, 0xFFFFF), set32(wd, o + 2 + 4 * 14, 0xFFFFF), set32(wd, o + 2 + 4 * 17, 0xFFFFF);
    o += 2 + 88;
    set16(wd, o, 108);
    for (int i = 0; i < 108; i++)
        set32(wd, o + 2 + 8 * i, (uint32_t)fc[i]), set32(wd, o + 2 + 8 * i + 4, (uint32_t)lcb[i]);
    free(fc);
    free(lcb);
    /* the summary information */
    NSMutableDictionary *summary = [NSMutableDictionary dictionary], *docSummary = [NSMutableDictionary dictionary];
    NSDictionary *pids = @{NSTitleDocumentAttribute : @(PID_TITLE), NSSubjectDocumentAttribute : @(PID_SUBJECT),
                           NSAuthorDocumentAttribute : @(PID_AUTHOR), NSCommentDocumentAttribute : @(PID_COMMENTS),
                           NSEditorDocumentAttribute : @(PID_LASTAUTHOR)};
    for (NSString *k in pids)
        if ([docAttrs[k] isKindOfClass:[NSString class]] && [docAttrs[k] length])
            summary[pids[k]] = docAttrs[k];
    id keywords = docAttrs[NSKeywordsDocumentAttribute];
    if ([keywords isKindOfClass:[NSArray class]] && [keywords count])
        summary[@(PID_KEYWORDS)] = [keywords componentsJoinedByString:@", "];
    if ([docAttrs[NSCompanyDocumentAttribute] isKindOfClass:[NSString class]] && [docAttrs[NSCompanyDocumentAttribute] length])
        docSummary[@(PID_COMPANY)] = docAttrs[NSCompanyDocumentAttribute];
    if ([docAttrs[NSCopyrightDocumentAttribute] isKindOfClass:[NSString class]] && [docAttrs[NSCopyrightDocumentAttribute] length])
        docSummary[@(PID_COPYRIGHT)] = docAttrs[NSCopyrightDocumentAttribute];
    return cfb_file(@[ @"1Table", @"WordDocument", @"\005SummaryInformation", @"\005DocumentSummaryInformation" ],
                    @[ table, wd, property_set(SummaryFMTID, summary), property_set(DocSummaryFMTID, docSummary) ]);
}

#pragma mark - Reading

/* Properties as read: a run's and a paragraph's. */
typedef struct {
    int ftc;
    int hps;         /* half points */
    BOOL bold, italic, strike, dstrike, outline, shadow, vanish, caps, smallcaps, special;
    int kul;         /* underline */
    int iss;         /* 1 superscript, 2 subscript */
    int ico;         /* 0 auto */
    BOOL hasCv;
    uint8_t cv[3];
    int highlight;   /* ico */
    int dxaSpace;    /* kerning, twips */
    int hpsPos;      /* baseline, half points */
    int istd;        /* character style */
} Chp;

typedef struct {
    int jc;
    int dxaLeft, dxaLeft1, dxaRight;
    int dyaBefore, dyaAfter;
    int dyaLine;
    BOOL multLine;
    BOOL bidi, inTable, rowEnd;
    BOOL hasTabs;
    int ntabs;
    int tabPos[64];
    uint8_t tabType[64];
} Pap;

typedef struct {
    NSData *wd, *table;
    const uint8_t *w, *t;
    NSUInteger wlen, tlen;
    NSArray<NSString *> *fonts;
    /* the styles, resolved */
    NSUInteger nstyles;
    Chp *styleChp;
    Pap *stylePap;
    BOOL *styleIsChar;
    int defaultFtc;
    /* the piece-level property lists */
    NSMutableArray<NSData *> *prcs;
} Doc;

/* The operand size of a sprm at p (its code read), or -1. */
static long
sprm_operand(uint16_t op, const uint8_t *p, NSUInteger avail)
{
    switch (op >> 13) {
    case 0: case 1: return 1;
    case 2: case 4: case 5: return 2;
    case 3: return 4;
    case 7: return 3;
    default: break;
    }
    if (!avail)
        return -1;
    if (op == 0xD606 || op == 0xD608) {
        if (avail < 2)
            return -1;
        return 2 + rd16(p) - 1;
    }
    if (op == 0xC615 && p[0] == 255) {
        /* sprmPChgTabs: deletions with tolerances, then additions */
        NSUInteger at = 1;
        if (at >= avail)
            return -1;
        NSUInteger del = p[at];
        at += 1 + 4 * del;
        if (at >= avail)
            return -1;
        NSUInteger add = p[at];
        at += 1 + 3 * add;
        return (long)at;
    }
    return 1 + p[0];
}

/* Each sprm of a property list, to `apply`. */
static void
each_sprm(const uint8_t *g, NSUInteger len, void (^apply)(uint16_t op, const uint8_t *arg, NSUInteger argLen))
{
    NSUInteger i = 0;
    while (i + 2 <= len) {
        uint16_t op = rd16(g + i);
        i += 2;
        long n = sprm_operand(op, g + i, len - i);
        if (n < 0 || i + (NSUInteger)n > len)
            break;
        apply(op, g + i, (NSUInteger)n);
        i += (NSUInteger)n;
    }
}

static BOOL
toggle(uint8_t v, BOOL style)
{
    if (v == 0x80)
        return style;
    if (v == 0x81)
        return !style;
    return v != 0;
}

static void
apply_chp(Doc *doc, Chp *c, const uint8_t *g, NSUInteger len)
{
    each_sprm(g, len, ^(uint16_t op, const uint8_t *a, NSUInteger n) {
        Chp base = c->istd > 0 && (NSUInteger)c->istd < doc->nstyles ? doc->styleChp[c->istd] : *c;
        switch (op) {
        case 0x0835: c->bold = toggle(a[0], base.bold); break;
        case 0x0836: c->italic = toggle(a[0], base.italic); break;
        case 0x0837: c->strike = toggle(a[0], base.strike); break;
        case 0x0838: c->outline = toggle(a[0], base.outline); break;
        case 0x0839: c->shadow = toggle(a[0], base.shadow); break;
        case 0x083A: c->smallcaps = toggle(a[0], base.smallcaps); break;
        case 0x083B: c->caps = toggle(a[0], base.caps); break;
        case 0x083C: c->vanish = toggle(a[0], base.vanish); break;
        case 0x2A53: c->dstrike = toggle(a[0], base.dstrike); break;
        case 0x0855: c->special = a[0] != 0; break;
        case 0x2A3E: c->kul = a[0]; break;
        case 0x2A42: c->ico = a[0], c->hasCv = NO; break;
        case 0x6870:
            if (n >= 4 && a[3] != 0xFF)
                c->hasCv = YES, c->cv[0] = a[0], c->cv[1] = a[1], c->cv[2] = a[2];
            else
                c->hasCv = NO, c->ico = 0;  /* automatic */
            break;
        case 0x2A0C: c->highlight = a[0]; break;
        case 0x2A48: c->iss = a[0]; break;
        case 0x4A43: c->hps = rd16(a); break;
        case 0x4845: c->hpsPos = (int16_t)rd16(a); break;
        case 0x8840: c->dxaSpace = (int16_t)rd16(a); break;
        case 0x4A4F: c->ftc = rd16(a); break;
        case 0x4A30: {
            int s = rd16(a);
            if (s > 0 && (NSUInteger)s < doc->nstyles) {
                /* a character style: its properties under the run's own */
                Chp keep = *c;
                *c = doc->styleChp[s];
                c->ftc = keep.ftc != doc->styleChp[0].ftc ? keep.ftc : c->ftc;
                c->istd = s;
            }
            break;
        }
        default: break;
        }
    });
}

static void
apply_pap(Pap *p, const uint8_t *g, NSUInteger len)
{
    each_sprm(g, len, ^(uint16_t op, const uint8_t *a, NSUInteger n) {
        switch (op) {
        case 0x2403: case 0x2461: p->jc = a[0]; break;
        case 0x840F: case 0x845E: p->dxaLeft = (int16_t)rd16(a); break;
        case 0x840E: case 0x845D: p->dxaRight = (int16_t)rd16(a); break;
        case 0x8411: case 0x8460: p->dxaLeft1 = (int16_t)rd16(a); break;
        case 0xA413: p->dyaBefore = rd16(a); break;
        case 0xA414: p->dyaAfter = rd16(a); break;
        case 0x6412: p->dyaLine = (int16_t)rd16(a), p->multLine = rd16(a + 2) != 0; break;
        case 0x2441: p->bidi = a[0] != 0; break;
        case 0x2416: p->inTable = a[0] != 0; break;
        case 0x2417: p->rowEnd = a[0] != 0; break;
        case 0xC60D:
        case 0xC615: {
            /* tab stops: some deleted, some added */
            if (n < 1)
                break;
            NSUInteger at = 1;
            BOOL complex = op == 0xC615;
            NSUInteger del = at < n ? a[at++] : 0;
            for (NSUInteger k = 0; k < del && at + 2 <= n; k++) {
                int pos = (int16_t)rd16(a + at + 2 * k);
                for (int t = 0; t < p->ntabs; t++)
                    if (p->tabPos[t] == pos) {
                        memmove(p->tabPos + t, p->tabPos + t + 1, sizeof(int) * (p->ntabs - t - 1));
                        memmove(p->tabType + t, p->tabType + t + 1, p->ntabs - t - 1);
                        p->ntabs--;
                        break;
                    }
            }
            at += (complex ? 4 : 2) * del;
            NSUInteger add = at < n ? a[at++] : 0;
            for (NSUInteger k = 0; k < add && at + 2 * add + k < n + 1 && p->ntabs < 64; k++) {
                if (at + 2 * k + 2 > n)
                    break;
                int pos = (int16_t)rd16(a + at + 2 * k);
                uint8_t type = at + 2 * add + k < n ? a[at + 2 * add + k] & 7 : 0;
                int t = 0;
                while (t < p->ntabs && p->tabPos[t] < pos)
                    t++;
                if (t < p->ntabs && p->tabPos[t] == pos) {
                    p->tabType[t] = type;
                    continue;
                }
                memmove(p->tabPos + t + 1, p->tabPos + t, sizeof(int) * (p->ntabs - t));
                memmove(p->tabType + t + 1, p->tabType + t, p->ntabs - t);
                p->tabPos[t] = pos, p->tabType[t] = type;
                p->ntabs++;
            }
            p->hasTabs = YES;
            break;
        }
        default: break;
        }
    });
}

/* The stylesheet: each style's properties, its base's first. */
static void
read_styles(Doc *doc, uint32_t fc, uint32_t lcb)
{
    Chp defChp = {0};
    defChp.hps = 20, defChp.ftc = doc->defaultFtc;
    Pap defPap = {0};
    if (!lcb || (NSUInteger)fc + lcb > doc->tlen || lcb < 4) {
        doc->nstyles = 1;
        doc->styleChp = calloc(1, sizeof(Chp)), doc->stylePap = calloc(1, sizeof(Pap));
        doc->styleIsChar = calloc(1, sizeof(BOOL));
        doc->styleChp[0] = defChp, doc->stylePap[0] = defPap;
        return;
    }
    const uint8_t *s = doc->t + fc;
    NSUInteger cbStshi = rd16(s);
    if (cbStshi < 6 || 2 + cbStshi > lcb)
        cbStshi = 6;
    NSUInteger cstd = rd16(s + 2), cbBase = rd16(s + 4);
    if (cbStshi >= 18) {
        defChp.ftc = rd16(s + 2 + 12);  /* the standard font */
        doc->defaultFtc = defChp.ftc;
    }
    cstd = MIN(cstd, (NSUInteger)4096);
    doc->nstyles = MAX(cstd, (NSUInteger)1);
    doc->styleChp = calloc(doc->nstyles, sizeof(Chp));
    doc->stylePap = calloc(doc->nstyles, sizeof(Pap));
    doc->styleIsChar = calloc(doc->nstyles, sizeof(BOOL));
    const uint8_t **stds = calloc(doc->nstyles, sizeof(uint8_t *));
    NSUInteger *lens = calloc(doc->nstyles, sizeof(NSUInteger));
    NSUInteger at = 2 + cbStshi;
    for (NSUInteger i = 0; i < cstd && at + 2 <= lcb; i++) {
        NSUInteger cb = rd16(s + at);
        at += 2;
        if (cb && at + cb <= lcb)
            stds[i] = s + at, lens[i] = cb;
        at += cb;
    }
    int *done = calloc(doc->nstyles, sizeof(int));
    __block void (^resolve)(NSUInteger) = nil;
    void (^resolveBlock)(NSUInteger) = ^(NSUInteger i) {
        if (done[i])
            return;
        done[i] = 1;  /* (a loop of bases ends here) */
        Chp c = defChp;
        Pap p = defPap;
        const uint8_t *e = stds[i];
        NSUInteger len = lens[i];
        if (e && len >= 10 && cbBase <= len) {
            NSUInteger stk = rd16(e + 2) & 0xF, base = rd16(e + 2) >> 4, cupx = rd16(e + 4) & 0xF;
            doc->styleIsChar[i] = stk == 2;
            if (base < doc->nstyles && base != i) {
                resolve(base);
                c = doc->styleChp[base], p = doc->stylePap[base];
            }
            /* the name, then the UPXs */
            NSUInteger at2 = cbBase;
            if (at2 + 2 <= len) {
                NSUInteger cch = rd16(e + at2);
                at2 += 2 + 2 * (cch + 1);
            }
            for (NSUInteger u = 0; u < cupx && at2 + 2 <= len; u++) {
                if (at2 & 1)
                    at2++;
                NSUInteger cbu = rd16(e + at2);
                at2 += 2;
                if (at2 + cbu > len)
                    break;
                const uint8_t *upx = e + at2;
                if (stk == 1 && u == 0) {
                    if (cbu >= 2)
                        apply_pap(&p, upx + 2, cbu - 2);
                } else if ((stk == 1 && u == 1) || (stk == 2 && u == 0)) {
                    Chp keep = c;
                    keep.istd = 0;
                    c = keep;
                    apply_chp(doc, &c, upx, cbu);
                }
                at2 += cbu;
            }
        }
        doc->styleChp[i] = c, doc->stylePap[i] = p;
    };
    resolve = resolveBlock;
    for (NSUInteger i = 0; i < cstd; i++)
        resolve(i);
    if (!cstd)
        doc->styleChp[0] = defChp, doc->stylePap[0] = defPap;
    free(done);
    free(stds);
    free(lens);
}

static NSArray<NSString *> *
read_fonts(Doc *doc, uint32_t fc, uint32_t lcb)
{
    NSMutableArray *out = [NSMutableArray array];
    if (!lcb || (NSUInteger)fc + lcb > doc->tlen || lcb < 4)
        return out;
    const uint8_t *s = doc->t + fc;
    NSUInteger count = rd16(s), at = 4;
    if (count == 0xFFFF)
        count = rd16(s + 2), at = 6;  /* (extended: a 2-byte count follows) */
    for (NSUInteger i = 0; i < count && at < lcb; i++) {
        NSUInteger cb = (NSUInteger)s[at] + 1;
        if (at + cb > lcb)
            break;
        const uint8_t *ffn = s + at + 1;
        NSUInteger nameAt = 39, nameMax = cb - 1;
        NSMutableString *name = [NSMutableString string];
        for (NSUInteger k = nameAt; k + 2 <= nameMax; k += 2) {
            unichar c = rd16(ffn + k);
            if (!c)
                break;
            [name appendFormat:@"%C", c];
        }
        [out addObject:name];
        at += cb;
    }
    return out;
}

typedef struct {
    uint32_t cpStart, cpEnd, fc;
    BOOL compressed;
    uint16_t prm;
} Piece;

/* The FKP runs of a bin table: each run's fc range and property bytes. */
typedef struct {
    uint32_t fcStart, fcEnd;
    const uint8_t *g;
    NSUInteger len;
    uint16_t istd;
} PropRun;

static NSUInteger
read_bin(Doc *doc, uint32_t fc, uint32_t lcb, BOOL paragraphs, PropRun **out)
{
    *out = NULL;
    if (lcb < 12 || (NSUInteger)fc + lcb > doc->tlen)
        return 0;
    const uint8_t *plc = doc->t + fc;
    NSUInteger n = (lcb - 4) / 8;
    NSMutableData *runs = [NSMutableData data];
    for (NSUInteger i = 0; i < n; i++) {
        uint32_t pn = rd32(plc + 4 * (n + 1) + 4 * i) & 0x3FFFFF;
        if ((NSUInteger)(pn + 1) * 512 > doc->wlen)
            continue;
        const uint8_t *page = doc->w + (NSUInteger)pn * 512;
        NSUInteger crun = page[511];
        if (4 * (crun + 1) + (paragraphs ? 13 : 1) * crun > 511)
            continue;
        for (NSUInteger k = 0; k < crun; k++) {
            PropRun r = {rd32(page + 4 * k), rd32(page + 4 * (k + 1)), NULL, 0, 0};
            NSUInteger off = 2 * (NSUInteger)page[4 * (crun + 1) + (paragraphs ? 13 : 1) * k];
            if (off && off < 511) {
                if (paragraphs) {
                    NSUInteger cb = page[off], len, start;
                    if (cb)
                        len = 2 * cb - 1, start = off + 1;
                    else
                        len = 2 * (NSUInteger)page[off + 1], start = off + 2;
                    if (start + len <= 511 && len >= 2) {
                        r.istd = rd16(page + start);
                        r.g = page + start + 2, r.len = len - 2;
                    }
                } else {
                    NSUInteger len = page[off];
                    if (off + 1 + len <= 511)
                        r.g = page + off + 1, r.len = len;
                }
            }
            [runs appendBytes:&r length:sizeof r];
        }
    }
    NSUInteger count = [runs length] / sizeof(PropRun);
    *out = malloc([runs length] + sizeof(PropRun));
    memcpy(*out, [runs bytes], [runs length]);
    return count;
}

static const PropRun *
run_at(const PropRun *runs, NSUInteger n, uint32_t fc)
{
    NSUInteger lo = 0, hi = n;
    while (lo < hi) {
        NSUInteger mid = (lo + hi) / 2;
        if (fc < runs[mid].fcStart)
            hi = mid;
        else if (fc >= runs[mid].fcEnd)
            lo = mid + 1;
        else
            return runs + mid;
    }
    return NULL;
}

/* cp1252 for an 8-bit piece's 0x80–0x9F, as Word maps them */
static const unichar Cp1252High[32] = {
    0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
    0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
};

static NSDictionary *
run_attributes(Doc *doc, Chp c, Pap p, CGFloat defaultTab)
{
    NSMutableDictionary *a = [NSMutableDictionary dictionary];
    NSString *family = c.ftc >= 0 && (NSUInteger)c.ftc < [doc->fonts count] ? doc->fonts[c.ftc] : nil;
    a[NSFontAttributeName] = UIFImportFont([family length] ? family : @"Times New Roman", c.hps > 0 ? c.hps / 2.0 : 10,
                                           c.bold, c.italic);
    if (c.kul) {
        NSInteger u = NSUnderlineStyleSingle;
        if (c.kul == 2)
            u = NSUnderlineStyleSingle | NSUnderlineByWord;
        else if (c.kul == 3)
            u = NSUnderlineStyleDouble;
        else if (c.kul == 6)
            u = NSUnderlineStyleThick;
        else if (c.kul == 4)
            u = NSUnderlineStyleSingle | NSUnderlinePatternDot;
        a[NSUnderlineStyleAttributeName] = @(u);
    }
    if (c.strike)
        a[NSStrikethroughStyleAttributeName] = @(NSUnderlineStyleSingle);
    else if (c.dstrike)
        a[NSStrikethroughStyleAttributeName] = @(NSUnderlineStyleDouble);
    if (c.outline)
        a[NSStrokeWidthAttributeName] = @3;
    if (c.iss == 1)
        a[NSSuperscriptAttributeName] = @1;
    else if (c.iss == 2)
        a[NSSuperscriptAttributeName] = @-1;
    if (c.hasCv)
        a[NSForegroundColorAttributeName] = calibrated(c.cv[0], c.cv[1], c.cv[2]);
    else if (c.ico > 0 && c.ico <= 16)
        a[NSForegroundColorAttributeName] = calibrated(IcoRGB[c.ico][0], IcoRGB[c.ico][1], IcoRGB[c.ico][2]);
    if (c.highlight > 0 && c.highlight <= 16)
        a[NSBackgroundColorAttributeName] = calibrated(IcoRGB[c.highlight][0], IcoRGB[c.highlight][1], IcoRGB[c.highlight][2]);
    if (c.dxaSpace)
        a[NSKernAttributeName] = @(c.dxaSpace / 20.0);
    if (c.hpsPos)
        a[NSBaselineOffsetAttributeName] = @(c.hpsPos / 2.0);
    NSMutableParagraphStyle *ps = [[[NSMutableParagraphStyle alloc] init] autorelease];
    switch (p.jc) {
    case 1: [ps setAlignment:NSTextAlignmentCenter]; break;
    case 2: [ps setAlignment:NSTextAlignmentRight]; break;
    case 3: case 4: case 5: [ps setAlignment:NSTextAlignmentJustified]; break;
    default: break;
    }
    [ps setHeadIndent:p.dxaLeft / 20.0];
    [ps setFirstLineHeadIndent:(p.dxaLeft + p.dxaLeft1) / 20.0];
    if (p.dxaRight)
        [ps setTailIndent:-p.dxaRight / 20.0];
    [ps setParagraphSpacingBefore:p.dyaBefore / 20.0];
    [ps setParagraphSpacing:p.dyaAfter / 20.0];
    if (p.multLine) {
        if (p.dyaLine > 0 && p.dyaLine != 240)
            [ps setLineHeightMultiple:p.dyaLine / 240.0];
    } else if (p.dyaLine < 0) {
        [ps setMinimumLineHeight:-p.dyaLine / 20.0];
        [ps setMaximumLineHeight:-p.dyaLine / 20.0];
    } else if (p.dyaLine > 0) {
        [ps setMinimumLineHeight:p.dyaLine / 20.0];
    }
    if (p.bidi)
        [ps setBaseWritingDirection:NSWritingDirectionRightToLeft];
    if (p.hasTabs) {
        NSMutableArray *tabs = [NSMutableArray array];
        for (int t = 0; t < p.ntabs; t++) {
            CGFloat loc = p.tabPos[t] / 20.0;
            NSTextTab *tab;
            if (p.tabType[t] == 3)
                tab = [[[NSTextTab alloc] initWithType:NSDecimalTabStopType location:loc] autorelease];
            else if (p.tabType[t] == 1)
                tab = [[[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentCenter location:loc options:@{}] autorelease];
            else if (p.tabType[t] == 2)
                tab = [[[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentRight location:loc options:@{}] autorelease];
            else
                tab = [[[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentLeft location:loc options:@{}] autorelease];
            [tabs addObject:tab];
        }
        [ps setTabStops:tabs];
    } else {
        [ps setTabStops:@[]];  /* as Apple's reader: none, rather than the default stops */
    }
    [ps setDefaultTabInterval:defaultTab];
    a[NSParagraphStyleAttributeName] = ps;
    return a;
}

static Pap
pap_for(Doc *doc, const PropRun *r)
{
    NSUInteger istd = r ? r->istd : 0;
    Pap p = istd < doc->nstyles ? doc->stylePap[istd] : doc->stylePap[0];
    if (r && r->g)
        apply_pap(&p, r->g, r->len);
    return p;
}

static void
apply_prm(Doc *doc, uint16_t prm, Chp *c, Pap *p)
{
    if (!prm)
        return;
    if (prm & 1) {
        NSUInteger i = prm >> 1;
        if (i < [doc->prcs count]) {
            NSData *g = doc->prcs[i];
            if (c)
                apply_chp(doc, c, [g bytes], [g length]);
            if (p)
                apply_pap(p, [g bytes], [g length]);
        }
    }
}

UIF_HIDDEN BOOL
UIFIsWordDocument(NSData *data)
{
    static const uint8_t magic[8] = {0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1};
    if ([data length] < 512 || memcmp([data bytes], magic, 8))
        return NO;
    NSDictionary *streams = cfb_streams(data);
    NSData *wd = streams[@"WordDocument"];
    return [wd length] >= 32 && rd16([wd bytes]) == 0xA5EC;
}

UIF_HIDDEN NSAttributedString *
UIFReadWordDocument(NSData *data, NSDictionary **docAttrs)
{
    NSDictionary *streams = cfb_streams(data);
    NSData *wd = streams[@"WordDocument"];
    if ([wd length] < 0x200)
        return nil;
    const uint8_t *w = [wd bytes];
    uint16_t nFib = rd16(w + 2), flags = rd16(w + 0x0A);
    if (rd16(w) != 0xA5EC || nFib < 101 || (flags & 0x0100))  /* not Word 97 or later, or encrypted */
        return nil;
    NSData *table = streams[(flags & 0x0200) ? @"1Table" : @"0Table"];
    if (!table)
        return nil;
    Doc doc = {0};
    doc.wd = wd, doc.table = table;
    doc.w = w, doc.wlen = [wd length];
    doc.t = [table bytes], doc.tlen = [table length];
    NSUInteger csw = rd16(w + 0x20);
    NSUInteger o = 0x22 + 2 * csw;
    if (o + 2 > doc.wlen)
        return nil;
    NSUInteger cslw = rd16(w + o);
    if (o + 2 + 4 * cslw > doc.wlen || cslw < 4)
        return nil;
    uint32_t ccpText = rd32(w + o + 2 + 12);
    o += 2 + 4 * cslw;
    NSUInteger cbRgFcLcb = rd16(w + o);
    const uint8_t *pairs = w + o + 2;
    if (o + 2 + 8 * cbRgFcLcb > doc.wlen || cbRgFcLcb < 34)
        return nil;
    uint32_t (^fcOf)(int) = ^uint32_t(int i) { return rd32(pairs + 8 * i); };
    uint32_t (^lcbOf)(int) = ^uint32_t(int i) { return rd32(pairs + 8 * i + 4); };
    doc.fonts = read_fonts(&doc, fcOf(15), lcbOf(15));
    read_styles(&doc, fcOf(1), lcbOf(1));
    /* the piece table, after any property lists */
    NSMutableData *piecesData = [NSMutableData data];
    doc.prcs = [NSMutableArray array];
    uint32_t clxFc = fcOf(33), clxLcb = lcbOf(33);
    if ((NSUInteger)clxFc + clxLcb <= doc.tlen) {
        const uint8_t *c = doc.t + clxFc;
        NSUInteger at = 0;
        while (at < clxLcb && c[at] == 1) {
            if (at + 3 > clxLcb)
                break;
            NSUInteger cb = rd16(c + at + 1);
            if (at + 3 + cb > clxLcb)
                break;
            [doc.prcs addObject:[NSData dataWithBytes:c + at + 3 length:cb]];
            at += 3 + cb;
        }
        if (at + 5 <= clxLcb && c[at] == 2) {
            uint32_t lcb = rd32(c + at + 1);
            const uint8_t *plc = c + at + 5;
            if (at + 5 + lcb <= clxLcb && lcb >= 16) {
                NSUInteger n = (lcb - 4) / 12;
                for (NSUInteger i = 0; i < n; i++) {
                    const uint8_t *pcd = plc + 4 * (n + 1) + 8 * i;
                    uint32_t fc = rd32(pcd + 2);
                    Piece piece = {rd32(plc + 4 * i), rd32(plc + 4 * (i + 1)), fc & 0x3FFFFFFF, (fc & 0x40000000) != 0,
                                   rd16(pcd + 6)};
                    if (piece.compressed)
                        piece.fc /= 2;
                    [piecesData appendBytes:&piece length:sizeof piece];
                }
            }
        }
    }
    const Piece *pieces = [piecesData bytes];
    NSUInteger npieces = [piecesData length] / sizeof(Piece);
    if (!npieces) {
        /* (no piece table: the text from fcMin, as the FIB says) */
        Piece p = {0, ccpText, rd32(w + 0x18), !(flags & 0x1000), 0};
        [piecesData appendBytes:&p length:sizeof p];
        pieces = [piecesData bytes];
        npieces = 1;
    }
    PropRun *chpRuns = NULL, *papRuns = NULL;
    NSUInteger nchp = read_bin(&doc, fcOf(12), lcbOf(12), NO, &chpRuns);
    NSUInteger npap = read_bin(&doc, fcOf(13), lcbOf(13), YES, &papRuns);
    /* the default tab interval and view, from the document's properties */
    CGFloat defaultTab = 36;
    NSInteger viewMode = 0;
    NSDate *created = nil, *modified = nil;
    uint32_t dopFc = fcOf(31), dopLcb = lcbOf(31);
    if (dopLcb >= 0x54 && (NSUInteger)dopFc + dopLcb <= doc.tlen) {
        const uint8_t *dop = doc.t + dopFc;
        if (rd16(dop + 0x0A))
            defaultTab = rd16(dop + 0x0A) / 20.0;
        created = date_of_dttm(rd32(dop + 0x14));
        modified = date_of_dttm(rd32(dop + 0x18));
        if ((dop[0x52] & 7) == 1)
            viewMode = 1;
    }
    /* the text: each character of the main document's pieces, with its run's and its
       paragraph's properties */
    NSMutableAttributedString *out = [[[NSMutableAttributedString alloc] init] autorelease];
    NSMutableString *pending = [NSMutableString string];
    __block NSDictionary *pendingAttrs = nil;
    void (^flush)(void) = ^{
        if ([pending length])
            [out appendAttributedString:[[[NSAttributedString alloc] initWithString:pending attributes:pendingAttrs] autorelease]];
        [pending setString:@""];
    };
    /* fields: the instructions skipped, the result kept (a link for HYPERLINK) */
    NSMutableArray *fieldStack = [NSMutableArray array];  /* per open field: @{instr, inResult, start} */
    NSUInteger paraStartOut = 0;
    Pap paraPap = {0};
    BOOL havePara = NO;
    for (NSUInteger pi = 0; pi < npieces; pi++) {
        Piece pc = pieces[pi];
        uint32_t cpEnd = MIN(pc.cpEnd, ccpText);
        for (uint32_t cp = pc.cpStart; cp < cpEnd; cp++) {
            uint32_t fc = pc.compressed ? pc.fc + (cp - pc.cpStart) : pc.fc + 2 * (cp - pc.cpStart);
            unichar ch;
            if (pc.compressed) {
                if (fc >= doc.wlen)
                    break;
                uint8_t b = w[fc];
                ch = b >= 0x80 && b < 0xA0 ? Cp1252High[b - 0x80] : b;
            } else {
                if ((NSUInteger)fc + 2 > doc.wlen)
                    break;
                ch = rd16(w + fc);
            }
            /* the paragraph's properties, from its mark */
            if (!havePara) {
                uint32_t markFc = fc;
                for (NSUInteger pj = pi; pj < npieces; pj++) {
                    Piece q = pieces[pj];
                    uint32_t from = pj == pi ? cp : q.cpStart, to = MIN(q.cpEnd, ccpText);
                    BOOL found = NO;
                    for (uint32_t c2 = from; c2 < to; c2++) {
                        uint32_t f2 = q.compressed ? q.fc + (c2 - q.cpStart) : q.fc + 2 * (c2 - q.cpStart);
                        unichar u = q.compressed ? (f2 < doc.wlen ? w[f2] : 0x0D) : ((NSUInteger)f2 + 2 <= doc.wlen ? rd16(w + f2) : 0x0D);
                        if (u == 0x0D || (u == 0x07 && 0)) {
                            markFc = f2;
                            found = YES;
                            break;
                        }
                    }
                    if (found)
                        break;
                }
                paraPap = pap_for(&doc, run_at(papRuns, npap, markFc));
                apply_prm(&doc, pc.prm, NULL, &paraPap);
                havePara = YES;
            }
            const PropRun *cr = run_at(chpRuns, nchp, fc);
            NSUInteger pistd = 0;
            {
                const PropRun *pr = run_at(papRuns, npap, fc);
                pistd = pr ? pr->istd : 0;
            }
            Chp c = pistd < doc.nstyles ? doc.styleChp[pistd] : doc.styleChp[0];
            c.istd = 0;
            if (cr && cr->g)
                apply_chp(&doc, &c, cr->g, cr->len);
            apply_prm(&doc, pc.prm, &c, NULL);
            /* fields */
            if (c.special || ch == 0x13 || ch == 0x14 || ch == 0x15) {
                if (ch == 0x13) {
                    flush();
                    [fieldStack addObject:[NSMutableDictionary dictionaryWithDictionary:@{
                                    @"instr" : [NSMutableString string], @"result" : @NO, @"start" : @([out length])}]];
                    continue;
                }
                if (ch == 0x14 && [fieldStack count]) {
                    [fieldStack lastObject][@"result"] = @YES;
                    [fieldStack lastObject][@"start"] = @([out length] + [pending length]);
                    continue;
                }
                if (ch == 0x15 && [fieldStack count]) {
                    flush();
                    NSMutableDictionary *f = [fieldStack lastObject];
                    NSString *instr = [f[@"instr"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    NSUInteger start = [f[@"start"] unsignedIntegerValue];
                    if ([f[@"result"] boolValue] && [[instr uppercaseString] hasPrefix:@"HYPERLINK"] && [out length] > start) {
                        NSRange q1 = [instr rangeOfString:@"\""];
                        NSString *target = nil;
                        if (q1.location != NSNotFound) {
                            NSRange q2 = [instr rangeOfString:@"\"" options:0
                                                        range:NSMakeRange(NSMaxRange(q1), [instr length] - NSMaxRange(q1))];
                            if (q2.location != NSNotFound)
                                target = [instr substringWithRange:NSMakeRange(NSMaxRange(q1), q2.location - NSMaxRange(q1))];
                        }
                        NSURL *url = [target length] ? [NSURL URLWithString:target] : nil;
                        if (url)
                            [out addAttribute:NSLinkAttributeName value:url range:NSMakeRange(start, [out length] - start)];
                    }
                    [fieldStack removeLastObject];
                    continue;
                }
                if (c.special && ch != 0x13 && ch != 0x14 && ch != 0x15)
                    continue;  /* pictures, notes' references, drawn objects */
            }
            if ([fieldStack count] && ![[fieldStack lastObject][@"result"] boolValue]) {
                [[fieldStack lastObject][@"instr"] appendFormat:@"%C", ch];
                continue;
            }
            if (c.vanish && ch != 0x0D)
                continue;
            NSString *piece = nil;
            switch (ch) {
            case 0x0D: piece = @"\n"; break;
            case 0x0B: piece = @" "; break;
            case 0x0C: piece = @""; break;  /* (page and section breaks: as Apple's reader, dropped) */
            case 0x07: piece = paraPap.inTable ? @"\t" : @""; break;
            case 0x1E: piece = @"‑"; break;
            case 0x1F: piece = @"­"; break;
            case 0x01: case 0x08: case 0x02: case 0x05: piece = @""; break;
            default: piece = [NSString stringWithCharacters:&ch length:1]; break;
            }
            NSDictionary *attrs = run_attributes(&doc, c, paraPap, defaultTab);
            if (![attrs isEqualToDictionary:pendingAttrs]) {
                flush();
                pendingAttrs = attrs;
            }
            [pending appendString:piece];
            if (ch == 0x0D || (ch == 0x07 && paraPap.inTable && paraPap.rowEnd)) {
                flush();
                (void)paraStartOut;
                paraStartOut = [out length];
                havePara = NO;
            }
        }
    }
    flush();
    free(chpRuns);
    free(papRuns);
    free(doc.styleChp);
    free(doc.stylePap);
    free(doc.styleIsChar);
    /* the document's attributes: Word's page and margins unless the first section has
       its own, and the summary information */
    if (docAttrs) {
        CGFloat pageW = 612, pageH = 792, left = 90, right = 90, top = 72, bottom = 72;
        uint32_t sedFc = fcOf(6), sedLcb = lcbOf(6);
        if (sedLcb >= 16 && (NSUInteger)sedFc + sedLcb <= doc.tlen) {
            uint32_t fcSepx = rd32(doc.t + sedFc + 8 + 2);
            if (fcSepx != 0xFFFFFFFF && (NSUInteger)fcSepx + 2 <= doc.wlen) {
                NSUInteger cb = rd16(w + fcSepx);
                if (fcSepx + 2 + cb <= doc.wlen)
                    each_sprm(w + fcSepx + 2, cb, ^(uint16_t op, const uint8_t *a, NSUInteger n) {});
                __block CGFloat pw = pageW, ph = pageH, l = left, r = right, t = top, b = bottom;
                if (fcSepx + 2 + cb <= doc.wlen)
                    each_sprm(w + fcSepx + 2, cb, ^(uint16_t op, const uint8_t *a, NSUInteger n) {
                        switch (op) {
                        case 0xB01F: pw = rd16(a) / 20.0; break;
                        case 0xB020: ph = rd16(a) / 20.0; break;
                        case 0xB021: l = rd16(a) / 20.0; break;
                        case 0xB022: r = rd16(a) / 20.0; break;
                        case 0x9023: t = abs((int16_t)rd16(a)) / 20.0; break;
                        case 0x9024: b = abs((int16_t)rd16(a)) / 20.0; break;
                        default: break;
                        }
                    });
                pageW = pw, pageH = ph, left = l, right = r, top = t, bottom = b;
            }
        }
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[NSDocumentTypeDocumentAttribute] = NSDocFormatTextDocumentType;
        d[@"UTI"] = @"com.microsoft.word.doc";
        d[NSPaperSizeDocumentAttribute] = [NSValue valueWithSize:NSMakeSize(pageW, pageH)];
        d[NSLeftMarginDocumentAttribute] = @(left);
        d[NSRightMarginDocumentAttribute] = @(right);
        d[NSTopMarginDocumentAttribute] = @(top);
        d[NSBottomMarginDocumentAttribute] = @(bottom);
        d[NSDefaultTabIntervalDocumentAttribute] = @(defaultTab);
        if (viewMode)
            d[NSViewModeDocumentAttribute] = @(viewMode);
        /* as Apple's: a document another app wrote is a conversion */
        if (rd16(w + 0x22) != CocoaMagic)
            d[NSConvertedDocumentAttribute] = @-1;
        NSDictionary *summary = read_property_set(streams[@"\005SummaryInformation"]);
        NSDictionary *docSummary = read_property_set(streams[@"\005DocumentSummaryInformation"]);
        NSDictionary *keys = @{@(PID_TITLE) : NSTitleDocumentAttribute, @(PID_SUBJECT) : NSSubjectDocumentAttribute,
                               @(PID_AUTHOR) : NSAuthorDocumentAttribute, @(PID_COMMENTS) : NSCommentDocumentAttribute,
                               @(PID_LASTAUTHOR) : NSEditorDocumentAttribute};
        for (NSNumber *pid in keys)
            if ([summary[pid] isKindOfClass:[NSString class]] && [summary[pid] length])
                d[keys[pid]] = summary[pid];
        if ([summary[@(PID_KEYWORDS)] isKindOfClass:[NSString class]] && [summary[@(PID_KEYWORDS)] length])
            d[NSKeywordsDocumentAttribute] = [summary[@(PID_KEYWORDS)] componentsSeparatedByString:@", "];
        if ([docSummary[@(PID_COMPANY)] isKindOfClass:[NSString class]] && [docSummary[@(PID_COMPANY)] length])
            d[NSCompanyDocumentAttribute] = docSummary[@(PID_COMPANY)];
        if ([docSummary[@(PID_COPYRIGHT)] isKindOfClass:[NSString class]] && [docSummary[@(PID_COPYRIGHT)] length])
            d[NSCopyrightDocumentAttribute] = docSummary[@(PID_COPYRIGHT)];
        NSDate *c = [summary[@(PID_CREATE_DTM)] isKindOfClass:[NSDate class]] ? summary[@(PID_CREATE_DTM)] : created;
        NSDate *m = [summary[@(PID_LASTSAVE_DTM)] isKindOfClass:[NSDate class]] ? summary[@(PID_LASTSAVE_DTM)] : modified;
        if (c)
            d[NSCreationTimeDocumentAttribute] = c;
        if (m)
            d[NSModificationTimeDocumentAttribute] = m;
        *docAttrs = d;
    }
    return out;
}
