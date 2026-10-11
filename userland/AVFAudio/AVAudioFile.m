/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* AVAudioFile: PCM and G.711 file access through ExtAudioFile. */
#import <AVFAudio/AVAudioFile.h>
#import <AVFAudio/AVAudioBuffer.h>
#import <AVFAudio/AVAudioSettings.h>
#import <AudioToolbox/AudioConverter.h>
#import <AudioToolbox/ExtendedAudioFile.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

NSString *const AVAudioFileTypeKey = @"AVAudioFileTypeKey";

@interface AVAudioFile () {
    void *_impl;
}
@end

struct AVAudioFileImpl {
    ExtAudioFileRef file;
    NSURL *url;
    AVAudioFormat *fileFormat;
    AVAudioFormat *processingFormat;
    AVAudioFramePosition position;
    AVAudioFramePosition cachedLength;
    BOOL writing;
};

static NSError *
audio_error(OSStatus status, NSString *message)
{
    return [NSError errorWithDomain:NSOSStatusErrorDomain code:status
        userInfo:@{NSLocalizedDescriptionKey: message}];
}

static void
set_audio_error(NSError **outError, OSStatus status, NSString *message)
{
    if (outError)
        *outError = audio_error(status, message);
}

static AVAudioChannelLayout *
layout_from_settings(NSDictionary *settings, UInt32 channels)
{
    id object = settings[AVChannelLayoutKey];
    if (!object)
        return nil;
    if (![object isKindOfClass:[NSData class]])
        return nil;
    NSData *data = object;
    if (data.length < offsetof(AudioChannelLayout, mChannelDescriptions))
        return nil;
    const AudioChannelLayout *layout = data.bytes;
    if (layout->mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions) {
        if (layout->mNumberChannelDescriptions > 256)
            return nil;
        size_t needed = offsetof(AudioChannelLayout, mChannelDescriptions) +
            (size_t)layout->mNumberChannelDescriptions * sizeof(AudioChannelDescription);
        if (data.length < needed)
            return nil;
    }
    AVAudioChannelLayout *result = [[AVAudioChannelLayout alloc] initWithLayout:layout];
    if (!result || result.channelCount != channels) {
        [result release];
        return nil;
    }
    return result;
}

static AVAudioChannelLayout *
layout_from_file(ExtAudioFileRef file, UInt32 channels)
{
    UInt32 size = 0;
    OSStatus status = ExtAudioFileGetPropertyInfo(file, kExtAudioFileProperty_FileChannelLayout, &size, NULL);
    const size_t baseSize = offsetof(AudioChannelLayout, mChannelDescriptions);
    const size_t maxSize = baseSize + 256 * sizeof(AudioChannelDescription);
    if (status || size < baseSize || size > maxSize)
        return nil;
    AudioChannelLayout *raw = calloc(1, size);
    if (!raw)
        return nil;
    UInt32 actualSize = size;
    status = ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileChannelLayout, &actualSize, raw);
    AVAudioChannelLayout *result = nil;
    if (!status && actualSize >= offsetof(AudioChannelLayout, mChannelDescriptions)) {
        if (raw->mChannelLayoutTag != kAudioChannelLayoutTag_UseChannelDescriptions ||
            raw->mNumberChannelDescriptions <= 256) {
            size_t needed = offsetof(AudioChannelLayout, mChannelDescriptions);
            if (raw->mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions)
                needed += (size_t)raw->mNumberChannelDescriptions * sizeof(AudioChannelDescription);
            if (actualSize >= needed) {
                result = [[AVAudioChannelLayout alloc] initWithLayout:raw];
                if (result && result.channelCount != channels) {
                    [result release];
                    result = nil;
                }
            }
        }
    }
    free(raw);
    return result;
}

static AVAudioFormat *
format_from_file(ExtAudioFileRef file, NSError **outError)
{
    AudioStreamBasicDescription asbd = {0};
    UInt32 size = sizeof(asbd);
    OSStatus status = ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &asbd);
    if (status || size != sizeof(asbd)) {
        set_audio_error(outError, status ? status : kAudioFileBadPropertySizeError,
            @"Could not read the audio file format.");
        return nil;
    }
    if (!asbd.mChannelsPerFrame || asbd.mChannelsPerFrame > 256) {
        set_audio_error(outError, kAudioFileUnsupportedDataFormatError,
            @"This audio file has an unsupported channel count.");
        return nil;
    }
    AVAudioChannelLayout *layout = layout_from_file(file, asbd.mChannelsPerFrame);
    if (asbd.mChannelsPerFrame > 2 && !layout) {
        set_audio_error(outError, kAudioFileUnsupportedDataFormatError,
            @"This multichannel file does not include a usable channel layout.");
        return nil;
    }
    AVAudioFormat *format = [[AVAudioFormat alloc] initWithStreamDescription:&asbd channelLayout:layout];
    [layout release];
    if (!format)
        set_audio_error(outError, kAudioFileUnsupportedDataFormatError,
            @"The audio file format cannot be represented by AVAudioFormat.");
    return format;
}

