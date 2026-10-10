/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CNContactStore: the user's contacts, in Finch's own store, a keyed archive at
 * ~/Library/Application Support/AddressBook/Finch Contacts.archive holding the one local
 * container ("On My Mac"), its contacts and groups, group membership, the Me card, and
 * a history of changes (CNChangeHistoryFetchRequest reads it). Each read and save takes
 * the file's lock, so processes share the store; a save posts
 * CNContactStoreDidChangeNotification here and, through the distributed notification
 * center, in the other processes using it. Finch has no privacy prompt yet, so access
 * is granted, as when the user allows it.
 */
#import "Contacts_Finch.h"
#import <ImageIO/ImageIO.h>
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>

static NSString *const kChangedDistributed = @"org.finch.contacts.changed";
static NSString *const kOriginationExternally = @"CNNotificationOriginationExternally";

/* --- predicates --- */

@implementation FinchCNPredicate

- (BOOL)evaluateWithObject:(id)object
{
    return [self evaluateWithObject:object substitutionVariables:nil];
}

- (BOOL)evaluateWithObject:(id)object substitutionVariables:(NSDictionary *)bindings
{
    /* (group and container predicates need the store: it answers those itself) */
    if (![object isKindOfClass:[CNContact class]])
        return NO;
    CNContact *c = object;
    if ([_kind isEqualToString:@"name"]) {
        NSStringCompareOptions o = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch | NSAnchoredSearch;
        NSMutableArray *words = [NSMutableArray array];
        for (NSString *k in @[ CNContactGivenNameKey, CNContactMiddleNameKey, CNContactFamilyNameKey, CNContactNicknameKey,
                               CNContactOrganizationNameKey, CNContactPhoneticGivenNameKey, CNContactPhoneticFamilyNameKey,
                               CNContactNamePrefixKey, CNContactNameSuffixKey ])
            if ([c isKeyAvailable:k])
                [words addObjectsFromArray:[[c valueForKey:k] componentsSeparatedByCharactersInSet:
                                                                  [NSCharacterSet whitespaceAndNewlineCharacterSet]]];
        NSArray *query = [_argument componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        BOOL any = NO;
        for (NSString *q in query) {
            if (!q.length)
                continue;
            any = YES;
            BOOL found = NO;
            for (NSString *w in words)
                if (w.length && [w rangeOfString:q options:o].location != NSNotFound)
                    found = YES;
            if (!found)
                return NO;
        }
        return any;
    }
    if ([_kind isEqualToString:@"email"]) {
        for (CNLabeledValue *l in c.emailAddresses)
            for (NSString *e in _argument)
                if ([l.value caseInsensitiveCompare:e] == NSOrderedSame)
                    return YES;
        return NO;
    }
    if ([_kind isEqualToString:@"phone"]) {
        NSString *want = [_argument valueForKey:@"digits"];
        if (want.length < 3)
            return NO;
        for (CNLabeledValue *l in c.phoneNumbers) {
            NSString *have = [l.value valueForKey:@"digits"];
            if ([have isEqualToString:want])
                return YES;
            NSString *shorter = have.length < want.length ? have : want, *longer = have.length < want.length ? want : have;
            if (shorter.length >= 7 && [longer hasSuffix:[shorter stringByReplacingOccurrencesOfString:@"+" withString:@""]])
                return YES;
        }
        return NO;
    }
    return NO;
}

- (NSString *)predicateFormat { return _finchDescription ?: @""; }

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p: kind=%@>", [self class], self, _finchDescription];
}

- (id)copyWithZone:(NSZone *)zone
{
    FinchCNPredicate *p = [[FinchCNPredicate alloc] init];
    p.kind = _kind;
    p.argument = _argument;
    p.finchDescription = _finchDescription;
    return p;
}

@end

static NSPredicate *
store_predicate(NSString *kind, id argument, NSString *description)
{
    FinchCNPredicate *p = [[FinchCNPredicate alloc] init];
    p.kind = kind;
    p.argument = argument;
    p.finchDescription = description;
    return p;
}

@implementation CNContact (Predicates)
+ (NSPredicate *)predicateForContactsMatchingName:(NSString *)name
{
    return store_predicate(@"name", name, @"-[CNContact predicateForContactsMatchingName:]");
}
+ (NSPredicate *)predicateForContactsMatchingEmailAddress:(NSString *)emailAddress
{
    return store_predicate(@"email", @[ emailAddress ?: @"" ], @"-[CNContact predicateForContactsMatchingEmailAddresses:]");
}
+ (NSPredicate *)predicateForContactsMatchingPhoneNumber:(CNPhoneNumber *)phoneNumber
{
    return store_predicate(@"phone", phoneNumber, @"-[CNContact predicateForContactsMatchingPhoneNumber:]");
}
+ (NSPredicate *)predicateForContactsWithIdentifiers:(NSArray<NSString *> *)identifiers
{
    return [NSPredicate predicateWithFormat:@"identifier IN %@", identifiers ?: @[]];
}
+ (NSPredicate *)predicateForContactsInGroupWithIdentifier:(NSString *)groupIdentifier
{
    return store_predicate(@"group", groupIdentifier, @"-[CNContact predicateForContactsInGroupWithIdentifier:]");
}
+ (NSPredicate *)predicateForContactsInContainerWithIdentifier:(NSString *)containerIdentifier
{
    return store_predicate(@"container", containerIdentifier, @"-[CNContact predicateForContactsInContainerWithIdentifier:]");
}
@end

@implementation CNGroup (Predicates)
+ (NSPredicate *)predicateForGroupsWithIdentifiers:(NSArray<NSString *> *)identifiers
{
    return store_predicate(@"groups", identifiers, @"-[CNContact predicateForGroupsWithIdentifiers:]");
}
+ (NSPredicate *)predicateForSubgroupsInGroupWithIdentifier:(NSString *)parentGroupIdentifier
{
    return store_predicate(@"subgroups", parentGroupIdentifier, @"-[CNContact predicateForSubgroupsInGroupWithIdentifier:]");
}
+ (NSPredicate *)predicateForGroupsInContainerWithIdentifier:(NSString *)containerIdentifier
{
    return store_predicate(@"container", containerIdentifier, @"-[CNContact predicateForGroupsInContainerWithIdentifier:]");
}
@end

