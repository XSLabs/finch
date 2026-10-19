/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Compare writer track groups and metadata input setup on both systems. */
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <stdio.h>

int main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        printf("%s\n", class_getImageName([AVAssetWriterInputGroup class]));
        AVAssetWriterInput *english = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:nil];
        AVAssetWriterInput *french = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:nil];
        english.languageCode = @"eng";
        english.extendedLanguageTag = @"en";
        french.languageCode = @"fra";
        french.extendedLanguageTag = @"fr";
        AVAssetWriterInputGroup *group = [AVAssetWriterInputGroup assetWriterInputGroupWithInputs:@[english, french] defaultInput:english];
        printf("group inputs=%lu default=%d options=%lu empty=%d defaultOption=%ld enabled=%d,%d\n",
            (unsigned long)group.inputs.count, group.defaultInput == english, (unsigned long)group.options.count,
            group.allowsEmptySelection, group.defaultOption ? (long)[group.options indexOfObject:group.defaultOption] : -1L,
            english.marksOutputTrackAsEnabled, french.marksOutputTrackAsEnabled);
        for (AVMediaSelectionOption *option in group.options)
            printf(" option type=%s lang=%s tag=%s name=%s playable=%d\n", option.mediaType.UTF8String,
                option.locale.localeIdentifier.UTF8String ?: "-", option.extendedLanguageTag.UTF8String ?: "-",
                option.displayName.UTF8String, option.playable);

        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"avwriter-media-%d.mov", getpid()]];
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        NSError *error = nil;
        AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:[NSURL fileURLWithPath:path] fileType:AVFileTypeQuickTimeMovie error:&error];
        [writer addInput:english];
        [writer addInput:french];
        BOOL canAssociate = [english canAddTrackAssociationWithTrackOfInput:french type:AVTrackAssociationTypeAudioFallback];
        if (canAssociate)
            [english addTrackAssociationWithTrackOfInput:french type:AVTrackAssociationTypeAudioFallback];
        printf("writer track association can-add=%d added=%d\n", canAssociate, canAssociate);
        BOOL canAddGroup = [writer canAddInputGroup:group];
        if (canAddGroup) [writer addInputGroup:group];
        printf("writer group-can=%d groups=%lu enabled=%d,%d defaultOption=%ld\n", canAddGroup,
            (unsigned long)writer.inputGroups.count, english.marksOutputTrackAsEnabled, french.marksOutputTrackAsEnabled,
            group.defaultOption ? (long)[group.options indexOfObject:group.defaultOption] : -1L);

        AVMutableMetadataItem *item = [AVMutableMetadataItem metadataItem];
        item.identifier = AVMetadataIdentifierQuickTimeMetadataTitle;
        item.dataType = (__bridge NSString *)kCMMetadataBaseDataType_UTF8;
        item.value = @"Writer metadata";
        AVTimedMetadataGroup *metadata = [[AVTimedMetadataGroup alloc] initWithItems:@[item] timeRange:CMTimeRangeMake(kCMTimeZero, CMTimeMake(1, 1))];
        CMMetadataFormatDescriptionRef format = [metadata copyFormatDescription];
        AVAssetWriterInput *metadataInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeMetadata outputSettings:nil sourceFormatHint:format];
        AVAssetWriterInputMetadataAdaptor *adaptor = [AVAssetWriterInputMetadataAdaptor assetWriterInputMetadataAdaptorWithAssetWriterInput:metadataInput];
        printf("metadata input=%d format=%d adaptor=%d error=%ld\n", metadataInput != nil, format != NULL,
            adaptor != nil, (long)error.code);
        if (format) CFRelease(format);
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    }
    return 0;
}
