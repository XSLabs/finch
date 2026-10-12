/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * More of Core Animation's private API that Apple's apps use (signatures read from
 * their calls): constants (dynamic ranges, order actions, animation modes, filter names,
 * package types, context and snapshot keys), and the classes CAPortalLayer (a layer
 * showing another layer's content), CAPackage (a Core Animation archive's layers),
 * CAState and CAStateController (named layer states), CAContext (a layer tree's handle
 * for the render server); CATransform3DInterpolate and CACornerRadiiEqualToRadii.
 * Finch has no render server yet: contexts have no IDs other processes can use, and
 * snapshots of the screen can't be taken.
 */
#import <QuartzCore/QuartzCore.h>

#define CA_EXPORT __attribute__((visibility("default")))

CA_EXPORT NSString *const CADynamicRangeHigh = @"high";
CA_EXPORT NSString *const CADynamicRangeConstrainedHigh = @"constrainedHigh";
CA_EXPORT NSString *const CADynamicRangeStandard = @"standard";
CA_EXPORT NSString *const CAToneMapModeAutomatic = @"automatic";
CA_EXPORT NSString *const CAToneMapModeIfSupported = @"ifSupported";
CA_EXPORT NSString *const CAToneMapModeNever = @"never";
CA_EXPORT NSString *const kCAOnOrderIn = @"onOrderIn";
CA_EXPORT NSString *const kCAOnOrderOut = @"onOrderOut";
CA_EXPORT NSString *const kCAAnimationAbsolute = @"absolute";
CA_EXPORT NSString *const kCAAnimationRelative = @"relative";
CA_EXPORT NSString *const kCAFilterPageCurl = @"pageCurl";
CA_EXPORT NSString *const kCAFilterMinimum = @"minimum";
CA_EXPORT NSString *const kCAFilterMultiply = @"multiply";
CA_EXPORT NSString *const kCAFilterNormalBlendMode = @"normalBlendMode";
CA_EXPORT NSString *const kCAFilterSubtractD = @"subtractD";
CA_EXPORT NSString *const kCAFilterSubtractS = @"subtractS";
CA_EXPORT NSString *const kCAPackageTypeCAMLBundle = @"com.apple.coreanimation-bundle";
CA_EXPORT NSString *const kCAPackageTypeArchive = @"com.apple.coreanimation-archive";
CA_EXPORT NSString *const kCAContextDisplayName = @"displayName";
CA_EXPORT NSString *const kCAContextIgnoresHitTest = @"ignoresHitTest";
CA_EXPORT NSString *const kCASnapshotBottomLeftOrigin = @"bottomLeftOrigin";
CA_EXPORT NSString *const kCASnapshotContextId = @"contextId";
CA_EXPORT NSString *const kCASnapshotDestination = @"destination";
CA_EXPORT NSString *const kCASnapshotDisplayName = @"displayName";
CA_EXPORT NSString *const kCASnapshotIgnoreRootAccessibilityFilters = @"ignoreAccessibility";
CA_EXPORT NSString *const kCASnapshotLayerId = @"layerId";
CA_EXPORT NSString *const kCASnapshotMode = @"mode";
CA_EXPORT NSString *const kCASnapshotModeLayer = @"modeLayer";
CA_EXPORT NSString *const kCASnapshotReuseBackdropContents = @"reuseBackdrops";
CA_EXPORT NSString *const kCASnapshotTransform = @"transform";
CA_EXPORT NSString *const kCAContentsFormatRGBA8ColorRGBA8LinearGlyphMask = @"RGBA8ColorRGBA8Mask";
CA_EXPORT NSString *const kCADepthNormalizationNone = @"none";

/* --- functions --- */

CA_EXPORT void CATransform3DInterpolate(CATransform3D *out, const CATransform3D *a, const CATransform3D *b, double t);
CA_EXPORT BOOL CARenderServerSnapshot(mach_port_t server, NSDictionary *options);
CA_EXPORT void CALayerMapGeometry(CALayer *from, CALayer *to, void *pointMapper, void *rectMapper, void *info);

typedef struct {
    CGSize minXMaxY, maxXMaxY, maxXMinY, minXMinY;
} FinchCornerRadii;
CA_EXPORT BOOL CACornerRadiiEqualToRadii(FinchCornerRadii a, FinchCornerRadii b);

/* (element by element, as Apple's interpolates between transforms of the same kind) */
void
CATransform3DInterpolate(CATransform3D *out, const CATransform3D *a, const CATransform3D *b, double t)
{
    if (!out || !a || !b)
        return;
    const CGFloat *x = &a->m11, *y = &b->m11;
    CGFloat *o = &out->m11;
    for (int i = 0; i < 16; i++)
        o[i] = x[i] + (y[i] - x[i]) * t;
}

