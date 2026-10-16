/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSItemProvider, Finch's: representations registered by type, each loaded on demand
 * (as data, as a file, as an item or as an object), as Apple's are.
 *
 * Types conform through UniformTypeIdentifiers' UTType, looked up at run time (that
 * framework links Foundation, so Foundation can't link it). Loads complete on a
 * background queue. A representation that can't be had (none conforms, or its handler
 * fails) ends in NSItemProviderItemUnavailableError, as with Apple's. Data asked for as
 * a file is written to a temporary file named with the type's extension; a file asked
 * for as a file is copied, unless it was registered to open in place. Both are removed
 * when the completion handler returns.
 */
#import <Foundation/Foundation.h>
#import <objc/message.h>
#include <dlfcn.h>

NSString *const NSItemProviderErrorDomain = @"NSItemProviderErrorDomain";
NSString *const NSItemProviderPreferredImageSizeKey = @"NSItemProviderPreferredImageSize";

/* --- types --- */

static Class
uttype_class(void)
{
    static Class cls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      cls = objc_getClass("UTType");
      if (!cls && dlopen("/System/Library/Frameworks/UniformTypeIdentifiers.framework/UniformTypeIdentifiers", RTLD_LAZY))
          cls = objc_getClass("UTType");
    });
    return cls;
}

static id
uttype(NSString *identifier)
{
    Class cls = uttype_class();
    return cls && identifier ? ((id(*)(id, SEL, id))objc_msgSend)(cls, sel_registerName("typeWithIdentifier:"), identifier) : nil;
}

/* Whether a type is the other or conforms to it. */
static BOOL
conforms(NSString *type, NSString *to)
{
    if ([type isEqualToString:to])
        return YES;
    id a = uttype(type), b = uttype(to);
    if (a && b)
        return ((BOOL(*)(id, SEL, id))objc_msgSend)(a, sel_registerName("conformsToType:"), b);
    return [to isEqualToString:@"public.item"] || [to isEqualToString:@"public.data"];
}

static NSString *
type_for_extension(NSString *extension)
{
    Class cls = uttype_class();
    id t = cls && extension.length
               ? ((id(*)(id, SEL, id))objc_msgSend)(cls, sel_registerName("typeWithFilenameExtension:"), extension)
               : nil;
    NSString *identifier = t ? ((id(*)(id, SEL))objc_msgSend)(t, sel_registerName("identifier")) : nil;
    return identifier ?: @"public.data";
}

static NSString *
extension_for_type(NSString *type)
{
    id t = uttype(type);
    return t ? ((id(*)(id, SEL))objc_msgSend)(t, sel_registerName("preferredFilenameExtension")) : nil;
}

static NSError *
unavailable(void)
{
    return [NSError errorWithDomain:NSItemProviderErrorDomain code:NSItemProviderItemUnavailableError userInfo:nil];
}

static dispatch_queue_t
load_queue(void)
{
    return dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
}

/* --- representations --- */

typedef NS_ENUM(NSInteger, RepKind) {
    RepData,   /* a data load handler */
    RepFile,   /* a file load handler */
    RepItem,   /* an item load handler (the older API) */
    RepObject, /* an object (or its class's load handler) writing this type */
};

@interface FinchItemRep : NSObject {
@public
    NSString *type;
    RepKind kind;
    NSItemProviderRepresentationVisibility visibility;
    BOOL openInPlace, coordinated;
    id handler;           /* (copied block) */
    id<NSItemProviderWriting> object;
    Class objectClass;
}
@end

@implementation FinchItemRep
- (void)dealloc
{
    [type release];
    [handler release];
    [(id)object release];
    [super dealloc];
}
@end

@implementation NSItemProvider {
    NSMutableArray<FinchItemRep *> *_reps;
    NSString *_suggestedName;
    NSItemProviderLoadHandler _preview;
}

- (instancetype)init
{
    if ((self = [super init]))
        _reps = [NSMutableArray new];
    return self;
}

- (void)dealloc
{
    [_reps release];
    [_suggestedName release];
    [_preview release];
    [super dealloc];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p> {types = %@}", [self class], self, self.registeredTypeIdentifiers];
}

