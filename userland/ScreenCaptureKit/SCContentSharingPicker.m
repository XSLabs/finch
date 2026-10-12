/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The content sharing picker: Finch's own small panel listing what the configuration
 * allows (the display, apps, windows), less the excluded windows and bundles. Choosing
 * one tells the observers the filter for it; cancelling tells them that. Defaults are
 * Apple's (every mode allowed, changing allowed, one stream at most).
 */
#import "SCInternal.h"
#import <AppKit/AppKit.h>

@interface SCShareableContent (FinchPicker)
- (instancetype)_initExcludingDesktop:(BOOL)excludeDesktop option:(CGWindowListOption)option relativeTo:(CGWindowID)window
                                  pid:(pid_t)onlyPID;
@end

@implementation SCContentSharingPickerConfiguration {
    NSArray *_excludedWindowIDs, *_excludedBundleIDs;
}

@synthesize allowedPickerModes = _modes, allowsChangingSelectedContent = _allowsChanging;

- (instancetype)init
{
    if ((self = [super init])) {
        _modes = SCContentSharingPickerModeSingleWindow | SCContentSharingPickerModeMultipleWindows |
                 SCContentSharingPickerModeSingleApplication | SCContentSharingPickerModeMultipleApplications |
                 SCContentSharingPickerModeSingleDisplay;
        _excludedWindowIDs = [@[] retain];
        _excludedBundleIDs = [@[] retain];
        _allowsChanging = YES;
    }
    return self;
}

- (void)dealloc
{
    [_excludedWindowIDs release];
    [_excludedBundleIDs release];
    [super dealloc];
}

- (NSArray<NSNumber *> *)excludedWindowIDs { return _excludedWindowIDs; }
- (void)setExcludedWindowIDs:(NSArray<NSNumber *> *)ids
{
    [_excludedWindowIDs autorelease];
    _excludedWindowIDs = [ids copy] ?: [@[] retain];
}
- (NSArray<NSString *> *)excludedBundleIDs { return _excludedBundleIDs; }
- (void)setExcludedBundleIDs:(NSArray<NSString *> *)ids
{
    [_excludedBundleIDs autorelease];
    _excludedBundleIDs = [ids copy] ?: [@[] retain];
}

- (id)copyWithZone:(NSZone *)zone
{
    SCContentSharingPickerConfiguration *c = [[SCContentSharingPickerConfiguration alloc] init];
    c->_modes = _modes;
    c->_allowsChanging = _allowsChanging;
    [c setExcludedWindowIDs:_excludedWindowIDs];
    [c setExcludedBundleIDs:_excludedBundleIDs];
    return c;
}

@end

@implementation SCContentSharingPicker {
    SCContentSharingPickerConfiguration *_default;
    NSNumber *_maximum;
    BOOL _active;
    NSHashTable *_observers;
    NSMapTable *_streamConfigs;
}

+ (SCContentSharingPicker *)sharedPicker
{
    static SCContentSharingPicker *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[super alloc] _finchInit];
    });
    return shared;
}

- (instancetype)_finchInit
{
    if ((self = [super init])) {
        _default = [[SCContentSharingPickerConfiguration alloc] init];
        _maximum = [@1 retain];
        _observers = [[NSHashTable weakObjectsHashTable] retain];
        _streamConfigs = [[NSMapTable weakToStrongObjectsMapTable] retain];
    }
    return self;
}

- (SCContentSharingPickerConfiguration *)defaultConfiguration { return _default; }
- (void)setDefaultConfiguration:(SCContentSharingPickerConfiguration *)config
{
    [_default autorelease];
    _default = [config copy];
}
- (NSNumber *)maximumStreamCount { return _maximum; }
- (void)setMaximumStreamCount:(NSNumber *)count
{
    [_maximum autorelease];
    _maximum = [count retain];
}
- (BOOL)isActive { return _active; }
- (void)setActive:(BOOL)active { _active = active; }

- (void)addObserver:(id<SCContentSharingPickerObserver>)observer { [_observers addObject:observer]; }
- (void)removeObserver:(id<SCContentSharingPickerObserver>)observer { [_observers removeObject:observer]; }

- (void)setConfiguration:(SCContentSharingPickerConfiguration *)pickerConfig forStream:(SCStream *)stream
{
    if (pickerConfig)
        [_streamConfigs setObject:[[pickerConfig copy] autorelease] forKey:stream];
    else
        [_streamConfigs removeObjectForKey:stream];
}

- (void)present { [self _finchPresentForStream:nil style:SCShareableContentStyleNone]; }
- (void)presentPickerUsingContentStyle:(SCShareableContentStyle)style { [self _finchPresentForStream:nil style:style]; }
- (void)presentPickerForStream:(SCStream *)stream { [self _finchPresentForStream:stream style:SCShareableContentStyleNone]; }
- (void)presentPickerForStream:(SCStream *)stream usingContentStyle:(SCShareableContentStyle)style
{
    [self _finchPresentForStream:stream style:style];
}