static AVAudioFormat *
processing_format(AVAudioFormat *fileFormat, AVAudioCommonFormat commonFormat, BOOL interleaved)
{
    if (fileFormat.channelLayout)
        return [[AVAudioFormat alloc] initWithCommonFormat:commonFormat sampleRate:fileFormat.sampleRate
            interleaved:interleaved channelLayout:fileFormat.channelLayout];
    return [[AVAudioFormat alloc] initWithCommonFormat:commonFormat sampleRate:fileFormat.sampleRate
        channels:fileFormat.channelCount interleaved:interleaved];
}

static AudioFileTypeID
file_type_for_url(NSURL *url)
{
    NSString *extension = [[url.path pathExtension] lowercaseString];
    if ([extension isEqualToString:@"wav"] || [extension isEqualToString:@"wave"])
        return kAudioFileWAVEType;
    if ([extension isEqualToString:@"aif"] || [extension isEqualToString:@"aiff"])
        return kAudioFileAIFFType;
    if ([extension isEqualToString:@"aifc"])
        return kAudioFileAIFCType;
    if ([extension isEqualToString:@"caf"])
        return kAudioFileCAFType;
    if ([extension isEqualToString:@"snd"] || [extension isEqualToString:@"au"])
        return kAudioFileNextType;
    return 0;
}

static AVAudioFormat *
file_format_from_settings(NSDictionary *settings, NSError **outError)
{
    id rateObject = settings[AVSampleRateKey];
    id channelsObject = settings[AVNumberOfChannelsKey];
    id formatObject = settings[AVFormatIDKey];
    if (![rateObject isKindOfClass:[NSNumber class]] ||
        ![channelsObject isKindOfClass:[NSNumber class]]) {
        set_audio_error(outError, kAudio_ParamError,
            @"Audio settings need a sample rate and channel count.");
        return nil;
    }
    double rate = [rateObject doubleValue];
    UInt32 channels = [channelsObject unsignedIntValue];
    UInt32 formatID = [formatObject isKindOfClass:[NSNumber class]] ?
        [formatObject unsignedIntValue] : kAudioFormatLinearPCM;
    if (!isfinite(rate) || rate <= 0 || !channels || channels > 256) {
        set_audio_error(outError, kAudio_ParamError, @"The audio settings contain an invalid rate or channel count.");
        return nil;
    }

    if (formatID == kAudioFormatLinearPCM) {
        NSMutableDictionary *interleavedSettings = [NSMutableDictionary dictionaryWithDictionary:settings];
        interleavedSettings[AVLinearPCMIsNonInterleaved] = @NO;
        AVAudioFormat *format = [[AVAudioFormat alloc] initWithSettings:interleavedSettings];
        if (!format)
            set_audio_error(outError, kAudioFileUnsupportedDataFormatError,
                @"The requested PCM file format is not supported.");
        return format;
    }

    if (formatID == kAudioFormatULaw || formatID == kAudioFormatALaw) {
        AVAudioChannelLayout *layout = layout_from_settings(settings, channels);
        if (channels > 2 && !layout) {
            set_audio_error(outError, kAudioFileUnsupportedDataFormatError,
                @"Multichannel G.711 files need a matching channel layout.");
            return nil;
        }
        AudioStreamBasicDescription asbd = {0};
        asbd.mSampleRate = rate;
        asbd.mFormatID = formatID;
        asbd.mBytesPerPacket = channels;
        asbd.mFramesPerPacket = 1;
        asbd.mBytesPerFrame = channels;
        asbd.mChannelsPerFrame = channels;
        asbd.mBitsPerChannel = 8;
        AVAudioFormat *format = [[AVAudioFormat alloc] initWithStreamDescription:&asbd channelLayout:layout];
        [layout release];
        if (!format)
            set_audio_error(outError, kAudioFileUnsupportedDataFormatError,
                @"The requested G.711 file format is not supported.");
        return format;
    }

    set_audio_error(outError, kAudioConverterErr_FormatNotSupported,
        @"This audio codec is not supported by Finch's audio file layer.");
    return nil;
}

