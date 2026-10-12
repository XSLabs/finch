/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * OnBoardingKit (private), the AppKit side, Finch's own: the welcome and privacy screens
 * Mac apps show. OBTemplateView lays out an icon, a title, a headline, body text and a
 * content area in a column; OBTemplateContainerViewController puts one above a tray of
 * buttons (primary, secondary, cancel), with a spinner and a status line;
 * OBTemplatePartBulletList is a scrolling list of titled items with images or symbols.
 * The privacy screens (OBBundle, OBPrivacyFlow, OBPrivacyLinkController,
 * OBPrivacyPresenter, OBPrivacySplashController) would show Apple's privacy text from
 * its OnBoarding bundles; Finch carries none, so they show Finch's own statement.
 * The UIKit classes (OBWelcomeController and its buttons) wait for UIKit.
 */
#import <AppKit/AppKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#define OB_EXPORT __attribute__((visibility("default")))

OB_EXPORT NSString *const OBPrivacyAppleArcadeIdentifier = @"com.apple.onboarding.applearcade";
OB_EXPORT NSString *const OBPrivacyAppleMusicIdentifier = @"com.apple.onboarding.applemusic";
OB_EXPORT NSString *const OBPrivacyAppStoreIdentifier = @"com.apple.onboarding.appstore";
OB_EXPORT NSString *const OBPrivacyiTunesStoreIdentifier = @"com.apple.onboarding.itunesstore";
OB_EXPORT NSString *const OBPrivacyTVAppIdentifier = @"com.apple.onboarding.tvapp";

static NSString *
finch_privacy_text(void)
{
    return @"Finch keeps what you do in this app on this Mac. It sends nothing to Apple or "
           @"anyone else, and no account is needed. Some features of the app that depend on "
           @"Apple's services aren't available.";
}

#pragma mark - Template view

OB_EXPORT
@interface OBTemplateView : NSView
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *headline;
@property (nonatomic, copy) NSString *bodyText;
@property (nonatomic, copy) NSAttributedString *attributedBodyText;
@property (nonatomic, strong) NSImage *topImage;
@property (nonatomic, copy) NSString *topImageSymbolName;
@property (nonatomic, strong) NSColor *topImageTintColor;
@property (nonatomic, strong) NSView *topContent;
@property (nonatomic, strong) NSView *contentView;
@property (nonatomic, strong) NSView *contentArea; /* (accessors written below) */
@property (nonatomic, strong) NSTextField *titleView;
@property (nonatomic, strong) NSTextField *headlineView;
@property (nonatomic, strong) NSTextField *bodyTextView;
@property (nonatomic, strong) NSImageView *iconImageView;
@property (nonatomic) NSInteger layoutStyle;
@property (nonatomic) NSUInteger templateType;
@property (nonatomic) NSTextAlignment bodyTextAlignment;
@property BOOL needsExtraWideContent;
@property BOOL usesLargeContentArea;
@end

@implementation OBTemplateView {
    NSView *_contentArea;
}

- (instancetype)initWithFrame:(NSRect)frame
{
    if ((self = [super initWithFrame:frame]))
        [self commonInit];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super initWithCoder:coder]))
        [self commonInit];
    return self;
}

static NSTextField *
label(CGFloat size, NSFontWeight weight)
{
    NSTextField *t = [NSTextField wrappingLabelWithString:@""];
    t.font = [NSFont systemFontOfSize:size weight:weight];
    t.alignment = NSTextAlignmentCenter;
    t.selectable = NO;
    return t;
}

- (void)commonInit
{
    if (_titleView)
        return;
    _iconImageView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _iconImageView.imageScaling = NSImageScaleProportionallyUpOrDown;
    _titleView = label(22, NSFontWeightBold);
    _headlineView = label(15, NSFontWeightSemibold);
    _bodyTextView = label(13, NSFontWeightRegular);
    _bodyTextAlignment = NSTextAlignmentCenter;
    for (NSView *v in @[ _iconImageView, _titleView, _headlineView, _bodyTextView ])
        [self addSubview:v];
}

