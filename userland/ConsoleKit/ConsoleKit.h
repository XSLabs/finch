/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * ConsoleKit, Finch's own: the classes Console.app uses, with Apple's names, selectors and
 * value meanings (Apple's framework is private and closed; these are written from how
 * Console calls it).
 */
#import <AppKit/AppKit.h>

enum {
    CSKMessageTypeDefault = 1,
    CSKMessageTypeInfo = 2,
    CSKMessageTypeDebug = 3,
    CSKMessageTypeError = 4,
    CSKMessageTypeFault = 5,
};

enum {
    CSKFilterTypeProcess = 0,
    CSKFilterTypePID = 1,
    CSKFilterTypeLibrary = 2,
    CSKFilterTypeAny = 3,
    CSKFilterTypeThreadID = 4,
    CSKFilterTypeMessage = 5,
    CSKFilterTypeMessageType = 6,
    CSKFilterTypeMessageType2 = 7,
    CSKFilterTypeMessageID = 8,
    CSKFilterTypeSubsystem = 9,
    CSKFilterTypeCategory = 10,
    CSKFilterTypeActivityName = 11,
    CSKFilterTypeActivityID = 12,
    CSKFilterTypeParentActivityID = 13,
    CSKFilterTypeProcessPath = 14,
    CSKFilterTypeLibraryPath = 15,
    CSKFilterTypeDateTime = 16,
};

enum {
    CSKFilterComparisonContains = 0,
    CSKFilterComparisonDoesNotContain = 1,
    CSKFilterComparisonEquals = 2,
    CSKFilterComparisonDoesNotEqual = 3,
};

#define CSKColumnType @"type"
#define CSKColumnTime @"time"
#define CSKColumnProcess @"process"
#define CSKColumnPID @"pid"
#define CSKColumnThread @"thread"
#define CSKColumnSubsystem @"subsystem"
#define CSKColumnCategory @"category"
#define CSKColumnLibrary @"library"
#define CSKColumnMessage @"message"

@interface CSKHelpers : NSObject
+ (NSString *)formattedNumberFromUnsignedInteger:(NSUInteger)n;
@end

@interface CSKEntity : NSObject {
@public
    NSNumber *_identifierNumber;
    NSString *_processImagePathString, *_libraryImagePathString;
}
@property (copy, nonatomic) NSString *formattedTime;
@property (copy, nonatomic) NSString *formattedDateTime;
@property (copy, nonatomic) NSDate *timestamp;
@property (nonatomic) BOOL isVolatile;
@property (copy, nonatomic) NSTimeZone *timeZone;
@property (readonly, copy, nonatomic) NSNumber *identifier;
@property (readonly, copy, nonatomic) NSString *processImagePath;
@property (readonly, copy, nonatomic) NSString *libraryImagePath;
@property (copy, nonatomic) NSString *threadIdentifier;
@property (copy, nonatomic) NSString *processName;
@property (copy, nonatomic) NSString *libraryName;
@property (copy, nonatomic) NSString *libraryImageUUID;
@property (copy, nonatomic) NSNumber *processIdentifier;
@end

@interface CSKMessage : CSKEntity {
@public
    NSString *_messageText;
}
+ (NSString *)localizedMessageTypeNameForType:(NSInteger)type;
@property (nonatomic) NSInteger type;
@property (readonly, copy, nonatomic) NSString *message;
@property (copy, nonatomic) NSString *subsystem;
@property (copy, nonatomic) NSString *category;
@property (copy, nonatomic) NSNumber *activityIdentifier;
@property (copy, nonatomic) NSString *payload;
@end