static AVAudioFormat *
processing_format_from_settings(AVAudioFormat *fileFormat, AVAudioCommonFormat commonFormat,
    BOOL interleaved, NSError **outError)
{
    AVAudioFormat *format = processing_format(fileFormat, commonFormat, interleaved);
    if (!format)
        set_audio_error(outError, kAudioConverterErr_FormatNotSupported,
            @"The requested processing format is not supported.");
    return format;
}

static OSStatus
set_client_format(ExtAudioFileRef file, AVAudioFormat *format)
{
    const AudioStreamBasicDescription *asbd = format.streamDescription;
    OSStatus status = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
        sizeof(*asbd), asbd);
    if (status)
        return status;
    if (format.channelLayout) {
        const AudioChannelLayout *layout = format.channelLayout.layout;
        UInt32 size = offsetof(AudioChannelLayout, mChannelDescriptions);
        if (layout->mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions)
            size += layout->mNumberChannelDescriptions * sizeof(AudioChannelDescription);
        status = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientChannelLayout, size, layout);
    }
    return status;
}

static BOOL
same_multichannel_layout(AVAudioFormat *a, AVAudioFormat *b)
{
    if (a.channelCount <= 2 && b.channelCount <= 2)
        return YES;
    return a.channelLayout && b.channelLayout && [a.channelLayout isEqual:b.channelLayout];
}

static void
dispose_file(struct AVAudioFileImpl *impl)
{
    if (!impl || !impl->file)
        return;
    SInt64 position = impl->position;
    if (ExtAudioFileTell(impl->file, &position) == noErr)
        impl->position = position;
    SInt64 length = impl->cachedLength;
    UInt32 size = sizeof(length);
    if (ExtAudioFileGetProperty(impl->file, kExtAudioFileProperty_FileLengthFrames, &size, &length) == noErr)
        impl->cachedLength = length;
    ExtAudioFileDispose(impl->file);
    impl->file = NULL;
}

@implementation AVAudioFile

- (instancetype)init
{
    [self release];
    return nil;
}

- (instancetype)initForReading:(NSURL *)fileURL error:(NSError **)outError
{
    if (outError) *outError = nil;
    if (![fileURL isKindOfClass:[NSURL class]] || !fileURL.isFileURL) {
        [self release];
        set_audio_error(outError, kAudio_ParamError, @"AVAudioFile needs a file URL.");
        return nil;
    }

    ExtAudioFileRef file = NULL;
    OSStatus status = ExtAudioFileOpenURL((CFURLRef)fileURL, &file);
    if (status) {
        if (file)
            ExtAudioFileDispose(file);
        [self release];
        set_audio_error(outError, status, @"Could not open the audio file for reading.");
        return nil;
    }
    AVAudioFormat *diskFormat = format_from_file(file, outError);
    AVAudioFormat *clientFormat = diskFormat ? processing_format(diskFormat, AVAudioPCMFormatFloat32, NO) : nil;
    if (!diskFormat || !clientFormat || !same_multichannel_layout(diskFormat, clientFormat)) {
        if (diskFormat && clientFormat)
            set_audio_error(outError, kAudioFileUnsupportedDataFormatError,
                @"The file's channel layout cannot be preserved while reading.");
        [diskFormat release];
        [clientFormat release];
        ExtAudioFileDispose(file);
        [self release];
        return nil;
    }
    status = set_client_format(file, clientFormat);
    if (status) {
        [diskFormat release];
        [clientFormat release];
        ExtAudioFileDispose(file);
        [self release];
        set_audio_error(outError, status, @"Could not set the audio file's processing format.");
        return nil;
    }

    self = [super init];
    if (!self) {
        [diskFormat release];
        [clientFormat release];
        ExtAudioFileDispose(file);
        return nil;
    }
    struct AVAudioFileImpl *impl = calloc(1, sizeof(*impl));
    if (!impl) {
        [diskFormat release];
        [clientFormat release];
        ExtAudioFileDispose(file);
        [self release];
        set_audio_error(outError, -108, @"Could not allocate the audio file object.");
        return nil;
    }
    impl->file = file;
    impl->url = [fileURL retain];
    impl->fileFormat = diskFormat;
    impl->processingFormat = clientFormat;
    _impl = impl;
    return self;
}

