/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSMessagePort over CFMessagePort and NSSocketPort over TCP sockets.
 *
 * Both carry NSPortMessage components (data and ports) in a framing of
 * Finch's own: a message is its msgid, the reply port, and each component as
 * data or a port description. A message port is described by its name; a
 * socket port by its family, type, protocol and address, with a listening
 * port's wildcard address replaced by the address the connection reached.
 * Remote ports are kept one object per name or address, as Apple's are.
 */

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>
#include <pthread.h>
#include <sys/socket.h>
#include <unistd.h>
#include "Foundation_Finch.h"

@interface NSRunLoop (FinchCF)
- (CFRunLoopRef)getCFRunLoop;
@end

/* MARK: - Framing */

static void
put32(NSMutableData *data, uint32_t value)
{
    [data appendBytes:&value length:sizeof(value)];
}

static BOOL
get32(NSData *data, NSUInteger *at, uint32_t *value)
{
    if (*at + sizeof(*value) > [data length]) return NO;
    memcpy(value, (const uint8_t *)[data bytes] + *at, sizeof(*value));
    *at += sizeof(*value);
    return YES;
}

static void
put_bytes(NSMutableData *data, NSData *bytes)
{
    put32(data, (uint32_t)[bytes length]);
    [data appendData:bytes];
}

static NSData *
get_bytes(NSData *data, NSUInteger *at)
{
    uint32_t length = 0;
    if (!get32(data, at, &length) || *at + length > [data length]) return nil;
    NSData *bytes = [data subdataWithRange:NSMakeRange(*at, length)];
    *at += length;
    return bytes;
}

/* MARK: - NSMessagePort */

static NSMutableDictionary *message_remotes;   /* name -> NSValue (weak) */
static pthread_mutex_t message_lock = PTHREAD_MUTEX_INITIALIZER;

@interface NSMessagePort (Finch)
- (instancetype)_initRemoteWithName:(NSString *)name;
- (NSString *)_name;
- (BOOL)_setName:(NSString *)name;
@end

static NSMessagePort *
message_port_named(NSString *name)
{
    if (!name.length) return nil;
    pthread_mutex_lock(&message_lock);
    NSMessagePort *port = [[[message_remotes objectForKey:name] nonretainedObjectValue] retain];
    pthread_mutex_unlock(&message_lock);
    if (port) return [port autorelease];
    return [[[NSMessagePort alloc] _initRemoteWithName:name] autorelease];
}

static CFDataRef message_received(CFMessagePortRef local, SInt32 msgid, CFDataRef data, void *info);

@implementation NSMessagePort {
    CFMessagePortRef _fPort;
    CFRunLoopSourceRef _fSource;
    id _fDelegate;
    BOOL _fRemote;
}

- (instancetype)init
{
    if ((self = [super init])) {
        CFMessagePortContext context = { 0, self, NULL, NULL, NULL };
        _fPort = CFMessagePortCreateLocal(NULL, NULL, message_received, &context, NULL);
        if (!_fPort) { [self release]; return nil; }
    }
    return self;
}

- (instancetype)_initRemoteWithName:(NSString *)name
{
    if ((self = [super init])) {
        _fPort = CFMessagePortCreateRemote(NULL, (CFStringRef)name);
        if (!_fPort) { [self release]; return nil; }
        _fRemote = YES;
        pthread_mutex_lock(&message_lock);
        if (!message_remotes) message_remotes = [[NSMutableDictionary alloc] init];
        [message_remotes setObject:[NSValue valueWithNonretainedObject:self] forKey:name];
        pthread_mutex_unlock(&message_lock);
    }
    return self;
}

- (void)dealloc
{
    if (_fRemote) {
        NSString *name = [self _name];
        pthread_mutex_lock(&message_lock);
        if (name && [[message_remotes objectForKey:name] nonretainedObjectValue] == self) [message_remotes removeObjectForKey:name];
        pthread_mutex_unlock(&message_lock);
    }
    if (_fSource) CFRelease(_fSource);
    if (_fPort) {
        if (!_fRemote) CFMessagePortInvalidate(_fPort);
        CFRelease(_fPort);
    }
    [super dealloc];
}

