/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Metal, Finch's. Finch drives no GPU yet, so there are no Metal devices: the system
 * default device is nil and the device list is empty, as on a Mac without a
 * Metal-capable GPU, and apps take the paths they have for that. Descriptors work as the
 * values they are (MTLDescriptors.m, with Apple's defaults): made, set, copied and
 * compared. Methods that need a device can't be reached without one.
 */
#import "Metal_Finch.h"
#import <objc/runtime.h>

/* --- devices: none --- */

id<MTLDevice>
MTLCreateSystemDefaultDevice(void)
{
    return nil;
}

NSArray<id<MTLDevice>> *
MTLCopyAllDevices(void)
{
    return [[NSArray alloc] init];
}

/* The observer: something to hand back to MTLRemoveDeviceObserver. No device comes or
   goes, so its handler is never called. */
@interface FinchMTLDeviceObserver : NSObject
@end
@implementation FinchMTLDeviceObserver
@end

NSArray<id<MTLDevice>> *
MTLCopyAllDevicesWithObserver(id<NSObject> __strong *observer, MTLDeviceNotificationHandler handler)
{
    if (observer)
        *observer = [[FinchMTLDeviceObserver alloc] init];
    return [[NSArray alloc] init];
}

void
MTLRemoveDeviceObserver(id<NSObject> observer)
{
}

id<MTLDevice>
MTLCopyDeviceForRegistryID(uint64_t registryID)
{
    return nil;
}

/* --- descriptors as values --- */

void
FinchMTLSetNew(id object, NSString *key, NSString *className)
{
    Class c = NSClassFromString(className);
    if (c && class_getProperty([object class], key.UTF8String))
        [object setValue:[[c alloc] init] forKey:key];
}

static const void *kElements = &kElements;

static NSMutableDictionary *
elements(id array)
{
    NSMutableDictionary *d = objc_getAssociatedObject(array, kElements);
    if (!d) {
        d = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(array, kElements, d, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return d;
}

id
FinchMTLArrayGet(id array, NSUInteger index, NSString *elementClass)
{
    NSMutableDictionary *d = elements(array);
    id e = d[@(index)];
    if (!e) {
        e = [[NSClassFromString(elementClass) alloc] init];
        if (e)
            d[@(index)] = e;
    }
    return e;
}

void
FinchMTLArraySet(id array, NSUInteger index, id element)
{
    NSMutableDictionary *d = elements(array);
    if (element)
        d[@(index)] = [element respondsToSelector:@selector(copyWithZone:)] ? [element copy] : element;
    else
        [d removeObjectForKey:@(index)];
}

void
FinchMTLArrayStore(id array, NSUInteger index, id element)
{
    NSMutableDictionary *d = elements(array);
    if (element)
        d[@(index)] = element;
    else
        [d removeObjectForKey:@(index)];
}

NSUInteger
FinchMTLArrayCount(id array)
{
    NSUInteger n = 0;
    for (NSNumber *i in objc_getAssociatedObject(array, kElements))
        n = MAX(n, i.unsignedIntegerValue + 1);
    return n;
}

/* Every property a descriptor class and its superclasses declare (up to NSObject). */
static NSArray<NSString *> *
property_names(Class cls)
{
    NSMutableArray *names = [NSMutableArray array];
    for (Class c = cls; c && c != [NSObject class]; c = class_getSuperclass(c)) {
        unsigned n = 0;
        objc_property_t *props = class_copyPropertyList(c, &n);
        for (unsigned i = 0; i < n; i++) {
            /* (only those with storage: synthesized here, an ivar named in the attributes) */
            char *ivar = property_copyAttributeValue(props[i], "V");
            if (ivar) {
                [names addObject:@(property_getName(props[i]))];
                free(ivar);
            }
        }
        free(props);
    }
    return names;
}

static BOOL
is_descriptor(id v)
{
    return [v isKindOfClass:[NSObject class]] && [NSStringFromClass([v class]) hasPrefix:@"MTL"] &&
           [v respondsToSelector:@selector(copyWithZone:)];
}

id
FinchMTLCopy(id object)
{
    id copy = [[[object class] alloc] init];
    for (NSString *k in property_names([object class])) {
        id v = [object valueForKey:k];
        if (is_descriptor(v) || [v isKindOfClass:[NSArray class]] || [v isKindOfClass:[NSString class]])
            v = [v copy];
        else if ([NSStringFromClass([v class]) hasSuffix:@"Array"] && [NSStringFromClass([v class]) hasPrefix:@"MTL"]) {
            /* a descriptor array: its elements, copied */
            id a = [[[v class] alloc] init];
            NSMutableDictionary *d = elements(a);
            [elements(v) enumerateKeysAndObjectsUsingBlock:^(id i, id e, BOOL *stop) {
              d[i] = is_descriptor(e) ? [e copy] : e;
            }];
            v = a;
        }
        [copy setValue:v forKey:k];
    }
    NSMutableDictionary *mine = objc_getAssociatedObject(object, kElements);
    if (mine) {
        NSMutableDictionary *d = elements(copy);
        [mine enumerateKeysAndObjectsUsingBlock:^(id i, id e, BOOL *stop) {
          d[i] = is_descriptor(e) ? [e copy] : e;
        }];
    }
    return copy;
}

BOOL
FinchMTLEqual(id object, id other)
{
    if (object == other)
        return YES;
    if (![other isKindOfClass:[object class]] || ![object isKindOfClass:[other class]])
        return NO;
    for (NSString *k in property_names([object class])) {
        id a = [object valueForKey:k], b = [other valueForKey:k];
        if (a != b && ![a isEqual:b])
            return NO;
    }
    NSDictionary *x = objc_getAssociatedObject(object, kElements), *y = objc_getAssociatedObject(other, kElements);
    return (x.count == 0 && y.count == 0) || [x isEqual:y];
}

NSUInteger
FinchMTLHash(id object)
{
    NSUInteger h = (NSUInteger)[object class];
    for (NSString *k in property_names([object class])) {
        id v = [object valueForKey:k];
        if ([v isKindOfClass:[NSNumber class]] || [v isKindOfClass:[NSString class]])
            h = h * 31 + [v hash];
    }
    return h;
}

/* --- names and sizes (private, as Apple's) --- */

#include "MTLTables.inc"
#define COUNT(a) (sizeof(a) / sizeof((a)[0]))

NSString *
MTLDataTypeString(MTLDataType type)
{
    for (size_t i = 0; i < COUNT(data_types); i++)
        if (data_types[i].type == (int)type)
            return @(data_types[i].name);
    return @"Unknown";
}

#define DATA_TYPE_FIELD(fn, field)                      \
    NSUInteger fn(MTLDataType type)                     \
    {                                                   \
        for (size_t i = 0; i < COUNT(data_types); i++)  \
            if (data_types[i].type == (int)type)        \
                return data_types[i].field;             \
        return 0;                                       \
    }
DATA_TYPE_FIELD(MTLDataTypeGetAlignment, align)
DATA_TYPE_FIELD(MTLDataTypeGetSize, size)
DATA_TYPE_FIELD(MTLDataTypeGetComponentCount, count)

MTLDataType
MTLDataTypeGetComponentType(MTLDataType type)
{
    for (size_t i = 0; i < COUNT(data_types); i++)
        if (data_types[i].type == (int)type)
            return (MTLDataType)data_types[i].component;
    return MTLDataTypeNone;
}

NSString *
MTLTextureTypeString(MTLTextureType type)
{
    for (size_t i = 0; i < COUNT(texture_types); i++)
        if (texture_types[i].type == (int)type)
            return @(texture_types[i].name);
    return @"Unknown";
}

const char *
MTLPixelFormatGetName(MTLPixelFormat format)
{
    for (size_t i = 0; i < COUNT(pixel_formats); i++)
        if (pixel_formats[i].format == (int)format)
            return pixel_formats[i].name;
    return "MTLPixelFormatInvalid";
}

/* API validation (MTL_DEBUG_LAYER): nothing to validate without a device. */
BOOL
MTLValidationEnabled(void)
{
    return NO;
}

/* Where compiled shaders would be cached: the per-user cache folder's com.apple.metal. */
NSString *
MTLGetShaderCachePath(void)
{
    char dir[PATH_MAX];
    size_t n = confstr(_CS_DARWIN_USER_CACHE_DIR, dir, sizeof dir);
    NSString *base = n ? @(dir) : NSTemporaryDirectory();
    return [base stringByAppendingString:@"/com.apple.metal"];
}

/* (private) the device apps should prefer: there's none to choose. */
void
_MTLOverrideCurrentPreferredDevice(id device)
{
}

/* --- private classes apps name --- */

@interface MTLFunctionStitchingFunctionNodeSPI : MTLFunctionStitchingFunctionNode
@end
@implementation MTLFunctionStitchingFunctionNodeSPI
@end

@interface MTLFunctionStitchingGraphSPI : MTLFunctionStitchingGraph
@end
@implementation MTLFunctionStitchingGraphSPI
@end

#define STITCHING_INPUT(name)                     \
    @interface name : MTLFunctionStitchingInputNode \
    @end                                          \
    @implementation name                          \
    @end
STITCHING_INPUT(MTLFunctionStitchingInputSampler)
STITCHING_INPUT(MTLFunctionStitchingInputTexture)
STITCHING_INPUT(MTLFunctionStitchingInputBufferAddress)
STITCHING_INPUT(MTLFunctionStitchingInputImageblock)

#define STITCHING_BUILTIN(name)                                 \
    @interface name : NSObject <MTLFunctionStitchingNode>       \
    @end                                                        \
    @implementation name                                        \
    -(id)copyWithZone:(NSZone *)zone { return self; }           \
    @end
STITCHING_BUILTIN(MTLFunctionStitchingBuiltinThreadPositionInGrid)
STITCHING_BUILTIN(MTLFunctionStitchingBuiltinThreadPositionInThreadgroup)

/* A binary archive: needs a device to be made. */
@interface _MTLBinaryArchive : NSObject
@end
@implementation _MTLBinaryArchive
@end
