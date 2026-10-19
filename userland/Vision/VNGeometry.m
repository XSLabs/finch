// SPDX-License-Identifier: MIT OR Apache-2.0
#import "VNPrivate.h"
#include <float.h>
#include <math.h>
#include <string.h>

@implementation VNPoint {
    double _x;
    double _y;
}

+ (VNPoint *)zeroPoint
{
    static VNPoint *point;
    @synchronized(self) {
        if (!point)
            point = [[self alloc] initWithX:0.0 y:0.0];
    }
    return point;
}

+ (VNPoint *)pointByApplyingVector:(VNVector *)vector toPoint:(VNPoint *)point
{
    return [[[self alloc] initWithX:point.x + vector.x y:point.y + vector.y] autorelease];
}

+ (double)distanceBetweenPoint:(VNPoint *)point1 point:(VNPoint *)point2
{
    return [point1 distanceToPoint:point2];
}

- (instancetype)init
{
    return [self initWithX:0.0 y:0.0];
}

- (instancetype)initWithX:(double)x y:(double)y
{
    if ((self = [super init])) {
        _x = x;
        _y = y;
    }
    return self;
}

- (instancetype)initWithLocation:(CGPoint)location
{
    return [self initWithX:location.x y:location.y];
}

- (double)x { return _x; }
- (double)y { return _y; }
- (CGPoint)location { return CGPointMake(_x, _y); }
- (double)distanceToPoint:(VNPoint *)point
{
    return hypot(_x - point.x, _y - point.y);
}

- (id)copyWithZone:(NSZone *)zone
{
    return [[VNPoint allocWithZone:zone] initWithX:_x y:_y];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeDouble:_x forKey:@"x"];
    [coder encodeDouble:_y forKey:@"y"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    return [self initWithX:[coder decodeDoubleForKey:@"x"] y:[coder decodeDoubleForKey:@"y"]];
}

+ (BOOL)supportsSecureCoding { return YES; }

@end

@implementation VNPoint3D {
    simd_float4x4 _position;
}

- (instancetype)init { [self release]; return nil; }
- (instancetype)initWithPosition:(simd_float4x4)position
{
    if ((self = [super init])) _position = position;
    return self;
}
- (simd_float4x4)position { return _position; }
- (id)copyWithZone:(NSZone *)zone
{
    return [[VNPoint3D allocWithZone:zone] initWithPosition:_position];
}
- (void)encodeWithCoder:(NSCoder *)coder
{
    NSData *data = [NSData dataWithBytes:&_position length:sizeof(_position)];
    [coder encodeObject:data forKey:@"position"];
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSData *data = [coder decodeObjectOfClass:NSData.class forKey:@"position"];
    if (data.length != sizeof(_position)) { [self release]; return nil; }
    simd_float4x4 position;
    memcpy(&position, data.bytes, sizeof(position));
    return [self initWithPosition:position];
}
+ (BOOL)supportsSecureCoding { return YES; }

@end

@implementation VNVector {
    double _x;
    double _y;
}

+ (VNVector *)zeroVector
{
    static VNVector *vector;
    @synchronized(self) {
        if (!vector)
            vector = [[self alloc] initWithXComponent:0.0 yComponent:0.0];
    }
    return vector;
}

+ (VNVector *)unitVectorForVector:(VNVector *)vector
{
    double length = vector.length;
    if (!length)
        return [self zeroVector];
    return [[[self alloc] initWithXComponent:vector.x / length yComponent:vector.y / length] autorelease];
}

+ (VNVector *)vectorByMultiplyingVector:(VNVector *)vector byScalar:(double)scalar
{
    return [[[self alloc] initWithXComponent:vector.x * scalar yComponent:vector.y * scalar] autorelease];
}

+ (VNVector *)vectorByAddingVector:(VNVector *)first toVector:(VNVector *)second
{
    return [[[self alloc] initWithXComponent:first.x + second.x yComponent:first.y + second.y] autorelease];
}

