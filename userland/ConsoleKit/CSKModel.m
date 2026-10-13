/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * ConsoleKit, Finch's own (the private framework Console.app is built on): the model
 * classes. Log entities and messages, filters, load ranges, column layouts, menu item
 * representations, the host device and its manager, the file system of log reports, and
 * the directory and file-tail observers. Enum values, names and descriptions are
 * Apple's (filter types 0-16, comparisons 0-3, message types 1-5, the host device's
 * type 14 and UDID "OSX-HOST").
 */
#import "ConsoleKit.h"
#include <sys/stat.h>

@protocol CSKFinchDeviceManagerDelegate <NSObject>
@optional
- (void)deviceManager:(CSKDeviceManager *)m deviceDidConnect:(CSKDevice *)d;
- (void)deviceManager:(CSKDeviceManager *)m deviceDidTrust:(CSKDevice *)d;
@end

/* ---- CSKHelpers ---- */

@implementation CSKHelpers
+ (NSString *)formattedNumberFromUnsignedInteger:(NSUInteger)n
{
    return [NSNumberFormatter localizedStringFromNumber:@(n) numberStyle:NSNumberFormatterDecimalStyle];
}
@end

/* ---- CSKEntity, CSKMessage ---- */

@implementation CSKEntity

- (NSNumber *)identifier { return _identifierNumber; }
- (NSString *)processImagePath { return _processImagePathString; }
- (NSString *)libraryImagePath { return _libraryImagePathString; }

- (NSString *)formattedTime
{
    if (!_formattedTime && _timestamp) {
        static NSDateFormatter *f;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            f = [NSDateFormatter new];
            f.dateFormat = @"HH:mm:ss.SSSSSS";
        });
        _formattedTime = [f stringFromDate:_timestamp];
    }
    return _formattedTime;
}

- (NSString *)formattedDateTime
{
    if (!_formattedDateTime && _timestamp) {
        static NSDateFormatter *f;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            f = [NSDateFormatter new];
            f.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSSSSSZ";
        });
        _formattedDateTime = [f stringFromDate:_timestamp];
    }
    return _formattedDateTime;
}

- (BOOL)isEqual:(id)o
{
    return [o isKindOfClass:[CSKEntity class]] && [_identifierNumber isEqual:((CSKEntity *)o)->_identifierNumber];
}

- (NSUInteger)hash { return _identifierNumber.hash; }
- (NSString *)stringDescriptionForIndexer { return self.description; }
- (NSUInteger)stringDescriptionLengthForIndexer { return self.description.length; }
- (NSString *)pasteboardDescriptionForProperties:(NSArray *)properties { return self.description; }

@end

@implementation CSKMessage

+ (NSString *)localizedMessageTypeNameForType:(NSInteger)type
{
    switch (type) {
    case CSKMessageTypeInfo: return @"info";
    case CSKMessageTypeDebug: return @"debug";
    case CSKMessageTypeError: return @"error";
    case CSKMessageTypeFault: return @"fault";
    default: return @"default";
    }
}

- (NSString *)message { return _messageText; }

- (NSString *)description
{
    NSMutableString *s = [NSMutableString stringWithFormat:@"%@\t%@\t%@\t%@", self.formattedDateTime ?: @"",
                                                          [CSKMessage localizedMessageTypeNameForType:_type], self.processName ?: @"",
                                                          self.processIdentifier ?: @""];
    if (_subsystem.length || _category.length)
        [s appendFormat:@"\t%@\t%@", _subsystem ?: @"", _category ?: @""];
    [s appendFormat:@"\t%@", _messageText ?: @""];
    return s;
}

- (NSString *)debugDescription { return [NSString stringWithFormat:@"<%@: %p> %@", self.class, self, self.description]; }
- (NSString *)pasteboardDescriptionForProperties:(NSArray *)properties { return self.description; }

- (BOOL)isEqual:(id)o
{
    return [o isKindOfClass:[CSKMessage class]] && [self.identifier isEqual:((CSKMessage *)o).identifier];
}

