/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Classes Foundation still exports from older or narrower APIs
 * (docs/design/FOUNDATION.md), as Apple's behave:
 *
 *   - NSKeyValueSharedObservers (<Foundation/NSKeyValueSharedObservers.h>):
 *     observers gathered once for a class, then given to each of its
 *     instances from a snapshot (-setSharedObservers:), which replaces the
 *     instance's last snapshot. Only instances of exactly that class take one;
 *     the initial notification isn't sent.
 *   - NSSimpleCString and NSConstantString (<Foundation/NSString.h>): strings
 *     over a byte array in the layout -fconstant-string-class gives them, read
 *     as Mac OS Roman. Constant ones are immortal.
 *   - NSURLHandle (<Foundation/NSURLHandle.h>, gone since 10.4's NSURLConnection):
 *     a URL's data loaded in the foreground or background, for its clients; the
 *     class is abstract, and file: URLs get NSFileURLHandle.
 *   - NSFileProviderService: a file provider's service, which Finch has no
 *     providers to offer: asking for a connection gets no answer, as with Apple's
 *     when no provider is behind it.
 *   - NSSpellServer (<Foundation/NSSpellServer.h>): a spelling service's side;
 *     it registers its languages and runs, with no one yet to ask it.
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#include "Foundation_Finch.h"

/* MARK: - NSKeyValueSharedObservers */

@interface _FinchSharedObserver : NSObject {
@public
    NSObject *_observer; /* (not retained, as KVO doesn't) */
    NSString *_key;
    NSKeyValueObservingOptions _options;
    void *_context;
}
@end
@implementation _FinchSharedObserver
- (void)dealloc
{
    [_key release];
    [super dealloc];
}
@end

@interface NSKeyValueSharedObserversSnapshot () {
@public
    Class _class;
    NSArray *_observers;
}
@end

@implementation NSKeyValueSharedObserversSnapshot
- (void)dealloc
{
    [_observers release];
    [super dealloc];
}
@end

@interface NSKeyValueSharedObservers () {
    Class _class;
    NSMutableArray *_observers;
}
@end

@implementation NSKeyValueSharedObservers

- (id)initWithObservableClass:(Class)observableClass
{
    if ((self = [super init])) {
        _class = observableClass;
        _observers = [[NSMutableArray alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [_observers release];
    [super dealloc];
}

- (void)addSharedObserver:(NSObject *)observer forKey:(NSString *)key options:(NSKeyValueObservingOptions)options context:(void *)context
{
    _FinchSharedObserver *o = [[_FinchSharedObserver alloc] init];
    o->_observer = observer;
    o->_key = [key copy];
    o->_options = options & ~NSKeyValueObservingOptionInitial;
    o->_context = context;
    @synchronized(self) {
        [_observers addObject:o];
    }
    [o release];
}

- (NSKeyValueSharedObserversSnapshot *)snapshot
{
    NSKeyValueSharedObserversSnapshot *s = [[(id)[NSKeyValueSharedObserversSnapshot alloc] init] autorelease];
    s->_class = _class;
    @synchronized(self) {
        s->_observers = [_observers copy];
    }
    return s;
}

@end

static const char shared_observers_key = 0;

@implementation NSObject (NSKeyValueSharedObserverRegistration)

- (void)setSharedObservers:(NSKeyValueSharedObserversSnapshot *)sharedObservers
{
    if (sharedObservers && object_getClass(self) != sharedObservers->_class && [self class] != sharedObservers->_class)
        [NSException raise:NSInternalInconsistencyException
                    format:@"%@: Attempted to set shared observers from snapshot %@, which is targetting a different class", self,
                           sharedObservers];
    NSKeyValueSharedObserversSnapshot *old = objc_getAssociatedObject(self, &shared_observers_key);
    for (_FinchSharedObserver *o in old ? old->_observers : nil)
        [self removeObserver:o->_observer forKeyPath:o->_key context:o->_context];
    for (_FinchSharedObserver *o in sharedObservers ? sharedObservers->_observers : nil)
        [self addObserver:o->_observer forKeyPath:o->_key options:o->_options context:o->_context];
    objc_setAssociatedObject(self, &shared_observers_key, sharedObservers, OBJC_ASSOCIATION_RETAIN);
}

@end

/* MARK: - NSSimpleCString, NSConstantString */

/* Mac OS Roman's upper half, as Unicode. */
static unichar
mac_roman(uint8_t byte)
{
    static unichar upper[128];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        uint8_t all[128];
        for (int i = 0; i < 128; i++) all[i] = (uint8_t)(128 + i);
        CFStringRef s = CFStringCreateWithBytes(NULL, all, 128, kCFStringEncodingMacRoman, false);
        CFStringGetCharacters(s, CFRangeMake(0, 128), upper);
        CFRelease(s);
    });
    return byte < 128 ? byte : upper[byte - 128];
}

@implementation NSSimpleCString

- (NSUInteger)length { return (NSUInteger)numBytes; }

- (unichar)characterAtIndex:(NSUInteger)index
{
    if (index >= (NSUInteger)numBytes)
        FinchRaise(NSRangeException, "*** -[%s characterAtIndex:]: Index %lu out of bounds; string length %lu", object_getClassName(self),
            (unsigned long)index, (unsigned long)numBytes);
    return mac_roman((uint8_t)bytes[index]);
}

- (void)getCharacters:(unichar *)buffer range:(NSRange)range
{
    if (NSMaxRange(range) > (NSUInteger)numBytes)
        FinchRaise(NSRangeException, "*** -[%s getCharacters:range:]: Range {%lu, %lu} out of bounds; string length %lu",
            object_getClassName(self), (unsigned long)range.location, (unsigned long)range.length, (unsigned long)numBytes);
    for (NSUInteger i = 0; i < range.length; i++)
        buffer[i] = mac_roman((uint8_t)bytes[range.location + i]);
}

/* (the bytes themselves, as Apple's gives them) */
- (const char *)UTF8String
{
    NSMutableData *d = [NSMutableData dataWithBytes:bytes length:(NSUInteger)numBytes];
    [d appendBytes:"" length:1];
    return (const char *)[d bytes];
}

- (NSStringEncoding)fastestEncoding { return NSMacOSRomanStringEncoding; }
- (NSStringEncoding)smallestEncoding { return NSMacOSRomanStringEncoding; }
- (NSUInteger)cStringLength { return (NSUInteger)numBytes; }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }

@end

@implementation NSConstantString

- (id)retain { return self; }
- (oneway void)release { }
- (id)autorelease { return self; }
- (NSUInteger)retainCount { return NSUIntegerMax; }

@end

/* MARK: - NSURLHandle */

/* (as Apple's: NSURLHandle is abstract; file: URLs have NSFileURLHandle) */
@interface NSFileURLHandle : NSURLHandle
@end

static NSMutableArray *handle_classes;
static NSMutableDictionary *cached_handles;

/* (Apple's ivars hold the clients, the data and the status; the URL and a failure's
   reason are kept alongside) */
@interface NSURLHandle () {
@protected
    NSURL *_url;
    NSString *_failure;
}
@end

void NSRequestConcreteImplementation(id self, SEL cmd, Class absClass);

@implementation NSURLHandle

static void
register_defaults(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle_classes = [[NSMutableArray alloc] initWithObjects:[NSFileURLHandle class], nil];
        cached_handles = [[NSMutableDictionary alloc] init];
    });
}

