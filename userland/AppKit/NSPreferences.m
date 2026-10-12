/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSPreferences and NSPreferencesModule, AppKit's old private preferences window that
 * some of Apple's apps still subclass: modules added by name, shown one at a time in a
 * window whose toolbar switches between them. The ivars apps read directly
 * (_preferencesPanel, _currentModule) are kept by those names.
 *
 * And AppKit's OpenGL classes: Finch has no OpenGL yet, so no pixel format can be made
 * (as on a Mac without the attributes asked for); an NSOpenGLView is a plain view with
 * no context.
 */
#import "AppKit_Finch.h"

#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#pragma clang diagnostic ignored "-Wdeprecated-implementations"

@interface NSPreferencesModule : NSObject {
@public
    NSBox *_preferencesView;
    NSSize _minSize;
    BOOL _hasChanges;
    void *_reserved;
}
+ (instancetype)sharedInstance;
- (NSString *)preferencesNibName;
- (NSView *)viewForPreferenceNamed:(NSString *)name;
- (NSImage *)imageForPreferenceNamed:(NSString *)name;
- (BOOL)hasChangesPending;
- (void)saveChanges;
- (void)willBeDisplayed;
- (void)initializeFromDefaults;
- (void)moduleWillBeRemoved;
- (void)moduleWasInstalled;
- (BOOL)moduleCanBeRemoved;
- (BOOL)preferencesWindowShouldClose;
- (BOOL)isResizable;
- (NSSize)minSize;
- (void)setMinSize:(NSSize)size;
- (void)didChange;
@end

@interface NSPreferences : NSObject <NSToolbarDelegate> {
@public
    NSWindow *_preferencesPanel;
    NSBox *_preferenceBox;
    NSMatrix *_moduleMatrix;
    NSButtonCell *_okButton, *_cancelButton, *_applyButton;
    NSMutableArray *_preferenceTitles;
    NSMutableArray *_preferenceModules;
    NSMutableDictionary *_masterPreferenceViews;
    NSMutableDictionary *_currentSessionPreferenceViews;
    NSBox *_originalContentView;
    BOOL _isModal;
    double _constrainedWidth;
    id _currentModule;
    void *_reserved;
}
+ (instancetype)sharedPreferences;
+ (void)setDefaultPreferencesClass:(Class)cls;
+ (Class)defaultPreferencesClass;
- (void)addPreferenceNamed:(NSString *)name owner:(id)owner;
- (void)showPreferencesPanel;
- (void)showPreferencesPanelForOwner:(id)owner;
- (NSWindow *)preferencesPanel;
- (NSString *)windowTitle;
- (BOOL)usesButtons;
@end

@implementation NSPreferencesModule

+ (instancetype)sharedInstance
{
    static NSMutableDictionary *instances;
    @synchronized([NSPreferencesModule class]) {
        if (!instances)
            instances = [NSMutableDictionary new];
        NSString *key = NSStringFromClass(self);
        id m = instances[key];
        if (!m) {
            m = [[[self alloc] init] autorelease];
            instances[key] = m;
        }
        return m;
    }
}

- (void)dealloc
{
    [_preferencesView release];
    [super dealloc];
}

- (NSString *)preferencesNibName { return NSStringFromClass([self class]); }
- (void)setPreferencesView:(NSBox *)view { [_preferencesView autorelease]; _preferencesView = [view retain]; }

/* The module's view, from its nib (whose _preferencesView outlet is a box). */
- (NSView *)viewForPreferenceNamed:(NSString *)name
{
    if (!_preferencesView) {
        NSNib *nib = [[[NSNib alloc] initWithNibNamed:[self preferencesNibName] bundle:[NSBundle bundleForClass:[self class]]] autorelease];
        [nib instantiateWithOwner:self topLevelObjects:NULL];
        [self initializeFromDefaults];
    }
    NSView *v = [_preferencesView isKindOfClass:[NSBox class]] ? _preferencesView.contentView : _preferencesView;
    return v;
}

- (NSImage *)imageForPreferenceNamed:(NSString *)name { return [NSImage imageNamed:name]; }
- (BOOL)hasChangesPending { return _hasChanges; }
- (void)saveChanges { _hasChanges = NO; }
- (void)willBeDisplayed {}
- (void)initializeFromDefaults {}
- (void)moduleWillBeRemoved {}
- (void)moduleWasInstalled {}
- (BOOL)moduleCanBeRemoved { return YES; }
- (BOOL)preferencesWindowShouldClose { return YES; }
- (BOOL)isResizable { return NO; }
- (NSSize)minSize { return _minSize; }
- (void)setMinSize:(NSSize)size { _minSize = size; }
- (void)didChange { _hasChanges = YES; }

@end

static Class default_preferences_class;

@implementation NSPreferences

+ (instancetype)sharedPreferences
{
    static NSPreferences *shared;
    @synchronized([NSPreferences class]) {
        if (!shared)
            shared = [[[self defaultPreferencesClass] alloc] init];
        return shared;
    }
}