- (NSString *)_name { return _fPort ? [[(NSString *)CFMessagePortGetName(_fPort) copy] autorelease] : nil; }
- (BOOL)_setName:(NSString *)name { return !_fRemote && _fPort && CFMessagePortSetName(_fPort, (CFStringRef)name); }
- (id)delegate { return _fDelegate; }
- (void)setDelegate:(id)delegate { _fDelegate = delegate; }
- (BOOL)isValid { return _fPort && CFMessagePortIsValid(_fPort); }

- (void)invalidate
{
    if (![self isValid]) return;
    CFMessagePortInvalidate(_fPort);
    [[NSNotificationCenter defaultCenter] postNotificationName:NSPortDidBecomeInvalidNotification object:self];
}

- (void)scheduleInRunLoop:(NSRunLoop *)runLoop forMode:(NSRunLoopMode)mode
{
    if (_fRemote || !_fPort) return;
    if (!_fSource) _fSource = CFMessagePortCreateRunLoopSource(NULL, _fPort, 0);
    if (_fSource) CFRunLoopAddSource([runLoop getCFRunLoop], _fSource, (CFStringRef)mode);
}

- (void)removeFromRunLoop:(NSRunLoop *)runLoop forMode:(NSRunLoopMode)mode
{
    if (_fSource) CFRunLoopRemoveSource([runLoop getCFRunLoop], _fSource, (CFStringRef)mode);
}

- (NSUInteger)hash { return [[self _name] hash] ?: (NSUInteger)_fPort; }
- (BOOL)isEqual:(id)object
{
    if (object == self) return YES;
    if (![object isKindOfClass:[NSMessagePort class]]) return NO;
    NSString *name = [self _name];
    return name && [name isEqualToString:[object _name]];
}

- (BOOL)sendBeforeDate:(NSDate *)limitDate msgid:(NSUInteger)msgID components:(NSMutableArray *)components from:(NSPort *)receivePort reserved:(NSUInteger)headerSpaceReserved
{
    (void)headerSpaceReserved;
    if (![self isValid]) return NO;
    NSMutableData *data = [NSMutableData data];
    NSString *reply = [receivePort isKindOfClass:[NSMessagePort class]] ? [(NSMessagePort *)receivePort _name] : nil;
    put_bytes(data, [reply ?: @"" dataUsingEncoding:NSUTF8StringEncoding]);
    put32(data, (uint32_t)[components count]);
    for (id component in components) {
        if ([component isKindOfClass:[NSMessagePort class]]) {
            put32(data, 'P');
            put_bytes(data, [[component _name] ?: @"" dataUsingEncoding:NSUTF8StringEncoding]);
        } else if ([component isKindOfClass:[NSData class]]) {
            put32(data, 'D');
            put_bytes(data, component);
        } else {
            put32(data, '-');
        }
    }
    double wait = limitDate ? [limitDate timeIntervalSinceNow] : 0;
    if (wait > 1e6) wait = 1e6;
    SInt32 result = CFMessagePortSendRequest(_fPort, (SInt32)msgID, (CFDataRef)data, wait > 0 ? wait : 0, 0, NULL, NULL);
    if (result == kCFMessagePortSendTimeout) FinchRaise(NSPortTimeoutException, "[NSMessagePort sendBeforeDate:] timed out");
    return result == kCFMessagePortSuccess;
}

- (BOOL)sendBeforeDate:(NSDate *)limitDate components:(NSMutableArray *)components from:(NSPort *)receivePort reserved:(NSUInteger)headerSpaceReserved
{
    return [self sendBeforeDate:limitDate msgid:0 components:components from:receivePort reserved:headerSpaceReserved];
}

@end

static CFDataRef
message_received(CFMessagePortRef local, SInt32 msgid, CFDataRef data, void *info)
{
    (void)local;
    @autoreleasepool {
        NSMessagePort *port = info;
        NSData *bytes = (NSData *)data;
        NSUInteger at = 0;
        NSData *replyName = get_bytes(bytes, &at);
        uint32_t count = 0;
        get32(bytes, &at, &count);
        NSMutableArray *components = [NSMutableArray array];
        for (uint32_t i = 0; i < count; i++) {
            uint32_t kind = 0;
            if (!get32(bytes, &at, &kind)) break;
            if (kind == 'D') {
                NSData *component = get_bytes(bytes, &at);
                if (component) [components addObject:component];
            } else if (kind == 'P') {
                NSString *name = [[[NSString alloc] initWithData:get_bytes(bytes, &at) encoding:NSUTF8StringEncoding] autorelease];
                NSPort *component = message_port_named(name);
                if (component) [components addObject:component];
            }
        }
        NSString *reply = replyName ? [[[NSString alloc] initWithData:replyName encoding:NSUTF8StringEncoding] autorelease] : nil;
        NSPortMessage *message = [[[NSPortMessage alloc] initWithSendPort:message_port_named(reply) receivePort:port components:components] autorelease];
        [message setMsgid:(uint32_t)msgid];
        id delegate = [port delegate];
        if ([delegate respondsToSelector:@selector(handlePortMessage:)]) [delegate handlePortMessage:message];
    }
    return NULL;
}

