/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * AVAudioFormat and AVAudioChannelLayout: small value objects that describe PCM
 * samples and channel roles. They use the public Core Audio structs so callers can
 * pass them to AudioToolbox without another conversion layer.
 */
#import <AVFAudio/AVAudioFormat.h>
#import <AVFAudio/AVAudioSettings.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#define AVAUDIO_INIT_FAIL() do { [self release]; return nil; } while (0)

NSString *const AVFormatIDKey = @"AVFormatIDKey";
NSString *const AVSampleRateKey = @"AVSampleRateKey";
NSString *const AVNumberOfChannelsKey = @"AVNumberOfChannelsKey";
NSString *const AVLinearPCMBitDepthKey = @"AVLinearPCMBitDepthKey";
NSString *const AVLinearPCMIsBigEndianKey = @"AVLinearPCMIsBigEndianKey";
NSString *const AVLinearPCMIsFloatKey = @"AVLinearPCMIsFloatKey";
NSString *const AVLinearPCMIsNonInterleaved = @"AVLinearPCMIsNonInterleaved";
NSString *const AVChannelLayoutKey = @"AVChannelLayoutKey";

static UInt32
layout_channels(const AudioChannelLayout *layout)
{
    if (!layout)
        return 0;
    switch (layout->mChannelLayoutTag) {
    case kAudioChannelLayoutTag_UseChannelBitmap:
        return (UInt32)__builtin_popcount(layout->mChannelBitmap);
    case kAudioChannelLayoutTag_UseChannelDescriptions:
        return layout->mNumberChannelDescriptions;
    default:
        return layout->mChannelLayoutTag & 0xffff;
    }
}

static BOOL
layout_data_is_valid(NSData *data)
{
    if (![data isKindOfClass:[NSData class]] || data.length < offsetof(AudioChannelLayout, mChannelDescriptions))
        return NO;
    const AudioChannelLayout *layout = data.bytes;
    if (layout->mChannelLayoutTag != kAudioChannelLayoutTag_UseChannelDescriptions)
        return YES;
    if (layout->mNumberChannelDescriptions > 256)
        return NO;
    size_t needed = offsetof(AudioChannelLayout, mChannelDescriptions) +
                    (size_t)layout->mNumberChannelDescriptions * sizeof(AudioChannelDescription);
    return data.length >= needed;
}

@implementation AVAudioChannelLayout

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)initWithLayoutTag:(AudioChannelLayoutTag)tag
{
    if (tag == kAudioChannelLayoutTag_UseChannelBitmap || tag == kAudioChannelLayoutTag_UseChannelDescriptions)
        AVAUDIO_INIT_FAIL();
    AudioChannelLayout layout = {0};
    layout.mChannelLayoutTag = tag;
    return [self initWithLayout:&layout];
}

- (instancetype)initWithLayout:(const AudioChannelLayout *)layout
{
    if (!layout)
        AVAUDIO_INIT_FAIL();
    UInt32 count = layout->mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions ? layout->mNumberChannelDescriptions : 0;
    if (count > 256)
        AVAUDIO_INIT_FAIL();
    size_t size = offsetof(AudioChannelLayout, mChannelDescriptions) + (size_t)count * sizeof(AudioChannelDescription);
    AudioChannelLayout *copy = calloc(1, size);
    if (!copy)
        AVAUDIO_INIT_FAIL();
    memcpy(copy, layout, size);
    self = [super init];
    if (!self) { free(copy); return nil; }
    _layout = copy;
    _layoutTag = layout->mChannelLayoutTag;
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSData *data = [coder decodeObjectOfClass:[NSData class] forKey:@"layout"];
    if (!layout_data_is_valid(data)) AVAUDIO_INIT_FAIL();
    return [self initWithLayout:data.bytes];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    size_t size = offsetof(AudioChannelLayout, mChannelDescriptions);
    if (_layoutTag == kAudioChannelLayoutTag_UseChannelDescriptions)
        size += _layout->mNumberChannelDescriptions * sizeof(AudioChannelDescription);
    [coder encodeObject:[NSData dataWithBytes:_layout length:size] forKey:@"layout"];
}