- (instancetype)initForReading:(NSURL *)fileURL commonFormat:(AVAudioCommonFormat)format
    interleaved:(BOOL)interleaved error:(NSError **)outError
{
    if (outError) *outError = nil;
    if (![fileURL isKindOfClass:[NSURL class]] || !fileURL.isFileURL) {
        [self release];
        set_audio_error(outError, kAudio_ParamError, @"AVAudioFile needs a file URL.");
        return nil;
    }
    ExtAudioFileRef file = NULL;
    OSStatus status = ExtAudioFileOpenURL((CFURLRef)fileURL, &file);
    if (status) {
        if (file)
            ExtAudioFileDispose(file);
        [self release];
        set_audio_error(outError, status, @"Could not open the audio file for reading.");
        return nil;
    }
    AVAudioFormat *diskFormat = format_from_file(file, outError);
    AVAudioFormat *clientFormat = diskFormat ? processing_format(diskFormat, format, interleaved) : nil;
    if (!diskFormat || !clientFormat || !same_multichannel_layout(diskFormat, clientFormat)) {
        if (diskFormat && !clientFormat)
            set_audio_error(outError, kAudioConverterErr_FormatNotSupported,
                @"The requested processing format is not supported.");
        else if (diskFormat && clientFormat)
            set_audio_error(outError, kAudioFileUnsupportedDataFormatError,
                @"The file's channel layout cannot be preserved while reading.");
        [diskFormat release];
        [clientFormat release];
        ExtAudioFileDispose(file);
        [self release];
        return nil;
    }
    status = set_client_format(file, clientFormat);
    if (status) {
        [diskFormat release];
        [clientFormat release];
        ExtAudioFileDispose(file);
        [self release];
        set_audio_error(outError, status, @"Could not set the audio file's processing format.");
        return nil;
    }
    self = [super init];
    if (!self) {
        [diskFormat release];
        [clientFormat release];
        ExtAudioFileDispose(file);
        return nil;
    }
    struct AVAudioFileImpl *impl = calloc(1, sizeof(*impl));
    if (!impl) {
        [diskFormat release];
        [clientFormat release];
        ExtAudioFileDispose(file);
        [self release];
        set_audio_error(outError, -108, @"Could not allocate the audio file object.");
        return nil;
    }
    impl->file = file;
    impl->url = [fileURL retain];
    impl->fileFormat = diskFormat;
    impl->processingFormat = clientFormat;
    _impl = impl;
    return self;
}

- (instancetype)initForWriting:(NSURL *)fileURL settings:(NSDictionary<NSString *,id> *)settings error:(NSError **)outError
{
    if (outError) *outError = nil;
    if (![fileURL isKindOfClass:[NSURL class]] || !fileURL.isFileURL ||
        ![settings isKindOfClass:[NSDictionary class]]) {
        [self release];
        set_audio_error(outError, kAudio_ParamError, @"AVAudioFile needs a file URL and audio settings.");
        return nil;
    }
    AVAudioFormat *diskFormat = file_format_from_settings(settings, outError);
    if (!diskFormat) {
        [self release];
        return nil;
    }
    AVAudioFormat *clientFormat = processing_format(diskFormat, AVAudioPCMFormatFloat32, NO);
    if (!clientFormat || !same_multichannel_layout(diskFormat, clientFormat)) {
        [diskFormat release];
        [clientFormat release];
        [self release];
        set_audio_error(outError, kAudioFileUnsupportedDataFormatError,
            @"The file's channel layout cannot be preserved while writing.");
        return nil;
    }
    AudioFileTypeID fileType = file_type_for_url(fileURL);
    id typeObject = settings[AVAudioFileTypeKey];
    if (typeObject) {
        if (![typeObject isKindOfClass:[NSNumber class]]) {
            [diskFormat release];
            [clientFormat release];
            [self release];
            set_audio_error(outError, kAudio_ParamError, @"The audio file type setting must be a number.");
            return nil;
        }
        fileType = [typeObject unsignedIntValue];
    }
    if (!fileType) {
        [diskFormat release];
        [clientFormat release];
        [self release];
        set_audio_error(outError, kAudioFileUnsupportedFileTypeError,
            @"The file extension does not name a supported audio file type.");
        return nil;
    }

    const AudioChannelLayout *layout = diskFormat.channelLayout.layout;
    ExtAudioFileRef file = NULL;
    OSStatus status = ExtAudioFileCreateWithURL((CFURLRef)fileURL, fileType,
        diskFormat.streamDescription, layout, kAudioFileFlags_EraseFile, &file);
    if (!status)
        status = set_client_format(file, clientFormat);
    if (status) {
        if (file)
            ExtAudioFileDispose(file);
        [diskFormat release];
        [clientFormat release];
        [self release];
        set_audio_error(outError, status, @"Could not create the audio file with the requested settings.");
        return nil;
    }
    self = [super init];
    if (!self) {
        [diskFormat release];
        [clientFormat release];
        ExtAudioFileDispose(file);
        return nil;
    }
    struct AVAudioFileImpl *impl = calloc(1, sizeof(*impl));
    if (!impl) {
        [diskFormat release];
        [clientFormat release];
        ExtAudioFileDispose(file);
        [self release];
        set_audio_error(outError, -108, @"Could not allocate the audio file object.");
        return nil;
    }
    impl->file = file;
    impl->url = [fileURL retain];
    impl->fileFormat = diskFormat;
    impl->processingFormat = clientFormat;
    impl->writing = YES;
    _impl = impl;
    return self;
}

