/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * macOS 26's glass: NSGlassEffectView (and the private NSGlassView apps use),
 * NSGlassEffectContainerView. Fieldwork isn't glass: in it these draw as slate panels
 * (FinchGlassBackdrop below); the Classic theme draws a translucent stand-in for Apple's.
 * As with Apple's, the content view lives in a container inside the glass (beside the
 * backdrop), and the private variant settings are kept.
 */
#import "AppKit_Finch.h"
#import "FinchTheme.h"

/* (the material: drawn behind the content) */
@interface FinchGlassBackdrop : NSView
@end

@implementation FinchGlassBackdrop

/* Fieldwork: glass is a slate surface, solid and sharply defined, with the one-pixel
   outline and faint top-edge highlight of every Fieldwork panel (docs/design/FIELDWORK.md);
   a tint washes it lightly. Classic: a translucent rounded material, as close to Apple's
   glass as Finch can draw without blurring what's behind. */
- (void)drawRect:(NSRect)dirty
{
    NSGlassEffectView *glass = (NSGlassEffectView *)self.superview;
    BOOL isGlass = [glass isKindOfClass:[NSGlassEffectView class]];
    CGFloat radius = isGlass ? glass.cornerRadius : 8;
    NSColor *tint = isGlass ? glass.tintColor : nil;
    NSRect r = NSInsetRect(self.bounds, 0.5, 0.5);
    if (!FinchThemeIsClassic()) {
        radius = MIN(radius, FinchThemeMetric(@"windowTopCornerRadius", 6));
        NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:r xRadius:radius yRadius:radius];
        [(FinchThemePaletteColor(@"slate") ?: [NSColor controlBackgroundColor]) setFill];
        [path fill];
        if (tint) {
            [[tint colorWithAlphaComponent:0.12 * tint.alphaComponent] setFill];
            [path fill];
        }
        NSColor *highlight = FinchThemePaletteColor(@"edgeHighlight");
        if (highlight && NSHeight(r) > 6) {
            [NSGraphicsContext saveGraphicsState];
            [path addClip];
            [highlight setFill];
            NSRectFillUsingOperation(NSMakeRect(NSMinX(r), self.isFlipped ? NSMinY(r) + 0.5 : NSMaxY(r) - 1.5, NSWidth(r), 1),
                NSCompositingOperationSourceOver);
            [NSGraphicsContext restoreGraphicsState];
        }
        [(FinchThemePaletteColor(@"outline") ?: [NSColor separatorColor]) setStroke];
        path.lineWidth = FinchThemeMetric(@"windowOutlineWidth", 1);
        [path stroke];
        return;
    }
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:r xRadius:radius yRadius:radius];
    BOOL dark = [[self.effectiveAppearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]]
        isEqualToString:NSAppearanceNameDarkAqua];
    NSColor *base = dark ? [NSColor colorWithWhite:0.18 alpha:0.72] : [NSColor colorWithWhite:0.98 alpha:0.72];
    if (isGlass && glass.style == NSGlassEffectViewStyleClear)
        base = [base colorWithAlphaComponent:0.35];
    [base setFill];
    [path fill];
    if (tint) {
        [[tint colorWithAlphaComponent:0.25 * tint.alphaComponent] setFill];
        [path fill];
    }
    [[NSColor colorWithWhite:dark ? 1 : 0 alpha:0.12] setStroke];
    path.lineWidth = 1;
    [path stroke];
}

@end

@implementation NSGlassEffectView {
    FinchGlassBackdrop *_backdrop;
    NSView *_container;
    NSView *_contentView;
    CGFloat _cornerRadius;
    NSColor *_tintColor;
    NSGlassEffectViewStyle _style;
    BOOL _clips;
    /* (the private settings, kept) */
    NSInteger _variant, _interactionState, _subduedState, _scrimState, _contentLensing, _adaptiveAppearance, _disableEmbeddingCount;
    NSString *_subvariant, *_groupIdentifier;
    BOOL _useReducedShadowRadius;
}

- (void)_finchSetUp
{
    _cornerRadius = 8;
    _backdrop = [[FinchGlassBackdrop alloc] initWithFrame:self.bounds];
    _backdrop.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self addSubview:_backdrop];
    /* (the content's container is there from the start, as Apple's is) */
    _container = [[NSView alloc] initWithFrame:self.bounds];
    _container.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self addSubview:_container];
}