+ (void)registerURLHandleClass:(Class)anURLHandleSubclass
{
    register_defaults();
    @synchronized([NSURLHandle class]) {
        if (anURLHandleSubclass && ![handle_classes containsObject:anURLHandleSubclass]) [handle_classes addObject:anURLHandleSubclass];
    }
}

+ (Class)URLHandleClassForURL:(NSURL *)anURL
{
    register_defaults();
    @synchronized([NSURLHandle class]) {
        for (Class c in [handle_classes reverseObjectEnumerator])
            if ([c canInitWithURL:anURL]) return c;
    }
    return Nil;
}

+ (BOOL)canInitWithURL:(NSURL *)anURL { return NO; }

/* One handle a URL, kept: of the class that can take it. */
+ (NSURLHandle *)cachedHandleForURL:(NSURL *)anURL
{
    Class cls = self == [NSURLHandle class] ? [self URLHandleClassForURL:anURL] : self;
    if (!cls || !anURL) return nil;
    @synchronized([NSURLHandle class]) {
        NSURLHandle *h = cached_handles[anURL];
        if (!h) {
            h = [[[cls alloc] initWithURL:anURL cached:YES] autorelease];
            if (h) cached_handles[anURL] = h;
        }
        return h;
    }
}

- (id)initWithURL:(NSURL *)anURL cached:(BOOL)willCache
{
    if ((self = [super init])) {
        _url = [anURL copy];
        _data = [[NSMutableData alloc] init];
        _clients = [[NSMutableArray alloc] init];
        _status = NSURLHandleNotLoaded;
    }
    return self;
}

