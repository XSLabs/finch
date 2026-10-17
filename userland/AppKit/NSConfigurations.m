/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Small AppKit value classes: NSMenuItemBadge (counts with "1 update", "2 new",
 * "1,234 alerts"), NSItemBadge (toolbar labels and indicators),
 * NSSharingCollaborationModeRestriction (a mode and its optional alert),
 * NSPressureConfiguration, NSTintConfiguration (the shared default and monochrome
 * configurations, a preferred colour that follows the accent colour, a fixed one that
 * doesn't), NSUserInterfaceCompressionOptions (sets of identifiers; the standard ones
 * are shared instances) and NSScrollEdgeEffectStyle (three shared styles). Behaviour,
 * sharing, coding and equality as Apple's.
 */
#import <AppKit/AppKit.h>

/* ---- NSMenuItemBadge ---- */

@implementation NSMenuItemBadge {
    NSInteger _itemCount;
    NSMenuItemBadgeType _type;
    NSString *_stringValue;
    BOOL _usesPreferredLocalization;
}

static NSString *
counted(NSInteger count, NSString *one, NSString *many)
{
    if (count <= 0)
        return nil;
    NSString *n = [NSNumberFormatter localizedStringFromNumber:@(count) numberStyle:NSNumberFormatterDecimalStyle];
    return [NSString stringWithFormat:@"%@ %@", n, count == 1 ? one : many];
}

- (instancetype)initWithCount:(NSInteger)count type:(NSMenuItemBadgeType)type
{
    if ((self = [super init]))
        [self _finchSetCount:count type:type stringValue:nil usesPreferredLocalization:NO];
    return self;
}

- (void)_finchSetCount:(NSInteger)count type:(NSMenuItemBadgeType)type stringValue:(NSString *)stringValue usesPreferredLocalization:(BOOL)usesPreferredLocalization
{
    _itemCount = count;
    _type = type;
    _usesPreferredLocalization = usesPreferredLocalization;
    [_stringValue release];
    if (type == NSMenuItemBadgeTypeNone && count == 0 && stringValue) {
        _stringValue = [stringValue copy];
        return;
    }
    switch (type) {
    case NSMenuItemBadgeTypeUpdates: _stringValue = [counted(count, @"update", @"updates") copy]; break;
    case NSMenuItemBadgeTypeNewItems: _stringValue = [counted(count, @"new", @"new") copy]; break;
    case NSMenuItemBadgeTypeAlerts: _stringValue = [counted(count, @"alert", @"alerts") copy]; break;
    default:
        _stringValue = count > 0 ? [[NSNumberFormatter localizedStringFromNumber:@(count) numberStyle:NSNumberFormatterDecimalStyle] copy] : nil;
    }
}

- (id)_finchSetCodingState:(NSDictionary *)state
{
    [self _finchSetCount:[state[@"itemCount"] integerValue]
                    type:[state[@"type"] integerValue]
             stringValue:state[@"stringValue"] == [NSNull null] ? nil : state[@"stringValue"]
 usesPreferredLocalization:[state[@"usesPreferredLocalization"] boolValue]];
    return self;
}

- (NSDictionary *)_finchCodingState
{
    return @{
        @"itemCount": @(_itemCount),
        @"stringValue": _stringValue ?: [NSNull null],
        @"type": @(_type),
        @"usesPreferredLocalization": @(_usesPreferredLocalization),
    };
}

- (instancetype)initWithCount:(NSInteger)count { return [self initWithCount:count type:NSMenuItemBadgeTypeNone]; }

- (instancetype)initWithString:(NSString *)string
{
    if ((self = [super init]))
        [self _finchSetCount:0 type:NSMenuItemBadgeTypeNone stringValue:string usesPreferredLocalization:NO];
    return self;
}

+ (instancetype)updatesWithCount:(NSInteger)count { return [[[self alloc] initWithCount:count type:NSMenuItemBadgeTypeUpdates] autorelease]; }
/* (a "new" method: the caller owns what it returns) */
+ (instancetype)newItemsWithCount:(NSInteger)count { return [[self alloc] initWithCount:count type:NSMenuItemBadgeTypeNewItems]; }
+ (instancetype)alertsWithCount:(NSInteger)count { return [[[self alloc] initWithCount:count type:NSMenuItemBadgeTypeAlerts] autorelease]; }

- (void)dealloc
{
    [_stringValue release];
    [super dealloc];
}