- (FinchItemRep *)_add:(NSString *)type kind:(RepKind)kind visibility:(NSItemProviderRepresentationVisibility)visibility handler:(id)handler
{
    FinchItemRep *r = [FinchItemRep new];
    r->type = [type copy];
    r->kind = kind;
    r->visibility = visibility;
    r->handler = [handler copy];
    [_reps addObject:r];
    [r release];
    return r;
}

- (NSString *)suggestedName
{
    return _suggestedName;
}

- (void)setSuggestedName:(NSString *)name
{
    [_suggestedName autorelease];
    _suggestedName = [name copy];
}

/* --- registering --- */

- (instancetype)initWithObject:(id<NSItemProviderWriting>)object
{
    if ((self = [self init]))
        [self registerObject:object visibility:NSItemProviderRepresentationVisibilityAll];
    return self;
}

- (void)registerObject:(id<NSItemProviderWriting>)object visibility:(NSItemProviderRepresentationVisibility)visibility
{
    NSArray *types = [(id)object respondsToSelector:@selector(writableTypeIdentifiersForItemProvider)]
                         ? [(id)object writableTypeIdentifiersForItemProvider]
                         : [[(id)object class] writableTypeIdentifiersForItemProvider];
    for (NSString *t in types) {
        FinchItemRep *r = [self _add:t kind:RepObject visibility:visibility handler:nil];
        r->object = [(id)object retain];
    }
}

- (void)registerObjectOfClass:(Class<NSItemProviderWriting>)aClass visibility:(NSItemProviderRepresentationVisibility)visibility
                  loadHandler:(NSProgress *_Nullable (^)(void (^)(__kindof id<NSItemProviderWriting> _Nullable, NSError *_Nullable)))loadHandler
{
    for (NSString *t in [aClass writableTypeIdentifiersForItemProvider]) {
        FinchItemRep *r = [self _add:t kind:RepObject visibility:visibility handler:loadHandler];
        r->objectClass = aClass;
    }
}

- (void)registerDataRepresentationForTypeIdentifier:(NSString *)typeIdentifier visibility:(NSItemProviderRepresentationVisibility)visibility
                                        loadHandler:(NSProgress *_Nullable (^)(void (^)(NSData *, NSError *)))loadHandler
{
    [self _add:typeIdentifier kind:RepData visibility:visibility handler:loadHandler];
}

- (void)registerFileRepresentationForTypeIdentifier:(NSString *)typeIdentifier fileOptions:(NSItemProviderFileOptions)fileOptions
                                         visibility:(NSItemProviderRepresentationVisibility)visibility
                                        loadHandler:(NSProgress *_Nullable (^)(void (^)(NSURL *, BOOL, NSError *)))loadHandler
{
    FinchItemRep *r = [self _add:typeIdentifier kind:RepFile visibility:visibility handler:loadHandler];
    r->openInPlace = (fileOptions & NSItemProviderFileOptionOpenInPlace) != 0;
}

- (void)registerItemForTypeIdentifier:(NSString *)typeIdentifier loadHandler:(NSItemProviderLoadHandler)loadHandler
{
    [self _add:typeIdentifier kind:RepItem visibility:NSItemProviderRepresentationVisibilityAll handler:loadHandler];
}

- (instancetype)initWithItem:(id<NSSecureCoding>)item typeIdentifier:(NSString *)typeIdentifier
{
    if ((self = [self init]) && item && typeIdentifier) {
        id held = [(id)item retain];
        [self registerItemForTypeIdentifier:typeIdentifier
                                loadHandler:^(NSItemProviderCompletionHandler completion, Class expected, NSDictionary *options) {
                                  completion(held, nil);
                                }];
        /* (the block keeps the item; this balances the retain above when it goes) */
        [held autorelease];
    }
    return self;
}