@implementation CNContainer (Predicates)
+ (NSPredicate *)predicateForContainersWithIdentifiers:(NSArray<NSString *> *)identifiers
{
    return store_predicate(@"containers", identifiers, @"-[CNContainer predicateForContainersWithIdentifiers:]");
}
+ (NSPredicate *)predicateForContainerOfContactWithIdentifier:(NSString *)contactIdentifier
{
    return store_predicate(@"containerOfContact", contactIdentifier, @"-[CNContainer predicateForContainerOfContactWithIdentifier:]");
}
+ (NSPredicate *)predicateForContainerOfGroupWithIdentifier:(NSString *)groupIdentifier
{
    return store_predicate(@"containerOfGroup", groupIdentifier, @"-[CNContainer predicateForContainerOfGroupWithIdentifier:]");
}
@end

/* --- requests and results --- */

@implementation CNFetchRequest
@end

@implementation CNContactFetchRequest {
    NSPredicate *_predicate;
    NSArray *_keysToFetch;
    BOOL _mutableObjects, _unifyResults;
    CNContactSortOrder _sortOrder;
}
+ (BOOL)supportsSecureCoding { return YES; }
- (instancetype)initWithKeysToFetch:(NSArray *)keysToFetch
{
    if ((self = [super init])) {
        _keysToFetch = [keysToFetch copy] ?: @[];
        _unifyResults = YES;
    }
    return self;
}
- (NSPredicate *)predicate { return _predicate; }
- (void)setPredicate:(NSPredicate *)p { _predicate = [p copy]; }
- (NSArray *)keysToFetch { return _keysToFetch; }
- (void)setKeysToFetch:(NSArray *)k { _keysToFetch = [k copy]; }
- (BOOL)mutableObjects { return _mutableObjects; }
- (void)setMutableObjects:(BOOL)m { _mutableObjects = m; }
- (BOOL)unifyResults { return _unifyResults; }
- (void)setUnifyResults:(BOOL)u { _unifyResults = u; }
- (CNContactSortOrder)sortOrder { return _sortOrder; }
- (void)setSortOrder:(CNContactSortOrder)s { _sortOrder = s; }
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_keysToFetch forKey:@"keysToFetch"];
    [coder encodeObject:_predicate forKey:@"predicate"];
    [coder encodeBool:_mutableObjects forKey:@"mutableObjects"];
    [coder encodeBool:_unifyResults forKey:@"unifyResults"];
    [coder encodeInteger:_sortOrder forKey:@"sortOrder"];
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSSet *keys = [NSSet setWithObjects:[NSArray class], [NSString class], [CNAggregateKeyDescriptor class], nil];
    if ((self = [self initWithKeysToFetch:[coder decodeObjectOfClasses:keys forKey:@"keysToFetch"]])) {
        _predicate = [coder decodeObjectOfClass:[NSPredicate class] forKey:@"predicate"];
        _mutableObjects = [coder decodeBoolForKey:@"mutableObjects"];
        _unifyResults = [coder decodeBoolForKey:@"unifyResults"];
        _sortOrder = [coder decodeIntegerForKey:@"sortOrder"];
    }
    return self;
}
@end

@implementation CNChangeHistoryFetchRequest
+ (BOOL)supportsSecureCoding { return YES; }
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:self.startingToken forKey:@"startingToken"];
    [coder encodeObject:self.additionalContactKeyDescriptors forKey:@"additionalContactKeyDescriptors"];
    [coder encodeBool:self.shouldUnifyResults forKey:@"shouldUnifyResults"];
    [coder encodeBool:self.mutableObjects forKey:@"mutableObjects"];
    [coder encodeBool:self.includeGroupChanges forKey:@"includeGroupChanges"];
    [coder encodeObject:self.excludedTransactionAuthors forKey:@"excludedTransactionAuthors"];
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super init])) {
        NSSet *keys = [NSSet setWithObjects:[NSArray class], [NSString class], [CNAggregateKeyDescriptor class], nil];
        self.startingToken = [coder decodeObjectOfClass:[NSData class] forKey:@"startingToken"];
        self.additionalContactKeyDescriptors = [coder decodeObjectOfClasses:keys forKey:@"additionalContactKeyDescriptors"];
        self.shouldUnifyResults = [coder decodeBoolForKey:@"shouldUnifyResults"];
        self.mutableObjects = [coder decodeBoolForKey:@"mutableObjects"];
        self.includeGroupChanges = [coder decodeBoolForKey:@"includeGroupChanges"];
        self.excludedTransactionAuthors = [coder decodeObjectOfClasses:[NSSet setWithObjects:[NSArray class], [NSString class], nil]
                                                                forKey:@"excludedTransactionAuthors"];
    }
    return self;
}
@end

@interface CNFetchResult () {
    id _value;
    NSData *_currentHistoryToken;
}
- (instancetype)_finchInitWithValue:(id)value token:(NSData *)token FINCH_INIT;
@end

@implementation CNFetchResult
- (instancetype)_finchInitWithValue:(id)value token:(NSData *)token
{
    if ((self = [super init])) {
        _value = value;
        _currentHistoryToken = [token copy];
    }
    return self;
}
- (id)value { return _value; }
- (NSData *)currentHistoryToken { return _currentHistoryToken; }
@end

/* The save request: its changes, in order. */
@interface CNSaveRequest () {
  @public
    NSMutableArray<NSArray *> *_changes; /* (operation, object, argument) */
}
@end

