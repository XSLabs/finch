/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Finch's QuickTime and ISO base media file reader (AVFMovie.m): the movie and its
 * tracks as the file describes them, each track's samples (where they are, how big,
 * when, which are sync samples), its edits and format descriptions, and the user data
 * and metadata the movie and tracks carry. AVAsset and its kin are built on it.
 */
#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreGraphics/CoreGraphics.h>

typedef struct {
    uint64_t offset;
    uint32_t size;
    uint32_t duration;     /* media timescale */
    int64_t decodeTime;    /* media timescale */
    int32_t compositionOffset;
    uint32_t description;  /* index into formatDescriptions */
    uint64_t chunkOffset;
    uint64_t chunkLength;
    uint32_t chunkIndex;
    uint32_t chunkSampleIndex;
    uint32_t chunkSampleCount;
    bool chunkHasUniformSampleSizes;
    bool sync;
} AVFSample;

typedef struct {
    int64_t duration;      /* movie timescale */
    int64_t mediaTime;     /* media timescale; -1: empty */
    double rate;
} AVFEdit;

/* A piece of user data or metadata: a QuickTime user-data text, an 'mdta' key, an
   iTunes item. */
@interface AVFMetadataEntry : NSObject {
@public
    NSString *keySpace;    /* "udta", "mdta", "itsk" */
    id key;                /* NSNumber of the four-character code, or an NSString key */
    id value;              /* NSString, NSData, NSNumber */
    NSString *dataType;    /* a CoreMedia metadata base data type, or nil */
    NSString *language;    /* an ISO 639 code or locale identifier, or nil */
}
@end

@interface AVFTrack : NSObject {
@public
    uint32_t trackID;
    FourCharCode handler;  /* 'vide', 'soun', 'text', 'sbtl', 'clcp', 'tmcd', 'meta' */
    uint32_t flags;
    uint32_t timescale;
    uint64_t mediaDuration;
    uint64_t duration;     /* movie timescale */
    int16_t layer, alternateGroup;
    float volume;
    CGAffineTransform matrix;
    CGSize dimensions;
    NSString *language, *extendedLanguage;
    NSMutableArray *formatDescriptions; /* CMFormatDescriptionRef */
    AVFSample *samples;
    size_t sampleCount;
    uint64_t totalBytes;
    AVFEdit *edits;
    size_t editCount;
    NSMutableArray<AVFMetadataEntry *> *userData;
    NSMutableArray<NSString *> *trackAssociationTypes;
    NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *trackReferences;
    BOOL selfContained;
}
@end

@interface AVFMovie : NSObject {
@public
    NSData *data;
    FourCharCode majorBrand;
    BOOL quickTime;        /* QuickTime ('qt  ' or no 'ftyp') rather than ISO */
    uint32_t nextTrackID;  /* 'mvhd' reservation used by AVAsset's ID picker */
    uint32_t timescale;
    uint64_t duration;
    uint64_t creationTime; /* seconds since 1904 */
    double rate;
    float volume;
    CGAffineTransform matrix;
    NSMutableArray<AVFTrack *> *tracks;
    NSMutableArray<AVFMetadataEntry *> *userData, *metadata;
}
/* Read from the file's bytes; nil, with *error, if they aren't a movie. */
+ (instancetype)movieWithData:(NSData *)data error:(NSError **)error;
@end

/* A four-character code as AVFoundation's identifiers write it ("%A9nam"). */
NSString *AVFKeyString(FourCharCode key);
