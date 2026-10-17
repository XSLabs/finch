// SPDX-License-Identifier: MIT OR Apache-2.0
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#import <Block.h>

static char MPCommandEnabledKey;
static char MPCommandHandlersKey;
static char MPCommandCenterCommandsKey;
static char MPEventCommandKey;
static char MPEventTimestampKey;
static char MPEventValueKey;
static char MPEventExtraKey;
static char MPIntervalsKey;
static char MPFeedbackActiveKey;
static char MPFeedbackTitleKey;
static char MPFeedbackShortTitleKey;
static char MPRatingMinimumKey;
static char MPRatingMaximumKey;
static char MPPlaybackRatesKey;

@interface MPRemoteCommandEvent (FinchInternal)
- (instancetype)_initWithCommand:(MPRemoteCommand *)command timestamp:(NSTimeInterval)timestamp value:(id)value extra:(id)extra;
@end

@interface MPCommandWeakReference : NSObject
{
    id _object;
}
- (instancetype)initWithObject:(id)object;
- (id)load;
@end

@implementation MPCommandWeakReference
- (instancetype)initWithObject:(id)object
{
    self = [super init];
    if (self) objc_storeWeak(&_object, object);
    return self;
}
- (id)load { return [objc_loadWeak(&_object) retain]; }
- (void)dealloc
{
    objc_storeWeak(&_object, nil);
    [super dealloc];
}
@end

@interface MPCommandRegistration : NSObject
{
    MPCommandWeakReference *_target;
    SEL _action;
    MPRemoteCommandHandlerStatus (^_handler)(MPRemoteCommandEvent *);
    id _token;
}
- (instancetype)initWithTarget:(id)target action:(SEL)action handler:(MPRemoteCommandHandlerStatus (^)(MPRemoteCommandEvent *))handler token:(id)token;
- (id)target;
- (SEL)action;
- (MPRemoteCommandHandlerStatus (^)(MPRemoteCommandEvent *))handler;
- (id)token;
@end

@implementation MPCommandRegistration
- (instancetype)initWithTarget:(id)target action:(SEL)action handler:(MPRemoteCommandHandlerStatus (^)(MPRemoteCommandEvent *))handler token:(id)token
{
    self = [super init];
    if (self) {
        _target = [[MPCommandWeakReference alloc] initWithObject:target];
        _action = action;
        _handler = handler ? Block_copy(handler) : NULL;
        _token = [token retain];
    }
    return self;
}
- (id)target { return [_target load]; }
- (SEL)action { return _action; }
- (MPRemoteCommandHandlerStatus (^)(MPRemoteCommandEvent *))handler { return _handler; }
- (id)token { return _token; }
- (void)dealloc
{
    [_target release];
    if (_handler) Block_release(_handler);
    [_token release];
    [super dealloc];
}
@end

@implementation MPRemoteCommandEvent

