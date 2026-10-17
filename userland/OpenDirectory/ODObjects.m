/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Objective-C OpenDirectory objects backed by Finch's local account database. */
#import <OpenDirectory/OpenDirectory.h>
#import <CFOpenDirectory/CFOpenDirectory.h>
#import <objc/runtime.h>
#import <account_tools.h>
#import <pwd.h>
#include <stdio.h>

@interface ODNode (FinchLocal)
@end

@interface ODRecord (FinchLocal)
- (instancetype)_finchInitWithRecord:(NSDictionary *)record;
@end

static char recordStateKey;
static NSDictionary *record_state(ODRecord *record)
{
    return objc_getAssociatedObject(record, &recordStateKey);
}

static NSArray *string_array(id value)
{
    if ([value isKindOfClass:[NSArray class]])
        return value;
    return value ? [NSArray arrayWithObject:value] : [NSArray array];
}

@implementation ODSession

+ (ODSession *)defaultSession
{
    static ODSession *session;
    @synchronized(self) {
        if (!session) {
            session = [[ODSession alloc] initWithOptions:nil error:NULL];
        }
    }
    return session;
}

+ (instancetype)sessionWithOptions:(NSDictionary *)options error:(NSError **)outError
{
    return [[[self alloc] initWithOptions:options error:outError] autorelease];
}

- (instancetype)initWithOptions:(NSDictionary *)options error:(NSError **)outError
{
    (void)options;
    self = [super init];
    if (self)
        _internal = NULL;
    return self;
}

- (NSArray *)nodeNamesAndReturnError:(NSError **)outError
{
    (void)outError;
    return [NSArray arrayWithObjects:@"/Local/Default", @"/Search", nil];
}

- (NSArray *)configurationTemplateNames { return [NSArray array]; }
- (NSArray *)mappingTemplateNames { return [NSArray array]; }

- (void)dealloc
{
    if (_internal)
        CFRelease(_internal);
    [super dealloc];
}

@end

@implementation ODNode

+ (instancetype)nodeWithSession:(ODSession *)session type:(ODNodeType)type error:(NSError **)outError
{
    return [[[self alloc] initWithSession:session type:type error:outError] autorelease];
}

+ (instancetype)nodeWithSession:(ODSession *)session name:(NSString *)name error:(NSError **)outError
{
    return [[[self alloc] initWithSession:session name:name error:outError] autorelease];
}

- (instancetype)initWithSession:(ODSession *)session type:(ODNodeType)type error:(NSError **)outError
{
    (void)session;
    (void)outError;
    self = [super init];
    if (self) {
        if (type != kODNodeTypeAuthentication && type != kODNodeTypeLocalNodes &&
            type != kODNodeTypeNetwork && type != kODNodeTypeContacts) {
            [self release];
            return nil;
        }
        _internal = [@"/Local/Default" copy];
    }
    return self;
}

- (instancetype)initWithSession:(ODSession *)session name:(NSString *)name error:(NSError **)outError
{
    (void)session;
    (void)outError;
    self = [super init];
    if (self) {
        if (![name isEqualToString:@"/Local/Default"] && ![name isEqualToString:@"/Search"] &&
            ![name isEqualToString:@"/Local"]) {
            [self release];
            return nil;
        }
        _internal = [name copy];
    }
    return self;
}

- (NSString *)nodeName { return _internal; }
- (NSArray *)subnodeNamesAndReturnError:(NSError **)error { (void)error; return [NSArray array]; }
- (NSArray *)unreachableSubnodeNamesAndReturnError:(NSError **)error { (void)error; return [NSArray array]; }
- (NSArray *)supportedRecordTypesAndReturnError:(NSError **)error
{
    (void)error;
    return [NSArray arrayWithObject:(NSString *)kODRecordTypeUsers];
}
- (NSArray *)supportedAttributesForRecordType:(ODRecordType)type error:(NSError **)error
{
    (void)error;
    if (![type isEqual:(NSString *)kODRecordTypeUsers])
        return [NSArray array];
    return [NSArray arrayWithObjects:(NSString *)kODAttributeTypeRecordName,
        (NSString *)kODAttributeTypeUniqueID, (NSString *)kODAttributeTypePrimaryGroupID,
        (NSString *)kODAttributeTypeFullName, (NSString *)kODAttributeTypeNFSHomeDirectory,
        (NSString *)kODAttributeTypeUserShell, (NSString *)kODAttributeTypeMetaNodeLocation,
        (NSString *)kODAttributeTypeAuthenticationAuthority, nil];
}
- (NSDictionary *)nodeDetailsForKeys:(NSArray *)keys error:(NSError **)error
{
    (void)error;
    NSDictionary *details = [NSDictionary dictionaryWithObject:self.nodeName forKey:@"NodeName"];
    if (!keys)
        return details;
    NSMutableDictionary *filtered = [NSMutableDictionary dictionary];
    for (id key in keys) {
        id value = [details objectForKey:key];
        if (value)
            [filtered setObject:value forKey:key];
    }
    return filtered;
}
- (ODRecord *)recordWithRecordType:(ODRecordType)type name:(NSString *)name attributes:(id)attributes error:(NSError **)outError
{
    (void)attributes;
    (void)outError;
    if (![type isEqual:(NSString *)kODRecordTypeUsers] ||
        !name.UTF8String || getpwnam(name.UTF8String) == NULL)
        return nil;
    NSDictionary *state = [NSDictionary dictionaryWithObjectsAndKeys:
        type, @"type", name, @"name", self.nodeName, @"node", nil];
    return [[ODRecord alloc] _finchInitWithRecord:state];
}
- (BOOL)setCredentialsWithRecordType:(ODRecordType)type recordName:(NSString *)name password:(NSString *)password error:(NSError **)outError
{
    ODRecord *record = [self recordWithRecordType:type name:name attributes:nil error:outError];
    if (!record)
        return NO;
    return [record verifyPassword:password error:outError];
}
- (void)dealloc
{
    if (_internal)
        [(id)_internal release];
    [super dealloc];
}

