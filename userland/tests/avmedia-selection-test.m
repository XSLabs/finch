/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Compare track-backed media selection on the same small movie on both systems. */
#import <AVFoundation/AVFoundation.h>
#import <AVFoundation/AVPlayerMediaSelectionCriteria.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include "avmovie.h"
#include <string.h>

static uint32_t read_be32(const uint8_t *bytes)
{
    return ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) | ((uint32_t)bytes[2] << 8) | bytes[3];
}

static NSData *movie_with_grouped_audio(void)
{
    NSMutableData *movie = [build_movie_with_frames(@[]) mutableCopy];
    uint8_t *bytes = movie.mutableBytes;
    NSUInteger length = movie.length, movieBox = NSNotFound, movieEnd = 0, trackHeader = NSNotFound;
    for (NSUInteger offset = 0; offset + 8 <= length;) {
        uint32_t size = read_be32(bytes + offset);
        if (size < 8 || offset + size > length) break;
        if (!memcmp(bytes + offset + 4, "moov", 4)) { movieBox = offset; movieEnd = offset + size; break; }
        offset += size;
    }
    if (movieBox == NSNotFound) return movie;
    for (NSUInteger offset = movieBox + 8; offset + 8 <= movieEnd;) {
        uint32_t size = read_be32(bytes + offset);
        if (size < 8 || offset + size > movieEnd) break;
        if (!memcmp(bytes + offset + 4, "trak", 4) && memmem(bytes + offset, size, "soun", 4)) {
            for (NSUInteger child = offset + 8; child + 8 <= offset + size;) {
                uint32_t childSize = read_be32(bytes + child);
                if (childSize < 8 || child + childSize > offset + size) break;
                if (!memcmp(bytes + child + 4, "tkhd", 4)) { trackHeader = child; break; }
                child += childSize;
            }
            break;
        }
        offset += size;
    }
    if (trackHeader == NSNotFound) return movie;
    bytes = movie.mutableBytes;
    bytes[trackHeader + 8 + 34] = 0;
    bytes[trackHeader + 8 + 35] = 1;
    return movie;
}

static void
print_group(AVAsset *asset, AVMediaCharacteristic characteristic, const char *label)
{
    AVMediaSelectionGroup *group = [asset mediaSelectionGroupForMediaCharacteristic:characteristic];
    printf("%s present=%d options=%lu empty=%d default=%ld\n", label, group != nil,
        (unsigned long)group.options.count, group.allowsEmptySelection,
        group.defaultOption ? (long)[group.options indexOfObject:group.defaultOption] : -1L);
    for (AVMediaSelectionOption *option in group.options)
        printf(" option type=%s playable=%d lang=%s locale=%s name=%s common=%lu\n",
            option.mediaType.UTF8String, option.playable, option.extendedLanguageTag.UTF8String ?: "-",
            option.locale.localeIdentifier.UTF8String ?: "-", option.displayName.UTF8String,
            (unsigned long)option.commonMetadata.count);
    AVMediaSelection *selection = asset.preferredMediaSelection;
    AVMediaSelectionOption *selected = group ? [selection selectedMediaOptionInMediaSelectionGroup:group] : nil;
    printf(" preferred=%d automatic=%d\n", selected ? (int)[group.options indexOfObject:selected] : -1,
        group ? [selection mediaSelectionCriteriaCanBeAppliedAutomaticallyToMediaSelectionGroup:group] : 0);
    AVMutableMediaSelection *mutable = [selection mutableCopy];
    if (group && group.allowsEmptySelection)
        [mutable selectMediaOption:nil inMediaSelectionGroup:group];
    printf(" mutable=%d\n", [mutable selectedMediaOptionInMediaSelectionGroup:group] == nil);
}

