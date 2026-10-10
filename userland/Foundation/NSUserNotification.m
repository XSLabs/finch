/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSUserNotification (the older notifications, before UserNotifications.framework):
 * scheduled and delivered within the app, as UserNotifications' are on Finch. A
 * delivered notification is added to the center's list and its delegate told; with no
 * Notification Center to show it in yet, it's written to the system log. And the user
 * script tasks: NSUserUnixTask runs a script from the app's Application Scripts folder;
 * AppleScript and Automator need OSA, which Finch doesn't have yet, so those fail.
 */
#import <Foundation/Foundation.h>
#include <os/log.h>

NSString *const NSUserNotificationDefaultSoundName = @"DefaultSoundName";

@implementation NSUserNotificationAction {
    NSString *_identifier, *_title;
}
+ (instancetype)actionWithIdentifier:(NSString *)identifier title:(NSString *)title
{
    NSUserNotificationAction *a = [[[self alloc] init] autorelease];
    a->_identifier = [identifier copy];
    a->_title = [title copy];
    return a;
}
- (void)dealloc
{
    [_identifier release];
    [_title release];
    [super dealloc];
}
- (NSString *)identifier { return _identifier; }
- (NSString *)title { return _title; }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }
@end

@implementation NSUserNotification {
    NSString *_title, *_subtitle, *_informativeText, *_actionButtonTitle, *_otherButtonTitle, *_soundName, *_identifier;
    NSString *_responsePlaceholder;
    NSDictionary *_userInfo;
    NSDate *_deliveryDate, *_actualDeliveryDate;
    NSTimeZone *_deliveryTimeZone;
    NSDateComponents *_repeat;
    id _contentImage;
    NSArray *_actions;
    BOOL _presented, _hasActionButton, _hasReplyButton;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _actionButtonTitle = @"Show";
        _otherButtonTitle = @"Close";
        _hasActionButton = YES;
    }
    return self;
}

- (void)dealloc
{
    for (id o in @[ _title ?: @"", _subtitle ?: @"", _informativeText ?: @"", _soundName ?: @"", _identifier ?: @"",
                    _responsePlaceholder ?: @"" ])
        (void)o;
    [_title release];
    [_subtitle release];
    [_informativeText release];
    [_actionButtonTitle release];
    [_otherButtonTitle release];
    [_soundName release];
    [_identifier release];
    [_responsePlaceholder release];
    [_userInfo release];
    [_deliveryDate release];
    [_actualDeliveryDate release];
    [_deliveryTimeZone release];
    [_repeat release];
    [_contentImage release];
    [_actions release];
    [super dealloc];
}

#define COPY_PROPERTY(type, getter, setter, ivar)                                                              \
    -(type)getter { return ivar; }                                                                             \
    -(void)setter:(type)v                                                                                      \
    {                                                                                                          \
        [ivar autorelease];                                                                                    \
        ivar = [v copy];                                                                                       \
    }
COPY_PROPERTY(NSString *, title, setTitle, _title)
COPY_PROPERTY(NSString *, subtitle, setSubtitle, _subtitle)
COPY_PROPERTY(NSString *, informativeText, setInformativeText, _informativeText)
COPY_PROPERTY(NSString *, actionButtonTitle, setActionButtonTitle, _actionButtonTitle)
COPY_PROPERTY(NSString *, otherButtonTitle, setOtherButtonTitle, _otherButtonTitle)
COPY_PROPERTY(NSString *, soundName, setSoundName, _soundName)
COPY_PROPERTY(NSString *, identifier, setIdentifier, _identifier)
COPY_PROPERTY(NSString *, responsePlaceholder, setResponsePlaceholder, _responsePlaceholder)
COPY_PROPERTY(NSDictionary *, userInfo, setUserInfo, _userInfo)
COPY_PROPERTY(NSDate *, deliveryDate, setDeliveryDate, _deliveryDate)
COPY_PROPERTY(NSTimeZone *, deliveryTimeZone, setDeliveryTimeZone, _deliveryTimeZone)
COPY_PROPERTY(NSDateComponents *, deliveryRepeatInterval, setDeliveryRepeatInterval, _repeat)
COPY_PROPERTY(id, contentImage, setContentImage, _contentImage)
COPY_PROPERTY(NSArray *, additionalActions, setAdditionalActions, _actions)

- (NSDate *)actualDeliveryDate { return _actualDeliveryDate; }
- (BOOL)isPresented { return _presented; }
- (BOOL)isRemote { return NO; }
- (BOOL)hasActionButton { return _hasActionButton; }
- (void)setHasActionButton:(BOOL)v { _hasActionButton = v; }
- (BOOL)hasReplyButton { return _hasReplyButton; }
- (void)setHasReplyButton:(BOOL)v { _hasReplyButton = v; }
- (NSUserNotificationActivationType)activationType { return NSUserNotificationActivationTypeNone; }
- (NSAttributedString *)response { return nil; }
- (NSUserNotificationAction *)additionalActivationAction { return nil; }

