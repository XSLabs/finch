/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * AVAudioPlayer, Finch's: a sound from a file or from memory, read through
 * ExtAudioFile. With no audio device yet, playing runs a clock at the sound's own
 * pace: the current time advances, meters read the audio under it, loops repeat and
 * the delegate hears that the sound finished, on the main thread, as with Apple's.
 */
#import <AVFAudio/AVFAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#include <dispatch/dispatch.h>
#include <math.h>
#include <mach/mach_time.h>

@interface FinchAudioPlayerState : NSObject {
@public
    NSURL *url;
    NSData *data;
    AudioFileID file;
    ExtAudioFileRef ext;
    AVAudioFormat *format;
    NSDictionary *settings;
    SInt64 frames;
    double rate;
    BOOL playing, meteringEnabled, enableRate;
    float volume, pan, playbackRate;
    NSInteger loops, loopsDone;
    double position;      /* (seconds into the sound when the clock was last read) */
    uint64_t startedHost; /* (host time position was measured at, while playing) */
    dispatch_source_t timer;
    float peak[16], average[16];
    __unsafe_unretained id<AVAudioPlayerDelegate> delegate;
    NSString *device;
    NSArray *assignments;
    CASpatialAudioExperience *experience;
}
@end

@implementation FinchAudioPlayerState
- (void)dealloc
{
    if (timer) {
        dispatch_source_cancel(timer);
        dispatch_release(timer);
    }
    if (ext)
        ExtAudioFileDispose(ext);
    if (file)
        AudioFileClose(file);
    [url release];
    [data release];
    [format release];
    [settings release];
    [device release];
    [assignments release];
    [experience release];
    [super dealloc];
}
@end

static double
host_seconds(uint64_t t)
{
    static mach_timebase_info_data_t i;
    if (!i.denom)
        mach_timebase_info(&i);
    return (double)t * i.numer / i.denom / 1e9;
}

/* (reading a sound held in memory) */
static OSStatus
data_read(void *client, SInt64 at, UInt32 size, void *out, UInt32 *got)
{
    NSData *d = client;
    if (at < 0 || at >= (SInt64)d.length) {
        *got = 0;
        return at == (SInt64)d.length ? noErr : kAudioFileInvalidPacketOffsetError;
    }
    UInt32 n = (UInt32)MIN((SInt64)size, (SInt64)d.length - at);
    memcpy(out, (const char *)d.bytes + at, n);
    *got = n;
    return noErr;
}

static SInt64
data_size(void *client)
{
    return (SInt64)((NSData *)client).length;
}

#define STATE ((FinchAudioPlayerState *)_impl)

@implementation AVAudioPlayer

- (instancetype)_initWithURL:(NSURL *)url data:(NSData *)data error:(NSError **)outError
{
    if (!(self = [super init]))
        return nil;
    FinchAudioPlayerState *s = [FinchAudioPlayerState new];
    _impl = s;
    s->volume = 1;
    s->playbackRate = 1;
    OSStatus e;
    if (url) {
        s->url = [url retain];
        e = AudioFileOpenURL((CFURLRef)url, kAudioFileReadPermission, 0, &s->file);
    } else {
        s->data = [data retain];
        e = AudioFileOpenWithCallbacks(s->data, data_read, NULL, data_size, NULL, 0, &s->file);
    }
    if (!e)
        e = ExtAudioFileWrapAudioFileID(s->file, false, &s->ext);
    AudioStreamBasicDescription asbd = {0};
    UInt32 size = sizeof asbd;
    if (!e)
        e = ExtAudioFileGetProperty(s->ext, kExtAudioFileProperty_FileDataFormat, &size, &asbd);
    size = sizeof s->frames;
    if (!e)
        e = ExtAudioFileGetProperty(s->ext, kExtAudioFileProperty_FileLengthFrames, &size, &s->frames);
    if (e) {
        if (outError)
            *outError = [NSError errorWithDomain:NSOSStatusErrorDomain code:e userInfo:nil];
        [self release];
        return nil;
    }
    s->rate = asbd.mSampleRate;
    s->format = [[AVAudioFormat alloc] initWithStreamDescription:&asbd];
    /* (the format's settings, with the file's type and its bit rate, as Apple's lists them) */
    NSMutableDictionary *settings = [[s->format.settings mutableCopy] autorelease];
    AudioFileTypeID type = 0;
    size = sizeof type;
    AudioFileGetProperty(s->file, kAudioFilePropertyFileFormat, &size, &type);
    settings[AVAudioFileTypeKey] = @(type);
    settings[AVEncoderBitRateKey] = @0;
    s->settings = [settings copy];
    /* (the meters read float audio) */
    AVAudioFormat *client = [[[AVAudioFormat alloc] initStandardFormatWithSampleRate:asbd.mSampleRate channels:asbd.mChannelsPerFrame] autorelease];
    ExtAudioFileSetProperty(s->ext, kExtAudioFileProperty_ClientDataFormat, sizeof(AudioStreamBasicDescription), client.streamDescription);
    for (int i = 0; i < 16; i++)
        s->peak[i] = s->average[i] = -160;
    return self;
}

