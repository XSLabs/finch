/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSFileWrapper (docs/design/FOUNDATION.md), against the SDK's
 * <Foundation/NSFileWrapper.h>: regular files, directories and symbolic
 * links, read from and written to disk. A directory's children are keyed
 * by preferred filename; a clashing name gets Apple's "1__#$!@%!#__name"
 * key, which is also the name written to disk, as Apple's is.
 *
 * serializedRepresentation is Apple's flat RTFD format (the pasteboard's
 * RTFD), little-endian throughout: "rtfd", 0, then a directory node. A
 * directory node is 3 and a table: a count, the names (each a length and
 * UTF-8), the entries' lengths, then the entries. A file entry is 1, a length
 * and the contents (a link's are its destination path); each directory's "."
 * file holds a table of 16-byte attributes by name (a file's modification
 * time in Unix seconds, or 0; permissions; flags: 1 a directory, 4 a link, 2
 * the lone file; then 1 for the lone file). A lone
 * file or link is the entry "..", with its preferred name in
 * "__@PreferredName@__" and "__@UTF8PreferredName@__".
 */
#import <Foundation/Foundation.h>
#include <errno.h>
#include <stdio.h>

#include "Foundation_Finch.h"

typedef enum { KIND_FILE, KIND_DIRECTORY, KIND_LINK } Kind;

@interface NSFileWrapper () {
    Kind _kind;
    NSData *_contents;
    NSMutableDictionary *_children;
    NSURL *_destination;
    NSString *_preferred, *_filename;
    NSDictionary *_attributes;
    NSURL *_readFrom;
    NSFileWrapper *_parent;     /* not retained */
}
@end

@implementation NSFileWrapper

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)initRegularFileWithContents:(NSData *)contents
{
    if ((self = [super init])) {
        _kind = KIND_FILE;
        _contents = [contents copy];
        _attributes = [@{NSFileType:NSFileTypeRegular, NSFilePosixPermissions:@0666} copy];
    }
    return self;
}

- (instancetype)initDirectoryWithFileWrappers:(NSDictionary<NSString *, NSFileWrapper *> *)childrenByPreferredName
{
    if ((self = [super init])) {
        _kind = KIND_DIRECTORY;
        _children = [NSMutableDictionary new];
        _attributes = [@{NSFileType:NSFileTypeDirectory, NSFilePosixPermissions:@0777} copy];
        for (NSString *name in childrenByPreferredName) {
            NSFileWrapper *w = [childrenByPreferredName objectForKey:name];
            if (![w preferredFilename]) [w setPreferredFilename:name];
            [_children setObject:w forKey:name];
            w->_parent = self;
        }
    }
    return self;
}

- (instancetype)initSymbolicLinkWithDestinationURL:(NSURL *)url
{
    if ((self = [super init])) {
        _kind = KIND_LINK;
        _destination = [url copy];
        _attributes = [@{NSFileType:NSFileTypeSymbolicLink, NSFilePosixPermissions:@0666} copy];
    }
    return self;
}

- (instancetype)init { return [self initDirectoryWithFileWrappers:@{}]; }

- (BOOL)loadFromURL:(NSURL *)url error:(NSError **)outError
{
    NSString *path = [url path];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:outError];
    if (!attrs) return NO;
    [_attributes release];
    _attributes = [attrs copy];
    NSString *type = [attrs fileType];
    [_contents release];
    _contents = nil;
    [_children release];
    _children = nil;
    [_destination release];
    _destination = nil;
    if ([type isEqualToString:NSFileTypeSymbolicLink]) {
        _kind = KIND_LINK;
        NSString *dest = [fm destinationOfSymbolicLinkAtPath:path error:outError];
        if (!dest) return NO;
        _destination = [[NSURL fileURLWithPath:dest] copy];
        if (![dest hasPrefix:@"/"]) {
            [_destination release];
            _destination = [[NSURL URLWithString:[dest stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]]] copy];
        }
    } else if ([type isEqualToString:NSFileTypeDirectory]) {
        _kind = KIND_DIRECTORY;
        _children = [NSMutableDictionary new];
        NSArray *names = [fm contentsOfDirectoryAtPath:path error:outError];
        if (!names) return NO;
        for (NSString *name in names) {
            NSFileWrapper *child = [[[NSFileWrapper alloc] initWithURL:[url URLByAppendingPathComponent:name] options:0 error:outError] autorelease];
            if (!child) return NO;
            [_children setObject:child forKey:name];
            child->_parent = self;
        }
    } else {
        _kind = KIND_FILE;
        _contents = [[NSData alloc] initWithContentsOfURL:url options:0 error:outError];
        if (!_contents) return NO;
    }
    [_filename release];
    _filename = [[url lastPathComponent] copy];
    if (!_preferred) _preferred = [_filename copy];
    [_readFrom release];
    _readFrom = [url copy];
    return YES;
}