- (BOOL)isFlipped { return YES; }

- (void)setTitle:(NSString *)title { _title = [title copy]; _titleView.stringValue = title ?: @""; [self setNeedsLayout:YES]; }
- (void)setHeadline:(NSString *)h { _headline = [h copy]; _headlineView.stringValue = h ?: @""; [self setNeedsLayout:YES]; }
- (void)setBodyText:(NSString *)b { _bodyText = [b copy]; _bodyTextView.stringValue = b ?: @""; [self setNeedsLayout:YES]; }

- (void)setAttributedBodyText:(NSAttributedString *)b
{
    _attributedBodyText = [b copy];
    _bodyTextView.attributedStringValue = b ?: [[NSAttributedString alloc] init];
    [self setNeedsLayout:YES];
}

- (void)setBodyTextAlignment:(NSTextAlignment)a
{
    _bodyTextAlignment = a;
    _bodyTextView.alignment = a;
}

- (void)setTopImage:(NSImage *)image { _topImage = image; _iconImageView.image = image; [self setNeedsLayout:YES]; }

- (void)setTopImageSymbolName:(NSString *)name
{
    _topImageSymbolName = [name copy];
    NSImage *i = name ? [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil] : nil;
    _iconImageView.image = [i imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:48 weight:NSFontWeightRegular]];
    _iconImageView.contentTintColor = _topImageTintColor ?: [NSColor controlAccentColor];
    [self setNeedsLayout:YES];
}

- (void)setTopImageTintColor:(NSColor *)c { _topImageTintColor = c; _iconImageView.contentTintColor = c; }

- (void)setContentView:(NSView *)v
{
    if (_contentView == v)
        return;
    [_contentView removeFromSuperview];
    _contentView = v;
    if (v)
        [self addSubview:v];
    [self setNeedsLayout:YES];
}

- (NSView *)contentArea { return _contentArea ?: _contentView; }
- (void)setContentArea:(NSView *)v { _contentArea = v; [self setContentView:v]; }

- (void)setTopContent:(NSView *)v
{
    [_topContent removeFromSuperview];
    _topContent = v;
    if (v)
        [self addSubview:v];
    [self setNeedsLayout:YES];
}

- (void)layout
{
    [super layout];
    [self layoutSubviews];
}

/* A centred column: icon, title, headline, body, then the content area to the bottom. */
- (void)layoutSubviews
{
    CGFloat w = self.bounds.size.width, margin = _needsExtraWideContent ? 24 : 48, inner = MAX(40, w - 2 * margin);
    CGFloat y = 32;
    NSView *top = _topContent ?: (_iconImageView.image ? _iconImageView : nil);
    _iconImageView.hidden = top != _iconImageView;
    if (top) {
        NSSize s = _topContent ? _topContent.fittingSize : NSMakeSize(64, 64);
        if (s.width < 1 || s.height < 1)
            s = NSMakeSize(64, 64);
        top.frame = NSMakeRect(floor((w - s.width) / 2), y, s.width, s.height);
        y += s.height + 16;
    }
    for (NSTextField *t in @[ _titleView, _headlineView, _bodyTextView ]) {
        t.hidden = t.stringValue.length == 0;
        if (t.hidden)
            continue;
        t.preferredMaxLayoutWidth = inner;
        NSSize s = [t.cell cellSizeForBounds:NSMakeRect(0, 0, inner, 10000)];
        t.frame = NSMakeRect(margin, y, inner, ceil(s.height));
        y += ceil(s.height) + (t == _titleView ? 10 : 8);
    }
    if (_contentView) {
        y += 8;
        _contentView.frame = NSMakeRect(margin, y, inner, MAX(0, self.bounds.size.height - y - 16));
    }
}

- (void)viewDidMoveToWindow { [self setNeedsLayout:YES]; }
- (void)updateLayer {}

@end

#pragma mark - Bullet list

