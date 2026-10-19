/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* AVFoundation's insides, shared between its files. */
#import <AVFoundation/AVFoundation.h>
#import "AVFMovie.h"

typedef struct {
    const char *identifier, *keySpace;
    const char *stringKey;  /* or NULL, for a four-character code */
    uint32_t codeKey;
    const char *commonKey;  /* or NULL */
} AVFIdentifierInfo;

extern const AVFIdentifierInfo AVFIdentifierTable[];
extern const size_t AVFIdentifierTableCount;

/* An error in AVFoundation's domain, with Apple's code. */
NSError *AVFError(NSInteger code, NSError *underlying);

/* The common key a key in a key space has, as Apple's gives it (or nil). */
NSString *AVFCommonKeyFor(id key, NSString *keySpace);

@interface AVMetadataItem (Finch)
/* A read-only item made from what a movie's user data or metadata holds. */
+ (instancetype)_finchItemWithEntry:(AVFMetadataEntry *)entry;
- (void)_finchTakeFrom:(AVMetadataItem *)other;
@end

/* The common metadata from a list of items: the first item for each common key, in
   Apple's order of common keys. */
NSArray<AVMetadataItem *> *AVFCommonMetadata(NSArray<AVMetadataItem *> *items);

/* Apply an AVAudioMix's volume ramps to a writable, interleaved linear-PCM sample buffer. */
BOOL AVFAudioMixProcessSampleBuffer(AVAudioMix *mix, CMPersistentTrackID trackID, CMSampleBufferRef sampleBuffer);

/* The types and MIME types AVURLAsset opens (AVFTypes.m). */
NSArray<NSString *> *AVFAudiovisualTypes(void);
NSArray<NSString *> *AVFAudiovisualMIMETypes(void);

/* Alternate-track choices read from an asset's movie tracks. */
NSArray<AVMediaCharacteristic> *AVFMediaSelectionAvailableCharacteristics(AVAsset *asset);
AVMediaSelectionGroup *AVFMediaSelectionGroupForCharacteristic(AVAsset *asset, AVMediaCharacteristic characteristic);
AVMediaSelection *AVFMediaSelectionForAsset(AVAsset *asset);
NSArray<AVMediaSelection *> *AVFMediaSelectionsForAsset(AVAsset *asset);

/* A video sample decoded (JPEG, through ImageIO), or NULL (AVAssetReader.m). */
CGImageRef AVFCopySampleImage(AVFTrack *track, NSData *file, size_t index);