- (NSUInteger)hash { return self.identifier.hash; }

@end

/* ---- CSKFilter ---- */

@implementation CSKFilter

+ (BOOL)supportsSecureCoding { return YES; }

+ (NSString *)localizedFilterTypeNameForType:(NSInteger)type
{
    static NSArray *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @[ @"Process", @"PID", @"Library", @"Any", @"Thread ID", @"Message", @"Message Type", @"Message Type", @"Message ID",
                   @"Subsystem", @"Category", @"Activity Name", @"Activity ID", @"Parent Activity ID", @"Process Path", @"Library Path",
                   @"Date & Time" ];
    });
    return type >= 0 && (NSUInteger)type < names.count ? names[type] : @"Any";
}

+ (NSString *)localizedFilterComparisonTypeNameForComparisonType:(NSInteger)type
{
    switch (type) {
    case CSKFilterComparisonDoesNotContain: return @"Does Not Contain";
    case CSKFilterComparisonEquals: return @"Equals";
    case CSKFilterComparisonDoesNotEqual: return @"Does Not Equal";
    default: return @"Contains";
    }
}

- (instancetype)initWithType:(NSInteger)type value:(NSString *)value
{
    if ((self = [super init])) {
        _type = type;
        _value = value;
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)c
{
    if ((self = [super init])) {
        _type = [c decodeIntegerForKey:@"type"];
        _comparisonType = [c decodeIntegerForKey:@"comparisonType"];
        _value = [c decodeObjectOfClass:[NSString class] forKey:@"value"];
        _number = [c decodeObjectOfClass:[NSNumber class] forKey:@"number"];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)c
{
    [c encodeInteger:_type forKey:@"type"];
    [c encodeInteger:_comparisonType forKey:@"comparisonType"];
    [c encodeObject:_value forKey:@"value"];
    [c encodeObject:_number forKey:@"number"];
}

- (id)copyWithZone:(NSZone *)zone
{
    CSKFilter *f = [[CSKFilter alloc] initWithType:_type value:_value];
    f.comparisonType = _comparisonType;
    f.number = _number;
    return f;
}

- (BOOL)isEqual:(id)o
{
    if (![o isKindOfClass:[CSKFilter class]])
        return NO;
    CSKFilter *f = o;
    return f.type == _type && f.comparisonType == _comparisonType && (f.value == _value || [f.value isEqual:_value]);
}

- (NSUInteger)hash { return (NSUInteger)_type * 31 + (NSUInteger)_comparisonType * 7 + _value.hash; }

- (NSString *)description
{
    return [NSString stringWithFormat:@"Type: %ld - Comparison Type: %ld - Value: %@", (long)_type, (long)_comparisonType, _value];
}

- (NSString *)debugDescription { return [NSString stringWithFormat:@"<%@: %p> %@", self.class, self, self.description]; }

/* The text of a message a filter of this type looks at. */
static NSString *
field(CSKMessage *m, NSInteger type)
{
    switch (type) {
    case CSKFilterTypeProcess: return m.processName;
    case CSKFilterTypePID: return m.processIdentifier.stringValue;
    case CSKFilterTypeLibrary: return m.libraryName;
    case CSKFilterTypeThreadID: return m.threadIdentifier;
    case CSKFilterTypeMessage: return m.message;
    case CSKFilterTypeMessageType:
    case CSKFilterTypeMessageType2: return [CSKMessage localizedMessageTypeNameForType:m.type];
    case CSKFilterTypeSubsystem: return m.subsystem;
    case CSKFilterTypeCategory: return m.category;
    case CSKFilterTypeProcessPath: return m.processImagePath;
    case CSKFilterTypeLibraryPath: return m.libraryImagePath;
    default: return nil;
    }
}

- (BOOL)matchesMessage:(CSKMessage *)m
{
    if (!_value.length)
        return YES;
    NSArray *texts = _type == CSKFilterTypeAny
                         ? @[ m.message ?: @"", m.processName ?: @"", m.subsystem ?: @"", m.category ?: @"", m.libraryName ?: @"" ]
                         : @[ field(m, _type) ?: @"" ];
    BOOL hit = NO;
    for (NSString *t in texts) {
        if (_comparisonType == CSKFilterComparisonEquals || _comparisonType == CSKFilterComparisonDoesNotEqual)
            hit = [t caseInsensitiveCompare:_value] == NSOrderedSame;
        else
            hit = [t rangeOfString:_value options:NSCaseInsensitiveSearch].location != NSNotFound;
        if (hit)
            break;
    }
    BOOL negated = _comparisonType == CSKFilterComparisonDoesNotContain || _comparisonType == CSKFilterComparisonDoesNotEqual;
    return negated ? !hit : hit;
}

@end

/* ---- CSKLoadRange ---- */

@implementation CSKLoadRange

- (instancetype)initWithIdentifier:(NSUInteger)identifier interval:(NSDateInterval *)interval
{
    if ((self = [super init])) {
        _identifier = identifier;
        _interval = interval;
    }
    return self;
}

- (NSString *)localizedDescription
{
    if (!_interval)
        return @"All";
    NSDateComponentsFormatter *f = [NSDateComponentsFormatter new];
    f.unitsStyle = NSDateComponentsFormatterUnitsStyleFull;
    f.maximumUnitCount = 1;
    return [NSString stringWithFormat:@"Last %@", [f stringFromTimeInterval:_interval.duration]];
}

- (BOOL)isEqual:(id)o { return [o isKindOfClass:[CSKLoadRange class]] && ((CSKLoadRange *)o).identifier == _identifier; }
- (NSUInteger)hash { return _identifier; }
- (NSString *)description { return [NSString stringWithFormat:@"<%@: %p> %lu %@", self.class, self, (unsigned long)_identifier, _interval]; }

@end

/* ---- CSKMenuItemRepresentation ---- */

@implementation CSKMenuItemRepresentation

- (instancetype)initWithProperty:(NSString *)property
{
    if ((self = [super init]))
        _property = [property copy];
    return self;
}

@end

/* ---- CSKStreamArchiveStatisticsEntry ---- */

@implementation CSKStreamArchiveStatisticsEntry
- (NSString *)description { return [NSString stringWithFormat:@"%@: %@ (%@%%)", _path, _entityCount, _entityPercentage]; }
@end

/* ---- column layouts ---- */

@implementation CSKTableColumnLayout

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)init
{
    if ((self = [super init])) {
        _layoutColumnIdentifiers = [[self class] defaultColumnIdentifiers];
        _layoutColumnsCanBeReordered = YES;
        _layoutColumnInitialWidths = @{};
    }
    return self;
}

+ (NSArray *)defaultColumnIdentifiers { return @[ CSKColumnType, CSKColumnTime, CSKColumnProcess, CSKColumnMessage ]; }

+ (NSArray *)allColumnIdentifiers
{
    return @[ CSKColumnType, CSKColumnTime, CSKColumnProcess, CSKColumnPID, CSKColumnThread, CSKColumnSubsystem, CSKColumnCategory,
              CSKColumnLibrary, CSKColumnMessage ];
}

+ (NSString *)titleForColumnIdentifier:(NSString *)identifier
{
    static NSDictionary *titles;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        titles = @{CSKColumnType : @"Type", CSKColumnTime : @"Time", CSKColumnProcess : @"Process", CSKColumnPID : @"PID",
                   CSKColumnThread : @"Thread", CSKColumnSubsystem : @"Subsystem", CSKColumnCategory : @"Category",
                   CSKColumnLibrary : @"Library", CSKColumnMessage : @"Message"};
    });
    return titles[identifier] ?: identifier;
}