- (void)_finchDeliveredAt:(NSDate *)date presented:(BOOL)presented
{
    [_actualDeliveryDate autorelease];
    _actualDeliveryDate = [date copy];
    _presented = presented;
}

- (id)copyWithZone:(NSZone *)zone
{
    NSUserNotification *n = [[NSUserNotification allocWithZone:zone] init];
    n.title = _title;
    n.subtitle = _subtitle;
    n.informativeText = _informativeText;
    n.actionButtonTitle = _actionButtonTitle;
    n.otherButtonTitle = _otherButtonTitle;
    n.soundName = _soundName;
    n.identifier = _identifier;
    n.userInfo = _userInfo;
    n.deliveryDate = _deliveryDate;
    n.deliveryTimeZone = _deliveryTimeZone;
    n.deliveryRepeatInterval = _repeat;
    n.contentImage = _contentImage;
    n.additionalActions = _actions;
    n.hasActionButton = _hasActionButton;
    n.hasReplyButton = _hasReplyButton;
    n.responsePlaceholder = _responsePlaceholder;
    return n;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<NSUserNotification: %p: title: %@ id: %@>", self, _title, _identifier];
}

@end

@implementation NSUserNotificationCenter {
    id<NSUserNotificationCenterDelegate> _delegate; /* not retained, as Apple's (assign) */
    NSMutableArray *_scheduled, *_delivered;
    NSMutableDictionary *_timers; /* notification (pointer) -> timer */
}

+ (NSUserNotificationCenter *)defaultUserNotificationCenter
{
    static NSUserNotificationCenter *center;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ center = [[NSUserNotificationCenter alloc] init]; });
    return center;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _scheduled = [NSMutableArray new];
        _delivered = [NSMutableArray new];
        _timers = [NSMutableDictionary new];
    }
    return self;
}

- (id<NSUserNotificationCenterDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<NSUserNotificationCenterDelegate>)delegate { _delegate = delegate; }

- (NSArray *)scheduledNotifications { return [[_scheduled copy] autorelease]; }

- (void)setScheduledNotifications:(NSArray *)notifications
{
    for (NSUserNotification *n in [[_scheduled copy] autorelease])
        [self removeScheduledNotification:n];
    for (NSUserNotification *n in notifications)
        [self scheduleNotification:n];
}

- (NSArray *)deliveredNotifications { return [[_delivered copy] autorelease]; }