- (void)dealloc { free(_layout); [super dealloc]; }
- (AudioChannelLayoutTag)layoutTag { return _layoutTag; }
- (const AudioChannelLayout *)layout { return _layout; }
- (AVAudioChannelCount)channelCount { return layout_channels(_layout); }

- (BOOL)isEqual:(id)object
{
    if (object == self) return YES;
    if (![object isKindOfClass:[AVAudioChannelLayout class]]) return NO;
    AVAudioChannelLayout *other = object;
    if (_layoutTag != other->_layoutTag || self.channelCount != other.channelCount) return NO;
    size_t size = offsetof(AudioChannelLayout, mChannelDescriptions);
    if (_layoutTag == kAudioChannelLayoutTag_UseChannelDescriptions)
        size += _layout->mNumberChannelDescriptions * sizeof(AudioChannelDescription);
    return memcmp(_layout, other->_layout, size) == 0;
}

+ (instancetype)layoutWithLayoutTag:(AudioChannelLayoutTag)tag
{
    return [[[self alloc] initWithLayoutTag:tag] autorelease];
}

+ (instancetype)layoutWithLayout:(const AudioChannelLayout *)layout
{
    return [[[self alloc] initWithLayout:layout] autorelease];
}

@end

struct AVAudioFormatExtra { NSData *magicCookie; CMAudioFormatDescriptionRef description; };

static AVAudioCommonFormat
common_format(const AudioStreamBasicDescription *asbd)
{
    if (asbd->mFormatID != kAudioFormatLinearPCM) return AVAudioOtherFormat;
    UInt32 flags = asbd->mFormatFlags;
    if (flags & kAudioFormatFlagIsBigEndian) return AVAudioOtherFormat;
    if ((flags & kAudioFormatFlagIsFloat) && asbd->mBitsPerChannel == 32) return AVAudioPCMFormatFloat32;
    if ((flags & kAudioFormatFlagIsFloat) && asbd->mBitsPerChannel == 64) return AVAudioPCMFormatFloat64;
    if ((flags & kAudioFormatFlagIsSignedInteger) && asbd->mBitsPerChannel == 16) return AVAudioPCMFormatInt16;
    if ((flags & kAudioFormatFlagIsSignedInteger) && asbd->mBitsPerChannel == 32) return AVAudioPCMFormatInt32;
    return AVAudioOtherFormat;
}

static BOOL
valid_format(const AudioStreamBasicDescription *asbd, AVAudioChannelLayout *layout)
{
    if (!asbd || !isfinite(asbd->mSampleRate) || asbd->mSampleRate <= 0 || !asbd->mChannelsPerFrame)
        return NO;
    if (asbd->mChannelsPerFrame > 2 && (!layout || layout.channelCount != asbd->mChannelsPerFrame))
        return NO;
    if (layout && layout.channelCount != asbd->mChannelsPerFrame)
        return NO;
    if (asbd->mFormatID == kAudioFormatLinearPCM)
        return asbd->mBitsPerChannel > 0 && asbd->mBytesPerFrame > 0 && asbd->mFramesPerPacket > 0;
    return YES;
}

@implementation AVAudioFormat

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)initWithStreamDescription:(const AudioStreamBasicDescription *)asbd
{
    return [self initWithStreamDescription:asbd channelLayout:nil];
}

- (instancetype)initWithStreamDescription:(const AudioStreamBasicDescription *)asbd channelLayout:(AVAudioChannelLayout *)layout
{
    if (!valid_format(asbd, layout)) AVAUDIO_INIT_FAIL();
    self = [super init];
    if (self) {
        _asbd = *asbd;
        _layout = [layout retain];
        _commonFormat = common_format(asbd);
        _reserved = calloc(1, sizeof(struct AVAudioFormatExtra));
        if (!_reserved) { [_layout release]; _layout = nil; [self release]; return nil; }
    }
    return self;
}

- (instancetype)initStandardFormatWithSampleRate:(double)rate channels:(AVAudioChannelCount)channels
{
    return [self initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:rate channels:channels interleaved:NO];
}

