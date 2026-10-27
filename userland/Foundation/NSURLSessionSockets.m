/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSURLSession's socket tasks (docs/design/FOUNDATION.md), against the SDK's
 * <Foundation/NSURLSession.h>, over NSURLSession.m's connections:
 *
 *   - NSURLSessionWebSocketTask: the HTTP/1.1 upgrade (RFC 6455), then masked
 *     frames out and messages in, reassembled from fragments, up to the
 *     maximum message size. Pings are answered, pongs go to their handlers, and
 *     closing is Apple's: a close from the server is echoed, its code and reason
 *     kept, waiting receives fail with ENOTCONN, and the delegate hears the close
 *     and then the completion; a message over the maximum closes with 1009 and
 *     fails the task with EMSGSIZE.
 *   - NSURLSessionStreamTask: a TCP connection read with a minimum and maximum,
 *     written, closed a side at a time, upgraded to TLS, or handed over as a pair
 *     of streams.
 *
 * Each task's reads run on one thread and its writes on a serial queue; with TLS a
 * lock keeps OpenSSL to one call at a time. Handlers and delegate calls go to the
 * session's delegate queue in order.
 */
#import <Foundation/Foundation.h>
#import <objc/message.h>
#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <unistd.h>

#include "NSURLSession_Finch.h"

static NSError *
posix_error(int code)
{
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
}

/* A read, with TLS one OpenSSL call at a time (writes take the lock too): wait for
   the socket outside the lock, so a write can go out while nothing arrives. */
static ssize_t
io_read(Connection *c, pthread_mutex_t *lock, void *buf, size_t n)
{
    if (!c->ssl)
        return read(c->fd, buf, n);
    for (;;) {
        pthread_mutex_lock(lock);
        BOOL pending = SSL_pending(c->ssl) > 0;
        pthread_mutex_unlock(lock);
        if (!pending) {
            struct pollfd p = {.fd = c->fd, .events = POLLIN};
            if (poll(&p, 1, -1) < 0 && errno != EINTR)
                return -1;
        }
        pthread_mutex_lock(lock);
        int r = SSL_read(c->ssl, buf, (int)n);
        int e = r > 0 ? SSL_ERROR_NONE : SSL_get_error(c->ssl, r);
        pthread_mutex_unlock(lock);
        if (r > 0)
            return r;
        if (e == SSL_ERROR_WANT_READ || e == SSL_ERROR_WANT_WRITE)
            continue;
        return e == SSL_ERROR_ZERO_RETURN ? 0 : -1;
    }
}

static BOOL
io_write(Connection *c, pthread_mutex_t *lock, const void *buf, size_t n)
{
    if (!c->ssl)
        return conn_write(c, buf, n);
    pthread_mutex_lock(lock);
    BOOL ok = conn_write(c, buf, n);
    pthread_mutex_unlock(lock);
    return ok;
}

/* (after the handshake: SSL_read gives up after a record that isn't data, rather than
   holding the lock until more arrives) */
static void
io_prepare(Connection *c)
{
    if (c->ssl)
        SSL_clear_mode(c->ssl, SSL_MODE_AUTO_RETRY);
}

/* MARK: - NSURLSessionWebSocketMessage */

@implementation NSURLSessionWebSocketMessage {
    NSURLSessionWebSocketMessageType _type;
    NSData *_data;
    NSString *_string;
}

- (instancetype)initWithData:(NSData *)data
{
    if ((self = [super init])) {
        _type = NSURLSessionWebSocketMessageTypeData;
        _data = [data copy];
    }
    return self;
}

- (instancetype)initWithString:(NSString *)string
{
    if ((self = [super init])) {
        _type = NSURLSessionWebSocketMessageTypeString;
        _string = [string copy];
    }
    return self;
}

- (void)dealloc
{
    [_data release];
    [_string release];
    [super dealloc];
}

- (NSURLSessionWebSocketMessageType)type { return _type; }
- (NSData *)data { return _data; }
- (NSString *)string { return _string; }

@end

/* MARK: - NSURLSessionWebSocketTask */

enum { OpContinuation = 0, OpText = 1, OpBinary = 2, OpClose = 8, OpPing = 9, OpPong = 10 };

