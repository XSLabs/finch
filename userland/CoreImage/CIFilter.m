/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CIFilter: a named filter, its inputs set by key-value coding (or the typed
 * properties of CIFilterBuiltins.h: "radius" is inputRadius, as a float), its
 * attributes, and its outputImage. Finch's built-in filters and their inputs are in
 * CIFilterTable.m; each instance's class is named after its filter, as Apple's are.
 * Apps' own CIFilter subclasses work as on macOS (they override outputImage).
 */
#import "CoreImage_Finch.h"
#include "CIFilterBuiltins.inc"
#import <CoreImage/CIFilterBuiltins.h>
#include <objc/runtime.h>
#include <string.h>

static NSMutableDictionary *registered; /* name -> constructor, from +registerFilterName: */

/* Keep SDK protocol descriptions available for typed property dispatch.
   Factories still resolve only to Finch filter descriptions. */
static Protocol *builtinProtocols[160];
static size_t builtinProtocolCount;

static Protocol *
builtin_protocol(NSString *name)
{
    for (size_t i = 0; i < builtinProtocolCount; i++)
        if (builtinProtocols[i] && [name isEqualToString:@(protocol_getName(builtinProtocols[i]))])
            return builtinProtocols[i];
    return nil;
}

static Protocol *
protocol_for_filter_name(NSString *name)
{
    if ([name hasPrefix:@"CIPhotoEffect"])
        return builtin_protocol(@"CIPhotoEffect");
    if ([name hasPrefix:@"CIConvolution"])
        return builtin_protocol(@"CIConvolution");
    if ([name isEqualToString:@"CIMedianFilter"])
        return builtin_protocol(@"CIMedian");
    if ([name isEqualToString:@"CIStraightenFilter"])
        return builtin_protocol(@"CIStraighten");
    if ([name isEqualToString:@"CIAreaAlphaWeightedHistogram"])
        return builtin_protocol(@"CIAreaHistogram");
    if ([name hasPrefix:@"CIBlendWith"])
        return builtin_protocol(@"CIBlendWithMask");
    return builtin_protocol(name);
}

@implementation CIFilter {
    NSMutableDictionary *_values;
    const CIFilterDescription *_desc;
    NSString *_name;
    BOOL _enabled;
}

+ (void)load
{
#define CI_PROTOCOL_REF(name) @protocol(name),
    Protocol *protocols[] = {CI_FILTER_BUILTIN_PROTOCOLS(CI_PROTOCOL_REF)};
#undef CI_PROTOCOL_REF
    builtinProtocolCount = sizeof protocols / sizeof protocols[0];
    memcpy(builtinProtocols, protocols, sizeof protocols);
}

+ (BOOL)supportsSecureCoding { return YES; }

static id
value_from_string(const char *s)
{
    if (!s)
        return nil;
    NSString *rest = [NSString stringWithUTF8String:s + 1];
    switch (s[0]) {
    case 'V':
        return [CIVector vectorWithString:rest];
    case 'C':
        return [CIColor colorWithString:rest];
    case 'T': {
        double v[6] = {1, 0, 0, 1, 0, 0};
        sscanf(s + 1, "%lf %lf %lf %lf %lf %lf", &v[0], &v[1], &v[2], &v[3], &v[4], &v[5]);
        CGAffineTransform t = CGAffineTransformMake(v[0], v[1], v[2], v[3], v[4], v[5]);
        return [NSValue valueWithBytes:&t objCType:@encode(CGAffineTransform)];
    }
    case 'A': { /* NSAffineTransform, as Apple's CIAffineTransform takes */
        NSAffineTransform *t = [NSAffineTransform transform];
        return t;
    }
    case 'S':
        return rest;
    case 'D': { /* the public 2 x 2 x 2 identity cube used by CIColorCube */
        float cube[2 * 2 * 2 * 4];
        size_t at = 0;
        for (int b = 0; b < 2; b++)
            for (int g = 0; g < 2; g++)
                for (int r = 0; r < 2; r++) {
                    cube[at++] = (float)r;
                    cube[at++] = (float)g;
                    cube[at++] = (float)b;
                    cube[at++] = 1;
                }
        return [NSData dataWithBytes:cube length:sizeof cube];
    }
    case 'G':
        return [(id)CGColorSpaceCreateWithName(kCGColorSpaceSRGB) autorelease];
    }
    return nil;
}

