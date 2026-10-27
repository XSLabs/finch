/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Distributed Objects: NSConnection, NSDistantObject, NSPortCoder and the
 * port name servers.
 *
 * A connection pairs a receive port with a send port. Messages are NSPort
 * messages whose first component is the payload an NSPortCoder writes; ports
 * travel as further components. A proxy's message goes out as a request
 * (target, selector, types, arguments) and the caller runs its run loop in
 * NSConnectionReplyMode until the reply comes back with the result, any
 * out-parameters, or the exception the remote side raised. Objects travel by
 * copy when their class says so (strings, numbers, data, dates, collections
 * and the like) and otherwise by reference, as a proxy on the far side; an
 * object that comes home arrives as a local proxy, as with Apple's.
 *
 * The wire format is Finch's own: both ends run Finch's Foundation.
 */

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <servers/bootstrap.h>
#include <pthread.h>
#include "Foundation_Finch.h"

@interface NSMethodSignature (FinchTypes)
- (const char *)_typeString;
@end

/* libobjc's: a protocol method's full (extended) type encoding. */
const char *_protocol_getMethodTypeEncoding(Protocol *protocol, SEL sel, BOOL required, BOOL instance);

enum { DORequest = 1, DOReply = 2, DORootRequest = 3, DOSignatureRequest = 4 };
enum { TagNil = 0, TagCopy = 1, TagExported = 2, TagReturned = 3, TagPort = 4 };

static NSString *const ServerNote = @"[NOTE: this exception originated in the server.]\n";

@interface NSConnection (FinchDO)
- (instancetype)_initChildOf:(NSConnection *)parent sendPort:(NSPort *)port;
- (uint64_t)_exportObject:(id)object;
- (id)_exportedObject:(uint64_t)identifier;
- (NSDistantObject *)_proxyForRemote:(uint64_t)identifier;
- (void)_forgetProxy:(NSDistantObject *)proxy;
- (void)_forwardInvocation:(NSInvocation *)invocation toRemote:(uint64_t)identifier;
- (NSString *)_remoteTypesForSelector:(SEL)sel target:(uint64_t)identifier;
- (void)_handleComponents:(NSArray *)components msgid:(uint32_t)msgid;
@end

@interface NSConnection () <NSPortDelegate>
@end

@interface NSDistantObject (FinchDO)
- (BOOL)_isLocal;
- (id)_localTarget;
- (uint64_t)_remoteID;
@end

@interface NSPortCoder (FinchDO)
- (instancetype)_initForConnection:(NSConnection *)connection;
- (instancetype)_initWithComponents:(NSArray *)components connection:(NSConnection *)connection;
- (NSArray *)_components;
- (void)_writeBytes:(const void *)bytes length:(NSUInteger)length;
- (BOOL)_readBytes:(void *)bytes length:(NSUInteger)length;
- (void)_writeString:(NSString *)string;
- (NSString *)_readString;
@end

/* MARK: - Type encodings */

static const char *
skip_qualifiers(const char *type)
{
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL
has_qualifier(const char *type, char qualifier)
{
    for (; *type && strchr("rnNoORV", *type); type++)
        if (*type == qualifier) return YES;
    return NO;
}

/* The size of one encoded type, skipping trailing frame offsets. */
static NSUInteger
type_size(const char *type)
{
    NSUInteger size = 0;
    NSGetSizeAndAlignment(skip_qualifiers(type), &size, NULL);
    return size;
}

/* MARK: - NSPortCoder */

@implementation NSPortCoder {
    NSConnection *_fConnection;
    NSMutableData *_fOut;
    NSData *_fIn;
    NSUInteger _fPos;
    NSMutableArray *_fPorts;
    NSArray *_fComponents;
    NSPort *_fReceive, *_fSend;
    BOOL _fBycopy, _fByref;
}

+ (id)portCoderWithReceivePort:(NSPort *)rcvPort sendPort:(NSPort *)sndPort components:(NSArray *)comps
{
    return [[[self alloc] initWithReceivePort:rcvPort sendPort:sndPort components:comps] autorelease];
}

- (id)initWithReceivePort:(NSPort *)rcvPort sendPort:(NSPort *)sndPort components:(NSArray *)comps
{
    NSConnection *connection = [NSConnection connectionWithReceivePort:rcvPort sendPort:sndPort];
    if ((self = [self _initWithComponents:comps connection:connection])) {
        _fReceive = [rcvPort retain];
        _fSend = [sndPort retain];
    }
    return self;
}

- (instancetype)_initForConnection:(NSConnection *)connection
{
    if ((self = [super init])) {
        _fConnection = [connection retain];
        _fOut = [[NSMutableData alloc] init];
        _fPorts = [[NSMutableArray alloc] init];
    }
    return self;
}

- (instancetype)_initWithComponents:(NSArray *)components connection:(NSConnection *)connection
{
    if ((self = [super init])) {
        _fConnection = [connection retain];
        _fComponents = [components copy];
        id first = [components firstObject];
        _fIn = [[first isKindOfClass:[NSData class]] ? first : [NSData data] retain];
    }
    return self;
}

- (void)dealloc
{
    [_fConnection release];
    [_fOut release];
    [_fIn release];
    [_fPorts release];
    [_fComponents release];
    [_fReceive release];
    [_fSend release];
    [super dealloc];
}

- (NSConnection *)connection { return _fConnection; }
- (BOOL)isBycopy { return _fBycopy; }
- (BOOL)isByref { return _fByref; }
- (BOOL)allowsKeyedCoding { return NO; }
- (unsigned)systemVersion { return 1000; }
- (NSInteger)versionForClassName:(NSString *)className
{
    Class cls = NSClassFromString(className);
    return cls ? class_getVersion(cls) : NSNotFound;
}

- (NSArray *)_components
{
    NSMutableArray *components = [NSMutableArray arrayWithObject:[[_fOut copy] autorelease]];
    [components addObjectsFromArray:_fPorts];
    return components;
}

- (void)dispatch
{
    [_fConnection _handleComponents:_fComponents msgid:DORequest];
}

- (void)_writeBytes:(const void *)bytes length:(NSUInteger)length { [_fOut appendBytes:bytes length:length]; }

- (BOOL)_readBytes:(void *)bytes length:(NSUInteger)length
{
    if (_fPos + length > [_fIn length]) {
        FinchRaise(NSPortReceiveException, "*** NSPortCoder: message ended early");
        return NO;
    }
    memcpy(bytes, (const uint8_t *)[_fIn bytes] + _fPos, length);
    _fPos += length;
    return YES;
}

- (void)_writeString:(NSString *)string
{
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    int32_t length = string ? (int32_t)[data length] : -1;
    [self _writeBytes:&length length:sizeof(length)];
    if (data) [self _writeBytes:[data bytes] length:[data length]];
}

- (NSString *)_readString
{
    int32_t length = 0;
    [self _readBytes:&length length:sizeof(length)];
    if (length < 0) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)length];
    [self _readBytes:[data mutableBytes] length:(NSUInteger)length];
    return [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
}