@implementation CNSaveRequest
- (instancetype)init
{
    if ((self = [super init]))
        _changes = [NSMutableArray array];
    return self;
}
- (void)_finchAdd:(NSString *)op object:(id)o argument:(id)a
{
    [_changes addObject:@[ op, o ?: [NSNull null], a ?: [NSNull null] ]];
}
- (void)addContact:(CNMutableContact *)contact toContainerWithIdentifier:(NSString *)identifier
{
    [self _finchAdd:@"addContact" object:contact argument:identifier];
}
- (void)updateContact:(CNMutableContact *)contact { [self _finchAdd:@"updateContact" object:contact argument:nil]; }
- (void)deleteContact:(CNMutableContact *)contact { [self _finchAdd:@"deleteContact" object:contact argument:nil]; }
- (void)addGroup:(CNMutableGroup *)group toContainerWithIdentifier:(NSString *)identifier
{
    [self _finchAdd:@"addGroup" object:group argument:identifier];
}
- (void)updateGroup:(CNMutableGroup *)group { [self _finchAdd:@"updateGroup" object:group argument:nil]; }
- (void)deleteGroup:(CNMutableGroup *)group { [self _finchAdd:@"deleteGroup" object:group argument:nil]; }
- (void)addSubgroup:(CNGroup *)subgroup toGroup:(CNGroup *)group { [self _finchAdd:@"addSubgroup" object:subgroup argument:group]; }
- (void)removeSubgroup:(CNGroup *)subgroup fromGroup:(CNGroup *)group
{
    [self _finchAdd:@"removeSubgroup" object:subgroup argument:group];
}
- (void)addMember:(CNContact *)contact toGroup:(CNGroup *)group { [self _finchAdd:@"addMember" object:contact argument:group]; }
- (void)removeMember:(CNContact *)contact fromGroup:(CNGroup *)group { [self _finchAdd:@"removeMember" object:contact argument:group]; }
@end

/* --- change history events --- */

@interface CNChangeHistoryEvent ()
- (instancetype)_finchInit FINCH_INIT;
@end

@implementation CNChangeHistoryEvent
+ (BOOL)supportsSecureCoding { return YES; }
- (instancetype)_finchInit { return [super init]; }
- (void)acceptEventVisitor:(id<CNChangeHistoryEventVisitor>)visitor {}
- (id)copyWithZone:(NSZone *)zone { return self; }
- (void)encodeWithCoder:(NSCoder *)coder {}
- (instancetype)initWithCoder:(NSCoder *)coder { return [super init]; }
@end

@implementation CNChangeHistoryDropEverythingEvent
- (void)acceptEventVisitor:(id<CNChangeHistoryEventVisitor>)visitor { [visitor visitDropEverythingEvent:self]; }
@end

#define EVENT_CLASS(Name, visit, required, ...)                                       \
    @interface Name ()                                                                \
    - (instancetype)_finchInitWith:(id)a with:(id)b FINCH_INIT;                      \
    @end                                                                              \
    @implementation Name {                                                            \
        id _a, _b;                                                                    \
    }                                                                                 \
    - (instancetype)_finchInitWith:(id)a with:(id)b                                  \
    {                                                                                 \
        if ((self = [super _finchInit])) {                                            \
            _a = a;                                                                   \
            _b = b;                                                                   \
        }                                                                             \
        return self;                                                                  \
    }                                                                                 \
    - (void)acceptEventVisitor:(id<CNChangeHistoryEventVisitor>)visitor               \
    {                                                                                 \
        if (required || [visitor respondsToSelector:@selector(visit:)])               \
            [visitor visit:self];                                                     \
    }                                                                                 \
    __VA_ARGS__                                                                       \
    @end

EVENT_CLASS(CNChangeHistoryAddContactEvent, visitAddContactEvent, YES,
            -(CNContact *)contact { return _a; } - (NSString *)containerIdentifier { return _b; })
EVENT_CLASS(CNChangeHistoryUpdateContactEvent, visitUpdateContactEvent, YES, -(CNContact *)contact { return _a; })
EVENT_CLASS(CNChangeHistoryDeleteContactEvent, visitDeleteContactEvent, YES, -(NSString *)contactIdentifier { return _a; })
EVENT_CLASS(CNChangeHistoryAddGroupEvent, visitAddGroupEvent, NO,
            -(CNGroup *)group { return _a; } - (NSString *)containerIdentifier { return _b; })
EVENT_CLASS(CNChangeHistoryUpdateGroupEvent, visitUpdateGroupEvent, NO, -(CNGroup *)group { return _a; })
EVENT_CLASS(CNChangeHistoryDeleteGroupEvent, visitDeleteGroupEvent, NO, -(NSString *)groupIdentifier { return _a; })
EVENT_CLASS(CNChangeHistoryAddMemberToGroupEvent, visitAddMemberToGroupEvent, NO,
            -(CNContact *)member { return _a; } - (CNGroup *)group { return _b; })
EVENT_CLASS(CNChangeHistoryRemoveMemberFromGroupEvent, visitRemoveMemberFromGroupEvent, NO,
            -(CNContact *)member { return _a; } - (CNGroup *)group { return _b; })
EVENT_CLASS(CNChangeHistoryAddSubgroupToGroupEvent, visitAddSubgroupToGroupEvent, NO,
            -(CNGroup *)subgroup { return _a; } - (CNGroup *)group { return _b; })
EVENT_CLASS(CNChangeHistoryRemoveSubgroupFromGroupEvent, visitRemoveSubgroupFromGroupEvent, NO,
            -(CNGroup *)subgroup { return _a; } - (CNGroup *)group { return _b; })

/* --- the store's file --- */

/* The store's contents: one container's contacts and groups, and the history. */
@interface FinchContactsDB : NSObject
@property (strong) NSString *containerIdentifier;
@property (strong) NSMutableArray<CNContact *> *contacts;
@property (strong) NSMutableArray<CNGroup *> *groups;
@property (strong) NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *members;   /* group -> contacts */
@property (strong) NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *subgroups; /* group -> groups */
@property (strong) NSString *meIdentifier;
@property uint64_t token;
@property uint64_t historyStart; /* the oldest token the history goes back to */
@property (strong) NSMutableArray<NSDictionary *> *history; /* {token, kind, id, extra} */
@end

@implementation FinchContactsDB
@end

static NSString *
store_path(void)
{
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/AddressBook/Finch Contacts.archive"];
}

static const NSUInteger kHistoryLimit = 2000;