/* The class each filter's instances have ("CIGaussianBlur", ...), made once. */
static Class
class_for(NSString *name)
{
    static NSMutableDictionary *classes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ classes = [NSMutableDictionary new]; });
    @synchronized(classes) {
        Class c = classes[name];
        if (c)
            return c;
        c = NSClassFromString(name);
        if (!c || ![c isSubclassOfClass:[CIFilter class]]) {
            c = objc_allocateClassPair([CIFilter class], name.UTF8String, 0);
            if (c)
                objc_registerClassPair(c);
            else
                c = [CIFilter class];
        }
        classes[name] = c;
        return c;
    }
}

+ (CIFilter *)filterWithName:(NSString *)name
{
    if (!name)
        return nil;
    id constructor = registered[name];
    if (constructor)
        return [constructor filterWithName:name];
    const CIFilterDescription *d = ci_filter_description(name);
    if (!d)
        return nil;
    CIFilter *f = [[[class_for(name) alloc] init] autorelease];
    f->_desc = d;
    [f->_name release];
    f->_name = [name copy];
    [f setDefaults];
    return f;
}

+ (CIFilter *)filterWithName:(NSString *)name keysAndValues:(id)key0, ...
{
    CIFilter *f = [self filterWithName:name];
    va_list ap;
    va_start(ap, key0);
    for (id key = key0; key; key = va_arg(ap, id)) {
        id value = va_arg(ap, id);
        [f setValue:value forKey:key];
    }
    va_end(ap);
    return f;
}

+ (CIFilter *)filterWithName:(NSString *)name withInputParameters:(NSDictionary *)params
{
    CIFilter *f = [self filterWithName:name];
    [f setValuesForKeysWithDictionary:params ?: @{}];
    return f;
}

+ (CIFilter *)filterWithImageURL:(NSURL *)url options:(NSDictionary *)options { return nil; } /* RAW: none yet */
+ (CIFilter *)filterWithImageData:(NSData *)data options:(NSDictionary *)options { return nil; }
+ (CIFilter *)filterWithCVPixelBuffer:(CVPixelBufferRef)pixelBuffer properties:(NSDictionary *)properties options:(NSDictionary *)options
{
    return nil;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _values = [NSMutableDictionary new];
        _enabled = YES;
        /* an app's own subclass is named after itself */
        if (!_desc)
            _name = [NSStringFromClass([self class]) copy];
    }
    return self;
}

- (void)dealloc
{
    [_values release];
    [_name release];
    [super dealloc];
}

- (const CIFilterDescription *)_finchDescription { return _desc; }

- (NSString *)name { return _name; }
- (void)setName:(NSString *)name
{
    [_name autorelease];
    _name = [name copy];
}
- (BOOL)isEnabled { return _enabled; }
- (void)setEnabled:(BOOL)enabled { _enabled = enabled; }

- (NSArray<NSString *> *)inputKeys
{
    NSMutableArray *keys = [NSMutableArray array];
    if (_desc) {
        for (size_t i = 0; i < sizeof _desc->inputs / sizeof _desc->inputs[0] && _desc->inputs[i].key; i++)
            [keys addObject:@(_desc->inputs[i].key)];
        return keys;
    }
    /* a subclass: its input... properties */
    for (Class c = [self class]; c && c != [CIFilter class]; c = class_getSuperclass(c)) {
        unsigned n = 0;
        objc_property_t *props = class_copyPropertyList(c, &n);
        for (unsigned i = 0; i < n; i++) {
            NSString *p = @(property_getName(props[i]));
            if ([p hasPrefix:@"input"] && ![keys containsObject:p])
                [keys addObject:p];
        }
        free(props);
        Ivar *ivars = class_copyIvarList(c, &n);
        for (unsigned i = 0; i < n; i++) {
            NSString *p = @(ivar_getName(ivars[i]));
            if ([p hasPrefix:@"input"] && ![keys containsObject:p])
                [keys addObject:p];
        }
        free(ivars);
    }
    return keys;
}