/* A client frame: final, masked. */
static NSData *
ws_frame(int opcode, const void *payload, size_t n)
{
    NSMutableData *f = [NSMutableData dataWithCapacity:n + 14];
    uint8_t h[14] = {(uint8_t)(0x80 | opcode)};
    size_t hn = 2;
    if (n < 126) {
        h[1] = (uint8_t)(0x80 | n);
    } else if (n < 65536) {
        h[1] = 0x80 | 126, h[2] = (uint8_t)(n >> 8), h[3] = (uint8_t)n, hn = 4;
    } else {
        h[1] = 0x80 | 127;
        for (int i = 0; i < 8; i++)
            h[2 + i] = (uint8_t)((uint64_t)n >> (56 - 8 * i));
        hn = 10;
    }
    uint32_t mask = arc4random();
    memcpy(h + hn, &mask, 4);
    hn += 4;
    [f appendBytes:h length:hn];
    [f setLength:hn + n];
    uint8_t *out = (uint8_t *)[f mutableBytes] + hn;
    const uint8_t *in = payload, *m = (const uint8_t *)&mask;
    for (size_t i = 0; i < n; i++)
        out[i] = in[i] ^ m[i % 4];
    return f;
}

static NSData *
close_payload(NSInteger code, NSData *reason)
{
    NSMutableData *d = [NSMutableData data];
    if (code) {
        uint8_t c[2] = {(uint8_t)(code >> 8), (uint8_t)code};
        [d appendBytes:c length:2];
        if (reason)
            [d appendData:reason];
    }
    return d;
}

@interface NSURLSessionWebSocketTask () {
    Connection _c;
    pthread_mutex_t _io;
    NSMutableData *_pending; /* read past the handshake's head */
    dispatch_queue_t _writes; /* (suspended until the handshake is done) */
    NSOperationQueue *_queue;
    NSURLSession *_owner;
    NSMutableArray *_messages, *_receivers, *_pongs;
    NSError *_failure;
    NSInteger _maximumMessageSize;
    NSURLSessionWebSocketCloseCode _closeCode;
    NSData *_closeReason;
    BOOL _closeSent, _writesResumed, _ended;
    uint32_t _pings;
}
@end

@implementation NSURLSessionWebSocketTask

- (instancetype)_finchInitWithSession:(NSURLSession *)session request:(NSURLRequest *)request identifier:(NSUInteger)ident
                             download:(BOOL)download completion:(void (^)(id, NSURLResponse *, NSError *))completion
{
    if ((self = [super _finchInitWithSession:session request:request identifier:ident download:NO completion:nil])) {
        _c.fd = -1;
        pthread_mutex_init(&_io, NULL);
        _pending = [NSMutableData new];
        _writes = dispatch_queue_create("org.finch.websocket.writes", DISPATCH_QUEUE_SERIAL);
        dispatch_suspend(_writes);
        _messages = [NSMutableArray new];
        _receivers = [NSMutableArray new];
        _pongs = [NSMutableArray new];
        _maximumMessageSize = 1024 * 1024;
        _queue = [session.delegateQueue retain];
        _owner = [session retain];
    }
    return self;
}

- (void)dealloc
{
    if (!_writesResumed)
        dispatch_resume(_writes);
    dispatch_release(_writes);
    conn_close(&_c);
    pthread_mutex_destroy(&_io);
    [_pending release];
    [_queue release];
    [_owner release];
    [_messages release];
    [_receivers release];
    [_pongs release];
    [_failure release];
    [_closeReason release];
    [super dealloc];
}

- (NSInteger)maximumMessageSize { return _maximumMessageSize; }
- (void)setMaximumMessageSize:(NSInteger)size { _maximumMessageSize = size; }
- (NSURLSessionWebSocketCloseCode)closeCode
{
    @synchronized(self) { return _closeCode; }
}
- (NSData *)closeReason
{
    @synchronized(self) { return [[_closeReason retain] autorelease]; }
}

- (void)_deliver:(void (^)(void))block { [_queue addOperationWithBlock:block]; }

- (void)_resumeWrites
{
    @synchronized(self) {
        if (_writesResumed)
            return;
        _writesResumed = YES;
    }
    dispatch_resume(_writes);
}

/* No more messages either way: waiting receives and pings fail with error. */
- (void)_failWith:(NSError *)error
{
    NSArray *receivers, *pongs;
    @synchronized(self) {
        if (!_failure)
            _failure = [error retain];
        error = _failure;
        receivers = [[_receivers copy] autorelease];
        pongs = [[_pongs copy] autorelease];
        [_receivers removeAllObjects];
        [_pongs removeAllObjects];
    }
    for (void (^r)(NSURLSessionWebSocketMessage *, NSError *) in receivers)
        [self _deliver:^{ r(nil, error); }];
    for (void (^p)(NSError *) in pongs)
        [self _deliver:^{ p(error); }];
    [self _resumeWrites];
}