static FinchContactsDB *
load_db(void)
{
    FinchContactsDB *db = [[FinchContactsDB alloc] init];
    NSData *data = [NSData dataWithContentsOfFile:store_path()];
    NSDictionary *root = nil;
    if (data) {
        NSKeyedUnarchiver *u = [[NSKeyedUnarchiver alloc] initForReadingFromData:data error:NULL];
        u.requiresSecureCoding = NO;
        root = [u decodeObjectForKey:NSKeyedArchiveRootObjectKey];
    }
    db.containerIdentifier = root[@"container"] ?: [NSUUID UUID].UUIDString;
    db.contacts = [NSMutableArray arrayWithArray:root[@"contacts"] ?: @[]];
    db.groups = [NSMutableArray arrayWithArray:root[@"groups"] ?: @[]];
    db.members = [NSMutableDictionary dictionary];
    for (NSString *g in root[@"members"])
        db.members[g] = [root[@"members"][g] mutableCopy];
    db.subgroups = [NSMutableDictionary dictionary];
    for (NSString *g in root[@"subgroups"])
        db.subgroups[g] = [root[@"subgroups"][g] mutableCopy];
    db.meIdentifier = root[@"me"];
    db.token = [root[@"token"] unsignedLongLongValue];
    db.historyStart = [root[@"historyStart"] unsignedLongLongValue];
    db.history = [NSMutableArray arrayWithArray:root[@"history"] ?: @[]];
    return db;
}

static BOOL
save_db(FinchContactsDB *db, NSError **error)
{
    while (db.history.count > kHistoryLimit) {
        db.historyStart = [db.history[0][@"token"] unsignedLongLongValue];
        [db.history removeObjectAtIndex:0];
    }
    NSMutableDictionary *root = [NSMutableDictionary dictionary];
    root[@"container"] = db.containerIdentifier;
    root[@"contacts"] = db.contacts;
    root[@"groups"] = db.groups;
    root[@"members"] = db.members;
    root[@"subgroups"] = db.subgroups;
    if (db.meIdentifier)
        root[@"me"] = db.meIdentifier;
    root[@"token"] = @(db.token);
    root[@"historyStart"] = @(db.historyStart);
    root[@"history"] = db.history;
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:root requiringSecureCoding:NO error:error];
    if (!data)
        return NO;
    [[NSFileManager defaultManager] createDirectoryAtPath:[store_path() stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES attributes:nil error:NULL];
    if (![data writeToFile:store_path() options:NSDataWritingAtomic error:NULL]) {
        if (error)
            *error = FinchCNError(CNErrorCodeDataAccessError, @"The contacts store couldn't be saved.");
        return NO;
    }
    return YES;
}

/* Runs a block with the store's lock (shared for reading, exclusive for saving). */
static void
with_lock(BOOL exclusive, void (^block)(void))
{
    NSString *dir = [store_path() stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    int fd = open([dir stringByAppendingPathComponent:@".Finch Contacts.lock"].fileSystemRepresentation, O_RDWR | O_CREAT, 0600);
    if (fd >= 0)
        flock(fd, exclusive ? LOCK_EX : LOCK_SH);
    block();
    if (fd >= 0) {
        flock(fd, LOCK_UN);
        close(fd);
    }
}

static NSData *
token_data(uint64_t token)
{
    uint64_t le = NSSwapHostLongLongToLittle(token);
    return [NSData dataWithBytes:&le length:sizeof le];
}

static BOOL
token_value(NSData *d, uint64_t *out)
{
    if (d.length != sizeof(uint64_t))
        return NO;
    uint64_t le;
    memcpy(&le, d.bytes, sizeof le);
    *out = NSSwapLittleLongLongToHost(le);
    return YES;
}

NSData *
FinchCNThumbnail(NSData *imageData)
{
    if (!imageData.length)
        return nil;
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)imageData, NULL);
    if (!src)
        return nil;
    NSDictionary *opts = @{
        (__bridge id)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
        (__bridge id)kCGImageSourceThumbnailMaxPixelSize : @320,
        (__bridge id)kCGImageSourceCreateThumbnailWithTransform : @YES,
    };
    CGImageRef thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
    CFRelease(src);
    if (!thumb)
        return nil;
    NSMutableData *out = [NSMutableData data];
    CGImageDestinationRef dst = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)out, CFSTR("public.jpeg"), 1, NULL);
    BOOL ok = NO;
    if (dst) {
        CGImageDestinationAddImage(dst, thumb, (__bridge CFDictionaryRef) @{(__bridge id)kCGImageDestinationLossyCompressionQuality : @0.8});
        ok = CGImageDestinationFinalize(dst);
        CFRelease(dst);
    }
    CGImageRelease(thumb);
    return ok ? out : nil;
}

/* --- the store --- */

@implementation CNContactStore

+ (CNAuthorizationStatus)authorizationStatusForEntityType:(CNEntityType)entityType
{
    return CNAuthorizationStatusAuthorized;
}

+ (void)_finchForwardChanges
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      Class dnc = NSClassFromString(@"NSDistributedNotificationCenter");
      [[dnc defaultCenter] addObserverForName:kChangedDistributed object:nil queue:[NSOperationQueue mainQueue]
                                   usingBlock:^(NSNotification *n) {
                                     if ([n.object isEqual:[NSString stringWithFormat:@"%d", getpid()]])
                                         return;
                                     [[NSNotificationCenter defaultCenter] postNotificationName:CNContactStoreDidChangeNotification
                                                                                         object:nil
                                                                                       userInfo:@{kOriginationExternally : @YES}];
                                   }];
    });
}

- (instancetype)init
{
    if ((self = [super init]))
        [CNContactStore _finchForwardChanges];
    return self;
}

- (instancetype)initWithConfiguration:(id)configuration { return [self init]; }

- (void)requestAccessForEntityType:(CNEntityType)entityType completionHandler:(void (^)(BOOL, NSError *))completionHandler
{
    if (!completionHandler)
        return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
      completionHandler(YES, nil);
    });
}