- (instancetype)initStandardFormatWithSampleRate:(double)rate channelLayout:(AVAudioChannelLayout *)layout
{
    if (!layout) return nil;
    return [self initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:rate interleaved:NO channelLayout:layout];
}

- (instancetype)initWithCommonFormat:(AVAudioCommonFormat)format sampleRate:(double)rate channels:(AVAudioChannelCount)channels interleaved:(BOOL)interleaved
{
    if (!isfinite(rate) || rate <= 0 || !channels || channels > 2) AVAUDIO_INIT_FAIL();
    UInt32 bits, flags;
    switch (format) {
    case AVAudioPCMFormatFloat32: bits = 32; flags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked; break;
    case AVAudioPCMFormatFloat64: bits = 64; flags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked; break;
    case AVAudioPCMFormatInt16: bits = 16; flags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked; break;
    case AVAudioPCMFormatInt32: bits = 32; flags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked; break;
    default: AVAUDIO_INIT_FAIL();
    }
    if (!interleaved) flags |= kAudioFormatFlagIsNonInterleaved;
    UInt32 sampleBytes = bits / 8;
    UInt32 bytesPerFrame = sampleBytes * (interleaved ? channels : 1);
    AudioStreamBasicDescription asbd = {0};
    asbd.mSampleRate = rate;
    asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mFormatFlags = flags;
    asbd.mBytesPerPacket = bytesPerFrame;
    asbd.mFramesPerPacket = 1;
    asbd.mBytesPerFrame = bytesPerFrame;
    asbd.mChannelsPerFrame = channels;
    asbd.mBitsPerChannel = bits;
    return [self initWithStreamDescription:&asbd];
}

- (instancetype)initWithCommonFormat:(AVAudioCommonFormat)format sampleRate:(double)rate interleaved:(BOOL)interleaved channelLayout:(AVAudioChannelLayout *)layout
{
    if (!layout) AVAUDIO_INIT_FAIL();
    if (!isfinite(rate) || rate <= 0 || !layout.channelCount) AVAUDIO_INIT_FAIL();
    UInt32 bits, flags;
    switch (format) {
    case AVAudioPCMFormatFloat32: bits = 32; flags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked; break;
    case AVAudioPCMFormatFloat64: bits = 64; flags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked; break;
    case AVAudioPCMFormatInt16: bits = 16; flags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked; break;
    case AVAudioPCMFormatInt32: bits = 32; flags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked; break;
    default: AVAUDIO_INIT_FAIL();
    }
    if (!interleaved) flags |= kAudioFormatFlagIsNonInterleaved;
    UInt32 bytesPerFrame = (bits / 8) * (interleaved ? layout.channelCount : 1);
    AudioStreamBasicDescription asbd = {0};
    asbd.mSampleRate = rate; asbd.mFormatID = kAudioFormatLinearPCM; asbd.mFormatFlags = flags;
    asbd.mBytesPerPacket = bytesPerFrame; asbd.mFramesPerPacket = 1; asbd.mBytesPerFrame = bytesPerFrame;
    asbd.mChannelsPerFrame = layout.channelCount; asbd.mBitsPerChannel = bits;
    return [self initWithStreamDescription:&asbd channelLayout:layout];
}