@interface CSKFilter : NSObject <NSSecureCoding, NSCopying>
+ (NSString *)localizedFilterTypeNameForType:(NSInteger)type;
+ (NSString *)localizedFilterComparisonTypeNameForComparisonType:(NSInteger)type;
- (instancetype)initWithType:(NSInteger)type value:(NSString *)value;
@property (nonatomic) NSInteger type;
@property (strong, nonatomic) NSString *value;
@property (strong, nonatomic) NSNumber *number;
@property (nonatomic) NSInteger comparisonType;
- (BOOL)matchesMessage:(CSKMessage *)m;
@end

@interface CSKLoadRange : NSObject
- (instancetype)initWithIdentifier:(NSUInteger)identifier interval:(NSDateInterval *)interval;
@property (nonatomic) NSUInteger identifier;
@property (strong, nonatomic) NSDateInterval *interval;
@property (readonly) NSString *localizedDescription;
@end

@interface CSKMenuItemRepresentation : NSObject
- (instancetype)initWithProperty:(NSString *)property;
@property (readonly, nonatomic) NSString *property;
@property (weak, nonatomic) NSMenuItem *parentMenuItem;
@property (strong, nonatomic) NSString *groupIdentifier;
@property (strong, nonatomic) id value;
@end

@interface CSKStreamArchiveStatisticsEntry : NSObject
@property (strong, nonatomic) NSString *path;
@property (strong, nonatomic) NSNumber *entityCount;
@property (strong, nonatomic) NSNumber *entityPercentage;
@end

@interface CSKTableColumnLayout : NSObject <NSSecureCoding>
+ (NSArray *)updatedTableColumnIdentifiersFromLayout:(CSKTableColumnLayout *)layout tableColumnIdentifier:(NSString *)identifier;
+ (NSArray *)defaultColumnIdentifiers;
+ (NSArray *)allColumnIdentifiers;
+ (NSString *)titleForColumnIdentifier:(NSString *)identifier;
- (void)fillTableColumnsMenu:(NSMenu *)menu usingBlock:(void (^)(NSMenuItem *))block;
@property (strong, nonatomic) NSArray *layoutColumnIdentifiers;
@property (nonatomic) BOOL layoutColumnsCanBeReordered;
@property (strong, nonatomic) NSDictionary *layoutColumnInitialWidths;
@property (strong, nonatomic) NSSortDescriptor *layoutDefaultSortDescriptor;
@end
@interface CSKMessagesTableColumnLayout : CSKTableColumnLayout
@end
@interface CSKActivitiesTableColumnLayout : CSKTableColumnLayout
@end
@interface CSKArchiveMessagesTableColumnLayout : CSKMessagesTableColumnLayout
@end
@interface CSKArchiveActivitiesTableColumnLayout : CSKActivitiesTableColumnLayout
@end
@interface CSKASLTableColumnLayout : CSKTableColumnLayout
@end

@interface CSKDevice : NSObject {
@public
    NSString *_name, *_UDID, *_modelID;
    BOOL _isHostDevice;
}
+ (CSKDevice *)hostDevice;
@property (readonly, nonatomic) NSString *UDID;
@property (readonly, nonatomic) NSString *name;
@property (readonly, nonatomic) NSString *modelID;
@property (strong, nonatomic) NSString *build;
@property (strong, nonatomic) NSString *version;
@property (nonatomic) NSInteger state;
@property (nonatomic) NSUInteger type;
@property (nonatomic) BOOL supportsLogsPersistenceReading;
@property (strong, nonatomic) NSImage *icon;
- (BOOL)isEqualToDevice:(CSKDevice *)d;
- (BOOL)establishTrustWithFailingHandler:(void (^)(NSInteger))handler;
@end

@interface CSKDeviceManager : NSObject
+ (CSKDeviceManager *)sharedManager;
@property (readonly) NSArray *allDevices;
@property (weak, nonatomic) id delegate;
@end

@interface CSKFileNode : NSObject
@property (strong, nonatomic) NSMutableArray *mutableChildren;
@property (readonly) NSArray *children;
@property (nonatomic) BOOL isDirectory;
@property (strong, nonatomic) NSString *name;
@property (strong, nonatomic) NSURL *url;
@end