/* The layout's columns with one shown or hidden. */
+ (NSArray *)updatedTableColumnIdentifiersFromLayout:(CSKTableColumnLayout *)layout tableColumnIdentifier:(NSString *)identifier
{
    NSMutableArray *ids = [layout.layoutColumnIdentifiers mutableCopy] ?: [NSMutableArray array];
    if ([ids containsObject:identifier]) {
        if (ids.count > 1)
            [ids removeObject:identifier];
    } else {
        NSArray *all = [[layout class] allColumnIdentifiers];
        NSUInteger want = [all indexOfObject:identifier], at = ids.count;
        for (NSUInteger i = 0; i < ids.count; i++)
            if ([all indexOfObject:ids[i]] > want) {
                at = i;
                break;
            }
        [ids insertObject:identifier atIndex:at];
    }
    return ids;
}

- (void)fillTableColumnsMenu:(NSMenu *)menu usingBlock:(void (^)(NSMenuItem *))block
{
    [menu removeAllItems];
    for (NSString *ident in [[self class] allColumnIdentifiers]) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:[[self class] titleForColumnIdentifier:ident] action:NULL keyEquivalent:@""];
        item.representedObject = ident;
        item.state = [_layoutColumnIdentifiers containsObject:ident] ? NSControlStateValueOn : NSControlStateValueOff;
        [menu addItem:item];
        if (block)
            block(item);
    }
}

