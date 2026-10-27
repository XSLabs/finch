/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-do-test: Distributed Objects between two processes: a server
 * registered by name, a client calling it through a proxy (values by copy,
 * structures, out-parameters, oneway calls, exceptions, callbacks to the
 * client), and the connection, coder and name-server API around it; message
 * ports, socket ports with Distributed Objects over TCP, and CFMessagePort
 * requests and replies between processes (diff Apple's and Finch's).
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#include <spawn.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>

extern char **environ;

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

@protocol Counter
- (int)add:(int)n;
- (NSString *)greet:(NSString *)name;
- (oneway void)ping;
- (int)pings;
- (NSArray *)items;
- (NSDictionary *)table;
- (double)scale:(double)x by:(float)y;
- (NSRect)grow:(NSRect)r;
- (NSRange)rangeOf:(NSString *)needle;
- (void)fill:(out int *)value;
- (void)twice:(inout int *)value;
- (id)echo:(id)object;
- (void)fail;
- (int)callBack:(id)client;
- (BOOL)isProxyArgument:(id)object;
- (char)letter;
- (unsigned long long)big;
@end

@interface Server : NSObject <Counter>
@property int total;
@property int pingCount;
@end
@implementation Server
- (int)add:(int)n { self.total += n; return self.total; }
- (NSString *)greet:(NSString *)name { return [@"hello " stringByAppendingString:name]; }
- (oneway void)ping { self.pingCount++; }
- (int)pings { return self.pingCount; }
- (NSArray *)items { return @[ @1, @"two", @{ @"k" : @3 }, [NSData dataWithBytes:"ab" length:2], [NSNull null] ]; }
- (NSDictionary *)table { return @{ @"when" : [NSDate dateWithTimeIntervalSinceReferenceDate:60], @"url" : [NSURL URLWithString:@"https://example.org/a"] }; }
- (double)scale:(double)x by:(float)y { return x * y; }
- (NSRect)grow:(NSRect)r { return NSInsetRect(r, -1, -2); }
- (NSRange)rangeOf:(NSString *)needle { return [@"finch on darwin" rangeOfString:needle]; }
- (void)fill:(out int *)value { *value = 42; }
- (void)twice:(inout int *)value { *value *= 2; }
- (id)echo:(id)object { return object; }
- (void)fail { [NSException raise:@"ServerFailure" format:@"failed on purpose %d", 7]; }
- (int)callBack:(id)client { return [client add:100] + 1; }
- (BOOL)isProxyArgument:(id)object { return [object isProxy]; }
- (char)letter { return 'F'; }
- (unsigned long long)big { return 0xFEEDFACECAFEBEEFULL; }
@end

@interface Client : NSObject
@end
@implementation Client
- (int)add:(int)n { return n * 2; }
@end