+ (void)setDefaultPreferencesClass:(Class)cls { default_preferences_class = cls; }
+ (Class)defaultPreferencesClass { return default_preferences_class ?: self; }

- (instancetype)init
{
    if ((self = [super init])) {
        _preferenceTitles = [NSMutableArray new];
        _preferenceModules = [NSMutableArray new];
        _masterPreferenceViews = [NSMutableDictionary new];
        _currentSessionPreferenceViews = [NSMutableDictionary new];
    }
    return self;
}

- (void)dealloc
{
    [_preferencesPanel release];
    [_preferenceTitles release];
    [_preferenceModules release];
    [_masterPreferenceViews release];
    [_currentSessionPreferenceViews release];
    [super dealloc];
}

- (void)addPreferenceNamed:(NSString *)name owner:(id)owner
{
    if (!name || !owner)
        return;
    [_preferenceTitles addObject:name];
    [_preferenceModules addObject:owner];
    if ([owner respondsToSelector:@selector(moduleWasInstalled)])
        [owner moduleWasInstalled];
}

- (NSString *)windowTitle { return @"Settings"; }
- (BOOL)usesButtons { return NO; }
- (NSWindow *)preferencesPanel { return _preferencesPanel; }

- (void)_finchShowModuleAtIndex:(NSUInteger)index
{
    if (index >= _preferenceModules.count)
        return;
    id module = _preferenceModules[index];
    NSString *name = _preferenceTitles[index];
    NSView *view = _masterPreferenceViews[name];
    if (!view && [module respondsToSelector:@selector(viewForPreferenceNamed:)]) {
        view = [module viewForPreferenceNamed:name];
        if (view)
            _masterPreferenceViews[name] = view;
    }
    if ([module respondsToSelector:@selector(willBeDisplayed)])
        [module willBeDisplayed];
    _currentModule = module;
    if (view) {
        NSRect frame = _preferencesPanel.frame;
        NSRect content = [_preferencesPanel contentRectForFrameRect:frame];
        CGFloat dy = NSHeight(view.frame) - NSHeight(content);
        frame.origin.y -= dy;
        frame.size.height += dy;
        frame.size.width = MAX(NSWidth(view.frame), 320);
        _preferencesPanel.contentView = view;
        [_preferencesPanel setFrame:frame display:YES];
    }
    _preferencesPanel.title = name;
    _preferencesPanel.toolbar.selectedItemIdentifier = name;
}

- (void)_finchSelect:(NSToolbarItem *)item
{
    NSUInteger i = [_preferenceTitles indexOfObject:item.itemIdentifier];
    if (i != NSNotFound)
        [self _finchShowModuleAtIndex:i];
}

- (void)_finchMakePanel
{
    if (_preferencesPanel)
        return;
    _preferencesPanel = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 480, 320)
                                                    styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                      backing:NSBackingStoreBuffered defer:YES];
    _preferencesPanel.releasedWhenClosed = NO;
    _preferencesPanel.title = [self windowTitle];
    NSToolbar *toolbar = [[[NSToolbar alloc] initWithIdentifier:@"NSPreferences"] autorelease];
    toolbar.delegate = self;
    toolbar.allowsUserCustomization = NO;
    _preferencesPanel.toolbar = toolbar;
    _preferencesPanel.toolbarStyle = NSWindowToolbarStylePreference;
    [_preferencesPanel center];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar { return _preferenceTitles; }
- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar { return _preferenceTitles; }
- (NSArray<NSToolbarItemIdentifier> *)toolbarSelectableItemIdentifiers:(NSToolbar *)toolbar { return _preferenceTitles; }

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)identifier willBeInsertedIntoToolbar:(BOOL)flag
{
    NSUInteger i = [_preferenceTitles indexOfObject:identifier];
    if (i == NSNotFound)
        return nil;
    NSToolbarItem *item = [[[NSToolbarItem alloc] initWithItemIdentifier:identifier] autorelease];
    item.label = identifier;
    id module = _preferenceModules[i];
    if ([module respondsToSelector:@selector(imageForPreferenceNamed:)])
        item.image = [module imageForPreferenceNamed:identifier];
    item.target = self;
    item.action = @selector(_finchSelect:);
    return item;
}

- (void)showPreferencesPanel
{
    [self _finchMakePanel];
    if (!_currentModule && _preferenceModules.count)
        [self _finchShowModuleAtIndex:0];
    [_preferencesPanel makeKeyAndOrderFront:nil];
}

- (void)showPreferencesPanelForOwner:(id)owner
{
    [self _finchMakePanel];
    NSUInteger i = [_preferenceModules indexOfObjectIdenticalTo:owner];
    [self _finchShowModuleAtIndex:i == NSNotFound ? 0 : i];
    [_preferencesPanel makeKeyAndOrderFront:nil];
}

@end