- (instancetype)initWithFrame:(NSRect)frameRect
{
    if ((self = [super initWithFrame:frameRect]))
        [self _finchSetUp];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super initWithCoder:coder])) {
        [self _finchSetUp];
        if ([coder containsValueForKey:@"NSCornerRadius"])
            _cornerRadius = [coder decodeDoubleForKey:@"NSCornerRadius"];
        _style = (NSGlassEffectViewStyle)[coder decodeIntegerForKey:@"NSStyle"];
        _tintColor = [[coder decodeObjectOfClass:[NSColor class] forKey:@"NSTintColor"] retain];
        NSView *content = [coder decodeObjectOfClass:[NSView class] forKey:@"NSContentView"];
        if (content)
            self.contentView = content;
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    [coder encodeDouble:_cornerRadius forKey:@"NSCornerRadius"];
    [coder encodeInteger:_style forKey:@"NSStyle"];
    [coder encodeObject:_tintColor forKey:@"NSTintColor"];
    [coder encodeObject:_contentView forKey:@"NSContentView"];
}

- (void)dealloc
{
    [_backdrop release];
    [_container release];
    [_contentView release];
    [_tintColor release];
    [_subvariant release];
    [_groupIdentifier release];
    [super dealloc];
}

- (NSView *)contentView { return _contentView; }

- (void)setContentView:(NSView *)view
{
    if (view == _contentView)
        return;
    [_contentView removeFromSuperview];
    [_contentView autorelease];
    _contentView = [view retain];
    if (!view)
        return;
    if (!_container) {
        _container = [[NSView alloc] initWithFrame:self.bounds];
        _container.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self addSubview:_container];
    }
    view.frame = _container.bounds;
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [_container addSubview:view];
}

- (CGFloat)cornerRadius { return _cornerRadius; }
- (void)setCornerRadius:(CGFloat)r { _cornerRadius = r; [_backdrop setNeedsDisplay:YES]; }
- (NSColor *)tintColor { return _tintColor; }
- (void)setTintColor:(NSColor *)c { [_tintColor autorelease]; _tintColor = [c copy]; [_backdrop setNeedsDisplay:YES]; }
- (NSGlassEffectViewStyle)style { return _style; }
- (void)setStyle:(NSGlassEffectViewStyle)s { _style = s; [_backdrop setNeedsDisplay:YES]; }
- (BOOL)clipsToBounds { return _clips; }
- (void)setClipsToBounds:(BOOL)c { _clips = c; }

- (NSInteger)_variant { return _variant; }
- (void)set_variant:(NSInteger)v { _variant = v; }
- (NSString *)_subvariant { return _subvariant; }
- (void)set_subvariant:(NSString *)s { [_subvariant autorelease]; _subvariant = [s copy]; }
- (NSInteger)_interactionState { return _interactionState; }
- (void)set_interactionState:(NSInteger)v { _interactionState = v; }
- (NSInteger)_subduedState { return _subduedState; }
- (void)set_subduedState:(NSInteger)v { _subduedState = v; }
- (NSInteger)_scrimState { return _scrimState; }
- (void)set_scrimState:(NSInteger)v { _scrimState = v; }
- (NSInteger)_contentLensing { return _contentLensing; }
- (void)set_contentLensing:(NSInteger)v { _contentLensing = v; }
- (NSInteger)_adaptiveAppearance { return _adaptiveAppearance; }
- (void)set_adaptiveAppearance:(NSInteger)v { _adaptiveAppearance = v; }
- (BOOL)_useReducedShadowRadius { return _useReducedShadowRadius; }
- (void)set_useReducedShadowRadius:(BOOL)v { _useReducedShadowRadius = v; }
- (NSString *)_groupIdentifier { return _groupIdentifier; }
- (void)set_groupIdentifier:(NSString *)s { [_groupIdentifier autorelease]; _groupIdentifier = [s copy]; }
- (NSInteger)_disableEmbeddingCount { return _disableEmbeddingCount; }
- (void)set_disableEmbeddingCount:(NSInteger)v { _disableEmbeddingCount = v; }
- (void)_incrementDisableEmbedding { _disableEmbeddingCount++; }
- (void)_decrementDisableEmbedding { _disableEmbeddingCount--; }

@end

/* (the private class apps use, a glass effect view by another name) */
@interface NSGlassView : NSGlassEffectView
@end

@implementation NSGlassView

/* (the theme's accent: Fieldwork has no glow colours) */
+ (NSColor *)_intelligentLightTintColor
{
    return [NSColor controlAccentColor];
}

@end

@implementation NSGlassEffectContainerView {
    NSView *_contentView;
    CGFloat _spacing;
}

- (void)dealloc
{
    [_contentView release];
    [super dealloc];
}

- (NSView *)contentView { return _contentView; }

- (void)setContentView:(NSView *)view
{
    if (view == _contentView)
        return;
    [_contentView removeFromSuperview];
    [_contentView autorelease];
    _contentView = [view retain];
    if (view) {
        view.frame = self.bounds;
        view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self addSubview:view];
    }
}

- (CGFloat)spacing { return _spacing; }
- (void)setSpacing:(CGFloat)s { _spacing = s; }

@end