- (NSInteger)itemCount { return _itemCount; }
- (NSMenuItemBadgeType)type { return _type; }
- (NSString *)stringValue { return _stringValue; }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }

@end

/* ---- NSItemBadge ---- */

@interface NSItemBadge () <NSCopying>
@end

@implementation NSItemBadge {
    NSString *_text;
}

- (instancetype)init
{
    if ((self = [super init]))
        _text = [@"" copy];
    return self;
}

- (void)dealloc
{
    [_text release];
    [super dealloc];
}

+ (NSItemBadge *)badgeWithCount:(NSInteger)count
{
    NSString *text = [NSNumberFormatter localizedStringFromNumber:@(count) numberStyle:NSNumberFormatterDecimalStyle];
    return [self badgeWithText:text];
}

+ (NSItemBadge *)badgeWithText:(NSString *)text
{
    NSItemBadge *badge = [[[self alloc] init] autorelease];
    [badge->_text release];
    badge->_text = [text retain];
    return badge;
}

+ (NSItemBadge *)indicatorBadge
{
    return [[[self alloc] init] autorelease];
}

- (NSString *)text { return _text; }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }

@end

/* The SDK refines these Objective-C declarations away in Swift, so the Swift overlay
   reaches them through these small ownership-aware helpers. */
id FinchAppKitSwiftItemBadgeWithCount(NSInteger count);
id FinchAppKitSwiftItemBadgeWithText(NSString *text);
id FinchAppKitSwiftItemBadgeIndicator(void);
NSString *FinchAppKitSwiftItemBadgeText(id badge);
id FinchAppKitSwiftToolbarItemBadge(NSToolbarItem *item);
void FinchAppKitSwiftSetToolbarItemBadge(NSToolbarItem *item, id badge);

id FinchAppKitSwiftItemBadgeWithCount(NSInteger count)
{
    return [[NSItemBadge badgeWithCount:count] retain];
}

id FinchAppKitSwiftItemBadgeWithText(NSString *text)
{
    return [[NSItemBadge badgeWithText:text] retain];
}

id FinchAppKitSwiftItemBadgeIndicator(void)
{
    return [[NSItemBadge indicatorBadge] retain];
}

NSString *FinchAppKitSwiftItemBadgeText(id badge)
{
    return [[(NSItemBadge *)badge text] retain];
}

id FinchAppKitSwiftToolbarItemBadge(NSToolbarItem *item)
{
    return [[item badge] retain];
}

void FinchAppKitSwiftSetToolbarItemBadge(NSToolbarItem *item, id badge)
{
    [item setBadge:badge];
}

/* ---- NSSharingCollaborationModeRestriction ---- */

@interface NSSharingCollaborationModeRestriction (FinchRestriction)
- (instancetype)_finchInitWithDisabledMode:(NSSharingCollaborationMode)mode
                                alertTitle:(NSString *)title
                              alertMessage:(NSString *)message
                 alertDismissButtonTitle:(NSString *)dismissTitle
       alertRecoverySuggestionButtonTitle:(NSString *)recoveryTitle
 alertRecoverySuggestionButtonLaunchURL:(NSURL *)recoveryURL;
@end

@implementation NSSharingCollaborationModeRestriction {
    NSSharingCollaborationMode _disabledMode;
    NSString *_alertTitle, *_alertMessage, *_alertDismissButtonTitle;
    NSString *_alertRecoverySuggestionButtonTitle;
    NSURL *_alertRecoverySuggestionButtonLaunchURL;
    BOOL _allowContinueToMode;
}

- (instancetype)_finchInitWithDisabledMode:(NSSharingCollaborationMode)mode
                                alertTitle:(NSString *)title
                              alertMessage:(NSString *)message
                 alertDismissButtonTitle:(NSString *)dismissTitle
       alertRecoverySuggestionButtonTitle:(NSString *)recoveryTitle
 alertRecoverySuggestionButtonLaunchURL:(NSURL *)recoveryURL
{
    if ((self = [super init])) {
        _disabledMode = mode;
        _alertTitle = [title copy];
        _alertMessage = [message copy];
        _alertDismissButtonTitle = [dismissTitle copy];
        _alertRecoverySuggestionButtonTitle = [recoveryTitle copy];
        _alertRecoverySuggestionButtonLaunchURL = [recoveryURL copy];
    }
    return self;
}

