/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSUbiquitousKeyValueStore. Finch has no iCloud, so the store is the app's own: kept
 * where Apple's keeps its local copy, ~/Library/SyncedPreferences/<bundle identifier>.plist,
 * written by -synchronize and when the app quits, with Apple's limits (1024 keys, 1 MB in
 * all, a key at most 64 bytes long). Nothing changes it from outside, so the
 * did-change-externally notification is never posted.
 */
#import <Foundation/Foundation.h>

enum { MAX_KEYS = 1024, MAX_BYTES = 1024 * 1024, MAX_KEY_BYTES = 64 };

@implementation NSUbiquitousKeyValueStore {
    NSMutableDictionary *_values;
    NSString *_path;
    BOOL _dirty;
}

+ (NSUbiquitousKeyValueStore *)defaultStore
{
    static NSUbiquitousKeyValueStore *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ store = [[self alloc] init]; });
    return store;
}

- (instancetype)init
{
    if ((self = [super init])) {
        NSString *ident = [NSBundle mainBundle].bundleIdentifier ?: [NSProcessInfo processInfo].processName;
        _path = [[NSHomeDirectory() stringByAppendingFormat:@"/Library/SyncedPreferences/%@.plist", ident] retain];
        NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:_path];
        _values = [saved isKindOfClass:[NSDictionary class]] ? [saved mutableCopy] : [NSMutableDictionary new];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_finchSave:)
                                                     name:@"NSApplicationWillTerminateNotification" object:nil];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_values release];
    [_path release];
    [super dealloc];
}

- (void)_finchSave:(NSNotification *)n { [self synchronize]; }

- (id)objectForKey:(NSString *)key
{
    @synchronized(self) {
        return [[_values[key] retain] autorelease];
    }
}

static NSUInteger
size_of(id plist)
{
    NSData *d = [NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    return d.length;
}

- (void)setObject:(id)value forKey:(NSString *)key
{
    if (!key)
        return;
    if (!value) {
        [self removeObjectForKey:key];
        return;
    }
    if (strlen(key.UTF8String) > MAX_KEY_BYTES || ![NSPropertyListSerialization propertyList:value isValidForFormat:NSPropertyListBinaryFormat_v1_0])
        return;
    @synchronized(self) {
        if (!_values[key] && _values.count >= MAX_KEYS)
            return;
        id old = [_values[key] retain];
        _values[key] = value;
        if (size_of(_values) > MAX_BYTES) {
            if (old)
                _values[key] = old;
            else
                [_values removeObjectForKey:key];
        }
        [old release];
        _dirty = YES;
    }
}

- (void)removeObjectForKey:(NSString *)key
{
    @synchronized(self) {
        if (key && _values[key]) {
            [_values removeObjectForKey:key];
            _dirty = YES;
        }
    }
}

- (NSString *)stringForKey:(NSString *)key { id v = [self objectForKey:key]; return [v isKindOfClass:[NSString class]] ? v : nil; }
- (NSArray *)arrayForKey:(NSString *)key { id v = [self objectForKey:key]; return [v isKindOfClass:[NSArray class]] ? v : nil; }
- (NSDictionary *)dictionaryForKey:(NSString *)key { id v = [self objectForKey:key]; return [v isKindOfClass:[NSDictionary class]] ? v : nil; }
- (NSData *)dataForKey:(NSString *)key { id v = [self objectForKey:key]; return [v isKindOfClass:[NSData class]] ? v : nil; }
- (long long)longLongForKey:(NSString *)key { id v = [self objectForKey:key]; return [v respondsToSelector:@selector(longLongValue)] ? [v longLongValue] : 0; }
- (double)doubleForKey:(NSString *)key { id v = [self objectForKey:key]; return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : 0; }
- (BOOL)boolForKey:(NSString *)key { id v = [self objectForKey:key]; return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : NO; }
- (void)setString:(NSString *)v forKey:(NSString *)key { [self setObject:v forKey:key]; }
- (void)setData:(NSData *)v forKey:(NSString *)key { [self setObject:v forKey:key]; }
- (void)setArray:(NSArray *)v forKey:(NSString *)key { [self setObject:v forKey:key]; }
- (void)setDictionary:(NSDictionary *)v forKey:(NSString *)key { [self setObject:v forKey:key]; }
- (void)setLongLong:(long long)v forKey:(NSString *)key { [self setObject:@(v) forKey:key]; }
- (void)setDouble:(double)v forKey:(NSString *)key { [self setObject:@(v) forKey:key]; }
- (void)setBool:(BOOL)v forKey:(NSString *)key { [self setObject:@(v) forKey:key]; }

- (NSDictionary *)dictionaryRepresentation
{
    @synchronized(self) {
        return [[_values copy] autorelease];
    }
}

- (BOOL)synchronize
{
    @synchronized(self) {
        if (!_dirty)
            return YES;
        [[NSFileManager defaultManager] createDirectoryAtPath:_path.stringByDeletingLastPathComponent withIntermediateDirectories:YES
                                                   attributes:nil error:NULL];
        BOOL ok = [_values writeToFile:_path atomically:YES];
        if (ok)
            _dirty = NO;
        return ok;
    }
}

@end