/* The task's end (once): the connection closed, the delegate told of a close, then the completion. */
- (void)_endWithError:(NSError *)error closed:(BOOL)closed
{
    @synchronized(self) {
        if (_ended)
            return;
        _ended = YES;
    }
    if (_c.fd >= 0)
        shutdown(_c.fd, SHUT_RDWR);
    if (closed) {
        id d = _owner.delegate;
        NSURLSession *session = _owner;
        NSURLSessionWebSocketCloseCode code = _closeCode;
        NSData *reason = [[_closeReason retain] autorelease];
        if ([d respondsToSelector:@selector(URLSession:webSocketTask:didCloseWithCode:reason:)])
            [self _deliver:^{
                [(id<NSURLSessionWebSocketDelegate>)d URLSession:session webSocketTask:self didCloseWithCode:code reason:reason];
            }];
    }
    [self _finchFinishWithResult:nil response:[self response] error:error];
}

- (void)resume
{
    if (![self _finchStartRunning])
        return;
    [self retain];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            [self _run];
        }
        [self release];
    });
}

- (void)suspend {}

/* Exactly n bytes, from what the handshake read past and then the connection. */
- (BOOL)_read:(void *)buf length:(size_t)n
{
    uint8_t *p = buf;
    size_t have = MIN(n, [_pending length]);
    if (have) {
        memcpy(p, [_pending bytes], have);
        [_pending replaceBytesInRange:NSMakeRange(0, have) withBytes:NULL length:0];
        p += have, n -= have;
    }
    while (n) {
        ssize_t r = io_read(&_c, &_io, p, n);
        if (r <= 0)
            return NO;
        p += r, n -= (size_t)r;
    }
    return YES;
}

- (BOOL)_send:(NSData *)frame { return io_write(&_c, &_io, [frame bytes], [frame length]); }

- (NSString *)_handshakeKey
{
    uint8_t nonce[16];
    arc4random_buf(nonce, sizeof nonce);
    return [[NSData dataWithBytes:nonce length:sizeof nonce] base64EncodedStringWithOptions:0];
}

