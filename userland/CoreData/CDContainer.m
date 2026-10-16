// SPDX-License-Identifier: MIT OR Apache-2.0
#import "CDInternal.h"

@implementation NSPersistentStoreDescription
+ (instancetype)persistentStoreDescriptionWithURL:(NSURL *)url {
    return [[[self alloc] initWithURL:url] autorelease];
}
- (instancetype)init { return [self initWithURL:[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"Finch.sqlite"]]]; }
- (instancetype)initWithURL:(NSURL *)url {
    self = [super init];
    if (self) {
        CDSet(self, @"URL", url);
        CDSet(self, @"type", NSSQLiteStoreType);
        CDSet(self, @"options", [NSMutableDictionary dictionary]);
        CDSet(self, @"sqlitePragmas", [NSMutableDictionary dictionary]);
        CDSet(self, @"timeout", [NSNumber numberWithDouble:5.0]);
        CDSet(self, @"shouldMigrateStoreAutomatically", [NSNumber numberWithBool:YES]);
        CDSet(self, @"shouldInferMappingModelAutomatically", [NSNumber numberWithBool:YES]);
    }
    return self;
}
- (NSString *)type { return CDGet(self, @"type"); }
- (void)setType:(NSString *)value { CDSet(self, @"type", [value copy]); }
- (NSString *)configuration { return CDGet(self, @"configuration"); }
- (void)setConfiguration:(NSString *)value { CDSet(self, @"configuration", [value copy]); }
- (NSURL *)URL { return CDGet(self, @"URL"); }
- (void)setURL:(NSURL *)value { CDSet(self, @"URL", value); }
- (NSDictionary *)options { return [[CDGet(self, @"options") copy] autorelease]; }
- (void)setOption:(NSObject *)option forKey:(NSString *)key {
    NSMutableDictionary *options = CDGet(self, @"options");
    if (option) [options setObject:option forKey:key]; else [options removeObjectForKey:key];
}
- (BOOL)isReadOnly { return [(NSNumber *)[self.options objectForKey:NSReadOnlyPersistentStoreOption] boolValue]; }
- (void)setReadOnly:(BOOL)value { [self setOption:[NSNumber numberWithBool:value] forKey:NSReadOnlyPersistentStoreOption]; }
- (NSTimeInterval)timeout { return [CDGet(self, @"timeout") doubleValue]; }
- (void)setTimeout:(NSTimeInterval)value { CDSet(self, @"timeout", [NSNumber numberWithDouble:value]); }
- (NSDictionary *)sqlitePragmas { return [[CDGet(self, @"sqlitePragmas") copy] autorelease]; }
- (void)setValue:(NSObject *)value forPragmaNamed:(NSString *)name {
    NSMutableDictionary *pragmas = CDGet(self, @"sqlitePragmas");
    if (value) [pragmas setObject:value forKey:name]; else [pragmas removeObjectForKey:name];
}
- (BOOL)shouldAddStoreAsynchronously { return [CDGet(self, @"shouldAddStoreAsynchronously") boolValue]; }
- (void)setShouldAddStoreAsynchronously:(BOOL)value { CDSet(self, @"shouldAddStoreAsynchronously", [NSNumber numberWithBool:value]); }
- (BOOL)shouldMigrateStoreAutomatically { return CDGet(self, @"shouldMigrateStoreAutomatically") ? [CDGet(self, @"shouldMigrateStoreAutomatically") boolValue] : YES; }
- (void)setShouldMigrateStoreAutomatically:(BOOL)value { CDSet(self, @"shouldMigrateStoreAutomatically", [NSNumber numberWithBool:value]); }
- (BOOL)shouldInferMappingModelAutomatically { return CDGet(self, @"shouldInferMappingModelAutomatically") ? [CDGet(self, @"shouldInferMappingModelAutomatically") boolValue] : YES; }
- (void)setShouldInferMappingModelAutomatically:(BOOL)value { CDSet(self, @"shouldInferMappingModelAutomatically", [NSNumber numberWithBool:value]); }
- (id)copyWithZone:(NSZone *)zone {
    NSPersistentStoreDescription *copy = [[[self class] allocWithZone:zone] initWithURL:self.URL];
    copy.type = self.type;
    copy.configuration = self.configuration;
    copy.timeout = self.timeout;
    copy.readOnly = self.isReadOnly;
    copy.shouldAddStoreAsynchronously = self.shouldAddStoreAsynchronously;
    copy.shouldMigrateStoreAutomatically = self.shouldMigrateStoreAutomatically;
    copy.shouldInferMappingModelAutomatically = self.shouldInferMappingModelAutomatically;
    for (NSString *key in self.options) [copy setOption:[self.options objectForKey:key] forKey:key];
    for (NSString *key in self.sqlitePragmas) [copy setValue:[self.sqlitePragmas objectForKey:key] forPragmaNamed:key];
    return copy;
}
@end