/* A file's own type, then its URL. */
- (instancetype)initWithContentsOfURL:(NSURL *)fileURL
{
    if (!(self = [self init]))
        return nil;
    if (!fileURL)
        return self;
    NSString *type = type_for_extension(fileURL.pathExtension);
    NSURL *url = [[fileURL copy] autorelease];
    [self registerFileRepresentationForTypeIdentifier:type fileOptions:0 visibility:NSItemProviderRepresentationVisibilityAll
                                          loadHandler:^NSProgress *(void (^completion)(NSURL *, BOOL, NSError *)) {
                                            completion(url, NO, nil);
                                            return nil;
                                          }];
    for (NSString *t in @[ @"public.file-url", @"public.url" ])
        [self registerItemForTypeIdentifier:t
                                loadHandler:^(NSItemProviderCompletionHandler completion, Class expected, NSDictionary *options) {
                                  completion(url, nil);
                                }];
    return self;
}

/* (UniformTypeIdentifiers' NSItemProvider (UTType) initializer calls this) */
- (instancetype)_finchInitWithContentsOfURL:(NSURL *)fileURL type:(NSString *)type openInPlace:(BOOL)openInPlace
                                 coordinated:(BOOL)coordinated visibility:(NSItemProviderRepresentationVisibility)visibility
{
    if (!(self = [self init]))
        return nil;
    NSURL *url = [[fileURL copy] autorelease];
    [self registerFileRepresentationForTypeIdentifier:type ?: type_for_extension(fileURL.pathExtension)
                                          fileOptions:openInPlace ? NSItemProviderFileOptionOpenInPlace : 0
                                           visibility:visibility
                                          loadHandler:^NSProgress *(void (^completion)(NSURL *, BOOL, NSError *)) {
                                            completion(url, openInPlace, nil);
                                            return nil;
                                          }];
    _reps.lastObject->coordinated = coordinated;
    return self;
}

/* --- what it has --- */

- (NSArray<NSString *> *)registeredTypeIdentifiers
{
    NSMutableOrderedSet *types = [NSMutableOrderedSet orderedSet];
    for (FinchItemRep *r in _reps)
        [types addObject:r->type];
    return types.array;
}

- (NSArray<NSString *> *)registeredTypeIdentifiersWithFileOptions:(NSItemProviderFileOptions)fileOptions
{
    BOOL inPlace = (fileOptions & NSItemProviderFileOptionOpenInPlace) != 0;
    NSMutableOrderedSet *types = [NSMutableOrderedSet orderedSet];
    for (FinchItemRep *r in _reps)
        if (!inPlace || (r->kind == RepFile && r->openInPlace))
            [types addObject:r->type];
    return types.array;
}

- (BOOL)hasItemConformingToTypeIdentifier:(NSString *)typeIdentifier
{
    for (FinchItemRep *r in _reps)
        if (conforms(r->type, typeIdentifier))
            return YES;
    return NO;
}

- (BOOL)hasRepresentationConformingToTypeIdentifier:(NSString *)typeIdentifier fileOptions:(NSItemProviderFileOptions)fileOptions
{
    for (NSString *t in [self registeredTypeIdentifiersWithFileOptions:fileOptions])
        if (conforms(t, typeIdentifier))
            return YES;
    return NO;
}

/* The representation for a type: one of that type, or the first that conforms to it. */
- (FinchItemRep *)_repFor:(NSString *)type
{
    for (FinchItemRep *r in _reps)
        if ([r->type isEqualToString:type])
            return r;
    for (FinchItemRep *r in _reps)
        if (conforms(r->type, type))
            return r;
    return nil;
}

- (BOOL)canLoadObjectOfClass:(Class<NSItemProviderReading>)aClass
{
    if (![(id)aClass respondsToSelector:@selector(readableTypeIdentifiersForItemProvider)])
        return NO;
    for (NSString *t in [aClass readableTypeIdentifiersForItemProvider])
        if ([self _repFor:t])
            return YES;
    return NO;
}

/* --- loading --- */

static NSProgress *
new_progress(void)
{
    NSProgress *p = [NSProgress discreteProgressWithTotalUnitCount:100];
    return p;
}

/* A representation's object, then its data. */
static void
object_of(FinchItemRep *r, void (^done)(id, NSError *))
{
    if (r->object) {
        done(r->object, nil);
        return;
    }
    NSProgress *(^handler)(void (^)(id<NSItemProviderWriting>, NSError *)) = r->handler;
    if (!handler) {
        done(nil, unavailable());
        return;
    }
    handler(^(id<NSItemProviderWriting> o, NSError *e) {
      done(o, e);
    });
}

