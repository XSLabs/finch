/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-websocket-test: NSURLSession's WebSocket and stream tasks against servers
 * of the test's own on the loopback interface, compared with Apple's on the host:
 *   - WebSocket: the handshake (subprotocol, the delegate's open call), text and
 *     binary messages echoed, ping and pong, a message over the maximum size, the
 *     server closing with a code and reason (the delegate's close call, the task's
 *     close code and reason, receiving after it), the client closing with a code
 *     the server sees, and a server that won't upgrade;
 *   - stream: writing, reading with a minimum and maximum, the end of the stream
 *     when the server closes, closing the write side, and captured streams.
 */
#import <CommonCrypto/CommonDigest.h>
#import <Foundation/Foundation.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <sys/socket.h>
#include <unistd.h>

/* MARK: - The servers */

static int
listen_loopback(int *port)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on);
    struct sockaddr_in a = {.sin_len = sizeof a, .sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    bind(fd, (struct sockaddr *)&a, sizeof a);
    socklen_t n = sizeof a;
    getsockname(fd, (struct sockaddr *)&a, &n);
    *port = ntohs(a.sin_port);
    listen(fd, 8);
    return fd;
}

static BOOL
read_full(int fd, void *buf, size_t n)
{
    char *p = buf;
    while (n) {
        ssize_t r = read(fd, p, n);
        if (r <= 0) return NO;
        p += r;
        n -= (size_t)r;
    }
    return YES;
}

static void
write_full(int fd, const void *buf, size_t n)
{
    const char *p = buf;
    while (n) {
        ssize_t w = write(fd, p, n);
        if (w <= 0) return;
        p += w;
        n -= (size_t)w;
    }
}

/* What the WebSocket server saw, for the test to print. */
static NSMutableArray<NSString *> *server_log;

static void
log_server(NSString *line)
{
    @synchronized(server_log) { [server_log addObject:line]; }
}

static void
send_frame(int fd, int opcode, const void *payload, size_t n)
{
    unsigned char h[10] = {(unsigned char)(0x80 | opcode)};
    size_t hn = 2;
    if (n < 126) {
        h[1] = (unsigned char)n;
    } else if (n < 65536) {
        h[1] = 126, h[2] = (unsigned char)(n >> 8), h[3] = (unsigned char)n, hn = 4;
    } else {
        h[1] = 127;
        for (int i = 0; i < 8; i++) h[2 + i] = (unsigned char)((uint64_t)n >> (56 - 8 * i));
        hn = 10;
    }
    write_full(fd, h, hn);
    write_full(fd, payload, n);
}

/* One frame from the client (masked), or NO at the end. */
static BOOL
read_frame(int fd, int *opcode, NSMutableData *payload, BOOL *masked)
{
    unsigned char h[2];
    if (!read_full(fd, h, 2)) return NO;
    *opcode = h[0] & 0x0f;
    *masked = (h[1] & 0x80) != 0;
    uint64_t n = h[1] & 0x7f;
    if (n == 126) {
        unsigned char e[2];
        if (!read_full(fd, e, 2)) return NO;
        n = (uint64_t)e[0] << 8 | e[1];
    } else if (n == 127) {
        unsigned char e[8];
        if (!read_full(fd, e, 8)) return NO;
        n = 0;
        for (int i = 0; i < 8; i++) n = n << 8 | e[i];
    }
    unsigned char mask[4] = {0};
    if (*masked && !read_full(fd, mask, 4)) return NO;
    [payload setLength:(NSUInteger)n];
    unsigned char *p = [payload mutableBytes];
    if (n && !read_full(fd, p, (size_t)n)) return NO;
    for (uint64_t i = 0; i < n; i++) p[i] ^= mask[i % 4];
    return YES;
}

