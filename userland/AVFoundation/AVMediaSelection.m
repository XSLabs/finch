/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Media choices are built from alternate tracks in the movie Finch actually read. */
#import "AVFInternal.h"
#import <AVFoundation/AVMediaSelection.h>
#import <AVFoundation/AVMediaSelectionGroup.h>
#import <objc/runtime.h>

@interface AVAssetTrack (FinchMediaSelection)
- (AVFTrack *)_finchTrack;
@end

@interface AVMediaSelectionOption (FinchMediaSelection)
- (instancetype)initWithFinchTrack:(AVAssetTrack *)track characteristics:(NSArray<AVMediaCharacteristic> *)characteristics;
- (instancetype)initWithFinchWriterInput:(AVAssetWriterInput *)input characteristics:(NSArray<AVMediaCharacteristic> *)characteristics;
- (AVAssetTrack *)_finchTrack;
- (BOOL)_finchIsEnabled;
@end

@interface AVMediaSelectionGroup (FinchMediaSelection)
- (instancetype)initWithFinchOptions:(NSArray<AVMediaSelectionOption *> *)options allowsEmptySelection:(BOOL)allowsEmptySelection;
- (void)_finchSetOptions:(NSArray<AVMediaSelectionOption *> *)options allowsEmptySelection:(BOOL)allowsEmptySelection;
@end

@interface AVMediaSelection (FinchMediaSelection)
- (instancetype)initWithFinchAsset:(AVAsset *)asset selections:(NSDictionary<NSValue *, id> *)selections automatic:(BOOL)automatic;
@end

static const void *AVFMediaGroupsKey = &AVFMediaGroupsKey;
static const void *AVFPreferredSelectionKey = &AVFPreferredSelectionKey;

static NSArray<AVMediaCharacteristic> *
AVFCharacteristicsForTrack(AVAssetTrack *track)
{
    if ([track.mediaType isEqualToString:AVMediaTypeAudio])
        return @[AVMediaCharacteristicAudible];
    if ([track.mediaType isEqualToString:AVMediaTypeVideo])
        return @[AVMediaCharacteristicVisual];
    if ([track.mediaType isEqualToString:AVMediaTypeSubtitle] ||
        [track.mediaType isEqualToString:AVMediaTypeText] ||
        [track.mediaType isEqualToString:AVMediaTypeClosedCaption])
        return @[AVMediaCharacteristicLegible];
    return @[];
}

static NSString *
AVFLanguageTagForTrack(AVAssetTrack *track)
{
    return track.extendedLanguageTag.length ? track.extendedLanguageTag : (track.languageCode.length ? track.languageCode : nil);
}