static void
api(void)
{
    printf("== api\n");
    NSConnection *c = [NSConnection new];
    printf("ports equal %d receive class %s\n", c.sendPort == c.receivePort, NSStringFromClass([c.receivePort class]).UTF8String);
    printf("valid %d timeouts %g %g modes %s\n", c.isValid, c.requestTimeout, c.replyTimeout, [[c.requestModes componentsJoinedByString:@","] UTF8String]);
    printf("in all %d\n", [[NSConnection allConnections] containsObject:c]);
    printf("statistics present %d\n", [c.statistics count] > 0);
    printf("local %lu remote %lu\n", (unsigned long)c.localObjects.count, (unsigned long)c.remoteObjects.count);
    [c addRequestMode:@"FinchMode"];
    printf("modes after add %s\n", [[c.requestModes componentsJoinedByString:@","] UTF8String]);
    [c removeRequestMode:@"FinchMode"];
    __block int died = 0;
    id token = [[NSNotificationCenter defaultCenter] addObserverForName:NSConnectionDidDieNotification object:c queue:nil
                                                             usingBlock:^(NSNotification *n) { died++; }];
    [c invalidate];
    printf("after invalidate valid %d died %d in all %d\n", c.isValid, died, [[NSConnection allConnections] containsObject:c]);
    [[NSNotificationCenter defaultCenter] removeObserver:token];
    NSConnection *pair = [NSConnection connectionWithReceivePort:[NSMachPort port] sendPort:nil];
    printf("pair send is receive %d\n", pair.sendPort == pair.receivePort);
    printf("unknown name %s\n", [NSConnection connectionWithRegisteredName:@"org.finch.no-such-name" host:nil] ? "found" : "nil");
    printf("default server %s mach %s message %s socket %s\n", NSStringFromClass([[NSPortNameServer systemDefaultPortNameServer] class]).UTF8String,
           NSStringFromClass([[NSMachBootstrapServer sharedInstance] class]).UTF8String,
           NSStringFromClass([[NSMessagePortNameServer sharedInstance] class]).UTF8String,
           NSStringFromClass([[NSSocketPortNameServer sharedInstance] class]).UTF8String);
    printf("message lookup %s\n", [[NSMessagePortNameServer sharedInstance] portForName:@"org.finch.none"] ? "found" : "nil");
    printf("remote host %s\n", [[NSMachBootstrapServer sharedInstance] portForName:@"x" host:@"elsewhere.example"] ? "found" : "nil");
    printf("bycopy %d byref %d keyed %d\n", [NSPortCoder instancesRespondToSelector:@selector(isBycopy)],
           [NSPortCoder instancesRespondToSelector:@selector(isByref)], [NSPortCoder instancesRespondToSelector:@selector(allowsKeyedCoding)]);
    printf("class for port coder %s %s\n", NSStringFromClass([@"s" classForPortCoder]).UTF8String, NSStringFromClass([[NSObject new] classForPortCoder]).UTF8String);
    [pair invalidate];
}

@interface Echo : NSObject
- (NSString *)shout:(NSString *)s;
@end
@implementation Echo
- (NSString *)shout:(NSString *)s { return [s uppercaseString]; }
@end

static CFDataRef
reverse(CFMessagePortRef port, SInt32 msgid, CFDataRef data, void *info)
{
    NSMutableData *reply = [NSMutableData data];
    const uint8_t *bytes = CFDataGetBytePtr(data);
    for (CFIndex i = CFDataGetLength(data); i > 0; i--) [reply appendBytes:&bytes[i - 1] length:1];
    uint8_t id = (uint8_t)msgid;
    [reply appendBytes:&id length:1];
    return CFBridgingRetain(reply);
}

/* A CFMessagePort that answers with its request reversed and the msgid. */
static int
serve_messages(const char *name, int fd)
{
    @autoreleasepool {
        CFMessagePortRef port = CFMessagePortCreateLocal(NULL, (__bridge CFStringRef)@(name), reverse, NULL, NULL);
        char ok = port ? 'y' : 'n';
        write(fd, &ok, 1);
        CFRunLoopSourceRef source = CFMessagePortCreateRunLoopSource(NULL, port, 0);
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopDefaultMode);
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 30, false);
    }
    return 0;
}

/* Distributed Objects over a TCP socket port; reports the port it listens on. */
static int
serve_socket(int fd)
{
    @autoreleasepool {
        NSSocketPort *p = [[NSSocketPort alloc] initWithTCPPort:0];
        NSConnection *c = [NSConnection connectionWithReceivePort:p sendPort:nil];
        c.rootObject = [Echo new];
        const struct sockaddr_in *a = p.address.bytes;
        unsigned short port = ntohs(a->sin_port);
        write(fd, &port, sizeof port);
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:30]];
    }
    return 0;
}

static pid_t
spawn(char *self, char *mode, char *name, int fd)
{
    char number[16];
    snprintf(number, sizeof number, "%d", fd);
    char *args[] = { self, mode, name, number, NULL };
    pid_t child = 0;
    posix_spawn(&child, self, NULL, NULL, args, environ);
    return child;
}

