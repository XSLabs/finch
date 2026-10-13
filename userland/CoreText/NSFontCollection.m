/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSFontCollection and NSMutableFontCollection, in CoreText as Apple's are: a set of fonts
 * named by query descriptors (and fonts to leave out), matched through CoreText's font
 * collections. Descriptors are CTFontDescriptors, which are UIFoundation's NSFontDescriptors.
 *
 * Named collections, as Apple's:
 *   - com.apple.AllFonts      every font;
 *   - com.apple.UserFonts     the fonts in ~/Library/Fonts;
 *   - com.apple.Favorites, com.apple.Recents   the user's, kept like any other;
 *   - "Fixed Width"           monospaced fonts;
 *   - "PDF", "Web"            the families those formats have always named.
 * Collections the app shows are kept for the process, the user
 * (~/Library/FontCollections/<name>.collection, in Apple's format: a keyed archive whose
 * NSFontCollectionDictionary holds the query descriptors and the name, so macOS's and
 * Finch's collections are each other's) or the computer (/Library/FontCollections,
 * refused unless writable). A collection kept in a file comes before a built-in one of
 * the same name, as on macOS, which keeps "Fixed Width" and the like there too. Showing, hiding
 * and renaming post NSFontCollectionDidChangeNotification with Apple's keys.
 */
#import <Foundation/Foundation.h>
#import <AppKit/NSFontCollection.h>
#import <AppKit/NSFontDescriptor.h>
#import <CoreText/CoreText.h>

/* a descriptor for attributes (CoreText's, which is an NSFontDescriptor) */
static id
descriptor_with(NSDictionary *attributes)
{
    return CFBridgingRelease(CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef)attributes));
}

static BOOL
is_descriptor(id d)
{
    return d && CFGetTypeID((__bridge CFTypeRef)d) == CTFontDescriptorGetTypeID();
}

NSString *const NSFontCollectionDidChangeNotification = @"NSFontCollectionDidChange";
NSString *const NSFontCollectionActionKey = @"NSFontCollectionAction";
NSString *const NSFontCollectionNameKey = @"NSFontCollectionName";
NSString *const NSFontCollectionOldNameKey = @"NSFontCollectionOldName";
NSString *const NSFontCollectionVisibilityKey = @"NSFontCollectionVisibility";
NSString *const NSFontCollectionWasShown = @"NSFontCollectionWasShown";
NSString *const NSFontCollectionWasHidden = @"NSFontCollectionWasHidden";
NSString *const NSFontCollectionWasRenamed = @"NSFontCollectionWasRenamed";
NSString *const NSFontCollectionAllFonts = @"com.apple.AllFonts";
NSString *const NSFontCollectionUser = @"com.apple.UserFonts";
NSString *const NSFontCollectionFavorites = @"com.apple.Favorites";
NSString *const NSFontCollectionRecentlyUsed = @"com.apple.Recents";
NSString *const NSFontCollectionIncludeDisabledFontsOption = @"NSCTFontCollectionIncludeDisabledFontsOption";
NSString *const NSFontCollectionRemoveDuplicatesOption = @"NSCTFontCollectionRemoveDuplicatesOption";
NSString *const NSFontCollectionDisallowAutoActivationOption = @"NSCTFontCollectionDisallowAutoActivationOption";

@implementation NSFontCollection {
@protected
    NSArray *_query;     /* nil: every font */
    NSArray *_exclusion;
}

- (instancetype)_initWithQuery:(NSArray *)query exclusion:(NSArray *)exclusion
{
    if ((self = [super init])) {
        _query = [query copy];
        _exclusion = [exclusion copy];
    }
    return self;
}


+ (BOOL)supportsSecureCoding { return YES; }

/* (a mutable collection's copy is mutable too, as Apple's) */
- (id)copyWithZone:(NSZone *)zone
{
    return [[[self class] allocWithZone:zone] _initWithQuery:_query exclusion:_exclusion];
}

- (id)mutableCopyWithZone:(NSZone *)zone
{
    return [[NSMutableFontCollection allocWithZone:zone] _initWithQuery:_query exclusion:_exclusion];
}