- (void)encodeBytes:(const void *)bytes length:(NSUInteger)length
{
    uint64_t n = bytes ? length : UINT64_MAX;
    [self _writeBytes:&n length:sizeof(n)];
    if (bytes) [self _writeBytes:bytes length:length];
}

- (void *)decodeBytesWithReturnedLength:(NSUInteger *)length
{
    uint64_t n = 0;
    [self _readBytes:&n length:sizeof(n)];
    if (n == UINT64_MAX) { if (length) *length = 0; return NULL; }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)n];
    [self _readBytes:[data mutableBytes] length:(NSUInteger)n];
    if (length) *length = (NSUInteger)n;
    return [data mutableBytes];
}

- (void)encodeDataObject:(NSData *)data { [self encodeBytes:[data bytes] ?: "" length:[data length]]; }

- (NSData *)decodeDataObject
{
    NSUInteger n = 0;
    void *bytes = [self decodeBytesWithReturnedLength:&n];
    return [NSMutableData dataWithBytes:bytes length:n];
}

/* Values: scalars as their bytes (both ends run on the same machine type),
 * objects through encodeObject:, strings, selectors and classes by name,
 * structures and arrays element by element. */
- (void)encodeValueOfObjCType:(const char *)type at:(const void *)address
{
    type = skip_qualifiers(type);
    switch (*type) {
    case '@': [self encodeObject:*(id *)address]; return;
    case '#': [self _writeString:*(Class *)address ? NSStringFromClass(*(Class *)address) : nil]; return;
    case ':': [self _writeString:*(SEL *)address ? NSStringFromSelector(*(SEL *)address) : nil]; return;
    case '*': {
        const char *s = *(const char **)address;
        [self encodeBytes:s length:s ? strlen(s) + 1 : 0];
        return;
    }
    case '{': {
        const char *field = strchr(type, '=');
        if (!field) break;
        field++;
        NSUInteger offset = 0;
        while (*field && *field != '}') {
            NSUInteger size = 0, alignment = 1;
            const char *next = NSGetSizeAndAlignment(field, &size, &alignment);
            if (alignment) offset = (offset + alignment - 1) / alignment * alignment;
            [self encodeValueOfObjCType:field at:(const uint8_t *)address + offset];
            offset += size;
            field = next;
        }
        return;
    }
    case '[': {
        char *element = NULL;
        unsigned long count = strtoul(type + 1, &element, 10);
        NSUInteger size = type_size(element);
        for (unsigned long i = 0; i < count; i++) [self encodeValueOfObjCType:element at:(const uint8_t *)address + i * size];
        return;
    }
    default:
        break;
    }
    [self _writeBytes:address length:type_size(type)];
}

- (void)decodeValueOfObjCType:(const char *)type at:(void *)address size:(NSUInteger)size
{
    (void)size;
    type = skip_qualifiers(type);
    switch (*type) {
    case '@': *(id *)address = [self decodeObject]; return;
    case '#': { NSString *name = [self _readString]; *(Class *)address = name ? NSClassFromString(name) : Nil; return; }
    case ':': { NSString *name = [self _readString]; *(SEL *)address = name ? NSSelectorFromString(name) : NULL; return; }
    case '*': {
        NSUInteger n = 0;
        void *bytes = [self decodeBytesWithReturnedLength:&n];
        *(char **)address = bytes && n ? (char *)[[NSMutableData dataWithBytes:bytes length:n] mutableBytes] : NULL;
        return;
    }
    case '{': {
        const char *field = strchr(type, '=');
        if (!field) break;
        field++;
        NSUInteger offset = 0;
        while (*field && *field != '}') {
            NSUInteger fieldSize = 0, alignment = 1;
            const char *next = NSGetSizeAndAlignment(field, &fieldSize, &alignment);
            if (alignment) offset = (offset + alignment - 1) / alignment * alignment;
            [self decodeValueOfObjCType:field at:(uint8_t *)address + offset size:fieldSize];
            offset += fieldSize;
            field = next;
        }
        return;
    }
    case '[': {
        char *element = NULL;
        unsigned long count = strtoul(type + 1, &element, 10);
        NSUInteger elementSize = type_size(element);
        for (unsigned long i = 0; i < count; i++) [self decodeValueOfObjCType:element at:(uint8_t *)address + i * elementSize size:elementSize];
        return;
    }
    default:
        break;
    }
    [self _readBytes:address length:type_size(type)];
}

- (void)decodeValueOfObjCType:(const char *)type at:(void *)address
{
    [self decodeValueOfObjCType:type at:address size:type_size(type)];
}

- (void)encodePortObject:(NSPort *)port
{
    uint8_t tag = TagPort;
    [self _writeBytes:&tag length:1];
    int32_t index = port ? (int32_t)[_fPorts count] : -1;
    if (port) [_fPorts addObject:port];
    [self _writeBytes:&index length:sizeof(index)];
}

- (NSPort *)decodePortObject
{
    uint8_t tag = 0;
    [self _readBytes:&tag length:1];
    if (tag != TagPort) return nil;
    int32_t index = -1;
    [self _readBytes:&index length:sizeof(index)];
    if (index < 0 || (NSUInteger)index + 1 >= [_fComponents count]) return nil;
    id port = [_fComponents objectAtIndex:(NSUInteger)index + 1];
    return [port isKindOfClass:[NSPort class]] ? port : nil;
}

- (void)encodeBycopyObject:(id)object
{
    BOOL was = _fBycopy;
    _fBycopy = YES;
    [self encodeObject:object];
    _fBycopy = was;
}

- (void)encodeByrefObject:(id)object
{
    BOOL was = _fByref;
    _fByref = YES;
    [self encodeObject:object];
    _fByref = was;
}

- (void)encodeConditionalObject:(id)object { [self encodeObject:object]; }
- (void)encodeRootObject:(id)object { [self encodeObject:object]; }

- (void)encodeObject:(id)object
{
    if (!object) {
        uint8_t tag = TagNil;
        [self _writeBytes:&tag length:1];
        return;
    }
    if (![object isProxy] && [object isKindOfClass:[NSPort class]]) {
        [self encodePortObject:object];
        return;
    }
    id replacement = _fByref ? [NSDistantObject proxyWithLocal:object connection:_fConnection]
                             : [object replacementObjectForPortCoder:self];
    if ([replacement isProxy] && object_getClass(replacement) == [NSDistantObject class]) {
        NSDistantObject *proxy = replacement;
        if (![proxy _isLocal] && [proxy connectionForProxy] == _fConnection) {
            uint8_t tag = TagReturned;
            uint64_t identifier = [proxy _remoteID];
            [self _writeBytes:&tag length:1];
            [self _writeBytes:&identifier length:sizeof(identifier)];
            return;
        }
        uint8_t tag = TagExported;
        uint64_t identifier = [_fConnection _exportObject:[proxy _isLocal] ? [proxy _localTarget] : proxy];
        [self _writeBytes:&tag length:1];
        [self _writeBytes:&identifier length:sizeof(identifier)];
        return;
    }
    uint8_t tag = TagCopy;
    [self _writeBytes:&tag length:1];
    Class cls = [replacement classForPortCoder];
    [self _writeString:NSStringFromClass(cls)];
    BOOL wasBycopy = _fBycopy, wasByref = _fByref;
    _fBycopy = NO;
    _fByref = NO;
    [replacement encodeWithCoder:self];
    _fBycopy = wasBycopy;
    _fByref = wasByref;
}