static void
ports(char *self)
{
    printf("== ports\n");
    NSMessagePort *m = (NSMessagePort *)[NSMessagePort port];
    printf("message class %s valid %d\n", NSStringFromClass([m class]).UTF8String, m.isValid);
    char name[64];
    snprintf(name, sizeof name, "org.finch.do-test.msg.%d", getpid());
    printf("message register %d\n", [[NSMessagePortNameServer sharedInstance] registerPort:m name:@(name)]);
    NSPort *found = [[NSMessagePortNameServer sharedInstance] portForName:@(name)];
    printf("message lookup %s class %s\n", found ? "found" : "nil", NSStringFromClass([found class]).UTF8String);
    NSSocketPort *s = [NSSocketPort new];
    const struct sockaddr_in *a = s.address.bytes;
    printf("socket family %d type %d protocol %d has-socket %d address %s port-set %d\n", s.protocolFamily, s.socketType, s.protocol,
           s.socket >= 0, inet_ntoa(a->sin_addr), a->sin_port != 0);
    NSSocketPort *r = [[NSSocketPort alloc] initRemoteWithTCPPort:4321 host:@"127.0.0.1"];
    const struct sockaddr_in *ra = r.address.bytes;
    printf("remote socket %d port %d address %s\n", r.socket, ntohs(ra->sin_port), inet_ntoa(ra->sin_addr));
    NSSocketPort *r2 = [[NSSocketPort alloc] initRemoteWithTCPPort:4321 host:@"127.0.0.1"];
    printf("remote same object %d equal %d\n", r == r2, [r isEqual:r2]);
    [s invalidate];
    printf("after invalidate %d\n", s.isValid);

    int ready[2];
    pipe(ready);
    snprintf(name, sizeof name, "org.finch.do-test.cf.%d", getpid());
    pid_t child = spawn(self, "messages", name, ready[1]);
    char ok = 0;
    read(ready[0], &ok, 1);
    printf("cf message server %c\n", ok);
    CFMessagePortRef remote = CFMessagePortCreateRemote(NULL, (__bridge CFStringRef)@(name));
    CFDataRef reply = NULL;
    NSData *request = [@"finch" dataUsingEncoding:NSUTF8StringEncoding];
    SInt32 status = remote ? CFMessagePortSendRequest(remote, 7, (__bridge CFDataRef)request, 5, 5, kCFRunLoopDefaultMode, &reply) : -99;
    printf("cf send %d reply %s\n", (int)status, reply ? [[(__bridge NSData *)reply description] UTF8String] : "none");
    if (remote) CFRelease(remote);
    kill(child, SIGTERM);
    waitpid(child, NULL, 0);

    pipe(ready);
    child = spawn(self, "socket", name, ready[1]);
    unsigned short port = 0;
    read(ready[0], &port, sizeof port);
    NSSocketPort *server = [[NSSocketPort alloc] initRemoteWithTCPPort:port host:@"127.0.0.1"];
    NSConnection *c = [NSConnection connectionWithReceivePort:[NSSocketPort new] sendPort:server];
    printf("socket shout %s\n", [[(id)c.rootProxy shout:@"over tcp"] UTF8String]);
    kill(child, SIGTERM);
    waitpid(child, NULL, 0);
}

static int
serve(const char *name, int fd)
{
    @autoreleasepool {
        Server *server = [Server new];
        NSConnection *c = [NSConnection new];
        c.rootObject = server;
        char ok = [c registerName:[NSString stringWithUTF8String:name]] ? 'y' : 'n';
        write(fd, &ok, 1);
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:30]];
    }
    return 0;
}