static NSString *
expected_accept(NSString *key)
{
    NSData *s = [[key stringByAppendingString:@"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"] dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[20];
    SHA1([s bytes], [s length], digest);
    return [[NSData dataWithBytes:digest length:sizeof digest] base64EncodedStringWithOptions:0];
}

/* The upgrade: its response, or nil with the error. */
- (NSHTTPURLResponse *)_handshake:(NSURL *)url error:(NSError **)error
{
    NSURLRequest *request = [self originalRequest];
    NSInteger failure = _FinchURLTaskConnect(self, &_c, url, [request timeoutInterval]);
    if (failure) {
        _c.fd = -1;
        *error = url_error(failure, url, nil);
        return nil;
    }
    NSURLComponents *parts = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSString *target = [parts.percentEncodedPath length] ? parts.percentEncodedPath : @"/";
    if (parts.percentEncodedQuery)
        target = [target stringByAppendingFormat:@"?%@", parts.percentEncodedQuery];
    NSString *host = [url port] ? [NSString stringWithFormat:@"%@:%@", [url host], [url port]] : [url host];
    NSString *key = [self _handshakeKey];
    NSMutableString *head = [NSMutableString stringWithFormat:@"GET %@ HTTP/1.1\r\nHost: %@\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                                                              @"Sec-WebSocket-Key: %@\r\nSec-WebSocket-Version: 13\r\n",
                                             target, host, key];
    NSMutableDictionary *fields = [[[request allHTTPHeaderFields] mutableCopy] autorelease] ?: [NSMutableDictionary dictionary];
    NSURLSessionConfiguration *configuration = _owner.configuration;
    if (configuration.HTTPShouldSetCookies && [request HTTPShouldHandleCookies]) {
        NSArray *cookies = [configuration.HTTPCookieStorage cookiesForURL:url];
        if ([cookies count])
            [fields addEntriesFromDictionary:[NSHTTPCookie requestHeaderFieldsWithCookies:cookies]];
    }
    for (NSString *k in fields) {
        NSString *lower = [k lowercaseString];
        if ([lower isEqualToString:@"host"] || [lower isEqualToString:@"upgrade"] || [lower isEqualToString:@"connection"] ||
            [lower isEqualToString:@"sec-websocket-key"] || [lower isEqualToString:@"sec-websocket-version"])
            continue;
        [head appendFormat:@"%@: %@\r\n", k, fields[k]];
    }
    [head appendString:@"\r\n"];
    NSData *bytes = [head dataUsingEncoding:NSUTF8StringEncoding];
    if (!io_write(&_c, &_io, [bytes bytes], [bytes length])) {
        *error = url_error(NSURLErrorNetworkConnectionLost, url, nil);
        return nil;
    }
    /* the response's head */
    NSMutableData *in = [NSMutableData data];
    NSRange end = {NSNotFound, 0};
    while (end.location == NSNotFound) {
        uint8_t buf[4096];
        ssize_t r = io_read(&_c, &_io, buf, sizeof buf);
        if (r <= 0) {
            *error = url_error(NSURLErrorNetworkConnectionLost, url, nil);
            return nil;
        }
        [in appendBytes:buf length:(NSUInteger)r];
        end = [in rangeOfData:[NSData dataWithBytes:"\r\n\r\n" length:4] options:0 range:NSMakeRange(0, [in length])];
    }
    [_pending appendData:[in subdataWithRange:NSMakeRange(NSMaxRange(end), [in length] - NSMaxRange(end))]];
    NSString *text = [[[NSString alloc] initWithData:[in subdataWithRange:NSMakeRange(0, end.location)] encoding:NSISOLatin1StringEncoding]
        autorelease];
    NSArray *lines = [text componentsSeparatedByString:@"\r\n"];
    NSArray *status = [lines[0] componentsSeparatedByString:@" "];
    NSInteger code = [status count] > 1 ? [status[1] integerValue] : 0;
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    for (NSString *line in [lines subarrayWithRange:NSMakeRange(1, [lines count] - 1)]) {
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound)
            continue;
        NSString *name = [line substringToIndex:colon.location];
        NSString *value = [[line substringFromIndex:colon.location + 1]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        headers[name] = headers[name] ? [NSString stringWithFormat:@"%@, %@", headers[name], value] : value;
    }
    NSHTTPURLResponse *response = [[[NSHTTPURLResponse alloc] initWithURL:url statusCode:code HTTPVersion:@"HTTP/1.1"
                                                             headerFields:headers] autorelease];
    [self _finchSetResponse:response];
    if (configuration.HTTPShouldSetCookies && configuration.HTTPCookieAcceptPolicy != NSHTTPCookieAcceptPolicyNever) {
        NSArray *cookies = [NSHTTPCookie cookiesWithResponseHeaderFields:headers forURL:url];
        if ([cookies count])
            [configuration.HTTPCookieStorage setCookies:cookies forURL:url mainDocumentURL:nil];
    }
    NSString *accept = [response valueForHTTPHeaderField:@"Sec-WebSocket-Accept"];
    if (code != 101 || ![accept isEqualToString:expected_accept(key)]) {
        *error = url_error(NSURLErrorBadServerResponse, url, nil);
        return nil;
    }
    return response;
}

- (void)_run
{
    NSURL *url = [[self originalRequest] URL];
    NSError *error = nil;
    NSHTTPURLResponse *response = [self _handshake:url error:&error];
    @synchronized(self) {
        if (_failure) /* (cancelled meanwhile) */
            response = nil, error = _failure;
    }
    if (!response) {
        [self _failWith:error];
        [self _endWithError:error closed:NO];
        return;
    }
    io_prepare(&_c);
    id d = _owner.delegate;
    NSURLSession *session = _owner;
    NSString *protocol = [response valueForHTTPHeaderField:@"Sec-WebSocket-Protocol"];
    if ([d respondsToSelector:@selector(URLSession:webSocketTask:didOpenWithProtocol:)])
        [self _deliver:^{ [(id<NSURLSessionWebSocketDelegate>)d URLSession:session webSocketTask:self didOpenWithProtocol:protocol]; }];
    [self _resumeWrites];
    [self _readFrames];
}

- (void)_received:(NSURLSessionWebSocketMessage *)message
{
    void (^receiver)(NSURLSessionWebSocketMessage *, NSError *) = nil;
    @synchronized(self) {
        if ([_receivers count]) {
            receiver = [[_receivers[0] retain] autorelease];
            [_receivers removeObjectAtIndex:0];
        } else {
            [_messages addObject:message];
        }
    }
    if (receiver)
        [self _deliver:^{ receiver(message, nil); }];
}

/* After this side's close: what the server still sends, discarded, until its close or the end (5 seconds at most). */
- (void)_drainUntilClosed
{
    struct timeval tv = {5, 0};
    setsockopt(_c.fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    [_pending setLength:0];
    uint8_t buf[65536];
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:5];
    while ([until timeIntervalSinceNow] > 0 && io_read(&_c, &_io, buf, sizeof buf) > 0)
        ;
}

- (void)_readFrames
{
    NSMutableData *message = nil;
    int messageType = 0;
    for (;;) {
        @autoreleasepool {
            uint8_t h[2];
            if (![self _read:h length:2])
                break;
            int opcode = h[0] & 0x0f;
            BOOL final = (h[0] & 0x80) != 0;
            uint64_t n = h[1] & 0x7f;
            if (n == 126) {
                uint8_t e[2];
                if (![self _read:e length:2])
                    break;
                n = (uint64_t)e[0] << 8 | e[1];
            } else if (n == 127) {
                uint8_t e[8];
                if (![self _read:e length:8])
                    break;
                n = 0;
                for (int i = 0; i < 8; i++)
                    n = n << 8 | e[i];
            }
            uint8_t mask[4] = {0};
            if ((h[1] & 0x80) && ![self _read:mask length:4])
                break;
            BOOL data = opcode == OpText || opcode == OpBinary || opcode == OpContinuation;
            if (data && n + [message length] > (uint64_t)_maximumMessageSize) {
                @synchronized(self) {
                    _closeSent = YES;
                }
                [self _send:ws_frame(OpClose, [close_payload(NSURLSessionWebSocketCloseCodeMessageTooBig, nil) bytes], 2)];
                [self _drainUntilClosed];
                NSError *error = posix_error(EMSGSIZE);
                [self _failWith:error];
                [self _endWithError:error closed:NO];
                return;
            }
            NSMutableData *payload = [NSMutableData dataWithLength:(NSUInteger)n];
            if (n && ![self _read:[payload mutableBytes] length:(size_t)n])
                break;
            uint8_t *p = [payload mutableBytes];
            for (uint64_t i = 0; i < n; i++)
                p[i] ^= mask[i % 4];
            if (opcode == OpText || opcode == OpBinary) {
                message = [[payload mutableCopy] autorelease];
                messageType = opcode;
            } else if (opcode == OpContinuation) {
                [message appendData:payload];
            }
            if (data && final && message) {
                NSURLSessionWebSocketMessage *m = messageType == OpText
                    ? [[NSURLSessionWebSocketMessage alloc] initWithString:[[[NSString alloc] initWithData:message
                                                                                                encoding:NSUTF8StringEncoding] autorelease]]
                    : [[NSURLSessionWebSocketMessage alloc] initWithData:message];
                [self _received:[m autorelease]];
                [message retain];
                [message release];
                message = nil;
            } else if (opcode == OpPing) {
                [self _send:ws_frame(OpPong, [payload bytes], [payload length])];
            } else if (opcode == OpPong) {
                void (^pong)(NSError *) = nil;
                @synchronized(self) {
                    if ([_pongs count]) {
                        pong = [[_pongs[0] retain] autorelease];
                        [_pongs removeObjectAtIndex:0];
                    }
                }
                if (pong)
                    [self _deliver:^{ pong(nil); }];
            } else if (opcode == OpClose) {
                const uint8_t *b = [payload bytes];
                BOOL echo;
                @synchronized(self) {
                    _closeCode = n >= 2 ? (NSURLSessionWebSocketCloseCode)(b[0] << 8 | b[1]) : NSURLSessionWebSocketCloseCodeNoStatusReceived;
                    [_closeReason release];
                    _closeReason = n > 2 ? [[payload subdataWithRange:NSMakeRange(2, (NSUInteger)n - 2)] retain] : nil;
                    echo = !_closeSent;
                    _closeSent = YES;
                }
                if (echo)
                    [self _send:ws_frame(OpClose, [payload bytes], [payload length])];
                [self _failWith:posix_error(ENOTCONN)];
                [self _endWithError:nil closed:YES];
                return;
            }
        }
    }
    /* the connection ended without a close: normal if this side had closed or cancelled */
    BOOL closing;
    NSError *failure;
    @synchronized(self) {
        closing = _closeSent;
        failure = [[_failure retain] autorelease];
    }
    [self _failWith:posix_error(ENOTCONN)];
    [self _endWithError:closing ? nil : failure ?: posix_error(ENOTCONN) closed:closing];
}

- (void)sendMessage:(NSURLSessionWebSocketMessage *)message completionHandler:(void (^)(NSError *))completionHandler
{
    NSData *payload = message.type == NSURLSessionWebSocketMessageTypeString ? [message.string dataUsingEncoding:NSUTF8StringEncoding]
                                                                              : message.data;
    NSData *frame = ws_frame(message.type == NSURLSessionWebSocketMessageTypeString ? OpText : OpBinary, [payload bytes], [payload length]);
    completionHandler = [[completionHandler copy] autorelease];
    [self retain];
    dispatch_async(_writes, ^{
        NSError *error;
        @synchronized(self) {
            error = [[_failure retain] autorelease];
        }
        if (!error && ![self _send:frame])
            error = posix_error(errno ?: ENOTCONN);
        if (completionHandler)
            [self _deliver:^{ completionHandler(error); }];
        [self release];
    });
}

- (void)receiveMessageWithCompletionHandler:(void (^)(NSURLSessionWebSocketMessage *, NSError *))completionHandler
{
    completionHandler = [[completionHandler copy] autorelease];
    NSURLSessionWebSocketMessage *message = nil;
    NSError *error = nil;
    @synchronized(self) {
        if ([_messages count]) {
            message = [[_messages[0] retain] autorelease];
            [_messages removeObjectAtIndex:0];
        } else if (_failure) {
            error = [[_failure retain] autorelease];
        } else {
            [_receivers addObject:completionHandler];
            return;
        }
    }
    [self _deliver:^{ completionHandler(message, error); }];
}

- (void)sendPingWithPongReceiveHandler:(void (^)(NSError *))pongReceiveHandler
{
    pongReceiveHandler = [[pongReceiveHandler copy] autorelease];
    [self retain];
    dispatch_async(_writes, ^{
        NSError *error;
        uint32_t count;
        @synchronized(self) {
            error = [[_failure retain] autorelease];
            if (!error)
                [_pongs addObject:pongReceiveHandler];
            count = ++_pings;
        }
        uint8_t payload[4] = {(uint8_t)(count >> 24), (uint8_t)(count >> 16), (uint8_t)(count >> 8), (uint8_t)count};
        if (!error && ![self _send:ws_frame(OpPing, payload, sizeof payload)]) {
            error = posix_error(errno ?: ENOTCONN);
            @synchronized(self) {
                [_pongs removeObjectIdenticalTo:pongReceiveHandler];
            }
        }
        if (error)
            [self _deliver:^{ pongReceiveHandler(error); }];
        [self release];
    });
}

- (void)cancelWithCloseCode:(NSURLSessionWebSocketCloseCode)closeCode reason:(NSData *)reason
{
    @synchronized(self) {
        if (_closeSent || _ended)
            return;
        _closeSent = YES;
        _closeCode = closeCode;
        [_closeReason release];
        _closeReason = [reason copy];
    }
    NSData *frame = ws_frame(OpClose, [close_payload(closeCode, reason) bytes], [close_payload(closeCode, reason) length]);
    [self retain];
    dispatch_async(_writes, ^{
        [self _send:frame];
        /* (the server answers with its own close; give up on it after a while) */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_global_queue(0, 0), ^{
            if (_c.fd >= 0)
                shutdown(_c.fd, SHUT_RDWR);
            [self release];
        });
    });
}