- (id)decodeObject
{
    uint8_t tag = TagNil;
    [self _readBytes:&tag length:1];
    switch (tag) {
    case TagNil:
        return nil;
    case TagPort: {
        _fPos--;
        return [self decodePortObject];
    }
    case TagExported: {
        uint64_t identifier = 0;
        [self _readBytes:&identifier length:sizeof(identifier)];
        return [_fConnection _proxyForRemote:identifier];
    }
    case TagReturned: {
        uint64_t identifier = 0;
        [self _readBytes:&identifier length:sizeof(identifier)];
        id local = [_fConnection _exportedObject:identifier];
        return local ? [NSDistantObject proxyWithLocal:local connection:_fConnection] : nil;
    }
    case TagCopy: {
        NSString *name = [self _readString];
        Class cls = name ? NSClassFromString(name) : Nil;
        if (!cls) FinchRaise(NSPortReceiveException, "*** NSPortCoder: no class named %s", [name UTF8String]);
        id object = [[cls allocWithZone:NULL] initWithCoder:self];
        id replaced = [object awakeAfterUsingCoder:self];
        if (replaced != object) { [replaced retain]; [object release]; object = replaced; }
        return [object autorelease];
    }
    default:
        FinchRaise(NSPortReceiveException, "*** NSPortCoder: unknown object tag %u", tag);
        return nil;
    }
}

@end

/* MARK: - Passing objects */

@implementation NSObject (NSDistributedObjects)
- (Class)classForPortCoder { return [self classForCoder]; }
- (id)replacementObjectForPortCoder:(NSPortCoder *)coder
{
    if ([coder isBycopy] && [self conformsToProtocol:@protocol(NSCoding)]) return self;
    return [NSDistantObject proxyWithLocal:self connection:[coder connection]];
}
@end

/* Values and collections travel by copy unless sent byref. */
#define BYCOPY(cls) \
    @implementation cls (FinchPortCoding) \
    - (id)replacementObjectForPortCoder:(NSPortCoder *)coder \
    { \
        return [coder isByref] ? [NSDistantObject proxyWithLocal:self connection:[coder connection]] : self; \
    } \
    @end

BYCOPY(NSString)
BYCOPY(NSValue)
BYCOPY(NSData)
BYCOPY(NSDate)
BYCOPY(NSArray)
BYCOPY(NSDictionary)
BYCOPY(NSSet)
BYCOPY(NSOrderedSet)
BYCOPY(NSNull)
BYCOPY(NSURL)
BYCOPY(NSError)
BYCOPY(NSException)
BYCOPY(NSUUID)
BYCOPY(NSCharacterSet)
BYCOPY(NSIndexSet)
BYCOPY(NSAttributedString)
BYCOPY(NSTimeZone)
BYCOPY(NSLocale)

/* MARK: - NSDistantObject */

@implementation NSDistantObject {
    NSConnection *_fConnection;
    uint64_t _fRemote;
    id _fLocal;
    Protocol *_fProtocol;
    NSMutableDictionary *_fSignatures;
}

+ (id)proxyWithTarget:(id)target connection:(NSConnection *)connection
{
    return [[[self alloc] initWithTarget:target connection:connection] autorelease];
}

- (instancetype)initWithTarget:(id)target connection:(NSConnection *)connection
{
    _fConnection = [connection retain];
    _fRemote = [target respondsToSelector:@selector(unsignedLongLongValue)] ? [target unsignedLongLongValue] : 0;
    _fSignatures = [[NSMutableDictionary alloc] init];
    return self;
}

+ (id)proxyWithLocal:(id)target connection:(NSConnection *)connection
{
    return [[[self alloc] initWithLocal:target connection:connection] autorelease];
}

- (instancetype)initWithLocal:(id)target connection:(NSConnection *)connection
{
    _fConnection = [connection retain];
    _fLocal = [target retain];
    _fSignatures = [[NSMutableDictionary alloc] init];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    [self release];
    return [[coder decodeObject] retain];
}

- (void)encodeWithCoder:(NSCoder *)coder { [coder encodeObject:self]; }
- (Class)classForCoder { return [NSDistantObject class]; }
- (Class)classForPortCoder { return [NSDistantObject class]; }
- (id)replacementObjectForPortCoder:(NSPortCoder *)coder { (void)coder; return self; }

- (void)dealloc
{
    if (!_fLocal) [_fConnection _forgetProxy:self];
    [_fConnection release];
    [_fLocal release];
    [_fSignatures release];
    [super dealloc];
}

- (BOOL)_isLocal { return _fLocal != nil; }
- (id)_localTarget { return _fLocal; }
- (uint64_t)_remoteID { return _fRemote; }
- (NSConnection *)connectionForProxy { return _fConnection; }
- (void)setProtocolForProxy:(Protocol *)proto { _fProtocol = proto; }

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel
{
    if (_fLocal) return [_fLocal methodSignatureForSelector:sel];
    NSString *key = NSStringFromSelector(sel);
    NSMethodSignature *signature = [_fSignatures objectForKey:key];
    if (signature) return signature;
    const char *types = NULL;
    if (_fProtocol) {
        types = _protocol_getMethodTypeEncoding(_fProtocol, sel, YES, YES);
        if (!types) types = _protocol_getMethodTypeEncoding(_fProtocol, sel, NO, YES);
        if (!types) {
            struct objc_method_description d = protocol_getMethodDescription(_fProtocol, sel, YES, YES);
            if (!d.name) d = protocol_getMethodDescription(_fProtocol, sel, NO, YES);
            types = d.types;
        }
    }
    NSString *remote = nil;
    if (!types) {
        Method method = class_getInstanceMethod([NSObject class], sel);
        if (method) types = method_getTypeEncoding(method);
        else {
            remote = [_fConnection _remoteTypesForSelector:sel target:_fRemote];
            types = [remote UTF8String];
        }
    }
    if (!types) return nil;
    signature = [NSMethodSignature signatureWithObjCTypes:types];
    if (signature) [_fSignatures setObject:signature forKey:key];
    return signature;
}