/* MARK: - NSSocketPort */

static NSMutableDictionary *socket_remotes;   /* description -> NSValue (weak) */
static pthread_mutex_t socket_lock = PTHREAD_MUTEX_INITIALIZER;

@interface NSSocketPort (Finch)
- (void)_received:(NSData *)bytes onConnection:(CFSocketRef)connection;
- (void)_accepted:(int)fd;
- (NSData *)_describeAs:(const struct sockaddr *)reached;
- (void)_close;
@end

static NSString *
socket_key(int family, int type, int protocol, NSData *address)
{
    return [NSString stringWithFormat:@"%d/%d/%d/%@", family, type, protocol, address];
}

static void
socket_accepted(CFSocketRef s, CFSocketCallBackType type, CFDataRef address, const void *data, void *info)
{
    (void)s; (void)address;
    if (type == kCFSocketAcceptCallBack) [(NSSocketPort *)info _accepted:*(const int *)data];
}

static void
socket_data(CFSocketRef s, CFSocketCallBackType type, CFDataRef address, const void *data, void *info)
{
    (void)address;
    if (type == kCFSocketDataCallBack) @autoreleasepool { [(NSSocketPort *)info _received:(NSData *)data onConnection:s]; }
}

@implementation NSSocketPort {
    int _fFamily, _fType, _fProtocol;
    NSData *_fAddress;
    int _fListen;
    CFSocketRef _fListener;
    CFRunLoopSourceRef _fListenSource;
    NSMutableArray *_fScheduled;          /* [runloop, mode] pairs */
    NSMutableArray *_fIncoming;           /* CFSocketRef of accepted connections */
    NSMutableDictionary *_fBuffers;       /* NSValue(CFSocketRef) -> NSMutableData */
    NSMutableDictionary *_fSources;       /* NSValue(CFSocketRef) -> NSValue(CFRunLoopSourceRef) */
    int _fOutgoing;                       /* a remote port's connection */
    id _fDelegate;
    BOOL _fRemote, _fValid;
}

- (instancetype)init { return [self initWithTCPPort:0]; }

- (instancetype)initWithTCPPort:(unsigned short)port
{
    struct sockaddr_in address = { .sin_len = sizeof(address), .sin_family = AF_INET, .sin_port = htons(port), .sin_addr.s_addr = htonl(INADDR_ANY) };
    return [self initWithProtocolFamily:AF_INET socketType:SOCK_STREAM protocol:IPPROTO_TCP
                                address:[NSData dataWithBytes:&address length:sizeof(address)]];
}

- (instancetype)initWithProtocolFamily:(int)family socketType:(int)type protocol:(int)protocol address:(NSData *)address
{
    int fd = socket(family, type, protocol);
    if (fd < 0) { [self release]; return nil; }
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    if (bind(fd, [address bytes], (socklen_t)[address length]) != 0 || (type == SOCK_STREAM && listen(fd, 16) != 0)) {
        close(fd);
        [self release];
        return nil;
    }
    return [self initWithProtocolFamily:family socketType:type protocol:protocol socket:fd];
}

- (instancetype)initWithProtocolFamily:(int)family socketType:(int)type protocol:(int)protocol socket:(NSSocketNativeHandle)sock
{
    if (!(self = [super init])) return nil;
    _fFamily = family;
    _fType = type;
    _fProtocol = protocol;
    _fListen = sock;
    _fOutgoing = -1;
    _fValid = YES;
    struct sockaddr_storage storage;
    socklen_t length = sizeof(storage);
    if (getsockname(sock, (struct sockaddr *)&storage, &length) == 0) _fAddress = [[NSData alloc] initWithBytes:&storage length:length];
    CFSocketContext context = { 0, self, NULL, NULL, NULL };
    _fListener = CFSocketCreateWithNative(NULL, sock, kCFSocketAcceptCallBack, socket_accepted, &context);
    _fScheduled = [[NSMutableArray alloc] init];
    _fIncoming = [[NSMutableArray alloc] init];
    _fBuffers = [[NSMutableDictionary alloc] init];
    _fSources = [[NSMutableDictionary alloc] init];
    return self;
}