@interface CSKFileSystem : NSObject
+ (CSKFileSystem *)sharedInstance;
@property (readonly, nonatomic) dispatch_queue_t systemSerialQueue;
@property (copy, nonatomic) id handler;
@end

@interface CSKDirectoryObserver : NSObject
- (instancetype)initWithURL:(NSURL *)url eventHandler:(void (^)(CSKDirectoryObserver *, NSArray *, BOOL))handler;
- (instancetype)initWithURLs:(NSArray *)urls eventHandler:(void (^)(CSKDirectoryObserver *, NSArray *, BOOL))handler;
- (void)start;
- (void)stop;
@property (readonly) NSArray *URLs;
@property (strong, nonatomic) dispatch_queue_t eventQueue;
@property (nonatomic) BOOL recursive;
@property (nonatomic) BOOL ignoreFiles;
@property (nonatomic) double eventInterval;
@property (strong, nonatomic) id representedObject;
@end

@interface CSKFileObserver : NSObject
@end

@interface CSKFileTailObserver : CSKFileObserver
@property (strong, nonatomic) dispatch_queue_t eventDataQueue;
- (void)stop;
@end

/* ---- streams ---- */

@class CSKStreamSource;

/* What a source tells the stream view controller. */
@protocol CSKFinchStreamSourceClient
- (void)streamSource:(CSKStreamSource *)source didStreamForwardEntities:(NSArray *)entities;
- (void)streamSourceDidFinish:(CSKStreamSource *)source total:(NSUInteger)total failures:(NSUInteger)failures;
- (void)streamSourceDidFail:(CSKStreamSource *)source;
@end

@interface CSKStreamSource : NSObject
@property (weak, nonatomic) id<CSKFinchStreamSourceClient> client;
@property (nonatomic) BOOL ignoresStatistics;
@property (strong, nonatomic) NSProgress *loadingProgress;
@property (readonly) BOOL isStreaming;
@property (readonly) BOOL isLive; /* goes on until stopped */
- (void)resume;
- (void)stop;
- (void)finish;
- (NSArray *)processStatistics;
- (NSArray *)availableLoadRanges;
@property (strong, nonatomic) CSKLoadRange *currentLoadRange;
/* subclasses */
- (void)deliver:(NSArray *)entities;
- (void)finished:(NSUInteger)total;
@end

@interface CSKStreamDeviceSource : CSKStreamSource
- (instancetype)initWithDevice:(CSKDevice *)device PID:(NSInteger)pid;
@property (readonly) CSKDevice *device;
@property (nonatomic) BOOL includesInfoEntities;
@property (nonatomic) BOOL includesDebugEntities;
@end

@interface CSKStreamSQLSource : CSKStreamSource
@end

@interface CSKStreamArchiveSource : CSKStreamSource
- (instancetype)initWithArchiveURL:(NSURL *)url error:(NSError **)error;
@property (readonly) BOOL isArchiveCorrupted;
@end

@interface CSKStreamASLSource : CSKStreamSource
+ (instancetype)diagnosticAndUsageDataASLSource;
- (instancetype)initWithFileURL:(NSURL *)url;
@end

/* Messages from Finch's log store (finch-logd's records). */
NSArray *CSKReadLogStore(NSString *path, off_t *offset, BOOL includeInfo, BOOL includeDebug, NSInteger pid, NSTimeInterval since);

@interface NSColor (ConsoleKit)
+ (NSColor *)csk_debugMessageTypeColor;
+ (NSColor *)csk_infoMessageTypeColor;
+ (NSColor *)csk_errorMessageTypeColor;
+ (NSColor *)csk_faultMessageTypeColor;
@end

@interface NSImage (ConsoleKit)
- (NSImage *)csk_imageTintedWithColor:(NSColor *)color;
+ (NSImage *)csk_findIconWithColor:(NSColor *)color;
@end
