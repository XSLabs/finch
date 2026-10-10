/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSURLConnection, the URL loading system's older interface, over NSURLSession (as
 * Apple's is now). A connection loads its request and tells its delegate, on the run
 * loop it was scheduled on (the creating thread's, in the default mode, unless
 * scheduled elsewhere) or on its delegate queue: the response, the data, then the
 * end or the failure. The synchronous and block forms wait on, or call back with,
 * the same load.
 */
#import <Foundation/Foundation.h>

@implementation NSURLConnection {
    NSURLRequest *_original, *_current;
    id _delegate;
    NSURLSessionDataTask *_task;
    NSMutableArray *_schedules; /* (run loop, mode) pairs */
    NSOperationQueue *_queue;
    BOOL _started, _cancelled;
}

+ (BOOL)canHandleRequest:(NSURLRequest *)request
{
    NSString *scheme = request.URL.scheme.lowercaseString;
    return [@[ @"http", @"https", @"file", @"data" ] containsObject:scheme ?: @""];
}

+ (NSURLConnection *)connectionWithRequest:(NSURLRequest *)request delegate:(id)delegate
{
    return [[[self alloc] initWithRequest:request delegate:delegate] autorelease];
}

- (instancetype)initWithRequest:(NSURLRequest *)request delegate:(id)delegate startImmediately:(BOOL)startImmediately
{
    if (!(self = [super init]))
        return nil;
    _original = [request copy];
    _current = [request copy];
    _delegate = [delegate retain]; /* held until the load ends, as Apple's */
    _schedules = [NSMutableArray new];
    if (startImmediately) {
        [self scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
        [self start];
    }
    return self;
}

- (instancetype)initWithRequest:(NSURLRequest *)request delegate:(id)delegate
{
    return [self initWithRequest:request delegate:delegate startImmediately:YES];
}

- (void)dealloc
{
    [_original release];
    [_current release];
    [_delegate release];
    [_task release];
    [_schedules release];
    [_queue release];
    [super dealloc];
}

- (NSURLRequest *)originalRequest { return _original; }
- (NSURLRequest *)currentRequest { return _current; }

- (void)scheduleInRunLoop:(NSRunLoop *)aRunLoop forMode:(NSRunLoopMode)mode
{
    if (aRunLoop && mode)
        [_schedules addObject:@[ aRunLoop, mode ]];
}

- (void)unscheduleFromRunLoop:(NSRunLoop *)aRunLoop forMode:(NSRunLoopMode)mode
{
    [_schedules removeObject:@[ aRunLoop, mode ]];
}

- (void)setDelegateQueue:(NSOperationQueue *)queue
{
    [_queue autorelease];
    _queue = [queue retain];
}

/* Runs block where the delegate hears from this connection. */
- (void)_finchDeliver:(void (^)(void))block
{
    if (_queue) {
        [_queue addOperationWithBlock:block];
        return;
    }
    NSArray *where = _schedules.count ? _schedules : @[ @[ [NSRunLoop mainRunLoop], NSDefaultRunLoopMode ] ];
    NSArray *first = where.firstObject;
    NSMutableArray *modes = [NSMutableArray array];
    for (NSArray *s in where)
        if (s[0] == first[0])
            [modes addObject:s[1]];
    CFRunLoopRef loop = [(NSRunLoop *)first[0] getCFRunLoop];
    CFRunLoopPerformBlock(loop, (CFArrayRef)modes, block);
    CFRunLoopWakeUp(loop);
}

- (void)start
{
    if (_started)
        return;
    _started = YES;
    [self retain]; /* until the delegate has heard the end */
    id delegate = _delegate;
    if ([delegate respondsToSelector:@selector(connection:willSendRequest:redirectResponse:)]) {
        NSURLRequest *r = [delegate connection:self willSendRequest:_current redirectResponse:nil];
        if (!r) {
            [self release];
            return;
        }
        [_current autorelease];
        _current = [r copy];
    }
    _task = [[[NSURLSession sharedSession]
        dataTaskWithRequest:_current
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            [self _finchDeliver:^{
              if (!_cancelled) {
                  if (error) {
                      if ([delegate respondsToSelector:@selector(connection:didFailWithError:)])
                          [delegate connection:self didFailWithError:error];
                  } else {
                      if (response && [delegate respondsToSelector:@selector(connection:didReceiveResponse:)])
                          [delegate connection:self didReceiveResponse:response];
                      if (!_cancelled && data.length && [delegate respondsToSelector:@selector(connection:didReceiveData:)])
                          [delegate connection:self didReceiveData:data];
                      if (!_cancelled && [delegate respondsToSelector:@selector(connectionDidFinishLoading:)])
                          [delegate connectionDidFinishLoading:self];
                  }
              }
              [_delegate release];
              _delegate = nil;
              [self release];
            }];
          }] retain];
    [_task resume];
}

- (void)cancel
{
    _cancelled = YES;
    [_task cancel];
}

+ (NSData *)sendSynchronousRequest:(NSURLRequest *)request returningResponse:(NSURLResponse **)response error:(NSError **)error
{
    __block NSData *result = nil;
    __block NSURLResponse *resp = nil;
    __block NSError *err = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:request
          completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
            result = [data retain];
            resp = [r retain];
            err = [e retain];
            dispatch_semaphore_signal(done);
          }];
    [task resume];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    dispatch_release(done);
    if (response)
        *response = [resp autorelease];
    else
        [resp release];
    if (error)
        *error = [err autorelease];
    else
        [err release];
    return [result autorelease];
}

+ (void)sendAsynchronousRequest:(NSURLRequest *)request queue:(NSOperationQueue *)queue
              completionHandler:(void (^)(NSURLResponse *response, NSData *data, NSError *connectionError))handler
{
    void (^h)(NSURLResponse *, NSData *, NSError *) = [[handler copy] autorelease];
    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:request
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            [queue ?: [NSOperationQueue mainQueue] addOperationWithBlock:^{ h(response, data, error); }];
          }];
    [task resume];
}

@end