- (instancetype)initWithCoder:(NSCoder *)c
{
    NSSet *classes = [NSSet setWithObjects:[NSArray class], NSClassFromString(@"NSFontDescriptor") ?: [NSObject class], nil];
    return [self _initWithQuery:[c decodeObjectOfClasses:classes forKey:@"NSFontCollectionQueryDescriptors"]
                      exclusion:[c decodeObjectOfClasses:classes forKey:@"NSFontCollectionExclusionDescriptors"]];
}

- (void)encodeWithCoder:(NSCoder *)c
{
    [c encodeObject:_query forKey:@"NSFontCollectionQueryDescriptors"];
    [c encodeObject:_exclusion forKey:@"NSFontCollectionExclusionDescriptors"];
}

/* ---- making ---- */

+ (NSFontCollection *)fontCollectionWithDescriptors:(NSArray *)queryDescriptors
{
    return [[self alloc] _initWithQuery:queryDescriptors ?: @[] exclusion:nil];
}

+ (NSFontCollection *)fontCollectionWithAllAvailableDescriptors
{
    return [[self alloc] _initWithQuery:nil exclusion:nil];
}

+ (NSFontCollection *)fontCollectionWithLocale:(NSLocale *)locale
{
    NSString *lang = [locale objectForKey:NSLocaleLanguageCode];
    if (!lang)
        return nil;
    NSFontDescriptor *d = descriptor_with(@{(id)kCTFontLanguagesAttribute : @[ lang ]});
    return [self fontCollectionWithDescriptors:@[ d ]];
}

static NSArray *
families(NSArray *names)
{
    NSMutableArray *a = [NSMutableArray array];
    for (NSString *n in names)
        [a addObject:descriptor_with(@{(id)kCTFontFamilyNameAttribute : n})];
    return a;
}

/* The collections every Mac has. */
static NSArray *
builtin_query(NSString *name, BOOL *found)
{
    *found = YES;
    if ([name isEqualToString:NSFontCollectionAllFonts])
        return nil;
    if ([name isEqualToString:@"Fixed Width"])
        return @[ descriptor_with(@{
            (id)kCTFontTraitsAttribute : @{(id)kCTFontSymbolicTrait : @(kCTFontMonoSpaceTrait)}
        }) ];
    if ([name isEqualToString:@"PDF"])
        return families(@[ @"Courier", @"Helvetica", @"Times", @"Symbol", @"Zapf Dingbats" ]);
    if ([name isEqualToString:@"Web"])
        return families(@[ @"Arial", @"Arial Black", @"Comic Sans MS", @"Courier New", @"Georgia", @"Impact", @"Times New Roman",
                           @"Trebuchet MS", @"Verdana", @"Webdings" ]);
    if ([name isEqualToString:NSFontCollectionUser]) {
        NSURL *dir = [[[NSFileManager defaultManager] URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask].firstObject
            URLByAppendingPathComponent:@"Fonts"];
        NSMutableArray *a = [NSMutableArray array];
        for (NSURL *u in [[NSFileManager defaultManager] contentsOfDirectoryAtURL:dir includingPropertiesForKeys:nil options:0 error:NULL]) {
            NSArray *ds = CFBridgingRelease(CTFontManagerCreateFontDescriptorsFromURL((__bridge CFURLRef)u));
            [a addObjectsFromArray:ds];
        }
        return a;
    }
    *found = NO;
    return nil;
}

static NSMutableDictionary *
process_collections(void)
{
    static NSMutableDictionary *d;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [NSMutableDictionary new]; });
    return d;
}

static NSURL *
collection_dir(NSFontCollectionVisibility v)
{
    if (v & NSFontCollectionVisibilityComputer)
        return [NSURL fileURLWithPath:@"/Library/FontCollections" isDirectory:YES];
    return [[[NSFileManager defaultManager] URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask].firstObject
        URLByAppendingPathComponent:@"FontCollections"
                        isDirectory:YES];
}

static NSURL *
collection_file(NSString *name, NSFontCollectionVisibility v)
{
    return [collection_dir(v) URLByAppendingPathComponent:[name stringByAppendingPathExtension:@"collection"]];
}

