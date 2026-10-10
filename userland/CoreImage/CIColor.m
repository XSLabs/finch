/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CIColor: a color's components in a color space (sRGB unless given), and CIVector:
 * a short vector of CGFloats, as Apple's. Both read and write Apple's string forms
 * ("0.2 0.4 0.6 0.8", "[1 2.5 3]") and archive with its keys.
 */
#import "CoreImage_Finch.h"

@implementation CIColor {
    CGFloat _c[4];
    size_t _n; /* components, alpha included */
    CGColorSpaceRef _space;
}

+ (BOOL)supportsSecureCoding { return YES; }

static CGColorSpaceRef
srgb(void)
{
    static CGColorSpaceRef s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = CGColorSpaceCreateWithName(kCGColorSpaceSRGB); });
    return s;
}

- (instancetype)_finchInitWithComponents:(const CGFloat *)c count:(size_t)n space:(CGColorSpaceRef)space
{
    if (!(self = [super init]))
        return nil;
    if (n > 4)
        n = 4;
    for (size_t i = 0; i < n; i++)
        _c[i] = c[i];
    _n = n;
    _space = CGColorSpaceRetain(space ?: srgb());
    return self;
}

- (instancetype)initWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a
{
    CGFloat c[4] = {r, g, b, a};
    return [self _finchInitWithComponents:c count:4 space:NULL];
}

- (instancetype)initWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b
{
    return [self initWithRed:r green:g blue:b alpha:1];
}

- (nullable instancetype)initWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a colorSpace:(CGColorSpaceRef)colorSpace
{
    if (colorSpace && CGColorSpaceGetModel(colorSpace) != kCGColorSpaceModelRGB) {
        [self release];
        return nil;
    }
    CGFloat c[4] = {r, g, b, a};
    return [self _finchInitWithComponents:c count:4 space:colorSpace];
}

- (nullable instancetype)initWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b colorSpace:(CGColorSpaceRef)colorSpace
{
    return [self initWithRed:r green:g blue:b alpha:1 colorSpace:colorSpace];
}

/* A CGColor's components, as RGB: gray is spread over red, green and blue. */
- (instancetype)initWithCGColor:(CGColorRef)color
{
    if (!color)
        return [self initWithRed:0 green:0 blue:0 alpha:0];
    CGColorSpaceRef space = CGColorGetColorSpace(color);
    const CGFloat *c = CGColorGetComponents(color);
    size_t n = CGColorGetNumberOfComponents(color);
    if (space && CGColorSpaceGetModel(space) == kCGColorSpaceModelRGB && n >= 4)
        return [self _finchInitWithComponents:c count:4 space:space];
    /* any other model: what CoreGraphics makes of it in sRGB */
    CGColorRef converted = CGColorCreateCopyByMatchingToColorSpace(srgb(), kCGRenderingIntentDefault, color, NULL);
    if (converted) {
        self = [self _finchInitWithComponents:CGColorGetComponents(converted) count:4 space:NULL];
        CGColorRelease(converted);
        return self;
    }
    return [self initWithRed:0 green:0 blue:0 alpha:CGColorGetAlpha(color)];
}

+ (instancetype)colorWithCGColor:(CGColorRef)color { return [[[self alloc] initWithCGColor:color] autorelease]; }
+ (instancetype)colorWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a
{
    return [[[self alloc] initWithRed:r green:g blue:b alpha:a] autorelease];
}
+ (instancetype)colorWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b
{
    return [[[self alloc] initWithRed:r green:g blue:b] autorelease];
}
+ (nullable instancetype)colorWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a colorSpace:(CGColorSpaceRef)colorSpace
{
    return [[[self alloc] initWithRed:r green:g blue:b alpha:a colorSpace:colorSpace] autorelease];
}
+ (nullable instancetype)colorWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b colorSpace:(CGColorSpaceRef)colorSpace
{
    return [[[self alloc] initWithRed:r green:g blue:b colorSpace:colorSpace] autorelease];
}

/* "r g b" or "r g b a" (a missing alpha is 1). */
+ (instancetype)colorWithString:(NSString *)representation
{
    CGFloat c[4] = {0, 0, 0, 1};
    NSScanner *s = [NSScanner scannerWithString:representation ?: @""];
    int n = 0;
    double v;
    while (n < 4 && [s scanDouble:&v])
        c[n++] = v;
    return [self colorWithRed:c[0] green:c[1] blue:c[2] alpha:c[3]];
}

#define CONSTANT_COLOR(name, r, g, b, a)                                                                       \
    +(CIColor *)name                                                                                           \
    {                                                                                                          \
        static CIColor *c;                                                                                     \
        static dispatch_once_t once;                                                                           \
        dispatch_once(&once, ^{ c = [[CIColor alloc] initWithRed:r green:g blue:b alpha:a]; });                \
        return c;                                                                                              \
    }