/* (no render server: nothing to snapshot) */
BOOL
CARenderServerSnapshot(mach_port_t server, NSDictionary *options)
{
    return NO;
}

/* (geometry mapping between layer trees is for the render server; nothing is mapped) */
void
CALayerMapGeometry(CALayer *from, CALayer *to, void *pointMapper, void *rectMapper, void *info)
{
}

BOOL
CACornerRadiiEqualToRadii(FinchCornerRadii a, FinchCornerRadii b)
{
    return CGSizeEqualToSize(a.minXMaxY, b.minXMaxY) && CGSizeEqualToSize(a.maxXMaxY, b.maxXMaxY) &&
           CGSizeEqualToSize(a.maxXMinY, b.maxXMinY) && CGSizeEqualToSize(a.minXMinY, b.minXMinY);
}

/* --- classes --- */

/* A layer showing its source layer's content (Finch draws it as an ordinary layer). */
@interface CAPortalLayer : CALayer
@property (weak) CALayer *sourceLayer;
@property BOOL hidesSourceLayer, matchesPosition, matchesTransform, matchesOpacity, allowsHitTesting, allowsBackdropGroups;
@end

@implementation CAPortalLayer
@end

/* A Core Animation archive's layers: an archive written by NSKeyedArchiver with a root
   layer, as CAPackage reads it; CAML bundles aren't read yet. */
@interface CAPackage : NSObject
+ (instancetype)packageWithContentsOfURL:(NSURL *)url type:(NSString *)type options:(NSDictionary *)options error:(NSError **)error;
+ (instancetype)packageWithData:(NSData *)data type:(NSString *)type options:(NSDictionary *)options error:(NSError **)error;
@property (readonly) CALayer *rootLayer;
@property (readonly, getter=isGeometryFlipped) BOOL geometryFlipped;
- (NSArray<NSString *> *)publishedObjectNames;
- (id)publishedObjectWithName:(NSString *)name;
@end

@implementation CAPackage {
    CALayer *_root;
}

+ (instancetype)packageWithData:(NSData *)data type:(NSString *)type options:(NSDictionary *)options error:(NSError **)error
{
    CALayer *root = nil;
    if (data && [type isEqualToString:kCAPackageTypeArchive]) {
        NSKeyedUnarchiver *u = [[NSKeyedUnarchiver alloc] initForReadingFromData:data error:NULL];
        u.requiresSecureCoding = NO;
        id object = [u decodeObjectForKey:NSKeyedArchiveRootObjectKey];
        root = [object isKindOfClass:[CALayer class]] ? object
               : [object isKindOfClass:[NSDictionary class]] && [object[@"rootLayer"] isKindOfClass:[CALayer class]] ? object[@"rootLayer"]
                                                                                                                       : nil;
    }
    if (!root) {
        if (error)
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:nil];
        return nil;
    }
    CAPackage *p = [self new];
    p->_root = root;
    return p;
}

+ (instancetype)packageWithContentsOfURL:(NSURL *)url type:(NSString *)type options:(NSDictionary *)options error:(NSError **)error
{
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:error];
    return data ? [self packageWithData:data type:type options:options error:error] : nil;
}

- (CALayer *)rootLayer { return _root; }
- (BOOL)isGeometryFlipped { return _root.geometryFlipped; }

- (NSArray<NSString *> *)publishedObjectNames
{
    NSMutableArray *names = [NSMutableArray array];
    NSMutableArray *queue = [NSMutableArray arrayWithObject:_root];
    while (queue.count) {
        CALayer *l = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (l.name)
            [names addObject:l.name];
        [queue addObjectsFromArray:l.sublayers ?: @[]];
    }
    return names;
}

- (id)publishedObjectWithName:(NSString *)name
{
    NSMutableArray *queue = [NSMutableArray arrayWithObject:_root];
    while (queue.count) {
        CALayer *l = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([l.name isEqualToString:name])
            return l;
        [queue addObjectsFromArray:l.sublayers ?: @[]];
    }
    return nil;
}

@end

/* A named state: values for layers' key paths. */
@interface CAState : NSObject <NSCopying, NSSecureCoding>
@property (copy) NSString *name;
@property (copy) NSArray *elements;
@property (copy) NSString *basedOn;
@property BOOL enabled;
@property CGFloat nextDelay, previousDelay;
@end

@implementation CAState

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)init
{
    if ((self = [super init]))
        _enabled = YES;
    return self;
}

