/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * UserNotifications: an app's local notifications. Requests are scheduled in the app
 * (time-interval and calendar triggers) and, when due, delivered: the delivered list
 * holds them, and the center's delegate is asked how to present each while the app
 * runs, as on macOS. Finch has no notification banners or Notification Center yet, so
 * what the user would see is written to the system log. Authorization is granted when
 * asked (and remembered in the app's defaults); push notifications need Apple's push
 * service and aren't available.
 */
#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>
#include <os/log.h>

/* For classes whose -init the headers mark unavailable. */
@interface NSObject (FinchUNInit)
- (instancetype)_finchInit __attribute__((objc_method_family(init)));
@end
@implementation NSObject (FinchUNInit)
- (instancetype)_finchInit { return [self init]; }
@end

/* --- content --- */

@implementation UNNotificationContent {
    @protected
    NSArray *_attachments;
    NSNumber *_badge;
    NSString *_body, *_categoryIdentifier, *_launchImageName, *_subtitle, *_threadIdentifier, *_title;
    NSString *_summaryArgument, *_targetContentIdentifier, *_filterCriteria;
    UNNotificationSound *_sound;
    NSDictionary *_userInfo;
    NSUInteger _summaryArgumentCount;
    UNNotificationInterruptionLevel _interruptionLevel;
    double _relevanceScore;
}

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)init
{
    if ((self = [super init])) {
        _attachments = @[];
        _body = _categoryIdentifier = _launchImageName = _subtitle = _threadIdentifier = _title = _summaryArgument = @"";
        _userInfo = @{};
        _interruptionLevel = UNNotificationInterruptionLevelActive;
    }
    return self;
}

- (NSArray *)attachments { return _attachments; }
- (NSNumber *)badge { return _badge; }
- (NSString *)body { return _body; }
- (NSString *)categoryIdentifier { return _categoryIdentifier; }
- (NSString *)launchImageName { return _launchImageName; }
- (UNNotificationSound *)sound { return _sound; }
- (NSString *)subtitle { return _subtitle; }
- (NSString *)threadIdentifier { return _threadIdentifier; }
- (NSString *)title { return _title; }
- (NSDictionary *)userInfo { return _userInfo; }
- (NSString *)summaryArgument { return _summaryArgument; }
- (NSUInteger)summaryArgumentCount { return _summaryArgumentCount; }
- (NSString *)targetContentIdentifier { return _targetContentIdentifier; }
- (UNNotificationInterruptionLevel)interruptionLevel { return _interruptionLevel; }
- (double)relevanceScore { return _relevanceScore; }
- (NSString *)filterCriteria { return _filterCriteria; }

- (void)_finchCopyInto:(UNNotificationContent *)c
{
    c->_attachments = [_attachments copy];
    c->_badge = [_badge copy];
    c->_body = [_body copy];
    c->_categoryIdentifier = [_categoryIdentifier copy];
    c->_launchImageName = [_launchImageName copy];
    c->_sound = _sound;
    c->_subtitle = [_subtitle copy];
    c->_threadIdentifier = [_threadIdentifier copy];
    c->_title = [_title copy];
    c->_userInfo = [_userInfo copy];
    c->_summaryArgument = [_summaryArgument copy];
    c->_summaryArgumentCount = _summaryArgumentCount;
    c->_targetContentIdentifier = [_targetContentIdentifier copy];
    c->_interruptionLevel = _interruptionLevel;
    c->_relevanceScore = _relevanceScore;
    c->_filterCriteria = [_filterCriteria copy];
}

- (id)copyWithZone:(NSZone *)zone
{
    UNNotificationContent *c = [UNNotificationContent new];
    [self _finchCopyInto:c];
    return c;
}

- (id)mutableCopyWithZone:(NSZone *)zone
{
    UNMutableNotificationContent *c = [UNMutableNotificationContent new];
    [self _finchCopyInto:c];
    return c;
}

- (UNNotificationContent *)contentByUpdatingWithProvider:(id<UNNotificationContentProviding>)provider error:(NSError **)outError
{
    return [self copy];
}