- (instancetype)initWithDisabledMode:(NSSharingCollaborationMode)mode
{
    return [self _finchInitWithDisabledMode:mode alertTitle:nil alertMessage:nil
                    alertDismissButtonTitle:nil alertRecoverySuggestionButtonTitle:nil
          alertRecoverySuggestionButtonLaunchURL:nil];
}

- (instancetype)initWithDisabledMode:(NSSharingCollaborationMode)mode alertTitle:(NSString *)title alertMessage:(NSString *)message
{
    return [self _finchInitWithDisabledMode:mode alertTitle:title alertMessage:message
                    alertDismissButtonTitle:nil alertRecoverySuggestionButtonTitle:nil
          alertRecoverySuggestionButtonLaunchURL:nil];
}

- (instancetype)initWithDisabledMode:(NSSharingCollaborationMode)mode alertTitle:(NSString *)title alertMessage:(NSString *)message
             alertDismissButtonTitle:(NSString *)dismissTitle
{
    return [self _finchInitWithDisabledMode:mode alertTitle:title alertMessage:message
                    alertDismissButtonTitle:dismissTitle alertRecoverySuggestionButtonTitle:nil
          alertRecoverySuggestionButtonLaunchURL:nil];
}

- (instancetype)initWithDisabledMode:(NSSharingCollaborationMode)mode alertTitle:(NSString *)title alertMessage:(NSString *)message
             alertDismissButtonTitle:(NSString *)dismissTitle
     alertRecoverySuggestionButtonTitle:(NSString *)recoveryTitle
       alertRecoverySuggestionButtonLaunchURL:(NSURL *)recoveryURL
{
    return [self _finchInitWithDisabledMode:mode alertTitle:title alertMessage:message
                    alertDismissButtonTitle:dismissTitle alertRecoverySuggestionButtonTitle:recoveryTitle
          alertRecoverySuggestionButtonLaunchURL:recoveryURL];
}

- (NSSharingCollaborationMode)disabledMode { return _disabledMode; }
- (NSString *)alertTitle { return _alertTitle; }
- (NSString *)alertMessage { return _alertMessage; }
- (NSString *)alertDismissButtonTitle { return _alertDismissButtonTitle; }
- (NSString *)alertRecoverySuggestionButtonTitle { return _alertRecoverySuggestionButtonTitle; }
- (NSURL *)alertRecoverySuggestionButtonLaunchURL { return _alertRecoverySuggestionButtonLaunchURL; }

- (id)copyWithZone:(NSZone *)zone
{
    NSSharingCollaborationModeRestriction *copy = [[[self class] allocWithZone:zone]
        _finchInitWithDisabledMode:_disabledMode
                        alertTitle:_alertTitle
                      alertMessage:_alertMessage
         alertDismissButtonTitle:_alertDismissButtonTitle
 alertRecoverySuggestionButtonTitle:_alertRecoverySuggestionButtonTitle
alertRecoverySuggestionButtonLaunchURL:_alertRecoverySuggestionButtonLaunchURL];
    copy->_allowContinueToMode = _allowContinueToMode;
    return copy;
}

+ (BOOL)supportsSecureCoding { return YES; }

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeInteger:_disabledMode forKey:@"disabledMode"];
    [coder encodeBool:_allowContinueToMode forKey:@"allowContinueToMode"];
    [coder encodeObject:_alertTitle forKey:@"alertTitle"];
    [coder encodeObject:_alertMessage forKey:@"alertMessage"];
    [coder encodeObject:_alertDismissButtonTitle forKey:@"alertDismissButtonTitle"];
    [coder encodeObject:_alertRecoverySuggestionButtonTitle forKey:@"alertRecoverySuggestionButtonTitle"];
    [coder encodeObject:_alertRecoverySuggestionButtonLaunchURL forKey:@"alertRecoverySuggestionButtonLaunchURL"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [self _finchInitWithDisabledMode:(NSSharingCollaborationMode)[coder decodeIntegerForKey:@"disabledMode"]
                                       alertTitle:[coder decodeObjectOfClass:[NSString class] forKey:@"alertTitle"]
                                     alertMessage:[coder decodeObjectOfClass:[NSString class] forKey:@"alertMessage"]
                        alertDismissButtonTitle:[coder decodeObjectOfClass:[NSString class] forKey:@"alertDismissButtonTitle"]
              alertRecoverySuggestionButtonTitle:[coder decodeObjectOfClass:[NSString class] forKey:@"alertRecoverySuggestionButtonTitle"]
        alertRecoverySuggestionButtonLaunchURL:[coder decodeObjectOfClass:[NSURL class] forKey:@"alertRecoverySuggestionButtonLaunchURL"]]))
        _allowContinueToMode = [coder decodeBoolForKey:@"allowContinueToMode"];
    return self;
}

