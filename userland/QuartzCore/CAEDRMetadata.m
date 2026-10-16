/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CAEDRMetadata holds the HDR10 and HLG metadata an app associates with image
 * data. Finch preserves the specified metadata and coding values; it has no
 * extended-range display path yet.
 */
#import <QuartzCore/CAEDRMetadata.h>
#import <Foundation/Foundation.h>

enum FinchEDRKind { FinchEDRHDR10 = 1, FinchEDRHLG = 2 };

@interface CAEDRMetadata (FinchPrivate)
- (instancetype)_initWithKind:(NSInteger)kind displayInfo:(NSData *)displayInfo contentInfo:(NSData *)contentInfo
                 ambientInfo:(NSData *)ambientInfo minimum:(float)minimum maximum:(float)maximum scale:(float)scale;
@end

@implementation CAEDRMetadata {
    NSInteger _kind;
    NSData *_displayInfo;
    NSData *_contentInfo;
    NSData *_ambientInfo;
    float _minimum, _maximum, _scale;
}

- (instancetype)_initWithKind:(NSInteger)kind displayInfo:(NSData *)displayInfo contentInfo:(NSData *)contentInfo
                  ambientInfo:(NSData *)ambientInfo minimum:(float)minimum maximum:(float)maximum scale:(float)scale
{
    self = [super init];
    if (self) {
        _kind = kind;
        _displayInfo = [displayInfo copy];
        _contentInfo = [contentInfo copy];
        _ambientInfo = [ambientInfo copy];
        _minimum = minimum;
        _maximum = maximum;
        _scale = scale;
    }
    return self;
}

- (void)dealloc
{
    [_displayInfo release];
    [_contentInfo release];
    [_ambientInfo release];
    [super dealloc];
}

+ (instancetype)HDR10MetadataWithDisplayInfo:(NSData *)displayData contentInfo:(NSData *)contentData opticalOutputScale:(float)scale
{
    if ((displayData && [displayData length] != 24) || (contentData && [contentData length] != 4))
        return nil;
    return [[[self alloc] _initWithKind:FinchEDRHDR10 displayInfo:displayData contentInfo:contentData ambientInfo:nil minimum:0
                                maximum:0 scale:scale] autorelease];
}

+ (instancetype)HDR10MetadataWithMinLuminance:(float)minNits maxLuminance:(float)maxNits opticalOutputScale:(float)scale
{
    return [[[self alloc] _initWithKind:FinchEDRHDR10 displayInfo:nil contentInfo:nil ambientInfo:nil minimum:minNits maximum:maxNits
                                scale:scale] autorelease];
}

+ (instancetype)HLGMetadataWithAmbientViewingEnvironment:(NSData *)data
{
    if (!data || [data length] != 8)
        return nil;
    return [[[self alloc] _initWithKind:FinchEDRHLG displayInfo:nil contentInfo:nil ambientInfo:data minimum:0 maximum:0 scale:0]
        autorelease];
}

+ (instancetype)HLGMetadata
{
    static CAEDRMetadata *metadata;
    @synchronized(self) {
        if (!metadata) {
            const UInt8 bytes[] = {0x00, 0x2f, 0xef, 0xe0, 0x3d, 0x13, 0x40, 0x42};
            NSData *data = [NSData dataWithBytes:bytes length:sizeof bytes];
            metadata = [[self HLGMetadataWithAmbientViewingEnvironment:data] retain];
        }
    }
    return metadata;
}

+ (BOOL)isAvailable
{
    return NO;
}

- (id)copyWithZone:(NSZone *)zone
{
    return [self retain];
}

+ (BOOL)supportsSecureCoding
{
    return YES;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super init];
    if (self) {
        _kind = [coder decodeIntegerForKey:@"kind"];
        _displayInfo = [[coder decodeObjectOfClass:[NSData class] forKey:@"displayInfo"] copy];
        _contentInfo = [[coder decodeObjectOfClass:[NSData class] forKey:@"contentInfo"] copy];
        _ambientInfo = [[coder decodeObjectOfClass:[NSData class] forKey:@"ambientInfo"] copy];
        _minimum = [coder decodeFloatForKey:@"minimum"];
        _maximum = [coder decodeFloatForKey:@"maximum"];
        _scale = [coder decodeFloatForKey:@"scale"];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeInteger:_kind forKey:@"kind"];
    if (_displayInfo)
        [coder encodeObject:_displayInfo forKey:@"displayInfo"];
    if (_contentInfo)
        [coder encodeObject:_contentInfo forKey:@"contentInfo"];
    if (_ambientInfo)
        [coder encodeObject:_ambientInfo forKey:@"ambientInfo"];
    [coder encodeFloat:_minimum forKey:@"minimum"];
    [coder encodeFloat:_maximum forKey:@"maximum"];
    [coder encodeFloat:_scale forKey:@"scale"];
}

@end
