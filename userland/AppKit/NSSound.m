/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSSound: a sound from a file or data, played through AudioToolbox's system sounds.
 * Sounds are found by name as on macOS (the app's resources, then ~/Library/Sounds,
 * /Library/Sounds and /System/Library/Sounds). Durations are read from WAVE, AIFF and
 * CAF headers. With no audio device (Finch has no audio driver yet) playing still
 * runs its course: the delegate hears that it finished.
 */
#import "AppKit_Finch.h"
#import <AudioToolbox/AudioToolbox.h>
#include <dlfcn.h>

/* AudioToolbox, loaded when a sound first plays (AppKit is built before it). */
static OSStatus (*create_sound)(CFURLRef, SystemSoundID *);
static OSStatus (*dispose_sound)(SystemSoundID);
static OSStatus (*add_completion)(SystemSoundID, CFRunLoopRef, CFStringRef, AudioServicesSystemSoundCompletionProc, void *);
static void (*play_sound)(SystemSoundID);

static BOOL
audio_toolbox(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      void *h = dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox", RTLD_LAZY);
      if (!h)
          return;
      create_sound = dlsym(h, "AudioServicesCreateSystemSoundID");
      dispose_sound = dlsym(h, "AudioServicesDisposeSystemSoundID");
      add_completion = dlsym(h, "AudioServicesAddSystemSoundCompletion");
      play_sound = dlsym(h, "AudioServicesPlaySystemSound");
    });
    return create_sound && play_sound;
}


static NSMutableDictionary *named_sounds;

static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]; }
static uint32_t le32(const uint8_t *p) { return (uint32_t)p[3] << 24 | p[2] << 16 | p[1] << 8 | p[0]; }

/* AIFF's sample rate: an 80-bit extended float. */
static double
finch_extended80(const uint8_t *p)
{
    int exponent = ((p[0] & 0x7f) << 8 | p[1]) - 16383;
    uint64_t mantissa = 0;
    for (int i = 0; i < 8; i++)
        mantissa = mantissa << 8 | p[2 + i];
    return ldexp((double)mantissa, exponent - 63);
}

/* The duration in a WAVE, AIFF or CAF header (0 if it can't be read). */
static NSTimeInterval
header_duration(NSData *d)
{
    const uint8_t *b = d.bytes;
    NSUInteger n = d.length;
    if (n >= 12 && !memcmp(b, "RIFF", 4) && !memcmp(b + 8, "WAVE", 4)) {
        uint32_t byteRate = 0, dataSize = 0;
        for (NSUInteger at = 12; at + 8 <= n;) {
            uint32_t size = le32(b + at + 4);
            if (!memcmp(b + at, "fmt ", 4) && at + 16 <= n)
                byteRate = le32(b + at + 16);
            if (!memcmp(b + at, "data", 4))
                dataSize = size;
            at += 8 + size + (size & 1);
        }
        return byteRate ? (double)dataSize / byteRate : 0;
    }
    if (n >= 12 && !memcmp(b, "FORM", 4) && (!memcmp(b + 8, "AIFF", 4) || !memcmp(b + 8, "AIFC", 4))) {
        for (NSUInteger at = 12; at + 8 <= n;) {
            uint32_t size = be32(b + at + 4);
            if (!memcmp(b + at, "COMM", 4) && at + 26 <= n) {
                uint32_t frames = be32(b + at + 10);
                double rate = finch_extended80(b + at + 16);
                return rate > 0 ? frames / rate : 0;
            }
            at += 8 + size + (size & 1);
        }
    }
    if (n >= 8 && !memcmp(b, "caff", 4)) {
        double rate = 0;
        uint32_t framesPerPacket = 0, bytesPerPacket = 0;
        int64_t packets = -1, dataBytes = -1;
        for (NSUInteger at = 8; at + 12 <= n;) {
            int64_t size = (int64_t)((uint64_t)be32(b + at + 4) << 32 | be32(b + at + 8));
            const uint8_t *c = b + at + 12;
            if (!memcmp(b + at, "desc", 4) && at + 12 + 32 <= n) {
                uint64_t bits = (uint64_t)be32(c) << 32 | be32(c + 4);
                memcpy(&rate, &bits, 8);
                bytesPerPacket = be32(c + 16);
                framesPerPacket = be32(c + 20);
            } else if (!memcmp(b + at, "pakt", 4) && at + 12 + 8 <= n) {
                packets = (int64_t)((uint64_t)be32(c) << 32 | be32(c + 4));
            } else if (!memcmp(b + at, "data", 4)) {
                dataBytes = size >= 4 ? size - 4 : -1;
            }
            if (size < 0)
                break;
            at += 12 + (NSUInteger)size;
        }
        if (rate <= 0)
            return 0;
        if (packets < 0 && bytesPerPacket && dataBytes >= 0)
            packets = dataBytes / bytesPerPacket;
        return packets >= 0 && framesPerPacket ? (double)packets * framesPerPacket / rate : 0;
    }
    return 0;
}