- (NSArray<NSString *> *)outputKeys
{
    if (_desc && _desc->outputs[0]) {
        NSMutableArray *keys = [NSMutableArray array];
        for (int i = 0; i < 3 && _desc->outputs[i]; i++)
            [keys addObject:@(_desc->outputs[i])];
        return keys;
    }
    return @[ kCIOutputImageKey ];
}

static const CIFilterInput *
input_named(const CIFilterDescription *d, NSString *key)
{
    if (!d)
        return NULL;
    for (size_t i = 0; i < sizeof d->inputs / sizeof d->inputs[0] && d->inputs[i].key; i++)
        if ([key isEqualToString:@(d->inputs[i].key)])
            return &d->inputs[i];
    return NULL;
}

static id
default_value(const CIFilterInput *in)
{
    if (in->defString)
        return value_from_string(in->defString);
    if (in->flags & CI_DEF)
        return @(in->def);
    return nil;
}

- (void)setDefaults
{
    if (!_desc)
        return;
    for (size_t i = 0; i < sizeof _desc->inputs / sizeof _desc->inputs[0] && _desc->inputs[i].key; i++) {
        id v = default_value(&_desc->inputs[i]);
        NSString *key = @(_desc->inputs[i].key);
        if (v)
            _values[key] = v;
        else
            [_values removeObjectForKey:key];
    }
}

- (void)setValue:(id)value forKey:(NSString *)key
{
    if (_desc && input_named(_desc, key)) {
        if (value)
            _values[key] = value;
        else
            [_values removeObjectForKey:key];
        return;
    }
    if (!_desc && [key hasPrefix:@"input"]) {
        /* a subclass's own ivars and properties take it the usual way */
        @try {
            [super setValue:value forKey:key];
        } @catch (NSException *e) {
            if (value)
                _values[key] = value;
            else
                [_values removeObjectForKey:key];
        }
        return;
    }
    [super setValue:value forKey:key];
}

- (id)valueForKey:(NSString *)key
{
    if ([key isEqualToString:kCIOutputImageKey])
        return [self outputImage];
    if (_desc && input_named(_desc, key))
        return _values[key];
    if (!_desc && [key hasPrefix:@"input"]) {
        @try {
            return [super valueForKey:key];
        } @catch (NSException *e) {
            return _values[key];
        }
    }
    return [super valueForKey:key];
}

- (void)setValue:(id)value forUndefinedKey:(NSString *)key
{
    if (value)
        _values[key] = value;
    else
        [_values removeObjectForKey:key];
}

- (id)valueForUndefinedKey:(NSString *)key { return _values[key]; }

- (CIImage *)outputImage
{
    if (_desc && _desc->output)
        return _desc->output(self);
    return nil;
}

- (NSDictionary<NSString *, id> *)attributes
{
    NSMutableDictionary *a = [NSMutableDictionary dictionary];
    a[kCIAttributeFilterName] = _name ?: @"";
    if (!_desc)
        return [[self class] respondsToSelector:@selector(customAttributes)]
                   ? ({
                         NSMutableDictionary *m = [[[(id)[self class] customAttributes] mutableCopy] autorelease];
                         m[kCIAttributeFilterName] = _name;
                         m;
                     })
                   : a;
    a[kCIAttributeFilterDisplayName] = @(_desc->displayName);
    NSMutableArray *cats = [NSMutableArray array];
    for (int i = 0; i < 10 && _desc->categories[i]; i++)
        [cats addObject:@(_desc->categories[i])];
    a[kCIAttributeFilterCategories] = cats;
    if (_desc->availableMac)
        a[kCIAttributeFilterAvailable_Mac] = @(_desc->availableMac);
    if (_desc->availableIOS)
        a[kCIAttributeFilterAvailable_iOS] = @(_desc->availableIOS);
    a[kCIAttributeReferenceDocumentation] = [NSURL
        URLWithString:[NSString stringWithFormat:@"http://developer.apple.com/library/mac/documentation/GraphicsImaging/"
                                                 @"Reference/CoreImageFilterReference/index.html#//apple_ref/doc/filter/ci/%@",
                                                 _name]];
    for (size_t i = 0; i < sizeof _desc->inputs / sizeof _desc->inputs[0] && _desc->inputs[i].key; i++) {
        const CIFilterInput *in = &_desc->inputs[i];
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        if (in->cls)
            d[kCIAttributeClass] = @(in->cls);
        if (in->type)
            d[kCIAttributeType] = @(in->type);
        if (in->displayName)
            d[kCIAttributeDisplayName] = @(in->displayName);
        id def = default_value(in);
        if (def)
            d[kCIAttributeDefault] = def;
        if (in->flags & CI_MIN)
            d[kCIAttributeMin] = @(in->min);
        if (in->flags & CI_MAX)
            d[kCIAttributeMax] = @(in->max);
        if (in->flags & CI_SMIN)
            d[kCIAttributeSliderMin] = @(in->sliderMin);
        if (in->flags & CI_SMAX)
            d[kCIAttributeSliderMax] = @(in->sliderMax);
        if (in->flags & CI_IDENTITY)
            d[kCIAttributeIdentity] = @(in->identity);
        else if (in->identityString)
            d[kCIAttributeIdentity] = value_from_string(in->identityString);
        a[@(in->key)] = d;
    }
    return a;
}