- (void)forwardInvocation:(NSInvocation *)invocation
{
    if (_fLocal) [invocation invokeWithTarget:_fLocal];
    else [_fConnection _forwardInvocation:invocation toRemote:_fRemote];
}

- (BOOL)respondsToSelector:(SEL)sel
{
    if (_fLocal) return [_fLocal respondsToSelector:sel];
    if (_fProtocol && (protocol_getMethodDescription(_fProtocol, sel, YES, YES).name ||
                       protocol_getMethodDescription(_fProtocol, sel, NO, YES).name)) return YES;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:"c@::"];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    [invocation setSelector:@selector(respondsToSelector:)];
    [invocation setArgument:&sel atIndex:2];
    [_fConnection _forwardInvocation:invocation toRemote:_fRemote];
    BOOL result = NO;
    [invocation getReturnValue:&result];
    return result;
}

- (BOOL)conformsToProtocol:(Protocol *)protocol
{
    if (_fLocal) return [_fLocal conformsToProtocol:protocol];
    if (_fProtocol && protocol_conformsToProtocol(_fProtocol, protocol)) return YES;
    return NO;
}

- (BOOL)isEqual:(id)object
{
    if (object == self) return YES;
    if (_fLocal) return [_fLocal isEqual:[object isProxy] && object_getClass(object) == [NSDistantObject class] && [object _isLocal] ? [object _localTarget] : object];
    if ([object isProxy] && object_getClass(object) == [NSDistantObject class])
        return ![object _isLocal] && [object connectionForProxy] == _fConnection && [object _remoteID] == _fRemote;
    return NO;
}

- (NSUInteger)hash { return _fLocal ? [_fLocal hash] : (NSUInteger)_fRemote; }

- (NSString *)description
{
    if (_fLocal) return [_fLocal description];
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:"@@:"];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    [invocation setSelector:@selector(description)];
    [_fConnection _forwardInvocation:invocation toRemote:_fRemote];
    id result = nil;
    [invocation getReturnValue:&result];
    return result;
}

@end

/* MARK: - NSDistantObjectRequest */

@implementation NSDistantObjectRequest {
    NSInvocation *_fInvocation;
    NSConnection *_fConnection;
    NSException *_fException;
}
- (NSInvocation *)invocation { return _fInvocation; }
- (NSConnection *)connection { return _fConnection; }
- (id)conversation { return nil; }
- (void)replyWithException:(NSException *)exception { [_fException release]; _fException = [exception retain]; }
- (void)dealloc
{
    [_fInvocation release];
    [_fConnection release];
    [_fException release];
    [super dealloc];
}
@end

/* MARK: - NSConnection */

static NSMutableArray *all_connections;
static pthread_mutex_t connections_lock = PTHREAD_MUTEX_INITIALIZER;

static NSConnection *
find_connection(NSPort *receive, NSPort *send)
{
    NSConnection *found = nil;
    pthread_mutex_lock(&connections_lock);
    for (NSConnection *connection in all_connections)
        if ([[connection receivePort] isEqual:receive] && [[connection sendPort] isEqual:send] && [connection isValid]) {
            found = [[connection retain] autorelease];
            break;
        }
    pthread_mutex_unlock(&connections_lock);
    return found;
}

static NSConnection *
owner_of(NSPort *receive)
{
    NSConnection *found = nil;
    pthread_mutex_lock(&connections_lock);
    for (NSConnection *connection in all_connections)
        if ([[connection receivePort] isEqual:receive] && [[connection receivePort] delegate] == connection) {
            found = [[connection retain] autorelease];
            break;
        }
    pthread_mutex_unlock(&connections_lock);
    return found;
}

@implementation NSConnection {
    NSPort *_fReceive, *_fSend;
    id _fRoot;
    id _fDelegate;
    NSTimeInterval _fRequestTimeout, _fReplyTimeout;
    BOOL _fValid, _fIndependent, _fMultiple;
    NSMutableArray *_fModes;
    NSMutableArray *_fRunLoops;
    NSMutableDictionary *_fExported;      /* identifier -> object */
    NSMutableDictionary *_fExportIDs;     /* object address -> identifier */
    NSMutableDictionary *_fProxies;       /* identifier -> NSValue (weak proxy) */
    NSMutableDictionary *_fReplies;       /* sequence -> NSPortCoder */
    uint32_t _fSequence;
    uint64_t _fNextExport;
    NSDistantObject *_fRootProxy;
    NSUInteger _fRequestsSent, _fRepliesReceived, _fRequestsReceived, _fRepliesSent;
}

+ (NSArray *)allConnections
{
    pthread_mutex_lock(&connections_lock);
    NSArray *connections = [[all_connections copy] autorelease] ?: [NSArray array];
    pthread_mutex_unlock(&connections_lock);
    return connections;
}

+ (NSConnection *)defaultConnection
{
    NSMutableDictionary *thread = [[NSThread currentThread] threadDictionary];
    NSConnection *connection = [thread objectForKey:@"NSDefaultConnection"];
    if (!connection) {
        connection = [[[NSConnection alloc] init] autorelease];
        [thread setObject:connection forKey:@"NSDefaultConnection"];
    }
    return connection;
}

+ (id)currentConversation { return nil; }

+ (instancetype)connectionWithReceivePort:(NSPort *)rcvPort sendPort:(NSPort *)sndPort
{
    return [[[self alloc] initWithReceivePort:rcvPort sendPort:sndPort] autorelease];
}

+ (instancetype)connectionWithRegisteredName:(NSString *)name host:(NSString *)hostName
{
    return [self connectionWithRegisteredName:name host:hostName usingNameServer:[NSPortNameServer systemDefaultPortNameServer]];
}

+ (instancetype)connectionWithRegisteredName:(NSString *)name host:(NSString *)hostName usingNameServer:(NSPortNameServer *)server
{
    NSPort *port = [server portForName:name host:hostName];
    if (!port) return nil;
    NSPort *receive = [port isKindOfClass:[NSMachPort class]] ? [NSMachPort port] : [[[[port class] alloc] init] autorelease];
    return [self connectionWithReceivePort:receive sendPort:port];
}

+ (NSDistantObject *)rootProxyForConnectionWithRegisteredName:(NSString *)name host:(NSString *)hostName
{
    return [[self connectionWithRegisteredName:name host:hostName] rootProxy];
}

+ (NSDistantObject *)rootProxyForConnectionWithRegisteredName:(NSString *)name host:(NSString *)hostName usingNameServer:(NSPortNameServer *)server
{
    return [[self connectionWithRegisteredName:name host:hostName usingNameServer:server] rootProxy];
}

+ (instancetype)serviceConnectionWithName:(NSString *)name rootObject:(id)root usingNameServer:(NSPortNameServer *)server
{
    NSConnection *connection = [[[self alloc] init] autorelease];
    connection.rootObject = root;
    return [connection registerName:name withNameServer:server] ? connection : nil;
}