/* Data for a representation, whatever its kind. */
- (void)_dataOf:(FinchItemRep *)r type:(NSString *)type completion:(void (^)(NSData *, NSError *))done
{
    switch (r->kind) {
    case RepData: {
        NSProgress *(^handler)(void (^)(NSData *, NSError *)) = r->handler;
        handler(^(NSData *d, NSError *e) {
          done(d, d ? nil : unavailable());
        });
        break;
    }
    case RepFile: {
        NSProgress *(^handler)(void (^)(NSURL *, BOOL, NSError *)) = r->handler;
        handler(^(NSURL *url, BOOL inPlace, NSError *e) {
          NSData *d = url ? [NSData dataWithContentsOfURL:url] : nil;
          done(d, d ? nil : unavailable());
        });
        break;
    }
    case RepItem: {
        NSItemProviderLoadHandler handler = r->handler;
        handler(
            ^(id item, NSError *e) {
              NSData *d = nil;
              if ([item isKindOfClass:[NSData class]])
                  d = item;
              else if ([item isKindOfClass:[NSString class]])
                  d = [item dataUsingEncoding:NSUTF8StringEncoding];
              else if ([item isKindOfClass:[NSURL class]] && [item isFileURL] && !conforms(type, @"public.url"))
                  d = [NSData dataWithContentsOfURL:item];
              else if ([item isKindOfClass:[NSURL class]])
                  d = [[item absoluteString] dataUsingEncoding:NSUTF8StringEncoding];
              done(d, d ? nil : unavailable());
            },
            [NSData class], nil);
        break;
    }
    case RepObject:
        object_of(r, ^(id o, NSError *e) {
          if (!o || ![o respondsToSelector:@selector(loadDataWithTypeIdentifier:forItemProviderCompletionHandler:)]) {
              done(nil, unavailable());
              return;
          }
          [o loadDataWithTypeIdentifier:r->type
              forItemProviderCompletionHandler:^(NSData *d, NSError *err) {
                done(d, d ? nil : unavailable());
              }];
        });
        break;
    }
}

- (NSProgress *)loadDataRepresentationForTypeIdentifier:(NSString *)typeIdentifier
                                      completionHandler:(void (^)(NSData *, NSError *))completionHandler
{
    NSProgress *progress = new_progress();
    FinchItemRep *r = [[self _repFor:typeIdentifier] retain];
    void (^completion)(NSData *, NSError *) = [[completionHandler copy] autorelease];
    dispatch_async(load_queue(), ^{
      if (!r) {
          completion(nil, unavailable());
          return;
      }
      [self _dataOf:r type:typeIdentifier
          completion:^(NSData *d, NSError *e) {
            progress.completedUnitCount = 100;
            completion(d, e);
          }];
      [r release];
    });
    return progress;
}

/* A temporary copy, or the file itself when it opens in place; removed after done. */
static void
hand_over(NSURL *url, BOOL inPlace, NSString *name, void (^done)(NSURL *, BOOL, NSError *))
{
    if (inPlace) {
        done(url, YES, nil);
        return;
    }
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSURL *copy = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:name ?: url.lastPathComponent]];
    NSError *error = nil;
    if (![[NSFileManager defaultManager] copyItemAtURL:url toURL:copy error:&error])
        done(nil, NO, unavailable());
    else
        done(copy, NO, nil);
    [[NSFileManager defaultManager] removeItemAtPath:dir error:NULL];
}

- (void)_fileFor:(NSString *)type inPlace:(BOOL)wantInPlace completion:(void (^)(NSURL *, BOOL, NSError *))done
{
    FinchItemRep *r = [self _repFor:type];
    if (!r) {
        done(nil, NO, unavailable());
        return;
    }
    if (r->kind == RepFile) {
        NSProgress *(^handler)(void (^)(NSURL *, BOOL, NSError *)) = r->handler;
        handler(^(NSURL *url, BOOL inPlace, NSError *e) {
          if (!url)
              done(nil, NO, unavailable());
          else
              hand_over(url, wantInPlace && inPlace && r->openInPlace, nil, done);
        });
        return;
    }
    NSString *name = _suggestedName;
    [self _dataOf:r type:type
        completion:^(NSData *d, NSError *e) {
          if (!d) {
              done(nil, NO, e ?: unavailable());
              return;
          }
          NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
          [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
          NSString *file = name.length ? name : @"data";
          NSString *ext = extension_for_type(r->type);
          if (ext.length && ![file.pathExtension isEqualToString:ext])
              file = [file stringByAppendingPathExtension:ext];
          NSURL *url = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:file]];
          if ([d writeToURL:url atomically:NO])
              done(url, NO, nil);
          else
              done(nil, NO, unavailable());
          [[NSFileManager defaultManager] removeItemAtPath:dir error:NULL];
        }];
}