@implementation AVMediaSelectionOption {
    AVAssetTrack *_finchTrack;
    AVAssetWriterInput *_finchWriterInput;
    NSArray<AVMediaCharacteristic> *_finchCharacteristics;
}
- (instancetype)initWithFinchTrack:(AVAssetTrack *)track characteristics:(NSArray<AVMediaCharacteristic> *)characteristics
{
    if ((self = [super init])) {
        _finchTrack = track;
        _finchCharacteristics = [characteristics copy] ?: @[];
    }
    return self;
}
- (instancetype)initWithFinchWriterInput:(AVAssetWriterInput *)input characteristics:(NSArray<AVMediaCharacteristic> *)characteristics
{
    if ((self = [super init])) {
        _finchWriterInput = input;
        _finchCharacteristics = [characteristics copy] ?: @[];
    }
    return self;
}
- (AVAssetTrack *)_finchTrack { return _finchTrack; }
- (BOOL)_finchIsEnabled { return _finchTrack ? _finchTrack.isEnabled : _finchWriterInput.marksOutputTrackAsEnabled; }
- (AVMediaType)mediaType { return _finchTrack ? _finchTrack.mediaType : _finchWriterInput.mediaType; }
- (NSArray<NSNumber *> *)mediaSubTypes
{
    if (_finchWriterInput.sourceFormatHint)
        return @[@(CMFormatDescriptionGetMediaSubType(_finchWriterInput.sourceFormatHint))];
    if (!_finchTrack) return @[];
    NSMutableArray *types = [NSMutableArray array];
    for (id value in _finchTrack.formatDescriptions) {
        CMFormatDescriptionRef description = (__bridge CMFormatDescriptionRef)value;
        if (description) [types addObject:@(CMFormatDescriptionGetMediaSubType(description))];
    }
    return types;
}
- (BOOL)hasMediaCharacteristic:(AVMediaCharacteristic)characteristic
{
    return [_finchCharacteristics containsObject:characteristic];
}
- (BOOL)isPlayable { return _finchTrack ? _finchTrack.isPlayable : YES; }
- (NSString *)extendedLanguageTag
{
    if (_finchWriterInput.extendedLanguageTag.length) return _finchWriterInput.extendedLanguageTag;
    if (_finchWriterInput.languageCode.length) return _finchWriterInput.languageCode;
    return AVFLanguageTagForTrack(_finchTrack);
}
- (NSLocale *)locale
{
    NSString *tag = self.extendedLanguageTag;
    return tag.length ? [NSLocale localeWithLocaleIdentifier:tag] : nil;
}
- (NSArray<AVMetadataItem *> *)commonMetadata
{
    return _finchTrack ? (_finchTrack.commonMetadata ?: @[]) : AVFCommonMetadata(_finchWriterInput.metadata ?: @[]);
}
- (NSArray<NSString *> *)availableMetadataFormats
{
    return _finchTrack ? (_finchTrack.availableMetadataFormats ?: @[]) : @[];
}
- (NSArray<AVMetadataItem *> *)metadataForFormat:(NSString *)format
{
    if (_finchTrack) return [_finchTrack metadataForFormat:format] ?: @[];
    return @[];
}
- (AVMediaSelectionOption *)associatedMediaSelectionOptionInMediaSelectionGroup:(AVMediaSelectionGroup *)group
{
    NSString *tag = self.extendedLanguageTag;
    for (AVMediaSelectionOption *option in group.options) {
        if (option == self) continue;
        if (tag.length && [option.extendedLanguageTag caseInsensitiveCompare:tag] == NSOrderedSame)
            return option;
    }
    return nil;
}
- (id)propertyList
{
    NSString *tag = self.extendedLanguageTag;
    NSNumber *identifier = _finchTrack ? @(_finchTrack.trackID) : @((uintptr_t)(__bridge void *)_finchWriterInput);
    return @{@"trackID" : identifier, @"mediaType" : self.mediaType,
             @"language" : tag ?: @""};
}
- (NSString *)displayNameWithLocale:(NSLocale *)locale
{
    for (AVMetadataItem *item in self.commonMetadata)
        if ([item.commonKey isEqualToString:AVMetadataCommonKeyTitle] && item.stringValue.length)
            return item.stringValue;
    NSString *tag = self.extendedLanguageTag;
    if (!tag.length) return @"Unknown language";
    if ([tag caseInsensitiveCompare:@"und"] == NSOrderedSame) return @"Unknown language";
    NSLocale *displayLocale = locale ?: NSLocale.currentLocale;
    NSString *name = [displayLocale displayNameForKey:NSLocaleIdentifier value:tag];
    return name.length ? name : tag;
}
- (NSString *)displayName { return [self displayNameWithLocale:NSLocale.currentLocale]; }
- (id)copyWithZone:(NSZone *)zone { return self; }
@end