+ (instancetype)serviceConnectionWithName:(NSString *)name rootObject:(id)root
{
    return [self serviceConnectionWithName:name rootObject:root usingNameServer:[NSPortNameServer systemDefaultPortNameServer]];
}

- (instancetype)init { return [self initWithReceivePort:[NSMachPort port] sendPort:nil]; }

- (instancetype)initWithReceivePort:(NSPort *)rcvPort sendPort:(NSPort *)sndPort
{
    if (!rcvPort) rcvPort = sndPort ? [[[[sndPort class] alloc] init] autorelease] : [NSMachPort port];
    if (!sndPort) sndPort = rcvPort;
    NSConnection *existing = find_connection(rcvPort, sndPort);
    if (existing) {
        [self release];
        return [existing retain];
    }
    if (!(self = [super init])) return nil;
    _fReceive = [rcvPort retain];
    _fSend = [sndPort retain];
    _fRequestTimeout = 1e10;
    _fReplyTimeout = 1e10;
    _fValid = YES;
    _fModes = [[NSMutableArray alloc] initWithObjects:NSDefaultRunLoopMode, nil];
    _fRunLoops = [[NSMutableArray alloc] init];
    _fExported = [[NSMutableDictionary alloc] init];
    _fExportIDs = [[NSMutableDictionary alloc] init];
    _fProxies = [[NSMutableDictionary alloc] init];
    _fReplies = [[NSMutableDictionary alloc] init];
    _fNextExport = 1;
    BOOL owns = owner_of(rcvPort) == nil;
    pthread_mutex_lock(&connections_lock);
    if (!all_connections) all_connections = [[NSMutableArray alloc] init];
    [all_connections addObject:self];
    pthread_mutex_unlock(&connections_lock);
    if (owns) {
        [_fReceive setDelegate:self];
        [self addRunLoop:[NSRunLoop currentRunLoop]];
    }
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(_portDidBecomeInvalid:) name:NSPortDidBecomeInvalidNotification object:_fReceive];
    if (_fSend != _fReceive)
        [center addObserver:self selector:@selector(_portDidBecomeInvalid:) name:NSPortDidBecomeInvalidNotification object:_fSend];
    [center postNotificationName:NSConnectionDidInitializeNotification object:self];
    return self;
}

- (instancetype)_initChildOf:(NSConnection *)parent sendPort:(NSPort *)port
{
    if ((self = [self initWithReceivePort:[parent receivePort] sendPort:port])) {
        self.rootObject = parent.rootObject;
        self.delegate = parent.delegate;
        _fRequestTimeout = parent.requestTimeout;
        _fReplyTimeout = parent.replyTimeout;
        for (NSString *mode in parent.requestModes) if (![_fModes containsObject:mode]) [_fModes addObject:mode];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_fReceive release];
    [_fSend release];
    [_fRoot release];
    [_fModes release];
    [_fRunLoops release];
    [_fExported release];
    [_fExportIDs release];
    [_fProxies release];
    [_fReplies release];
    [super dealloc];
}

- (NSPort *)receivePort { return _fReceive; }
- (NSPort *)sendPort { return _fSend; }
- (NSTimeInterval)requestTimeout { return _fRequestTimeout; }
- (void)setRequestTimeout:(NSTimeInterval)value { _fRequestTimeout = value; }
- (NSTimeInterval)replyTimeout { return _fReplyTimeout; }
- (void)setReplyTimeout:(NSTimeInterval)value { _fReplyTimeout = value; }
- (id)rootObject { return _fRoot; }
- (void)setRootObject:(id)object { [_fRoot autorelease]; _fRoot = [object retain]; }
- (id)delegate { return _fDelegate; }
- (void)setDelegate:(id)anObject { _fDelegate = anObject; }
- (BOOL)independentConversationQueueing { return _fIndependent; }
- (void)setIndependentConversationQueueing:(BOOL)value { _fIndependent = value; }
- (BOOL)isValid { return _fValid; }
- (NSArray *)requestModes { return [[_fModes copy] autorelease]; }
- (BOOL)multipleThreadsEnabled { return _fMultiple; }
- (void)enableMultipleThreads { _fMultiple = YES; }

- (NSDictionary *)statistics
{
    return [NSDictionary dictionaryWithObjectsAndKeys:
            [NSNumber numberWithUnsignedInteger:_fRequestsSent], @"NSConnectionRequestsSent",
            [NSNumber numberWithUnsignedInteger:_fRepliesReceived], @"NSConnectionRepliesReceived",
            [NSNumber numberWithUnsignedInteger:_fRequestsReceived], @"NSConnectionRequestsReceived",
            [NSNumber numberWithUnsignedInteger:_fRepliesSent], @"NSConnectionRepliesSent",
            [NSNumber numberWithUnsignedInteger:[_fExported count]], @"NSConnectionLocalCount",
            [NSNumber numberWithUnsignedInteger:[_fProxies count]], @"NSConnectionProxyCount", nil];
}

- (NSArray *)localObjects
{
    NSMutableArray *objects = [NSMutableArray array];
    for (id object in [_fExported allValues]) [objects addObject:[NSDistantObject proxyWithLocal:object connection:self]];
    return objects;
}

- (NSArray *)remoteObjects
{
    NSMutableArray *objects = [NSMutableArray array];
    for (NSValue *proxy in [_fProxies allValues]) if ([proxy nonretainedObjectValue]) [objects addObject:[proxy nonretainedObjectValue]];
    return objects;
}

- (void)_schedule:(BOOL)add runLoop:(NSRunLoop *)runLoop
{
    NSMutableArray *modes = [[_fModes mutableCopy] autorelease];
    if (![modes containsObject:NSConnectionReplyMode]) [modes addObject:NSConnectionReplyMode];
    for (NSString *mode in modes) {
        if (add) [_fReceive scheduleInRunLoop:runLoop forMode:mode];
        else [_fReceive removeFromRunLoop:runLoop forMode:mode];
    }
}

- (void)addRunLoop:(NSRunLoop *)runloop
{
    if (!runloop || [_fRunLoops containsObject:runloop]) return;
    [_fRunLoops addObject:runloop];
    [self _schedule:YES runLoop:runloop];
}

- (void)removeRunLoop:(NSRunLoop *)runloop
{
    if (![_fRunLoops containsObject:runloop]) return;
    [self _schedule:NO runLoop:runloop];
    [_fRunLoops removeObject:runloop];
}

- (void)addRequestMode:(NSString *)rmode
{
    if (!rmode || [_fModes containsObject:rmode]) return;
    [_fModes addObject:rmode];
    for (NSRunLoop *runLoop in _fRunLoops) [_fReceive scheduleInRunLoop:runLoop forMode:rmode];
}