- (FinchContactsDB *)_finchRead
{
    /* (the first look makes the store, so its container's identifier stays) */
    if (![[NSFileManager defaultManager] fileExistsAtPath:store_path()])
        with_lock(YES, ^{
          if (![[NSFileManager defaultManager] fileExistsAtPath:store_path()])
              save_db(load_db(), NULL);
        });
    __block FinchContactsDB *db;
    with_lock(NO, ^{
      db = load_db();
    });
    return db;
}

/* A stored contact as fetched with these keys. */
static CNContact *
fetched(CNContact *stored, NSSet *keys, BOOL mutableObject)
{
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    for (NSString *k in keys)
        if (stored->_values[k])
            values[k] = stored->_values[k];
    Class cls = mutableObject ? [CNMutableContact class] : [CNContact class];
    CNContact *c = [[cls alloc] _finchInitWithIdentifier:stored->_identifier values:values available:keys];
    c->_persisted = YES;
    return c;
}

static NSSet *
group_members(FinchContactsDB *db, NSString *group)
{
    /* a group's members, its subgroups' too */
    NSMutableSet *ids = [NSMutableSet set];
    NSMutableArray *todo = [NSMutableArray arrayWithObject:group ?: @""];
    NSMutableSet *seen = [NSMutableSet set];
    while (todo.count) {
        NSString *g = todo.lastObject;
        [todo removeLastObject];
        if ([seen containsObject:g])
            continue;
        [seen addObject:g];
        [ids addObjectsFromArray:db.members[g] ?: @[]];
        [todo addObjectsFromArray:db.subgroups[g] ?: @[]];
    }
    return ids;
}

- (NSArray<CNContact *> *)_finchContactsIn:(FinchContactsDB *)db predicate:(NSPredicate *)predicate keys:(NSArray *)keyDescriptors
                                   mutable:(BOOL)mutableObjects
                                 sortOrder:(CNContactSortOrder)order
                                     error:(NSError **)error
{
    NSSet *keys;
    @try {
        keys = FinchCNKeysOfDescriptors(keyDescriptors ?: @[]);
    } @catch (NSException *e) {
        if (error)
            *error = FinchCNError(CNErrorCodePredicateInvalid, e.reason);
        return nil;
    }
    NSArray *candidates = db.contacts;
    if ([predicate isKindOfClass:[FinchCNPredicate class]]) {
        FinchCNPredicate *p = (FinchCNPredicate *)predicate;
        if ([p.kind isEqualToString:@"group"]) {
            NSSet *ids = group_members(db, p.argument);
            candidates = [db.contacts filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(CNContact *c, id b) {
                                        return [ids containsObject:c->_identifier];
                                      }]];
        } else if ([p.kind isEqualToString:@"container"]) {
            if (![p.argument isEqual:db.containerIdentifier])
                candidates = @[];
        } else {
            candidates = [db.contacts filteredArrayUsingPredicate:p];
        }
    } else if (predicate) {
        candidates = [db.contacts filteredArrayUsingPredicate:predicate];
    }
    if (order != CNContactSortOrderNone)
        candidates = [candidates sortedArrayUsingComparator:[CNContact comparatorForNameSortOrder:order]];
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:candidates.count];
    for (CNContact *c in candidates)
        [out addObject:fetched(c, keys, mutableObjects)];
    return out;
}

- (NSArray<CNContact *> *)unifiedContactsMatchingPredicate:(NSPredicate *)predicate keysToFetch:(NSArray *)keys error:(NSError **)error
{
    if (!predicate) {
        if (error)
            *error = FinchCNError(CNErrorCodePredicateInvalid, @"A predicate is required.");
        return nil;
    }
    return [self _finchContactsIn:[self _finchRead] predicate:predicate keys:keys mutable:NO sortOrder:CNContactSortOrderNone
                            error:error];
}

- (CNContact *)unifiedContactWithIdentifier:(NSString *)identifier keysToFetch:(NSArray *)keys error:(NSError **)error
{
    NSArray *found = [self unifiedContactsMatchingPredicate:[CNContact predicateForContactsWithIdentifiers:@[ identifier ?: @"" ]]
                                                keysToFetch:keys error:error];
    if (!found.count) {
        if (found && error)
            *error = [NSError errorWithDomain:CNErrorDomain code:CNErrorCodeRecordDoesNotExist
                                     userInfo:@{CNErrorUserInfoAffectedRecordIdentifiersKey : @[ identifier ?: @"" ]}];
        return nil;
    }
    return found[0];
}

- (CNContact *)unifiedMeContactWithKeysToFetch:(NSArray *)keys error:(NSError **)error
{
    FinchContactsDB *db = [self _finchRead];
    if (db.meIdentifier)
        for (CNContact *c in db.contacts)
            if ([c->_identifier isEqualToString:db.meIdentifier])
                return fetched(c, FinchCNKeysOfDescriptors(keys ?: @[]), NO);
    if (error)
        *error = FinchCNError(CNErrorCodeRecordDoesNotExist, nil);
    return nil;
}

/* (private, as Apple's) makes a contact the Me card */
- (BOOL)setMeContact:(CNContact *)contact error:(NSError **)error
{
    __block BOOL ok = YES;
    __block NSError *failure = nil;
    with_lock(YES, ^{
      FinchContactsDB *db = load_db();
      db.meIdentifier = contact.identifier;
      NSError *e = nil;
      ok = save_db(db, &e);
      failure = e;
    });
    if (!ok && error)
        *error = failure;
    if (ok)
        [self _finchPostChange];
    return ok;
}

- (BOOL)enumerateContactsWithFetchRequest:(CNContactFetchRequest *)fetchRequest error:(NSError **)error
                               usingBlock:(void (NS_NOESCAPE ^)(CNContact *, BOOL *))block
{
    NSArray *contacts = [self _finchContactsIn:[self _finchRead] predicate:fetchRequest.predicate keys:fetchRequest.keysToFetch
                                       mutable:fetchRequest.mutableObjects
                                     sortOrder:fetchRequest.sortOrder
                                         error:error];
    if (!contacts)
        return NO;
    BOOL stop = NO;
    for (CNContact *c in contacts) {
        block(c, &stop);
        if (stop)
            break;
    }
    return YES;
}