@implementation AVMediaSelectionGroup {
    NSArray<AVMediaSelectionOption *> *_finchOptions;
    BOOL _finchAllowsEmptySelection;
}
- (instancetype)init { return [self initWithFinchOptions:@[] allowsEmptySelection:NO]; }
- (instancetype)initWithFinchOptions:(NSArray<AVMediaSelectionOption *> *)options allowsEmptySelection:(BOOL)allowsEmptySelection
{
    if ((self = [super init])) [self _finchSetOptions:options allowsEmptySelection:allowsEmptySelection];
    return self;
}
- (void)_finchSetOptions:(NSArray<AVMediaSelectionOption *> *)options allowsEmptySelection:(BOOL)allowsEmptySelection
{
    _finchOptions = [options copy] ?: @[];
    _finchAllowsEmptySelection = allowsEmptySelection;
}
- (NSArray<AVMediaSelectionOption *> *)options { return _finchOptions; }
- (AVMediaSelectionOption *)defaultOption
{
    for (AVMediaSelectionOption *option in _finchOptions)
        if (option._finchIsEnabled && option._finchTrack) return option;
    return _finchOptions.firstObject;
}
- (BOOL)allowsEmptySelection { return _finchAllowsEmptySelection; }
- (AVCustomMediaSelectionScheme *)customMediaSelectionScheme { return nil; }
- (AVMediaSelectionOption *)mediaSelectionOptionWithPropertyList:(id)plist
{
    if (!plist) return nil;
    for (AVMediaSelectionOption *option in _finchOptions)
        if ([option.propertyList isEqual:plist]) return option;
    return nil;
}
+ (NSArray<AVMediaSelectionOption *> *)playableMediaSelectionOptionsFromArray:(NSArray<AVMediaSelectionOption *> *)options
{
    NSMutableArray *result = [NSMutableArray array];
    for (AVMediaSelectionOption *option in options)
        if (option.isPlayable) [result addObject:option];
    return result;
}
+ (NSArray<AVMediaSelectionOption *> *)mediaSelectionOptionsFromArray:(NSArray<AVMediaSelectionOption *> *)options withLocale:(NSLocale *)locale
{
    NSMutableArray *result = [NSMutableArray array];
    for (AVMediaSelectionOption *option in options)
        if ([option.locale.localeIdentifier caseInsensitiveCompare:locale.localeIdentifier] == NSOrderedSame)
            [result addObject:option];
    return result;
}
+ (NSArray<AVMediaSelectionOption *> *)mediaSelectionOptionsFromArray:(NSArray<AVMediaSelectionOption *> *)options withMediaCharacteristics:(NSArray<AVMediaCharacteristic> *)characteristics
{
    NSMutableArray *result = [NSMutableArray array];
    for (AVMediaSelectionOption *option in options) {
        BOOL matches = YES;
        for (AVMediaCharacteristic characteristic in characteristics)
            if (![option hasMediaCharacteristic:characteristic]) { matches = NO; break; }
        if (matches) [result addObject:option];
    }
    return result;
}
+ (NSArray<AVMediaSelectionOption *> *)mediaSelectionOptionsFromArray:(NSArray<AVMediaSelectionOption *> *)options withoutMediaCharacteristics:(NSArray<AVMediaCharacteristic> *)characteristics
{
    NSMutableArray *result = [NSMutableArray array];
    for (AVMediaSelectionOption *option in options) {
        BOOL matches = YES;
        for (AVMediaCharacteristic characteristic in characteristics)
            if ([option hasMediaCharacteristic:characteristic]) { matches = NO; break; }
        if (matches) [result addObject:option];
    }
    return result;
}
+ (NSArray<AVMediaSelectionOption *> *)mediaSelectionOptionsFromArray:(NSArray<AVMediaSelectionOption *> *)options filteredAndSortedAccordingToPreferredLanguages:(NSArray<NSString *> *)languages
{
    NSMutableArray<NSDictionary *> *ranked = [NSMutableArray array];
    for (NSUInteger index = 0; index < options.count; index++) {
        AVMediaSelectionOption *option = options[index];
        NSString *tag = option.extendedLanguageTag;
        NSUInteger rank = NSNotFound;
        for (NSUInteger preference = 0; tag.length && preference < languages.count; preference++) {
            NSString *preferred = languages[preference];
            if ([tag caseInsensitiveCompare:preferred] == NSOrderedSame ||
                [[tag componentsSeparatedByString:@"-"][0] caseInsensitiveCompare:[preferred componentsSeparatedByString:@"-"][0]] == NSOrderedSame) {
                rank = preference;
                break;
            }
        }
        if (rank != NSNotFound)
            [ranked addObject:@{@"option" : option, @"rank" : @(rank), @"order" : @(index)}];
    }
    [ranked sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult result = [a[@"rank"] compare:b[@"rank"]];
        return result == NSOrderedSame ? [a[@"order"] compare:b[@"order"]] : result;
    }];
    return [ranked valueForKey:@"option"];
}
- (id)copyWithZone:(NSZone *)zone { return self; }
@end