CONSTANT_COLOR(blackColor, 0, 0, 0, 1)
CONSTANT_COLOR(whiteColor, 1, 1, 1, 1)
CONSTANT_COLOR(grayColor, 0.5, 0.5, 0.5, 1)
CONSTANT_COLOR(redColor, 1, 0, 0, 1)
CONSTANT_COLOR(greenColor, 0, 1, 0, 1)
CONSTANT_COLOR(blueColor, 0, 0, 1, 1)
CONSTANT_COLOR(cyanColor, 0, 1, 1, 1)
CONSTANT_COLOR(magentaColor, 1, 0, 1, 1)
CONSTANT_COLOR(yellowColor, 1, 1, 0, 1)
CONSTANT_COLOR(clearColor, 0, 0, 0, 0)

- (void)dealloc
{
    CGColorSpaceRelease(_space);
    [super dealloc];
}

- (size_t)numberOfComponents { return _n; }
- (const CGFloat *)components { return _c; }
- (CGFloat)red { return _c[0]; }
- (CGFloat)green { return _c[1]; }
- (CGFloat)blue { return _c[2]; }
- (CGFloat)alpha { return _n ? _c[_n - 1] : 1; }
- (CGColorSpaceRef)colorSpace { return _space; }

static NSString *
number(CGFloat v)
{
    return [NSString stringWithFormat:@"%g", (double)v];
}

- (NSString *)stringRepresentation
{
    NSMutableArray *parts = [NSMutableArray array];
    for (size_t i = 0; i < _n; i++)
        [parts addObject:number(_c[i])];
    return [parts componentsJoinedByString:@" "];
}

/* Apple's short name for the space: "sRGB", or the ICC description. */
static NSString *
space_name(CGColorSpaceRef space)
{
    CFStringRef name = CGColorSpaceCopyName(space);
    NSString *out = nil;
    if (name) {
        if (CFEqual(name, kCGColorSpaceSRGB))
            out = @"sRGB";
        else if (CFEqual(name, kCGColorSpaceExtendedSRGB))
            out = @"extended sRGB";
        else if (CFEqual(name, kCGColorSpaceLinearSRGB))
            out = @"sRGB linear";
        else if (CFEqual(name, kCGColorSpaceExtendedLinearSRGB))
            out = @"extended sRGB linear";
        else if (CFEqual(name, kCGColorSpaceDisplayP3))
            out = @"Display P3";
        else
            out = [(NSString *)name stringByReplacingOccurrencesOfString:@"kCGColorSpace" withString:@""];
        CFRelease(name);
    }
    return out ?: @"(unnamed)";
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<CIColor %p (%@) %@>", self, [self stringRepresentation], space_name(_space)];
}

- (BOOL)isEqual:(id)other
{
    if (other == self)
        return YES;
    if (![other isKindOfClass:[CIColor class]])
        return NO;
    CIColor *o = other;
    if (o->_n != _n || !CFEqual(o->_space, _space))
        return NO;
    for (size_t i = 0; i < _n; i++)
        if (o->_c[i] != _c[i])
            return NO;
    return YES;
}

- (NSUInteger)hash
{
    return (NSUInteger)(_c[0] * 255) ^ (NSUInteger)(_c[1] * 255) << 8 ^ (NSUInteger)(_c[2] * 255) << 16;
}

- (id)copyWithZone:(NSZone *)zone { return [self retain]; }

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:[self stringRepresentation] forKey:@"CIColorString"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSString *s = [coder decodeObjectOfClass:[NSString class] forKey:@"CIColorString"];
    CGFloat c[4] = {0, 0, 0, 1};
    NSScanner *scan = [NSScanner scannerWithString:s ?: @""];
    int n = 0;
    double v;
    while (n < 4 && [scan scanDouble:&v])
        c[n++] = v;
    return [self initWithRed:c[0] green:c[1] blue:c[2] alpha:c[3]];
}

/* The components converted to linear, premultiplied (CoreImage's working space). */
- (void)_finchWorkingComponents:(float *)out
{
    float a = (float)[self alpha];
    for (int i = 0; i < 3; i++)
        out[i] = ci_linear_from_srgb((float)_c[i]) * a;
    CFStringRef name = CGColorSpaceCopyName(_space);
    if (name && (CFEqual(name, kCGColorSpaceLinearSRGB) || CFEqual(name, kCGColorSpaceExtendedLinearSRGB) ||
                 CFEqual(name, kCGColorSpaceGenericRGBLinear)))
        for (int i = 0; i < 3; i++)
            out[i] = (float)_c[i] * a;
    if (name)
        CFRelease(name);
    out[3] = a;
}

@end

@implementation CIVector {
    CGFloat *_vals;
    size_t _vn;
    CGFloat _inline4[4];
}

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)initWithValues:(const CGFloat *)values count:(size_t)count
{
    if (!(self = [super init]))
        return nil;
    _vn = count;
    _vals = count <= 4 ? _inline4 : malloc(count * sizeof(CGFloat));
    for (size_t i = 0; i < count; i++)
        _vals[i] = values ? values[i] : 0;
    for (size_t i = count; i < 4 && _vals == _inline4; i++)
        _inline4[i] = 0;
    return self;
}