OB_EXPORT
@interface OBTemplatePartBulletList : NSScrollView
@property (strong) NSStackView *stack;
@property double itemWidth;
@property double itemInset;
@property (nonatomic) NSUInteger templateType;
@property (nonatomic) BOOL needsExtraWideContent;
@property (nonatomic) NSInteger bulletListSpacing;
@property (nonatomic) BOOL bulletsHaveBackgrounds;
@end

@implementation OBTemplatePartBulletList

- (instancetype)initWithFrame:(NSRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        _stack = [[NSStackView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, 10)];
        _stack.orientation = NSUserInterfaceLayoutOrientationVertical;
        _stack.alignment = NSLayoutAttributeLeading;
        _stack.spacing = 16;
        self.documentView = _stack;
        self.drawsBackground = NO;
        self.hasVerticalScroller = YES;
        self.autohidesScrollers = YES;
    }
    return self;
}

- (void)addItemWithTitle:(NSString *)title description:(NSString *)description image:(NSImage *)image imageTintColor:(NSColor *)tint
{
    NSImageView *iv = [NSImageView imageViewWithImage:image ?: [NSImage new]];
    iv.contentTintColor = tint;
    iv.imageScaling = NSImageScaleProportionallyUpOrDown;
    [iv.widthAnchor constraintEqualToConstant:32].active = YES;
    [iv.heightAnchor constraintEqualToConstant:32].active = YES;
    NSTextField *t = [NSTextField labelWithString:title ?: @""];
    t.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    NSTextField *d = [NSTextField wrappingLabelWithString:description ?: @""];
    d.textColor = [NSColor secondaryLabelColor];
    NSStackView *text = [NSStackView stackViewWithViews:@[ t, d ]];
    text.orientation = NSUserInterfaceLayoutOrientationVertical;
    text.alignment = NSLayoutAttributeLeading;
    text.spacing = 2;
    NSStackView *row = [NSStackView stackViewWithViews:@[ iv, text ]];
    row.alignment = NSLayoutAttributeTop;
    row.spacing = 12;
    [_stack addArrangedSubview:row];
    [self tile];
}

- (void)addItemWithTitle:(NSString *)title description:(NSString *)description symbol:(NSString *)symbol symbolTintColor:(NSColor *)tint
{
    NSImage *i = symbol ? [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil] : nil;
    [self addItemWithTitle:title description:description image:i imageTintColor:tint ?: [NSColor controlAccentColor]];
}

- (void)tile
{
    [super tile];
    NSSize fit = _stack.fittingSize;
    _stack.frame = NSMakeRect(0, 0, self.contentSize.width, MAX(fit.height, self.contentSize.height));
}

- (void)viewDidMoveToWindow { [self tile]; }

@end

#pragma mark - Container

OB_EXPORT
@interface OBTemplateContainerViewController : NSViewController
@property (nonatomic, strong) OBTemplateView *templateView;
@property (nonatomic, strong) NSView *templateContainerView;
@property (nonatomic, strong) NSView *buttonTray;
@property (nonatomic, strong) NSBox *divider;
@property (nonatomic, strong) NSButton *primaryButton;
@property (nonatomic, strong) NSButton *secondaryButton;
@property (nonatomic, strong) NSButton *cancelButton;
@property (nonatomic, strong) NSButton *backButton;
@property (nonatomic, strong) NSProgressIndicator *spinner;
@property (nonatomic, strong) NSTextField *statusMessage;
@property (nonatomic, strong) NSMutableArray *buttonConstraints;
@property (nonatomic, getter=isSpinnerVisible, setter=setSpinnerVisible:) BOOL spinnerVisible;
@property (readonly) NSButton *firstButton;
@property (readonly) NSButton *secondButton;
@property (readonly) NSButton *linkButton;
@end

@implementation OBTemplateContainerViewController {
    NSString *_titles[3];
    NSButton *_linkButton;
}