- (instancetype)initRemoteWithTCPPort:(unsigned short)port host:(NSString *)hostName
{
    struct addrinfo hints = { .ai_family = AF_INET, .ai_socktype = SOCK_STREAM }, *found = NULL;
    const char *host = hostName.length ? [hostName UTF8String] : "localhost";
    if (getaddrinfo(host, NULL, &hints, &found) != 0 || !found) { [self release]; return nil; }
    struct sockaddr_in address = *(struct sockaddr_in *)found->ai_addr;
    freeaddrinfo(found);
    address.sin_port = htons(port);
    address.sin_len = sizeof(address);
    return [self initRemoteWithProtocolFamily:AF_INET socketType:SOCK_STREAM protocol:IPPROTO_TCP
                                      address:[NSData dataWithBytes:&address length:sizeof(address)]];
}

- (instancetype)initRemoteWithProtocolFamily:(int)family socketType:(int)type protocol:(int)protocol address:(NSData *)address
{
    NSString *key = socket_key(family, type, protocol, address);
    pthread_mutex_lock(&socket_lock);
    NSSocketPort *existing = [[[socket_remotes objectForKey:key] nonretainedObjectValue] retain];
    if (!existing && (self = [super init])) {
        _fFamily = family;
        _fType = type;
        _fProtocol = protocol;
        _fAddress = [address copy];
        _fListen = -1;
        _fOutgoing = -1;
        _fRemote = YES;
        _fValid = YES;
        if (!socket_remotes) socket_remotes = [[NSMutableDictionary alloc] init];
        [socket_remotes setObject:[NSValue valueWithNonretainedObject:self] forKey:key];
    }
    pthread_mutex_unlock(&socket_lock);
    if (existing) {
        [self release];
        return existing;
    }
    return self;
}

- (void)dealloc
{
    if (_fRemote) {
        NSString *key = socket_key(_fFamily, _fType, _fProtocol, _fAddress);
        pthread_mutex_lock(&socket_lock);
        if ([[socket_remotes objectForKey:key] nonretainedObjectValue] == self) [socket_remotes removeObjectForKey:key];
        pthread_mutex_unlock(&socket_lock);
    }
    [self _close];
    [_fAddress release];
    [_fScheduled release];
    [_fIncoming release];
    [_fBuffers release];
    [_fSources release];
    [super dealloc];
}

- (int)protocolFamily { return _fFamily; }
- (int)socketType { return _fType; }
- (int)protocol { return _fProtocol; }
- (NSData *)address { return _fAddress; }
- (NSSocketNativeHandle)socket { return _fRemote ? -1 : _fListen; }
- (id)delegate { return _fDelegate; }
- (void)setDelegate:(id)delegate { _fDelegate = delegate; }
- (BOOL)isValid { return _fValid; }
- (NSUInteger)hash { return [_fAddress hash]; }

- (BOOL)isEqual:(id)object
{
    if (object == self) return YES;
    if (![object isKindOfClass:[NSSocketPort class]]) return NO;
    NSSocketPort *other = object;
    return other->_fRemote == _fRemote && other->_fFamily == _fFamily && other->_fType == _fType &&
           other->_fProtocol == _fProtocol && [other->_fAddress isEqual:_fAddress];
}

- (void)invalidate
{
    if (!_fValid) return;
    [self _close];
    [[NSNotificationCenter defaultCenter] postNotificationName:NSPortDidBecomeInvalidNotification object:self];
}

- (void)_close
{
    if (!_fValid) return;
    _fValid = NO;
    if (_fListener) { CFSocketInvalidate(_fListener); CFRelease(_fListener); _fListener = NULL; }
    if (_fListenSource) { CFRelease(_fListenSource); _fListenSource = NULL; }
    for (id connection in [[_fIncoming copy] autorelease]) CFSocketInvalidate((CFSocketRef)connection);
    [_fIncoming removeAllObjects];
    for (NSValue *source in [_fSources allValues]) CFRelease([source pointerValue]);
    [_fSources removeAllObjects];
    if (_fOutgoing >= 0) { close(_fOutgoing); _fOutgoing = -1; }
}

