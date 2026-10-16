/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * LinkPresentation: fetches HTML page metadata with NSURLSession and presents it as an
 * AppKit card. Image and icon providers fetch their remote bytes only when a caller asks.
 */
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <LinkPresentation/LinkPresentation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

NSErrorDomain const LPErrorDomain = @"LPErrorDomain";

static NSError *
lp_error(LPErrorCode code, NSString *description, NSError *underlying)
{
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (description)
        info[NSLocalizedDescriptionKey] = description;
    if (underlying)
        info[NSUnderlyingErrorKey] = underlying;
    return [NSError errorWithDomain:LPErrorDomain code:code userInfo:info];
}

static NSString *
decode_html(NSString *string)
{
    NSDictionary *entities = @{ @"&amp;" : @"&", @"&quot;" : @"\"", @"&#39;" : @"'", @"&apos;" : @"'",
                                @"&lt;" : @"<", @"&gt;" : @">", @"&nbsp;" : @" " };
    for (NSString *key in entities)
        string = [string stringByReplacingOccurrencesOfString:key withString:entities[key] options:NSCaseInsensitiveSearch range:NSMakeRange(0, string.length)];
    return string;
}

static NSDictionary<NSString *, NSString *> *
tag_attributes(NSString *tag)
{
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"([A-Za-z_:][A-Za-z0-9_:.-]*)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s/>]+))"
                                                                           options:0 error:NULL];
    for (NSTextCheckingResult *match in [regex matchesInString:tag options:0 range:NSMakeRange(0, tag.length)]) {
        NSString *name = [[tag substringWithRange:[match rangeAtIndex:1]] lowercaseString];
        NSString *value = nil;
        for (NSUInteger i = 2; i <= 4; i++)
            if ([match rangeAtIndex:i].location != NSNotFound) {
                value = [tag substringWithRange:[match rangeAtIndex:i]];
                break;
            }
        if (value)
            result[name] = decode_html(value);
    }
    return result;
}

static NSArray<NSString *> *
tag_matches(NSString *html, NSString *name)
{
    NSString *pattern = [NSString stringWithFormat:@"(?is)<%@\\b[^>]*>", name];
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:NULL];
    NSMutableArray *tags = [NSMutableArray array];
    for (NSTextCheckingResult *match in [regex matchesInString:html options:0 range:NSMakeRange(0, html.length)])
        [tags addObject:[html substringWithRange:match.range]];
    return tags;
}

static NSURL *
resolved_url(NSString *string, NSURL *base)
{
    if (!string.length)
        return nil;
    return [NSURL URLWithString:string relativeToURL:base].absoluteURL;
}

static NSItemProvider *
remote_provider(NSURL *url, NSTimeInterval timeout)
{
    if (!url || !([url.scheme.lowercaseString isEqualToString:@"http"] || [url.scheme.lowercaseString isEqualToString:@"https"]))
        return nil;
    NSItemProvider *provider = [[NSItemProvider alloc] init];
    NSString *type = UTTypeImage.identifier ?: @"public.image";
    [provider registerDataRepresentationForTypeIdentifier:type visibility:NSItemProviderRepresentationVisibilityAll
                                               loadHandler:^NSProgress *(void (^completion)(NSData *, NSError *)) {
        NSProgress *progress = [NSProgress progressWithTotalUnitCount:1];
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        request.timeoutInterval = timeout > 0 ? timeout : 30.0;
        NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error)
                completion(nil, error);
            else if ([response isKindOfClass:[NSHTTPURLResponse class]] && ((NSHTTPURLResponse *)response).statusCode >= 400)
                completion(nil, [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadServerResponse userInfo:nil]);
            else {
                progress.completedUnitCount = 1;
                completion(data, nil);
            }
            [session finishTasksAndInvalidate];
        }];
        progress.cancellationHandler = ^{ [task cancel]; [session invalidateAndCancel]; };
        [task resume];
        return progress;
    }];
    return provider;
}