- (instancetype)initWithContentsOfURL:(NSURL *)url error:(NSError **)outError
{
    return [self _initWithURL:url data:nil error:outError];
}

- (instancetype)initWithContentsOfURL:(NSURL *)url fileTypeHint:(NSString *)utiString error:(NSError **)outError
{
    return [self _initWithURL:url data:nil error:outError];
}

- (instancetype)initWithData:(NSData *)data error:(NSError **)outError
{
    return [self _initWithURL:nil data:data error:outError];
}

- (instancetype)initWithData:(NSData *)data fileTypeHint:(NSString *)utiString error:(NSError **)outError
{
    return [self _initWithURL:nil data:data error:outError];
}

- (void)dealloc
{
    [STATE release];
    [super dealloc];
}

- (double)duration
{
    return STATE->rate > 0 ? (double)STATE->frames / STATE->rate : 0;
}

/* Where the clock is now. */
- (double)_position
{
    FinchAudioPlayerState *s = STATE;
    if (!s->playing)
        return s->position;
    double r = s->playbackRate < 0.5 ? 0.5 : s->playbackRate > 2 ? 2 : s->playbackRate;
    double elapsed = host_seconds(mach_absolute_time() - s->startedHost) * (s->enableRate ? r : 1);
    return s->position + elapsed;
}

- (void)_finish
{
    FinchAudioPlayerState *s = STATE;
    if (!s->playing)
        return;
    double duration = self.duration;
    if (s->loops < 0 || s->loopsDone < s->loops) {
        s->loopsDone++;
        s->position = fmod([self _position], duration > 0 ? duration : 1);
        s->startedHost = mach_absolute_time();
        return;
    }
    [self _stopClock];
    s->playing = NO;
    s->position = 0;
    s->loopsDone = 0;
    id<AVAudioPlayerDelegate> d = s->delegate;
    if ([d respondsToSelector:@selector(audioPlayerDidFinishPlaying:successfully:)])
        [d audioPlayerDidFinishPlaying:self successfully:YES];
}

- (void)_stopClock
{
    if (STATE->timer) {
        dispatch_source_cancel(STATE->timer);
        dispatch_release(STATE->timer);
        STATE->timer = NULL;
    }
}

- (void)_startClock
{
    [self _stopClock];
    FinchAudioPlayerState *s = STATE;
    s->timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    uint64_t tick = 10 * NSEC_PER_MSEC;
    dispatch_source_set_timer(s->timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)tick), tick, tick / 4);
    __block AVAudioPlayer *player = self;
    dispatch_source_set_event_handler(s->timer, ^{
      if ([player _position] >= player.duration)
          [player _finish];
    });
    dispatch_resume(s->timer);
}

- (BOOL)prepareToPlay
{
    return YES;
}

- (BOOL)play
{
    FinchAudioPlayerState *s = STATE;
    if (s->playing)
        return YES;
    s->playing = YES;
    s->startedHost = mach_absolute_time();
    [self _startClock];
    return YES;
}

- (BOOL)playAtTime:(NSTimeInterval)time
{
    double delay = time - self.deviceCurrentTime;
    if (delay <= 0)
        return [self play];
    [self retain];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      [self play];
      [self release];
    });
    return YES;
}

- (void)pause
{
    FinchAudioPlayerState *s = STATE;
    if (!s->playing)
        return;
    s->position = MIN([self _position], self.duration);
    s->playing = NO;
    [self _stopClock];
}

- (void)stop
{
    [self pause];
}

- (BOOL)isPlaying
{
    return STATE->playing;
}

- (NSUInteger)numberOfChannels
{
    return STATE->format.channelCount;
}

- (NSString *)currentDevice
{
    return STATE->device;
}

- (void)setCurrentDevice:(NSString *)d
{
    [STATE->device autorelease];
    STATE->device = [d copy];
}

- (id<AVAudioPlayerDelegate>)delegate
{
    return STATE->delegate;
}

- (void)setDelegate:(id<AVAudioPlayerDelegate>)d
{
    STATE->delegate = d;
}

- (NSURL *)url
{
    return STATE->url;
}

