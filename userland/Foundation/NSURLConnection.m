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

/* MARK: - NSURLDownload */

/*
 * The older download interface, over a download task, telling its delegate on the run
 * loop it was made on, in Apple's order: the start, the request, the response (with a
 * first count of no bytes), the destination asked for and made, the bytes, the end.
 * Without allowOverwrite: an existing file's name gets "-1" and so on before the extension.
 */
@implementation NSURLDownload {
    NSURLRequest *_request;
    id _delegate;
    NSURLSessionDownloadTask *_task;
    NSRunLoop *_runLoop;
    NSString *_destination;
    BOOL _overwrite, _deletes, _cancelled;
}

+ (BOOL)canResumeDownloadDecodedWithEncodingMIMEType:(NSString *)MIMEType { return NO; }

- (instancetype)initWithRequest:(NSURLRequest *)request delegate:(id<NSURLDownloadDelegate>)delegate
{
    if ((self = [super init])) {
        _request = [request copy];
        _delegate = [(id)delegate retain]; /* until the download ends */
        _runLoop = [[NSRunLoop currentRunLoop] retain];
        _deletes = YES;
        [self retain];
        [self _finchDeliver:^{ [self _finchStart]; }];
    }
    return self;
}

/* (Finch's downloads keep no resume data of NSURLDownload's kind: this starts again) */
- (instancetype)initWithResumeData:(NSData *)resumeData delegate:(id<NSURLDownloadDelegate>)delegate path:(NSString *)path
{
    id info = resumeData ? [NSPropertyListSerialization propertyListWithData:resumeData options:0 format:NULL error:NULL] : nil;
    NSString *url = [info isKindOfClass:[NSDictionary class]] ? info[@"NSURLSessionDownloadURL"] : nil;
    NSURLRequest *r = [NSURLRequest requestWithURL:[NSURL URLWithString:[url isKindOfClass:[NSString class]] ? url : @"finch-invalid-resume-data:"]];
    if ((self = [self initWithRequest:r delegate:delegate]) && path)
        [self setDestination:path allowOverwrite:YES];
    return self;
}

- (void)dealloc
{
    [_request release];
    [_delegate release];
    [_task release];
    [_runLoop release];
    [_destination release];
    [super dealloc];
}

- (NSURLRequest *)request { return _request; }
- (NSData *)resumeData { return nil; }
- (BOOL)deletesFileUponFailure { return _deletes; }
- (void)setDeletesFileUponFailure:(BOOL)deletes { _deletes = deletes; }

- (void)setDestination:(NSString *)path allowOverwrite:(BOOL)allowOverwrite
{
    [_destination autorelease];
    _destination = [path copy];
    _overwrite = allowOverwrite;
}

- (void)_finchDeliver:(void (^)(void))block
{
    CFRunLoopRef loop = [_runLoop getCFRunLoop];
    CFRunLoopPerformBlock(loop, kCFRunLoopDefaultMode, block);
    CFRunLoopWakeUp(loop);
}

- (void)_finchEnd
{
    [_delegate release];
    _delegate = nil;
    [self release];
}

- (void)_finchStart
{
    id d = _delegate;
    if (_cancelled) return [self _finchEnd];
    if ([d respondsToSelector:@selector(downloadDidBegin:)]) [d downloadDidBegin:self];
    if ([d respondsToSelector:@selector(download:willSendRequest:redirectResponse:)]) {
        NSURLRequest *r = [d download:self willSendRequest:_request redirectResponse:nil];
        if (!r) return [self _finchEnd];
        [_request autorelease];
        _request = [r copy];
    }
    _task = [[[NSURLSession sharedSession] downloadTaskWithRequest:_request
                                                 completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        /* (the file is the session's until this returns: move it aside first) */
        NSString *kept = nil;
        if (location) {
            kept = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
            if (![[NSFileManager defaultManager] moveItemAtPath:[location path] toPath:kept error:NULL]) kept = nil;
        }
        [kept retain];
        [response retain];
        [error retain];
        [self _finchDeliver:^{
            [self _finchFinish:kept response:response error:error];
            [kept release];
            [response release];
            [error release];
        }];
    }] retain];
    [_task resume];
}

/* A name not taken in its folder: "name-1.ext", "name-2.ext", ... */
static NSString *
unique_path(NSString *path)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) return path;
    NSString *ext = [path pathExtension], *base = [path stringByDeletingPathExtension];
    for (NSUInteger i = 1;; i++) {
        NSString *p = [NSString stringWithFormat:@"%@-%lu", base, (unsigned long)i];
        if ([ext length]) p = [p stringByAppendingPathExtension:ext];
        if (![fm fileExistsAtPath:p]) return p;
    }
}

- (void)_finchFinish:(NSString *)file response:(NSURLResponse *)response error:(NSError *)error
{
    id d = _delegate;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (_cancelled) {
        if (file) [fm removeItemAtPath:file error:NULL];
        return [self _finchEnd];
    }
    if (error || !file) {
        if ([d respondsToSelector:@selector(download:didFailWithError:)])
            [d download:self didFailWithError:error ?: [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorUnknown userInfo:nil]];
        return [self _finchEnd];
    }
    if ([d respondsToSelector:@selector(download:didReceiveResponse:)]) [d download:self didReceiveResponse:response];
    if ([d respondsToSelector:@selector(download:didReceiveDataOfLength:)]) [d download:self didReceiveDataOfLength:0];
    if (!_destination && [d respondsToSelector:@selector(download:decideDestinationWithSuggestedFilename:)])
        [d download:self decideDestinationWithSuggestedFilename:[response suggestedFilename] ?: @"Unknown"];
    unsigned long long size = [[fm attributesOfItemAtPath:file error:NULL] fileSize];
    if (_destination) {
        NSString *path = _overwrite ? _destination : unique_path(_destination);
        if (_overwrite) [fm removeItemAtPath:path error:NULL];
        NSError *moveError = nil;
        if (![fm moveItemAtPath:file toPath:path error:&moveError]) {
            [fm removeItemAtPath:file error:NULL];
            if ([d respondsToSelector:@selector(download:didFailWithError:)])
                [d download:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotCreateFile userInfo:nil]];
            return [self _finchEnd];
        }
        if ([d respondsToSelector:@selector(download:didCreateDestination:)]) [d download:self didCreateDestination:path];
    } else {
        [fm removeItemAtPath:file error:NULL];
    }
    if ([d respondsToSelector:@selector(download:didReceiveDataOfLength:)]) [d download:self didReceiveDataOfLength:(NSUInteger)size];
    if ([d respondsToSelector:@selector(downloadDidFinish:)]) [d downloadDidFinish:self];
    [self _finchEnd];
}

- (void)cancel
{
    _cancelled = YES;
    [_task cancel];
}

@end