static NSArray *
coded_keys(void)
{
    return @[ @"title", @"subtitle", @"body", @"badge", @"categoryIdentifier", @"threadIdentifier", @"userInfo",
              @"targetContentIdentifier", @"filterCriteria" ];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    for (NSString *k in coded_keys())
        [coder encodeObject:[self valueForKey:k] forKey:k];
    [coder encodeObject:_attachments forKey:@"attachments"];
    [coder encodeObject:_sound forKey:@"sound"];
    [coder encodeInteger:(NSInteger)_interruptionLevel forKey:@"interruptionLevel"];
    [coder encodeDouble:_relevanceScore forKey:@"relevanceScore"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if (!(self = [self init]))
        return nil;
    NSSet *plist = [NSSet setWithObjects:[NSString class], [NSNumber class], [NSDictionary class], [NSArray class],
                                         [NSData class], [NSDate class], nil];
    _title = [coder decodeObjectOfClass:[NSString class] forKey:@"title"] ?: @"";
    _subtitle = [coder decodeObjectOfClass:[NSString class] forKey:@"subtitle"] ?: @"";
    _body = [coder decodeObjectOfClass:[NSString class] forKey:@"body"] ?: @"";
    _badge = [coder decodeObjectOfClass:[NSNumber class] forKey:@"badge"];
    _categoryIdentifier = [coder decodeObjectOfClass:[NSString class] forKey:@"categoryIdentifier"] ?: @"";
    _threadIdentifier = [coder decodeObjectOfClass:[NSString class] forKey:@"threadIdentifier"] ?: @"";
    _userInfo = [coder decodeObjectOfClasses:plist forKey:@"userInfo"] ?: @{};
    _targetContentIdentifier = [coder decodeObjectOfClass:[NSString class] forKey:@"targetContentIdentifier"];
    _filterCriteria = [coder decodeObjectOfClass:[NSString class] forKey:@"filterCriteria"];
    _attachments = [coder decodeObjectOfClasses:[NSSet setWithObjects:[NSArray class], [UNNotificationAttachment class], nil]
                                         forKey:@"attachments"]
                       ?: @[];
    _sound = [coder decodeObjectOfClass:[UNNotificationSound class] forKey:@"sound"];
    _interruptionLevel = (UNNotificationInterruptionLevel)[coder decodeIntegerForKey:@"interruptionLevel"];
    _relevanceScore = [coder decodeDoubleForKey:@"relevanceScore"];
    return self;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p; title: %@, subtitle: %@, body: %@, categoryIdentifier: %@, "
                                      @"threadIdentifier: %@, badge: %@, sound: %@, attachments: %@>",
                                      NSStringFromClass([self class]), self, _title.length ? _title : @"(null)",
                                      _subtitle.length ? _subtitle : @"(null)", _body.length ? _body : @"(null)",
                                      _categoryIdentifier, _threadIdentifier, _badge, _sound, _attachments];
}

@end

@implementation UNMutableNotificationContent
- (void)setAttachments:(NSArray *)v { _attachments = [v copy] ?: @[]; }
- (void)setBadge:(NSNumber *)v { _badge = [v copy]; }
- (void)setBody:(NSString *)v { _body = [v copy] ?: @""; }
- (void)setCategoryIdentifier:(NSString *)v { _categoryIdentifier = [v copy] ?: @""; }
- (void)setLaunchImageName:(NSString *)v { _launchImageName = [v copy] ?: @""; }
- (void)setSound:(UNNotificationSound *)v { _sound = v; }
- (void)setSubtitle:(NSString *)v { _subtitle = [v copy] ?: @""; }
- (void)setThreadIdentifier:(NSString *)v { _threadIdentifier = [v copy] ?: @""; }
- (void)setTitle:(NSString *)v { _title = [v copy] ?: @""; }
- (void)setUserInfo:(NSDictionary *)v { _userInfo = [v copy] ?: @{}; }
- (void)setSummaryArgument:(NSString *)v { _summaryArgument = [v copy] ?: @""; }
- (void)setSummaryArgumentCount:(NSUInteger)v { _summaryArgumentCount = v; }
- (void)setTargetContentIdentifier:(NSString *)v { _targetContentIdentifier = [v copy]; }
- (void)setInterruptionLevel:(UNNotificationInterruptionLevel)v { _interruptionLevel = v; }
- (void)setRelevanceScore:(double)v { _relevanceScore = v; }
- (void)setFilterCriteria:(NSString *)v { _filterCriteria = [v copy]; }
@end

/* --- sounds and attachments --- */

@implementation UNNotificationSound {
    NSString *_name;
    BOOL _critical;
    float _volume;
}

+ (BOOL)supportsSecureCoding { return YES; }

+ (instancetype)_finchSound:(NSString *)name critical:(BOOL)critical volume:(float)volume
{
    UNNotificationSound *s = [[self alloc] _finchInit];
    s->_name = [name copy];
    s->_critical = critical;
    s->_volume = volume;
    return s;
}

+ (UNNotificationSound *)defaultSound { return [self _finchSound:nil critical:NO volume:1]; }
+ (UNNotificationSound *)defaultRingtoneSound { return [self _finchSound:nil critical:NO volume:1]; }
+ (UNNotificationSound *)defaultCriticalSound { return [self _finchSound:nil critical:YES volume:1]; }
+ (UNNotificationSound *)defaultCriticalSoundWithAudioVolume:(float)volume { return [self _finchSound:nil critical:YES volume:volume]; }
+ (UNNotificationSound *)soundNamed:(UNNotificationSoundName)name { return [self _finchSound:name critical:NO volume:1]; }
+ (UNNotificationSound *)ringtoneSoundNamed:(UNNotificationSoundName)name { return [self _finchSound:name critical:NO volume:1]; }
+ (UNNotificationSound *)criticalSoundNamed:(UNNotificationSoundName)name { return [self _finchSound:name critical:YES volume:1]; }
+ (UNNotificationSound *)criticalSoundNamed:(UNNotificationSoundName)name withAudioVolume:(float)volume
{
    return [self _finchSound:name critical:YES volume:volume];
}