- (instancetype)initWithTemplateView:(OBTemplateView *)view primaryButtonTitle:(NSString *)primary
                secondaryButtonTitle:(NSString *)secondary cancelButtonTitle:(NSString *)cancel
{
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _templateView = view;
        _titles[0] = [primary copy];
        _titles[1] = [secondary copy];
        _titles[2] = [cancel copy];
    }
    return self;
}

- (instancetype)initWithPrimaryButtonTitle:(NSString *)primary secondaryButtonTitle:(NSString *)secondary
                         cancelButtonTitle:(NSString *)cancel
{
    return [self initWithTemplateView:nil primaryButtonTitle:primary secondaryButtonTitle:secondary cancelButtonTitle:cancel];
}

/* (the older names: first is primary, second secondary, the link a borderless button) */
- (instancetype)initWithTemplateView:(OBTemplateView *)view firstButtonTitle:(NSString *)first
                   secondButtonTitle:(NSString *)second linkButtonTitle:(NSString *)link
{
    if ((self = [self initWithTemplateView:view primaryButtonTitle:first secondaryButtonTitle:second cancelButtonTitle:nil]) && link) {
        _linkButton = [NSButton buttonWithTitle:link target:nil action:NULL];
        _linkButton.bordered = NO;
        _linkButton.contentTintColor = [NSColor linkColor];
    }
    return self;
}

- (instancetype)initWithFirstButtonTitle:(NSString *)first secondButtonTitle:(NSString *)second linkButtonTitle:(NSString *)link
{
    return [self initWithTemplateView:nil firstButtonTitle:first secondButtonTitle:second linkButtonTitle:link];
}

- (NSButton *)firstButton { return self.primaryButton; }
- (NSButton *)secondButton { return self.secondaryButton; }
- (NSButton *)linkButton { return _linkButton; }

- (void)loadView
{
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 640, 520)];
    if (!_templateView)
        _templateView = [[OBTemplateView alloc] initWithFrame:NSZeroRect];
    _templateContainerView = [[NSView alloc] initWithFrame:NSZeroRect];
    [_templateContainerView addSubview:_templateView];
    _buttonTray = [[NSView alloc] initWithFrame:NSZeroRect];
    _divider = [[NSBox alloc] initWithFrame:NSZeroRect];
    _divider.boxType = NSBoxSeparator;
    if (_titles[0]) {
        _primaryButton = [NSButton buttonWithTitle:_titles[0] target:nil action:NULL];
        _primaryButton.keyEquivalent = @"\r";
    }
    if (_titles[1])
        _secondaryButton = [NSButton buttonWithTitle:_titles[1] target:nil action:NULL];
    if (_titles[2]) {
        _cancelButton = [NSButton buttonWithTitle:_titles[2] target:nil action:NULL];
        _cancelButton.keyEquivalent = @"\e";
    }
    _spinner = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    _spinner.style = NSProgressIndicatorStyleSpinning;
    _spinner.controlSize = NSControlSizeSmall;
    _spinner.displayedWhenStopped = NO;
    _statusMessage = [NSTextField labelWithString:@""];
    _statusMessage.textColor = [NSColor secondaryLabelColor];
    for (NSView *v in @[ _spinner, _statusMessage ])
        [_buttonTray addSubview:v];
    for (NSButton *b in @[ _primaryButton ?: (id)[NSNull null], _secondaryButton ?: (id)[NSNull null], _cancelButton ?: (id)[NSNull null],
                           _linkButton ?: (id)[NSNull null] ])
        if ([b isKindOfClass:[NSButton class]])
            [_buttonTray addSubview:b];
    for (NSView *v in @[ _templateContainerView, _divider, _buttonTray ])
        [root addSubview:v];
    self.view = root;
}