- (instancetype)initWithCoder:(NSCoder *)c
{
    if ((self = [self init])) {
        NSArray *ids = [c decodeObjectOfClasses:[NSSet setWithObjects:[NSArray class], [NSString class], nil] forKey:@"identifiers"];
        if (ids.count)
            _layoutColumnIdentifiers = ids;
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)c { [c encodeObject:_layoutColumnIdentifiers forKey:@"identifiers"]; }

@end

@implementation CSKMessagesTableColumnLayout
@end
@implementation CSKActivitiesTableColumnLayout
+ (NSArray *)defaultColumnIdentifiers { return @[ CSKColumnTime, CSKColumnProcess, CSKColumnMessage ]; }
@end
@implementation CSKArchiveMessagesTableColumnLayout
@end
@implementation CSKArchiveActivitiesTableColumnLayout
@end
@implementation CSKASLTableColumnLayout
+ (NSArray *)defaultColumnIdentifiers { return @[ CSKColumnTime, CSKColumnProcess, CSKColumnMessage ]; }
@end

/* ---- CSKDevice, CSKDeviceManager ---- */

@implementation CSKDevice

+ (CSKDevice *)hostDevice
{
    static CSKDevice *host;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        host = [[CSKDevice alloc] init];
        host->_name = [[NSHost currentHost] localizedName] ?: @"This Mac";
        host->_UDID = @"OSX-HOST";
        host->_type = 14;
        host->_state = 1;
        host->_isHostDevice = YES;
        host->_supportsLogsPersistenceReading = YES;
        host->_modelID = @"Mac";
        NSOperatingSystemVersion v = [NSProcessInfo processInfo].operatingSystemVersion;
        host->_version = [NSString stringWithFormat:@"%ld.%ld", (long)v.majorVersion, (long)v.minorVersion];
        host->_icon = [NSImage imageNamed:NSImageNameComputer];
    });
    return host;
}

- (BOOL)isEqualToDevice:(CSKDevice *)d { return [d.UDID isEqualToString:_UDID]; }
- (BOOL)isEqual:(id)o { return [o isKindOfClass:[CSKDevice class]] && [self isEqualToDevice:o]; }
- (NSUInteger)hash { return _UDID.hash; }

/* The host trusts itself; there are no other devices to pair with yet. */
- (BOOL)establishTrustWithFailingHandler:(void (^)(NSInteger))handler { return YES; }

@end

@implementation CSKDeviceManager

+ (CSKDeviceManager *)sharedManager
{
    static CSKDeviceManager *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [CSKDeviceManager new]; });
    return m;
}

/* The Mac itself. (Finch can't reach other devices' logs yet.) */
- (NSArray *)allDevices { return @[ [CSKDevice hostDevice] ]; }

/* A new delegate hears of the devices already there (the Mac, connected and trusted), as
   Apple's tells it as each one appears. */