- (id)copyWithZone:(NSZone *)zone
{
    CAState *c = [[CAState allocWithZone:zone] init];
    c.name = _name;
    c.elements = _elements;
    c.basedOn = _basedOn;
    c.enabled = _enabled;
    c.nextDelay = _nextDelay;
    c.previousDelay = _previousDelay;
    return c;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_name forKey:@"name"];
    [coder encodeObject:_elements forKey:@"elements"];
    [coder encodeObject:_basedOn forKey:@"basedOn"];
    [coder encodeBool:_enabled forKey:@"enabled"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [self init])) {
        _name = [[coder decodeObjectOfClass:[NSString class] forKey:@"name"] copy];
        _basedOn = [[coder decodeObjectOfClass:[NSString class] forKey:@"basedOn"] copy];
        _enabled = [coder containsValueForKey:@"enabled"] ? [coder decodeBoolForKey:@"enabled"] : YES;
    }
    return self;
}

@end

/* Moves a layer between its named states (layers keep their states under "states"). */
@interface CAStateController : NSObject
- (instancetype)initWithLayer:(CALayer *)layer;
@property (readonly) CALayer *layer;
@property (weak) id delegate;
- (CAState *)stateOfLayer:(CALayer *)layer;
- (void)setState:(CAState *)state ofLayer:(CALayer *)layer;
- (void)setState:(CAState *)state ofLayer:(CALayer *)layer transitionSpeed:(float)speed;
- (void)setInitialStatesOfLayer:(CALayer *)layer;
- (void)removeAllStateChanges;
@end

@implementation CAStateController {
    CALayer *_layer;
    NSMapTable<CALayer *, CAState *> *_states;
}

- (instancetype)initWithLayer:(CALayer *)layer
{
    if ((self = [super init])) {
        _layer = layer;
        _states = [NSMapTable weakToStrongObjectsMapTable];
    }
    return self;
}

- (CALayer *)layer { return _layer; }
- (CAState *)stateOfLayer:(CALayer *)layer { return [_states objectForKey:layer]; }

- (void)setState:(CAState *)state ofLayer:(CALayer *)layer
{
    [self setState:state ofLayer:layer transitionSpeed:1];
}

/* (a state's elements set their values on the layer as they're given: key path and value) */
- (void)setState:(CAState *)state ofLayer:(CALayer *)layer transitionSpeed:(float)speed
{
    if (!layer)
        return;
    if (state)
        [_states setObject:state forKey:layer];
    else
        [_states removeObjectForKey:layer];
    for (id element in state.elements) {
        NSString *keyPath = [element respondsToSelector:@selector(keyPath)] ? [element valueForKey:@"keyPath"] : nil;
        id value = [element respondsToSelector:@selector(value)] ? [element valueForKey:@"value"] : nil;
        CALayer *target = [element respondsToSelector:@selector(target)] ? [element valueForKey:@"target"] : layer;
        if (keyPath)
            [target ?: layer setValue:value forKeyPath:keyPath];
    }
}

- (void)setInitialStatesOfLayer:(CALayer *)layer
{
    [self setState:nil ofLayer:layer];
}

- (void)removeAllStateChanges
{
    [_states removeAllObjects];
}

@end

/* A layer tree's handle for the render server. */
@interface CAContext : NSObject
+ (instancetype)localContext;
+ (instancetype)localContextWithOptions:(NSDictionary *)options;
+ (instancetype)remoteContext;
+ (instancetype)remoteContextWithOptions:(NSDictionary *)options;
+ (instancetype)contextWithCGSConnection:(int)cid options:(NSDictionary *)options;
+ (NSArray<CAContext *> *)allContexts;
@property (strong) CALayer *layer;
@property (readonly) uint32_t contextId;
@property (copy) NSDictionary *options;
@property (getter=isSecure) BOOL secure;
@property float level;
- (void)invalidate;
@end

@implementation CAContext {
    uint32_t _id;
}

static NSHashTable *all_contexts(void)
{
    static NSHashTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      table = [NSHashTable weakObjectsHashTable];
    });
    return table;
}

+ (instancetype)_finchContextWithOptions:(NSDictionary *)options
{
    static uint32_t next = 1;
    CAContext *c = [self new];
    @synchronized(all_contexts()) {
        c->_id = next++;
        [all_contexts() addObject:c];
    }
    c.options = options;
    return c;
}

+ (instancetype)localContext { return [self _finchContextWithOptions:nil]; }
+ (instancetype)localContextWithOptions:(NSDictionary *)options { return [self _finchContextWithOptions:options]; }
+ (instancetype)remoteContext { return [self _finchContextWithOptions:nil]; }
+ (instancetype)remoteContextWithOptions:(NSDictionary *)options { return [self _finchContextWithOptions:options]; }
+ (instancetype)contextWithCGSConnection:(int)cid options:(NSDictionary *)options { return [self _finchContextWithOptions:options]; }

+ (NSArray<CAContext *> *)allContexts
{
    @synchronized(all_contexts()) {
        return all_contexts().allObjects;
    }
}

- (uint32_t)contextId { return _id; }

- (void)invalidate
{
    self.layer = nil;
    @synchronized(all_contexts()) {
        [all_contexts() removeObject:self];
    }
}

@end