- (NSString *)description
{
    NSMutableString *s = [NSMutableString stringWithFormat:@"<%@: %p", NSStringFromClass([self class]), self];
    for (NSString *k in [self inputKeys]) {
        id v = _values[k];
        [s appendFormat:@"\n    %@=%@", k, v ?: @"nil"];
    }
    [s appendString:@">"];
    return s;
}

- (id)copyWithZone:(NSZone *)zone
{
    CIFilter *f = [[[self class] allocWithZone:zone] init];
    f->_desc = _desc;
    [f->_name release];
    f->_name = [_name copy];
    [f->_values setDictionary:_values];
    f->_enabled = _enabled;
    return f;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_name forKey:@"CIFilterName"];
    NSMutableDictionary *plain = [NSMutableDictionary dictionary];
    for (NSString *k in _values)
        if ([_values[k] conformsToProtocol:@protocol(NSSecureCoding)])
            plain[k] = _values[k];
    [coder encodeObject:plain forKey:@"CIFilterInputs"];
    [coder encodeBool:_enabled forKey:@"CIFilterEnabled"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSString *name = [coder decodeObjectOfClass:[NSString class] forKey:@"CIFilterName"];
    CIFilter *f = [[CIFilter filterWithName:name] retain];
    [self release];
    if (!f)
        return nil;
    NSSet *classes = [NSSet setWithObjects:[NSDictionary class], [NSString class], [NSNumber class], [CIVector class],
                                           [CIColor class], [CIImage class], [NSValue class], [NSData class], nil];
    NSDictionary *inputs = [coder decodeObjectOfClasses:classes forKey:@"CIFilterInputs"];
    [f setValuesForKeysWithDictionary:inputs ?: @{}];
    f->_enabled = [coder containsValueForKey:@"CIFilterEnabled"] ? [coder decodeBoolForKey:@"CIFilterEnabled"] : YES;
    return f;
}

/* --- the filter list --- */

+ (NSArray<NSString *> *)filterNamesInCategory:(NSString *)category
{
    return [self filterNamesInCategories:category ? @[ category ] : nil];
}

+ (NSArray<NSString *> *)filterNamesInCategories:(NSArray<NSString *> *)categories
{
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *name in ci_filter_names()) {
        const CIFilterDescription *d = ci_filter_description(name);
        BOOL all = YES;
        for (NSString *want in categories) {
            BOOL has = NO;
            for (int i = 0; i < 10 && d->categories[i]; i++)
                if ([want isEqualToString:@(d->categories[i])])
                    has = YES;
            all = all && has;
        }
        if (all)
            [out addObject:name];
    }
    for (NSString *name in registered) {
        NSArray *cats = [registered[name] respondsToSelector:@selector(customAttributes)] ? nil : nil;
        (void)cats;
        if (!categories.count && ![out containsObject:name])
            [out addObject:name];
    }
    return out;
}