- (instancetype)initWithSettings:(NSDictionary<NSString *,id> *)settings
{
    if (![settings isKindOfClass:[NSDictionary class]]) AVAUDIO_INIT_FAIL();
    id rateObj = settings[AVSampleRateKey];
    id channelsObj = settings[AVNumberOfChannelsKey];
    id formatObj = settings[AVFormatIDKey];
    if (![rateObj isKindOfClass:[NSNumber class]] || ![channelsObj isKindOfClass:[NSNumber class]]) AVAUDIO_INIT_FAIL();
    double rate = [rateObj doubleValue];
    AVAudioChannelCount channels = [channelsObj unsignedIntValue];
    UInt32 formatID = [formatObj isKindOfClass:[NSNumber class]] ? [formatObj unsignedIntValue] : kAudioFormatLinearPCM;
    if (formatID != kAudioFormatLinearPCM || !channels || !isfinite(rate) || rate <= 0) AVAUDIO_INIT_FAIL();
    int bits = [settings[AVLinearPCMBitDepthKey] respondsToSelector:@selector(intValue)] ? [settings[AVLinearPCMBitDepthKey] intValue] : 16;
    BOOL flt = [settings[AVLinearPCMIsFloatKey] respondsToSelector:@selector(boolValue)] && [settings[AVLinearPCMIsFloatKey] boolValue];
    BOOL big = [settings[AVLinearPCMIsBigEndianKey] respondsToSelector:@selector(boolValue)] && [settings[AVLinearPCMIsBigEndianKey] boolValue];
    BOOL noninterleaved = [settings[AVLinearPCMIsNonInterleaved] respondsToSelector:@selector(boolValue)] && [settings[AVLinearPCMIsNonInterleaved] boolValue];
    if (bits != 8 && bits != 16 && bits != 24 && bits != 32) AVAUDIO_INIT_FAIL();
    if (flt && bits != 32) AVAUDIO_INIT_FAIL();
    UInt32 flags = kAudioFormatFlagIsPacked | (flt ? kAudioFormatFlagIsFloat : (bits > 8 ? kAudioFormatFlagIsSignedInteger : 0));
    if (big) flags |= kAudioFormatFlagIsBigEndian;
    if (noninterleaved) flags |= kAudioFormatFlagIsNonInterleaved;
    UInt32 bpf = ((bits + 7) / 8) * (noninterleaved ? 1 : channels);
    AudioStreamBasicDescription asbd = {rate, formatID, flags, bpf, 1, bpf, channels, (UInt32)bits, 0};
    AVAudioChannelLayout *layout = nil;
    id layoutObject = settings[AVChannelLayoutKey];
    if (layoutObject) {
        if (!layout_data_is_valid(layoutObject)) AVAUDIO_INIT_FAIL();
        layout = [[AVAudioChannelLayout alloc] initWithLayout:[layoutObject bytes]];
        if (!layout) AVAUDIO_INIT_FAIL();
    }
    self = [self initWithStreamDescription:&asbd channelLayout:layout];
    [layout release];
    return self;
}

#if AVAUDIOFORMAT_HAVE_CMFORMATDESCRIPTION
- (instancetype)initWithCMAudioFormatDescription:(CMAudioFormatDescriptionRef)description
{
    if (!description) AVAUDIO_INIT_FAIL();
    const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description);
    if (!asbd) AVAUDIO_INIT_FAIL();
    const AudioChannelLayout *rawLayout = CMAudioFormatDescriptionGetChannelLayout(description, NULL);
    AVAudioChannelLayout *layout = rawLayout ? [[AVAudioChannelLayout alloc] initWithLayout:rawLayout] : nil;
    self = [self initWithStreamDescription:asbd channelLayout:layout];
    [layout release];
    return self;
}

- (CMAudioFormatDescriptionRef)formatDescription
{
    struct AVAudioFormatExtra *extra = _reserved;
    if (extra->description) return extra->description;
    size_t layoutSize = 0;
    if (_layout) {
        layoutSize = offsetof(AudioChannelLayout, mChannelDescriptions);
        if (_layout.layoutTag == kAudioChannelLayoutTag_UseChannelDescriptions)
            layoutSize += _layout.layout->mNumberChannelDescriptions * sizeof(AudioChannelDescription);
    }
    CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &_asbd, layoutSize, _layout.layout,
                                   self.magicCookie.length, self.magicCookie.bytes, NULL, &extra->description);
    return extra->description;
}
#endif

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSData *data = [coder decodeObjectOfClass:[NSData class] forKey:@"asbd"];
    AVAudioChannelLayout *layout = [coder decodeObjectOfClass:[AVAudioChannelLayout class] forKey:@"layout"];
    if (!data || data.length != sizeof(AudioStreamBasicDescription)) AVAUDIO_INIT_FAIL();
    self = [self initWithStreamDescription:data.bytes channelLayout:layout];
    if (self) self.magicCookie = [coder decodeObjectOfClass:[NSData class] forKey:@"cookie"];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:[NSData dataWithBytes:&_asbd length:sizeof(_asbd)] forKey:@"asbd"];
    if (_layout) [coder encodeObject:_layout forKey:@"layout"];
    if (self.magicCookie) [coder encodeObject:self.magicCookie forKey:@"cookie"];
}