- (instancetype)initWithURL:(NSURL *)url options:(NSFileWrapperReadingOptions)options error:(NSError **)outError
{
    if ((self = [super init])) {
        /* Without following a final symbolic link. */
        if (![[NSFileManager defaultManager] attributesOfItemAtPath:[url path] error:NULL]) {
            if (outError) {
                NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObject:[url path] ?: @"" forKey:NSFilePathErrorKey];
                if (url)
                    info[NSURLErrorKey] = url;
                *outError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError userInfo:info];
            }
            [self release];
            return nil;
        }
        if (![self loadFromURL:url error:outError]) {
            [self release];
            return nil;
        }
    }
    return self;
}

enum { RTFD_FILE = 1, RTFD_DIRECTORY = 3, RTFD_IS_DIRECTORY = 1, RTFD_IS_LONE = 2, RTFD_IS_LINK = 4 };

static void
rtfd_put(NSMutableData *out, uint32_t value)
{
    uint32_t le = NSSwapHostIntToLittle(value);
    [out appendBytes:&le length:4];
}

/* (`names` gives the order; a directory's follows its dictionary, which needn't match
   Apple's byte for byte, as readers look entries up by name) */
static void
rtfd_ordered_table(NSMutableData *out, NSDictionary *entries, NSArray *names)
{
    rtfd_put(out, (uint32_t)[names count]);
    for (NSString *name in names) {
        NSData *utf8 = [name dataUsingEncoding:NSUTF8StringEncoding];
        rtfd_put(out, (uint32_t)[utf8 length]);
        [out appendData:utf8];
    }
    for (NSString *name in names)
        rtfd_put(out, (uint32_t)[[entries objectForKey:name] length]);
    for (NSString *name in names)
        [out appendData:[entries objectForKey:name]];
}

static void
rtfd_table(NSMutableData *out, NSDictionary *entries)
{
    rtfd_ordered_table(out, entries, [entries allKeys]);
}

static NSData *
rtfd_file(NSData *contents)
{
    NSMutableData *out = [NSMutableData data];
    rtfd_put(out, RTFD_FILE);
    rtfd_put(out, (uint32_t)[contents length]);
    if (contents)
        [out appendData:contents];
    return out;
}

static NSData *
rtfd_attributes(NSFileWrapper *w, uint32_t flags, uint32_t lone)
{
    NSMutableData *out = [NSMutableData data];
    NSNumber *permissions = [[w fileAttributes] objectForKey:NSFilePosixPermissions];
    NSDate *modified = [[w fileAttributes] objectForKey:NSFileModificationDate];
    /* (Apple's: a file in a directory has a time, now if it has none of its own) */
    rtfd_put(out, lone || [w isDirectory] || [w isSymbolicLink] ? 0 : (uint32_t)[modified ?: [NSDate date] timeIntervalSince1970]);
    rtfd_put(out, permissions ? (uint32_t)[permissions unsignedIntValue] : [w isDirectory] ? 0777 : 0666);
    rtfd_put(out, flags);
    rtfd_put(out, lone);
    return out;
}

static NSData *
rtfd_link_contents(NSFileWrapper *w)
{
    return [[w symbolicLinkDestination] dataUsingEncoding:NSUTF8StringEncoding];
}