@implementation NSSound {
    NSString *_name;
    NSURL *_url;
    NSData *_data;
    __weak id<NSSoundDelegate> _delegate;
    float _volume;
    BOOL _loops, _playing, _paused;
    NSTimeInterval _duration, _started, _offset;
    SystemSoundID _sound;
    NSString *_device;
    NSArray *_channels;
}

+ (NSArray<NSString *> *)soundUnfilteredTypes
{
    return @[ @"com.microsoft.waveform-audio", @"public.aiff-audio", @"public.aifc-audio", @"com.apple.coreaudio-format",
              @"public.mp3", @"public.mpeg-4-audio", @"com.apple.m4a-audio" ];
}

+ (NSArray *)soundUnfilteredFileTypes { return @[ @"wav", @"aif", @"aiff", @"aifc", @"caf", @"mp3", @"m4a" ]; }
+ (NSArray *)soundUnfilteredPasteboardTypes { return @[ NSSoundPboardType ]; }

+ (NSSound *)soundNamed:(NSSoundName)name
{
    if (!name)
        return nil;
    NSSound *s = named_sounds[name];
    if (s)
        return s;
    NSArray *dirs = @[ [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Sounds"], @"/Library/Sounds",
                       @"/System/Library/Sounds" ];
    NSString *path = nil;
    for (NSString *ext in [self soundUnfilteredFileTypes]) {
        path = [[NSBundle mainBundle] pathForResource:name ofType:ext];
        if (path)
            break;
    }
    for (NSUInteger i = 0; !path && i < dirs.count; i++)
        for (NSString *ext in [self soundUnfilteredFileTypes]) {
            NSString *p = [[dirs[i] stringByAppendingPathComponent:name] stringByAppendingPathExtension:ext];
            if ([[NSFileManager defaultManager] fileExistsAtPath:p]) {
                path = p;
                break;
            }
        }
    if (!path)
        return nil;
    s = [[[NSSound alloc] initWithContentsOfFile:path byReference:YES] autorelease];
    [s setName:name];
    return s;
}

- (instancetype)initWithContentsOfURL:(NSURL *)url byReference:(BOOL)byRef
{
    NSData *d = url ? [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:NULL] : nil;
    if (!d) {
        [self release];
        return nil;
    }
    if ((self = [self initWithData:d]))
        _url = [url copy];
    return self;
}

- (instancetype)initWithContentsOfFile:(NSString *)path byReference:(BOOL)byRef
{
    return [self initWithContentsOfURL:path ? [NSURL fileURLWithPath:path] : nil byReference:byRef];
}

- (instancetype)initWithData:(NSData *)data
{
    if (!data.length) {
        [self release];
        return nil;
    }
    if ((self = [super init])) {
        _data = [data copy];
        _volume = 1;
        _duration = header_duration(data);
    }
    return self;
}

+ (BOOL)canInitWithPasteboard:(NSPasteboard *)pasteboard { return [pasteboard dataForType:NSSoundPboardType] != nil; }
- (instancetype)initWithPasteboard:(NSPasteboard *)pasteboard { return [self initWithData:[pasteboard dataForType:NSSoundPboardType]]; }
- (void)writeToPasteboard:(NSPasteboard *)pasteboard
{
    [pasteboard declareTypes:@[ NSSoundPboardType ] owner:nil];
    [pasteboard setData:_data forType:NSSoundPboardType];
}

- (void)dealloc
{
    if (_sound && dispose_sound)
        dispose_sound(_sound);
    if (_name && named_sounds[_name] == self)
        [named_sounds removeObjectForKey:_name];
    [_name release];
    [_url release];
    [_data release];
    [_device release];
    [_channels release];
    [super dealloc];
}

- (NSSoundName)name { return _name; }

/* Naming a sound registers it for +soundNamed: (NO if the name is taken). */
- (BOOL)setName:(NSSoundName)name
{
    if (name && named_sounds[name] && named_sounds[name] != self)
        return NO;
    if (!named_sounds)
        named_sounds = [NSMutableDictionary new];
    if (_name)
        [named_sounds removeObjectForKey:_name];
    [_name autorelease];
    _name = [name copy];
    if (name)
        [named_sounds setObject:self forKey:name];
    return YES;
}

- (id<NSSoundDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<NSSoundDelegate>)delegate { _delegate = delegate; }
- (NSTimeInterval)duration { return _duration; }
- (float)volume { return _volume; }
- (void)setVolume:(float)volume { _volume = volume; }
- (BOOL)loops { return _loops; }
- (void)setLoops:(BOOL)loops { _loops = loops; }
- (BOOL)isPlaying { return _playing && !_paused; }
- (NSString *)playbackDeviceIdentifier { return _device; }
- (void)setPlaybackDeviceIdentifier:(NSString *)d
{
    [_device autorelease];
    _device = [d copy];
}
- (NSArray *)channelMapping { return _channels; }
- (void)setChannelMapping:(NSArray *)m
{
    [_channels autorelease];
    _channels = [m copy];
}

- (NSTimeInterval)currentTime
{
    if (!_playing)
        return _offset;
    return _paused ? _offset : MIN(_duration, _offset + CFAbsoluteTimeGetCurrent() - _started);
}

- (void)setCurrentTime:(NSTimeInterval)t { _offset = t; }

static void
finished(SystemSoundID sid, void *info)
{
    NSSound *s = (NSSound *)info;
    dispatch_async(dispatch_get_main_queue(), ^{ [s _finchFinished]; });
}

- (void)_finchFinished
{
    if (!_playing || _paused)
        return;
    /* the end, after the sound's length (at once on a device that played nothing) */
    NSTimeInterval left = _duration - (CFAbsoluteTimeGetCurrent() - _started) - _offset;
    if (left > 0.01) {
        [self performSelector:@selector(_finchFinished) withObject:nil afterDelay:left];
        return;
    }
    if (_loops) {
        _offset = 0;
        _playing = NO;
        [self play];
        return;
    }
    _playing = NO;
    _offset = 0;
    id<NSSoundDelegate> d = _delegate;
    [self retain];
    if ([d respondsToSelector:@selector(sound:didFinishPlaying:)])
        [d sound:self didFinishPlaying:YES];
    [self release];
    [self release]; /* the play's own */
}

- (BOOL)play
{
    if (_playing)
        return NO;
    if (!_sound) {
        NSURL *url = _url;
        if (!url) {
            NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
            [_data writeToFile:tmp atomically:NO];
            url = [NSURL fileURLWithPath:tmp];
        }
        if (audio_toolbox()) {
            create_sound((CFURLRef)url, &_sound);
            if (add_completion)
                add_completion(_sound, NULL, NULL, finished, self);
        }
    }
    _playing = YES;
    _paused = NO;
    _started = CFAbsoluteTimeGetCurrent();
    [self retain]; /* a playing sound lives until it ends, as Apple's */
    if (_sound && play_sound)
        play_sound(_sound);
    else
        [self performSelector:@selector(_finchFinished) withObject:nil afterDelay:_duration];
    return YES;
}

- (BOOL)pause
{
    if (!_playing || _paused)
        return NO;
    _offset += CFAbsoluteTimeGetCurrent() - _started;
    _paused = YES;
    return YES;
}

- (BOOL)resume
{
    if (!_paused)
        return NO;
    _paused = NO;
    _started = CFAbsoluteTimeGetCurrent();
    [self performSelector:@selector(_finchFinished) withObject:nil afterDelay:MAX(0, _duration - _offset)];
    return YES;
}

- (BOOL)stop
{
    if (!_playing)
        return NO;
    _playing = NO;
    _paused = NO;
    _offset = 0;
    id<NSSoundDelegate> d = _delegate;
    if ([d respondsToSelector:@selector(sound:didFinishPlaying:)])
        [d sound:self didFinishPlaying:NO];
    [self release];
    return YES;
}

- (id)copyWithZone:(NSZone *)zone { return [[NSSound allocWithZone:zone] initWithData:_data]; }

+ (BOOL)supportsSecureCoding { return YES; }
- (void)encodeWithCoder:(NSCoder *)coder { [coder encodeObject:_data forKey:@"NSSoundData"]; }
- (instancetype)initWithCoder:(NSCoder *)coder
{
    return [self initWithData:[coder decodeObjectOfClass:[NSData class] forKey:@"NSSoundData"]];
}

@end

/* NSBeep's sound by name, and the bundle's own lookup. */
@implementation NSBundle (NSBundleSoundExtensions)
- (NSString *)pathForSoundResource:(NSSoundName)name
{
    for (NSString *ext in [NSSound soundUnfilteredFileTypes]) {
        NSString *p = [self pathForResource:name ofType:ext];
        if (p)
            return p;
    }
    return nil;
}
@end