+ (void)registerFilterName:(NSString *)name constructor:(id<CIFilterConstructor>)anObject classAttributes:(NSDictionary *)attributes
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{ registered = [NSMutableDictionary new]; });
    if (name && anObject)
        registered[name] = anObject;
}

+ (NSString *)localizedNameForFilterName:(NSString *)filterName
{
    const CIFilterDescription *d = ci_filter_description(filterName);
    return d ? @(d->displayName) : nil;
}

+ (NSString *)localizedNameForCategory:(NSString *)category
{
    NSString *s = [category hasPrefix:@"CICategory"] ? [category substringFromIndex:10] : category;
    /* "ColorAdjustment" -> "Color Adjustment" */
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (i && [[NSCharacterSet uppercaseLetterCharacterSet] characterIsMember:c] &&
            ![[NSCharacterSet uppercaseLetterCharacterSet] characterIsMember:[s characterAtIndex:i - 1]])
            [out appendString:@" "];
        [out appendFormat:@"%C", c];
    }
    return out;
}

+ (NSString *)localizedDescriptionForFilterName:(NSString *)filterName { return nil; }
+ (NSURL *)localizedReferenceDocumentationForFilterName:(NSString *)filterName { return nil; }

/* XMP serialization of filter chains: none yet. */
+ (NSData *)serializedXMPFromFilters:(NSArray<CIFilter *> *)filters inputImageExtent:(CGRect)extent { return nil; }
+ (NSArray<CIFilter *> *)filterArrayFromSerializedXMP:(NSData *)xmpData inputImageExtent:(CGRect)extent error:(NSError **)outError
{
    if (outError)
        *outError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:nil];
    return @[];
}

/* --- CIFilterBuiltins: +gaussianBlurFilter, filter.radius, ... --- */

static NSString *
filter_for_selector(SEL sel)
{
    NSString *s = NSStringFromSelector(sel);
    if ([s containsString:@":"] || !s.length)
        return nil;
    NSString *base = [s hasSuffix:@"Filter"] ? [s substringToIndex:s.length - 6] : s;
    NSMutableArray *candidates = [NSMutableArray arrayWithObject:[@"CI" stringByAppendingString:base]];
    if ([s hasSuffix:@"Filter"])
        [candidates addObject:[[@"CI" stringByAppendingString:base] stringByAppendingString:@"Filter"]];
    else if ([s isEqualToString:@"CMYKHalftone"])
        [candidates addObject:@"CICMYKHalftone"];
    for (NSString *candidate in candidates)
        for (NSString *name in ci_filter_names())
            if ([name caseInsensitiveCompare:candidate] == NSOrderedSame)
                return name;
    return nil;
}

static id
builtin_factory(id self, SEL _cmd)
{
    return [CIFilter filterWithName:filter_for_selector(_cmd)];
}

+ (BOOL)resolveClassMethod:(SEL)sel
{
    if (filter_for_selector(sel)) {
        class_addMethod(object_getClass([CIFilter class]), sel, (IMP)builtin_factory, "@@:");
        return YES;
    }
    return [super resolveClassMethod:sel];
}

/* "radius" -> inputRadius, "inputImage" stays. */
static const CIFilterInput *
input_for_property(const CIFilterDescription *d, NSString *prop)
{
    if (!d || !prop.length)
        return NULL;
    const CIFilterInput *in = input_named(d, prop);
    if (in)
        return in;
    NSString *key = [NSString stringWithFormat:@"input%@%@", [[prop substringToIndex:1] uppercaseString], [prop substringFromIndex:1]];
    in = input_named(d, key);
    if (in)
        return in;
    /* "inputRVector" from "RVector", "inputEV" from "EV" */
    return input_named(d, [@"input" stringByAppendingString:prop]);
}

enum { P_OBJECT, P_FLOAT, P_DOUBLE, P_BOOL, P_INTEGER, P_POINT, P_RECT, P_SIZE, P_TRANSFORM, P_COLORSPACE };