- (NSProgress *)loadFileRepresentationForTypeIdentifier:(NSString *)typeIdentifier
                                      completionHandler:(void (^)(NSURL *, NSError *))completionHandler
{
    NSProgress *progress = new_progress();
    void (^completion)(NSURL *, NSError *) = [[completionHandler copy] autorelease];
    dispatch_async(load_queue(), ^{
      [self _fileFor:typeIdentifier inPlace:NO
          completion:^(NSURL *url, BOOL inPlace, NSError *e) {
            progress.completedUnitCount = 100;
            completion(url, e);
          }];
    });
    return progress;
}

- (NSProgress *)loadInPlaceFileRepresentationForTypeIdentifier:(NSString *)typeIdentifier
                                             completionHandler:(void (^)(NSURL *, BOOL, NSError *))completionHandler
{
    NSProgress *progress = new_progress();
    void (^completion)(NSURL *, BOOL, NSError *) = [[completionHandler copy] autorelease];
    dispatch_async(load_queue(), ^{
      [self _fileFor:typeIdentifier inPlace:YES
          completion:^(NSURL *url, BOOL inPlace, NSError *e) {
            progress.completedUnitCount = 100;
            completion(url, inPlace, e);
          }];
    });
    return progress;
}

- (NSProgress *)loadObjectOfClass:(Class<NSItemProviderReading>)aClass
                completionHandler:(void (^)(__kindof id<NSItemProviderReading> _Nullable, NSError *_Nullable))completionHandler
{
    NSProgress *progress = new_progress();
    void (^completion)(id, NSError *) = [[completionHandler copy] autorelease];
    /* (the class's readable types in its order, the first the provider has) */
    NSString *type = nil;
    FinchItemRep *r = nil;
    if ([(id)aClass respondsToSelector:@selector(readableTypeIdentifiersForItemProvider)])
        for (NSString *t in [aClass readableTypeIdentifiersForItemProvider])
            if ((r = [self _repFor:t])) {
                type = t;
                break;
            }
    [r retain];
    dispatch_async(load_queue(), ^{
      if (!r) {
          completion(nil, [NSError errorWithDomain:NSItemProviderErrorDomain code:NSItemProviderUnavailableCoercionError userInfo:nil]);
          return;
      }
      void (^fromData)(void) = ^{
        [self _dataOf:r type:type
            completion:^(NSData *d, NSError *e) {
              NSError *err = e;
              id o = d ? [aClass objectWithItemProviderData:d typeIdentifier:r->type error:&err] : nil;
              progress.completedUnitCount = 100;
              completion(o, o ? nil : (err ?: unavailable()));
            }];
      };
      if (r->kind == RepObject)
          object_of(r, ^(id o, NSError *e) {
            if ([o isKindOfClass:aClass]) {
                progress.completedUnitCount = 100;
                completion(o, nil);
            } else
                fromData();
          });
      else
          fromData();
      [r release];
    });
    return progress;
}

- (void)loadItemForTypeIdentifier:(NSString *)typeIdentifier options:(NSDictionary *)options
                completionHandler:(NSItemProviderCompletionHandler)completionHandler
{
    if (!completionHandler)
        return;
    FinchItemRep *r = [[self _repFor:typeIdentifier] retain];
    NSItemProviderCompletionHandler completion = [[completionHandler copy] autorelease];
    dispatch_async(load_queue(), ^{
      if (!r)
          completion(nil, unavailable());
      else if (r->kind == RepItem) {
          NSItemProviderLoadHandler handler = r->handler;
          handler(completion, [NSObject class], options);
      } else
          [self _dataOf:r type:typeIdentifier
              completion:^(NSData *d, NSError *e) {
                completion(d, e);
              }];
      [r release];
    });
}