- (void)viewDidLayout
{
    [super viewDidLayout];
    NSRect b = self.view.bounds;
    CGFloat tray = 60;
    _buttonTray.frame = NSMakeRect(0, 0, b.size.width, tray);
    _divider.frame = NSMakeRect(0, tray, b.size.width, 1);
    _templateContainerView.frame = NSMakeRect(0, tray + 1, b.size.width, b.size.height - tray - 1);
    _templateView.frame = _templateContainerView.bounds;
    /* buttons from the right: primary, secondary, cancel; the link at the left */
    CGFloat x = b.size.width - 20;
    for (NSButton *button in @[ _primaryButton ?: (id)[NSNull null], _secondaryButton ?: (id)[NSNull null],
                                _cancelButton ?: (id)[NSNull null] ]) {
        if (![button isKindOfClass:[NSButton class]] || button.hidden)
            continue;
        NSSize s = button.fittingSize;
        s.width = MAX(s.width, 96);
        x -= s.width;
        button.frame = NSMakeRect(x, floor((tray - s.height) / 2), s.width, s.height);
        x -= 12;
    }
    _linkButton.frame = NSMakeRect(20, floor((tray - 20) / 2), _linkButton.fittingSize.width, 20);
    _spinner.frame = NSMakeRect(20, floor((tray - 16) / 2), 16, 16);
    _statusMessage.frame = NSMakeRect(44, floor((tray - 16) / 2), MAX(0, x - 52), 16);
}

- (void)viewDidLoad { [super viewDidLoad]; }
- (void)viewDidAppear { [super viewDidAppear]; }

- (void)setSpinnerVisible:(BOOL)visible
{
    _spinnerVisible = visible;
    if (visible)
        [_spinner startAnimation:nil];
    else
        [_spinner stopAnimation:nil];
}

- (void)hideSpinner { self.spinnerVisible = NO; }
- (void)showSpinner { self.spinnerVisible = YES; }

- (void)setControlsEnabled:(BOOL)enabled
{
    for (NSButton *b in @[ _primaryButton ?: (id)[NSNull null], _secondaryButton ?: (id)[NSNull null], _cancelButton ?: (id)[NSNull null],
                           _linkButton ?: (id)[NSNull null] ])
        if ([b isKindOfClass:[NSButton class]])
            b.enabled = enabled;
}

@end

#pragma mark - Privacy

OB_EXPORT
@interface OBBundle : NSObject
@property BOOL isPlaceholder;
@property BOOL isLinkBundle;
@property BOOL isReplacementBundle;
@property (readonly, copy) NSString *identifier;
@property (readonly, copy) NSString *name;
@property (readonly, copy) NSString *bundleVersion;
@property (readonly, strong) NSBundle *bundle;
@end

@class OBPrivacyFlow;

@implementation OBBundle

/* Apple's privacy bundles live in /System/Library/OnBoardingBundles; Finch has none, so
   each is a placeholder for Finch's own statement. */
+ (instancetype)bundleWithIdentifier:(NSString *)identifier
{
    OBBundle *b = [[self alloc] initWithBundle:nil];
    b->_identifier = [identifier copy];
    b->_name = @"Finch";
    return b;
}

- (instancetype)initWithBundle:(NSBundle *)bundle
{
    if ((self = [super init])) {
        _bundle = bundle;
        _identifier = [bundle.bundleIdentifier copy];
        _name = [bundle objectForInfoDictionaryKey:@"CFBundleName"];
        _bundleVersion = [bundle objectForInfoDictionaryKey:@"CFBundleVersion"];
        _isPlaceholder = bundle == nil;
    }
    return self;
}

- (NSBundle *)underlyingBundle { return _bundle; }
- (OBPrivacyFlow *)privacyFlow
{
    return ((id(*)(id, SEL, id))objc_msgSend)(NSClassFromString(@"OBPrivacyFlow"), @selector(flowWithBundle:), self);
}

@end

OB_EXPORT
@interface OBFlow : NSObject
@end

@implementation OBFlow
@end

OB_EXPORT
@interface OBPrivacyFlow : OBFlow
+ (instancetype)flowWithBundle:(OBBundle *)bundle;
@property (strong) OBBundle *bundle;
@property (nonatomic, strong) NSImage *buttonIcon;
@end

@implementation OBPrivacyFlow