- (instancetype)initForWriting:(NSURL *)fileURL settings:(NSDictionary<NSString *,id> *)settings
    commonFormat:(AVAudioCommonFormat)commonFormat interleaved:(BOOL)interleaved error:(NSError **)outError
{
    if (outError) *outError = nil;
    if (![fileURL isKindOfClass:[NSURL class]] || !fileURL.isFileURL ||
        ![settings isKindOfClass:[NSDictionary class]]) {
        [self release];
        set_audio_error(outError, kAudio_ParamError, @"AVAudioFile needs a file URL and audio settings.");
        return nil;
    }
    AVAudioFormat *diskFormat = file_format_from_settings(settings, outError);
    if (!diskFormat) {
        [self release];
        return nil;
    }
    AVAudioFormat *clientFormat = processing_format_from_settings(diskFormat, commonFormat, interleaved, outError);
    if (!clientFormat || !same_multichannel_layout(diskFormat, clientFormat)) {
        [diskFormat release];
        [clientFormat release];
        [self release];
        if (outError && !*outError)
            set_audio_error(outError, kAudioFileUnsupportedDataFormatError,
                @"The file's channel layout cannot be preserved while writing.");
        return nil;
    }
    AudioFileTypeID fileType = file_type_for_url(fileURL);
    id typeObject = settings[AVAudioFileTypeKey];
    if (typeObject) {
        if (![typeObject isKindOfClass:[NSNumber class]]) {
            [diskFormat release];
            [clientFormat release];
            [self release];
            set_audio_error(outError, kAudio_ParamError, @"The audio file type setting must be a number.");
            return nil;
        }
        fileType = [typeObject unsignedIntValue];
    }
    if (!fileType) {
        [diskFormat release];
        [clientFormat release];
        [self release];
        set_audio_error(outError, kAudioFileUnsupportedFileTypeError,
            @"The file extension does not name a supported audio file type.");
        return nil;
    }
    const AudioChannelLayout *layout = diskFormat.channelLayout.layout;
    ExtAudioFileRef file = NULL;
    OSStatus status = ExtAudioFileCreateWithURL((CFURLRef)fileURL, fileType,
        diskFormat.streamDescription, layout, kAudioFileFlags_EraseFile, &file);
    if (!status)
        status = set_client_format(file, clientFormat);
    if (status) {
        if (file)
            ExtAudioFileDispose(file);
        [diskFormat release];
        [clientFormat release];
        [self release];
        set_audio_error(outError, status, @"Could not create the audio file with the requested settings.");
        return nil;
    }
    self = [super init];
    if (!self) {
        [diskFormat release];
        [clientFormat release];
        ExtAudioFileDispose(file);
        return nil;
    }
    struct AVAudioFileImpl *impl = calloc(1, sizeof(*impl));
    if (!impl) {
        [diskFormat release];
        [clientFormat release];
        ExtAudioFileDispose(file);
        [self release];
        set_audio_error(outError, -108, @"Could not allocate the audio file object.");
        return nil;
    }
    impl->file = file;
    impl->url = [fileURL retain];
    impl->fileFormat = diskFormat;
    impl->processingFormat = clientFormat;
    impl->writing = YES;
    _impl = impl;
    return self;
}

- (void)close
{
    dispose_file(_impl);
}

- (BOOL)isOpen
{
    return _impl && ((struct AVAudioFileImpl *)_impl)->file != NULL;
}

