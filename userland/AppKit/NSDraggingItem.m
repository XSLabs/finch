/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Dragging items and their image components (what a drag shows, item by item), the
 * screen color sampler, and symbol image configurations.
 *
 * The color sampler's magnifying loupe picks a color from anywhere on screen; Finch's
 * window server doesn't offer one yet, so the sampler finishes at once with no color,
 * as when the user cancels. Symbol configurations are values; Finch has no symbol
 * images yet (SF Symbols are Apple's), so they configure nothing drawn.
 */
#import "AppKit_Finch.h"

NSDraggingImageComponentKey const NSDraggingImageComponentIconKey = @"icon";
NSDraggingImageComponentKey const NSDraggingImageComponentLabelKey = @"label";

@implementation NSDraggingImageComponent {
    NSString *_key;
    id _contents;
    NSRect _frame;
}

+ (NSDraggingImageComponent *)draggingImageComponentWithKey:(NSDraggingImageComponentKey)key
{
    return [[[self alloc] initWithKey:key] autorelease];
}

- (instancetype)initWithKey:(NSDraggingImageComponentKey)key
{
    if ((self = [super init]))
        _key = [key copy];
    return self;
}

- (void)dealloc
{
    [_key release];
    [_contents release];
    [super dealloc];
}

- (NSDraggingImageComponentKey)key { return _key; }
- (void)setKey:(NSDraggingImageComponentKey)key { [_key autorelease]; _key = [key copy]; }
- (id)contents { return _contents; }
- (void)setContents:(id)contents { [_contents autorelease]; _contents = [contents retain]; }
- (NSRect)frame { return _frame; }
- (void)setFrame:(NSRect)frame { _frame = frame; }

@end

@implementation NSDraggingItem {
    id _item;
    NSRect _draggingFrame;
    NSArray<NSDraggingImageComponent *> * (^_provider)(void);
    NSArray *_components;
}

- (instancetype)initWithPasteboardWriter:(id<NSPasteboardWriting>)pasteboardWriter
{
    if ((self = [super init]))
        _item = [pasteboardWriter retain];
    return self;
}

- (void)dealloc
{
    [_item release];
    [_provider release];
    [_components release];
    [super dealloc];
}

- (id)item { return _item; }
- (NSRect)draggingFrame { return _draggingFrame; }
- (void)setDraggingFrame:(NSRect)frame { _draggingFrame = frame; }

- (NSArray<NSDraggingImageComponent *> * (^)(void))imageComponentsProvider { return _provider; }
- (void)setImageComponentsProvider:(NSArray<NSDraggingImageComponent *> * (^)(void))provider
{
    [_provider autorelease];
    _provider = [provider copy];
    [_components release];
    _components = nil;
}

/* The frame, and the contents as one icon component the frame's size (as Apple's). */
- (void)setDraggingFrame:(NSRect)frame contents:(id)contents
{
    _draggingFrame = frame;
    [_provider release];
    _provider = nil;
    [_components release];
    _components = nil;
    if (contents) {
        NSDraggingImageComponent *c = [NSDraggingImageComponent draggingImageComponentWithKey:NSDraggingImageComponentIconKey];
        c.contents = contents;
        c.frame = NSMakeRect(0, 0, frame.size.width, frame.size.height);
        _components = [@[ c ] retain];
    }
}

- (NSArray<NSDraggingImageComponent *> *)imageComponents
{
    return _provider ? _provider() : _components;
}

@end

@implementation NSColorSampler

- (void)showSamplerWithSelectionHandler:(void (^)(NSColor *selectedColor))selectionHandler
{
    if (!selectionHandler)
        return;
    void (^handler)(NSColor *) = [selectionHandler copy];
    dispatch_async(dispatch_get_main_queue(), ^{
      handler(nil);
      [handler release];
    });
}

@end

/* --- symbol configurations --- */

@implementation NSImageSymbolConfiguration {
  @public
    CGFloat _pointSize;
    NSFontWeight _weight;
    NSImageSymbolScale _scale;
    NSString *_textStyle;
    NSColor *_hierarchicalColor;
    NSArray<NSColor *> *_paletteColors;
    BOOL _monochrome, _hierarchical, _multicolor;
    NSInteger _variableValueMode, _colorRenderingMode;
    BOOL _hasPointSize, _hasWeight, _hasScale;
}

+ (BOOL)supportsSecureCoding { return YES; }

/* (for symbol images, NSSystemImages.m: the size, weight and scale it sets, or 0 for each it doesn't) */
- (void)_finchPointSize:(CGFloat *)pointSize weight:(NSFontWeight *)weight hasWeight:(BOOL *)hasWeight scale:(NSImageSymbolScale *)scale
{
    *pointSize = _hasPointSize ? _pointSize
                 : _textStyle  ? [NSFont preferredFontForTextStyle:_textStyle options:@{}].pointSize
                               : 0;
    *weight = _weight;
    *hasWeight = _hasWeight;
    *scale = _hasScale ? _scale : (NSImageSymbolScale)0;
}

+ (instancetype)configurationWithPointSize:(CGFloat)pointSize weight:(NSFontWeight)weight scale:(NSImageSymbolScale)scale
{
    NSImageSymbolConfiguration *c = [[[self alloc] init] autorelease];
    c->_pointSize = pointSize, c->_hasPointSize = YES;
    c->_weight = weight, c->_hasWeight = YES;
    c->_scale = scale, c->_hasScale = YES;
    return c;
}

+ (instancetype)configurationWithPointSize:(CGFloat)pointSize weight:(NSFontWeight)weight
{
    NSImageSymbolConfiguration *c = [[[self alloc] init] autorelease];
    c->_pointSize = pointSize, c->_hasPointSize = YES;
    c->_weight = weight, c->_hasWeight = YES;
    return c;
}

+ (instancetype)configurationWithTextStyle:(NSFontTextStyle)style scale:(NSImageSymbolScale)scale
{
    NSImageSymbolConfiguration *c = [self configurationWithTextStyle:style];
    c->_scale = scale, c->_hasScale = YES;
    return c;
}

+ (instancetype)configurationWithTextStyle:(NSFontTextStyle)style
{
    NSImageSymbolConfiguration *c = [[[self alloc] init] autorelease];
    c->_textStyle = [style copy];
    return c;
}

+ (instancetype)configurationWithScale:(NSImageSymbolScale)scale
{
    NSImageSymbolConfiguration *c = [[[self alloc] init] autorelease];
    c->_scale = scale, c->_hasScale = YES;
    return c;
}

+ (instancetype)configurationPreferringMonochrome
{
    NSImageSymbolConfiguration *c = [[[self alloc] init] autorelease];
    c->_monochrome = YES;
    return c;
}

+ (instancetype)configurationPreferringHierarchical
{
    NSImageSymbolConfiguration *c = [[[self alloc] init] autorelease];
    c->_hierarchical = YES;
    return c;
}

+ (instancetype)configurationWithHierarchicalColor:(NSColor *)hierarchicalColor
{
    NSImageSymbolConfiguration *c = [[[self alloc] init] autorelease];
    c->_hierarchicalColor = [hierarchicalColor retain];
    return c;
}

+ (instancetype)configurationWithPaletteColors:(NSArray<NSColor *> *)paletteColors
{
    NSImageSymbolConfiguration *c = [[[self alloc] init] autorelease];
    c->_paletteColors = [paletteColors copy];
    return c;
}

+ (instancetype)configurationPreferringMulticolor
{
    NSImageSymbolConfiguration *c = [[[self alloc] init] autorelease];
    c->_multicolor = YES;
    return c;
}

+ (instancetype)configurationWithVariableValueMode:(NSImageSymbolVariableValueMode)variableValueMode
{
    NSImageSymbolConfiguration *c = [[[self alloc] init] autorelease];
    c->_variableValueMode = variableValueMode;
    return c;
}

+ (instancetype)configurationWithColorRenderingMode:(NSImageSymbolColorRenderingMode)mode
{
    NSImageSymbolConfiguration *c = [[[self alloc] init] autorelease];
    c->_colorRenderingMode = mode;
    return c;
}

- (void)dealloc
{
    [_textStyle release];
    [_hierarchicalColor release];
    [_paletteColors release];
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone
{
    NSImageSymbolConfiguration *c = [[NSImageSymbolConfiguration allocWithZone:zone] init];
    c->_pointSize = _pointSize, c->_hasPointSize = _hasPointSize;
    c->_weight = _weight, c->_hasWeight = _hasWeight;
    c->_scale = _scale, c->_hasScale = _hasScale;
    c->_textStyle = [_textStyle copy];
    c->_hierarchicalColor = [_hierarchicalColor retain];
    c->_paletteColors = [_paletteColors copy];
    c->_monochrome = _monochrome, c->_hierarchical = _hierarchical, c->_multicolor = _multicolor;
    c->_variableValueMode = _variableValueMode, c->_colorRenderingMode = _colorRenderingMode;
    return c;
}

/* The receiver's values, then the other's wherever it sets one (a palette or
   hierarchical color replaces the other kind, as the last one given wins). */
- (instancetype)configurationByApplyingConfiguration:(NSImageSymbolConfiguration *)o
{
    NSImageSymbolConfiguration *c = [[self copy] autorelease];
    if (!o)
        return c;
    if (o->_hasPointSize)
        c->_pointSize = o->_pointSize, c->_hasPointSize = YES;
    if (o->_hasWeight)
        c->_weight = o->_weight, c->_hasWeight = YES;
    if (o->_hasScale)
        c->_scale = o->_scale, c->_hasScale = YES;
    if (o->_textStyle) {
        [c->_textStyle release];
        c->_textStyle = [o->_textStyle copy];
    }
    if (o->_hierarchicalColor || o->_paletteColors) {
        [c->_hierarchicalColor release];
        [c->_paletteColors release];
        c->_hierarchicalColor = [o->_hierarchicalColor retain];
        c->_paletteColors = [o->_paletteColors copy];
    }
    c->_monochrome |= o->_monochrome;
    c->_hierarchical |= o->_hierarchical;
    c->_multicolor |= o->_multicolor;
    if (o->_variableValueMode)
        c->_variableValueMode = o->_variableValueMode;
    if (o->_colorRenderingMode)
        c->_colorRenderingMode = o->_colorRenderingMode;
    return c;
}

- (BOOL)isEqual:(id)other
{
    if (other == self)
        return YES;
    if (![other isKindOfClass:[NSImageSymbolConfiguration class]])
        return NO;
    NSImageSymbolConfiguration *o = other;
    return _pointSize == o->_pointSize && _weight == o->_weight && _scale == o->_scale &&
           (_textStyle == o->_textStyle || [_textStyle isEqual:o->_textStyle]) &&
           (_hierarchicalColor == o->_hierarchicalColor || [_hierarchicalColor isEqual:o->_hierarchicalColor]) &&
           (_paletteColors == o->_paletteColors || [_paletteColors isEqual:o->_paletteColors]) && _monochrome == o->_monochrome &&
           _hierarchical == o->_hierarchical && _multicolor == o->_multicolor;
}

- (NSUInteger)hash { return (NSUInteger)(_pointSize * 31) ^ (NSUInteger)_scale ^ _textStyle.hash; }

- (void)encodeWithCoder:(NSCoder *)coder
{
    if (_hasPointSize)
        [coder encodeDouble:_pointSize forKey:@"NSPointSize"];
    if (_hasWeight)
        [coder encodeDouble:_weight forKey:@"NSWeight"];
    if (_hasScale)
        [coder encodeInteger:_scale forKey:@"NSScale"];
    [coder encodeObject:_textStyle forKey:@"NSTextStyle"];
    [coder encodeObject:_hierarchicalColor forKey:@"NSHierarchicalColor"];
    [coder encodeObject:_paletteColors forKey:@"NSPaletteColors"];
    [coder encodeBool:_monochrome forKey:@"NSPrefersMonochrome"];
    [coder encodeBool:_hierarchical forKey:@"NSPrefersHierarchical"];
    [coder encodeBool:_multicolor forKey:@"NSPrefersMulticolor"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if (!(self = [super init]))
        return nil;
    if ((_hasPointSize = [coder containsValueForKey:@"NSPointSize"]))
        _pointSize = [coder decodeDoubleForKey:@"NSPointSize"];
    if ((_hasWeight = [coder containsValueForKey:@"NSWeight"]))
        _weight = [coder decodeDoubleForKey:@"NSWeight"];
    if ((_hasScale = [coder containsValueForKey:@"NSScale"]))
        _scale = [coder decodeIntegerForKey:@"NSScale"];
    _textStyle = [[coder decodeObjectOfClass:[NSString class] forKey:@"NSTextStyle"] copy];
    _hierarchicalColor = [[coder decodeObjectOfClass:[NSColor class] forKey:@"NSHierarchicalColor"] retain];
    _paletteColors = [[coder decodeObjectOfClasses:[NSSet setWithObjects:[NSArray class], [NSColor class], nil] forKey:@"NSPaletteColors"]
        copy];
    _monochrome = [coder decodeBoolForKey:@"NSPrefersMonochrome"];
    _hierarchical = [coder decodeBoolForKey:@"NSPrefersHierarchical"];
    _multicolor = [coder decodeBoolForKey:@"NSPrefersMulticolor"];
    return self;
}

@end