static NSData *
rtfd_directory(NSFileWrapper *w)
{
    NSMutableDictionary *entries = [NSMutableDictionary dictionary], *attributes = [NSMutableDictionary dictionary];
    NSDictionary *children = [w fileWrappers];
    for (NSString *name in children) {
        NSFileWrapper *child = [children objectForKey:name];
        uint32_t flags = 0;
        if ([child isDirectory]) {
            [entries setObject:rtfd_directory(child) forKey:name];
            flags = RTFD_IS_DIRECTORY;
        } else if ([child isSymbolicLink]) {
            [entries setObject:rtfd_file(rtfd_link_contents(child)) forKey:name];
            flags = RTFD_IS_LINK;
        } else {
            [entries setObject:rtfd_file([child regularFileContents]) forKey:name];
        }
        [attributes setObject:rtfd_attributes(child, flags, 0) forKey:name];
    }
    if ([attributes count]) {
        NSMutableData *table = [NSMutableData data];
        rtfd_table(table, attributes);
        [entries setObject:rtfd_file(table) forKey:@"."];
    }
    NSMutableData *out = [NSMutableData data];
    rtfd_put(out, RTFD_DIRECTORY);
    rtfd_table(out, entries);
    return out;
}

typedef struct {
    const uint8_t *bytes;
    NSUInteger length, at;
    BOOL bad;
} RTFDReader;

static uint32_t
rtfd_get(RTFDReader *r)
{
    if (r->bad || r->at + 4 > r->length) {
        r->bad = YES;
        return 0;
    }
    uint32_t le;
    memcpy(&le, r->bytes + r->at, 4);
    r->at += 4;
    return NSSwapLittleIntToHost(le);
}

/* A table's entries by name, each the data of its entry. */
static NSDictionary *
rtfd_read_table(RTFDReader *r)
{
    uint32_t count = rtfd_get(r);
    if (r->bad || count > r->length)
        return nil;
    NSMutableArray *names = [NSMutableArray array];
    for (uint32_t i = 0; i < count && !r->bad; i++) {
        uint32_t n = rtfd_get(r);
        if (r->bad || n > r->length - r->at)
            return nil;
        NSString *name = [[[NSString alloc] initWithBytes:r->bytes + r->at length:n encoding:NSUTF8StringEncoding] autorelease];
        r->at += n;
        if (!name)
            return nil;
        [names addObject:name];
    }
    NSUInteger lengths[count ? count : 1];
    for (uint32_t i = 0; i < count; i++)
        lengths[i] = rtfd_get(r);
    NSMutableDictionary *entries = [NSMutableDictionary dictionary];
    for (uint32_t i = 0; i < count && !r->bad; i++) {
        if (lengths[i] > r->length - r->at)
            return nil;
        [entries setObject:[NSData dataWithBytes:r->bytes + r->at length:lengths[i]] forKey:[names objectAtIndex:i]];
        r->at += lengths[i];
    }
    return r->bad ? nil : entries;
}

/* An entry: a directory node's table, or a file's contents. */
static id
rtfd_read_entry(NSData *data, BOOL *isDirectory)
{
    RTFDReader r = { [data bytes], [data length], 0, NO };
    uint32_t type = rtfd_get(&r);
    *isDirectory = type == RTFD_DIRECTORY;
    if (type == RTFD_DIRECTORY)
        return rtfd_read_table(&r);
    uint32_t n = rtfd_get(&r);
    if (r.bad || type != RTFD_FILE || n > r.length - r.at)
        return nil;
    return [data subdataWithRange:NSMakeRange(r.at, n)];
}

static NSDictionary *
rtfd_read_attributes(NSDictionary *entries)
{
    BOOL dir;
    NSData *table = rtfd_read_entry([entries objectForKey:@"."], &dir);
    if (![table isKindOfClass:[NSData class]])
        return nil;
    RTFDReader r = { [table bytes], [table length], 0, NO };
    return rtfd_read_table(&r);
}

static uint32_t
rtfd_word(NSData *attributes, NSUInteger index)
{
    uint32_t le = 0;
    if ([attributes length] >= 4 * (index + 1))
        memcpy(&le, (const uint8_t *)[attributes bytes] + 4 * index, 4);
    return NSSwapLittleIntToHost(le);
}