- (id)copyWithZone:(NSZone *)zone { return self; }
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_name forKey:@"name"];
    [coder encodeBool:_critical forKey:@"critical"];
    [coder encodeFloat:_volume forKey:@"volume"];
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super init])) {
        _name = [coder decodeObjectOfClass:[NSString class] forKey:@"name"];
        _critical = [coder decodeBoolForKey:@"critical"];
        _volume = [coder decodeFloatForKey:@"volume"];
    }
    return self;
}
- (NSString *)description
{
    return [NSString stringWithFormat:@"<UNNotificationSound: %p; name: %@>", self, _name ?: @"(default)"];
}

@end

@implementation UNNotificationAttachment {
    NSString *_identifier, *_type;
    NSURL *_URL;
}

+ (BOOL)supportsSecureCoding { return YES; }

+ (instancetype)attachmentWithIdentifier:(NSString *)identifier URL:(NSURL *)URL options:(NSDictionary *)options error:(NSError **)error
{
    if (!URL.isFileURL || ![[NSFileManager defaultManager] fileExistsAtPath:URL.path]) {
        if (error)
            *error = [NSError errorWithDomain:UNErrorDomain code:UNErrorCodeAttachmentInvalidURL userInfo:nil];
        return nil;
    }
    UNNotificationAttachment *a = [[self alloc] _finchInit];
    a->_identifier = identifier.length ? [identifier copy] : [[NSUUID UUID] UUIDString];
    a->_URL = [URL copy];
    a->_type = options[UNNotificationAttachmentOptionsTypeHintKey];
    if (!a->_type) {
        NSString *uti = nil;
        [URL getResourceValue:&uti forKey:NSURLTypeIdentifierKey error:nil];
        a->_type = uti ?: @"public.data";
    }
    return a;
}

- (NSString *)identifier { return _identifier; }
- (NSURL *)URL { return _URL; }
- (NSString *)type { return _type; }
- (id)copyWithZone:(NSZone *)zone { return self; }
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_identifier forKey:@"identifier"];
    [coder encodeObject:_URL forKey:@"URL"];
    [coder encodeObject:_type forKey:@"type"];
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super init])) {
        _identifier = [coder decodeObjectOfClass:[NSString class] forKey:@"identifier"];
        _URL = [coder decodeObjectOfClass:[NSURL class] forKey:@"URL"];
        _type = [coder decodeObjectOfClass:[NSString class] forKey:@"type"];
    }
    return self;
}

@end

/* --- triggers --- */

@implementation UNNotificationTrigger {
    @protected
    BOOL _repeats;
}
+ (BOOL)supportsSecureCoding { return YES; }
- (BOOL)repeats { return _repeats; }
- (id)copyWithZone:(NSZone *)zone { return self; }
- (void)encodeWithCoder:(NSCoder *)coder { [coder encodeBool:_repeats forKey:@"repeats"]; }
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super init]))
        _repeats = [coder decodeBoolForKey:@"repeats"];
    return self;
}
- (NSDate *)_finchNextDateAfter:(NSDate *)date { return nil; }
@end

@implementation UNPushNotificationTrigger
@end

@implementation UNTimeIntervalNotificationTrigger {
    NSTimeInterval _timeInterval;
    NSDate *_start;
}

+ (instancetype)triggerWithTimeInterval:(NSTimeInterval)timeInterval repeats:(BOOL)repeats
{
    if (timeInterval <= 0)
        [NSException raise:NSInternalInconsistencyException format:@"time interval must be greater than 0"];
    if (repeats && timeInterval < 60)
        [NSException raise:NSInternalInconsistencyException format:@"time interval must be at least 60 if repeating"];
    UNTimeIntervalNotificationTrigger *t = [[self alloc] _finchInit];
    t->_timeInterval = timeInterval;
    t->_repeats = repeats;
    t->_start = [NSDate date];
    return t;
}

- (NSTimeInterval)timeInterval { return _timeInterval; }
- (NSDate *)nextTriggerDate { return [self _finchNextDateAfter:[NSDate date]]; }

- (NSDate *)_finchNextDateAfter:(NSDate *)now
{
    NSDate *next = [_start dateByAddingTimeInterval:_timeInterval];
    if (_repeats)
        while ([next compare:now] != NSOrderedDescending)
            next = [next dateByAddingTimeInterval:_timeInterval];
    return next;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    [coder encodeDouble:_timeInterval forKey:@"timeInterval"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super initWithCoder:coder])) {
        _timeInterval = [coder decodeDoubleForKey:@"timeInterval"];
        _start = [NSDate date];
    }
    return self;
}