- (void)cancel
{
    NSError *error = url_error(NSURLErrorCancelled, [[self originalRequest] URL], @"cancelled");
    [self _failWith:error];
    [self _endWithError:error closed:NO];
}

@end

/* MARK: - NSURLSessionStreamTask */

@interface NSURLSessionStreamTask () {
    Connection _c;
    pthread_mutex_t _io;
    NSString *_host;
    NSInteger _port;
    dispatch_queue_t _reads, _writes; /* (suspended until connected) */
    BOOL _queuesResumed, _eof;
    NSMutableData *_buffer;
    NSError *_failure;
    NSOperationQueue *_queue;
    NSURLSession *_owner;
}
- (void)_finchSetHost:(NSString *)host port:(NSInteger)port;
@end

@implementation NSURLSessionStreamTask

- (instancetype)_finchInitWithSession:(NSURLSession *)session request:(NSURLRequest *)request identifier:(NSUInteger)ident
                             download:(BOOL)download completion:(void (^)(id, NSURLResponse *, NSError *))completion
{
    if ((self = [super _finchInitWithSession:session request:request identifier:ident download:NO completion:nil])) {
        _c.fd = -1;
        pthread_mutex_init(&_io, NULL);
        _reads = dispatch_queue_create("org.finch.stream.reads", DISPATCH_QUEUE_SERIAL);
        _writes = dispatch_queue_create("org.finch.stream.writes", DISPATCH_QUEUE_SERIAL);
        dispatch_suspend(_reads);
        dispatch_suspend(_writes);
        _buffer = [NSMutableData new];
        _queue = [session.delegateQueue retain];
        _owner = [session retain];
    }
    return self;
}