- (void)dealloc
{
    [_url release];
    [_data release];
    [_failure release];
    [_clients release];
    [super dealloc];
}

- (NSURLHandleStatus)status { return _status; }
- (NSString *)failureReason { return _status == NSURLHandleLoadFailed ? _failure : nil; }
- (void)addClient:(id<NSURLHandleClient>)client
{
    if (client && ![_clients containsObject:client]) [_clients addObject:client];
}
- (void)removeClient:(id<NSURLHandleClient>)client { [_clients removeObject:client]; }

- (NSData *)loadInForeground
{
    NSRequestConcreteImplementation(self, _cmd, [NSURLHandle class]);
    return nil;
}
- (id)propertyForKey:(NSString *)propertyKey
{
    NSRequestConcreteImplementation(self, _cmd, [NSURLHandle class]);
    return nil;
}
- (BOOL)writeData:(NSData *)data
{
    NSRequestConcreteImplementation(self, _cmd, [NSURLHandle class]);
    return NO;
}

- (NSData *)resourceData
{
    if (_status == NSURLHandleLoadSucceeded) return [[_data copy] autorelease];
    NSData *d = [self loadInForeground];
    if (d) {
        [_data setLength:0];
        [self didLoadBytes:d loadComplete:YES];
    }
    return d;
}

- (NSData *)availableResourceData { return [[_data copy] autorelease]; }
- (long long)expectedResourceDataSize { return _status == NSURLHandleLoadSucceeded ? (long long)[_data length] : -1; }
- (void)flushCachedData
{
    [_data setLength:0];
    _status = NSURLHandleNotLoaded;
}

- (void)loadInBackground
{
    _status = NSURLHandleLoadInProgress;
    for (id<NSURLHandleClient> c in [[_clients copy] autorelease])
        [c URLHandleResourceDidBeginLoading:self];
    [self beginLoadInBackground];
}

/* (on another thread; the clients hear on the main run loop) */
- (void)beginLoadInBackground
{
    [self retain];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSData *d = [[self loadInForeground] retain];
        CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopDefaultMode, ^{
            if (_status == NSURLHandleLoadInProgress) {
                if (d) [self didLoadBytes:d loadComplete:YES];
                else [self backgroundLoadDidFailWithReason:@"The resource couldn't be loaded."];
            }
            [d release];
            [self release];
        });
        CFRunLoopWakeUp(CFRunLoopGetMain());
    });
}

- (void)cancelLoadInBackground { [self endLoadInBackground]; }

- (void)endLoadInBackground
{
    if (_status != NSURLHandleLoadInProgress) return;
    _status = NSURLHandleNotLoaded;
    for (id<NSURLHandleClient> c in [[_clients copy] autorelease])
        [c URLHandleResourceDidCancelLoading:self];
}

- (void)backgroundLoadDidFailWithReason:(NSString *)reason
{
    _status = NSURLHandleLoadFailed;
    [_failure autorelease];
    _failure = [reason copy];
    for (id<NSURLHandleClient> c in [[_clients copy] autorelease])
        [c URLHandle:self resourceDidFailLoadingWithReason:reason];
}

- (void)didLoadBytes:(NSData *)newBytes loadComplete:(BOOL)yorn
{
    if (newBytes) [_data appendData:newBytes];
    for (id<NSURLHandleClient> c in [[_clients copy] autorelease])
        if (newBytes) [c URLHandle:self resourceDataDidBecomeAvailable:newBytes];
    if (yorn) {
        _status = NSURLHandleLoadSucceeded;
        for (id<NSURLHandleClient> c in [[_clients copy] autorelease])
            [c URLHandleResourceDidFinishLoading:self];
    }
}