- (void)dealloc
{
    [_alertTitle release];
    [_alertMessage release];
    [_alertDismissButtonTitle release];
    [_alertRecoverySuggestionButtonTitle release];
    [_alertRecoverySuggestionButtonLaunchURL release];
    [super dealloc];
}

@end

/* ---- NSPressureConfiguration ---- */

@implementation NSPressureConfiguration {
    NSPressureBehavior _behavior;
}

- (instancetype)init { return [self initWithPressureBehavior:NSPressureBehaviorPrimaryDefault]; }

- (instancetype)initWithPressureBehavior:(NSPressureBehavior)behavior
{
    if ((self = [super init]))
        _behavior = behavior;
    return self;
}

- (NSPressureBehavior)pressureBehavior { return _behavior; }

/* Finch's trackpads have no force sensing to configure. */
- (void)set
{
}

@end

/* ---- NSTintConfiguration ---- */

@implementation NSTintConfiguration {
    NSColor *_base, *_equivalent;
    BOOL _adapts;
}

- (instancetype)_initWithBase:(NSColor *)base equivalent:(NSColor *)equivalent adapts:(BOOL)adapts
{
    if ((self = [super init])) {
        _base = [base retain];
        _equivalent = [equivalent retain];
        _adapts = adapts;
    }
    return self;
}

- (void)dealloc
{
    [_base release];
    [_equivalent release];
    [super dealloc];
}

+ (NSTintConfiguration *)defaultTintConfiguration
{
    static NSTintConfiguration *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = [[NSTintConfiguration alloc] _initWithBase:nil equivalent:nil adapts:NO]; });
    return c;
}

+ (NSTintConfiguration *)monochromeTintConfiguration
{
    static NSTintConfiguration *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = [[NSTintConfiguration alloc] _initWithBase:nil equivalent:nil adapts:NO]; });
    return c;
}

+ (instancetype)tintConfigurationWithPreferredColor:(NSColor *)color
{
    return [[[self alloc] _initWithBase:color equivalent:color adapts:YES] autorelease];
}

+ (instancetype)tintConfigurationWithFixedColor:(NSColor *)color
{
    return [[[self alloc] _initWithBase:color equivalent:color adapts:NO] autorelease];
}

- (NSColor *)baseTintColor { return _base; }
- (NSColor *)equivalentContentTintColor { return _equivalent; }
- (BOOL)adaptsToUserAccentColor { return _adapts; }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)initWithCoder:(NSCoder *)c
{
    return [self _initWithBase:[c decodeObjectOfClass:[NSColor class] forKey:@"NSBaseTintColor"]
                    equivalent:[c decodeObjectOfClass:[NSColor class] forKey:@"NSEquivalentContentTintColor"]
                        adapts:[c decodeBoolForKey:@"NSAdaptsToUserAccentColor"]];
}

- (void)encodeWithCoder:(NSCoder *)c
{
    [c encodeObject:_base forKey:@"NSBaseTintColor"];
    [c encodeObject:_equivalent forKey:@"NSEquivalentContentTintColor"];
    [c encodeBool:_adapts forKey:@"NSAdaptsToUserAccentColor"];
}

@end

/* ---- NSUserInterfaceCompressionOptions ---- */

@implementation NSUserInterfaceCompressionOptions {
    NSSet *_identifiers;
}

- (instancetype)init { return [self initWithCompressionOptions:[NSSet set]]; }

- (instancetype)initWithIdentifier:(NSString *)identifier
{
    return [self initWithCompressionOptions:[NSSet setWithObject:identifier]];
}

/* (Apple's designated initializer takes a set of options; Finch's keeps identifiers) */
- (instancetype)initWithCompressionOptions:(NSSet *)options
{
    if ((self = [super init])) {
        NSMutableSet *ids = [NSMutableSet set];
        for (id o in options)
            [ids unionSet:[o isKindOfClass:[NSUserInterfaceCompressionOptions class]] ? ((NSUserInterfaceCompressionOptions *)o)->_identifiers
                                                                                     : [NSSet setWithObject:o]];
        _identifiers = [ids copy];
    }
    return self;
}

- (instancetype)_initWithIdentifiers:(NSSet *)ids
{
    if ((self = [super init]))
        _identifiers = [ids copy];
    return self;
}

