// SPDX-License-Identifier: MIT OR Apache-2.0
#import <CryptoTokenKit/CryptoTokenKit.h>
#import <objc/runtime.h>
#include <limits.h>

static char TKTLVTagKey;
static char TKTLVValueKey;
static char TKTLVDataKey;

@interface TKTLVRecord (FinchInternal)
- (instancetype)_initWithTag:(TKTLVTag)tag value:(NSData *)value data:(NSData *)data;
@end

static NSData *TKEncodeBERTag(TKTLVTag tag)
{
    uint8_t bytes[8];
    NSUInteger count = 0;
    do {
        bytes[7 - count] = (uint8_t)(tag & 0xff);
        tag >>= 8;
        count++;
    } while (tag && count < sizeof(bytes));
    return [NSData dataWithBytes:bytes + 8 - count length:count];
}

static NSData *TKEncodeBERLength(NSUInteger length)
{
    if (length <= 127) {
        uint8_t byte = (uint8_t)length;
        return [NSData dataWithBytes:&byte length:1];
    }
    uint8_t bytes[sizeof(NSUInteger) + 1];
    NSUInteger count = 0, value = length;
    while (value) {
        bytes[sizeof(bytes) - 1 - count] = (uint8_t)(value & 0xff);
        value >>= 8;
        count++;
    }
    if (count > 126) return nil;
    bytes[sizeof(bytes) - 1 - count] = (uint8_t)(0x80 | count);
    return [NSData dataWithBytes:bytes + sizeof(bytes) - 1 - count length:count + 1];
}

static BOOL TKReadBERRecord(const uint8_t *bytes, NSUInteger length, NSUInteger *offset,
    TKTLVTag *tag, NSData **value)
{
    NSUInteger start = *offset;
    if (start >= length) return NO;
    NSUInteger pos = start;
    uint8_t first = bytes[pos++];
    TKTLVTag parsedTag = first;
    if ((first & 0x1f) == 0x1f) {
        BOOL terminated = NO;
        while (pos < length && pos - start < 8) {
            uint8_t next = bytes[pos++];
            if (pos - start == 2 && (next & 0x7f) == 0) return NO;
            if (parsedTag > (UINT64_MAX >> 8)) return NO;
            parsedTag = (parsedTag << 8) | next;
            if (!(next & 0x80)) { terminated = YES; break; }
        }
        if (!terminated) return NO;
    }
    if (pos >= length) return NO;
    uint8_t lengthByte = bytes[pos++];
    NSUInteger valueLength = 0;
    if (!(lengthByte & 0x80)) valueLength = lengthByte;
    else {
        NSUInteger count = lengthByte & 0x7f;
        if (count == 0 || count > sizeof(NSUInteger) || count > length - pos) return NO;
        if (bytes[pos] == 0) return NO;
        for (NSUInteger i = 0; i < count; i++) {
            if (valueLength > (NSUIntegerMax >> 8)) return NO;
            valueLength = (valueLength << 8) | bytes[pos++];
        }
        if (valueLength < 128) return NO;
    }
    if (valueLength > length - pos) return NO;
    *tag = parsedTag;
    *value = [NSData dataWithBytes:bytes + pos length:valueLength];
    *offset = pos + valueLength;
    return YES;
}

@implementation TKTLVRecord