- (void)removeRequestMode:(NSString *)rmode
{
    if (![_fModes containsObject:rmode]) return;
    [_fModes removeObject:rmode];
    for (NSRunLoop *runLoop in _fRunLoops) [_fReceive removeFromRunLoop:runLoop forMode:rmode];
}

- (void)runInNewThread
{
    [self removeRunLoop:[NSRunLoop currentRunLoop]];
    [NSThread detachNewThreadSelector:@selector(_runThread) toTarget:self withObject:nil];
}

- (void)_runThread
{
    @autoreleasepool {
        [self addRunLoop:[NSRunLoop currentRunLoop]];
        while (_fValid) @autoreleasepool { [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]; }
    }
}

- (BOOL)registerName:(NSString *)name { return [self registerName:name withNameServer:[NSPortNameServer systemDefaultPortNameServer]]; }

- (BOOL)registerName:(NSString *)name withNameServer:(NSPortNameServer *)server
{
    if (!name) return NO;
    return [server registerPort:_fReceive name:name];
}

- (void)_portDidBecomeInvalid:(NSNotification *)notification
{
    (void)notification;
    [self invalidate];
}

- (void)invalidate
{
    if (!_fValid) return;
    _fValid = NO;
    [self retain];
    for (NSRunLoop *runLoop in [[_fRunLoops copy] autorelease]) [self removeRunLoop:runLoop];
    if ([_fReceive delegate] == self) [_fReceive setDelegate:nil];
    pthread_mutex_lock(&connections_lock);
    [all_connections removeObjectIdenticalTo:self];
    pthread_mutex_unlock(&connections_lock);
    [_fExported removeAllObjects];
    [_fExportIDs removeAllObjects];
    [[NSNotificationCenter defaultCenter] postNotificationName:NSConnectionDidDieNotification object:self];
    [self release];
}

/* Objects this side exports, and proxies for the other side's. */
- (uint64_t)_exportObject:(id)object
{
    NSValue *key = [NSValue valueWithPointer:object];
    NSNumber *identifier = [_fExportIDs objectForKey:key];
    if (!identifier) {
        identifier = [NSNumber numberWithUnsignedLongLong:_fNextExport++];
        [_fExportIDs setObject:identifier forKey:key];
        [_fExported setObject:object forKey:identifier];
    }
    return [identifier unsignedLongLongValue];
}

- (id)_exportedObject:(uint64_t)identifier { return [_fExported objectForKey:[NSNumber numberWithUnsignedLongLong:identifier]]; }

- (NSDistantObject *)_proxyForRemote:(uint64_t)identifier
{
    NSNumber *key = [NSNumber numberWithUnsignedLongLong:identifier];
    NSDistantObject *proxy = [[_fProxies objectForKey:key] nonretainedObjectValue];
    if (proxy) return [[proxy retain] autorelease];
    proxy = [NSDistantObject proxyWithTarget:key connection:self];
    [_fProxies setObject:[NSValue valueWithNonretainedObject:proxy] forKey:key];
    return proxy;
}

- (void)_forgetProxy:(NSDistantObject *)proxy
{
    NSNumber *key = [NSNumber numberWithUnsignedLongLong:[proxy _remoteID]];
    if ([[_fProxies objectForKey:key] nonretainedObjectValue] == proxy) [_fProxies removeObjectForKey:key];
}

- (NSDistantObject *)rootProxy
{
    if (_fRootProxy && _fValid) return _fRootProxy;
    NSPortCoder *request = [[[NSPortCoder alloc] _initForConnection:self] autorelease];
    uint32_t sequence = ++_fSequence;
    [request _writeBytes:&sequence length:sizeof(sequence)];
    NSPortCoder *reply = [self _send:request msgid:DORootRequest wait:YES sequence:sequence];
    uint8_t status = 0;
    [reply _readBytes:&status length:1];
    _fRootProxy = [reply decodeObject];
    return _fRootProxy;
}

- (NSString *)_remoteTypesForSelector:(SEL)sel target:(uint64_t)identifier
{
    NSPortCoder *request = [[[NSPortCoder alloc] _initForConnection:self] autorelease];
    uint32_t sequence = ++_fSequence;
    [request _writeBytes:&sequence length:sizeof(sequence)];
    [request _writeBytes:&identifier length:sizeof(identifier)];
    [request _writeString:NSStringFromSelector(sel)];
    NSPortCoder *reply = [self _send:request msgid:DOSignatureRequest wait:YES sequence:sequence];
    uint8_t status = 0;
    [reply _readBytes:&status length:1];
    return [reply _readString];
}

/* Sends a message and, if asked, runs the run loop until its reply arrives. */
- (NSPortCoder *)_send:(NSPortCoder *)coder msgid:(uint32_t)msgid wait:(BOOL)wait sequence:(uint32_t)sequence
{
    if (!_fValid) FinchRaise(NSInvalidSendPortException, "*** -[NSConnection sendInvocation:]: connection went invalid while waiting for a reply");
    NSPortMessage *message = [[[NSPortMessage alloc] initWithSendPort:_fSend receivePort:_fReceive components:[coder _components]] autorelease];
    [message setMsgid:msgid];
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:_fRequestTimeout];
    if (![message sendBeforeDate:limit]) FinchRaise(NSPortTimeoutException, "*** [NSConnection sendInvocation:]: timed out");
    if (msgid == DORequest) _fRequestsSent++;
    if (!wait) return nil;
    NSNumber *key = [NSNumber numberWithUnsignedInt:sequence];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:_fReplyTimeout];
    NSRunLoop *runLoop = [NSRunLoop currentRunLoop];
    BOOL scheduled = ![_fRunLoops containsObject:runLoop];
    if (scheduled) [_fReceive scheduleInRunLoop:runLoop forMode:NSConnectionReplyMode];
    NSPortCoder *reply = nil;
    while (!(reply = [_fReplies objectForKey:key])) {
        if (!_fValid) {
            if (scheduled) [_fReceive removeFromRunLoop:runLoop forMode:NSConnectionReplyMode];
            FinchRaise(NSInvalidReceivePortException, "*** -[NSConnection sendInvocation:]: connection went invalid while waiting for a reply");
        }
        if ([deadline timeIntervalSinceNow] <= 0) {
            if (scheduled) [_fReceive removeFromRunLoop:runLoop forMode:NSConnectionReplyMode];
            FinchRaise(NSPortTimeoutException, "*** [NSConnection sendInvocation:]: timed out waiting for a reply");
        }
        @autoreleasepool { [runLoop runMode:NSConnectionReplyMode beforeDate:deadline]; }
    }
    if (scheduled) [_fReceive removeFromRunLoop:runLoop forMode:NSConnectionReplyMode];
    [[reply retain] autorelease];
    [_fReplies removeObjectForKey:key];
    _fRepliesReceived++;
    return reply;
}