static NSFileWrapper *
rtfd_wrapper(id entry, BOOL isDirectory, NSData *attributes)
{
    NSFileWrapper *w;
    if (isDirectory) {
        NSDictionary *table = entry, *all = rtfd_read_attributes(table);
        NSMutableDictionary *children = [NSMutableDictionary dictionary];
        for (NSString *name in table) {
            if ([name isEqualToString:@"."] || [name hasPrefix:@"__@"])
                continue;
            BOOL childIsDirectory;
            id childEntry = rtfd_read_entry([table objectForKey:name], &childIsDirectory);
            NSFileWrapper *child = childEntry ? rtfd_wrapper(childEntry, childIsDirectory, [all objectForKey:name]) : nil;
            if (!child)
                return nil;
            [child setPreferredFilename:name];
            [children setObject:child forKey:name];
        }
        w = [[[NSFileWrapper alloc] initDirectoryWithFileWrappers:children] autorelease];
    } else if (rtfd_word(attributes, 2) & RTFD_IS_LINK) {
        NSString *path = [[[NSString alloc] initWithData:entry encoding:NSUTF8StringEncoding] autorelease];
        w = [[[NSFileWrapper alloc] initSymbolicLinkWithDestinationURL:[NSURL fileURLWithPath:path ?: @""]] autorelease];
    } else {
        w = [[[NSFileWrapper alloc] initRegularFileWithContents:entry] autorelease];
    }
    if ([attributes length] >= 8) {
        NSMutableDictionary *a = [NSMutableDictionary dictionaryWithDictionary:[w fileAttributes]];
        [a setObject:[NSNumber numberWithUnsignedInt:rtfd_word(attributes, 1)] forKey:NSFilePosixPermissions];
        if (rtfd_word(attributes, 0))
            [a setObject:[NSDate dateWithTimeIntervalSince1970:rtfd_word(attributes, 0)] forKey:NSFileModificationDate];
        [w setFileAttributes:a];
    }
    return w;
}

- (instancetype)initWithSerializedRepresentation:(NSData *)serializeRepresentation
{
    [self release];
    if ([serializeRepresentation length] < 8 || memcmp([serializeRepresentation bytes], "rtfd", 4) != 0)
        return nil;
    BOOL isDirectory;
    id top = rtfd_read_entry([serializeRepresentation subdataWithRange:NSMakeRange(8, [serializeRepresentation length] - 8)], &isDirectory);
    if (!isDirectory || ![top isKindOfClass:[NSDictionary class]])
        return nil;
    NSData *lone = [top objectForKey:@".."];
    if (!lone)
        return [rtfd_wrapper(top, YES, nil) retain];
    BOOL loneIsDirectory;
    id contents = rtfd_read_entry(lone, &loneIsDirectory);
    NSFileWrapper *w = contents ? rtfd_wrapper(contents, loneIsDirectory, [rtfd_read_attributes(top) objectForKey:@".."]) : nil;
    BOOL nameIsDirectory;
    NSData *name = rtfd_read_entry([top objectForKey:@"__@UTF8PreferredName@__"] ?: [top objectForKey:@"__@PreferredName@__"], &nameIsDirectory);
    if (w && [name isKindOfClass:[NSData class]])
        [w setPreferredFilename:[[[NSString alloc] initWithData:name encoding:NSUTF8StringEncoding] autorelease]];
    return [w retain];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super init])) {
        _kind = (Kind)[coder decodeIntForKey:@"NSFileWrapperKind"];
        _contents = [[coder decodeObjectOfClass:[NSData class] forKey:@"NSFileWrapperContents"] copy];
        _destination = [[coder decodeObjectOfClass:[NSURL class] forKey:@"NSFileWrapperLink"] copy];
        _preferred = [[coder decodeObjectOfClass:[NSString class] forKey:@"NSFileWrapperPreferredName"] copy];
        _filename = [[coder decodeObjectOfClass:[NSString class] forKey:@"NSFileWrapperFilename"] copy];
        _attributes = [[NSDictionary alloc] init];
        NSDictionary *children = [coder decodeObjectOfClasses:[NSSet setWithObjects:[NSDictionary class], [NSString class], [NSFileWrapper class], nil]
                                                       forKey:@"NSFileWrapperChildren"];
        if (_kind == KIND_DIRECTORY) {
            _children = [children mutableCopy];
            for (NSFileWrapper *w in [_children allValues]) w->_parent = self;
            if (!_children) _children = [NSMutableDictionary new];
        }
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeInt:_kind forKey:@"NSFileWrapperKind"];
    if (_contents) [coder encodeObject:_contents forKey:@"NSFileWrapperContents"];
    if (_destination) [coder encodeObject:_destination forKey:@"NSFileWrapperLink"];
    if (_preferred) [coder encodeObject:_preferred forKey:@"NSFileWrapperPreferredName"];
    if (_filename) [coder encodeObject:_filename forKey:@"NSFileWrapperFilename"];
    if (_children) [coder encodeObject:_children forKey:@"NSFileWrapperChildren"];
}