static NSString *
accept_key(NSString *key)
{
    NSString *s = [key stringByAppendingString:@"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(s.UTF8String, (CC_LONG)strlen(s.UTF8String), digest);
    return [[NSData dataWithBytes:digest length:sizeof digest] base64EncodedStringWithOptions:0];
}

/* The request's head, up to the blank line. */
static NSString *
read_head(int fd)
{
    NSMutableData *d = [NSMutableData data];
    char c;
    while (read(fd, &c, 1) == 1) {
        [d appendBytes:&c length:1];
        if (d.length >= 4 && !memcmp((const char *)d.bytes + d.length - 4, "\r\n\r\n", 4)) break;
    }
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
}

static NSString *
header(NSString *head, NSString *name)
{
    for (NSString *line in [head componentsSeparatedByString:@"\r\n"]) {
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location != NSNotFound && [[line substringToIndex:colon.location] caseInsensitiveCompare:name] == NSOrderedSame)
            return [[line substringFromIndex:colon.location + 1]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    }
    return nil;
}

/*
 * Each connection: path /echo echoes messages, answers "close-me" by closing
 * with 4000 "bye", and "big" with a 2 MB message; /refuse answers 404.
 */
static void
serve_websocket(int fd)
{
    NSString *head = read_head(fd);
    NSString *path = [[[head componentsSeparatedByString:@"\r\n"].firstObject componentsSeparatedByString:@" "] objectAtIndex:1];
    if ([path isEqualToString:@"/refuse"]) {
        const char *r = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        write_full(fd, r, strlen(r));
        close(fd);
        return;
    }
    log_server([NSString stringWithFormat:@"upgrade %@ version %@ protocols %@ custom %@", header(head, @"Upgrade"),
                         header(head, @"Sec-WebSocket-Version"), header(head, @"Sec-WebSocket-Protocol") ?: @"-",
                         header(head, @"X-Test") ?: @"-"]);
    NSString *protocols = header(head, @"Sec-WebSocket-Protocol");
    NSString *chosen = [[protocols componentsSeparatedByString:@","].lastObject
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSString *reply = [NSString stringWithFormat:@"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                                                 @"Sec-WebSocket-Accept: %@\r\n%@\r\n",
                                accept_key(header(head, @"Sec-WebSocket-Key")),
                                chosen ? [NSString stringWithFormat:@"Sec-WebSocket-Protocol: %@\r\n", chosen] : @""];
    write_full(fd, reply.UTF8String, strlen(reply.UTF8String));
    NSMutableData *payload = [NSMutableData data];
    int opcode;
    BOOL masked;
    while (read_frame(fd, &opcode, payload, &masked)) {
        if (!masked) log_server(@"unmasked frame");
        if (opcode == 1 || opcode == 2) {
            NSString *text = opcode == 1 ? [[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding] : nil;
            if ([text isEqualToString:@"close-me"]) {
                unsigned char body[5] = {4000 >> 8, 4000 & 0xff, 'b', 'y', 'e'};
                send_frame(fd, 8, body, sizeof body);
                continue;
            }
            if ([text isEqualToString:@"big"]) {
                NSMutableData *big = [NSMutableData dataWithLength:2 * 1024 * 1024];
                send_frame(fd, 2, big.bytes, big.length);
                continue;
            }
            send_frame(fd, opcode, payload.bytes, payload.length);
        } else if (opcode == 9) {
            log_server([NSString stringWithFormat:@"ping %lu bytes", (unsigned long)payload.length]);
            send_frame(fd, 10, payload.bytes, payload.length);
        } else if (opcode == 8) {
            const unsigned char *p = payload.bytes;
            int code = payload.length >= 2 ? p[0] << 8 | p[1] : -1;
            NSString *reason = payload.length > 2
                ? [[NSString alloc] initWithBytes:p + 2 length:payload.length - 2 encoding:NSUTF8StringEncoding]
                : @"-";
            log_server([NSString stringWithFormat:@"client closed %d %@", code, reason]);
            send_frame(fd, 8, payload.bytes, payload.length);
            break;
        }
    }
    close(fd);
}

static void *
websocket_server(void *arg)
{
    int listener = (int)(intptr_t)arg;
    for (;;) {
        int fd = accept(listener, NULL, NULL);
        if (fd < 0) break;
        dispatch_async(dispatch_get_global_queue(0, 0), ^{ @autoreleasepool { serve_websocket(fd); } });
    }
    return NULL;
}

/* The stream server: echoes until the client stops writing, then says "done" and closes. */
static void *
stream_server(void *arg)
{
    int listener = (int)(intptr_t)arg;
    for (;;) {
        int fd = accept(listener, NULL, NULL);
        if (fd < 0) break;
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
            char buf[4096];
            ssize_t r;
            while ((r = read(fd, buf, sizeof buf)) > 0) write_full(fd, buf, (size_t)r);
            write_full(fd, "done", 4);
            close(fd);
        });
    }
    return NULL;
}

/* MARK: - The client */

@interface Delegate : NSObject <NSURLSessionWebSocketDelegate, NSURLSessionStreamDelegate>
@property (strong) NSMutableArray<NSString *> *events;
@property (strong) NSInputStream *input;
@property (strong) NSOutputStream *output;
@end

@implementation Delegate
- (instancetype)init
{
    if ((self = [super init])) _events = [NSMutableArray array];
    return self;
}
- (void)note:(NSString *)event
{
    @synchronized(self) { [_events addObject:event]; }
}
- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)task didOpenWithProtocol:(NSString *)protocol
{
    [self note:[NSString stringWithFormat:@"open protocol %@", protocol ?: @"-"]];
}
- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)task
    didCloseWithCode:(NSURLSessionWebSocketCloseCode)code reason:(NSData *)reason
{
    [self note:[NSString stringWithFormat:@"close %ld %@", (long)code,
                         reason ? [[NSString alloc] initWithData:reason encoding:NSUTF8StringEncoding] : @"-"]];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    [self note:[NSString stringWithFormat:@"complete %@ %ld", error.domain ?: @"-", (long)error.code]];
}
- (void)URLSession:(NSURLSession *)session streamTask:(NSURLSessionStreamTask *)task
    didBecomeInputStream:(NSInputStream *)input outputStream:(NSOutputStream *)output
{
    self.input = input;
    self.output = output;
    [self note:@"streams"];
}
- (void)URLSession:(NSURLSession *)session readClosedForStreamTask:(NSURLSessionStreamTask *)task
{
    [self note:@"read closed"];
}
- (void)URLSession:(NSURLSession *)session writeClosedForStreamTask:(NSURLSessionStreamTask *)task
{
    [self note:@"write closed"];
}
@end

