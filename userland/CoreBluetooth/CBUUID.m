// SPDX-License-Identifier: MIT OR Apache-2.0
#import "CBInternal.h"
#import <CoreFoundation/CoreFoundation.h>
#include <ctype.h>
#include <stdint.h>

NSString * const CBUUIDCharacteristicExtendedPropertiesString = @"2900";
NSString * const CBUUIDCharacteristicUserDescriptionString = @"2901";
NSString * const CBUUIDClientCharacteristicConfigurationString = @"2902";
NSString * const CBUUIDServerCharacteristicConfigurationString = @"2903";
NSString * const CBUUIDCharacteristicFormatString = @"2904";
NSString * const CBUUIDCharacteristicAggregateFormatString = @"2905";
NSString * const CBUUIDCharacteristicValidRangeString = @"2906";
NSString * const CBUUIDCharacteristicObservationScheduleString = @"2907";
NSString * const CBUUIDL2CAPPSMCharacteristicString = @"2AFA";

static char CBUUIDDataKey;

static NSData *CBDataFromHex(NSString *string)
{
    if (![string isKindOfClass:[NSString class]]) return nil;
    NSString *text = [[string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] uppercaseString];
    if ([text hasPrefix:@"{"] && [text hasSuffix:@"}"] && text.length > 2)
        text = [text substringWithRange:NSMakeRange(1, text.length - 2)];
    NSMutableString *digits = [NSMutableString stringWithCapacity:text.length];
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (c == '-') continue;
        if (!isxdigit((int)c)) return nil;
        [digits appendFormat:@"%C", c];
    }
    if (digits.length != 4 && digits.length != 8 && digits.length != 32) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:digits.length / 2];
    uint8_t *bytes = data.mutableBytes;
    for (NSUInteger i = 0; i < data.length; i++) {
        unsigned int byte = 0;
        NSScanner *scanner = [NSScanner scannerWithString:[digits substringWithRange:NSMakeRange(i * 2, 2)]];
        if (![scanner scanHexInt:&byte]) return nil;
        bytes[i] = (uint8_t)byte;
    }
    if (data.length == 16) {
        const uint8_t base[] = {0x00,0x00,0x10,0x00,0x80,0x00,0x00,0x80,0x5F,0x9B,0x34,0xFB};
        bool bluetoothBase = memcmp(bytes + 4, base, sizeof(base)) == 0;
        if (bluetoothBase && bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 0 && bytes[3] != 0) {
            uint8_t shortBytes[] = {bytes[2], bytes[3]};
            return [NSData dataWithBytes:shortBytes length:2];
        }
        if (bluetoothBase && bytes[0] == 0 && bytes[1] == 0 && (bytes[2] || bytes[3])) {
            uint8_t shortBytes[] = {bytes[2], bytes[3]};
            return [NSData dataWithBytes:shortBytes length:2];
        }
    }
    return data;
}

static NSData *CBExpandedData(NSData *data)
{
    if (data.length == 16) return data;
    uint8_t full[16] = {0};
    if (data.length == 2) {
        const uint8_t base[] = {0x00,0x00,0x10,0x00,0x80,0x00,0x00,0x80,0x5F,0x9B,0x34,0xFB};
        full[2] = ((const uint8_t *)data.bytes)[0];
        full[3] = ((const uint8_t *)data.bytes)[1];
        memcpy(full + 4, base, sizeof(base));
    } else if (data.length == 4) {
        const uint8_t base[] = {0x00,0x00,0x10,0x00,0x80,0x00,0x00,0x80,0x5F,0x9B,0x34,0xFB};
        memcpy(full + 4, base, sizeof(base));
        memcpy(full, data.bytes, 4);
    } else return nil;
    return [NSData dataWithBytes:full length:sizeof(full)];
}

static NSString *CBStringFromData(NSData *data)
{
    const uint8_t *bytes = data.bytes;
    if (data.length == 2 || data.length == 4) {
        NSMutableString *result = [NSMutableString stringWithCapacity:data.length * 2];
        for (NSUInteger i = 0; i < data.length; i++) [result appendFormat:@"%02X", bytes[i]];
        return result;
    }
    if (data.length != 16) return @"";
    return [NSString stringWithFormat:
        @"%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X",
        bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],
        bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]];
}

@implementation CBUUID

- (instancetype)_initWithData:(NSData *)data
{
    if (data.length != 2 && data.length != 4 && data.length != 16) {
        [self release];
        return nil;
    }
    self = [super init];
    if (self) CBSet(self, &CBUUIDDataKey, [[data copy] autorelease]);
    return self;
}

+ (CBUUID *)UUIDWithString:(NSString *)string
{
    NSData *data = CBDataFromHex(string);
    return data ? [[[self alloc] _initWithData:data] autorelease] : nil;
}

+ (CBUUID *)UUIDWithData:(NSData *)data
{
    return [[[self alloc] _initWithData:data] autorelease];
}

+ (CBUUID *)UUIDWithCFUUID:(CFUUIDRef)UUID
{
    if (!UUID) return nil;
    CFUUIDBytes bytes = CFUUIDGetUUIDBytes(UUID);
    uint8_t raw[] = {bytes.byte0,bytes.byte1,bytes.byte2,bytes.byte3,bytes.byte4,bytes.byte5,bytes.byte6,bytes.byte7,
        bytes.byte8,bytes.byte9,bytes.byte10,bytes.byte11,bytes.byte12,bytes.byte13,bytes.byte14,bytes.byte15};
    return [self UUIDWithData:[NSData dataWithBytes:raw length:sizeof(raw)]];
}

+ (CBUUID *)UUIDWithNSUUID:(NSUUID *)UUID
{
    if (!UUID) return nil;
    uuid_t bytes;
    [UUID getUUIDBytes:bytes];
    return [self UUIDWithData:[NSData dataWithBytes:bytes length:sizeof(bytes)]];
}

- (NSData *)data { return CBGet(self, &CBUUIDDataKey); }
- (NSString *)UUIDString { return CBStringFromData(self.data); }

- (BOOL)isEqual:(id)object
{
    if (self == object) return YES;
    if (![object isKindOfClass:[CBUUID class]]) return NO;
    NSData *left = CBExpandedData(self.data), *right = CBExpandedData([object data]);
    return left && right && [left isEqualToData:right];
}

- (NSUInteger)hash
{
    return CBExpandedData(self.data).hash;
}

- (id)copyWithZone:(NSZone *)zone
{
    (void)zone;
    return [self retain];
}

- (NSString *)description { return self.UUIDString; }

@end