/* A .collection file's contents: Apple's archive, read and written. */
static NSDictionary *
read_collection(NSURL *url)
{
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (!data)
        return nil;
    NSKeyedUnarchiver *u = [[NSKeyedUnarchiver alloc] initForReadingFromData:data error:NULL];
    u.requiresSecureCoding = NO;
    NSDictionary *d = [u decodeObjectForKey:@"NSFontCollectionDictionary"];
    return [d isKindOfClass:[NSDictionary class]] ? d : nil;
}

static BOOL
write_collection(NSFontCollection *c, NSString *name, NSURL *url)
{
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"NSFontCollectionFontDescriptors"] = [(c.queryDescriptors ?: @[]) mutableCopy];
    if (c.exclusionDescriptors.count)
        d[@"NSFontCollectionExclusionDescriptors"] = [c.exclusionDescriptors mutableCopy];
    d[@"NSFontCollectionAttributes"] = [NSMutableDictionary dictionaryWithObjectsAndKeys:name, @"NSFontCollectionName",
                                                                                         url.lastPathComponent, @"NSFontCollectionFileName", nil];
    NSKeyedArchiver *a = [[NSKeyedArchiver alloc] initRequiringSecureCoding:NO];
    [a encodeObject:d forKey:@"NSFontCollectionDictionary"];
    [a finishEncoding];
    return [a.encodedData writeToURL:url atomically:YES];
}

static NSArray *
descriptors_in(id a)
{
    if (![a isKindOfClass:[NSArray class]])
        return nil;
    NSMutableArray *out = [NSMutableArray array];
    for (id d in a)
        if (is_descriptor(d))
            [out addObject:d];
    return out;
}

static NSFontCollection *
stored(Class cls, NSString *name, NSFontCollectionVisibility v)
{
    if (v & NSFontCollectionVisibilityProcess) {
        NSFontCollection *c = process_collections()[name];
        if (c)
            return [[cls alloc] _initWithQuery:c->_query exclusion:c->_exclusion];
    }
    for (NSFontCollectionVisibility vis = NSFontCollectionVisibilityUser; vis <= NSFontCollectionVisibilityComputer; vis <<= 1) {
        if (!(v & vis))
            continue;
        NSDictionary *d = read_collection(collection_file(name, vis));
        if (d)
            return [[cls alloc] _initWithQuery:descriptors_in(d[@"NSFontCollectionFontDescriptors"]) ?: @[]
                                     exclusion:descriptors_in(d[@"NSFontCollectionExclusionDescriptors"])];
    }
    return nil;
}

+ (NSFontCollection *)fontCollectionWithName:(NSFontCollectionName)name
{
    return [self fontCollectionWithName:name
                             visibility:NSFontCollectionVisibilityProcess | NSFontCollectionVisibilityUser | NSFontCollectionVisibilityComputer];
}

+ (NSFontCollection *)fontCollectionWithName:(NSFontCollectionName)name visibility:(NSFontCollectionVisibility)visibility
{
    if (!name)
        return nil;
    NSFontCollection *c = stored(self, name, visibility);
    if (c)
        return c;
    if ([name isEqualToString:NSFontCollectionFavorites] || [name isEqualToString:NSFontCollectionRecentlyUsed])
        return [[self alloc] _initWithQuery:@[] exclusion:nil];
    BOOL found;
    NSArray *query = builtin_query(name, &found);
    return found ? [[self alloc] _initWithQuery:query exclusion:nil] : nil;
}

+ (NSArray *)allFontCollectionNames
{
    NSMutableSet *names = [NSMutableSet setWithObjects:NSFontCollectionAllFonts, NSFontCollectionUser, NSFontCollectionFavorites,
                                                       NSFontCollectionRecentlyUsed, @"Fixed Width", @"PDF", @"Web", nil];
    [names addObjectsFromArray:process_collections().allKeys];
    for (NSFontCollectionVisibility vis = NSFontCollectionVisibilityUser; vis <= NSFontCollectionVisibilityComputer; vis <<= 1)
        for (NSURL *u in [[NSFileManager defaultManager] contentsOfDirectoryAtURL:collection_dir(vis) includingPropertiesForKeys:nil
                                                                           options:0 error:NULL])
            if ([u.pathExtension isEqualToString:@"collection"])
                [names addObject:u.URLByDeletingPathExtension.lastPathComponent];
    return names.allObjects;
}

