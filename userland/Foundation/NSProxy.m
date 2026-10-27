/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSProxy (docs/design/FOUNDATION.md), against the SDK's <Foundation/NSProxy.h>:
 * a root class that implements memory management, -class, -isProxy and
 * -description itself and forwards everything else (including
 * -isKindOfClass: and -respondsToSelector:, as Apple's does) through
 * -methodSignatureForSelector: and -forwardInvocation:, which subclasses
 * implement. Forwarding is CF's (NSInvocation_Finch.m), which libobjc calls
 * for any object.
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#include "Foundation_Finch.h"

/* libobjc's root-class reference counting. */
id _objc_rootRetain(id obj);
void _objc_rootRelease(id obj);
id _objc_rootAutorelease(id obj);
NSUInteger _objc_rootRetainCount(id obj);
void _objc_rootDealloc(id obj);
BOOL _objc_rootTryRetain(id obj);
BOOL _objc_rootIsDeallocating(id obj);

@implementation NSProxy

+ (void)load { }
+ (void)initialize { }
+ (id)alloc { return [self allocWithZone:NULL]; }
+ (id)allocWithZone:(NSZone *)zone { return class_createInstance(self, 0); }
+ (Class)class { return self; }
+ (BOOL)respondsToSelector:(SEL)aSelector { return class_respondsToSelector(object_getClass((id)self), aSelector); }
+ (NSString *)description { return [NSString stringWithUTF8String:class_getName(self)]; }
+ (NSString *)debugDescription { return [self description]; }
+ (BOOL)isProxy { return NO; }
+ (id)retain { return self; }
+ (oneway void)release { }
+ (id)autorelease { return self; }
+ (NSUInteger)retainCount { return NSUIntegerMax; }
+ (Class)superclass { return class_getSuperclass(self); }
+ (BOOL)conformsToProtocol:(Protocol *)protocol
{
    for (Class c = self; c; c = class_getSuperclass(c))
        if (class_conformsToProtocol(c, protocol)) return YES;
    return NO;
}
/* The rest of what the class answers itself, as Apple's NSProxy class does (NSObject's class
   methods, which a root class doesn't inherit). */
+ (id)self { return self; }
+ (struct _NSZone *)zone { return NULL; }
+ (id)init { return self; }
+ (void)dealloc { }
+ (void)finalize { }
+ (id)copy { return self; }
+ (id)copyWithZone:(struct _NSZone *)zone { return self; }
+ (id)mutableCopy { return self; }
+ (id)mutableCopyWithZone:(struct _NSZone *)zone { return self; }
+ (NSUInteger)hash { return (NSUInteger)(uintptr_t)self; }
+ (BOOL)isEqual:(id)object { return object == (id)self; }
+ (BOOL)isFault { return NO; }
+ (BOOL)_tryRetain { return YES; }
+ (BOOL)_isDeallocating { return NO; }
+ (BOOL)allowsWeakReference { return YES; }
+ (BOOL)retainWeakReference { return YES; }
+ (CFStringRef)_copyDescription { return (CFStringRef)[[self description] copy]; }
+ (BOOL)isKindOfClass:(Class)aClass
{
    for (Class c = object_getClass((id)self); c; c = class_getSuperclass(c))
        if (c == aClass) return YES;
    return NO;
}
+ (BOOL)isMemberOfClass:(Class)aClass { return object_getClass((id)self) == aClass; }
+ (BOOL)isSubclassOfClass:(Class)aClass
{
    for (Class c = self; c; c = class_getSuperclass(c))
        if (c == aClass) return YES;
    return NO;
}
+ (BOOL)isAncestorOfObject:(id)object
{
    for (Class c = object_getClass(object); c; c = class_getSuperclass(c))
        if (c == self) return YES;
    return NO;
}
+ (BOOL)instancesRespondToSelector:(SEL)aSelector { return class_respondsToSelector(self, aSelector); }
+ (IMP)instanceMethodForSelector:(SEL)aSelector { return class_getMethodImplementation(self, aSelector); }
+ (IMP)methodForSelector:(SEL)aSelector { return class_getMethodImplementation(object_getClass((id)self), aSelector); }
+ (NSMethodSignature *)instanceMethodSignatureForSelector:(SEL)aSelector
{
    Method m = class_getInstanceMethod(self, aSelector);
    return m ? [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(m)] : nil;
}
+ (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector
{
    Method m = class_getClassMethod(self, aSelector);
    return m ? [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(m)] : nil;
}
+ (id)performSelector:(SEL)aSelector { return ((id (*)(id, SEL))objc_msgSend)((id)self, aSelector); }
+ (id)performSelector:(SEL)aSelector withObject:(id)object
{
    return ((id (*)(id, SEL, id))objc_msgSend)((id)self, aSelector, object);
}
+ (id)performSelector:(SEL)aSelector withObject:(id)object1 withObject:(id)object2
{
    return ((id (*)(id, SEL, id, id))objc_msgSend)((id)self, aSelector, object1, object2);
}
+ (id)forwardingTargetForSelector:(SEL)aSelector { return nil; }
+ (void)doesNotRecognizeSelector:(SEL)aSelector
{
    [NSException raise:NSInvalidArgumentException format:@"+[%s %s]: unrecognized selector sent to class %p",
        class_getName(self), sel_getName(aSelector), self];
}
+ (void)forwardInvocation:(NSInvocation *)invocation { [self doesNotRecognizeSelector:[invocation selector]]; }

- (Class)class { return object_getClass(self); }
- (Class)superclass { return class_getSuperclass(object_getClass(self)); }
- (id)self { return self; }
- (struct _NSZone *)zone { return NULL; }
- (BOOL)isProxy { return YES; }

- (id)retain { return _objc_rootRetain(self); }
- (oneway void)release { _objc_rootRelease(self); }
- (id)autorelease { return _objc_rootAutorelease(self); }
- (NSUInteger)retainCount { return _objc_rootRetainCount(self); }
- (BOOL)_tryRetain { return _objc_rootTryRetain(self); }
- (BOOL)_isDeallocating { return _objc_rootIsDeallocating(self); }
- (BOOL)allowsWeakReference { return !_objc_rootIsDeallocating(self); }
- (BOOL)retainWeakReference { return _objc_rootTryRetain(self); }
- (void)dealloc { _objc_rootDealloc(self); }
- (void)finalize { }

- (NSUInteger)hash { return (NSUInteger)(uintptr_t)self; }
- (BOOL)isEqual:(id)object { return object == self; }

/* Apple's: the real class and the address. */
- (NSString *)description { return [NSString stringWithFormat:@"<%s: %p>", object_getClassName(self), self]; }
- (NSString *)debugDescription { return [self description]; }

- (id)performSelector:(SEL)aSelector { return ((id (*)(id, SEL))objc_msgSend)(self, aSelector); }
- (id)performSelector:(SEL)aSelector withObject:(id)object { return ((id (*)(id, SEL, id))objc_msgSend)(self, aSelector, object); }
- (id)performSelector:(SEL)aSelector withObject:(id)object1 withObject:(id)object2
{
    return ((id (*)(id, SEL, id, id))objc_msgSend)(self, aSelector, object1, object2);
}

- (void)forwardInvocation:(NSInvocation *)invocation
{
    FinchRaise(NSInvalidArgumentException, "*** -[NSProxy forwardInvocation:] called!");
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel
{
    FinchRaise(NSInvalidArgumentException, "*** -[NSProxy methodSignatureForSelector:] called!");
}

@end

/* MARK: - NSProtocolChecker */

/*
 * A proxy that passes on only the messages its protocol declares (required or
 * optional instance methods, the protocols it adopts included). As Apple's,
 * NSProtocolChecker is the abstract class and NSConcreteProtocolChecker the
 * instances; a method's result goes back as the target returned it.
 */
/* libobjc's: a protocol method's full (extended) type encoding. */
const char *_protocol_getMethodTypeEncoding(Protocol *protocol, SEL sel, BOOL required, BOOL instance);

@interface NSConcreteProtocolChecker : NSProtocolChecker {
    NSObject *_target;
    Protocol *_protocol;
}
@end

@implementation NSProtocolChecker

+ (id)allocWithZone:(NSZone *)zone
{
    if (self == [NSProtocolChecker class]) return [NSConcreteProtocolChecker allocWithZone:zone];
    return [super allocWithZone:zone];
}

+ (instancetype)protocolCheckerWithTarget:(NSObject *)anObject protocol:(Protocol *)aProtocol
{
    return [[[self alloc] initWithTarget:anObject protocol:aProtocol] autorelease];
}

- (instancetype)initWithTarget:(NSObject *)anObject protocol:(Protocol *)aProtocol { return self; }
- (Protocol *)protocol { return nil; }
- (NSObject *)target { return nil; }

@end

@implementation NSConcreteProtocolChecker

- (instancetype)initWithTarget:(NSObject *)anObject protocol:(Protocol *)aProtocol
{
    _target = [anObject retain];
    _protocol = aProtocol;
    return self;
}

- (void)dealloc
{
    [_target release];
    [super dealloc];
}

- (Protocol *)protocol { return _protocol; }
- (NSObject *)target { return _target; }

static BOOL
declares(Protocol *protocol, SEL sel)
{
    if (!protocol) return NO;
    return protocol_getMethodDescription(protocol, sel, YES, YES).name || protocol_getMethodDescription(protocol, sel, NO, YES).name;
}

- (BOOL)respondsToSelector:(SEL)sel { return declares(_protocol, sel) && [_target respondsToSelector:sel]; }
- (BOOL)conformsToProtocol:(Protocol *)protocol { return _protocol && protocol_conformsToProtocol(_protocol, protocol); }

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel
{
    if (!declares(_protocol, sel)) return nil;
    struct objc_method_description d = protocol_getMethodDescription(_protocol, sel, YES, YES);
    if (!d.name) d = protocol_getMethodDescription(_protocol, sel, NO, YES);
    const char *types = _protocol_getMethodTypeEncoding(_protocol, sel, YES, YES);
    if (!types) types = _protocol_getMethodTypeEncoding(_protocol, sel, NO, YES);
    return [NSMethodSignature signatureWithObjCTypes:types ?: d.types];
}

- (void)forwardInvocation:(NSInvocation *)invocation
{
    if (!declares(_protocol, [invocation selector]))
        FinchRaise(NSInvalidArgumentException, "*** NSProtocolChecker: target protocol does not recognize selector: %s",
            sel_getName([invocation selector]));
    [invocation invokeWithTarget:_target];
}

- (void)doesNotRecognizeSelector:(SEL)sel
{
    FinchRaise(NSInvalidArgumentException, "*** NSProtocolChecker: target protocol does not recognize selector: %s", sel_getName(sel));
}

@end