@end

@implementation UNCalendarNotificationTrigger {
    NSDateComponents *_dateComponents;
}

+ (instancetype)triggerWithDateMatchingComponents:(NSDateComponents *)dateComponents repeats:(BOOL)repeats
{
    UNCalendarNotificationTrigger *t = [[self alloc] _finchInit];
    t->_dateComponents = [dateComponents copy];
    t->_repeats = repeats;
    return t;
}

- (NSDateComponents *)dateComponents { return _dateComponents; }
- (NSDate *)nextTriggerDate { return [self _finchNextDateAfter:[NSDate date]]; }

- (NSDate *)_finchNextDateAfter:(NSDate *)now
{
    NSCalendar *cal = _dateComponents.calendar ?: [NSCalendar currentCalendar];
    return [cal nextDateAfterDate:now matchingComponents:_dateComponents options:NSCalendarMatchNextTime];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    [coder encodeObject:_dateComponents forKey:@"dateComponents"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super initWithCoder:coder]))
        _dateComponents = [coder decodeObjectOfClass:[NSDateComponents class] forKey:@"dateComponents"];
    return self;
}

@end

/* --- requests and delivered notifications --- */

@implementation UNNotificationRequest {
    NSString *_identifier;
    UNNotificationContent *_content;
    UNNotificationTrigger *_trigger;
}

+ (BOOL)supportsSecureCoding { return YES; }

+ (instancetype)requestWithIdentifier:(NSString *)identifier content:(UNNotificationContent *)content trigger:(UNNotificationTrigger *)trigger
{
    UNNotificationRequest *r = [[self alloc] _finchInit];
    r->_identifier = [identifier copy];
    r->_content = [content copy];
    r->_trigger = trigger;
    return r;
}

- (NSString *)identifier { return _identifier; }
- (UNNotificationContent *)content { return _content; }
- (UNNotificationTrigger *)trigger { return _trigger; }
- (id)copyWithZone:(NSZone *)zone { return self; }
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_identifier forKey:@"identifier"];
    [coder encodeObject:_content forKey:@"content"];
    [coder encodeObject:_trigger forKey:@"trigger"];
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super init])) {
        _identifier = [coder decodeObjectOfClass:[NSString class] forKey:@"identifier"];
        _content = [coder decodeObjectOfClass:[UNNotificationContent class] forKey:@"content"];
        _trigger = [coder decodeObjectOfClasses:[NSSet setWithObjects:[UNTimeIntervalNotificationTrigger class],
                                                                     [UNCalendarNotificationTrigger class], nil]
                                         forKey:@"trigger"];
    }
    return self;
}
- (NSString *)description
{
    return [NSString stringWithFormat:@"<UNNotificationRequest: %p; identifier: %@, content: %@, trigger: %@>", self,
                                      _identifier, _content, _trigger];
}

@end

@implementation UNNotification {
    UNNotificationRequest *_request;
    NSDate *_date;
}

+ (BOOL)supportsSecureCoding { return YES; }

+ (instancetype)_finchNotificationWithRequest:(UNNotificationRequest *)request date:(NSDate *)date
{
    UNNotification *n = [[self alloc] _finchInit];
    n->_request = request;
    n->_date = date;
    return n;
}

- (UNNotificationRequest *)request { return _request; }
- (NSDate *)date { return _date; }
- (id)copyWithZone:(NSZone *)zone { return self; }
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_request forKey:@"request"];
    [coder encodeObject:_date forKey:@"date"];
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super init])) {
        _request = [coder decodeObjectOfClass:[UNNotificationRequest class] forKey:@"request"];
        _date = [coder decodeObjectOfClass:[NSDate class] forKey:@"date"];
    }
    return self;
}

@end

/* --- actions, categories, responses, settings --- */

@implementation UNNotificationActionIcon {
    NSString *_name;
    BOOL _system;
}
+ (BOOL)supportsSecureCoding { return YES; }
+ (instancetype)iconWithTemplateImageName:(NSString *)templateImageName
{
    UNNotificationActionIcon *i = [[self alloc] _finchInit];
    i->_name = [templateImageName copy];
    return i;
}
+ (instancetype)iconWithSystemImageName:(NSString *)systemImageName
{
    UNNotificationActionIcon *i = [self iconWithTemplateImageName:systemImageName];
    i->_system = YES;
    return i;
}
- (id)copyWithZone:(NSZone *)zone { return self; }
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_name forKey:@"name"];
    [coder encodeBool:_system forKey:@"system"];
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super init])) {
        _name = [coder decodeObjectOfClass:[NSString class] forKey:@"name"];
        _system = [coder decodeBoolForKey:@"system"];
    }
    return self;
}
@end