static BOOL
wait_for(double seconds, BOOL (^done)(void))
{
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!done() && [until timeIntervalSinceNow] > 0) usleep(10000);
    if (!done() && getenv("WS_TIMES")) fprintf(stderr, "(timed out after %g s)\n", seconds);
    return done();
}

static NSString *
describe_message(NSURLSessionWebSocketMessage *m, NSError *e)
{
    if (e) return [NSString stringWithFormat:@"error %@ %ld", e.domain, (long)e.code];
    if (m.type == NSURLSessionWebSocketMessageTypeString) return [NSString stringWithFormat:@"string %@", m.string];
    return [NSString stringWithFormat:@"data %lu bytes, string %@", (unsigned long)m.data.length, m.string ?: @"-"];
}

/* A receive's result, waited for. */
static NSString *
receive(NSURLSessionWebSocketTask *task)
{
    __block NSString *result = nil;
    [task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *m, NSError *e) { result = describe_message(m, e); }];
    wait_for(10, ^BOOL { return result != nil; });
    return result ?: @"(nothing)";
}

static NSString *
send_message(NSURLSessionWebSocketTask *task, NSURLSessionWebSocketMessage *m)
{
    __block NSString *result = nil;
    [task sendMessage:m completionHandler:^(NSError *e) {
        result = e ? [NSString stringWithFormat:@"error %@ %ld", e.domain, (long)e.code] : @"sent";
    }];
    wait_for(10, ^BOOL { return result != nil; });
    return result ?: @"(nothing)";
}

static void
print_events(Delegate *d)
{
    if (getenv("WS_TIMES")) fprintf(stderr, "[%.2f]\n", CFAbsoluteTimeGetCurrent());
    @synchronized(d) {
        for (NSString *e in d.events) printf("  event: %s\n", e.UTF8String);
        [d.events removeAllObjects];
    }
}

static void
print_server(void)
{
    @synchronized(server_log) {
        for (NSString *e in server_log) printf("  server: %s\n", e.UTF8String);
        [server_log removeAllObjects];
    }
}