static LPLinkMetadata *
metadata_from_html(NSData *data, NSURL *requestedURL, NSURL *responseURL, BOOL includeSubresources, NSTimeInterval timeout)
{
    NSString *html = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!html)
        html = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    if (!html)
        return nil;
    NSMutableDictionary *meta = [NSMutableDictionary dictionary];
    for (NSString *tag in tag_matches(html, @"meta")) {
        NSDictionary *attributes = tag_attributes(tag);
        NSString *key = [(NSString *)(attributes[@"property"] ?: attributes[@"name"] ?: attributes[@"itemprop"]) lowercaseString];
        NSString *value = attributes[@"content"];
        if (key.length && value.length && !meta[key])
            meta[key] = value;
    }
    NSString *title = meta[@"og:title"] ?: meta[@"twitter:title"] ?: meta[@"title"];
    if (!title.length) {
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(?is)<title\\b[^>]*>(.*?)</title>" options:0 error:NULL];
        NSTextCheckingResult *match = [regex firstMatchInString:html options:0 range:NSMakeRange(0, html.length)];
        if (match) {
            title = [html substringWithRange:[match rangeAtIndex:1]];
            title = [title stringByReplacingOccurrencesOfString:@"<[^>]+>" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, title.length)];
            title = decode_html([title stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]);
        }
    }
    LPLinkMetadata *metadata = [[LPLinkMetadata alloc] init];
    metadata.originalURL = requestedURL;
    metadata.URL = responseURL ?: requestedURL;
    metadata.title = title.length ? title : nil;
    metadata.remoteVideoURL = resolved_url(meta[@"og:video:secure_url"] ?: meta[@"og:video"] ?: meta[@"twitter:player"], responseURL ?: requestedURL);
    if (includeSubresources) {
        NSURL *imageURL = resolved_url(meta[@"og:image:secure_url"] ?: meta[@"og:image"] ?: meta[@"twitter:image"], responseURL ?: requestedURL);
        NSURL *iconURL = nil;
        for (NSString *tag in tag_matches(html, @"link")) {
            NSDictionary *attributes = tag_attributes(tag);
            NSString *rel = [(NSString *)attributes[@"rel"] lowercaseString];
            if ([rel containsString:@"icon"]) {
                iconURL = resolved_url(attributes[@"href"], responseURL ?: requestedURL);
                if (iconURL)
                    break;
            }
        }
        metadata.imageProvider = remote_provider(imageURL, timeout);
        metadata.iconProvider = remote_provider(iconURL, timeout);
    }
    return metadata;
}

@implementation LPLinkMetadata {
    NSURL *_originalURL;
    NSURL *_URL;
    NSString *_title;
    NSItemProvider *_iconProvider;
    NSItemProvider *_imageProvider;
    NSItemProvider *_videoProvider;
    NSURL *_remoteVideoURL;
}

+ (BOOL)supportsSecureCoding { return YES; }
- (NSURL *)originalURL { return _originalURL; }
- (void)setOriginalURL:(NSURL *)value { _originalURL = value; }
- (NSURL *)URL { return _URL; }
- (void)setURL:(NSURL *)value { _URL = value; }
- (NSString *)title { return _title; }
- (void)setTitle:(NSString *)value { _title = [value copy]; }
- (NSItemProvider *)iconProvider { return _iconProvider; }
- (void)setIconProvider:(NSItemProvider *)value { _iconProvider = value; }
- (NSItemProvider *)imageProvider { return _imageProvider; }
- (void)setImageProvider:(NSItemProvider *)value { _imageProvider = value; }
- (NSItemProvider *)videoProvider { return _videoProvider; }
- (void)setVideoProvider:(NSItemProvider *)value { _videoProvider = value; }
- (NSURL *)remoteVideoURL { return _remoteVideoURL; }
- (void)setRemoteVideoURL:(NSURL *)value { _remoteVideoURL = value; }
- (id)copyWithZone:(NSZone *)zone
{
    LPLinkMetadata *copy = [[[self class] allocWithZone:zone] init];
    copy.originalURL = _originalURL;
    copy.URL = _URL;
    copy.title = _title;
    copy.iconProvider = _iconProvider;
    copy.imageProvider = _imageProvider;
    copy.videoProvider = _videoProvider;
    copy.remoteVideoURL = _remoteVideoURL;
    return copy;
}
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_originalURL forKey:@"originalURL"];
    [coder encodeObject:_URL forKey:@"URL"];
    [coder encodeObject:_title forKey:@"title"];
    [coder encodeObject:_iconProvider forKey:@"iconProvider"];
    [coder encodeObject:_imageProvider forKey:@"imageProvider"];
    [coder encodeObject:_videoProvider forKey:@"videoProvider"];
    [coder encodeObject:_remoteVideoURL forKey:@"remoteVideoURL"];
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super init])) {
        _originalURL = [coder decodeObjectOfClass:[NSURL class] forKey:@"originalURL"];
        _URL = [coder decodeObjectOfClass:[NSURL class] forKey:@"URL"];
        _title = [coder decodeObjectOfClass:[NSString class] forKey:@"title"];
        _iconProvider = [coder decodeObjectOfClass:[NSItemProvider class] forKey:@"iconProvider"];
        _imageProvider = [coder decodeObjectOfClass:[NSItemProvider class] forKey:@"imageProvider"];
        _videoProvider = [coder decodeObjectOfClass:[NSItemProvider class] forKey:@"videoProvider"];
        _remoteVideoURL = [coder decodeObjectOfClass:[NSURL class] forKey:@"remoteVideoURL"];
    }
    return self;
}
@end

