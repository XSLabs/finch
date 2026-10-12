/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * File promises: NSFilePromiseProvider (a pasteboard writer standing for a file that
 * will be written when it's dropped) and NSFilePromiseReceiver (its reader), with the
 * pasteboard types Apple's write.
 *
 * Each provider gets a promise ID, written as 8 bytes, by which a receiver in the same
 * process finds it and asks its delegate to write the file into the destination;
 * promises from other processes need Finch's drag server, which doesn't keep them yet,
 * so receiving one of those ends in an error.
 */
#import "AppKit_Finch.h"

static NSString *const MetadataType = @"com.apple.NSFilePromiseItemMetaData";
static NSString *const FileNameType = @"com.apple.pasteboard.promised-file-name";
static NSString *const SuggestedNameType = @"com.apple.pasteboard.promised-suggested-file-name";
static NSString *const ContentType = @"com.apple.pasteboard.promised-file-content-type";
static NSString *const PromiseIDType = @"com.apple.pasteboard.NSFilePromiseID";
/* (the older "Apple files promise pasteboard type", as its dynamic type) */
static NSString *const LegacyPromiseType = @"dyn.ah62d4rv4gu8yc6durvwwa3xmrvw1gkdusm1044pxqyuha2pxsvw0e55bsmwca7d3sbwu";

/* Providers by promise ID (weak: a provider goes when its owner lets it go). */
static NSMapTable<NSNumber *, NSFilePromiseProvider *> *
providers(void)
{
    static NSMapTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      table = [[NSMapTable strongToWeakObjectsMapTable] retain];
    });
    return table;
}

@implementation NSFilePromiseProvider {
    NSString *_fileType;
    id<NSFilePromiseProviderDelegate> _delegate; /* (weak) */
    id _userInfo;
    uint64_t _promiseID;
}

- (instancetype)init
{
    if ((self = [super init])) {
        static uint64_t next = 1;
        @synchronized(providers()) {
            _promiseID = next++;
            [providers() setObject:self forKey:@(_promiseID)];
        }
    }
    return self;
}

- (instancetype)initWithFileType:(NSString *)fileType delegate:(id<NSFilePromiseProviderDelegate>)delegate
{
    if ((self = [self init])) {
        _fileType = [fileType copy];
        _delegate = delegate;
    }
    return self;
}

- (void)dealloc
{
    @synchronized(providers()) {
        [providers() removeObjectForKey:@(_promiseID)];
    }
    [_fileType release];
    [_userInfo release];
    [super dealloc];
}

- (NSString *)fileType { return _fileType; }
- (void)setFileType:(NSString *)t { [_fileType autorelease]; _fileType = [t copy]; }
- (id<NSFilePromiseProviderDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<NSFilePromiseProviderDelegate>)d { _delegate = d; }
- (id)userInfo { return _userInfo; }
- (void)setUserInfo:(id)u { [_userInfo autorelease]; _userInfo = [u retain]; }
- (uint64_t)_finchPromiseID { return _promiseID; }

- (NSArray<NSPasteboardType> *)writableTypesForPasteboard:(NSPasteboard *)pasteboard
{
    return @[ MetadataType, FileNameType, SuggestedNameType, ContentType, PromiseIDType ];
}

- (NSPasteboardWritingOptions)writingOptionsForType:(NSPasteboardType)type pasteboard:(NSPasteboard *)pasteboard
{
    return 0;
}

- (id)pasteboardPropertyListForType:(NSPasteboardType)type
{
    if ([type isEqualToString:MetadataType])
        return _fileType ? @{ContentType : _fileType} : @{};
    if ([type isEqualToString:SuggestedNameType])
        return [_delegate filePromiseProvider:self fileNameForType:_fileType];
    if ([type isEqualToString:ContentType])
        return _fileType;
    if ([type isEqualToString:PromiseIDType])
        return [NSData dataWithBytes:&_promiseID length:sizeof _promiseID];
    return nil;
}

@end

@implementation NSFilePromiseReceiver {
    NSArray<NSString *> *_fileTypes, *_fileNames;
    NSString *_suggestedName;
    uint64_t _promiseID;
}

+ (NSArray<NSString *> *)readableDraggedTypes
{
    return @[ MetadataType, LegacyPromiseType, ContentType ];
}

+ (NSArray<NSPasteboardType> *)readableTypesForPasteboard:(NSPasteboard *)pasteboard
{
    return [self readableDraggedTypes];
}

+ (NSPasteboardReadingOptions)readingOptionsForType:(NSPasteboardType)type pasteboard:(NSPasteboard *)pasteboard
{
    return NSPasteboardReadingAsPropertyList;
}

- (instancetype)initWithPasteboardPropertyList:(id)propertyList ofType:(NSPasteboardType)type
{
    if (!(self = [super init]))
        return nil;
    NSString *contentType = [propertyList isKindOfClass:[NSDictionary class]] ? propertyList[ContentType]
                            : [propertyList isKindOfClass:[NSString class]]   ? propertyList
                                                                              : nil;
    NSPasteboardItem *item = FinchPasteboardItemBeingRead();
    if (!contentType)
        contentType = [item stringForType:ContentType];
    _fileTypes = [(contentType ? @[ contentType ] : @[]) copy];
    _suggestedName = [[item stringForType:SuggestedNameType] copy];
    NSData *ident = [item dataForType:PromiseIDType];
    if (ident.length == sizeof _promiseID)
        memcpy(&_promiseID, ident.bytes, sizeof _promiseID);
    return self;
}

- (void)dealloc
{
    [_fileTypes release];
    [_fileNames release];
    [_suggestedName release];
    [super dealloc];
}

- (NSArray<NSString *> *)fileTypes { return _fileTypes; }
- (NSArray<NSString *> *)fileNames { return _fileNames; }

/* Asks the promise's provider (in this process) to write the file into the destination,
   then hands it to the reader on the queue. */
- (void)receivePromisedFilesAtDestination:(NSURL *)destinationDir options:(NSDictionary *)options operationQueue:(NSOperationQueue *)queue
                                   reader:(void (^)(NSURL *, NSError *))reader
{
    NSFilePromiseProvider *provider = nil;
    @synchronized(providers()) {
        provider = [[[providers() objectForKey:@(_promiseID)] retain] autorelease];
    }
    void (^read)(NSURL *, NSError *) = [[reader copy] autorelease];
    if (!provider) {
        NSError *e = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnknownError userInfo:nil];
        [queue addOperationWithBlock:^{
          read(nil, e);
        }];
        return;
    }
    id<NSFilePromiseProviderDelegate> delegate = provider.delegate;
    NSString *name = _suggestedName ?: [delegate filePromiseProvider:provider fileNameForType:provider.fileType] ?: @"Untitled";
    NSURL *url = [destinationDir URLByAppendingPathComponent:name];
    [_fileNames autorelease];
    _fileNames = [@[ name ] copy];
    NSOperationQueue *writing = [delegate respondsToSelector:@selector(operationQueueForFilePromiseProvider:)]
                                    ? [delegate operationQueueForFilePromiseProvider:provider]
                                    : [NSOperationQueue mainQueue];
    [writing addOperationWithBlock:^{
      [delegate filePromiseProvider:provider writePromiseToURL:url
                  completionHandler:^(NSError *error) {
                    [queue addOperationWithBlock:^{
                      read(url, error);
                    }];
                  }];
    }];
}

@end