- (instancetype)_initWithTag:(TKTLVTag)tag value:(NSData *)value data:(NSData *)data
{
    self = [super init];
    if (self) {
        objc_setAssociatedObject(self, &TKTLVTagKey, [NSNumber numberWithUnsignedLongLong:tag], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, &TKTLVValueKey, [value copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, &TKTLVDataKey, [data copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return self;
}

- (TKTLVTag)tag { return [objc_getAssociatedObject(self, &TKTLVTagKey) unsignedLongLongValue]; }
- (NSData *)value { return objc_getAssociatedObject(self, &TKTLVValueKey); }
- (NSData *)data { return objc_getAssociatedObject(self, &TKTLVDataKey); }

+ (instancetype)recordFromData:(NSData *)data
{
    if (![data isKindOfClass:[NSData class]] || data.length == 0) return nil;
    NSUInteger offset = 0;
    TKTLVTag tag = 0;
    NSData *value = nil;
    if (!TKReadBERRecord(data.bytes, data.length, &offset, &tag, &value) || offset != data.length) return nil;
    return [[[TKBERTLVRecord alloc] _initWithTag:tag value:value data:data] autorelease];
}

+ (NSArray<TKTLVRecord *> *)sequenceOfRecordsFromData:(NSData *)data
{
    if (![data isKindOfClass:[NSData class]]) return nil;
    NSMutableArray *records = [NSMutableArray array];
    NSUInteger offset = 0;
    while (offset < data.length) {
        NSUInteger start = offset;
        TKTLVTag tag = 0;
        NSData *value = nil;
        if (!TKReadBERRecord(data.bytes, data.length, &offset, &tag, &value)) return nil;
        NSData *encoded = [data subdataWithRange:NSMakeRange(start, offset - start)];
        [records addObject:[[[TKBERTLVRecord alloc] _initWithTag:tag value:value data:encoded] autorelease]];
    }
    return records;
}

@end

@implementation TKBERTLVRecord

+ (NSData *)dataForTag:(TKTLVTag)tag
{
    if (!tag) return nil;
    NSData *data = TKEncodeBERTag(tag);
    const uint8_t *bytes = data.bytes;
    if (data.length > 1 && (bytes[0] & 0x1f) != 0x1f) return nil;
    if (data.length > 1) {
        for (NSUInteger i = 1; i + 1 < data.length; i++)
            if (!(bytes[i] & 0x80)) return nil;
        if (bytes[data.length - 1] & 0x80) return nil;
    }
    return data;
}

- (instancetype)initWithTag:(TKTLVTag)tag value:(NSData *)value
{
    if (![value isKindOfClass:[NSData class]]) [NSException raise:NSInvalidArgumentException format:@"A TLV value must be NSData"];
    NSData *tagData = [[self class] dataForTag:tag];
    NSData *lengthData = TKEncodeBERLength(value.length);
    if (!tagData || !lengthData) [NSException raise:NSInvalidArgumentException format:@"The BER tag or value length is out of range"];
    NSMutableData *data = [NSMutableData dataWithData:tagData];
    [data appendData:lengthData];
    [data appendData:value];
    return [super _initWithTag:tag value:value data:data];
}

- (instancetype)initWithTag:(TKTLVTag)tag records:(NSArray<TKTLVRecord *> *)records
{
    NSMutableData *value = [NSMutableData data];
    for (id record in records) {
        if (![record isKindOfClass:[TKTLVRecord class]])
            [NSException raise:NSInvalidArgumentException format:@"Subrecords must be TKTLVRecord objects"];
        [value appendData:[record data]];
    }
    return [self initWithTag:tag value:value];
}

@end

@implementation TKSimpleTLVRecord

- (instancetype)initWithTag:(UInt8)tag value:(NSData *)value
{
    if (tag == 0 || tag == 0xff || ![value isKindOfClass:[NSData class]] || value.length > UINT16_MAX)
        [NSException raise:NSInvalidArgumentException format:@"Simple TLV needs a tag from 1 through 254 and at most 65535 value bytes"];
    NSMutableData *data = [NSMutableData data];
    uint8_t header[4] = {tag, 0, 0, 0};
    NSUInteger headerLength = value.length <= 254 ? 2 : 4;
    if (headerLength == 2) header[1] = (uint8_t)value.length;
    else {
        header[1] = 0xff;
        header[2] = (uint8_t)(value.length >> 8);
        header[3] = (uint8_t)value.length;
    }
    [data appendBytes:header length:headerLength];
    [data appendData:value];
    return [super _initWithTag:tag value:value data:data];
}

@end

@implementation TKCompactTLVRecord

- (instancetype)initWithTag:(UInt8)tag value:(NSData *)value
{
    if (tag > 15 || ![value isKindOfClass:[NSData class]] || value.length > 15)
        [NSException raise:NSInvalidArgumentException format:@"Compact TLV tag and value length must fit four bits"];
    uint8_t header = (uint8_t)((tag << 4) | value.length);
    NSMutableData *data = [NSMutableData dataWithBytes:&header length:1];
    [data appendData:value];
    return [super _initWithTag:tag value:value data:data];
}

@end
