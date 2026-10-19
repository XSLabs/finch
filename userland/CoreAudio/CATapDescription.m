/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* CATapDescription keeps the process and device selection used by a Core Audio tap. */
#import <CoreAudio/CATapDescription.h>

@implementation CATapDescription {
    NSString *_name;
    NSUUID *_UUID;
    NSArray *_processes;
    NSArray *_bundleIDs;
    NSString *_deviceUID;
    NSNumber *_stream;
    CATapMuteBehavior _muteBehavior;
    BOOL _mono, _exclusive, _mixdown, _privateTap, _processRestoreEnabled;
}

@synthesize name = _name;
@synthesize UUID = _UUID;
@synthesize processes = _processes;
@synthesize bundleIDs = _bundleIDs;
@synthesize mono = _mono;
@synthesize exclusive = _exclusive;
@synthesize mixdown = _mixdown;
@synthesize privateTap = _privateTap;
@synthesize processRestoreEnabled = _processRestoreEnabled;
@synthesize muteBehavior = _muteBehavior;
@synthesize deviceUID = _deviceUID;
@synthesize stream = _stream;

- (instancetype)init
{
    if ((self = [super init])) {
        _name = [@"Tap" copy];
        _UUID = [[NSUUID alloc] init];
        _processes = [[NSArray alloc] init];
        _bundleIDs = [[NSArray alloc] init];
    }
    return self;
}

- (instancetype)initWithProcesses:(NSArray<NSNumber *> *)processes deviceUID:(NSString *)deviceUID stream:(NSNumber *)stream
                         exclusive:(BOOL)exclusive mono:(BOOL)mono mixdown:(BOOL)mixdown
{
    if ((self = [self init])) {
        self.processes = processes ?: @[];
        self.deviceUID = deviceUID;
        self.stream = stream;
        self.exclusive = exclusive;
        self.mono = mono;
        self.mixdown = mixdown;
    }
    return self;
}

- (instancetype)initStereoMixdownOfProcesses:(NSArray<NSNumber *> *)processes
{
    return [self initWithProcesses:processes deviceUID:nil stream:nil exclusive:NO mono:NO mixdown:YES];
}

- (instancetype)initStereoGlobalTapButExcludeProcesses:(NSArray<NSNumber *> *)processes
{
    return [self initWithProcesses:processes deviceUID:nil stream:nil exclusive:YES mono:NO mixdown:YES];
}

- (instancetype)initMonoMixdownOfProcesses:(NSArray<NSNumber *> *)processes
{
    return [self initWithProcesses:processes deviceUID:nil stream:nil exclusive:NO mono:YES mixdown:YES];
}

- (instancetype)initMonoGlobalTapButExcludeProcesses:(NSArray<NSNumber *> *)processes
{
    return [self initWithProcesses:processes deviceUID:nil stream:nil exclusive:YES mono:YES mixdown:YES];
}

- (instancetype)initWithProcesses:(NSArray<NSNumber *> *)processes andDeviceUID:(NSString *)deviceUID withStream:(NSInteger)stream
{
    return [self initWithProcesses:processes deviceUID:deviceUID stream:@(stream) exclusive:NO mono:NO mixdown:NO];
}

- (instancetype)initExcludingProcesses:(NSArray<NSNumber *> *)processes andDeviceUID:(NSString *)deviceUID withStream:(NSInteger)stream
{
    return [self initWithProcesses:processes deviceUID:deviceUID stream:@(stream) exclusive:YES mono:NO mixdown:NO];
}

- (void)dealloc
{
    [_name release];
    [_UUID release];
    [_processes release];
    [_bundleIDs release];
    [_deviceUID release];
    [_stream release];
    [super dealloc];
}
@end