@implementation AVMediaSelection {
    __weak AVAsset *_finchAsset;
    NSMutableDictionary<NSValue *, id> *_finchSelectedOptions;
    NSMutableSet<NSValue *> *_finchManuallySelectedGroups;
}
- (instancetype)init { return [self initWithFinchAsset:nil selections:@{} automatic:YES]; }
- (instancetype)initWithFinchAsset:(AVAsset *)asset selections:(NSDictionary<NSValue *,id> *)selections automatic:(BOOL)automatic
{
    if ((self = [super init])) {
        _finchAsset = asset;
        _finchSelectedOptions = [selections mutableCopy] ?: [NSMutableDictionary dictionary];
        _finchManuallySelectedGroups = [NSMutableSet set];
        if (!automatic) [_finchManuallySelectedGroups addObjectsFromArray:_finchSelectedOptions.allKeys];
    }
    return self;
}
- (AVAsset *)asset { return _finchAsset; }
- (NSValue *)_finchKeyForGroup:(AVMediaSelectionGroup *)group { return [NSValue valueWithNonretainedObject:group]; }
- (AVMediaSelectionOption *)selectedMediaOptionInMediaSelectionGroup:(AVMediaSelectionGroup *)group
{
    if (!group) return nil;
    id selected = _finchSelectedOptions[[self _finchKeyForGroup:group]];
    return selected == NSNull.null ? nil : (selected ?: group.defaultOption);
}
- (BOOL)mediaSelectionCriteriaCanBeAppliedAutomaticallyToMediaSelectionGroup:(AVMediaSelectionGroup *)group
{
    return group && ![_finchManuallySelectedGroups containsObject:[self _finchKeyForGroup:group]];
}
- (void)_finchSelectOption:(AVMediaSelectionOption *)option inGroup:(AVMediaSelectionGroup *)group
{
    [self _finchSetOption:option inGroup:group automatic:NO];
}
- (void)_finchSetOption:(AVMediaSelectionOption *)option inGroup:(AVMediaSelectionGroup *)group automatic:(BOOL)automatic
{
    if (!group || (option && ![group.options containsObject:option]) || (!option && !group.allowsEmptySelection)) return;
    NSValue *key = [self _finchKeyForGroup:group];
    _finchSelectedOptions[key] = option ?: NSNull.null;
    if (automatic)
        [_finchManuallySelectedGroups removeObject:key];
    else
        [_finchManuallySelectedGroups addObject:key];
}
- (id)copyWithZone:(NSZone *)zone
{
    return [[AVMediaSelection allocWithZone:zone] initWithFinchAsset:_finchAsset selections:_finchSelectedOptions automatic:NO];
}
- (id)mutableCopyWithZone:(NSZone *)zone
{
    AVMutableMediaSelection *copy = [[AVMutableMediaSelection allocWithZone:zone] initWithFinchAsset:_finchAsset selections:_finchSelectedOptions automatic:NO];
    return copy;
}
@end

@implementation AVMutableMediaSelection
- (void)selectMediaOption:(AVMediaSelectionOption *)option inMediaSelectionGroup:(AVMediaSelectionGroup *)group
{
    [self _finchSelectOption:option inGroup:group];
}
@end