@implementation UNNotificationAction {
    @protected
    NSString *_identifier, *_title;
    UNNotificationActionOptions _options;
    UNNotificationActionIcon *_icon;
}

+ (BOOL)supportsSecureCoding { return YES; }

+ (instancetype)actionWithIdentifier:(NSString *)identifier title:(NSString *)title options:(UNNotificationActionOptions)options
{
    return [self actionWithIdentifier:identifier title:title options:options icon:nil];
}

+ (instancetype)actionWithIdentifier:(NSString *)identifier title:(NSString *)title options:(UNNotificationActionOptions)options
                                icon:(UNNotificationActionIcon *)icon
{
    UNNotificationAction *a = [[self alloc] _finchInit];
    a->_identifier = [identifier copy];
    a->_title = [title copy];
    a->_options = options;
    a->_icon = icon;
    return a;
}

- (NSString *)identifier { return _identifier; }
- (NSString *)title { return _title; }
- (UNNotificationActionOptions)options { return _options; }
- (UNNotificationActionIcon *)icon { return _icon; }
- (id)copyWithZone:(NSZone *)zone { return self; }
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_identifier forKey:@"identifier"];
    [coder encodeObject:_title forKey:@"title"];
    [coder encodeInteger:(NSInteger)_options forKey:@"options"];
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super init])) {
        _identifier = [coder decodeObjectOfClass:[NSString class] forKey:@"identifier"];
        _title = [coder decodeObjectOfClass:[NSString class] forKey:@"title"];
        _options = (UNNotificationActionOptions)[coder decodeIntegerForKey:@"options"];
    }
    return self;
}

@end

@implementation UNTextInputNotificationAction {
    NSString *_buttonTitle, *_placeholder;
}

+ (instancetype)actionWithIdentifier:(NSString *)identifier title:(NSString *)title options:(UNNotificationActionOptions)options
                textInputButtonTitle:(NSString *)textInputButtonTitle textInputPlaceholder:(NSString *)textInputPlaceholder
{
    return [self actionWithIdentifier:identifier title:title options:options icon:nil textInputButtonTitle:textInputButtonTitle
                 textInputPlaceholder:textInputPlaceholder];
}

+ (instancetype)actionWithIdentifier:(NSString *)identifier title:(NSString *)title options:(UNNotificationActionOptions)options
                                icon:(UNNotificationActionIcon *)icon textInputButtonTitle:(NSString *)textInputButtonTitle
                textInputPlaceholder:(NSString *)textInputPlaceholder
{
    UNTextInputNotificationAction *a = [self actionWithIdentifier:identifier title:title options:options icon:icon];
    a->_buttonTitle = [textInputButtonTitle copy];
    a->_placeholder = [textInputPlaceholder copy];
    return a;
}

- (NSString *)textInputButtonTitle { return _buttonTitle; }
- (NSString *)textInputPlaceholder { return _placeholder; }

@end

@implementation UNNotificationCategory {
    NSString *_identifier, *_hiddenPreviewsBodyPlaceholder, *_categorySummaryFormat;
    NSArray *_actions, *_intentIdentifiers;
    UNNotificationCategoryOptions _options;
}

+ (BOOL)supportsSecureCoding { return YES; }

+ (instancetype)categoryWithIdentifier:(NSString *)identifier actions:(NSArray *)actions intentIdentifiers:(NSArray *)intentIdentifiers
                               options:(UNNotificationCategoryOptions)options
{
    UNNotificationCategory *c = [[self alloc] _finchInit];
    c->_identifier = [identifier copy];
    c->_actions = [actions copy] ?: @[];
    c->_intentIdentifiers = [intentIdentifiers copy] ?: @[];
    c->_options = options;
    return c;
}

+ (instancetype)categoryWithIdentifier:(NSString *)identifier actions:(NSArray *)actions intentIdentifiers:(NSArray *)intentIdentifiers
         hiddenPreviewsBodyPlaceholder:(NSString *)hiddenPreviewsBodyPlaceholder options:(UNNotificationCategoryOptions)options
{
    UNNotificationCategory *c = [self categoryWithIdentifier:identifier actions:actions intentIdentifiers:intentIdentifiers options:options];
    c->_hiddenPreviewsBodyPlaceholder = [hiddenPreviewsBodyPlaceholder copy];
    return c;
}

+ (instancetype)categoryWithIdentifier:(NSString *)identifier actions:(NSArray *)actions intentIdentifiers:(NSArray *)intentIdentifiers
         hiddenPreviewsBodyPlaceholder:(NSString *)hiddenPreviewsBodyPlaceholder
                 categorySummaryFormat:(NSString *)categorySummaryFormat
                               options:(UNNotificationCategoryOptions)options
{
    UNNotificationCategory *c = [self categoryWithIdentifier:identifier actions:actions intentIdentifiers:intentIdentifiers
                               hiddenPreviewsBodyPlaceholder:hiddenPreviewsBodyPlaceholder options:options];
    c->_categorySummaryFormat = [categorySummaryFormat copy];
    return c;
}