- (NSURL *)url { return ((struct AVAudioFileImpl *)_impl)->url; }
- (AVAudioFormat *)fileFormat { return ((struct AVAudioFileImpl *)_impl)->fileFormat; }
- (AVAudioFormat *)processingFormat { return ((struct AVAudioFileImpl *)_impl)->processingFormat; }

- (AVAudioFramePosition)length
{
    struct AVAudioFileImpl *impl = _impl;
    if (!impl->file)
        return impl->cachedLength;
    SInt64 frames = impl->cachedLength;
    UInt32 size = sizeof(frames);
    if (ExtAudioFileGetProperty(impl->file, kExtAudioFileProperty_FileLengthFrames, &size, &frames) != noErr)
        return impl->cachedLength;
    impl->cachedLength = frames;
    return frames;
}

- (AVAudioFramePosition)framePosition
{
    struct AVAudioFileImpl *impl = _impl;
    if (impl->file) {
        SInt64 position = impl->position;
        if (ExtAudioFileTell(impl->file, &position) == noErr)
            impl->position = position;
    }
    return impl->position;
}

- (void)setFramePosition:(AVAudioFramePosition)position
{
    struct AVAudioFileImpl *impl = _impl;
    if (!impl->file)
        return;
    OSStatus status = ExtAudioFileSeek(impl->file, position);
    if (status)
        [NSException raise:NSInvalidArgumentException
            format:@"Could not move the audio file to frame %lld (error %d).", (long long)position, (int)status];
    impl->position = position;
}

- (BOOL)readIntoBuffer:(AVAudioPCMBuffer *)buffer error:(NSError **)outError
{
    return [self readIntoBuffer:buffer frameCount:buffer.frameCapacity error:outError];
}

- (BOOL)readIntoBuffer:(AVAudioPCMBuffer *)buffer frameCount:(AVAudioFrameCount)frames error:(NSError **)outError
{
    if (outError) *outError = nil;
    struct AVAudioFileImpl *impl = _impl;
    if (!impl->file) {
        set_audio_error(outError, kAudioFileNotOpenError, @"The audio file is closed.");
        return NO;
    }
    if (impl->writing || ![buffer isKindOfClass:[AVAudioPCMBuffer class]] ||
        ![buffer.format isEqual:impl->processingFormat]) {
        set_audio_error(outError, kAudio_ParamError, @"The read buffer must match the file's processing format.");
        return NO;
    }
    if (frames > buffer.frameCapacity) {
        set_audio_error(outError, kAudio_ParamError, @"The requested frame count exceeds the buffer capacity.");
        return NO;
    }
    buffer.frameLength = frames;
    if (!frames)
        return YES;
    UInt32 readFrames = frames;
    OSStatus status = ExtAudioFileRead(impl->file, &readFrames, buffer.mutableAudioBufferList);
    if (status) {
        buffer.frameLength = 0;
        set_audio_error(outError, status, @"Could not read audio frames.");
        return NO;
    }
    buffer.frameLength = readFrames;
    (void)[self framePosition];
    return readFrames != 0;
}

- (BOOL)writeFromBuffer:(const AVAudioPCMBuffer *)buffer error:(NSError **)outError
{
    if (outError) *outError = nil;
    struct AVAudioFileImpl *impl = _impl;
    if (!impl->file) {
        set_audio_error(outError, kAudioFileNotOpenError, @"The audio file is closed.");
        return NO;
    }
    if (!impl->writing || ![buffer isKindOfClass:[AVAudioPCMBuffer class]] ||
        ![buffer.format isEqual:impl->processingFormat]) {
        set_audio_error(outError, kAudio_ParamError, @"The write buffer must match the file's processing format.");
        return NO;
    }
    UInt32 frames = buffer.frameLength;
    OSStatus status = ExtAudioFileWrite(impl->file, frames, buffer.audioBufferList);
    if (status) {
        set_audio_error(outError, status, @"Could not write audio frames.");
        return NO;
    }
    if (impl->position >= 0 && frames <= (UInt64)(INT64_MAX - impl->position)) {
        impl->position += frames;
        if (impl->position > impl->cachedLength)
            impl->cachedLength = impl->position;
    }
    (void)[self framePosition];
    return YES;
}

- (void)dealloc
{
    struct AVAudioFileImpl *impl = _impl;
    if (impl) {
        dispose_file(impl);
        [impl->url release];
        [impl->fileFormat release];
        [impl->processingFormat release];
        free(impl);
    }
    [super dealloc];
}

@end
