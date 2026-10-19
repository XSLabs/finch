/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Writer input groups keep real inputs mutually exclusive in the output movie. */
#import "AVFInternal.h"
#import <AVFoundation/AVAssetWriter.h>
#import <AVFoundation/AVAssetWriterInput.h>

@interface AVMediaSelectionOption (FinchWriterInputGroup)
- (instancetype)initWithFinchWriterInput:(AVAssetWriterInput *)input characteristics:(NSArray<AVMediaCharacteristic> *)characteristics;
@end

@interface AVMediaSelectionGroup (FinchWriterInputGroup)
- (instancetype)initWithFinchOptions:(NSArray<AVMediaSelectionOption *> *)options allowsEmptySelection:(BOOL)allowsEmptySelection;
- (void)_finchSetOptions:(NSArray<AVMediaSelectionOption *> *)options allowsEmptySelection:(BOOL)allowsEmptySelection;
@end

static NSArray<AVMediaCharacteristic> *
characteristics_for_input(AVAssetWriterInput *input)
{
    if ([input.mediaType isEqualToString:AVMediaTypeAudio]) return @[AVMediaCharacteristicAudible];
    if ([input.mediaType isEqualToString:AVMediaTypeVideo]) return @[AVMediaCharacteristicVisual];
    if ([input.mediaType isEqualToString:AVMediaTypeText] ||
        [input.mediaType isEqualToString:AVMediaTypeSubtitle] ||
        [input.mediaType isEqualToString:AVMediaTypeClosedCaption])
        return @[AVMediaCharacteristicLegible];
    return @[];
}

@implementation AVAssetWriterInputGroup {
    NSArray<AVAssetWriterInput *> *_finchInputs;
    AVAssetWriterInput *_finchDefaultInput;
}

+ (instancetype)assetWriterInputGroupWithInputs:(NSArray<AVAssetWriterInput *> *)inputs defaultInput:(AVAssetWriterInput *)defaultInput
{
    return [[self alloc] initWithInputs:inputs defaultInput:defaultInput];
}

- (instancetype)initWithInputs:(NSArray<AVAssetWriterInput *> *)inputs defaultInput:(AVAssetWriterInput *)defaultInput
{
    if (!inputs)
        [NSException raise:NSInvalidArgumentException format:@"An input group requires an input array"];
    NSMutableArray *options = [NSMutableArray arrayWithCapacity:inputs.count];
    for (AVAssetWriterInput *input in inputs) {
        if (![input isKindOfClass:AVAssetWriterInput.class])
            [NSException raise:NSInvalidArgumentException format:@"An input group may contain only AVAssetWriterInput objects"];
        [options addObject:[[AVMediaSelectionOption alloc] initWithFinchWriterInput:input characteristics:characteristics_for_input(input)]];
    }
    if ((self = [super init])) {
        [self _finchSetOptions:options allowsEmptySelection:YES];
        _finchInputs = [inputs copy];
        _finchDefaultInput = [inputs containsObject:defaultInput] ? defaultInput : nil;
    }
    return self;
}

- (NSArray<AVAssetWriterInput *> *)inputs { return _finchInputs; }
- (AVAssetWriterInput *)defaultInput { return _finchDefaultInput; }
- (AVMediaSelectionOption *)defaultOption { return nil; }
@end