@implementation LPMetadataProvider {
    BOOL _shouldFetchSubresources;
    NSTimeInterval _timeout;
    BOOL _started, _cancelled, _completed;
    NSURLSession *_session;
    NSURLSessionDataTask *_task;
    void (^_completion)(LPLinkMetadata *, NSError *);
}
- (instancetype)init
{
    if ((self = [super init])) {
        _shouldFetchSubresources = YES;
        _timeout = 30.0;
    }
    return self;
}
- (BOOL)shouldFetchSubresources { return _shouldFetchSubresources; }
- (void)setShouldFetchSubresources:(BOOL)value { _shouldFetchSubresources = value; }
- (NSTimeInterval)timeout { return _timeout; }
- (void)setTimeout:(NSTimeInterval)value { _timeout = value; }
- (void)startFetchingMetadataForURL:(NSURL *)url completionHandler:(void (^)(LPLinkMetadata *, NSError *))completion
{
    NSURLRequest *request = url ? [NSURLRequest requestWithURL:url] : nil;
    [self startFetchingMetadataForRequest:request completionHandler:completion];
}
- (void)startFetchingMetadataForRequest:(NSURLRequest *)request completionHandler:(void (^)(LPLinkMetadata *, NSError *))completion
{
    @synchronized(self) {
        if (_started)
            [NSException raise:NSInternalInconsistencyException format:@"A metadata provider can fetch only one request."];
        _started = YES;
        _completion = [completion copy];
    }
    NSURL *url = request.URL;
    NSString *scheme = url.scheme.lowercaseString;
    if (!url || !([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])) {
        [self _finishWithMetadata:nil error:lp_error(LPErrorMetadataFetchNotAllowed, @"Only HTTP and HTTPS pages can be fetched.", nil)];
        return;
    }
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    _session = [NSURLSession sessionWithConfiguration:configuration];
    NSMutableURLRequest *mutable = [request mutableCopy];
    mutable.timeoutInterval = _timeout > 0 ? _timeout : 30.0;
    __weak LPMetadataProvider *weakSelf = self;
    _task = [_session dataTaskWithRequest:mutable completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        LPMetadataProvider *strongSelf = weakSelf;
        if (!strongSelf)
            return;
        if (strongSelf->_cancelled || error.code == NSURLErrorCancelled) {
            [strongSelf _finishWithMetadata:nil error:lp_error(LPErrorMetadataFetchCancelled, @"The metadata request was cancelled.", error)];
            return;
        }
        if (error) {
            LPErrorCode code = error.code == NSURLErrorTimedOut ? LPErrorMetadataFetchTimedOut : LPErrorMetadataFetchFailed;
            [strongSelf _finishWithMetadata:nil error:lp_error(code, error.localizedDescription, error)];
            return;
        }
        if ([response isKindOfClass:[NSHTTPURLResponse class]] && ((NSHTTPURLResponse *)response).statusCode >= 400) {
            NSError *status = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadServerResponse
                                              userInfo:@{ NSLocalizedDescriptionKey : [NSString stringWithFormat:@"The page returned HTTP %ld.", (long)((NSHTTPURLResponse *)response).statusCode] }];
            [strongSelf _finishWithMetadata:nil error:lp_error(LPErrorMetadataFetchFailed, status.localizedDescription, status)];
            return;
        }
        NSURL *finalURL = response.URL ?: url;
        LPLinkMetadata *metadata = metadata_from_html(data ?: [NSData data], url, finalURL, strongSelf->_shouldFetchSubresources, strongSelf->_timeout);
        if (!metadata)
            [strongSelf _finishWithMetadata:nil error:lp_error(LPErrorMetadataFetchFailed, @"The page was not valid text.", nil)];
        else
            [strongSelf _finishWithMetadata:metadata error:nil];
    }];
    [_task resume];
}
- (void)_finishWithMetadata:(LPLinkMetadata *)metadata error:(NSError *)error
{
    void (^completion)(LPLinkMetadata *, NSError *) = nil;
    @synchronized(self) {
        if (_completed)
            return;
        _completed = YES;
        completion = _completion;
        _completion = nil;
    }
    [_session finishTasksAndInvalidate];
    if (completion)
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ completion(metadata, error); });
}
- (void)cancel
{
    NSURLSessionDataTask *task = nil;
    @synchronized(self) {
        if (_completed)
            return;
        _cancelled = YES;
        task = _task;
    }
    if (task)
        [task cancel];
    else
        [self _finishWithMetadata:nil error:lp_error(LPErrorMetadataFetchCancelled, @"The metadata request was cancelled.", nil)];
}
@end