- (NSData *)data
{
    return STATE->data;
}

- (float)pan
{
    return STATE->pan;
}

- (void)setPan:(float)v
{
    STATE->pan = v; /* (kept as given, as Apple's) */
}

- (float)volume
{
    return STATE->volume;
}

- (void)setVolume:(float)v
{
    STATE->volume = v < 0 ? 0 : v;
}

- (void)setVolume:(float)volume fadeDuration:(NSTimeInterval)duration
{
    self.volume = volume;
}

- (BOOL)enableRate
{
    return STATE->enableRate;
}

- (void)setEnableRate:(BOOL)v
{
    STATE->enableRate = v;
}

- (float)rate
{
    return STATE->playbackRate;
}

- (void)setRate:(float)v
{
    FinchAudioPlayerState *s = STATE;
    double now = [self _position];
    s->playbackRate = v; /* (kept as given; played at 0.5 to 2) */
    if (s->playing) {
        s->position = now;
        s->startedHost = mach_absolute_time();
    }
}

- (NSTimeInterval)currentTime
{
    double t = [self _position];
    return t < self.duration ? t : self.duration;
}

- (void)setCurrentTime:(NSTimeInterval)t
{
    FinchAudioPlayerState *s = STATE;
    s->position = t < 0 ? 0 : t > self.duration ? self.duration : t;
    s->startedHost = mach_absolute_time();
}

- (NSTimeInterval)deviceCurrentTime
{
    return host_seconds(mach_absolute_time());
}

- (NSInteger)numberOfLoops
{
    return STATE->loops;
}

- (void)setNumberOfLoops:(NSInteger)n
{
    STATE->loops = n;
}

- (NSDictionary *)settings
{
    return STATE->settings;
}

- (AVAudioFormat *)format
{
    return STATE->format;
}

- (BOOL)isMeteringEnabled
{
    return STATE->meteringEnabled;
}

- (void)setMeteringEnabled:(BOOL)v
{
    STATE->meteringEnabled = v;
}

/* The levels of the audio under the clock (the last 50 ms), in decibels; -160 for silence. */
- (void)updateMeters
{
    FinchAudioPlayerState *s = STATE;
    AVAudioChannelCount channels = s->format.channelCount;
    for (int i = 0; i < 16; i++)
        s->peak[i] = s->average[i] = -160;
    if (!s->meteringEnabled || !s->playing || channels > 16)
        return;
    UInt32 window = (UInt32)(s->rate * 0.05);
    SInt64 end = (SInt64)([self currentTime] * s->rate), start = end - window < 0 ? 0 : end - window;
    UInt32 n = (UInt32)(end - start);
    if (!n)
        return;
    AVAudioFormat *client = [[[AVAudioFormat alloc] initStandardFormatWithSampleRate:s->rate channels:channels] autorelease];
    AVAudioPCMBuffer *b = [[[AVAudioPCMBuffer alloc] initWithPCMFormat:client frameCapacity:n] autorelease];
    if (ExtAudioFileSeek(s->ext, start) || ExtAudioFileRead(s->ext, &n, b.mutableAudioBufferList))
        return;
    for (AVAudioChannelCount c = 0; c < channels; c++) {
        double peak = 0, sum = 0;
        for (UInt32 i = 0; i < n; i++) {
            double v = fabs(b.floatChannelData[c][i]) * s->volume;
            peak = v > peak ? v : peak;
            sum += v * v;
        }
        s->peak[c] = peak > 0 ? (float)fmax(20 * log10(peak), -160) : -160;
        double rms = n ? sqrt(sum / n) : 0;
        s->average[c] = rms > 0 ? (float)fmax(20 * log10(rms), -160) : -160;
    }
}

- (float)peakPowerForChannel:(NSUInteger)channelNumber
{
    return channelNumber < 16 ? STATE->peak[channelNumber] : -160;
}

- (float)averagePowerForChannel:(NSUInteger)channelNumber
{
    return channelNumber < 16 ? STATE->average[channelNumber] : -160;
}

- (NSArray<AVAudioSessionChannelDescription *> *)channelAssignments
{
    return STATE->assignments;
}

- (void)setChannelAssignments:(NSArray<AVAudioSessionChannelDescription *> *)a
{
    [STATE->assignments autorelease];
    STATE->assignments = [a copy];
}

- (CASpatialAudioExperience *)intendedSpatialExperience
{
    return STATE->experience;
}

- (void)setIntendedSpatialExperience:(CASpatialAudioExperience *)e
{
    [STATE->experience autorelease];
    STATE->experience = [e copy];
}

@end
