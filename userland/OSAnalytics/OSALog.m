/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * OSAnalytics (private), Finch's own: OSALog, a diagnostic report (.ips). A report's
 * first line is its metadata, a JSON object (app name, bug type, OS version, time...);
 * the rest is the body. That's what Console reads; Finch writes no reports of its own yet.
 */
#import <Foundation/Foundation.h>

#define OSA_EXPORT __attribute__((visibility("default")))

OSA_EXPORT NSString *const kOSALogMetadataAppName = @"name";
OSA_EXPORT NSString *const kOSALogMetadataBugType = @"bug_type";
OSA_EXPORT NSString *const kOSALogMetadataIncidentID = @"incident_id";
OSA_EXPORT NSString *const kOSALogMetadataTimestamp = @"timestamp";
OSA_EXPORT NSString *const kOSALogMetadataOsVersion = @"os_version";
OSA_EXPORT NSString *const kOSALogMetadataAppVersion = @"app_version";
OSA_EXPORT NSString *const kOSALogMetadataBuildVersion = @"build_version";

OSA_EXPORT
@interface OSALog : NSObject
- (instancetype)initWithPath:(NSString *)path forRouting:(NSString *)routing options:(NSDictionary *)options;
@property (readonly) NSDictionary *metaData;
@property (readonly) NSString *filepath;
@property (readonly) NSString *bugType;
@end

@implementation OSALog {
    NSString *_path;
    NSDictionary *_meta;
}

- (instancetype)initWithPath:(NSString *)path forRouting:(NSString *)routing options:(NSDictionary *)options
{
    NSFileHandle *h = path ? [NSFileHandle fileHandleForReadingAtPath:path] : nil;
    NSData *head = [h readDataOfLength:64 * 1024];
    [h closeFile];
    if (!head.length)
        return nil;
    if ((self = [super init])) {
        _path = [path copy];
        NSUInteger end = [head rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0 range:NSMakeRange(0, head.length)].location;
        NSData *line = [head subdataWithRange:NSMakeRange(0, end == NSNotFound ? head.length : end)];
        id meta = [NSJSONSerialization JSONObjectWithData:line options:0 error:NULL];
        _meta = [meta isKindOfClass:[NSDictionary class]] ? meta : @{};
    }
    return self;
}

- (NSDictionary *)metaData { return _meta; }
- (NSString *)filepath { return _path; }
- (NSString *)bugType { return [_meta[@"bug_type"] description]; }
- (NSString *)description { return [NSString stringWithFormat:@"<%@: %p> %@ %@", self.class, self, _path, _meta[@"name"]]; }

@end