int
main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        printf("%s\n", class_getImageName([AVMediaSelection class]));
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"avmedia-selection-%d.mov", getpid()]];
        [movie_with_grouped_audio() writeToFile:path atomically:YES];
        AVAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
        printf("characteristics=%lu audioTracks=%lu subtitleTracks=%lu\n",
            (unsigned long)asset.availableMediaCharacteristicsWithMediaSelectionOptions.count,
            (unsigned long)[asset tracksWithMediaType:AVMediaTypeAudio].count,
            (unsigned long)[asset tracksWithMediaType:AVMediaTypeSubtitle].count);
        NSArray<AVAssetTrackGroup *> *trackGroups = asset.trackGroups;
        printf("track-groups=%lu first-count=%lu first-id=%ld\n", (unsigned long)trackGroups.count,
            (unsigned long)trackGroups.firstObject.trackIDs.count,
            (long)trackGroups.firstObject.trackIDs.firstObject.integerValue);
        printf("all-selections=%lu\n", (unsigned long)asset.allMediaSelections.count);
        print_group(asset, AVMediaCharacteristicAudible, "audible");
        print_group(asset, AVMediaCharacteristicLegible, "legible");
        NSArray *playable = [AVMediaSelectionGroup playableMediaSelectionOptionsFromArray:
            [asset mediaSelectionGroupForMediaCharacteristic:AVMediaCharacteristicAudible].options ?: @[]];
        printf("playable-filter=%lu\n", (unsigned long)playable.count);

        AVMediaSelectionGroup *audioGroup = [asset mediaSelectionGroupForMediaCharacteristic:AVMediaCharacteristicAudible];
        AVPlayerMediaSelectionCriteria *criteria = [[AVPlayerMediaSelectionCriteria alloc]
            initWithPrincipalMediaCharacteristics:@[] preferredLanguages:@[@"und"] preferredMediaCharacteristics:@[]];
        AVPlayer *player = [[AVPlayer alloc] init];
        [player setMediaSelectionCriteria:criteria forMediaCharacteristic:AVMediaCharacteristicAudible];
        AVPlayerMediaSelectionCriteria *readBack = [player mediaSelectionCriteriaForMediaCharacteristic:AVMediaCharacteristicAudible];
        printf("criteria=%lu/%lu/%lu automatic=%d\n", (unsigned long)readBack.principalMediaCharacteristics.count,
            (unsigned long)readBack.preferredLanguages.count, (unsigned long)readBack.preferredMediaCharacteristics.count,
            player.appliesMediaSelectionCriteriaAutomatically);
        AVPlayerItem *item = [[AVPlayerItem alloc] initWithAsset:asset];
        [player replaceCurrentItemWithPlayerItem:item];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
        while (item.status == AVPlayerItemStatusUnknown && [deadline timeIntervalSinceNow] > 0)
            [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        AVMediaSelectionOption *selected = [item selectedMediaOptionInMediaSelectionGroup:audioGroup];
        printf("item-selection=%d schemes=%lu custom=%d\n", selected ? (int)[audioGroup.options indexOfObject:selected] : -1,
            (unsigned long)item.preferredCustomMediaSelectionSchemes.count, audioGroup.customMediaSelectionScheme != nil);
        [item selectMediaOption:nil inMediaSelectionGroup:audioGroup];
        printf("deselected=%d automatic=%d\n",
            [item selectedMediaOptionInMediaSelectionGroup:audioGroup] == nil,
            [item.currentMediaSelection mediaSelectionCriteriaCanBeAppliedAutomaticallyToMediaSelectionGroup:audioGroup]);
        [item selectMediaOptionAutomaticallyInMediaSelectionGroup:audioGroup];
        selected = [item.currentMediaSelection selectedMediaOptionInMediaSelectionGroup:audioGroup];
        printf("reselected=%d automatic=%d language=%d settings=%lu/%lu\n",
            selected ? (int)[audioGroup.options indexOfObject:selected] : -1,
            [item.currentMediaSelection mediaSelectionCriteriaCanBeAppliedAutomaticallyToMediaSelectionGroup:audioGroup],
            [item selectedMediaPresentationLanguageForMediaSelectionGroup:audioGroup] != nil,
            (unsigned long)[item selectedMediaPresentationSettingsForMediaSelectionGroup:audioGroup].count,
            (unsigned long)[item effectiveMediaPresentationSettingsForMediaSelectionGroup:audioGroup].count);
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    }
    return 0;
}