- (void)setDelegate:(id)delegate
{
    _delegate = delegate;
    if (!delegate)
        return;
    dispatch_async(dispatch_get_main_queue(), ^{
        id<CSKFinchDeviceManagerDelegate> d = self.delegate;
        for (CSKDevice *dev in self.allDevices) {
            if ([d respondsToSelector:@selector(deviceManager:deviceDidConnect:)])
                [d deviceManager:self deviceDidConnect:dev];
            if ([d respondsToSelector:@selector(deviceManager:deviceDidTrust:)])
                [d deviceManager:self deviceDidTrust:dev];
        }
    });
}

@end

/* ---- the file system of log reports ---- */

@implementation CSKFileNode

- (NSArray *)children { return _mutableChildren; }

- (instancetype)init
{
    if ((self = [super init]))
        _mutableChildren = [NSMutableArray array];
    return self;
}

- (NSString *)description { return [NSString stringWithFormat:@"<%@: %p> %@ (%lu)", self.class, self, _url.path, (unsigned long)_mutableChildren.count]; }

@end

@implementation CSKFileSystem

+ (CSKFileSystem *)sharedInstance
{
    static CSKFileSystem *fs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ fs = [CSKFileSystem new]; });
    return fs;
}

- (instancetype)init
{
    if ((self = [super init]))
        _systemSerialQueue = dispatch_queue_create("com.apple.ConsoleKit.filesystem", DISPATCH_QUEUE_SERIAL);
    return self;
}

static BOOL
has_ext(NSURL *u, NSArray *exts)
{
    return [exts containsObject:u.pathExtension.lowercaseString];
}

+ (BOOL)doesURLPointToValidFile:(NSURL *)url
{
    NSNumber *regular = nil;
    [url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:NULL];
    return regular.boolValue && [[NSFileManager defaultManager] isReadableFileAtPath:url.path];
}

+ (BOOL)isFileAtURLCrashLogFile:(NSURL *)url { return has_ext(url, @[ @"crash", @"ips", @"panic", @"hang" ]); }
+ (BOOL)isFileAtURLSpinLogFile:(NSURL *)url { return has_ext(url, @[ @"spin", @"cpu_resource", @"diag", @"wakeups_resource" ]); }
+ (BOOL)isFileAtURLJSONFile:(NSURL *)url { return has_ext(url, @[ @"json" ]); }
+ (BOOL)isFileAtURLCoreAnalyticsFile:(NSURL *)url { return has_ext(url, @[ @"core_analytics" ]); }
+ (BOOL)isFileAtURLASLFile:(NSURL *)url { return has_ext(url, @[ @"asl" ]); }
+ (BOOL)isFileAtPathValidASLFile:(NSString *)path { return [path.pathExtension isEqualToString:@"asl"]; }
+ (BOOL)isFileAtPathValidKtraceLogFile:(NSString *)path { return [@[ @"ktrace", @"trace", @"atrc" ] containsObject:path.pathExtension]; }
+ (BOOL)isFileAtPathValidLogArchive:(NSString *)path { return [path.pathExtension isEqualToString:@"logarchive"]; }

+ (BOOL)isFileAtURLLogFile:(NSURL *)url
{
    if (has_ext(url, @[ @"log", @"txt", @"out", @"err" ]))
        return YES;
    /* rotated logs: system.log.0, install.log.1.gz isn't readable as text */
    NSString *name = url.lastPathComponent;
    return [name rangeOfString:@".log."].location != NSNotFound && ![name hasSuffix:@".gz"] && ![name hasSuffix:@".bz2"];
}

+ (BOOL)isFileAtURLMiscLogFile:(NSURL *)url
{
    return ![self isFileAtURLLogFile:url] && ![self isFileAtURLCrashLogFile:url] && ![self isFileAtURLSpinLogFile:url] &&
           [self doesURLPointToValidFile:url];
}