- (NSString *)identifier { return _identifier; }
- (NSArray *)actions { return _actions; }
- (NSArray *)intentIdentifiers { return _intentIdentifiers; }
- (UNNotificationCategoryOptions)options { return _options; }
- (NSString *)hiddenPreviewsBodyPlaceholder { return _hiddenPreviewsBodyPlaceholder ?: @""; }
- (NSString *)categorySummaryFormat { return _categorySummaryFormat ?: @""; }
- (id)copyWithZone:(NSZone *)zone { return self; }
- (NSUInteger)hash { return _identifier.hash; }
- (BOOL)isEqual:(id)other
{
    return [other isKindOfClass:[UNNotificationCategory class]] && [((UNNotificationCategory *)other)->_identifier isEqual:_identifier];
}
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_identifier forKey:@"identifier"];
    [coder encodeObject:_actions forKey:@"actions"];
    [coder encodeInteger:(NSInteger)_options forKey:@"options"];
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super init])) {
        _identifier = [coder decodeObjectOfClass:[NSString class] forKey:@"identifier"];
        _actions = [coder decodeObjectOfClasses:[NSSet setWithObjects:[NSArray class], [UNNotificationAction class], nil] forKey:@"actions"];
        _options = (UNNotificationCategoryOptions)[coder decodeIntegerForKey:@"options"];
    }
    return self;
}

@end

@implementation UNNotificationResponse {
    @protected
    UNNotification *_notification;
    NSString *_actionIdentifier;
}
+ (BOOL)supportsSecureCoding { return YES; }
- (UNNotification *)notification { return _notification; }
- (NSString *)actionIdentifier { return _actionIdentifier; }
- (id)copyWithZone:(NSZone *)zone { return self; }
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_notification forKey:@"notification"];
    [coder encodeObject:_actionIdentifier forKey:@"actionIdentifier"];
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super init])) {
        _notification = [coder decodeObjectOfClass:[UNNotification class] forKey:@"notification"];
        _actionIdentifier = [coder decodeObjectOfClass:[NSString class] forKey:@"actionIdentifier"];
    }
    return self;
}
@end

@implementation UNTextInputNotificationResponse {
    NSString *_userText;
}
- (NSString *)userText { return _userText ?: @""; }
@end

@implementation UNNotificationSettings {
    UNAuthorizationStatus _status;
}

+ (BOOL)supportsSecureCoding { return YES; }

+ (instancetype)_finchSettingsWithStatus:(UNAuthorizationStatus)status
{
    UNNotificationSettings *s = [[self alloc] _finchInit];
    s->_status = status;
    return s;
}

- (UNAuthorizationStatus)authorizationStatus { return _status; }
- (UNNotificationSetting)_on
{
    return _status == UNAuthorizationStatusAuthorized || _status == UNAuthorizationStatusProvisional ? UNNotificationSettingEnabled
                                                                                                    : UNNotificationSettingDisabled;
}
- (UNNotificationSetting)soundSetting { return [self _on]; }
- (UNNotificationSetting)badgeSetting { return [self _on]; }
- (UNNotificationSetting)alertSetting { return [self _on]; }
- (UNNotificationSetting)notificationCenterSetting { return [self _on]; }
- (UNNotificationSetting)lockScreenSetting { return [self _on]; }
- (UNNotificationSetting)carPlaySetting { return UNNotificationSettingNotSupported; }
- (UNAlertStyle)alertStyle { return [self _on] == UNNotificationSettingEnabled ? UNAlertStyleBanner : UNAlertStyleNone; }
- (UNShowPreviewsSetting)showPreviewsSetting { return UNShowPreviewsSettingAlways; }
- (UNNotificationSetting)criticalAlertSetting { return UNNotificationSettingNotSupported; }
- (BOOL)providesAppNotificationSettings { return NO; }
- (UNNotificationSetting)announcementSetting { return UNNotificationSettingNotSupported; }
- (UNNotificationSetting)timeSensitiveSetting { return UNNotificationSettingNotSupported; }
- (UNNotificationSetting)scheduledDeliverySetting { return UNNotificationSettingDisabled; }
- (UNNotificationSetting)directMessagesSetting { return UNNotificationSettingNotSupported; }
- (id)copyWithZone:(NSZone *)zone { return self; }
- (void)encodeWithCoder:(NSCoder *)coder { [coder encodeInteger:_status forKey:@"authorizationStatus"]; }
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super init]))
        _status = (UNAuthorizationStatus)[coder decodeIntegerForKey:@"authorizationStatus"];
    return self;
}