- (void)_finchSetHost:(NSString *)host port:(NSInteger)port
{
    _host = [host copy];
    _port = port;
}

- (void)dealloc
{
    [self _resumeQueues];
    dispatch_release(_reads);
    dispatch_release(_writes);
    conn_close(&_c);
    pthread_mutex_destroy(&_io);
    [_host release];
    [_buffer release];
    [_failure release];
    [_queue release];
    [_owner release];
    [super dealloc];
}

- (void)_deliver:(void (^)(void))block { [_queue addOperationWithBlock:block]; }

- (void)_resumeQueues
{
    @synchronized(self) {
        if (_queuesResumed)
            return;
        _queuesResumed = YES;
    }
    dispatch_resume(_reads);
    dispatch_resume(_writes);
}

- (NSError *)_failure
{
    @synchronized(self) { return [[_failure retain] autorelease]; }
}

- (void)_fail:(NSError *)error
{
    @synchronized(self) {
        if (!_failure)
            _failure = [error retain];
    }
}

- (void)resume
{
    if (![self _finchStartRunning])
        return;
    [self retain];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSURLComponents *u = [[NSURLComponents new] autorelease];
            u.scheme = @"http";
            u.host = _host;
            u.port = @(_port);
            NSInteger failure = conn_open(&_c, u.URL, [[self originalRequest] timeoutInterval]);
            if (failure) {
                conn_close(&_c);
                _c.fd = -1;
                NSError *error = failure == NSURLErrorCannotConnectToHost ? posix_error(ECONNREFUSED)
                                                                          : url_error(failure, u.URL, nil);
                [self _fail:error];
                [self _resumeQueues];
                [self _finchFinishWithResult:nil response:nil error:error];
            } else {
                [self _resumeQueues];
            }
        }
        [self release];
    });
}