@implementation NSPersistentContainer
- (instancetype)init {
    NSManagedObjectModel *model = [[[NSManagedObjectModel alloc] init] autorelease];
    return [self initWithName:@"Finch" managedObjectModel:model];
}
+ (NSURL *)defaultDirectoryURL {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *path = [paths count] ? [paths objectAtIndex:0] : NSTemporaryDirectory();
    NSString *bundle = [[NSBundle mainBundle] bundleIdentifier] ?: @"Finch";
    NSURL *url = [NSURL fileURLWithPath:[path stringByAppendingPathComponent:bundle] isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:url withIntermediateDirectories:YES attributes:nil error:NULL];
    return url;
}
+ (instancetype)persistentContainerWithName:(NSString *)name {
    return [[[self alloc] initWithName:name] autorelease];
}
+ (instancetype)persistentContainerWithName:(NSString *)name managedObjectModel:(NSManagedObjectModel *)model {
    return [[[self alloc] initWithName:name managedObjectModel:model] autorelease];
}
- (instancetype)initWithName:(NSString *)name {
    NSManagedObjectModel *model = [NSManagedObjectModel mergedModelFromBundles:nil];
    if (!model) {
        NSURL *url = [[NSBundle mainBundle] URLForResource:name withExtension:@"momd"];
        if (!url) url = [[NSBundle mainBundle] URLForResource:name withExtension:@"mom"];
        if (url) model = [[[NSManagedObjectModel alloc] initWithContentsOfURL:url] autorelease];
    }
    if (!model) { [self release]; return nil; }
    return [self initWithName:name managedObjectModel:model];
}
- (instancetype)initWithName:(NSString *)name managedObjectModel:(NSManagedObjectModel *)model {
    self = [super init];
    if (self) {
        CDSet(self, @"name", [name copy]);
        CDSet(self, @"model", [model retain]);
        NSPersistentStoreCoordinator *coordinator = [[[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model] autorelease];
        CDSet(self, @"coordinator", coordinator);
        NSURL *url = [[self.class defaultDirectoryURL] URLByAppendingPathComponent:[name stringByAppendingPathExtension:@"sqlite"]];
        CDSet(self, @"descriptions", [NSArray arrayWithObject:[NSPersistentStoreDescription persistentStoreDescriptionWithURL:url]]);
    }
    return self;
}
- (NSString *)name { return CDGet(self, @"name"); }
- (NSManagedObjectModel *)managedObjectModel { return CDGet(self, @"model"); }
- (NSPersistentStoreCoordinator *)persistentStoreCoordinator { return CDGet(self, @"coordinator"); }
- (NSManagedObjectContext *)viewContext {
    NSManagedObjectContext *context = CDGet(self, @"viewContext");
    if (!context) {
        context = [[[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType] autorelease];
        context.persistentStoreCoordinator = self.persistentStoreCoordinator;
        CDSet(self, @"viewContext", context);
    }
    return context;
}
- (NSArray *)persistentStoreDescriptions { return CDGet(self, @"descriptions"); }
- (void)setPersistentStoreDescriptions:(NSArray *)descriptions { CDSet(self, @"descriptions", [descriptions copy]); }
- (void)loadPersistentStoresWithCompletionHandler:(void (^)(NSPersistentStoreDescription *, NSError *))block {
    NSArray *descriptions = self.persistentStoreDescriptions;
    if (!descriptions.count && block) { block(nil, CDError(134080, @"The container has no store descriptions.")); return; }
    for (NSPersistentStoreDescription *description in descriptions)
        [self.persistentStoreCoordinator addPersistentStoreWithDescription:description completionHandler:block];
}
- (NSManagedObjectContext *)newBackgroundContext {
    NSManagedObjectContext *context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    context.persistentStoreCoordinator = self.persistentStoreCoordinator;
    return context;
}
- (void)performBackgroundTask:(void (^)(NSManagedObjectContext *))block {
    if (!block) return;
    NSManagedObjectContext *context = [self newBackgroundContext];
    [context performBlock:^{ block(context); [context release]; }];
}
@end