static void
websockets(int port)
{
    Delegate *d = [Delegate new];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]
                                                          delegate:d delegateQueue:nil];
    NSString *base = [NSString stringWithFormat:@"ws://127.0.0.1:%d", port];

    NSURLSessionWebSocketMessage *text = [[NSURLSessionWebSocketMessage alloc] initWithString:@"héllo"];
    NSURLSessionWebSocketMessage *data = [[NSURLSessionWebSocketMessage alloc] initWithData:[@"bytes" dataUsingEncoding:NSUTF8StringEncoding]];
    printf("text message: type %ld, data %s, string %s\n", (long)text.type, text.data ? "yes" : "nil", text.string.UTF8String);
    printf("data message: type %ld, data %lu, string %s\n", (long)data.type, (unsigned long)data.data.length, data.string ? "yes" : "nil");

    NSURLSessionWebSocketTask *task = [session webSocketTaskWithURL:[NSURL URLWithString:[base stringByAppendingString:@"/echo"]]
                                                          protocols:@[ @"chat", @"superchat" ]];
    printf("class is a web socket task %d, state %ld, close code %ld, reason %s, max size %ld\n",
        [task isKindOfClass:[NSURLSessionWebSocketTask class]], (long)task.state, (long)task.closeCode,
        task.closeReason ? "yes" : "nil", (long)task.maximumMessageSize);
    printf("request: %s %s://%s%s\n", task.originalRequest.HTTPMethod.UTF8String, task.originalRequest.URL.scheme.UTF8String,
        task.originalRequest.URL.host.UTF8String, task.originalRequest.URL.path.UTF8String);
    [task resume];
    printf("send text: %s\n", send_message(task, text).UTF8String);
    printf("receive: %s\n", receive(task).UTF8String);
    printf("send data: %s\n", send_message(task, data).UTF8String);
    printf("receive: %s\n", receive(task).UTF8String);
    wait_for(5, ^BOOL { return d.events.count >= 1; });
    print_events(d);
    printf("response status %ld\n", (long)[(NSHTTPURLResponse *)task.response statusCode]);

    __block NSString *pong = nil;
    [task sendPingWithPongReceiveHandler:^(NSError *e) { pong = e ? @"error" : @"pong"; }];
    /* (incoming frames, the pong among them, are read while a receive waits) */
    send_message(task, [[NSURLSessionWebSocketMessage alloc] initWithString:@"after ping"]);
    printf("receive after ping: %s\n", receive(task).UTF8String);
    wait_for(10, ^BOOL { return pong != nil; });
    printf("ping: %s\n", pong.UTF8String ?: "(nothing)");

    /* two receives waiting, then two messages */
    __block NSMutableArray *order = [NSMutableArray array];
    for (int i = 0; i < 2; i++)
        [task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *m, NSError *e) {
            @synchronized(order) { [order addObject:describe_message(m, e)]; }
        }];
    send_message(task, [[NSURLSessionWebSocketMessage alloc] initWithString:@"first"]);
    send_message(task, [[NSURLSessionWebSocketMessage alloc] initWithString:@"second"]);
    wait_for(10, ^BOOL { @synchronized(order) { return order.count >= 2; } });
    printf("queued receives: %s\n", [[order componentsJoinedByString:@", "] UTF8String]);

    /* the server closes */
    send_message(task, [[NSURLSessionWebSocketMessage alloc] initWithString:@"close-me"]);
    printf("receive at close: %s\n", receive(task).UTF8String);
    wait_for(10, ^BOOL { @synchronized(d) { return d.events.count >= 2; } });
    print_events(d);
    printf("close code %ld, reason %s, state %ld\n", (long)task.closeCode,
        task.closeReason ? [[NSString alloc] initWithData:task.closeReason encoding:NSUTF8StringEncoding].UTF8String : "nil",
        (long)task.state);
    printf("receive after close: %s\n", receive(task).UTF8String);
    printf("send after close: %s\n", send_message(task, text).UTF8String);
    print_server();

    /* the client closes */
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[base stringByAppendingString:@"/echo"]]];
    [request setValue:@"custom" forHTTPHeaderField:@"X-Test"];
    task = [session webSocketTaskWithRequest:request];
    [task resume];
    printf("echo: %s\n", (send_message(task, text), receive(task)).UTF8String);
    [task cancelWithCloseCode:NSURLSessionWebSocketCloseCodeGoingAway reason:[@"leaving" dataUsingEncoding:NSUTF8StringEncoding]];
    wait_for(10, ^BOOL { @synchronized(server_log) { return server_log.count >= 2; } });
    wait_for(5, ^BOOL { @synchronized(d) { return d.events.count >= 2; } });
    print_server();
    print_events(d);
    printf("after cancel: close code %ld, reason %s, state %ld, error %ld\n", (long)task.closeCode,
        task.closeReason ? [[NSString alloc] initWithData:task.closeReason encoding:NSUTF8StringEncoding].UTF8String : "nil",
        (long)task.state, (long)task.error.code);

    /* too big */
    task = [session webSocketTaskWithURL:[NSURL URLWithString:[base stringByAppendingString:@"/echo"]]];
    [task resume];
    send_message(task, [[NSURLSessionWebSocketMessage alloc] initWithString:@"big"]);
    printf("too big: %s\n", receive(task).UTF8String);
    wait_for(5, ^BOOL { @synchronized(d) { return d.events.count >= 2; } });
    print_events(d);
    printf("close code %ld\n", (long)task.closeCode);
    print_server();

    /* no upgrade */
    task = [session webSocketTaskWithURL:[NSURL URLWithString:[base stringByAppendingString:@"/refuse"]]];
    [task resume];
    printf("refused: %s\n", receive(task).UTF8String);
    wait_for(5, ^BOOL { @synchronized(d) { return d.events.count >= 1; } });
    print_events(d);
    printf("refused response %ld, state %ld\n", (long)[(NSHTTPURLResponse *)task.response statusCode], (long)task.state);
    [session invalidateAndCancel];
}

