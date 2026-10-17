/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* A text caret view with the state and drawing behavior exposed by AppKit. */
#import <AppKit/AppKit.h>

@implementation NSTextInsertionIndicator {
    NSTextInsertionIndicatorDisplayMode _displayMode;
    BOOL _hasExplicitDisplayMode;
    NSColor *_color;
    NSTextInsertionIndicatorAutomaticModeOptions _automaticModeOptions;
    void (^_effectsViewInserter)(NSView *);
}

- (instancetype)initWithFrame:(NSRect)frame
{
    if ((self = [super initWithFrame:frame]))
        _automaticModeOptions = NSTextInsertionIndicatorAutomaticModeOptionsShowEffectsView;
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super initWithCoder:coder])) {
        _displayMode = [coder decodeIntegerForKey:@"NSTextInsertionIndicatorDisplayMode"];
        _hasExplicitDisplayMode = [coder containsValueForKey:@"NSTextInsertionIndicatorDisplayMode"] && _displayMode != 100;
        if (_displayMode == 100)
            _displayMode = NSTextInsertionIndicatorDisplayModeAutomatic;
        _color = [[coder decodeObjectForKey:@"NSTextInsertionIndicatorColor"] copy];
        _automaticModeOptions = [coder containsValueForKey:@"NSTextInsertionIndicatorAutomaticModeOptions"]
                                    ? [coder decodeIntegerForKey:@"NSTextInsertionIndicatorAutomaticModeOptions"]
                                    : NSTextInsertionIndicatorAutomaticModeOptionsShowEffectsView;
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    [coder encodeInteger:_hasExplicitDisplayMode ? _displayMode : 100 forKey:@"NSTextInsertionIndicatorDisplayMode"];
    [coder encodeObject:_color forKey:@"NSTextInsertionIndicatorColor"];
    [coder encodeInteger:_automaticModeOptions forKey:@"NSTextInsertionIndicatorAutomaticModeOptions"];
}

- (void)dealloc
{
    [_color release];
    [_effectsViewInserter release];
    [super dealloc];
}

- (NSTextInsertionIndicatorDisplayMode)displayMode
{
    return self.window && _hasExplicitDisplayMode ? _displayMode : (NSTextInsertionIndicatorDisplayMode)100;
}

- (void)setDisplayMode:(NSTextInsertionIndicatorDisplayMode)displayMode
{
    if (_hasExplicitDisplayMode && _displayMode == displayMode)
        return;
    _displayMode = displayMode;
    _hasExplicitDisplayMode = YES;
    if (self.window) {
        [self setHidden:displayMode == NSTextInsertionIndicatorDisplayModeHidden];
        [self setNeedsDisplay:YES];
    }
}

- (void)viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    if (_hasExplicitDisplayMode)
        [self setHidden:_displayMode == NSTextInsertionIndicatorDisplayModeHidden];
}

- (NSColor *)color { return _color ?: [NSColor textInsertionPointColor]; }

- (void)setColor:(NSColor *)color
{
    if (_color == color)
        return;
    [_color release];
    _color = [color copy];
    [self setNeedsDisplay:YES];
}

- (NSTextInsertionIndicatorAutomaticModeOptions)automaticModeOptions { return _automaticModeOptions; }

- (void)setAutomaticModeOptions:(NSTextInsertionIndicatorAutomaticModeOptions)options
{
    _automaticModeOptions = options;
}

- (void (^)(NSView *))effectsViewInserter { return _effectsViewInserter; }

- (void)setEffectsViewInserter:(void (^)(NSView *))inserter
{
    if (_effectsViewInserter == inserter)
        return;
    [_effectsViewInserter release];
    _effectsViewInserter = [inserter copy];
}

- (void)drawRect:(NSRect)dirtyRect
{
    if (_displayMode == NSTextInsertionIndicatorDisplayModeHidden)
        return;
    [[self color] setFill];
    NSRectFill(NSIntersectionRect([self bounds], dirtyRect));
}

@end