- (instancetype)initWithX:(CGFloat)x { return [self initWithValues:(CGFloat[]){x} count:1]; }
- (instancetype)initWithX:(CGFloat)x Y:(CGFloat)y { return [self initWithValues:(CGFloat[]){x, y} count:2]; }
- (instancetype)initWithX:(CGFloat)x Y:(CGFloat)y Z:(CGFloat)z { return [self initWithValues:(CGFloat[]){x, y, z} count:3]; }
- (instancetype)initWithX:(CGFloat)x Y:(CGFloat)y Z:(CGFloat)z W:(CGFloat)w
{
    return [self initWithValues:(CGFloat[]){x, y, z, w} count:4];
}
- (instancetype)initWithCGPoint:(CGPoint)p { return [self initWithX:p.x Y:p.y]; }
- (instancetype)initWithCGRect:(CGRect)r { return [self initWithX:r.origin.x Y:r.origin.y Z:r.size.width W:r.size.height]; }
- (instancetype)initWithCGAffineTransform:(CGAffineTransform)t
{
    return [self initWithValues:(CGFloat[]){t.a, t.b, t.c, t.d, t.tx, t.ty} count:6];
}

- (instancetype)initWithString:(NSString *)representation
{
    NSMutableData *d = [NSMutableData data];
    NSString *s = [[representation ?: @"" stringByReplacingOccurrencesOfString:@"[" withString:@" "]
        stringByReplacingOccurrencesOfString:@"]" withString:@" "];
    s = [s stringByReplacingOccurrencesOfString:@"," withString:@" "];
    NSScanner *scan = [NSScanner scannerWithString:s];
    double v;
    while ([scan scanDouble:&v]) {
        CGFloat f = v;
        [d appendBytes:&f length:sizeof f];
    }
    return [self initWithValues:d.bytes count:d.length / sizeof(CGFloat)];
}

+ (instancetype)vectorWithValues:(const CGFloat *)values count:(size_t)count
{
    return [[[self alloc] initWithValues:values count:count] autorelease];
}
+ (instancetype)vectorWithX:(CGFloat)x { return [[[self alloc] initWithX:x] autorelease]; }
+ (instancetype)vectorWithX:(CGFloat)x Y:(CGFloat)y { return [[[self alloc] initWithX:x Y:y] autorelease]; }
+ (instancetype)vectorWithX:(CGFloat)x Y:(CGFloat)y Z:(CGFloat)z { return [[[self alloc] initWithX:x Y:y Z:z] autorelease]; }
+ (instancetype)vectorWithX:(CGFloat)x Y:(CGFloat)y Z:(CGFloat)z W:(CGFloat)w
{
    return [[[self alloc] initWithX:x Y:y Z:z W:w] autorelease];
}
+ (instancetype)vectorWithCGPoint:(CGPoint)p { return [[[self alloc] initWithCGPoint:p] autorelease]; }
+ (instancetype)vectorWithCGRect:(CGRect)r { return [[[self alloc] initWithCGRect:r] autorelease]; }
+ (instancetype)vectorWithCGAffineTransform:(CGAffineTransform)t { return [[[self alloc] initWithCGAffineTransform:t] autorelease]; }
+ (instancetype)vectorWithString:(NSString *)representation { return [[[self alloc] initWithString:representation] autorelease]; }

- (void)dealloc
{
    if (_vals != _inline4)
        free(_vals);
    [super dealloc];
}

- (CGFloat)valueAtIndex:(size_t)index { return index < _vn ? _vals[index] : 0; }
- (size_t)count { return _vn; }
- (CGFloat)X { return [self valueAtIndex:0]; }
- (CGFloat)Y { return [self valueAtIndex:1]; }
- (CGFloat)Z { return [self valueAtIndex:2]; }
- (CGFloat)W { return [self valueAtIndex:3]; }
- (CGPoint)CGPointValue { return CGPointMake(self.X, self.Y); }
- (CGRect)CGRectValue { return CGRectMake(self.X, self.Y, self.Z, self.W); }
- (CGAffineTransform)CGAffineTransformValue
{
    return CGAffineTransformMake([self valueAtIndex:0], [self valueAtIndex:1], [self valueAtIndex:2], [self valueAtIndex:3],
                                 [self valueAtIndex:4], [self valueAtIndex:5]);
}

- (NSString *)stringRepresentation
{
    NSMutableArray *parts = [NSMutableArray array];
    for (size_t i = 0; i < _vn; i++)
        [parts addObject:number(_vals[i])];
    return [NSString stringWithFormat:@"[%@]", [parts componentsJoinedByString:@" "]];
}

- (NSString *)description { return [self stringRepresentation]; }

- (BOOL)isEqual:(id)other
{
    if (![other isKindOfClass:[CIVector class]])
        return NO;
    CIVector *o = other;
    if (o->_vn != _vn)
        return NO;
    for (size_t i = 0; i < _vn; i++)
        if (o->_vals[i] != _vals[i])
            return NO;
    return YES;
}

- (NSUInteger)hash { return _vn ? (NSUInteger)(_vals[0] * 31) ^ _vn : 0; }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:[self stringRepresentation] forKey:@"CIVectorString"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    return [self initWithString:[coder decodeObjectOfClass:[NSString class] forKey:@"CIVectorString"]];
}

@end