- (CNFetchResult *)enumeratorForContactFetchRequest:(CNContactFetchRequest *)request error:(NSError **)error
{
    FinchContactsDB *db = [self _finchRead];
    NSArray *contacts = [self _finchContactsIn:db predicate:request.predicate keys:request.keysToFetch mutable:request.mutableObjects
                                     sortOrder:request.sortOrder
                                         error:error];
    if (!contacts)
        return nil;
    return [[CNFetchResult alloc] _finchInitWithValue:contacts.objectEnumerator token:token_data(db.token)];
}

- (NSArray<CNGroup *> *)groupsMatchingPredicate:(NSPredicate *)predicate error:(NSError **)error
{
    FinchContactsDB *db = [self _finchRead];
    if (!predicate)
        return [db.groups copy];
    if ([predicate isKindOfClass:[FinchCNPredicate class]]) {
        FinchCNPredicate *p = (FinchCNPredicate *)predicate;
        NSArray *ids = nil;
        if ([p.kind isEqualToString:@"groups"])
            ids = p.argument;
        else if ([p.kind isEqualToString:@"subgroups"])
            ids = db.subgroups[p.argument] ?: @[];
        else if ([p.kind isEqualToString:@"container"])
            return [p.argument isEqual:db.containerIdentifier] ? [db.groups copy] : @[];
        if (ids)
            return [db.groups filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"identifier IN %@", ids]];
    }
    return [db.groups filteredArrayUsingPredicate:predicate];
}

- (CNContainer *)_finchContainer:(FinchContactsDB *)db
{
    return [[CNContainer alloc] _finchInitWithIdentifier:db.containerIdentifier name:@"On My Mac" type:CNContainerTypeLocal];
}

- (NSArray<CNContainer *> *)containersMatchingPredicate:(NSPredicate *)predicate error:(NSError **)error
{
    FinchContactsDB *db = [self _finchRead];
    CNContainer *only = [self _finchContainer:db];
    if (!predicate)
        return @[ only ];
    if ([predicate isKindOfClass:[FinchCNPredicate class]]) {
        FinchCNPredicate *p = (FinchCNPredicate *)predicate;
        BOOL match = NO;
        if ([p.kind isEqualToString:@"containers"])
            match = [p.argument containsObject:db.containerIdentifier];
        else if ([p.kind isEqualToString:@"containerOfContact"])
            match = [[db.contacts valueForKey:@"identifier"] containsObject:p.argument];
        else if ([p.kind isEqualToString:@"containerOfGroup"])
            match = [[db.groups valueForKey:@"identifier"] containsObject:p.argument];
        return match ? @[ only ] : @[];
    }
    return [@[ only ] filteredArrayUsingPredicate:predicate];
}

- (NSString *)defaultContainerIdentifier
{
    return [self _finchRead].containerIdentifier;
}

- (NSData *)currentHistoryToken { return token_data([self _finchRead].token); }

- (void)_finchPostChange
{
    [[NSNotificationCenter defaultCenter] postNotificationName:CNContactStoreDidChangeNotification object:nil
                                                      userInfo:@{kOriginationExternally : @NO}];
    Class dnc = NSClassFromString(@"NSDistributedNotificationCenter");
    [[dnc defaultCenter] postNotificationName:kChangedDistributed object:[NSString stringWithFormat:@"%d", getpid()]];
}

/* Whether a group is the other or among its subgroups (adding it would make a cycle). */
static BOOL
subgroup_reaches(FinchContactsDB *db, NSString *from, NSString *to)
{
    NSMutableArray *todo = [NSMutableArray arrayWithObject:from];
    NSMutableSet *seen = [NSMutableSet set];
    while (todo.count) {
        NSString *g = todo.lastObject;
        [todo removeLastObject];
        if ([g isEqualToString:to])
            return YES;
        if ([seen containsObject:g])
            continue;
        [seen addObject:g];
        [todo addObjectsFromArray:db.subgroups[g] ?: @[]];
    }
    return NO;
}

static NSInteger
index_of_contact(FinchContactsDB *db, NSString *identifier)
{
    for (NSUInteger i = 0; i < db.contacts.count; i++)
        if ([db.contacts[i]->_identifier isEqualToString:identifier])
            return (NSInteger)i;
    return -1;
}

static NSInteger
index_of_group(FinchContactsDB *db, NSString *identifier)
{
    for (NSUInteger i = 0; i < db.groups.count; i++)
        if ([db.groups[i]->_identifier isEqualToString:identifier])
            return (NSInteger)i;
    return -1;
}

/* The contact as the store keeps it: every key, the thumbnail made from the picture. */
static CNContact *
stored_form(CNContact *c, CNContact *previous)
{
    NSMutableDictionary *values = previous ? [previous->_values mutableCopy] : [NSMutableDictionary dictionary];
    for (NSString *k in FinchCNAllKeys()) {
        if (![c isKeyAvailable:k] || [k isEqualToString:CNContactIdentifierKey] || [k isEqualToString:CNContactImageDataAvailableKey] ||
            [k isEqualToString:CNContactThumbnailImageDataKey])
            continue;
        if (c->_values[k])
            values[k] = c->_values[k];
        else
            [values removeObjectForKey:k];
    }
    if ([c isKeyAvailable:CNContactImageDataKey]) {
        NSData *thumb = FinchCNThumbnail(values[CNContactImageDataKey]);
        if (thumb)
            values[CNContactThumbnailImageDataKey] = thumb;
        else if (values[CNContactImageDataKey])
            values[CNContactThumbnailImageDataKey] = values[CNContactImageDataKey];
        else
            [values removeObjectForKey:CNContactThumbnailImageDataKey];
    }
    CNContact *s = [[CNContact alloc] _finchInitWithIdentifier:c->_identifier values:values available:nil];
    s->_persisted = YES;
    return s;
}