+ (VNVector *)vectorBySubtractingVector:(VNVector *)first fromVector:(VNVector *)second
{
    return [[[self alloc] initWithXComponent:second.x - first.x yComponent:second.y - first.y] autorelease];
}

+ (double)dotProductOfVector:(VNVector *)first vector:(VNVector *)second
{
    return first.x * second.x + first.y * second.y;
}

- (instancetype)init
{
    return [self initWithXComponent:0.0 yComponent:0.0];
}

- (instancetype)initWithXComponent:(double)x yComponent:(double)y
{
    if ((self = [super init])) {
        _x = x;
        _y = y;
    }
    return self;
}

- (instancetype)initWithR:(double)r theta:(double)theta
{
    return [self initWithXComponent:r * cos(theta) yComponent:r * sin(theta)];
}

- (instancetype)initWithVectorHead:(VNPoint *)head tail:(VNPoint *)tail
{
    return [self initWithXComponent:head.x - tail.x yComponent:head.y - tail.y];
}

- (double)x { return _x; }
- (double)y { return _y; }
- (double)r { return self.length; }
- (double)theta { return atan2(_y, _x); }
- (double)length { return hypot(_x, _y); }
- (double)squaredLength { return _x * _x + _y * _y; }

- (id)copyWithZone:(NSZone *)zone
{
    return [[VNVector allocWithZone:zone] initWithXComponent:_x yComponent:_y];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeDouble:_x forKey:@"x"];
    [coder encodeDouble:_y forKey:@"y"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    return [self initWithXComponent:[coder decodeDoubleForKey:@"x"] yComponent:[coder decodeDoubleForKey:@"y"]];
}

+ (BOOL)supportsSecureCoding { return YES; }

@end

@implementation VNCircle {
    VNPoint *_center;
    double _radius;
}

+ (VNCircle *)zeroCircle
{
    static VNCircle *circle;
    @synchronized(self) {
        if (!circle)
            circle = [[self alloc] initWithCenter:[VNPoint zeroPoint] radius:0.0];
    }
    return circle;
}

- (instancetype)init
{
    return [self initWithCenter:[VNPoint zeroPoint] radius:0.0];
}

- (instancetype)initWithCenter:(VNPoint *)center radius:(double)radius
{
    if (!center || radius < 0.0 || !isfinite(radius)) {
        [self release];
        return nil;
    }
    if ((self = [super init])) {
        _center = [center copy];
        _radius = radius;
    }
    return self;
}

- (instancetype)initWithCenter:(VNPoint *)center diameter:(double)diameter
{
    return [self initWithCenter:center radius:diameter / 2.0];
}

- (void)dealloc
{
    [_center release];
    [super dealloc];
}

- (BOOL)containsPoint:(VNPoint *)point
{
    return point && [_center distanceToPoint:point] <= _radius;
}

- (BOOL)containsPoint:(VNPoint *)point inCircumferentialRingOfWidth:(double)ringWidth
{
    if (!point || ringWidth < 0.0)
        return NO;
    double distance = [_center distanceToPoint:point];
    return distance >= MAX(0.0, _radius - ringWidth / 2.0) && distance <= _radius + ringWidth / 2.0;
}

- (VNPoint *)center { return _center; }
- (double)radius { return _radius; }
- (double)diameter { return _radius * 2.0; }

- (id)copyWithZone:(NSZone *)zone
{
    return [[VNCircle allocWithZone:zone] initWithCenter:_center radius:_radius];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_center forKey:@"center"];
    [coder encodeDouble:_radius forKey:@"radius"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    VNPoint *center = [coder decodeObjectOfClass:VNPoint.class forKey:@"center"];
    return [self initWithCenter:center radius:[coder decodeDoubleForKey:@"radius"]];
}

+ (BOOL)supportsSecureCoding { return YES; }

@end

@implementation VNGeometryUtils