static void
changed(NSString *action, NSString *name, NSString *oldName, NSFontCollectionVisibility v)
{
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObjectsAndKeys:action, NSFontCollectionActionKey, name,
                                                                                  NSFontCollectionNameKey, @(v), NSFontCollectionVisibilityKey, nil];
    if (oldName)
        info[NSFontCollectionOldNameKey] = oldName;
    [[NSNotificationCenter defaultCenter] postNotificationName:NSFontCollectionDidChangeNotification object:nil userInfo:info];
}

static BOOL
fail(NSError **error, NSInteger code, NSString *name)
{
    if (error)
        *error = [NSError errorWithDomain:NSCocoaErrorDomain code:code userInfo:@{NSFilePathErrorKey : name ?: @""}];
    return NO;
}

+ (BOOL)showFontCollection:(NSFontCollection *)collection withName:(NSFontCollectionName)name
                visibility:(NSFontCollectionVisibility)visibility error:(NSError **)error
{
    if (!collection || !name.length)
        return fail(error, NSFileWriteInvalidFileNameError, name);
    if (visibility & NSFontCollectionVisibilityProcess)
        process_collections()[name] = [collection copy];
    for (NSFontCollectionVisibility vis = NSFontCollectionVisibilityUser; vis <= NSFontCollectionVisibilityComputer; vis <<= 1) {
        if (!(visibility & vis))
            continue;
        [[NSFileManager defaultManager] createDirectoryAtURL:collection_dir(vis) withIntermediateDirectories:YES attributes:nil error:NULL];
        if (!write_collection(collection, name, collection_file(name, vis)))
            return fail(error, NSFileWriteNoPermissionError, name);
    }
    changed(NSFontCollectionWasShown, name, nil, visibility);
    return YES;
}

+ (BOOL)hideFontCollectionWithName:(NSFontCollectionName)name visibility:(NSFontCollectionVisibility)visibility error:(NSError **)error
{
    BOOL found = NO;
    if ((visibility & NSFontCollectionVisibilityProcess) && process_collections()[name]) {
        [process_collections() removeObjectForKey:name];
        found = YES;
    }
    for (NSFontCollectionVisibility vis = NSFontCollectionVisibilityUser; vis <= NSFontCollectionVisibilityComputer; vis <<= 1)
        if ((visibility & vis) && [[NSFileManager defaultManager] removeItemAtURL:collection_file(name, vis) error:NULL])
            found = YES;
    if (!found)
        return fail(error, NSFileNoSuchFileError, name);
    changed(NSFontCollectionWasHidden, name, nil, visibility);
    return YES;
}

+ (BOOL)renameFontCollectionWithName:(NSFontCollectionName)name visibility:(NSFontCollectionVisibility)visibility
                              toName:(NSFontCollectionName)newName error:(NSError **)error
{
    NSFontCollection *c = stored(self, name, visibility);
    if (!c)
        return fail(error, NSFileNoSuchFileError, name);
    if (![self hideFontCollectionWithName:name visibility:visibility error:error])
        return NO;
    if (![self showFontCollection:c withName:newName visibility:visibility error:error])
        return NO;
    changed(NSFontCollectionWasRenamed, newName, name, visibility);
    return YES;
}

/* ---- reading ---- */

- (NSArray *)queryDescriptors { return _query; }
- (NSArray *)exclusionDescriptors { return _exclusion; }

- (CTFontCollectionRef)_ctCollection
{
    if (!_query)
        return CTFontCollectionCreateFromAvailableFonts(NULL);
    return CTFontCollectionCreateWithFontDescriptors((__bridge CFArrayRef)_query, NULL);
}

/* Matching fonts, less the excluded ones (a font is excluded when every attribute an
   exclusion names matches it). */
