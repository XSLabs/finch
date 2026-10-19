/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* File and settings state for recording when an audio input device is available. */
#import <AVFAudio/AVAudioRecorder.h>
#import <Foundation/Foundation.h>

@implementation AVAudioRecorder {
    NSURL *_fURL;
    NSDictionary *_fSettings;
    AVAudioFormat *_fFormat;
    id<AVAudioRecorderDelegate> _fDelegate;
    NSArray *_fChannelAssignments;
    BOOL _fMeteringEnabled;
}

- (instancetype)initWithURL:(NSURL *)URL settings:(NSDictionary<NSString *,id> *)settings error:(NSError **)outError
{
    if (!URL.isFileURL || !settings) {
        if (outError)
            *outError = [NSError errorWithDomain:@"AVFoundationErrorDomain" code:-11843 userInfo:nil];
        [self release];
        return nil;
    }
    if ((self = [super init])) {
        _fURL = [URL copy];
        _fSettings = [settings copy];
        _fFormat = [[AVAudioFormat alloc] initWithSettings:settings];
    }
    return self;
}

- (instancetype)initWithURL:(NSURL *)URL format:(AVAudioFormat *)format error:(NSError **)outError
{
    if (!format) {
        if (outError)
            *outError = [NSError errorWithDomain:@"AVFoundationErrorDomain" code:-11843 userInfo:nil];
        [self release];
        return nil;
    }
    return [self initWithURL:URL settings:format.settings error:outError];
}

- (void)dealloc
{
    [_fURL release];
    [_fSettings release];
    [_fFormat release];
    [_fChannelAssignments release];
    [super dealloc];
}

- (BOOL)prepareToRecord { return NO; }
- (BOOL)record { return NO; }
- (BOOL)recordAtTime:(NSTimeInterval)time { (void)time; return NO; }
- (BOOL)recordForDuration:(NSTimeInterval)duration { (void)duration; return NO; }
- (BOOL)recordAtTime:(NSTimeInterval)time forDuration:(NSTimeInterval)duration { (void)time; (void)duration; return NO; }
- (void)pause {}
- (void)stop {}
- (BOOL)deleteRecording
{
    if ([[NSFileManager defaultManager] fileExistsAtPath:_fURL.path])
        return [[NSFileManager defaultManager] removeItemAtURL:_fURL error:nil];
    return NO;
}
- (BOOL)isRecording { return NO; }
- (NSURL *)url { return _fURL; }
- (NSDictionary<NSString *,id> *)settings { return _fSettings; }
- (AVAudioFormat *)format { return _fFormat; }
- (id<AVAudioRecorderDelegate>)delegate { return _fDelegate; }
- (void)setDelegate:(id<AVAudioRecorderDelegate>)delegate { _fDelegate = delegate; }
- (NSTimeInterval)currentTime { return 0; }
- (NSTimeInterval)deviceCurrentTime { return 0; }
- (BOOL)isMeteringEnabled { return _fMeteringEnabled; }
- (void)setMeteringEnabled:(BOOL)enabled { _fMeteringEnabled = enabled; }
- (void)updateMeters {}
- (float)peakPowerForChannel:(NSUInteger)channel { (void)channel; return -160.0f; }
- (float)averagePowerForChannel:(NSUInteger)channel { (void)channel; return -160.0f; }
- (NSArray<AVAudioSessionChannelDescription *> *)channelAssignments { return _fChannelAssignments; }
- (void)setChannelAssignments:(NSArray<AVAudioSessionChannelDescription *> *)assignments
{
    [_fChannelAssignments release];
    _fChannelAssignments = [assignments copy];
}

@end