@end

@implementation UNNotificationServiceExtension
- (void)didReceiveNotificationRequest:(UNNotificationRequest *)request
                   withContentHandler:(void (^)(UNNotificationContent *))contentHandler
{
    contentHandler(request.content);
}
- (void)serviceExtensionTimeWillExpire {}
@end

/* --- the center --- */

static NSString *const kAuthorizationKey = @"FinchUserNotificationsAuthorization";

@implementation UNUserNotificationCenter {
    __weak id<UNUserNotificationCenterDelegate> _delegate;
    dispatch_queue_t _queue;
    NSMutableDictionary<NSString *, UNNotificationRequest *> *_pending;
    NSMutableDictionary<NSString *, dispatch_source_t> *_timers;
    NSMutableArray<UNNotification *> *_delivered;
    NSSet *_categories;
}

+ (UNUserNotificationCenter *)currentNotificationCenter
{
    static UNUserNotificationCenter *center;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ center = [[UNUserNotificationCenter alloc] _finchInit]; });
    return center;
}

- (instancetype)_finchInit
{
    if ((self = [super _finchInit])) {
        _queue = dispatch_queue_create("com.apple.usernotifications.UNUserNotificationCenter", DISPATCH_QUEUE_SERIAL);
        _pending = [NSMutableDictionary dictionary];
        _timers = [NSMutableDictionary dictionary];
        _delivered = [NSMutableArray array];
        _categories = [NSSet set];
    }
    return self;
}

- (id<UNUserNotificationCenterDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<UNUserNotificationCenterDelegate>)delegate { _delegate = delegate; }
- (BOOL)supportsContentExtensions { return NO; }

static UNAuthorizationStatus
status(void)
{
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:kAuthorizationKey];
    return v ? (UNAuthorizationStatus)[v integerValue] : UNAuthorizationStatusNotDetermined;
}

- (void)requestAuthorizationWithOptions:(UNAuthorizationOptions)options completionHandler:(void (^)(BOOL, NSError *))completionHandler
{
    /* no permission prompt on Finch yet: notifications are allowed (provisional if asked for) */
    UNAuthorizationStatus s = status();
    if (s == UNAuthorizationStatusNotDetermined || s == UNAuthorizationStatusProvisional) {
        s = (options & UNAuthorizationOptionProvisional) && s == UNAuthorizationStatusNotDetermined ? UNAuthorizationStatusProvisional
                                                                                                   : UNAuthorizationStatusAuthorized;
        [[NSUserDefaults standardUserDefaults] setInteger:s forKey:kAuthorizationKey];
    }
    BOOL granted = s == UNAuthorizationStatusAuthorized || s == UNAuthorizationStatusProvisional;
    if (completionHandler)
        dispatch_async(_queue, ^{ completionHandler(granted, nil); });
}

- (void)getNotificationSettingsWithCompletionHandler:(void (^)(UNNotificationSettings *))completionHandler
{
    UNNotificationSettings *settings = [UNNotificationSettings _finchSettingsWithStatus:status()];
    dispatch_async(_queue, ^{ completionHandler(settings); });
}

- (void)setNotificationCategories:(NSSet *)categories
{
    dispatch_sync(_queue, ^{ self->_categories = [categories copy] ?: [NSSet set]; });
}

- (void)getNotificationCategoriesWithCompletionHandler:(void (^)(NSSet<UNNotificationCategory *> *))completionHandler
{
    dispatch_async(_queue, ^{ completionHandler(self->_categories); });
}

/* Delivers a due request: into the delivered list, and to the delegate to present. */
- (void)_finchDeliver:(UNNotificationRequest *)request
{
    UNNotification *n = [UNNotification _finchNotificationWithRequest:request date:[NSDate date]];
    [_delivered addObject:n];
    if (!request.trigger.repeats) {
        [_pending removeObjectForKey:request.identifier];
        [_timers removeObjectForKey:request.identifier];
    }
    UNNotificationContent *c = request.content;
    os_log(OS_LOG_DEFAULT, "notification from %{public}@: %{public}@ %{public}@ %{public}@", [NSBundle mainBundle].bundleIdentifier,
           c.title, c.subtitle, c.body);
    id<UNUserNotificationCenterDelegate> d = _delegate;
    if ([d respondsToSelector:@selector(userNotificationCenter:willPresentNotification:withCompletionHandler:)])
        dispatch_async(dispatch_get_main_queue(), ^{
          [d userNotificationCenter:self willPresentNotification:n withCompletionHandler:^(UNNotificationPresentationOptions o){}];
        });
}