- (NSArray *)_matchFamily:(NSString *)family options:(NSDictionary *)options
{
    if (_query && !_query.count)
        return @[];
    CTFontCollectionRef c = [self _ctCollection];
    if (!c)
        return @[];
    CFArrayRef found = family ? CTFontCollectionCreateMatchingFontDescriptorsForFamily(c, (__bridge CFStringRef)family, (__bridge CFDictionaryRef)options)
                              : CTFontCollectionCreateMatchingFontDescriptorsWithOptions(c, (__bridge CFDictionaryRef)options);
    CFRelease(c);
    NSMutableArray *result = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (id d in (__bridge NSArray *)found) {
        CTFontDescriptorRef cd = (__bridge CTFontDescriptorRef)d;
        NSString *ps = CFBridgingRelease(CTFontDescriptorCopyAttribute(cd, kCTFontNameAttribute));
        BOOL excluded = NO;
        for (id x in _exclusion) {
            NSDictionary *xa = CFBridgingRelease(CTFontDescriptorCopyAttributes((__bridge CTFontDescriptorRef)x));
            BOOL all = xa.count > 0;
            for (NSString *k in xa) {
                id value = CFBridgingRelease(CTFontDescriptorCopyAttribute(cd, (__bridge CFStringRef)k));
                if (![value isEqual:xa[k]] && !([k isEqualToString:(id)kCTFontNameAttribute] && [ps isEqualToString:xa[k]])) {
                    all = NO;
                    break;
                }
            }
            if (all) {
                excluded = YES;
                break;
            }
        }
        if (excluded || (ps && [seen containsObject:ps]))
            continue;
        if (ps)
            [seen addObject:ps];
        [result addObject:d];
    }
    if (found)
        CFRelease(found);
    return result;
}

- (NSArray *)matchingDescriptors { return [self _matchFamily:nil options:nil]; }
- (NSArray *)matchingDescriptorsWithOptions:(NSDictionary *)options { return [self _matchFamily:nil options:options]; }
- (NSArray *)matchingDescriptorsForFamily:(NSString *)family { return [self _matchFamily:family options:nil]; }
- (NSArray *)matchingDescriptorsForFamily:(NSString *)family options:(NSDictionary *)options { return [self _matchFamily:family options:options]; }

@end

@implementation NSMutableFontCollection

+ (NSMutableFontCollection *)fontCollectionWithDescriptors:(NSArray *)queryDescriptors
{
    return (NSMutableFontCollection *)[super fontCollectionWithDescriptors:queryDescriptors];
}

+ (NSMutableFontCollection *)fontCollectionWithAllAvailableDescriptors
{
    return (NSMutableFontCollection *)[super fontCollectionWithAllAvailableDescriptors];
}

+ (NSMutableFontCollection *)fontCollectionWithLocale:(NSLocale *)locale
{
    return (NSMutableFontCollection *)[super fontCollectionWithLocale:locale];
}

+ (NSMutableFontCollection *)fontCollectionWithName:(NSFontCollectionName)name
{
    return (NSMutableFontCollection *)[super fontCollectionWithName:name];
}

+ (NSMutableFontCollection *)fontCollectionWithName:(NSFontCollectionName)name visibility:(NSFontCollectionVisibility)visibility
{
    return (NSMutableFontCollection *)[super fontCollectionWithName:name visibility:visibility];
}

- (void)setQueryDescriptors:(NSArray *)q
{
    _query = [q copy] ?: @[];
}

- (void)setExclusionDescriptors:(NSArray *)x
{
    _exclusion = [x copy];
}

- (void)addQueryForDescriptors:(NSArray *)descriptors
{
    self.queryDescriptors = [(_query ?: @[]) arrayByAddingObjectsFromArray:descriptors];
    /* added fonts are no longer excluded */
    NSMutableArray *x = [_exclusion mutableCopy];
    [x removeObjectsInArray:descriptors];
    self.exclusionDescriptors = x;
}

- (void)removeQueryForDescriptors:(NSArray *)descriptors
{
    NSMutableArray *q = [_query mutableCopy];
    NSUInteger before = q.count;
    [q removeObjectsInArray:descriptors];
    self.queryDescriptors = q;
    /* a font that wasn't a query of its own is left out instead */
    if (q.count == before)
        self.exclusionDescriptors = [(_exclusion ?: @[]) arrayByAddingObjectsFromArray:descriptors];
}

@end