+ (VNCircle *)boundingCircleForPoints:(NSArray<VNPoint *> *)points error:(NSError **)error
{
    if (![points count]) {
        if (error) *error = VNMakeError(VNErrorInvalidArgument, @"At least one point is required.");
        return nil;
    }
    double minX = DBL_MAX, minY = DBL_MAX, maxX = -DBL_MAX, maxY = -DBL_MAX;
    for (VNPoint *point in points) {
        minX = MIN(minX, point.x); minY = MIN(minY, point.y);
        maxX = MAX(maxX, point.x); maxY = MAX(maxY, point.y);
    }
    VNPoint *center = [[[VNPoint alloc] initWithX:(minX + maxX) / 2.0 y:(minY + maxY) / 2.0] autorelease];
    double radius = 0.0;
    for (VNPoint *point in points)
        radius = MAX(radius, [center distanceToPoint:point]);
    return [[[VNCircle alloc] initWithCenter:center radius:radius] autorelease];
}

+ (VNCircle *)boundingCircleForSIMDPoints:(simd_float2 const *)points pointCount:(NSInteger)pointCount error:(NSError **)error
{
    if (!points || pointCount <= 0) {
        if (error) *error = VNMakeError(VNErrorInvalidArgument, @"At least one point is required.");
        return nil;
    }
    NSMutableArray *items = [NSMutableArray arrayWithCapacity:(NSUInteger)pointCount];
    for (NSInteger index = 0; index < pointCount; index++)
        [items addObject:[[[VNPoint alloc] initWithX:points[index].x y:points[index].y] autorelease]];
    return [self boundingCircleForPoints:items error:error];
}

+ (VNCircle *)boundingCircleForContour:(VNContour *)contour error:(NSError **)error
{
    if (!contour || contour.pointCount <= 0) {
        if (error) *error = VNMakeError(VNErrorInvalidArgument, @"A contour with points is required.");
        return nil;
    }
    simd_float2 const *points = contour.normalizedPoints;
    CGFloat aspect = contour.aspectRatio;
    NSMutableArray *items = [NSMutableArray arrayWithCapacity:(NSUInteger)contour.pointCount];
    for (NSInteger index = 0; index < contour.pointCount; index++)
        [items addObject:[[[VNPoint alloc] initWithX:points[index].x * aspect y:points[index].y] autorelease]];
    return [self boundingCircleForPoints:items error:error];
}

+ (BOOL)calculateArea:(double *)area forContour:(VNContour *)contour orientedArea:(BOOL)orientedArea error:(NSError **)error
{
    if (!area || !contour || contour.pointCount < 3) {
        if (error) *error = VNMakeError(VNErrorInvalidArgument, @"A contour with at least three points and an output is required.");
        return NO;
    }
    simd_float2 const *points = contour.normalizedPoints;
    double sum = 0.0;
    for (NSInteger index = 0; index < contour.pointCount; index++) {
        NSInteger next = (index + 1) % contour.pointCount;
        sum += points[index].x * points[next].y - points[next].x * points[index].y;
    }
    sum *= (double)contour.aspectRatio / 2.0;
    *area = orientedArea ? sum : fabs(sum);
    return YES;
}

+ (BOOL)calculatePerimeter:(double *)perimeter forContour:(VNContour *)contour error:(NSError **)error
{
    if (!perimeter || !contour || contour.pointCount < 2) {
        if (error) *error = VNMakeError(VNErrorInvalidArgument, @"A contour with at least two points and an output is required.");
        return NO;
    }
    simd_float2 const *points = contour.normalizedPoints;
    double length = 0.0;
    for (NSInteger index = 0; index < contour.pointCount; index++) {
        NSInteger next = (index + 1) % contour.pointCount;
        length += hypot((points[next].x - points[index].x) * contour.aspectRatio,
                        points[next].y - points[index].y);
    }
    *perimeter = length;
    return YES;
}

@end