NSArray<AVMediaCharacteristic> *
AVFMediaSelectionAvailableCharacteristics(AVAsset *asset)
{
    NSMutableOrderedSet *characteristics = [NSMutableOrderedSet orderedSet];
    for (AVMediaCharacteristic characteristic in @[AVMediaCharacteristicAudible, AVMediaCharacteristicLegible, AVMediaCharacteristicVisual])
        if (AVFMediaSelectionGroupForCharacteristic(asset, characteristic)) [characteristics addObject:characteristic];
    return characteristics.array;
}

AVMediaSelectionGroup *
AVFMediaSelectionGroupForCharacteristic(AVAsset *asset, AVMediaCharacteristic characteristic)
{
    if (!asset) return nil;
    @synchronized (asset) {
        NSMutableDictionary *groups = objc_getAssociatedObject(asset, AVFMediaGroupsKey);
        if (!groups) {
            groups = [NSMutableDictionary dictionary];
            objc_setAssociatedObject(asset, AVFMediaGroupsKey, groups, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        id cached = groups[characteristic];
        if (cached) return cached == NSNull.null ? nil : cached;
        NSMutableArray *options = [NSMutableArray array];
        for (AVAssetTrack *track in asset.tracks) {
            AVFTrack *rawTrack = [track _finchTrack];
            if (rawTrack->alternateGroup <= 0 || ![AVFCharacteristicsForTrack(track) containsObject:characteristic]) continue;
            [options addObject:[[AVMediaSelectionOption alloc] initWithFinchTrack:track characteristics:AVFCharacteristicsForTrack(track)]];
        }
        AVMediaSelectionGroup *group = options.count ? [[AVMediaSelectionGroup alloc] initWithFinchOptions:options allowsEmptySelection:YES] : nil;
        groups[characteristic] = group ?: NSNull.null;
        return group;
    }
}

AVMediaSelection *
AVFMediaSelectionForAsset(AVAsset *asset)
{
    if (!asset) return nil;
    AVMediaSelection *selection = objc_getAssociatedObject(asset, AVFPreferredSelectionKey);
    if (selection) return selection;
    @synchronized (asset) {
        selection = objc_getAssociatedObject(asset, AVFPreferredSelectionKey);
        if (!selection) {
            NSMutableDictionary *defaults = [NSMutableDictionary dictionary];
            for (AVMediaCharacteristic characteristic in AVFMediaSelectionAvailableCharacteristics(asset)) {
                AVMediaSelectionGroup *group = AVFMediaSelectionGroupForCharacteristic(asset, characteristic);
                if (group.defaultOption) defaults[[NSValue valueWithNonretainedObject:group]] = group.defaultOption;
            }
            selection = [[AVMediaSelection alloc] initWithFinchAsset:asset selections:defaults automatic:YES];
            objc_setAssociatedObject(asset, AVFPreferredSelectionKey, selection, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    return selection;
}

NSArray<AVMediaSelection *> *
AVFMediaSelectionsForAsset(AVAsset *asset)
{
    if (!asset) return @[];
    NSArray<AVMediaCharacteristic> *characteristics = AVFMediaSelectionAvailableCharacteristics(asset);
    if (!characteristics.count) return @[];
    NSMutableArray<NSDictionary<NSValue *, id> *> *permutations = [NSMutableArray arrayWithObject:@{}];
    for (AVMediaCharacteristic characteristic in characteristics) {
        AVMediaSelectionGroup *group = AVFMediaSelectionGroupForCharacteristic(asset, characteristic);
        if (!group.options.count) continue;
        NSMutableArray *next = [NSMutableArray array];
        NSValue *key = [NSValue valueWithNonretainedObject:group];
        for (NSDictionary *permutation in permutations) {
            for (AVMediaSelectionOption *option in group.options) {
                NSMutableDictionary *choice = [permutation mutableCopy];
                choice[key] = option;
                [next addObject:choice];
            }
        }
        permutations = next;
    }
    NSMutableArray *selections = [NSMutableArray arrayWithCapacity:permutations.count];
    for (NSDictionary *permutation in permutations)
        [selections addObject:[[AVMediaSelection alloc] initWithFinchAsset:asset selections:permutation automatic:YES]];
    return selections;
}