static int
property_kind(const char *type)
{
    if (!type || !*type)
        return P_OBJECT;
    while (strchr("rnNoORV", *type))
        type++;
    if (*type == '@' || *type == '#')
        return P_OBJECT;
    if (*type == '^')
        return strstr(type, "CGColorSpace") ? P_COLORSPACE : P_OBJECT;
    if (*type == 'f')
        return P_FLOAT;
    if (*type == 'd')
        return P_DOUBLE;
    if (*type == 'B')
        return P_BOOL;
    if (strchr("qQ", *type))
        return P_INTEGER;
    if (strchr("cCsSiIlL", *type))
        return P_INTEGER;
    if (*type == '{') {
        if (strstr(type, "CGRect"))
            return P_RECT;
        if (strstr(type, "CGSize"))
            return P_SIZE;
        if (strstr(type, "CGPoint"))
            return P_POINT;
        if (strstr(type, "CGAffineTransform"))
            return P_TRANSFORM;
    }
    return P_OBJECT;
}

static NSString *
property_from_selector(SEL sel, BOOL *setter)
{
    NSString *s = NSStringFromSelector(sel);
    *setter = [s hasPrefix:@"set"] && [s hasSuffix:@":"] && s.length > 4;
    if (*setter) {
        s = [s substringWithRange:NSMakeRange(3, s.length - 4)];
        return [[[s substringToIndex:1] lowercaseString] stringByAppendingString:[s substringFromIndex:1]];
    }
    return [s containsString:@":"] ? nil : s;
}

static const CIFilterInput *
input_for_selector(CIFilter *f, SEL sel, BOOL *setter)
{
    NSString *prop = property_from_selector(sel, setter);
    const CIFilterInput *in = prop ? input_for_property(f->_desc, prop) : NULL;
    if (!in && *setter && prop.length > 1) /* setRVector: -> "RVector" */
        in = input_for_property(f->_desc, [[[prop substringToIndex:1] uppercaseString] stringByAppendingString:[prop substringFromIndex:1]]);
    return in;
}

static objc_property_t
property_in_protocol(Protocol *protocol, const char *name)
{
    if (!protocol)
        return NULL;
    objc_property_t property = protocol_getProperty(protocol, name, YES, YES);
    if (!property)
        property = protocol_getProperty(protocol, name, NO, YES);
    if (property)
        return property;
    unsigned count = 0;
    Protocol *__unsafe_unretained *adopted = protocol_copyProtocolList(protocol, &count);
    for (unsigned i = 0; i < count && !property; i++)
        property = property_in_protocol(adopted[i], name);
    free(adopted);
    return property;
}

static NSString *
key_for(CIFilter *self, SEL _cmd)
{
    BOOL setter;
    const CIFilterInput *in = input_for_selector(self, _cmd, &setter);
    return in ? @(in->key) : nil;
}