static void
encode_arguments(NSPortCoder *coder, NSInvocation *invocation, BOOL reply)
{
    NSMethodSignature *signature = [invocation methodSignature];
    NSUInteger count = [signature numberOfArguments];
    for (NSUInteger i = 2; i < count; i++) {
        const char *full = [signature getArgumentTypeAtIndex:i];
        const char *type = skip_qualifiers(full);
        BOOL out = has_qualifier(full, 'o'), inout = has_qualifier(full, 'N'), in = has_qualifier(full, 'n');
        if (*type == '^' && type[1] != '?' && type[1] != 'v') {
            if (reply && !(out || inout)) continue;
            if (!reply && out) {
                void *p = NULL;
                [invocation getArgument:&p atIndex:(NSInteger)i];
                uint8_t present = p != NULL;
                [coder _writeBytes:&present length:1];
                continue;
            }
            void *p = NULL;
            [invocation getArgument:&p atIndex:(NSInteger)i];
            uint8_t present = p != NULL;
            [coder _writeBytes:&present length:1];
            if (p && (reply || in || inout || !out)) [coder encodeValueOfObjCType:type + 1 at:p];
            continue;
        }
        if (reply) continue;
        NSUInteger size = type_size(type);
        void *buffer = calloc(1, size ? size : 1);
        [invocation getArgument:buffer atIndex:(NSInteger)i];
        if (*type == '@') {
            if (has_qualifier(full, 'O')) [coder encodeBycopyObject:*(id *)buffer];
            else if (has_qualifier(full, 'R')) [coder encodeByrefObject:*(id *)buffer];
            else [coder encodeObject:*(id *)buffer];
        } else {
            [coder encodeValueOfObjCType:type at:buffer];
        }
        free(buffer);
    }
}

- (void)_forwardInvocation:(NSInvocation *)invocation toRemote:(uint64_t)identifier
{
    NSMethodSignature *signature = [invocation methodSignature];
    NSPortCoder *request = [[[NSPortCoder alloc] _initForConnection:self] autorelease];
    uint32_t sequence = ++_fSequence;
    [request _writeBytes:&sequence length:sizeof(sequence)];
    [request _writeBytes:&identifier length:sizeof(identifier)];
    [request _writeString:NSStringFromSelector([invocation selector])];
    [request _writeString:[NSString stringWithUTF8String:[signature _typeString]]];
    encode_arguments(request, invocation, NO);
    BOOL oneway = [signature isOneway];
    NSPortCoder *reply = [self _send:request msgid:DORequest wait:!oneway sequence:sequence];
    if (oneway) return;
    uint8_t status = 0;
    [reply _readBytes:&status length:1];
    if (status) {
        NSString *name = [reply _readString], *reason = [reply _readString];
        NSDictionary *info = [reply decodeObject];
        @throw [NSException exceptionWithName:name ?: NSGenericException
                                       reason:[ServerNote stringByAppendingString:reason ?: @""] userInfo:info];
    }
    const char *returnType = skip_qualifiers([signature methodReturnType]);
    if (*returnType != 'v') {
        NSUInteger size = type_size(returnType);
        void *buffer = calloc(1, size ? size : 1);
        [reply decodeValueOfObjCType:returnType at:buffer size:size];
        [invocation setReturnValue:buffer];
        free(buffer);
    }
    NSUInteger count = [signature numberOfArguments];
    for (NSUInteger i = 2; i < count; i++) {
        const char *full = [signature getArgumentTypeAtIndex:i];
        const char *type = skip_qualifiers(full);
        if (*type != '^' || type[1] == '?' || type[1] == 'v' || !(has_qualifier(full, 'o') || has_qualifier(full, 'N'))) continue;
        uint8_t present = 0;
        [reply _readBytes:&present length:1];
        void *p = NULL;
        [invocation getArgument:&p atIndex:(NSInteger)i];
        if (present) {
            NSUInteger size = type_size(type + 1);
            void *scratch = calloc(1, size ? size : 1);
            [reply decodeValueOfObjCType:type + 1 at:scratch size:size];
            if (p) memcpy(p, scratch, size);
            free(scratch);
        }
    }
}

- (void)dispatchWithComponents:(NSArray *)components { [self _handleComponents:components msgid:DORequest]; }

/* The receive port's messages: the connection to the sender handles them,
 * made as a child of this one when the sender is new. */
- (void)handlePortMessage:(NSPortMessage *)message
{
    NSPort *peer = [message sendPort];
    NSConnection *connection = self;
    if (peer && ![peer isEqual:_fSend]) {
        connection = find_connection(_fReceive, peer);
        if (!connection) {
            connection = [[[NSConnection alloc] _initChildOf:self sendPort:peer] autorelease];
            BOOL allowed = YES;
            if ([_fDelegate respondsToSelector:@selector(connection:shouldMakeNewConnection:)])
                allowed = [_fDelegate connection:self shouldMakeNewConnection:connection];
            else if ([_fDelegate respondsToSelector:@selector(makeNewConnection:sender:)])
                allowed = [_fDelegate makeNewConnection:connection sender:self];
            if (!allowed) {
                [connection invalidate];
                return;
            }
        }
    }
    [connection _handleComponents:[message components] msgid:[message msgid]];
}

- (void)_sendReply:(NSPortCoder *)reply
{
    NSPortMessage *message = [[[NSPortMessage alloc] initWithSendPort:_fSend receivePort:_fReceive components:[reply _components]] autorelease];
    [message setMsgid:DOReply];
    [message sendBeforeDate:[NSDate dateWithTimeIntervalSinceNow:_fRequestTimeout]];
    _fRepliesSent++;
}