- (void)_addSource:(CFRunLoopSourceRef)source
{
    for (NSArray *pair in _fScheduled)
        CFRunLoopAddSource([[pair objectAtIndex:0] getCFRunLoop], source, (CFStringRef)[pair objectAtIndex:1]);
}

- (void)scheduleInRunLoop:(NSRunLoop *)runLoop forMode:(NSRunLoopMode)mode
{
    if (_fRemote || !_fListener) return;
    NSArray *pair = [NSArray arrayWithObjects:runLoop, mode, nil];
    if ([_fScheduled containsObject:pair]) return;
    [_fScheduled addObject:pair];
    if (!_fListenSource) _fListenSource = CFSocketCreateRunLoopSource(NULL, _fListener, 0);
    CFRunLoopAddSource([runLoop getCFRunLoop], _fListenSource, (CFStringRef)mode);
    for (NSValue *source in [_fSources allValues]) CFRunLoopAddSource([runLoop getCFRunLoop], [source pointerValue], (CFStringRef)mode);
}

- (void)removeFromRunLoop:(NSRunLoop *)runLoop forMode:(NSRunLoopMode)mode
{
    NSArray *pair = [NSArray arrayWithObjects:runLoop, mode, nil];
    [_fScheduled removeObject:pair];
    if (_fListenSource) CFRunLoopRemoveSource([runLoop getCFRunLoop], _fListenSource, (CFStringRef)mode);
    for (NSValue *source in [_fSources allValues]) CFRunLoopRemoveSource([runLoop getCFRunLoop], [source pointerValue], (CFStringRef)mode);
}

- (void)_accepted:(int)fd
{
    CFSocketContext context = { 0, self, NULL, NULL, NULL };
    CFSocketRef connection = CFSocketCreateWithNative(NULL, fd, kCFSocketDataCallBack, socket_data, &context);
    if (!connection) { close(fd); return; }
    [_fIncoming addObject:(id)connection];
    CFRunLoopSourceRef source = CFSocketCreateRunLoopSource(NULL, connection, 0);
    [_fSources setObject:[NSValue valueWithPointer:source] forKey:[NSValue valueWithPointer:connection]];
    [_fBuffers setObject:[NSMutableData data] forKey:[NSValue valueWithPointer:connection]];
    [self _addSource:source];
    CFRelease(connection);
}

/* A port as the peer should reach it: a listening port's wildcard address
 * becomes the address this connection's peer reached. */
- (NSData *)_describeAs:(const struct sockaddr *)reached
{
    NSMutableData *address = [[_fAddress mutableCopy] autorelease];
    if (reached && _fFamily == AF_INET && [address length] >= sizeof(struct sockaddr_in)) {
        struct sockaddr_in *own = [address mutableBytes];
        if (own->sin_addr.s_addr == htonl(INADDR_ANY)) own->sin_addr = ((const struct sockaddr_in *)reached)->sin_addr;
    }
    NSMutableData *description = [NSMutableData data];
    put32(description, (uint32_t)_fFamily);
    put32(description, (uint32_t)_fType);
    put32(description, (uint32_t)_fProtocol);
    put_bytes(description, address);
    return description;
}

static NSSocketPort *
socket_port_described(NSData *data, NSUInteger *at)
{
    uint32_t family = 0, type = 0, protocol = 0;
    if (!get32(data, at, &family) || !get32(data, at, &type) || !get32(data, at, &protocol)) return nil;
    NSData *address = get_bytes(data, at);
    if (!address.length) return nil;
    return [[[NSSocketPort alloc] initRemoteWithProtocolFamily:(int)family socketType:(int)type protocol:(int)protocol address:address] autorelease];
}