- (void)scheduleNotification:(NSUserNotification *)notification
{
    NSDate *when = notification.deliveryDate ?: [NSDate date];
    [_scheduled addObject:notification];
    NSTimer *t = [NSTimer timerWithTimeInterval:MAX(0, [when timeIntervalSinceNow]) target:self
                                       selector:@selector(_finchFire:) userInfo:notification repeats:NO];
    [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
    _timers[[NSValue valueWithNonretainedObject:notification]] = t;
}

- (void)_finchFire:(NSTimer *)t
{
    NSUserNotification *n = [[t.userInfo retain] autorelease];
    [_timers removeObjectForKey:[NSValue valueWithNonretainedObject:n]];
    NSDateComponents *repeat = n.deliveryRepeatInterval;
    if (!repeat)
        [_scheduled removeObject:n];
    [self deliverNotification:n];
    if (repeat) {
        NSDate *next = [[NSCalendar currentCalendar] dateByAddingComponents:repeat toDate:[NSDate date] options:0];
        if (next) {
            NSTimer *again = [NSTimer timerWithTimeInterval:MAX(1, [next timeIntervalSinceNow]) target:self
                                                   selector:@selector(_finchFire:) userInfo:n repeats:NO];
            [[NSRunLoop mainRunLoop] addTimer:again forMode:NSRunLoopCommonModes];
            _timers[[NSValue valueWithNonretainedObject:n]] = again;
        }
    }
}

- (void)removeScheduledNotification:(NSUserNotification *)notification
{
    NSValue *k = [NSValue valueWithNonretainedObject:notification];
    [_timers[k] invalidate];
    [_timers removeObjectForKey:k];
    [_scheduled removeObject:notification];
}

/* Delivered: listed, the delegate told; shown (in the log, for now) when the delegate
   allows it or the app isn't frontmost. */
- (void)deliverNotification:(NSUserNotification *)notification
{
    id<NSUserNotificationCenterDelegate> d = _delegate;
    BOOL present = [d respondsToSelector:@selector(userNotificationCenter:shouldPresentNotification:)]
                       ? [d userNotificationCenter:self shouldPresentNotification:notification]
                       : YES;
    for (NSUserNotification *old in [[_delivered copy] autorelease])
        if (notification.identifier && [old.identifier isEqualToString:notification.identifier])
            [_delivered removeObject:old];
    [(id)notification _finchDeliveredAt:[NSDate date] presented:present];
    [_delivered addObject:notification];
    if (present)
        os_log(OS_LOG_DEFAULT, "notification from %{public}@: %{public}@ %{public}@ %{public}@",
               [NSBundle mainBundle].bundleIdentifier, notification.title, notification.subtitle, notification.informativeText);
    if ([d respondsToSelector:@selector(userNotificationCenter:didDeliverNotification:)])
        [d userNotificationCenter:self didDeliverNotification:notification];
}

- (void)removeDeliveredNotification:(NSUserNotification *)notification { [_delivered removeObject:notification]; }
- (void)removeAllDeliveredNotifications { [_delivered removeAllObjects]; }

@end

/* --- user script tasks --- */

static NSURL *
scripts_dir(void)
{
    NSString *bundleID = [NSBundle mainBundle].bundleIdentifier ?: [[NSProcessInfo processInfo] processName];
    return [NSURL fileURLWithPath:[[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Scripts"]
                                      stringByAppendingPathComponent:bundleID]
                      isDirectory:YES];
}

@implementation NSUserScriptTask {
    @protected
    NSURL *_finchScriptURL;
}

- (instancetype)initWithURL:(NSURL *)url error:(NSError **)error
{
    NSString *dir = scripts_dir().path;
    if (![url.URLByStandardizingPath.path hasPrefix:dir] || ![[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
        if (error)
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoPermissionError
                                     userInfo:@{NSURLErrorKey : url ?: [NSNull null]}];
        [self release];
        return nil;
    }
    if ([self isMemberOfClass:[NSUserScriptTask class]]) {
        /* the kind of task by the script's type */
        NSString *ext = url.pathExtension.lowercaseString;
        Class c = [@[ @"scpt", @"scptd", @"applescript" ] containsObject:ext] ? [NSUserAppleScriptTask class]
                  : [ext isEqualToString:@"workflow"]                         ? [NSUserAutomatorTask class]
                                                                              : [NSUserUnixTask class];
        [self release];
        return [[c alloc] initWithURL:url error:error];
    }
    if ((self = [super init]))
        _finchScriptURL = [url copy];
    return self;
}

- (void)dealloc
{
    [_finchScriptURL release];
    [super dealloc];
}

- (NSURL *)scriptURL { return _finchScriptURL; }

- (void)executeWithCompletionHandler:(NSUserScriptTaskCompletionHandler)handler
{
    if (handler)
        handler([NSError errorWithDomain:NSCocoaErrorDomain code:NSFeatureUnsupportedError userInfo:nil]);
}

@end

@implementation NSUserUnixTask {
    NSFileHandle *_in, *_out, *_err;
}

- (void)dealloc
{
    [_in release];
    [_out release];
    [_err release];
    [super dealloc];
}

- (NSFileHandle *)standardInput { return _in; }
- (void)setStandardInput:(NSFileHandle *)h
{
    [_in autorelease];
    _in = [h retain];
}
- (NSFileHandle *)standardOutput { return _out; }
- (void)setStandardOutput:(NSFileHandle *)h
{
    [_out autorelease];
    _out = [h retain];
}
- (NSFileHandle *)standardError { return _err; }
- (void)setStandardError:(NSFileHandle *)h
{
    [_err autorelease];
    _err = [h retain];
}

- (void)executeWithArguments:(NSArray<NSString *> *)arguments completionHandler:(NSUserUnixTaskCompletionHandler)handler
{
    NSTask *task = [[[NSTask alloc] init] autorelease];
    task.executableURL = _finchScriptURL;
    task.arguments = arguments ?: @[];
    if (_in)
        task.standardInput = _in;
    if (_out)
        task.standardOutput = _out;
    if (_err)
        task.standardError = _err;
    NSUserUnixTaskCompletionHandler h = [[handler copy] autorelease];
    task.terminationHandler = ^(NSTask *t) {
      if (h)
          h(t.terminationStatus == 0 ? nil
                                     : [NSError errorWithDomain:NSPOSIXErrorDomain code:t.terminationStatus userInfo:nil]);
    };
    NSError *error = nil;
    if (![task launchAndReturnError:&error] && h)
        h(error);
}

- (void)executeWithCompletionHandler:(NSUserScriptTaskCompletionHandler)handler
{
    [self executeWithArguments:nil completionHandler:handler];
}

@end

/* No OSA (AppleScript) or Automator on Finch yet. */
@implementation NSUserAppleScriptTask
- (void)executeWithAppleEvent:(NSAppleEventDescriptor *)event completionHandler:(NSUserAppleScriptTaskCompletionHandler)handler
{
    if (handler)
        handler(nil, [NSError errorWithDomain:NSCocoaErrorDomain code:NSFeatureUnsupportedError userInfo:nil]);
}
@end

@implementation NSUserAutomatorTask {
    NSDictionary *_finchVariables;
}
- (void)dealloc
{
    [_finchVariables release];
    [super dealloc];
}
- (NSDictionary *)variables { return _finchVariables; }
- (void)setVariables:(NSDictionary *)v
{
    [_finchVariables autorelease];
    _finchVariables = [v copy];
}
- (void)executeWithInput:(id<NSSecureCoding>)input completionHandler:(NSUserAutomatorTaskCompletionHandler)handler
{
    if (handler)
        handler(nil, [NSError errorWithDomain:NSCocoaErrorDomain code:NSFeatureUnsupportedError userInfo:nil]);
}
@end