/* A folder's files, as file nodes (Apple's leaves its subfolders out). */
static NSArray *
files_in(NSURL *url, BOOL deep)
{
    NSMutableArray *out = [NSMutableArray array];
    NSDirectoryEnumerationOptions opts = NSDirectoryEnumerationSkipsHiddenFiles | NSDirectoryEnumerationSkipsPackageDescendants;
    if (!deep)
        opts |= NSDirectoryEnumerationSkipsSubdirectoryDescendants;
    NSDirectoryEnumerator *e = [[NSFileManager defaultManager] enumeratorAtURL:url
                                                    includingPropertiesForKeys:@[ NSURLIsRegularFileKey ]
                                                                       options:opts
                                                                  errorHandler:^BOOL(NSURL *u, NSError *err) { return YES; }];
    for (NSURL *u in e) {
        NSNumber *regular = nil;
        [u getResourceValue:&regular forKey:NSURLIsRegularFileKey error:NULL];
        if (!regular.boolValue && ![u.pathExtension isEqualToString:@"logarchive"])
            continue;
        CSKFileNode *n = [CSKFileNode new];
        n.url = u;
        n.name = u.lastPathComponent;
        [out addObject:n];
    }
    [out sortUsingComparator:^NSComparisonResult(CSKFileNode *x, CSKFileNode *y) { return [x.name localizedStandardCompare:y.name]; }];
    return out;
}

- (void)asyncFetchFilesAtURL:(NSURL *)url target:(id)target completionHandler:(void (^)(id, NSArray *))completion
{
    dispatch_async(_systemSerialQueue, ^{
        NSArray *files = files_in(url, NO);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion)
                completion(target, files);
        });
    });
}

- (void)asyncDeepFetchFilesAtURL:(NSURL *)url target:(id)target completionHandler:(void (^)(id, NSArray *))completion
{
    [self asyncDeepFetchFilesAtURL:url queue:dispatch_get_main_queue() target:target progress:nil completion:completion];
}

- (void)asyncDeepFetchFilesAtURL:(NSURL *)url queue:(dispatch_queue_t)queue target:(id)target
                        progress:(void (^)(id, NSArray *))progress
                      completion:(void (^)(id, NSArray *))completion
{
    dispatch_async(_systemSerialQueue, ^{
        NSArray *files = files_in(url, YES);
        dispatch_async(queue ?: dispatch_get_main_queue(), ^{
            if (progress)
                progress(target, files);
            if (completion)
                completion(target, files);
        });
    });
}

@end

/* ---- observers ---- */

/* A directory observer: watches its directories (vnode events, recursively if asked)
   and reports which changed, no more often than its event interval. */
@implementation CSKDirectoryObserver {
    NSArray *_urls;
    void (^_handler)(CSKDirectoryObserver *, NSArray *, BOOL);
    NSMutableArray *_sources;
    NSMutableSet *_pending;
    BOOL _scheduled;
}

- (instancetype)init { return [self initWithURLs:@[] eventHandler:nil]; }
- (instancetype)initWithURL:(NSURL *)url eventHandler:(void (^)(CSKDirectoryObserver *, NSArray *, BOOL))handler
{
    return [self initWithURLs:url ? @[ url ] : @[] eventHandler:handler];
}

- (instancetype)initWithURLs:(NSArray *)urls eventHandler:(void (^)(CSKDirectoryObserver *, NSArray *, BOOL))handler
{
    if ((self = [super init])) {
        _urls = [urls copy];
        _handler = [handler copy];
        _eventInterval = 1;
        _eventQueue = dispatch_get_main_queue();
        _sources = [NSMutableArray array];
        _pending = [NSMutableSet set];
    }
    return self;
}

- (void)dealloc { [self stop]; }
- (NSArray *)URLs { return _urls; }

- (void)watch:(NSURL *)dir
{
    int fd = open(dir.fileSystemRepresentation, O_EVTONLY);
    if (fd < 0)
        return;
    dispatch_source_t s = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, (uintptr_t)fd,
                                                 DISPATCH_VNODE_WRITE | DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME | DISPATCH_VNODE_EXTEND,
                                                 _eventQueue);
    __weak CSKDirectoryObserver *weakSelf = self;
    dispatch_source_set_event_handler(s, ^{ [weakSelf changed:dir]; });
    dispatch_source_set_cancel_handler(s, ^{ close(fd); });
    dispatch_resume(s);
    [_sources addObject:s];
}