+ (instancetype)flowWithBundle:(OBBundle *)bundle
{
    return [[self alloc] initWithBundle:bundle];
}

- (instancetype)initWithBundle:(OBBundle *)bundle
{
    if ((self = [super init]))
        _bundle = bundle;
    return self;
}

- (NSString *)identifier { return _bundle.identifier; }
- (NSString *)localizedTitle { return @"Your Data on Finch"; }
- (NSString *)localizedShortTitle { return @"Privacy"; }
- (NSString *)localizedButtonTitle { return @"See how your data is handled…"; }
- (NSString *)localizedButtonCaption { return finch_privacy_text(); }
- (NSString *)localizedCombinedHeader { return [self localizedTitle]; }
- (NSAttributedString *)localizedCombinedFooter { return [[NSAttributedString alloc] initWithString:@""]; }
- (NSArray *)localizedContentList { return @[ finch_privacy_text() ]; }
- (NSUInteger)contentVersion { return 1; }
- (BOOL)platformSupported { return YES; }
- (BOOL)showInCombinedList { return YES; }
- (BOOL)enablesGroupingInCombinedList { return NO; }
- (BOOL)isPersonallyIdentifiable { return NO; }
- (NSString *)_deviceClass { return @"Mac"; }
- (NSString *)_iconSymbolName { return @"hand.raised"; }

- (NSImage *)buttonIcon
{
    return _buttonIcon ?: [NSImage imageWithSystemSymbolName:@"hand.raised" accessibilityDescription:nil];
}

@end

/* The privacy screen: a window with the flow's title and text, and OK. */
OB_EXPORT
@interface OBPrivacySplashController : NSWindowController
@property (nonatomic, strong) OBPrivacyFlow *flow;
@property (strong) OBTemplateContainerViewController *containerViewController;
@property BOOL showsLinkToUnifiedAbout;
@property BOOL showPIIIcon;
@property BOOL allowsOpeningSafari;
@property BOOL useModalStyle;
@property (strong) NSColor *customTintColor;
@end

@implementation OBPrivacySplashController

- (instancetype)initWithFlow:(OBPrivacyFlow *)flow
{
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 520, 440)
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                backing:NSBackingStoreBuffered
                                                  defer:YES];
    w.title = flow.localizedShortTitle ?: @"Privacy";
    if ((self = [super initWithWindow:w])) {
        _flow = flow;
        [self prepareContentView];
    }
    return self;
}

- (instancetype)initWithPrivacyIdentifier:(NSString *)identifier
{
    return [self initWithFlow:[OBPrivacyFlow flowWithBundle:[OBBundle bundleWithIdentifier:identifier]]];
}

- (void)prepareContentView
{
    OBTemplateView *t = [[OBTemplateView alloc] initWithFrame:NSZeroRect];
    t.topImageSymbolName = @"hand.raised";
    t.title = _flow.localizedTitle;
    t.bodyText = finch_privacy_text();
    _containerViewController = [[OBTemplateContainerViewController alloc] initWithTemplateView:t primaryButtonTitle:@"OK"
                                                                          secondaryButtonTitle:nil cancelButtonTitle:nil];
    self.window.contentViewController = _containerViewController;
    _containerViewController.primaryButton.target = self;
    _containerViewController.primaryButton.action = @selector(_done:);
}

- (void)_done:(id)sender
{
    if (self.window.sheetParent)
        [self.window.sheetParent endSheet:self.window];
    else
        [self close];
}

- (void)scrollToTop {}
- (NSString *)_defaultButtonTitle { return @"OK"; }

@end

OB_EXPORT
@interface OBPrivacyPresenter : NSObject
@property (copy) void (^dismissHandler)(void);
@property (weak) NSWindow *presentingWindow;
@property (strong) NSWindowController *presentedController;
@property (strong) OBPrivacySplashController *splashController;
@property (strong) NSArray *presentedIdentifiers;
@property (copy, nonatomic) NSString *displayLanguage;
@property (strong, nonatomic) NSColor *customTintColor;
@end