- (void)_finchSchedule:(UNNotificationRequest *)request
{
    NSDate *when = request.trigger ? [(id)request.trigger _finchNextDateAfter:[NSDate date]] : [NSDate date];
    if (!when) /* a push trigger, or a date that never comes */
        return;
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    int64_t delay = (int64_t)(fmax(0, [when timeIntervalSinceNow]) * NSEC_PER_SEC);
    __weak UNUserNotificationCenter *weakSelf = self;
    dispatch_source_set_event_handler(t, ^{
      UNUserNotificationCenter *me = weakSelf;
      if (!me || me->_pending[request.identifier] != request)
          return;
      [me _finchDeliver:request];
      if (request.trigger.repeats) {
          NSDate *next = [(id)request.trigger _finchNextDateAfter:[NSDate dateWithTimeIntervalSinceNow:1]];
          if (next)
              dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, (int64_t)([next timeIntervalSinceNow] * NSEC_PER_SEC)),
                                        DISPATCH_TIME_FOREVER, NSEC_PER_SEC / 10);
      } else {
          dispatch_source_cancel(t);
      }
    });
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, delay), DISPATCH_TIME_FOREVER, NSEC_PER_SEC / 10);
    _timers[request.identifier] = t;
    dispatch_resume(t);
}

- (void)addNotificationRequest:(UNNotificationRequest *)request withCompletionHandler:(void (^)(NSError *))completionHandler
{
    dispatch_async(_queue, ^{
      NSError *error = nil;
      if (status() == UNAuthorizationStatusDenied)
          error = [NSError errorWithDomain:UNErrorDomain code:UNErrorCodeNotificationsNotAllowed userInfo:nil];
      else if (!request.identifier)
          error = [NSError errorWithDomain:UNErrorDomain code:UNErrorCodeNotificationInvalidNoContent userInfo:nil];
      if (!error) {
          dispatch_source_t old = self->_timers[request.identifier];
          if (old)
              dispatch_source_cancel(old);
          self->_pending[request.identifier] = request;
          [self _finchSchedule:request];
      }
      if (completionHandler)
          completionHandler(error);
    });
}

- (void)getPendingNotificationRequestsWithCompletionHandler:(void (^)(NSArray<UNNotificationRequest *> *))completionHandler
{
    dispatch_async(_queue, ^{ completionHandler(self->_pending.allValues); });
}

- (void)removePendingNotificationRequestsWithIdentifiers:(NSArray *)identifiers
{
    dispatch_async(_queue, ^{
      for (NSString *i in identifiers) {
          dispatch_source_t t = self->_timers[i];
          if (t)
              dispatch_source_cancel(t);
          [self->_timers removeObjectForKey:i];
          [self->_pending removeObjectForKey:i];
      }
    });
}

- (void)removeAllPendingNotificationRequests
{
    dispatch_async(_queue, ^{ [self removePendingNotificationRequestsWithIdentifiers:self->_pending.allKeys]; });
}

- (void)getDeliveredNotificationsWithCompletionHandler:(void (^)(NSArray<UNNotification *> *))completionHandler
{
    dispatch_async(_queue, ^{ completionHandler([self->_delivered copy]); });
}

- (void)removeDeliveredNotificationsWithIdentifiers:(NSArray *)identifiers
{
    dispatch_async(_queue, ^{
      NSSet *ids = [NSSet setWithArray:identifiers];
      [self->_delivered filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(UNNotification *n, NSDictionary *b) {
                          return ![ids containsObject:n.request.identifier];
                        }]];
    });
}

- (void)removeAllDeliveredNotifications
{
    dispatch_async(_queue, ^{ [self->_delivered removeAllObjects]; });
}

- (void)setBadgeCount:(NSInteger)newBadgeCount withCompletionHandler:(void (^)(NSError *))completionHandler
{
    dispatch_async(dispatch_get_main_queue(), ^{
      Class app = NSClassFromString(@"NSApplication");
      id dock = [[app performSelector:@selector(sharedApplication)] performSelector:@selector(dockTile)];
      [dock performSelector:@selector(setBadgeLabel:) withObject:newBadgeCount ? [@(newBadgeCount) stringValue] : nil];
      if (completionHandler)
          completionHandler(nil);
    });
}

@end

@implementation NSString (UNUserNotificationCenterSupport)
+ (NSString *)localizedUserNotificationStringForKey:(NSString *)key arguments:(NSArray *)arguments
{
    NSString *format = [[NSBundle mainBundle] localizedStringForKey:key value:key table:nil];
    if (!arguments.count)
        return format;
    /* the arguments, as %@ in order */
    NSMutableString *out = [NSMutableString string];
    NSScanner *s = [NSScanner scannerWithString:format];
    s.charactersToBeSkipped = nil;
    NSUInteger i = 0;
    while (!s.atEnd) {
        NSString *chunk;
        if ([s scanUpToString:@"%@" intoString:&chunk])
            [out appendString:chunk];
        if ([s scanString:@"%@" intoString:NULL])
            [out appendString:i < arguments.count ? [arguments[i++] description] : @""];
    }
    return out;
}
@end