- (void)dealloc
{
    [_identifiers release];
    [super dealloc];
}

#define SHARED_OPTION(name, ident)                                                                    \
    +(NSUserInterfaceCompressionOptions *)name                                                         \
    {                                                                                                  \
        static NSUserInterfaceCompressionOptions *o;                                                   \
        static dispatch_once_t once;                                                                   \
        dispatch_once(&once, ^{ o = [[NSUserInterfaceCompressionOptions alloc] initWithIdentifier:ident]; }); \
        return o;                                                                                      \
    }
SHARED_OPTION(hideImagesOption, @"NSUserInterfaceCompressionOptionHideImages")
SHARED_OPTION(hideTextOption, @"NSUserInterfaceCompressionOptionHideText")
SHARED_OPTION(reduceMetricsOption, @"NSUserInterfaceCompressionOptionReduceMetrics")
SHARED_OPTION(breakEqualWidthsOption, @"NSUserInterfaceCompressionOptionBreakEqualWidths")

+ (NSUserInterfaceCompressionOptions *)standardOptions
{
    static NSUserInterfaceCompressionOptions *o;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        o = [[NSUserInterfaceCompressionOptions alloc]
            _initWithIdentifiers:[NSSet setWithObjects:@"NSUserInterfaceCompressionOptionReduceMetrics",
                                                       @"NSUserInterfaceCompressionOptionBreakEqualWidths",
                                                       @"NSUserInterfaceCompressionOptionHideText",
                                                       @"NSUserInterfaceCompressionOptionHideImages", nil]];
    });
    return o;
}

- (BOOL)containsOptions:(NSUserInterfaceCompressionOptions *)o { return [o->_identifiers isSubsetOfSet:_identifiers]; }
- (BOOL)intersectsOptions:(NSUserInterfaceCompressionOptions *)o { return [o->_identifiers intersectsSet:_identifiers]; }
- (BOOL)isEmpty { return _identifiers.count == 0; }

- (NSUserInterfaceCompressionOptions *)optionsByAddingOptions:(NSUserInterfaceCompressionOptions *)o
{
    return [[[NSUserInterfaceCompressionOptions alloc] _initWithIdentifiers:[_identifiers setByAddingObjectsFromSet:o->_identifiers]]
        autorelease];
}

- (NSUserInterfaceCompressionOptions *)optionsByRemovingOptions:(NSUserInterfaceCompressionOptions *)o
{
    NSMutableSet *ids = [[_identifiers mutableCopy] autorelease];
    [ids minusSet:o->_identifiers];
    return [[[NSUserInterfaceCompressionOptions alloc] _initWithIdentifiers:ids] autorelease];
}

- (BOOL)isEqual:(id)o
{
    return [o isKindOfClass:[NSUserInterfaceCompressionOptions class]] && [_identifiers isEqualToSet:((NSUserInterfaceCompressionOptions *)o)->_identifiers];
}

- (NSUInteger)hash { return _identifiers.hash; }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p> identifiers = \"%@\"", self.class, self, _identifiers];
}

- (instancetype)initWithCoder:(NSCoder *)c
{
    return [self _initWithIdentifiers:[c decodeObjectOfClasses:[NSSet setWithObjects:[NSSet class], [NSString class], nil]
                                                        forKey:@"NSIdentifiers"]];
}

- (void)encodeWithCoder:(NSCoder *)c { [c encodeObject:_identifiers forKey:@"NSIdentifiers"]; }

@end

/* ---- NSScrollEdgeEffectStyle ---- */

#pragma clang diagnostic ignored "-Wunguarded-availability-new"

@implementation NSScrollEdgeEffectStyle {
    NSInteger _kind; /* 0 automatic, 1 soft, 2 hard */
}

- (instancetype)_initWithKind:(NSInteger)kind
{
    if ((self = [super init]))
        _kind = kind;
    return self;
}

static NSScrollEdgeEffectStyle *
edge_style(NSInteger kind)
{
    static NSScrollEdgeEffectStyle *styles[3];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (NSInteger k = 0; k < 3; k++)
            styles[k] = [[NSScrollEdgeEffectStyle alloc] _initWithKind:k];
    });
    return styles[kind];
}

+ (NSScrollEdgeEffectStyle *)automaticStyle { return edge_style(0); }
+ (NSScrollEdgeEffectStyle *)softStyle { return edge_style(1); }
+ (NSScrollEdgeEffectStyle *)hardStyle { return edge_style(2); }

@end