@end

@implementation ODRecord

- (instancetype)_finchInitWithRecord:(NSDictionary *)record
{
    self = [super init];
    if (self)
        objc_setAssociatedObject(self, &recordStateKey, record, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return self;
}
- (NSString *)recordName { return [record_state(self) objectForKey:@"name"]; }
- (NSString *)recordType { return [record_state(self) objectForKey:@"type"]; }
- (NSArray *)valuesForAttribute:(ODAttributeType)attribute error:(NSError **)outError
{
    (void)outError;
    struct passwd *pw = self.recordName.UTF8String ? getpwnam(self.recordName.UTF8String) : NULL;
    if (!pw)
        return nil;
    NSString *value = nil;
    if ([attribute isEqual:(NSString *)kODAttributeTypeRecordName]) value = self.recordName;
    else if ([attribute isEqual:(NSString *)kODAttributeTypeUniqueID]) value = [NSString stringWithFormat:@"%u", pw->pw_uid];
    else if ([attribute isEqual:(NSString *)kODAttributeTypePrimaryGroupID]) value = [NSString stringWithFormat:@"%u", pw->pw_gid];
    else if ([attribute isEqual:(NSString *)kODAttributeTypeFullName]) value = [NSString stringWithUTF8String:pw->pw_gecos ?: ""];
    else if ([attribute isEqual:(NSString *)kODAttributeTypeNFSHomeDirectory]) value = [NSString stringWithUTF8String:pw->pw_dir ?: ""];
    else if ([attribute isEqual:(NSString *)kODAttributeTypeUserShell]) value = [NSString stringWithUTF8String:pw->pw_shell ?: ""];
    else if ([attribute isEqual:(NSString *)kODAttributeTypeMetaNodeLocation]) value = [record_state(self) objectForKey:@"node"];
    else if ([attribute isEqual:(NSString *)kODAttributeTypeAuthenticationAuthority]) value = @";ShadowHash;";
    return value ? [NSArray arrayWithObject:value] : [NSArray array];
}
- (NSDictionary *)recordDetailsForAttributes:(NSArray *)attributes error:(NSError **)outError
{
    NSArray *keys = attributes ?: [NSArray arrayWithObject:(NSString *)kODAttributeTypeRecordName];
    NSMutableDictionary *details = [NSMutableDictionary dictionary];
    for (id key in keys) {
        NSArray *values = [self valuesForAttribute:key error:outError];
        if (!values)
            return nil;
        [details setObject:values forKey:key];
    }
    return details;
}
- (BOOL)verifyPassword:(NSString *)password error:(NSError **)outError
{
    struct passwd *pw = self.recordName.UTF8String ? getpwnam(self.recordName.UTF8String) : NULL;
    if (!pw || !password.UTF8String || !pw->pw_passwd)
        return NO;
    return at_password_verify(password.UTF8String, pw->pw_passwd);
}
- (BOOL)synchronizeAndReturnError:(NSError **)outError
{
    (void)outError;
    return self.recordName.UTF8String && getpwnam(self.recordName.UTF8String) != NULL;
}
- (void)dealloc { [super dealloc]; }

@end

@implementation ODQuery {
    ODNode *_node;
    NSArray *_recordTypes;
    NSString *_attribute;
    ODMatchType _matchType;
    NSArray *_queryValues;
    NSArray *_returnAttributes;
    NSInteger _maximumResults;
    id<ODQueryDelegate> _delegate;
    NSOperationQueue *_operationQueue;
}

+ (ODQuery *)queryWithNode:(ODNode *)node forRecordTypes:(id)types attribute:(ODAttributeType)attribute
                 matchType:(ODMatchType)matchType queryValues:(id)values returnAttributes:(id)attributes
            maximumResults:(NSInteger)maximum error:(NSError **)error
{
    return [[[self alloc] initWithNode:node forRecordTypes:types attribute:attribute matchType:matchType
        queryValues:values returnAttributes:attributes maximumResults:maximum error:error] autorelease];
}

- (instancetype)initWithNode:(ODNode *)node forRecordTypes:(id)types attribute:(ODAttributeType)attribute
                    matchType:(ODMatchType)matchType queryValues:(id)values returnAttributes:(id)attributes
               maximumResults:(NSInteger)maximum error:(NSError **)error
{
    self = [super init];
    if (self) {
        _node = [node retain];
        _recordTypes = [string_array(types) copy];
        _attribute = [(NSString *)attribute copy];
        _matchType = matchType;
        _queryValues = [string_array(values) copy];
        _returnAttributes = attributes ? [string_array(attributes) copy] : nil;
        _maximumResults = maximum;
        if (!_node || ![_recordTypes containsObject:(NSString *)kODRecordTypeUsers] ||
            !_attribute || !_queryValues.count || (matchType < kODMatchEqualTo || matchType > kODMatchEndsWith)) {
            [self release];
            if (error)
                *error = [NSError errorWithDomain:(NSString *)ODFrameworkErrorDomain code:kODErrorQueryInvalidMatchType
                    userInfo:nil];
            return nil;
        }
    }
    return self;
}

- (NSArray *)resultsAllowingPartial:(BOOL)partial error:(NSError **)error
{
    (void)partial;
    NSMutableArray *results = [NSMutableArray array];
    NSMutableArray *names = [NSMutableArray array];
    @synchronized([ODQuery class]) {
        setpwent();
        struct passwd *pw;
        while ((pw = getpwent()) != NULL)
            [names addObject:[NSString stringWithUTF8String:pw->pw_name]];
        endpwent();
    }
    for (NSString *name in names) {
            ODRecord *record = [_node recordWithRecordType:(NSString *)kODRecordTypeUsers name:name attributes:nil error:nil];
            if (!record) continue;
            NSArray *values = [record valuesForAttribute:_attribute error:nil];
            BOOL matches = NO;
            for (id candidate in values) {
                for (NSString *query in _queryValues) {
                    NSRange range = [candidate rangeOfString:query options:NSCaseInsensitiveSearch];
                    switch (_matchType) {
                        case kODMatchEqualTo: matches |= [candidate caseInsensitiveCompare:query] == NSOrderedSame; break;
                        case kODMatchBeginsWith: matches |= range.location == 0; break;
                        case kODMatchContains: matches |= range.location != NSNotFound; break;
                        case kODMatchEndsWith: matches |= range.location != NSNotFound && NSMaxRange(range) == [candidate length]; break;
                        default: break;
                    }
                }
            }
            if (matches) {
                [results addObject:record];
                if (_maximumResults > 0 && (NSInteger)results.count >= _maximumResults)
                    break;
            }
    }
    (void)error;
    return results;
}

- (id<ODQueryDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<ODQueryDelegate>)delegate { _delegate = delegate; }
- (NSOperationQueue *)operationQueue { return _operationQueue; }
- (void)setOperationQueue:(NSOperationQueue *)queue
{
    if (queue != _operationQueue) {
        [_operationQueue release];
        _operationQueue = [queue retain];
    }
}
- (void)scheduleInRunLoop:(NSRunLoop *)runLoop forMode:(NSString *)mode
{
    (void)runLoop; (void)mode;
    if (!_delegate)
        return;
    NSArray *results = [self resultsAllowingPartial:NO error:NULL];
    [_delegate query:self foundResults:results error:nil];
    [_delegate query:self foundResults:nil error:nil];
}
- (void)removeFromRunLoop:(NSRunLoop *)runLoop forMode:(NSString *)mode { (void)runLoop; (void)mode; }
- (void)synchronize { }
- (id)copyWithZone:(NSZone *)zone
{
    return [[ODQuery allocWithZone:zone] initWithNode:_node forRecordTypes:_recordTypes attribute:_attribute
        matchType:_matchType queryValues:_queryValues returnAttributes:_returnAttributes maximumResults:_maximumResults error:NULL];
}
- (void)dealloc
{
    [_node release];
    [_recordTypes release];
    [_attribute release];
    [_queryValues release];
    [_returnAttributes release];
    [_operationQueue release];
    [super dealloc];
}

@end