- (id)propertyForKeyIfAvailable:(NSString *)propertyKey { return [self propertyForKey:propertyKey]; }
- (BOOL)writeProperty:(id)propertyValue forKey:(NSString *)propertyKey { return NO; }

@end

@implementation NSFileURLHandle

+ (BOOL)canInitWithURL:(NSURL *)anURL { return [anURL isFileURL]; }
- (NSData *)loadInForeground { return [NSData dataWithContentsOfURL:_url]; }
- (id)propertyForKey:(NSString *)propertyKey { return [[[NSFileManager defaultManager] attributesOfItemAtPath:[_url path] error:NULL] objectForKey:propertyKey]; }
- (BOOL)writeData:(NSData *)data { return [data writeToURL:_url atomically:YES]; }

@end

/* MARK: - NSFileProviderService */

@implementation NSFileProviderService

- (void)dealloc
{
    [_name release];
    [super dealloc];
}

- (NSString *)name { return _name; }

/* (as Apple's with no provider behind the service: no connection, and no answer) */
- (void)getFileProviderConnectionWithCompletionHandler:(void (^)(NSXPCConnection *, NSError *))completionHandler
{
}

@end

/* MARK: - NSSpellServer */

@implementation NSSpellServer {
    id<NSSpellServerDelegate> _delegate;
    NSMutableArray *_languages;
}

- (void)dealloc
{
    [_languages release];
    [super dealloc];
}

- (id<NSSpellServerDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<NSSpellServerDelegate>)delegate { _delegate = delegate; }

- (BOOL)registerLanguage:(NSString *)language byVendor:(NSString *)vendor
{
    if (!language) return NO;
    if (!_languages) _languages = [[NSMutableArray alloc] init];
    [_languages addObject:@[ language, vendor ?: @"" ]];
    return YES;
}

/* The words a user taught the spelling service (~/Library/Spelling/LocalDictionary, one a line). */
- (BOOL)isWordInUserDictionaries:(NSString *)word caseSensitive:(BOOL)flag
{
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Spelling/LocalDictionary"];
    NSString *all = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    for (NSString *w in [all componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]])
        if (flag ? [w isEqualToString:word] : [w caseInsensitiveCompare:word] == NSOrderedSame) return YES;
    return NO;
}

- (void)run { [[NSRunLoop currentRunLoop] run]; }

@end

/* MARK: - Protocols */

/* The delegate protocols Apple's Foundation carries at run time (objc_getProtocol finds
   them) though nothing in Finch's adopts them: referenced here so the image has them. */
__attribute__((used)) static void
keep_protocols(Protocol *__unsafe_unretained *out)
{
    Protocol *kept[] = {
    @protocol(NSCacheDelegate), @protocol(NSExtensionRequestHandling), @protocol(NSFilePresenter),
    @protocol(NSKeyedArchiverDelegate), @protocol(NSStreamDelegate), @protocol(NSURLConnectionDataDelegate),
    @protocol(NSURLConnectionDelegate), @protocol(NSURLSessionDataDelegate), @protocol(NSURLSessionDelegate),
    @protocol(NSURLSessionStreamDelegate), @protocol(NSURLSessionTaskDelegate), @protocol(NSXMLParserDelegate),
    @protocol(NSXPCListenerDelegate), @protocol(NSURLSessionWebSocketDelegate), @protocol(NSURLSessionDownloadDelegate),
    @protocol(NSURLDownloadDelegate), @protocol(NSURLHandleClient), @protocol(NSSpellServerDelegate),
    @protocol(NSUserActivityDelegate), @protocol(NSNetServiceDelegate), @protocol(NSNetServiceBrowserDelegate),
    @protocol(NSPortDelegate), @protocol(NSMachPortDelegate), @protocol(NSMetadataQueryDelegate),
    @protocol(NSFileManagerDelegate), @protocol(NSLocking), @protocol(NSDecimalNumberBehaviors),
    };
    if (out) memcpy(out, kept, sizeof kept);
}