static id get_object(CIFilter *self, SEL _cmd) { return self->_values[key_for(self, _cmd)]; }
static float get_float(CIFilter *self, SEL _cmd) { return [self->_values[key_for(self, _cmd)] floatValue]; }
static double get_double(CIFilter *self, SEL _cmd) { return [self->_values[key_for(self, _cmd)] doubleValue]; }
static BOOL get_bool(CIFilter *self, SEL _cmd) { return [self->_values[key_for(self, _cmd)] boolValue]; }
static NSInteger get_integer(CIFilter *self, SEL _cmd) { return [self->_values[key_for(self, _cmd)] integerValue]; }
static CGPoint get_point(CIFilter *self, SEL _cmd) { return [self->_values[key_for(self, _cmd)] CGPointValue]; }
static CGRect get_rect(CIFilter *self, SEL _cmd) { return [self->_values[key_for(self, _cmd)] CGRectValue]; }
static CGSize
get_size(CIFilter *self, SEL _cmd)
{
    CIVector *v = self->_values[key_for(self, _cmd)];
    return CGSizeMake([v valueAtIndex:0], [v valueAtIndex:1]);
}
static CGAffineTransform
get_transform(CIFilter *self, SEL _cmd)
{
    CGAffineTransform t = CGAffineTransformIdentity;
    id v = self->_values[key_for(self, _cmd)];
    if ([v isKindOfClass:[NSAffineTransform class]]) {
        NSAffineTransformStruct s = [v transformStruct];
        return CGAffineTransformMake(s.m11, s.m12, s.m21, s.m22, s.tX, s.tY);
    }
    [v getValue:&t];
    return t;
}
static void set_object(CIFilter *self, SEL _cmd, id v) { [self setValue:v forKey:key_for(self, _cmd)]; }
static void set_float(CIFilter *self, SEL _cmd, float v) { [self setValue:@(v) forKey:key_for(self, _cmd)]; }
static void set_double(CIFilter *self, SEL _cmd, double v) { [self setValue:@(v) forKey:key_for(self, _cmd)]; }
static void set_bool(CIFilter *self, SEL _cmd, BOOL v) { [self setValue:@(v) forKey:key_for(self, _cmd)]; }
static void set_integer(CIFilter *self, SEL _cmd, NSInteger v) { [self setValue:@(v) forKey:key_for(self, _cmd)]; }
static void set_point(CIFilter *self, SEL _cmd, CGPoint v) { [self setValue:[CIVector vectorWithCGPoint:v] forKey:key_for(self, _cmd)]; }
static void set_rect(CIFilter *self, SEL _cmd, CGRect v) { [self setValue:[CIVector vectorWithCGRect:v] forKey:key_for(self, _cmd)]; }
static void set_size(CIFilter *self, SEL _cmd, CGSize v) { [self setValue:[CIVector vectorWithX:v.width Y:v.height] forKey:key_for(self, _cmd)]; }
static void
set_transform(CIFilter *self, SEL _cmd, CGAffineTransform v)
{
    [self setValue:[NSValue valueWithBytes:&v objCType:@encode(CGAffineTransform)] forKey:key_for(self, _cmd)];
}
static CGColorSpaceRef
get_colorspace(CIFilter *self, SEL _cmd)
{
    id value = self->_values[key_for(self, _cmd)];
    return [value isKindOfClass:[NSValue class]] ? [value pointerValue] : (CGColorSpaceRef)value;
}
static void
set_colorspace(CIFilter *self, SEL _cmd, CGColorSpaceRef value)
{
    [self setValue:(id)value forKey:key_for(self, _cmd)];
}

/* A filter's typed accessors, added to its class the first time they're called. */
+ (BOOL)resolveInstanceMethod:(SEL)sel
{
    NSString *name = NSStringFromClass(self);
    const CIFilterDescription *d = ci_filter_description(name);
    if (d) {
        BOOL setter;
        NSString *prop = property_from_selector(sel, &setter);
        const CIFilterInput *in = prop ? input_for_property(d, prop) : NULL;
        if (!in && setter && prop.length > 1)
            in = input_for_property(d, [[[prop substringToIndex:1] uppercaseString] stringByAppendingString:[prop substringFromIndex:1]]);
        if (in) {
            Protocol *protocol = protocol_for_filter_name(name);
            objc_property_t property = property_in_protocol(protocol, prop.UTF8String);
            char *type = property ? property_copyAttributeValue(property, "T") : NULL;
            int k = property_kind(type);
            IMP get[] = {(IMP)get_object, (IMP)get_float, (IMP)get_double, (IMP)get_bool, (IMP)get_integer,
                         (IMP)get_point, (IMP)get_rect, (IMP)get_size, (IMP)get_transform, (IMP)get_colorspace};
            IMP set[] = {(IMP)set_object, (IMP)set_float, (IMP)set_double, (IMP)set_bool, (IMP)set_integer,
                         (IMP)set_point, (IMP)set_rect, (IMP)set_size, (IMP)set_transform, (IMP)set_colorspace};
            char getter[192], setterType[196];
            const char *encoding = type ?: "@";
            snprintf(getter, sizeof getter, "%s@:", encoding);
            snprintf(setterType, sizeof setterType, "v@:%s", encoding);
            class_addMethod(self, sel, setter ? set[k] : get[k], setter ? setterType : getter);
            free(type);
            return YES;
        }
    }
    return [super resolveInstanceMethod:sel];
}

@end

/* Apple's CIFilter category for its private API's apps sometimes call. */
@implementation CIFilter (FinchCompatibility)
- (CIImage *)apply:(CIKernel *)k arguments:(NSArray *)args options:(NSDictionary *)dict { return nil; }
@end