@implementation OBPrivacyPresenter

+ (instancetype)presenterForPrivacySplashWithIdentifier:(NSString *)identifier
{
    OBPrivacyPresenter *p = [self new];
    p.presentedIdentifiers = identifier ? @[ identifier ] : @[];
    return p;
}

+ (instancetype)presenterForPrivacyUnifiedAboutWithIdentifiers:(NSArray *)identifiers
{
    OBPrivacyPresenter *p = [self new];
    p.presentedIdentifiers = identifiers ?: @[];
    return p;
}

/* As a sheet on the presenting window, else a window of its own. */
- (void)present
{
    OBPrivacySplashController *c = [[OBPrivacySplashController alloc] initWithPrivacyIdentifier:_presentedIdentifiers.firstObject];
    _splashController = c;
    _presentedController = c;
    NSWindow *parent = _presentingWindow;
    void (^done)(void) = _dismissHandler;
    if (parent) {
        [parent beginSheet:c.window completionHandler:^(NSModalResponse r) {
            if (done)
                done();
        }];
    } else {
        [c showWindow:nil];
        [c.window center];
    }
}

@end

/* A link to the privacy screen, for the bottom of a welcome screen. */
OB_EXPORT
@interface OBPrivacyLinkController : NSViewController
+ (instancetype)linkWithBundleIdentifier:(NSString *)identifier;
+ (instancetype)linkWithBundleIdentifiers:(NSArray *)identifiers;
@property NSTextAlignment textAlignment;
@property (strong) NSColor *iconTintColor;
@property (strong) NSColor *textTintColor;
@property BOOL displayIcon;
@property BOOL displayInfoIcon;
@property BOOL displayLargeIcon;
@property BOOL displayCaptionText;
@property BOOL allowsOpeningSafari;
@property (copy) void (^privacyLinkCallback)(void);
@property (readonly) NSArray *bundles;
@end

@implementation OBPrivacyLinkController {
    NSArray *_identifiers;
}

+ (instancetype)linkWithBundleIdentifier:(NSString *)identifier
{
    return [self linkWithBundleIdentifiers:identifier ? @[ identifier ] : @[]];
}

+ (instancetype)linkWithBundleIdentifiers:(NSArray *)identifiers
{
    OBPrivacyLinkController *c = [[self alloc] initWithNibName:nil bundle:nil];
    c->_identifiers = [identifiers copy];
    c.textAlignment = NSTextAlignmentCenter;
    c.displayIcon = YES;
    return c;
}

- (instancetype)init
{
    return [self initWithNibName:nil bundle:nil];
}

- (NSArray *)bundles
{
    NSMutableArray *a = [NSMutableArray array];
    for (NSString *i in _identifiers)
        [a addObject:[OBBundle bundleWithIdentifier:i]];
    return a;
}

- (OBBundle *)bundle { return self.bundles.firstObject; }
- (OBPrivacyFlow *)flow { return [OBPrivacyFlow flowWithBundle:self.bundle]; }

- (void)loadView
{
    NSButton *b = [NSButton buttonWithTitle:self.flow.localizedButtonTitle target:self action:@selector(_open:)];
    b.bordered = NO;
    b.contentTintColor = _textTintColor ?: [NSColor linkColor];
    if (_displayIcon || _displayInfoIcon) {
        b.image = [NSImage imageWithSystemSymbolName:_displayInfoIcon ? @"info.circle" : @"hand.raised" accessibilityDescription:nil];
        b.imagePosition = NSImageLeading;
    }
    [b sizeToFit];
    self.view = b;
}

- (void)_open:(id)sender
{
    if (_privacyLinkCallback) {
        _privacyLinkCallback();
        return;
    }
    OBPrivacyPresenter *p = [OBPrivacyPresenter presenterForPrivacyUnifiedAboutWithIdentifiers:_identifiers];
    p.presentingWindow = self.view.window;
    [p present];
    objc_setAssociatedObject(self, @selector(_open:), p, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end