- (void)_handleComponents:(NSArray *)components msgid:(uint32_t)msgid
{
    NSPortCoder *coder = [[[NSPortCoder alloc] _initWithComponents:components connection:self] autorelease];
    uint32_t sequence = 0;
    [coder _readBytes:&sequence length:sizeof(sequence)];
    if (msgid == DOReply) {
        [_fReplies setObject:coder forKey:[NSNumber numberWithUnsignedInt:sequence]];
        return;
    }
    NSPortCoder *reply = [[[NSPortCoder alloc] _initForConnection:self] autorelease];
    [reply _writeBytes:&sequence length:sizeof(sequence)];
    uint8_t ok = 0;
    if (msgid == DORootRequest) {
        [reply _writeBytes:&ok length:1];
        [reply encodeByrefObject:_fRoot];
        [self _sendReply:reply];
        return;
    }
    uint64_t identifier = 0;
    [coder _readBytes:&identifier length:sizeof(identifier)];
    NSString *selectorName = [coder _readString];
    id target = [self _exportedObject:identifier];
    if (msgid == DOSignatureRequest) {
        NSMethodSignature *signature = [target methodSignatureForSelector:NSSelectorFromString(selectorName)];
        [reply _writeBytes:&ok length:1];
        [reply _writeString:signature ? [NSString stringWithUTF8String:[signature _typeString]] : nil];
        [self _sendReply:reply];
        return;
    }
    if (msgid != DORequest) return;
    _fRequestsReceived++;
    NSString *types = [coder _readString];
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:[types UTF8String]];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    SEL sel = NSSelectorFromString(selectorName);
    [invocation setSelector:sel];
    NSMutableArray *storage = [NSMutableArray array];
    NSUInteger count = [signature numberOfArguments];
    for (NSUInteger i = 2; i < count; i++) {
        const char *full = [signature getArgumentTypeAtIndex:i];
        const char *type = skip_qualifiers(full);
        if (*type == '^' && type[1] != '?' && type[1] != 'v') {
            uint8_t present = 0;
            [coder _readBytes:&present length:1];
            void *p = NULL;
            if (present) {
                NSUInteger size = type_size(type + 1);
                NSMutableData *cell = [NSMutableData dataWithLength:size ? size : 1];
                [storage addObject:cell];
                p = [cell mutableBytes];
                if (!has_qualifier(full, 'o')) [coder decodeValueOfObjCType:type + 1 at:p size:size];
            }
            [invocation setArgument:&p atIndex:(NSInteger)i];
            continue;
        }
        NSUInteger size = type_size(type);
        NSMutableData *cell = [NSMutableData dataWithLength:size ? size : 1];
        [coder decodeValueOfObjCType:type at:[cell mutableBytes] size:size];
        [invocation setArgument:[cell mutableBytes] atIndex:(NSInteger)i];
    }
    [invocation retainArguments];
    NSException *failure = nil;
    @try {
        if (!target) FinchRaise(NSInvalidArgumentException, "*** NSConnection: no object for this proxy");
        [invocation invokeWithTarget:target];
    } @catch (NSException *exception) {
        failure = exception;
    }
    if ([signature isOneway]) return;
    if (failure) {
        uint8_t status = 1;
        [reply _writeBytes:&status length:1];
        [reply _writeString:[failure name]];
        [reply _writeString:[failure reason]];
        [reply encodeObject:[failure userInfo]];
        [self _sendReply:reply];
        return;
    }
    [reply _writeBytes:&ok length:1];
    const char *returnType = skip_qualifiers([signature methodReturnType]);
    if (*returnType != 'v') {
        NSUInteger size = type_size(returnType);
        void *buffer = calloc(1, size ? size : 1);
        [invocation getReturnValue:buffer];
        if (*returnType == '@' && has_qualifier([signature methodReturnType], 'O')) [reply encodeBycopyObject:*(id *)buffer];
        else if (*returnType == '@' && has_qualifier([signature methodReturnType], 'R')) [reply encodeByrefObject:*(id *)buffer];
        else [reply encodeValueOfObjCType:returnType at:buffer];
        free(buffer);
    }
    encode_arguments(reply, invocation, YES);
    [self _sendReply:reply];
}

@end

/* MARK: - Port name servers */

@implementation NSPortNameServer
+ (NSPortNameServer *)systemDefaultPortNameServer { return [NSMachBootstrapServer sharedInstance]; }
- (NSPort *)portForName:(NSString *)name { return [self portForName:name host:nil]; }
- (NSPort *)portForName:(NSString *)name host:(NSString *)host { (void)name; (void)host; return nil; }
- (BOOL)registerPort:(NSPort *)port name:(NSString *)name { (void)port; (void)name; return NO; }
- (BOOL)removePortForName:(NSString *)name { (void)name; return NO; }
@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

/* Names in the bootstrap namespace, as Apple's Mach name server keeps them. */
@implementation NSMachBootstrapServer
+ (id)sharedInstance
{
    static NSMachBootstrapServer *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[NSMachBootstrapServer alloc] init]; });
    return shared;
}
- (NSPort *)portForName:(NSString *)name { return [self portForName:name host:nil]; }
- (NSPort *)portForName:(NSString *)name host:(NSString *)host
{
    if (!name || (host.length && ![host isEqualToString:@"*"])) return nil;
    mach_port_t port = MACH_PORT_NULL;
    if (bootstrap_look_up(bootstrap_port, [name UTF8String], &port) != KERN_SUCCESS || port == MACH_PORT_NULL) return nil;
    return [NSMachPort portWithMachPort:port];
}
- (NSPort *)servicePortWithName:(NSString *)name
{
    mach_port_t port = MACH_PORT_NULL;
    if (!name || bootstrap_check_in(bootstrap_port, [name UTF8String], &port) != KERN_SUCCESS) return nil;
    return [NSMachPort portWithMachPort:port options:NSMachPortDeallocateReceiveRight];
}
- (BOOL)registerPort:(NSPort *)port name:(NSString *)name
{
    if (![port isKindOfClass:[NSMachPort class]] || !name) return NO;
    return bootstrap_register(bootstrap_port, (char *)[name UTF8String], [(NSMachPort *)port machPort]) == KERN_SUCCESS;
}
- (BOOL)removePortForName:(NSString *)name
{
    if (!name) return NO;
    return bootstrap_register(bootstrap_port, (char *)[name UTF8String], MACH_PORT_NULL) == KERN_SUCCESS;
}
@end

#pragma clang diagnostic pop

/* Message ports and socket ports carry no Distributed Objects traffic in
 * Finch: their name servers know no names. */
@implementation NSMessagePortNameServer
+ (id)sharedInstance
{
    static NSMessagePortNameServer *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[NSMessagePortNameServer alloc] init]; });
    return shared;
}
- (NSPort *)portForName:(NSString *)name { return [self portForName:name host:nil]; }
- (NSPort *)portForName:(NSString *)name host:(NSString *)host { (void)name; (void)host; return nil; }
@end

@implementation NSSocketPortNameServer {
    uint16_t _fDefaultPort;
}
+ (id)sharedInstance
{
    static NSSocketPortNameServer *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[NSSocketPortNameServer alloc] init]; });
    return shared;
}
- (NSPort *)portForName:(NSString *)name { return [self portForName:name host:nil]; }
- (NSPort *)portForName:(NSString *)name host:(NSString *)host { (void)name; (void)host; return nil; }
- (NSPort *)portForName:(NSString *)name host:(NSString *)host nameServerPortNumber:(uint16_t)portNumber
{
    (void)portNumber;
    return [self portForName:name host:host];
}
- (BOOL)registerPort:(NSPort *)port name:(NSString *)name { (void)port; (void)name; return NO; }
- (BOOL)registerPort:(NSPort *)port name:(NSString *)name nameServerPortNumber:(uint16_t)portNumber
{
    (void)portNumber;
    return [self registerPort:port name:name];
}
- (BOOL)removePortForName:(NSString *)name { (void)name; return NO; }
- (uint16_t)defaultNameServerPortNumber { return _fDefaultPort; }
- (void)setDefaultNameServerPortNumber:(uint16_t)value { _fDefaultPort = value; }
@end