/* The choices: titles and the filter each gives. */
- (void)_finchChoicesFor:(SCContentSharingPickerConfiguration *)config style:(SCShareableContentStyle)style
                  titles:(NSMutableArray *)titles filters:(NSMutableArray *)filters
{
    SCShareableContent *content = [[[SCShareableContent alloc] _initExcludingDesktop:YES option:kCGWindowListOptionOnScreenOnly
                                                                          relativeTo:kCGNullWindowID
                                                                                 pid:0] autorelease];
    SCDisplay *display = [[content displays] firstObject];
    SCContentSharingPickerMode modes = [config allowedPickerModes];
    NSSet *excludedWindows = [NSSet setWithArray:[config excludedWindowIDs]];
    NSSet *excludedBundles = [NSSet setWithArray:[config excludedBundleIDs]];
    pid_t me = getpid();
    if (display && (modes & SCContentSharingPickerModeSingleDisplay) &&
        (style == SCShareableContentStyleNone || style == SCShareableContentStyleDisplay)) {
        [titles addObject:@"Entire Screen"];
        [filters addObject:[[[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]] autorelease]];
    }
    if (display && (modes & (SCContentSharingPickerModeSingleApplication | SCContentSharingPickerModeMultipleApplications)) &&
        (style == SCShareableContentStyleNone || style == SCShareableContentStyleApplication))
        for (SCRunningApplication *app in [content applications]) {
            BOOL hasWindows = NO;
            for (SCWindow *w in [content windows])
                hasWindows |= [w owningApplication] == app && [w windowLayer] == 0;
            if (!hasWindows || [app processID] == me || [excludedBundles containsObject:[app bundleIdentifier]])
                continue;
            [titles addObject:[NSString stringWithFormat:@"%@ (all windows)", [app applicationName]]];
            [filters addObject:[[[SCContentFilter alloc] initWithDisplay:display includingApplications:@[ app ]
                                                        exceptingWindows:@[]] autorelease]];
        }
    if ((modes & (SCContentSharingPickerModeSingleWindow | SCContentSharingPickerModeMultipleWindows)) &&
        (style == SCShareableContentStyleNone || style == SCShareableContentStyleWindow))
        for (SCWindow *w in [content windows]) {
            SCRunningApplication *app = [w owningApplication];
            if ([w windowLayer] != 0 || [app processID] == me || [excludedWindows containsObject:@([w windowID])] ||
                [excludedBundles containsObject:[app bundleIdentifier]])
                continue;
            [titles addObject:[NSString stringWithFormat:@"%@ — %@", [app applicationName], [[w title] length] ? [w title] : @"Untitled"]];
            [filters addObject:[[[SCContentFilter alloc] initWithDesktopIndependentWindow:w] autorelease]];
        }
}

- (void)_finchPresentForStream:(SCStream *)stream style:(SCShareableContentStyle)style
{
    if (!_active) {
        NSError *e = SCFinchError(SCStreamErrorFailedToStart, @"The picker is not active");
        for (id<SCContentSharingPickerObserver> o in [_observers allObjects])
            [o contentSharingPickerStartDidFailWithError:e];
        return;
    }
    SCContentSharingPickerConfiguration *config = (stream ? [_streamConfigs objectForKey:stream] : nil) ?: _default;
    NSMutableArray *titles = [NSMutableArray array], *filters = [NSMutableArray array];
    [self _finchChoicesFor:config style:style titles:titles filters:filters];

    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    [alert setMessageText:@"Choose what to share"];
    [alert setInformativeText:[NSString stringWithFormat:@"“%@” wants to capture your screen.",
                                                         [[NSProcessInfo processInfo] processName]]];
    NSPopUpButton *popup = [[[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 300, 26) pullsDown:NO] autorelease];
    [popup addItemsWithTitles:titles];
    [alert setAccessoryView:popup];
    [alert addButtonWithTitle:@"Share"];
    [alert addButtonWithTitle:@"Cancel"];
    if (![titles count])
        [[alert buttons][0] setEnabled:NO];
    NSModalResponse r = [alert runModal];
    NSArray *observers = [_observers allObjects];
    if (r == NSAlertFirstButtonReturn && [popup indexOfSelectedItem] >= 0) {
        SCContentFilter *f = filters[(NSUInteger)[popup indexOfSelectedItem]];
        for (id<SCContentSharingPickerObserver> o in observers)
            [o contentSharingPicker:self didUpdateWithFilter:f forStream:stream];
    } else {
        for (id<SCContentSharingPickerObserver> o in observers)
            [o contentSharingPicker:self didCancelForStream:stream];
    }
}

@end