- (void)_received:(NSData *)bytes onConnection:(CFSocketRef)connection
{
    NSValue *key = [NSValue valueWithPointer:connection];
    if (![bytes length]) {
        NSValue *source = [_fSources objectForKey:key];
        if (source) {
            CFRunLoopSourceInvalidate([source pointerValue]);
            CFRelease([source pointerValue]);
        }
        [_fSources removeObjectForKey:key];
        [_fBuffers removeObjectForKey:key];
        CFSocketInvalidate(connection);
        [_fIncoming removeObjectIdenticalTo:(id)connection];
        return;
    }
    NSMutableData *buffer = [_fBuffers objectForKey:key];
    [buffer appendData:bytes];
    for (;;) {
        NSUInteger at = 0;
        uint32_t length = 0;
        if (!get32(buffer, &at, &length) || [buffer length] < at + length) return;
        NSData *frame = [buffer subdataWithRange:NSMakeRange(at, length)];
        [buffer replaceBytesInRange:NSMakeRange(0, at + length) withBytes:NULL length:0];
        NSUInteger offset = 0;
        uint32_t msgid = 0, hasReply = 0, count = 0;
        get32(frame, &offset, &msgid);
        get32(frame, &offset, &hasReply);
        NSSocketPort *reply = hasReply ? socket_port_described(frame, &offset) : nil;
        get32(frame, &offset, &count);
        NSMutableArray *components = [NSMutableArray array];
        for (uint32_t i = 0; i < count; i++) {
            uint32_t kind = 0;
            if (!get32(frame, &offset, &kind)) break;
            if (kind == 'D') {
                NSData *component = get_bytes(frame, &offset);
                if (component) [components addObject:component];
            } else if (kind == 'P') {
                NSSocketPort *component = socket_port_described(frame, &offset);
                if (component) [components addObject:component];
            }
        }
        NSPortMessage *message = [[[NSPortMessage alloc] initWithSendPort:reply receivePort:self components:components] autorelease];
        [message setMsgid:msgid];
        if ([_fDelegate respondsToSelector:@selector(handlePortMessage:)]) [_fDelegate handlePortMessage:message];
    }
}

static BOOL
write_all(int fd, const uint8_t *bytes, size_t length)
{
    while (length) {
        ssize_t n = write(fd, bytes, length);
        if (n <= 0) return NO;
        bytes += n;
        length -= (size_t)n;
    }
    return YES;
}

- (BOOL)sendBeforeDate:(NSDate *)limitDate msgid:(NSUInteger)msgID components:(NSMutableArray *)components from:(NSPort *)receivePort reserved:(NSUInteger)headerSpaceReserved
{
    (void)limitDate; (void)headerSpaceReserved;
    if (!_fValid) return NO;
    if (_fOutgoing < 0) {
        int fd = socket(_fFamily, _fType, _fProtocol);
        if (fd < 0) return NO;
        int yes = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
        if (connect(fd, [_fAddress bytes], (socklen_t)[_fAddress length]) != 0) { close(fd); return NO; }
        _fOutgoing = fd;
    }
    struct sockaddr_storage reached;
    socklen_t reachedLength = sizeof(reached);
    BOOL known = getsockname(_fOutgoing, (struct sockaddr *)&reached, &reachedLength) == 0;
    NSMutableData *frame = [NSMutableData data];
    put32(frame, (uint32_t)msgID);
    BOOL hasReply = [receivePort isKindOfClass:[NSSocketPort class]];
    put32(frame, hasReply);
    if (hasReply) [frame appendData:[(NSSocketPort *)receivePort _describeAs:known ? (struct sockaddr *)&reached : NULL]];
    put32(frame, (uint32_t)[components count]);
    for (id component in components) {
        if ([component isKindOfClass:[NSSocketPort class]]) {
            put32(frame, 'P');
            [frame appendData:[component _describeAs:known ? (struct sockaddr *)&reached : NULL]];
        } else if ([component isKindOfClass:[NSData class]]) {
            put32(frame, 'D');
            put_bytes(frame, component);
        } else {
            put32(frame, '-');
        }
    }
    uint32_t length = (uint32_t)[frame length];
    if (!write_all(_fOutgoing, (const uint8_t *)&length, sizeof(length)) || !write_all(_fOutgoing, [frame bytes], [frame length])) {
        close(_fOutgoing);
        _fOutgoing = -1;
        return NO;
    }
    return YES;
}

- (BOOL)sendBeforeDate:(NSDate *)limitDate components:(NSMutableArray *)components from:(NSPort *)receivePort reserved:(NSUInteger)headerSpaceReserved
{
    return [self sendBeforeDate:limitDate msgid:0 components:components from:receivePort reserved:headerSpaceReserved];
}

@end