/* --- previews --- */

- (NSItemProviderLoadHandler)previewImageHandler
{
    return _preview;
}

- (void)setPreviewImageHandler:(NSItemProviderLoadHandler)handler
{
    [_preview autorelease];
    _preview = [handler copy];
}

- (void)loadPreviewImageWithOptions:(NSDictionary *)options completionHandler:(NSItemProviderCompletionHandler)completionHandler
{
    if (!completionHandler)
        return;
    NSItemProviderLoadHandler preview = [[_preview retain] autorelease];
    NSItemProviderCompletionHandler completion = [[completionHandler copy] autorelease];
    dispatch_async(load_queue(), ^{
      if (preview)
          preview(completion, [NSObject class], options);
      else
          completion(nil, unavailable());
    });
}

@end

/* --- the Foundation classes that go through item providers --- */

@interface NSString (FinchItemProvider) <NSItemProviderReading, NSItemProviderWriting>
@end

@implementation NSString (FinchItemProvider)

+ (NSArray<NSString *> *)writableTypeIdentifiersForItemProvider
{
    return @[ @"public.utf8-plain-text" ];
}

+ (NSArray<NSString *> *)readableTypeIdentifiersForItemProvider
{
    return @[ @"public.utf8-plain-text", @"public.utf16-external-plain-text", @"public.utf16-plain-text", @"public.plain-text", @"public.url" ];
}

- (NSProgress *)loadDataWithTypeIdentifier:(NSString *)typeIdentifier
          forItemProviderCompletionHandler:(void (^)(NSData *, NSError *))completionHandler
{
    NSStringEncoding encoding = [typeIdentifier isEqualToString:@"public.utf16-plain-text"]            ? NSUTF16LittleEndianStringEncoding
                                : [typeIdentifier isEqualToString:@"public.utf16-external-plain-text"] ? NSUTF16StringEncoding
                                                                                                       : NSUTF8StringEncoding;
    completionHandler([self dataUsingEncoding:encoding], nil);
    return nil;
}

+ (instancetype)objectWithItemProviderData:(NSData *)data typeIdentifier:(NSString *)typeIdentifier error:(NSError **)outError
{
    NSStringEncoding encoding = [typeIdentifier isEqualToString:@"public.utf16-plain-text"]            ? NSUTF16LittleEndianStringEncoding
                                : [typeIdentifier isEqualToString:@"public.utf16-external-plain-text"] ? NSUTF16StringEncoding
                                                                                                       : NSUTF8StringEncoding;
    NSString *s = [[[self alloc] initWithData:data encoding:encoding] autorelease];
    if (!s && outError)
        *outError = [NSError errorWithDomain:NSItemProviderErrorDomain code:NSItemProviderUnexpectedValueClassError userInfo:nil];
    return s;
}

@end

@interface NSURL (FinchItemProvider) <NSItemProviderReading, NSItemProviderWriting>
@end

@implementation NSURL (FinchItemProvider)

+ (NSArray<NSString *> *)writableTypeIdentifiersForItemProvider
{
    return @[ @"public.url" ];
}

+ (NSArray<NSString *> *)readableTypeIdentifiersForItemProvider
{
    return @[ @"public.url" ];
}

- (NSProgress *)loadDataWithTypeIdentifier:(NSString *)typeIdentifier
          forItemProviderCompletionHandler:(void (^)(NSData *, NSError *))completionHandler
{
    completionHandler([self.absoluteString dataUsingEncoding:NSUTF8StringEncoding], nil);
    return nil;
}

+ (instancetype)objectWithItemProviderData:(NSData *)data typeIdentifier:(NSString *)typeIdentifier error:(NSError **)outError
{
    NSString *s = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    NSURL *url = s ? [self URLWithString:s] : nil;
    if (!url && outError)
        *outError = [NSError errorWithDomain:NSItemProviderErrorDomain code:NSItemProviderUnexpectedValueClassError userInfo:nil];
    return url;
}

@end