int
main(int argc, char **argv)
{
    if (argc == 4 && !strcmp(argv[1], "server")) return serve(argv[2], atoi(argv[3]));
    if (argc == 4 && !strcmp(argv[1], "messages")) return serve_messages(argv[2], atoi(argv[3]));
    if (argc == 4 && !strcmp(argv[1], "socket")) return serve_socket(atoi(argv[3]));
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        api();
        ports(argv[0]);
        printf("== remote\n");
        char name[128], fd[16];
        snprintf(name, sizeof name, "org.finch.do-test.%d", getpid());
        int ready[2];
        pipe(ready);
        snprintf(fd, sizeof fd, "%d", ready[1]);
        char *args[] = { argv[0], "server", name, fd, NULL };
        pid_t child = 0;
        posix_spawn(&child, argv[0], NULL, NULL, args, environ);
        char ok = 0;
        read(ready[0], &ok, 1);
        printf("server registered %c\n", ok);
        alarm(60);
        NSString *service = [NSString stringWithUTF8String:name];
        NSConnection *again = [NSConnection new];
        printf("second registration %d\n", [again registerName:service]);
        [again invalidate];
        id proxy = [NSConnection rootProxyForConnectionWithRegisteredName:service host:nil];
        printf("proxy %d class %s\n", proxy != nil, NSStringFromClass([proxy class]).UTF8String);
        [proxy setProtocolForProxy:@protocol(Counter)];
        printf("add %d %d\n", [proxy add:2], [proxy add:3]);
        printf("greet %s\n", [[proxy greet:@"finch"] UTF8String]);
        [proxy ping];
        [proxy ping];
        printf("pings %d\n", [proxy pings]);
        NSArray *items = [proxy items];
        printf("items %s array %d proxy %d\n", [[items description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "].UTF8String,
               [items isKindOfClass:[NSArray class]], [items isProxy]);
        NSDictionary *table = [proxy table];
        printf("table %s url %s\n", [[table[@"when"] description] UTF8String], [[table[@"url"] absoluteString] UTF8String]);
        printf("scale %g\n", [proxy scale:1.5 by:4]);
        printf("grow %s\n", NSStringFromRect([proxy grow:NSMakeRect(1, 2, 3, 4)]).UTF8String);
        printf("range %s\n", NSStringFromRange([proxy rangeOf:@"darwin"]).UTF8String);
        int v = 0;
        [proxy fill:&v];
        printf("fill %d\n", v);
        v = 21;
        [proxy twice:&v];
        printf("twice %d\n", v);
        printf("letter %c big %llx\n", [proxy letter], [proxy big]);
        id e = [proxy echo:[NSDate dateWithTimeIntervalSinceReferenceDate:5]];
        printf("echo date %s %d\n", [[e description] UTF8String], [e isKindOfClass:[NSDate class]]);
        printf("echo nil %d\n", [proxy echo:nil] == nil);
        @try {
            [proxy fail];
        } @catch (NSException *x) {
            printf("exception %s: %s\n", x.name.UTF8String, [x.reason stringByReplacingOccurrencesOfString:@"\n" withString:@" | "].UTF8String);
        }
        Client *client = [Client new];
        printf("callback %d\n", [proxy callBack:client]);
        printf("client arrives as proxy %d\n", [proxy isProxyArgument:client]);
        id me = [proxy echo:client];
        printf("echo local same %d proxy %d class %s equal %d\n", me == client, [me isProxy], NSStringFromClass(object_getClass(me)).UTF8String, [me isEqual:client]);
        printf("respondsTo add %d nope %d\n", [proxy respondsToSelector:@selector(add:)], [proxy respondsToSelector:@selector(nope)]);
        NSConnection *conn = [proxy connectionForProxy];
        printf("connection valid %d timeouts %g %g\n", conn.isValid, conn.requestTimeout, conn.replyTimeout);
        printf("root proxy same %d\n", conn.rootProxy == proxy);
        kill(child, SIGTERM);
        waitpid(child, NULL, 0);
    }
    return 0;
}