- (void)dealloc
{
    [_layout release];
    struct AVAudioFormatExtra *extra = _reserved;
    if (extra) {
        [extra->magicCookie release];
        if (extra->description) CFRelease(extra->description);
        free(extra);
    }
    [super dealloc];
}

- (BOOL)isEqual:(id)object
{
    if (object == self) return YES;
    if (![object isKindOfClass:[AVAudioFormat class]]) return NO;
    AVAudioFormat *other = object;
    UInt32 flags = _asbd.mFormatFlags, otherFlags = other->_asbd.mFormatFlags;
    if (_asbd.mChannelsPerFrame == 1 && other->_asbd.mChannelsPerFrame == 1) {
        flags &= ~kAudioFormatFlagIsNonInterleaved;
        otherFlags &= ~kAudioFormatFlagIsNonInterleaved;
    }
    if (_asbd.mFormatID != other->_asbd.mFormatID || _asbd.mSampleRate != other->_asbd.mSampleRate ||
        _asbd.mChannelsPerFrame != other->_asbd.mChannelsPerFrame || _asbd.mBitsPerChannel != other->_asbd.mBitsPerChannel ||
        _asbd.mBytesPerFrame != other->_asbd.mBytesPerFrame || flags != otherFlags)
        return NO;
    if (_layout == other->_layout) return YES;
    if (!_layout || !other->_layout) {
        AVAudioChannelLayout *present = _layout ?: other->_layout;
        return !present || present.layoutTag == kAudioChannelLayoutTag_Mono || present.layoutTag == kAudioChannelLayoutTag_Stereo;
    }
    return [_layout isEqual:other->_layout];
}

- (BOOL)isStandard { return _commonFormat == AVAudioPCMFormatFloat32 && !self.interleaved; }
- (AVAudioCommonFormat)commonFormat { return _commonFormat; }
- (AVAudioChannelCount)channelCount { return _asbd.mChannelsPerFrame; }
- (double)sampleRate { return _asbd.mSampleRate; }
- (BOOL)isInterleaved { return !(_asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved); }
- (const AudioStreamBasicDescription *)streamDescription { return &_asbd; }
- (AVAudioChannelLayout *)channelLayout { return _layout; }
- (NSData *)magicCookie { return ((struct AVAudioFormatExtra *)_reserved)->magicCookie; }
- (void)setMagicCookie:(NSData *)cookie
{
    struct AVAudioFormatExtra *extra = _reserved;
    if (extra->magicCookie != cookie) {
        [cookie retain]; [extra->magicCookie release]; extra->magicCookie = cookie;
#if AVAUDIOFORMAT_HAVE_CMFORMATDESCRIPTION
        if (extra->description) { CFRelease(extra->description); extra->description = NULL; }
#endif
    }
}

- (NSDictionary<NSString *,id> *)settings
{
    NSMutableDictionary *settings = [NSMutableDictionary dictionary];
    settings[AVFormatIDKey] = @(_asbd.mFormatID);
    settings[AVSampleRateKey] = @(_asbd.mSampleRate);
    settings[AVNumberOfChannelsKey] = @(_asbd.mChannelsPerFrame);
    if (_asbd.mFormatID == kAudioFormatLinearPCM) {
        settings[AVLinearPCMBitDepthKey] = @(_asbd.mBitsPerChannel);
        settings[AVLinearPCMIsFloatKey] = @((_asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0);
        settings[AVLinearPCMIsBigEndianKey] = @((_asbd.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0);
        settings[AVLinearPCMIsNonInterleaved] = @((_asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0);
    }
    if (_layout) {
        size_t size = offsetof(AudioChannelLayout, mChannelDescriptions);
        if (_layout.layoutTag == kAudioChannelLayoutTag_UseChannelDescriptions)
            size += _layout.layout->mNumberChannelDescriptions * sizeof(AudioChannelDescription);
        settings[AVChannelLayoutKey] = [NSData dataWithBytes:_layout.layout length:size];
    }
    return settings;
}

@end