static NSError *
record_error(CNErrorCode code, id record, NSString *identifier)
{
    return [NSError errorWithDomain:CNErrorDomain code:code
                           userInfo:@{
                               CNErrorUserInfoAffectedRecordsKey : @[ record ],
                               CNErrorUserInfoAffectedRecordIdentifiersKey : @[ identifier ?: @"" ],
                           }];
}

- (BOOL)executeSaveRequest:(CNSaveRequest *)saveRequest error:(NSError **)error
{
    __block NSError *failure = nil;
    __block BOOL changed = NO;
    NSMutableArray *saved = [NSMutableArray array];
    with_lock(YES, ^{
      FinchContactsDB *db = load_db();
      void (^log)(NSString *, NSString *, id) = ^(NSString *kind, NSString *identifier, id extra) {
        db.token++;
        [db.history addObject:@{@"token" : @(db.token), @"kind" : kind, @"id" : identifier ?: @"", @"extra" : extra ?: @""}];
      };
      for (NSArray *change in saveRequest->_changes) {
          NSString *op = change[0];
          id object = change[1], argument = change[2] == [NSNull null] ? nil : change[2];
          if ([op isEqualToString:@"addContact"]) {
              CNContact *c = object;
              if (argument && ![argument isEqual:db.containerIdentifier]) {
                  failure = record_error(CNErrorCodeParentRecordDoesNotExist, c, argument);
                  break;
              }
              if (index_of_contact(db, c->_identifier) >= 0) {
                  failure = record_error(CNErrorCodeInsertedRecordAlreadyExists, c, c->_identifier);
                  break;
              }
              [db.contacts addObject:stored_form(c, nil)];
              [saved addObject:c];
              log(@"addContact", c->_identifier, nil);
          } else if ([op isEqualToString:@"updateContact"]) {
              CNContact *c = object;
              NSInteger i = index_of_contact(db, c->_identifier);
              if (i < 0) {
                  failure = record_error(CNErrorCodeRecordDoesNotExist, c, c->_identifier);
                  break;
              }
              db.contacts[(NSUInteger)i] = stored_form(c, db.contacts[(NSUInteger)i]);
              [saved addObject:c];
              log(@"updateContact", c->_identifier, nil);
          } else if ([op isEqualToString:@"deleteContact"]) {
              CNContact *c = object;
              NSInteger i = index_of_contact(db, c->_identifier);
              if (i < 0) {
                  failure = record_error(CNErrorCodeRecordDoesNotExist, c, c->_identifier);
                  break;
              }
              [db.contacts removeObjectAtIndex:(NSUInteger)i];
              for (NSString *g in db.members)
                  [db.members[g] removeObject:c->_identifier];
              if ([db.meIdentifier isEqualToString:c->_identifier])
                  db.meIdentifier = nil;
              log(@"deleteContact", c->_identifier, nil);
          } else if ([op isEqualToString:@"addGroup"]) {
              CNGroup *g = object;
              if (index_of_group(db, g->_identifier) >= 0) {
                  failure = record_error(CNErrorCodeInsertedRecordAlreadyExists, g, g->_identifier);
                  break;
              }
              [db.groups addObject:[g copy]];
              log(@"addGroup", g->_identifier, nil);
          } else if ([op isEqualToString:@"updateGroup"]) {
              CNGroup *g = object;
              NSInteger i = index_of_group(db, g->_identifier);
              if (i < 0) {
                  failure = record_error(CNErrorCodeRecordDoesNotExist, g, g->_identifier);
                  break;
              }
              db.groups[(NSUInteger)i] = [g copy];
              log(@"updateGroup", g->_identifier, nil);
          } else if ([op isEqualToString:@"deleteGroup"]) {
              CNGroup *g = object;
              NSInteger i = index_of_group(db, g->_identifier);
              if (i < 0) {
                  failure = record_error(CNErrorCodeRecordDoesNotExist, g, g->_identifier);
                  break;
              }
              [db.groups removeObjectAtIndex:(NSUInteger)i];
              [db.members removeObjectForKey:g->_identifier];
              [db.subgroups removeObjectForKey:g->_identifier];
              for (NSString *p in db.subgroups)
                  [db.subgroups[p] removeObject:g->_identifier];
              log(@"deleteGroup", g->_identifier, nil);
          } else {
              /* membership: the group must exist, and the member */
              CNGroup *group = argument;
              BOOL contact = [op hasSuffix:@"Member"];
              NSString *memberID = contact ? ((CNContact *)object)->_identifier : ((CNGroup *)object)->_identifier;
              if (index_of_group(db, group->_identifier) < 0) {
                  failure = record_error(CNErrorCodeRecordDoesNotExist, group, group->_identifier);
                  break;
              }
              if ((contact ? index_of_contact(db, memberID) : index_of_group(db, memberID)) < 0) {
                  failure = record_error(CNErrorCodeRecordDoesNotExist, object, memberID);
                  break;
              }
              NSMutableDictionary *table = contact ? db.members : db.subgroups;
              NSMutableArray *list = table[group->_identifier] ?: (table[group->_identifier] = [NSMutableArray array]);
              if ([op hasPrefix:@"add"]) {
                  if (!contact && subgroup_reaches(db, memberID, group->_identifier)) {
                      failure = record_error(CNErrorCodeContainmentCycle, object, memberID);
                      break;
                  }
                  if (![list containsObject:memberID])
                      [list addObject:memberID];
              } else {
                  [list removeObject:memberID];
              }
              log(op, memberID, group->_identifier);
          }
          changed = YES;
      }
      NSError *e = nil;
      if (!failure && changed && !save_db(db, &e))
          failure = e ?: FinchCNError(CNErrorCodeDataAccessError, nil);
    });
    if (failure) {
        if (error)
            *error = failure;
        return NO;
    }
    for (CNContact *c in saved)
        c->_persisted = YES;
    if (changed)
        [self _finchPostChange];
    return YES;
}