- (void)suspend {}

- (void)readDataOfMinLength:(NSUInteger)minBytes maxLength:(NSUInteger)maxBytes timeout:(NSTimeInterval)timeout
          completionHandler:(void (^)(NSData *, BOOL, NSError *))completionHandler
{
    completionHandler = [[completionHandler copy] autorelease];
    if (minBytes > maxBytes || !maxBytes) {
        [self _deliver:^{ completionHandler(nil, NO, posix_error(EINVAL)); }];
        return;
    }
    [self retain];
    dispatch_async(_reads, ^{
        @autoreleasepool {
            NSError *error = [self _failure];
            NSDate *until = timeout > 0 ? [NSDate dateWithTimeIntervalSinceNow:timeout] : nil;
            while (!error && !_eof && [_buffer length] < minBytes) {
                if (!_c.ssl || !SSL_pending(_c.ssl)) {
                    int wait = until ? (int)MAX(0, [until timeIntervalSinceNow] * 1000) : -1;
                    struct pollfd p = {.fd = _c.fd, .events = POLLIN};
                    int ready = poll(&p, 1, wait);
                    if (ready == 0) {
                        error = posix_error(ETIMEDOUT);
                        break;
                    }
                    if (ready < 0 && errno != EINTR) {
                        error = posix_error(errno);
                        break;
                    }
                }
                uint8_t buf[65536];
                ssize_t r = io_read(&_c, &_io, buf, sizeof buf);
                if (r < 0)
                    error = [self _failure] ?: posix_error(errno ?: ECONNRESET);
                else if (r == 0)
                    _eof = YES;
                else
                    [_buffer appendBytes:buf length:(NSUInteger)r];
            }
            NSUInteger n = MIN(maxBytes, [_buffer length]);
            NSData *data = n ? [_buffer subdataWithRange:NSMakeRange(0, n)] : nil;
            [_buffer replaceBytesInRange:NSMakeRange(0, n) withBytes:NULL length:0];
            BOOL atEOF = _eof && ![_buffer length] && !data;
            if (data)
                error = nil;
            [self _deliver:^{ completionHandler(data, atEOF, error); }];
        }
        [self release];
    });
}

- (void)writeData:(NSData *)data timeout:(NSTimeInterval)timeout completionHandler:(void (^)(NSError *))completionHandler
{
    completionHandler = [[completionHandler copy] autorelease];
    data = [[data copy] autorelease];
    [self retain];
    dispatch_async(_writes, ^{
        NSError *error = [self _failure];
        if (!error && !io_write(&_c, &_io, [data bytes], [data length]))
            error = posix_error(errno ?: EPIPE);
        [self _deliver:^{ completionHandler(error); }];
        [self release];
    });
}

- (void)_tell:(SEL)message
{
    id d = _owner.delegate;
    NSURLSession *session = _owner;
    if ([d respondsToSelector:message])
        [self _deliver:^{ ((void (*)(id, SEL, id, id))(void *)objc_msgSend)(d, message, session, self); }];
}

- (void)closeWrite
{
    [self retain];
    dispatch_async(_writes, ^{
        if (_c.fd >= 0 && ![self _failure]) {
            if (_c.ssl) {
                pthread_mutex_lock(&_io);
                SSL_shutdown(_c.ssl);
                pthread_mutex_unlock(&_io);
            }
            shutdown(_c.fd, SHUT_WR);
        }
        [self _tell:@selector(URLSession:writeClosedForStreamTask:)];
        [self release];
    });
}

- (void)closeRead
{
    [self retain];
    dispatch_async(_reads, ^{
        if (_c.fd >= 0 && ![self _failure])
            shutdown(_c.fd, SHUT_RD);
        _eof = YES;
        [self _tell:@selector(URLSession:readClosedForStreamTask:)];
        [self release];
    });
}