- (instancetype)_initWithCommand:(MPRemoteCommand *)command timestamp:(NSTimeInterval)timestamp value:(id)value extra:(id)extra
{
    self = [super init];
    if (self) {
        objc_setAssociatedObject(self, &MPEventCommandKey, command, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, &MPEventTimestampKey, [NSNumber numberWithDouble:timestamp], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, &MPEventValueKey, value, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, &MPEventExtraKey, extra, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return self;
}
- (MPRemoteCommand *)command { return objc_getAssociatedObject(self, &MPEventCommandKey); }
- (NSTimeInterval)timestamp { return [objc_getAssociatedObject(self, &MPEventTimestampKey) doubleValue]; }

@end

@implementation MPSkipIntervalCommandEvent
- (NSTimeInterval)interval { return [objc_getAssociatedObject(self, &MPEventValueKey) doubleValue]; }
@end

@implementation MPSeekCommandEvent
- (MPSeekCommandEventType)type { return [objc_getAssociatedObject(self, &MPEventValueKey) unsignedIntegerValue]; }
@end

@implementation MPRatingCommandEvent
- (float)rating { return [objc_getAssociatedObject(self, &MPEventValueKey) floatValue]; }
@end

@implementation MPChangePlaybackRateCommandEvent
- (float)playbackRate { return [objc_getAssociatedObject(self, &MPEventValueKey) floatValue]; }
@end

@implementation MPFeedbackCommandEvent
- (BOOL)isNegative { return [objc_getAssociatedObject(self, &MPEventValueKey) boolValue]; }
@end

@implementation MPChangeLanguageOptionCommandEvent
- (MPNowPlayingInfoLanguageOption *)languageOption { return objc_getAssociatedObject(self, &MPEventValueKey); }
- (MPChangeLanguageOptionSetting)setting { return [objc_getAssociatedObject(self, &MPEventExtraKey) unsignedIntegerValue]; }
@end

@implementation MPChangePlaybackPositionCommandEvent
- (NSTimeInterval)positionTime { return [objc_getAssociatedObject(self, &MPEventValueKey) doubleValue]; }
@end

@implementation MPChangeShuffleModeCommandEvent
- (MPShuffleType)shuffleType { return [objc_getAssociatedObject(self, &MPEventValueKey) unsignedIntegerValue]; }
- (BOOL)preservesShuffleMode { return [objc_getAssociatedObject(self, &MPEventExtraKey) boolValue]; }
@end

@implementation MPChangeRepeatModeCommandEvent
- (MPRepeatType)repeatType { return [objc_getAssociatedObject(self, &MPEventValueKey) unsignedIntegerValue]; }
- (BOOL)preservesRepeatMode { return [objc_getAssociatedObject(self, &MPEventExtraKey) boolValue]; }
@end

@implementation MPRemoteCommand

- (BOOL)isEnabled
{
    NSNumber *value = objc_getAssociatedObject(self, &MPCommandEnabledKey);
    return value ? value.boolValue : YES;
}
- (void)setEnabled:(BOOL)enabled
{
    objc_setAssociatedObject(self, &MPCommandEnabledKey, [NSNumber numberWithBool:enabled], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSMutableArray *)_handlers
{
    NSMutableArray *handlers = objc_getAssociatedObject(self, &MPCommandHandlersKey);
    if (!handlers) {
        handlers = [NSMutableArray array];
        objc_setAssociatedObject(self, &MPCommandHandlersKey, handlers, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        handlers = objc_getAssociatedObject(self, &MPCommandHandlersKey);
    }
    return handlers;
}

- (void)addTarget:(id)target action:(SEL)action
{
    if (!target || !action) [NSException raise:NSInvalidArgumentException format:@"A command target and action are required"];
    MPCommandRegistration *entry = [[MPCommandRegistration alloc] initWithTarget:target action:action handler:nil token:nil];
    @synchronized(self) { [[self _handlers] addObject:entry]; }
    [entry release];
}

- (void)removeTarget:(id)target action:(SEL)action
{
    @synchronized(self) {
        NSMutableArray *handlers = [self _handlers];
        for (NSInteger i = (NSInteger)handlers.count - 1; i >= 0; i--) {
            MPCommandRegistration *entry = [handlers objectAtIndex:(NSUInteger)i];
            id registered = [entry target];
            BOOL matchToken = target && [entry token] == target;
            BOOL matchTarget = target == nil || registered == target;
            BOOL matchAction = action == NULL || [entry action] == action;
            if (matchToken || (matchTarget && matchAction)) [handlers removeObjectAtIndex:(NSUInteger)i];
            [registered release];
        }
    }
}

- (void)removeTarget:(id)target { [self removeTarget:target action:NULL]; }

- (id)addTargetWithHandler:(MPRemoteCommandHandlerStatus (^)(MPRemoteCommandEvent *))handler
{
    if (!handler) [NSException raise:NSInvalidArgumentException format:@"A command handler is required"];
    NSObject *token = [[NSObject alloc] init];
    MPCommandRegistration *entry = [[MPCommandRegistration alloc] initWithTarget:nil action:NULL handler:handler token:token];
    @synchronized(self) { [[self _handlers] addObject:entry]; }
    [entry release];
    return [token autorelease];
}

- (MPRemoteCommandHandlerStatus)_dispatchEvent:(MPRemoteCommandEvent *)event
{
    if (!self.enabled) return MPRemoteCommandHandlerStatusCommandFailed;
    NSArray *entries = nil;
    @synchronized(self) { entries = [[self _handlers] copy]; }
    if (entries.count == 0) { [entries release]; return MPRemoteCommandHandlerStatusNoSuchContent; }
    MPRemoteCommandHandlerStatus result = MPRemoteCommandHandlerStatusNoSuchContent;
    for (MPCommandRegistration *entry in entries) {
        MPRemoteCommandHandlerStatus (^handler)(MPRemoteCommandEvent *) = [entry handler];
        if (handler) {
            result = handler(event);
            continue;
        }
        id target = [entry target];
        SEL action = [entry action];
        if (!target || !action || ![target respondsToSelector:action]) { [target release]; continue; }
        NSMethodSignature *signature = [target methodSignatureForSelector:action];
        if (!signature || signature.numberOfArguments < 3) { [target release]; continue; }
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        invocation.target = target;
        invocation.selector = action;
        id argument = event;
        [invocation setArgument:&argument atIndex:2];
        [invocation invoke];
        const char *returnType = signature.methodReturnType;
        if (returnType && returnType[0] != 'v' && signature.methodReturnLength <= sizeof(result))
            [invocation getReturnValue:&result];
        else result = MPRemoteCommandHandlerStatusSuccess;
        [target release];
    }
    [entries release];
    return result;
}

@end

@implementation MPSkipIntervalCommand
- (NSArray *)preferredIntervals { return objc_getAssociatedObject(self, &MPIntervalsKey); }
- (void)setPreferredIntervals:(NSArray *)value
{
    for (id item in value)
        if (![item isKindOfClass:[NSNumber class]] || [item doubleValue] < 0)
            [NSException raise:NSInvalidArgumentException format:@"Skip intervals must be nonnegative numbers"];
    objc_setAssociatedObject(self, &MPIntervalsKey, [value copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
@end

@implementation MPFeedbackCommand
- (BOOL)isActive { return [objc_getAssociatedObject(self, &MPFeedbackActiveKey) boolValue]; }
- (void)setActive:(BOOL)value { objc_setAssociatedObject(self, &MPFeedbackActiveKey, [NSNumber numberWithBool:value], OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
- (NSString *)localizedTitle { return objc_getAssociatedObject(self, &MPFeedbackTitleKey); }
- (void)setLocalizedTitle:(NSString *)value { objc_setAssociatedObject(self, &MPFeedbackTitleKey, [value copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
- (NSString *)localizedShortTitle { return objc_getAssociatedObject(self, &MPFeedbackShortTitleKey); }
- (void)setLocalizedShortTitle:(NSString *)value { objc_setAssociatedObject(self, &MPFeedbackShortTitleKey, [value copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
@end

@implementation MPRatingCommand
- (float)minimumRating { return [objc_getAssociatedObject(self, &MPRatingMinimumKey) floatValue]; }
- (void)setMinimumRating:(float)value { objc_setAssociatedObject(self, &MPRatingMinimumKey, [NSNumber numberWithFloat:value], OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
- (float)maximumRating { return [objc_getAssociatedObject(self, &MPRatingMaximumKey) floatValue]; }
- (void)setMaximumRating:(float)value { objc_setAssociatedObject(self, &MPRatingMaximumKey, [NSNumber numberWithFloat:value], OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
@end

@implementation MPChangePlaybackRateCommand
- (NSArray *)supportedPlaybackRates { return objc_getAssociatedObject(self, &MPPlaybackRatesKey); }
- (void)setSupportedPlaybackRates:(NSArray *)value
{
    for (id item in value)
        if (![item isKindOfClass:[NSNumber class]] || [item floatValue] <= 0)
            [NSException raise:NSInvalidArgumentException format:@"Playback rates must be positive numbers"];
    objc_setAssociatedObject(self, &MPPlaybackRatesKey, [value copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
@end

@implementation MPChangePlaybackPositionCommand @end
@implementation MPChangeShuffleModeCommand
- (MPShuffleType)currentShuffleType { return [objc_getAssociatedObject(self, &MPRatingMinimumKey) integerValue]; }
- (void)setCurrentShuffleType:(MPShuffleType)value { objc_setAssociatedObject(self, &MPRatingMinimumKey, [NSNumber numberWithInteger:value], OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
@end
@implementation MPChangeRepeatModeCommand
- (MPRepeatType)currentRepeatType { return [objc_getAssociatedObject(self, &MPRatingMaximumKey) integerValue]; }
- (void)setCurrentRepeatType:(MPRepeatType)value { objc_setAssociatedObject(self, &MPRatingMaximumKey, [NSNumber numberWithInteger:value], OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
@end

@implementation MPRemoteCommandCenter

+ (MPRemoteCommandCenter *)sharedCommandCenter
{
    static MPRemoteCommandCenter *center = nil;
    @synchronized(self) { if (!center) center = [[self alloc] init]; }
    return center;
}

- (MPRemoteCommand *)_command:(NSString *)name class:(Class)class
{
    NSMutableDictionary *commands = objc_getAssociatedObject(self, &MPCommandCenterCommandsKey);
    if (!commands) {
        commands = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(self, &MPCommandCenterCommandsKey, commands, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        commands = objc_getAssociatedObject(self, &MPCommandCenterCommandsKey);
    }
    MPRemoteCommand *command = [commands objectForKey:name];
    if (!command) {
        command = [[[class alloc] init] autorelease];
        [commands setObject:command forKey:name];
    }
    return command;
}

#define MP_COMMAND_GETTER(method, type) - (type *)method { return (type *)[self _command:@#method class:[type class]]; }
MP_COMMAND_GETTER(pauseCommand, MPRemoteCommand)
MP_COMMAND_GETTER(playCommand, MPRemoteCommand)
MP_COMMAND_GETTER(stopCommand, MPRemoteCommand)
MP_COMMAND_GETTER(togglePlayPauseCommand, MPRemoteCommand)
MP_COMMAND_GETTER(enableLanguageOptionCommand, MPRemoteCommand)
MP_COMMAND_GETTER(disableLanguageOptionCommand, MPRemoteCommand)
MP_COMMAND_GETTER(changePlaybackRateCommand, MPChangePlaybackRateCommand)
MP_COMMAND_GETTER(changeRepeatModeCommand, MPChangeRepeatModeCommand)
MP_COMMAND_GETTER(changeShuffleModeCommand, MPChangeShuffleModeCommand)
MP_COMMAND_GETTER(nextTrackCommand, MPRemoteCommand)
MP_COMMAND_GETTER(previousTrackCommand, MPRemoteCommand)
MP_COMMAND_GETTER(skipForwardCommand, MPSkipIntervalCommand)
MP_COMMAND_GETTER(skipBackwardCommand, MPSkipIntervalCommand)
MP_COMMAND_GETTER(seekForwardCommand, MPRemoteCommand)
MP_COMMAND_GETTER(seekBackwardCommand, MPRemoteCommand)
MP_COMMAND_GETTER(changePlaybackPositionCommand, MPChangePlaybackPositionCommand)
MP_COMMAND_GETTER(ratingCommand, MPRatingCommand)
MP_COMMAND_GETTER(likeCommand, MPFeedbackCommand)
MP_COMMAND_GETTER(dislikeCommand, MPFeedbackCommand)
MP_COMMAND_GETTER(bookmarkCommand, MPFeedbackCommand)
#undef MP_COMMAND_GETTER

@end