- (void)dealloc
{
    for (NSFileWrapper *w in [_children allValues]) w->_parent = nil;
    [_contents release];
    [_children release];
    [_destination release];
    [_preferred release];
    [_filename release];
    [_attributes release];
    [_readFrom release];
    [super dealloc];
}

- (BOOL)isDirectory { return _kind == KIND_DIRECTORY; }
- (BOOL)isRegularFile { return _kind == KIND_FILE; }
- (BOOL)isSymbolicLink { return _kind == KIND_LINK; }

- (NSString *)preferredFilename { return _preferred; }
- (void)setPreferredFilename:(NSString *)name { [_preferred release]; _preferred = [name copy]; }
- (NSString *)filename { return _filename; }
- (void)setFilename:(NSString *)name { [_filename release]; _filename = [name copy]; }
- (NSDictionary *)fileAttributes { return _attributes; }
- (void)setFileAttributes:(NSDictionary *)attrs { [_attributes release]; _attributes = [attrs copy]; }

- (void)requireKind:(Kind)kind cmd:(SEL)cmd
{
    if (_kind != kind)
        FinchRaise(NSInternalInconsistencyException, "-[NSFileWrapper %s] tried to %s on a file wrapper that isn't a %s.", sel_getName(cmd),
            kind == KIND_DIRECTORY ? "get the children" : kind == KIND_FILE ? "get the contents" : "get the destination",
            kind == KIND_DIRECTORY ? "directory" : kind == KIND_FILE ? "regular file" : "symbolic link");
}

- (NSData *)regularFileContents { [self requireKind:KIND_FILE cmd:_cmd]; return _contents; }
- (NSURL *)symbolicLinkDestinationURL { [self requireKind:KIND_LINK cmd:_cmd]; return _destination; }
- (NSDictionary<NSString *, NSFileWrapper *> *)fileWrappers { [self requireKind:KIND_DIRECTORY cmd:_cmd]; return [[_children copy] autorelease]; }

/* A free key for `name`: the name, else Apple's numbered form. */
- (NSString *)keyFor:(NSString *)name
{
    if (![_children objectForKey:name]) return name;
    for (NSUInteger i = 1;; i++) {
        NSString *k = [NSString stringWithFormat:@"%lu__#$!@%%!#__%@", (unsigned long)i, name];
        if (![_children objectForKey:k]) return k;
    }
}

- (NSString *)addFileWrapper:(NSFileWrapper *)child
{
    [self requireKind:KIND_DIRECTORY cmd:_cmd];
    NSString *name = [child preferredFilename];
    if (!name) FinchRaise(NSInvalidArgumentException, "-[NSFileWrapper addFileWrapper:] called with a file wrapper that has no preferred filename");
    NSString *key = [self keyFor:name];
    [_children setObject:child forKey:key];
    child->_parent = self;
    return key;
}

- (NSString *)addRegularFileWithContents:(NSData *)data preferredFilename:(NSString *)fileName
{
    NSFileWrapper *w = [[[NSFileWrapper alloc] initRegularFileWithContents:data] autorelease];
    w.preferredFilename = fileName;
    return [self addFileWrapper:w];
}

- (void)removeFileWrapper:(NSFileWrapper *)child
{
    [self requireKind:KIND_DIRECTORY cmd:_cmd];
    NSString *key = [self keyForFileWrapper:child];
    if (key) {
        child->_parent = nil;
        [_children removeObjectForKey:key];
    }
}

- (NSString *)keyForFileWrapper:(NSFileWrapper *)child
{
    for (NSString *k in _children) if ([_children objectForKey:k] == child) return k;
    return nil;
}

