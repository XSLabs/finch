/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Validates metadata writer inputs; sample-level metadata encoding is not available yet. */
#import "AVFInternal.h"
#import <AVFoundation/AVAssetWriterInput.h>
#import <AVFoundation/AVError.h>
#import <objc/runtime.h>

@interface AVAssetWriterInput (FinchMetadataAdaptor)
- (AVAssetWriter *)_finchWriter;
@end

@interface AVAssetWriter (FinchMetadataAdaptor)
- (void)_finchFailWithError:(NSError *)error;
@end

static const void *AVFMetadataAdaptorKey = &AVFMetadataAdaptorKey;

@implementation AVAssetWriterInputMetadataAdaptor {
    AVAssetWriterInput *_finchInput;
}

+ (instancetype)assetWriterInputMetadataAdaptorWithAssetWriterInput:(AVAssetWriterInput *)input
{
    return [[self alloc] initWithAssetWriterInput:input];
}

- (instancetype)initWithAssetWriterInput:(AVAssetWriterInput *)input
{
    if (!input || ![input.mediaType isEqualToString:AVMediaTypeMetadata])
        [NSException raise:NSInvalidArgumentException format:@"A timed metadata adaptor needs a metadata writer input"];
    if (!input.sourceFormatHint || CMFormatDescriptionGetMediaSubType(input.sourceFormatHint) != kCMMetadataFormatType_Boxed)
        [NSException raise:NSInvalidArgumentException format:@"A timed metadata adaptor needs a boxed metadata format hint"];
    AVAssetWriter *writer = [input _finchWriter];
    if (writer && writer.status != AVAssetWriterStatusUnknown)
        [NSException raise:NSInternalInconsistencyException format:@"A timed metadata adaptor cannot be created after writing starts"];
    NSValue *existing = objc_getAssociatedObject(input, AVFMetadataAdaptorKey);
    if (existing && existing.nonretainedObjectValue)
        [NSException raise:NSInvalidArgumentException format:@"The writer input already has a timed metadata adaptor"];
    if ((self = [super init])) {
        _finchInput = input;
        objc_setAssociatedObject(input, AVFMetadataAdaptorKey, [NSValue valueWithNonretainedObject:self], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return self;
}

- (void)dealloc
{
    NSValue *existing = objc_getAssociatedObject(_finchInput, AVFMetadataAdaptorKey);
    if (existing.nonretainedObjectValue == self)
        objc_setAssociatedObject(_finchInput, AVFMetadataAdaptorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (AVAssetWriterInput *)assetWriterInput { return _finchInput; }

- (BOOL)appendTimedMetadataGroup:(AVTimedMetadataGroup *)group
{
    if (!group)
        [NSException raise:NSInvalidArgumentException format:@"A timed metadata group is required"];
    AVAssetWriter *writer = [_finchInput _finchWriter];
    if (!writer || writer.status != AVAssetWriterStatusWriting)
        [NSException raise:NSInternalInconsistencyException format:@"The metadata input must be attached to a writing asset writer"];
    NSError *error = AVFError(AVErrorOperationNotSupportedForAsset, nil);
    [writer _finchFailWithError:error];
    return NO;
}
@end