/* After the writes and reads already asked for. */
- (void)_afterPending:(void (^)(void))block
{
    block = [[block copy] autorelease];
    [self retain];
    dispatch_async(_writes, ^{
        dispatch_sync(_reads, block);
        [self release];
    });
}

- (void)startSecureConnection
{
    [self _afterPending:^{
        if ([self _failure] || _c.ssl)
            return;
        NSInteger failure = _FinchURLTaskStartTLS(self, &_c, _host);
        if (failure) {
            NSError *error = url_error(failure, nil, nil);
            [self _fail:error];
            [self _finchFinishWithResult:nil response:nil error:error];
        } else {
            io_prepare(&_c);
        }
    }];
}

- (void)stopSecureConnection {}

/* The connection as a pair of streams (a plain one: the streams don't speak TLS); the task is done. */
- (void)captureStreams
{
    [self _afterPending:^{
        if ([self _failure] || _c.fd < 0)
            return;
        CFReadStreamRef input = NULL;
        CFWriteStreamRef output = NULL;
        CFStreamCreatePairWithSocket(kCFAllocatorDefault, _c.fd, &input, &output);
        if (!input || !output)
            return;
        CFReadStreamSetProperty(input, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);
        CFWriteStreamSetProperty(output, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);
        if (_c.ssl) {
            SSL_free(_c.ssl);
            _c.ssl = NULL;
        }
        _c.fd = -1;
        id d = _owner.delegate;
        NSURLSession *session = _owner;
        NSInputStream *in = [(NSInputStream *)input autorelease];
        NSOutputStream *out = [(NSOutputStream *)output autorelease];
        if ([d respondsToSelector:@selector(URLSession:streamTask:didBecomeInputStream:outputStream:)])
            [self _deliver:^{
                [(id<NSURLSessionStreamDelegate>)d URLSession:session streamTask:self didBecomeInputStream:in outputStream:out];
            }];
        [self _finchFinishQuietly];
    }];
}

- (void)cancel
{
    NSError *error = url_error(NSURLErrorCancelled, [[self originalRequest] URL], @"cancelled");
    [self _fail:error];
    if (_c.fd >= 0)
        shutdown(_c.fd, SHUT_RDWR);
    [self _resumeQueues];
    [self _finchFinishWithResult:nil response:nil error:error];
}

@end

/* MARK: - The session's socket tasks */

@implementation NSURLSession (FinchSockets)

/* (as Apple's: the request is the http(s) one the upgrade is sent as) */
static NSURL *
http_url(NSURL *url)
{
    NSString *scheme = [[url scheme] lowercaseString];
    NSString *http = [scheme isEqualToString:@"ws"] ? @"http" : [scheme isEqualToString:@"wss"] ? @"https" : nil;
    if (!http)
        return url;
    NSURLComponents *parts = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:YES];
    parts.scheme = http;
    return parts.URL ?: url;
}

- (NSURLSessionWebSocketTask *)webSocketTaskWithURL:(NSURL *)url
{
    return [self webSocketTaskWithURL:url protocols:@[]];
}

- (NSURLSessionWebSocketTask *)webSocketTaskWithURL:(NSURL *)url protocols:(NSArray<NSString *> *)protocols
{
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    if ([protocols count])
        [request setValue:[protocols componentsJoinedByString:@", "] forHTTPHeaderField:@"Sec-WebSocket-Protocol"];
    return [self webSocketTaskWithRequest:request];
}

- (NSURLSessionWebSocketTask *)webSocketTaskWithRequest:(NSURLRequest *)request
{
    NSMutableURLRequest *r = [[request mutableCopy] autorelease];
    [r setURL:http_url([request URL])];
    return [self _finchTask:[NSURLSessionWebSocketTask class] request:r download:NO completion:nil];
}

- (NSURLSessionStreamTask *)streamTaskWithHostName:(NSString *)hostname port:(NSInteger)port
{
    NSURLComponents *u = [[NSURLComponents new] autorelease];
    u.scheme = @"tcp";
    u.host = hostname;
    u.port = @(port);
    NSURLSessionStreamTask *task = [self _finchTask:[NSURLSessionStreamTask class]
                                            request:[NSURLRequest requestWithURL:u.URL ?: [NSURL URLWithString:@"tcp:"]]
                                           download:NO completion:nil];
    [task _finchSetHost:hostname port:port];
    return task;
}

- (NSURLSessionStreamTask *)streamTaskWithNetService:(NSNetService *)service
{
    NSString *host = service.hostName;
    if (!host) {
        [service resolveWithTimeout:5];
        host = service.hostName ?: [NSString stringWithFormat:@"%@.local", service.name];
    }
    return [self streamTaskWithHostName:host port:service.port];
}

@end