- (BOOL)writeToURL:(NSURL *)url options:(NSFileWrapperWritingOptions)options originalContentsURL:(NSURL *)originalContentsURL error:(NSError **)outError
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *path = [url path];
    BOOL isDirectory = NO, exists = [fm fileExistsAtPath:path isDirectory:&isDirectory];
    switch (_kind) {
    case KIND_FILE:
        /* A file takes the place of a folder, as Apple's does. */
        if (exists && isDirectory) [fm removeItemAtPath:path error:NULL];
        if (![_contents writeToURL:url options:(options & NSFileWrapperWritingAtomic) ? NSDataWritingAtomic : 0 error:outError]) return NO;
        break;
    case KIND_LINK:
        [fm removeItemAtPath:path error:NULL];
        /* A relative destination stays relative, as Apple's does. */
        if (![fm createSymbolicLinkAtPath:path withDestinationPath:[_destination baseURL] || ![_destination isFileURL] ? [_destination relativePath] : [_destination path]
                                    error:outError])
            return NO;
        break;
    case KIND_DIRECTORY:
        /* As Apple's: written atomically, the folder replaces whatever is there,
           holding just its children (made beside it, then swapped in; in place when
           the folder can't have a sibling, in a sandboxed app's container say);
           otherwise there must be nothing there. */
        if (exists && !(options & NSFileWrapperWritingAtomic)) {
            if (outError)
                *outError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteFileExistsError
                                            userInfo:@{ NSFilePathErrorKey : path }];
            return NO;
        }
        if (options & NSFileWrapperWritingAtomic) {
            NSString *temporary = [[path stringByDeletingLastPathComponent] stringByAppendingPathComponent:
                [NSString stringWithFormat:@".%@.%@", [path lastPathComponent], [[NSUUID UUID] UUIDString]]];
            if ([fm createDirectoryAtPath:temporary withIntermediateDirectories:YES attributes:nil error:NULL]) {
                NSURL *temporaryURL = [NSURL fileURLWithPath:temporary isDirectory:YES];
                for (NSString *key in _children) {
                    NSFileWrapper *child = [_children objectForKey:key];
                    if (![child writeToURL:[temporaryURL URLByAppendingPathComponent:key] options:options
                            originalContentsURL:nil error:outError]) {
                        [fm removeItemAtPath:temporary error:NULL];
                        return NO;
                    }
                }
                if (exists) [fm removeItemAtPath:path error:NULL];
                if (rename([temporary fileSystemRepresentation], [path fileSystemRepresentation]) != 0) {
                    int e = errno;
                    [fm removeItemAtPath:temporary error:NULL];
                    if (outError)
                        *outError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnknownError
                                                    userInfo:@{ NSFilePathErrorKey : path,
                                                                NSUnderlyingErrorKey : [NSError errorWithDomain:NSPOSIXErrorDomain code:e userInfo:nil] }];
                    return NO;
                }
                break;
            }
            if (exists) [fm removeItemAtPath:path error:NULL];
        }
        if (![fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:outError]) return NO;
        for (NSString *key in _children) {
            NSFileWrapper *child = [_children objectForKey:key];
            if (![child writeToURL:[url URLByAppendingPathComponent:key] options:options
                    originalContentsURL:nil error:outError])
                return NO;
        }
        break;
    }
    if (options & NSFileWrapperWritingWithNameUpdating) [self setFilename:[url lastPathComponent]];
    return YES;
}

- (BOOL)readFromURL:(NSURL *)url options:(NSFileWrapperReadingOptions)options error:(NSError **)outError { return [self loadFromURL:url error:outError]; }

- (BOOL)matchesContentsOfURL:(NSURL *)url
{
    NSFileWrapper *other = [[[NSFileWrapper alloc] initWithURL:url options:0 error:NULL] autorelease];
    if (!other || other->_kind != _kind) return NO;
    switch (_kind) {
    case KIND_FILE: return [_contents isEqualToData:other->_contents];
    case KIND_LINK: return [[_destination relativeString] isEqualToString:[other->_destination relativeString]];
    case KIND_DIRECTORY:
        if (![[NSSet setWithArray:[_children allKeys]] isEqualToSet:[NSSet setWithArray:[other->_children allKeys]]]) return NO;
        for (NSString *k in _children)
            if (![[_children objectForKey:k] matchesContentsOfURL:[url URLByAppendingPathComponent:k]]) return NO;
        return YES;
    }
    return NO;
}