- (void)start
{
    [self stop];
    for (NSURL *u in _urls) {
        [self watch:u];
        if (_recursive) {
            NSDirectoryEnumerator *e = [[NSFileManager defaultManager] enumeratorAtURL:u includingPropertiesForKeys:@[ NSURLIsDirectoryKey ]
                                                                               options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
            for (NSURL *sub in e) {
                NSNumber *dir = nil;
                [sub getResourceValue:&dir forKey:NSURLIsDirectoryKey error:NULL];
                if (dir.boolValue)
                    [self watch:sub];
            }
        }
    }
}

- (void)stop
{
    for (dispatch_source_t s in _sources)
        dispatch_source_cancel(s);
    [_sources removeAllObjects];
}

- (void)changed:(NSURL *)dir
{
    [_pending addObject:dir];
    if (_scheduled)
        return;
    _scheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_eventInterval * NSEC_PER_SEC)), _eventQueue, ^{
        self->_scheduled = NO;
        NSArray *urls = self->_pending.allObjects;
        [self->_pending removeAllObjects];
        if (self->_handler && urls.count)
            self->_handler(self, urls, self->_recursive);
    });
}

@end

@implementation CSKFileObserver
@end

/* A file tail: reads what's appended to a file as it grows (from its end when started),
   and starts over when the file is replaced or shrinks. */
@implementation CSKFileTailObserver {
    NSURL *_url;
    BOOL (^_dataHandler)(BOOL, NSData *);
    void (^_handler)(id);
    dispatch_source_t _source;
    int _fd;
    off_t _offset;
}

- (instancetype)initWithURL:(NSURL *)url eventDataHandler:(BOOL (^)(BOOL, NSData *))handler
{
    if ((self = [super init])) {
        _url = url;
        _dataHandler = [handler copy];
        _eventDataQueue = dispatch_get_main_queue();
        _fd = -1;
        [self start];
    }
    return self;
}

- (instancetype)initWithURL:(NSURL *)url eventHandler:(void (^)(id))handler
{
    if ((self = [self initWithURL:url eventDataHandler:nil]))
        _handler = [handler copy];
    return self;
}

- (void)setEventDataHandler:(BOOL (^)(BOOL, NSData *))h { _dataHandler = [h copy]; }
- (void)dealloc { [self stop]; }

- (void)start
{
    _fd = open(_url.fileSystemRepresentation, O_RDONLY | O_EVTONLY);
    if (_fd < 0)
        return;
    _offset = 0;
    _source = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, (uintptr_t)_fd,
                                     DISPATCH_VNODE_WRITE | DISPATCH_VNODE_EXTEND | DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME,
                                     dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    __weak CSKFileTailObserver *weakSelf = self;
    int fd = _fd;
    dispatch_source_set_event_handler(_source, ^{ [weakSelf readMore]; });
    dispatch_source_set_cancel_handler(_source, ^{ close(fd); });
    dispatch_resume(_source);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [weakSelf readMore]; });
}

- (void)readMore
{
    struct stat st;
    if (fstat(_fd, &st) != 0)
        return;
    BOOL reset = NO;
    if (st.st_size < _offset) {
        _offset = 0;
        reset = YES;
    }
    if (st.st_size == _offset)
        return;
    NSMutableData *d = [NSMutableData dataWithLength:(NSUInteger)(st.st_size - _offset)];
    ssize_t n = pread(_fd, d.mutableBytes, d.length, _offset);
    if (n <= 0)
        return;
    d.length = (NSUInteger)n;
    _offset += n;
    BOOL (^h)(BOOL, NSData *) = _dataHandler;
    void (^plain)(id) = _handler;
    dispatch_async(_eventDataQueue ?: dispatch_get_main_queue(), ^{
        if (h)
            h(reset, d);
        if (plain)
            plain(self);
    });
}

- (void)stop
{
    if (_source) {
        dispatch_source_cancel(_source);
        _source = nil;
    }
}

@end