static void
streams(int port)
{
    Delegate *d = [Delegate new];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]
                                                          delegate:d delegateQueue:nil];
    NSURLSessionStreamTask *task = [session streamTaskWithHostName:@"127.0.0.1" port:port];
    printf("stream task %d, request %s\n", [task isKindOfClass:[NSURLSessionStreamTask class]],
        task.originalRequest ? "yes" : "nil");
    [task resume];
    __block NSString *wrote = nil;
    [task writeData:[@"abcdefghij" dataUsingEncoding:NSUTF8StringEncoding] timeout:10 completionHandler:^(NSError *e) {
        wrote = e ? @"error" : @"written";
    }];
    wait_for(10, ^BOOL { return wrote != nil; });
    printf("write: %s\n", wrote.UTF8String);
    __block NSMutableString *got = [NSMutableString string];
    __block BOOL finished = NO;
    [task readDataOfMinLength:10 maxLength:4 timeout:10 completionHandler:^(NSData *data, BOOL eof, NSError *e) {
        [got appendFormat:@"%@ eof %d error %ld", data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"nil",
                          eof, (long)e.code];
        finished = YES;
    }];
    wait_for(10, ^BOOL { return finished; });
    printf("read min 10 max 4: %s\n", got.UTF8String);
    got = [NSMutableString string];
    finished = NO;
    [task readDataOfMinLength:1 maxLength:100 timeout:10 completionHandler:^(NSData *data, BOOL eof, NSError *e) {
        [got appendFormat:@"%@ eof %d error %ld", data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"nil",
                          eof, (long)e.code];
        finished = YES;
    }];
    wait_for(10, ^BOOL { return finished; });
    printf("read 1-100: %s\n", got.UTF8String);
    [task closeWrite];
    NSMutableString *rest = [NSMutableString string];
    __block BOOL eof = NO;
    while (!eof) {
        finished = NO;
        [task readDataOfMinLength:1 maxLength:100 timeout:10 completionHandler:^(NSData *data, BOOL atEOF, NSError *e) {
            if (data) [rest appendString:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]];
            eof = atEOF || e;
            finished = YES;
        }];
        if (!wait_for(10, ^BOOL { return finished; })) break;
    }
    printf("after closing the write side: %s, eof %d\n", rest.UTF8String, eof);
    wait_for(2, ^BOOL { @synchronized(d) { return d.events.count >= 1; } });
    [task cancel];
    wait_for(5, ^BOOL { @synchronized(d) { return [d.events containsObject:@"complete NSURLErrorDomain -999"] || [d.events containsObject:@"complete - 0"]; } });
    print_events(d);

    /* captured streams */
    task = [session streamTaskWithHostName:@"127.0.0.1" port:port];
    [task resume];
    [task captureStreams];
    wait_for(10, ^BOOL { return d.input != nil; });
    print_events(d);
    [d.input open];
    [d.output open];
    printf("opened: input %ld, output %ld\n", (long)d.input.streamStatus, (long)d.output.streamStatus);
    NSInteger wrote6 = [d.output write:(const uint8_t *)"stream" maxLength:6];
    printf("wrote %ld\n", (long)wrote6);
    [d.output close];
    /* (the captured input stream doesn't block: read what's there until the end) */
    NSMutableData *all = [NSMutableData data];
    wait_for(10, ^BOOL {
        uint8_t buf[64];
        if (d.input.hasBytesAvailable) {
            NSInteger n = [d.input read:buf maxLength:sizeof buf];
            if (n > 0) [all appendBytes:buf length:(NSUInteger)n];
        }
        return all.length >= 6 || d.input.streamStatus == NSStreamStatusAtEnd || d.input.streamStatus == NSStreamStatusError;
    });
    /* (what was echoed: whether closing the output stream half-closes the socket isn't compared) */
    if (all.length > 6) all.length = 6;
    printf("captured: %s\n", [[NSString alloc] initWithData:all encoding:NSUTF8StringEncoding].UTF8String);
    [d.input close];
    [session invalidateAndCancel];
}

int
main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        signal(SIGPIPE, SIG_IGN);
        server_log = [NSMutableArray array];
        int wport, sport;
        int wl = listen_loopback(&wport), sl = listen_loopback(&sport);
        pthread_t t;
        pthread_create(&t, NULL, websocket_server, (void *)(intptr_t)wl);
        pthread_create(&t, NULL, stream_server, (void *)(intptr_t)sl);
        websockets(wport);
        streams(sport);
    }
    return 0;
}