- (BOOL)needsToBeUpdatedFromURL:(NSURL *)url { return ![self matchesContentsOfURL:url]; }

- (instancetype)initWithPath:(NSString *)path
{
    return [self initWithURL:[NSURL fileURLWithPath:path] options:0 error:NULL];
}

- (instancetype)initSymbolicLinkWithDestination:(NSString *)path
{
    if (![path length])
        return nil;
    NSURL *destination = [NSURL fileURLWithPath:path];
    self = [self initSymbolicLinkWithDestinationURL:destination];
    if (self)
        self.preferredFilename = [path lastPathComponent];
    return self;
}

- (NSString *)addFileWithPath:(NSString *)path
{
    NSFileWrapper *child = [[[NSFileWrapper alloc] initWithPath:path] autorelease];
    return child ? [self addFileWrapper:child] : nil;
}

- (NSString *)addSymbolicLinkWithDestination:(NSString *)path preferredFilename:(NSString *)filename
{
    NSFileWrapper *child = [[[NSFileWrapper alloc] initSymbolicLinkWithDestination:path] autorelease];
    [child setPreferredFilename:filename];
    return [self addFileWrapper:child];
}

- (BOOL)needsToBeUpdatedFromPath:(NSString *)path
{
    return ![self matchesContentsOfURL:[NSURL fileURLWithPath:path]];
}

- (BOOL)updateFromPath:(NSString *)path
{
    return [self readFromURL:[NSURL fileURLWithPath:path] options:0 error:NULL];
}

- (BOOL)writeToFile:(NSString *)path atomically:(BOOL)atomic updateFilenames:(BOOL)updateFilenames
{
    NSFileWrapperWritingOptions options = atomic ? NSFileWrapperWritingAtomic : 0;
    if (updateFilenames)
        options |= NSFileWrapperWritingWithNameUpdating;
    return [self writeToURL:[NSURL fileURLWithPath:path] options:options originalContentsURL:nil error:NULL];
}

- (NSString *)symbolicLinkDestination
{
    [self requireKind:KIND_LINK cmd:_cmd];
    if ([_destination isFileURL])
        return [_destination relativePath];
    return [[_destination relativeString] stringByRemovingPercentEncoding] ?: [_destination relativeString];
}

- (NSData *)serializedRepresentation
{
    NSMutableData *out = [NSMutableData dataWithBytes:"rtfd" length:4];
    rtfd_put(out, 0);
    if (_kind == KIND_DIRECTORY) {
        [out appendData:rtfd_directory(self)];
        return out;
    }
    NSMutableDictionary *entries = [NSMutableDictionary dictionary];
    [entries setObject:rtfd_file(_kind == KIND_LINK ? rtfd_link_contents(self) : [self regularFileContents]) forKey:@".."];
    if (_preferred) {
        NSData *name = rtfd_file([_preferred dataUsingEncoding:NSUTF8StringEncoding]);
        [entries setObject:name forKey:@"__@PreferredName@__"];
        [entries setObject:name forKey:@"__@UTF8PreferredName@__"];
    }
    NSMutableData *table = [NSMutableData data];
    rtfd_table(table, [NSDictionary dictionaryWithObject:rtfd_attributes(self, RTFD_IS_LONE | (_kind == KIND_LINK ? RTFD_IS_LINK : 0), 1) forKey:@".."]);
    [entries setObject:rtfd_file(table) forKey:@"."];
    rtfd_put(out, RTFD_DIRECTORY);
    rtfd_ordered_table(out, entries, _preferred ? @[ @"..", @"__@PreferredName@__", @"__@UTF8PreferredName@__", @"." ] : @[ @".", @".." ]);
    return out;
}

- (NSString *)description
{
    const char *kind = _kind == KIND_DIRECTORY ? "directory" : _kind == KIND_FILE ? "regular file" : "symbolic link";
    return [NSString stringWithFormat:@"<%s: %p> (%s %@)", object_getClassName(self), self, kind, _preferred ? _preferred : @""];
}

@end