@implementation LPLinkView {
    LPLinkMetadata *_metadata;
    NSTextField *_titleField;
    NSTextField *_URLField;
    NSImageView *_imageView;
}
- (instancetype)initWithURL:(NSURL *)url
{
    LPLinkMetadata *metadata = [[LPLinkMetadata alloc] init];
    metadata.originalURL = url;
    metadata.URL = url;
    return [self initWithMetadata:metadata];
}
- (instancetype)initWithMetadata:(LPLinkMetadata *)metadata
{
    if ((self = [super initWithFrame:NSMakeRect(0, 0, 360, 112)]))
        [self setMetadata:metadata];
    return self;
}
- (LPLinkMetadata *)metadata { return _metadata; }
- (void)setMetadata:(LPLinkMetadata *)metadata
{
    _metadata = [metadata copy] ?: [[LPLinkMetadata alloc] init];
    if (!_titleField) {
        _imageView = [[NSImageView alloc] initWithFrame:NSZeroRect];
        _imageView.imageScaling = NSImageScaleProportionallyUpOrDown;
        _titleField = [NSTextField labelWithString:@""];
        _titleField.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
        _titleField.lineBreakMode = NSLineBreakByTruncatingTail;
        _URLField = [NSTextField labelWithString:@""];
        _URLField.font = [NSFont systemFontOfSize:11];
        _URLField.textColor = [NSColor secondaryLabelColor];
        _URLField.lineBreakMode = NSLineBreakByTruncatingTail;
        [self addSubview:_imageView];
        [self addSubview:_titleField];
        [self addSubview:_URLField];
    }
    NSURL *url = _metadata.URL ?: _metadata.originalURL;
    _titleField.stringValue = _metadata.title.length ? _metadata.title : (url.host ?: url.absoluteString ?: @"");
    _URLField.stringValue = url.host ?: url.absoluteString ?: @"";
    _imageView.image = nil;
    NSItemProvider *provider = _metadata.imageProvider ?: _metadata.iconProvider;
    NSString *type = provider.registeredTypeIdentifiers.firstObject;
    if (provider && type) {
        __weak LPLinkView *weakSelf = self;
        [provider loadDataRepresentationForTypeIdentifier:type completionHandler:^(NSData *data, NSError *error) {
            if (!data || error)
                return;
            NSImage *image = [[NSImage alloc] initWithData:data];
            dispatch_async(dispatch_get_main_queue(), ^{
                LPLinkView *strongSelf = weakSelf;
                if (strongSelf && strongSelf->_metadata == _metadata) {
                    strongSelf->_imageView.image = image;
                    [strongSelf setNeedsLayout:YES];
                }
            });
        }];
    }
    [self setNeedsDisplay:YES];
    [self setNeedsLayout:YES];
}
- (NSSize)intrinsicContentSize { return NSMakeSize(360, 112); }
- (void)drawRect:(NSRect)dirtyRect
{
    NSRect bounds = NSInsetRect(self.bounds, 1, 1);
    [[NSColor controlBackgroundColor] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:bounds xRadius:10 yRadius:10] fill];
    [[NSColor separatorColor] setStroke];
    [[NSBezierPath bezierPathWithRoundedRect:bounds xRadius:10 yRadius:10] stroke];
}
- (void)layout
{
    [super layout];
    CGFloat inset = 14;
    CGFloat imageSize = _imageView.image ? 72 : 0;
    CGFloat left = inset + (imageSize ? imageSize + 12 : 0);
    if (imageSize)
        _imageView.frame = NSMakeRect(inset, floor((NSHeight(self.bounds) - imageSize) / 2), imageSize, imageSize);
    _titleField.frame = NSMakeRect(left, NSHeight(self.bounds) - 52, MAX(0, NSWidth(self.bounds) - left - inset), 24);
    _URLField.frame = NSMakeRect(left, NSHeight(self.bounds) - 76, MAX(0, NSWidth(self.bounds) - left - inset), 18);
}
@end