- (CNFetchResult *)enumeratorForChangeHistoryFetchRequest:(CNChangeHistoryFetchRequest *)request error:(NSError **)error
{
    FinchContactsDB *db = [self _finchRead];
    NSMutableSet *keys = [NSMutableSet setWithArray:FinchCNAllKeys()];
    if (request.additionalContactKeyDescriptors)
        [keys unionSet:FinchCNKeysOfDescriptors(request.additionalContactKeyDescriptors)];
    NSMutableArray *events = [NSMutableArray array];
    uint64_t start = 0;
    BOOL everything = !request.startingToken || !token_value(request.startingToken, &start) || start < db.historyStart ||
                      start > db.token;
    CNContact * (^contact)(NSString *) = ^CNContact *(NSString *identifier) {
      NSInteger i = index_of_contact(db, identifier);
      return i < 0 ? nil : fetched(db.contacts[(NSUInteger)i], keys, request.mutableObjects);
    };
    CNGroup * (^group)(NSString *) = ^CNGroup *(NSString *identifier) {
      NSInteger i = index_of_group(db, identifier);
      return i < 0 ? [[CNGroup alloc] _finchInitWithIdentifier:identifier name:@""] : db.groups[(NSUInteger)i];
    };
    if (everything) {
        [events addObject:[[CNChangeHistoryDropEverythingEvent alloc] _finchInit]];
        for (CNContact *c in db.contacts)
            [events addObject:[[CNChangeHistoryAddContactEvent alloc] _finchInitWith:fetched(c, keys, request.mutableObjects)
                                                                                 with:db.containerIdentifier]];
        if (request.includeGroupChanges) {
            for (CNGroup *g in db.groups)
                [events addObject:[[CNChangeHistoryAddGroupEvent alloc] _finchInitWith:g with:db.containerIdentifier]];
            for (NSString *g in db.members)
                for (NSString *m in db.members[g])
                    [events addObject:[[CNChangeHistoryAddMemberToGroupEvent alloc] _finchInitWith:contact(m) with:group(g)]];
            for (NSString *g in db.subgroups)
                for (NSString *s in db.subgroups[g])
                    [events addObject:[[CNChangeHistoryAddSubgroupToGroupEvent alloc] _finchInitWith:group(s) with:group(g)]];
        }
    } else {
        for (NSDictionary *h in db.history) {
            if ([h[@"token"] unsignedLongLongValue] <= start)
                continue;
            NSString *kind = h[@"kind"], *identifier = h[@"id"], *extra = h[@"extra"];
            CNChangeHistoryEvent *e = nil;
            if ([kind isEqualToString:@"addContact"] && contact(identifier))
                e = [[CNChangeHistoryAddContactEvent alloc] _finchInitWith:contact(identifier) with:db.containerIdentifier];
            else if ([kind isEqualToString:@"updateContact"] && contact(identifier))
                e = [[CNChangeHistoryUpdateContactEvent alloc] _finchInitWith:contact(identifier) with:nil];
            else if ([kind isEqualToString:@"deleteContact"])
                e = [[CNChangeHistoryDeleteContactEvent alloc] _finchInitWith:identifier with:nil];
            else if (!request.includeGroupChanges)
                continue;
            else if ([kind isEqualToString:@"addGroup"])
                e = [[CNChangeHistoryAddGroupEvent alloc] _finchInitWith:group(identifier) with:db.containerIdentifier];
            else if ([kind isEqualToString:@"updateGroup"])
                e = [[CNChangeHistoryUpdateGroupEvent alloc] _finchInitWith:group(identifier) with:nil];
            else if ([kind isEqualToString:@"deleteGroup"])
                e = [[CNChangeHistoryDeleteGroupEvent alloc] _finchInitWith:identifier with:nil];
            else if ([kind isEqualToString:@"addMember"] && contact(identifier))
                e = [[CNChangeHistoryAddMemberToGroupEvent alloc] _finchInitWith:contact(identifier) with:group(extra)];
            else if ([kind isEqualToString:@"removeMember"])
                e = [[CNChangeHistoryRemoveMemberFromGroupEvent alloc]
                    _finchInitWith:contact(identifier) ?: [[CNContact alloc] _finchInitWithIdentifier:identifier values:@{} available:nil]
                              with:group(extra)];
            else if ([kind isEqualToString:@"addSubgroup"])
                e = [[CNChangeHistoryAddSubgroupToGroupEvent alloc] _finchInitWith:group(identifier) with:group(extra)];
            else if ([kind isEqualToString:@"removeSubgroup"])
                e = [[CNChangeHistoryRemoveSubgroupFromGroupEvent alloc] _finchInitWith:group(identifier) with:group(extra)];
            if (e)
                [events addObject:e];
        }
    }
    return [[CNFetchResult alloc] _finchInitWithValue:events.objectEnumerator token:token_data(db.token)];
}

@end

/* --- user defaults --- */

@implementation CNContactsUserDefaults
+ (instancetype)sharedDefaults
{
    static CNContactsUserDefaults *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      shared = [[CNContactsUserDefaults alloc] init];
    });
    return shared;
}
/* (Contacts' own setting, "Sort By", in the AddressBook domain: last name unless set) */
- (CNContactSortOrder)sortOrder
{
    NSString *format = (__bridge_transfer NSString *)CFPreferencesCopyAppValue(CFSTR("ABNameSortingFormat"), CFSTR("com.apple.AddressBook"));
    if ([format hasPrefix:@"sortingFirstName"])
        return CNContactSortOrderGivenName;
    return CNContactSortOrderFamilyName;
}
- (NSString *)countryCode
{
    return [[[NSLocale currentLocale] objectForKey:NSLocaleCountryCode] lowercaseString] ?: @"us";
}
@end

/* --- classes apps name, kept for them --- */

@interface CNContactStoreConfiguration : NSObject <NSCopying>
@end
@implementation CNContactStoreConfiguration
- (id)copyWithZone:(NSZone *)zone { return self; }
@end

/* Recents (people recently messaged): Finch keeps none, so nothing changes. */
@interface CNCoreRecentsChangeNotifier : NSObject
@end
@implementation CNCoreRecentsChangeNotifier
@end

@interface CNUserSetupPictureData : NSObject
@end
@implementation CNUserSetupPictureData
@end
