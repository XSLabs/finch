/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSPasteboard, on CoreFoundation's pasteboards: finch-pboardd keeps each user's,
 * shared by their processes (copying in one, pasting in another), or the process keeps
 * its own where the server isn't running. Each named pasteboard is a list of items,
 * each a map from type to data; strings and property lists are stored as data, as
 * Apple's are. Data can be promised (an owner, an item's data provider, an object
 * written with promised types) and is asked for when read. Plain text written as
 * NSPasteboardTypeString also reads back under the old NSStringPboardType, as on macOS.
 */
#import "AppKit_Finch.h"

@interface NSPasteboardItem (FinchPasteboardIdentity)
- (uint64_t)_finchItemID;
- (NSPasteboard *)_finchPasteboard;
@end

NSPasteboardName NSPasteboardNameGeneral = @"Apple CFPasteboard general";
NSPasteboardName NSPasteboardNameFont = @"Apple CFPasteboard font";
NSPasteboardName NSPasteboardNameRuler = @"Apple CFPasteboard ruler";
NSPasteboardName NSPasteboardNameFind = @"Apple CFPasteboard find";
NSPasteboardName NSPasteboardNameDrag = @"Apple CFPasteboard drag";
/* the names' old spellings */
NSPasteboardName NSGeneralPboard = @"Apple CFPasteboard general";
NSPasteboardName NSFontPboard = @"Apple CFPasteboard font";
NSPasteboardName NSRulerPboard = @"Apple CFPasteboard ruler";
NSPasteboardName NSFindPboard = @"Apple CFPasteboard find";
NSPasteboardName NSDragPboard = @"Apple CFPasteboard drag";

NSPasteboardType const NSPasteboardTypeString = @"public.utf8-plain-text";
NSPasteboardType const NSPasteboardTypePDF = @"com.adobe.pdf";
NSPasteboardType const NSPasteboardTypeTIFF = @"public.tiff";
NSPasteboardType const NSPasteboardTypePNG = @"public.png";
NSPasteboardType const NSPasteboardTypeRTF = @"public.rtf";
NSPasteboardType const NSPasteboardTypeRTFD = @"com.apple.flat-rtfd";
NSPasteboardType const NSPasteboardTypeHTML = @"public.html";
NSPasteboardType const NSPasteboardTypeTabularText = @"public.utf8-tab-separated-values-text";
NSPasteboardType const NSPasteboardTypeFont = @"com.apple.cocoa.pasteboard.character-formatting";
NSPasteboardType const NSPasteboardTypeRuler = @"com.apple.cocoa.pasteboard.paragraph-formatting";
NSPasteboardType const NSPasteboardTypeColor = @"com.apple.cocoa.pasteboard.color";
NSPasteboardType const NSPasteboardTypeSound = @"com.apple.cocoa.pasteboard.sound";
NSPasteboardType const NSPasteboardTypeMultipleTextSelection = @"com.apple.cocoa.pasteboard.multiple-text-selection";
NSPasteboardType const NSPasteboardTypeTextFinderOptions = @"com.apple.cocoa.pasteboard.find-panel-search-options";
NSPasteboardType const NSPasteboardTypeFindPanelSearchOptions = @"com.apple.cocoa.pasteboard.find-panel-search-options";
NSPasteboardType const NSPasteboardTypeURL = @"public.url";
NSPasteboardType const NSPasteboardTypeFileURL = @"public.file-url";

NSPasteboardType NSStringPboardType = @"NSStringPboardType";
NSPasteboardType NSFilenamesPboardType = @"NSFilenamesPboardType";
NSPasteboardType NSTIFFPboardType = @"NeXT TIFF v4.0 pasteboard type";
NSPasteboardType NSRTFPboardType = @"NeXT Rich Text Format v1.0 pasteboard type";
NSPasteboardType NSTabularTextPboardType = @"NeXT tabular text pasteboard type";
NSPasteboardType NSFontPboardType = @"NeXT font pasteboard type";
NSPasteboardType NSRulerPboardType = @"NeXT ruler pasteboard type";
NSPasteboardType NSColorPboardType = @"NSColor pasteboard type";
NSPasteboardType NSRTFDPboardType = @"NeXT RTFD pasteboard type";
NSPasteboardType NSHTMLPboardType = @"Apple HTML pasteboard type";
NSPasteboardType NSURLPboardType = @"Apple URL pasteboard type";
NSPasteboardType NSPDFPboardType = @"Apple PDF pasteboard type";
NSPasteboardType NSVCardPboardType = @"Apple VCard pasteboard type";
NSPasteboardType NSFilesPromisePboardType = @"Apple files promise pasteboard type";
NSPasteboardType NSMultipleTextSelectionPboardType = @"Apple multiple text selection pasteboard type";
NSPasteboardType NSPostScriptPboardType = @"NeXT Encapsulated PostScript v1.2 pasteboard type";
NSPasteboardType NSPICTPboardType = @"Apple PICT pasteboard type";
NSPasteboardType NSInkTextPboardType = @"Apple InkText pasteboard type";
NSPasteboardType NSFileContentsPboardType = @"NXFileContentsPboardType";
NSPasteboardType const NSSoundPboardType = @"NSSoundPboardType";
NSPasteboardType NSFindPanelSearchOptionsPboardType = @"NSFindPanel search options pasteboard type";

NSPasteboardReadingOptionKey const NSPasteboardURLReadingFileURLsOnlyKey = @"NSPasteboardURLReadingFileURLsOnlyKey";
NSPasteboardReadingOptionKey const NSPasteboardURLReadingContentsConformToTypesKey =
    @"NSPasteboardURLReadingContentsConformToTypesKey";

/* The names a pasteboard also lists each type under, as Apple's does: the old pasteboard
   type names, Carbon's flavor names and their dynamic identifiers. */
static NSArray<NSString *> *
translations(NSString *type)
{
    static NSDictionary<NSString *, NSArray *> *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      NSString *urlDyn = @"dyn.ah62d4rv4gu8yc6durvwwaznwmuuha2pxsvw0e55bsmwca7d3sbwu";
      table = [@{
          NSPasteboardTypeString : @[ NSStringPboardType ],
          NSPasteboardTypePDF : @[ NSPDFPboardType ],
          NSPasteboardTypeTIFF : @[ NSTIFFPboardType ],
          /* (as Apple's: a PNG is offered as TIFF too, converted when read) */
          NSPasteboardTypePNG : @[ @"Apple PNG pasteboard type", NSPasteboardTypeTIFF, NSTIFFPboardType ],
          NSPasteboardTypeRTF : @[ NSRTFPboardType ],
          NSPasteboardTypeRTFD : @[ NSRTFDPboardType ],
          NSPasteboardTypeHTML : @[ NSHTMLPboardType ],
          NSPasteboardTypeTabularText : @[ NSTabularTextPboardType ],
          NSPasteboardTypeFont : @[ NSFontPboardType ],
          NSPasteboardTypeRuler : @[ NSRulerPboardType ],
          NSPasteboardTypeColor : @[ NSColorPboardType ],
          NSPasteboardTypeSound : @[ NSSoundPboardType ],
          NSPasteboardTypeMultipleTextSelection : @[ NSMultipleTextSelectionPboardType ],
          NSPasteboardTypeFindPanelSearchOptions : @[ NSFindPanelSearchOptionsPboardType ],
          NSPasteboardTypeURL : @[ @"CorePasteboardFlavorType 0x75726C20", urlDyn, NSURLPboardType ],
          NSPasteboardTypeFileURL : @[ @"CorePasteboardFlavorType 0x6675726C", @"dyn.ah62d4rv4gu8y6y4grf0gn5xbrzw1gydcr7u1e3cytf2gn",
                                       NSFilenamesPboardType, urlDyn, NSURLPboardType ],
          @"com.apple.traditional-mac-plain-text" : @[ @"CorePasteboardFlavorType 0x54455854" ],
      } retain];
    });
    return table[type] ?: @[];
}

/* A type and the old names it also goes by (drags match a view's registered types by these). */
FINCH_PRIVATE NSArray<NSString *> *
FinchPasteboardTypeNames(NSString *type)
{
    return [@[ type ] arrayByAddingObjectsFromArray:translations(type)];
}

/* The modern type an old name reads, and its data in the old form. */
static NSString *
translated_from(NSString *name, NSArray<NSString *> *available)
{
    for (NSString *t in available)
        if ([translations(t) containsObject:name])
            return t;
    return nil;
}

static NSData *
data_in_old_form(NSData *d, NSString *modern, NSString *name)
{
    if (!d)
        return nil;
    if ([modern isEqualToString:NSPasteboardTypePNG] && ([name isEqualToString:NSPasteboardTypeTIFF] || [name isEqualToString:NSTIFFPboardType]))
        return [[NSBitmapImageRep imageRepWithData:d] TIFFRepresentation];
    NSString *text = [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] autorelease];
    if ([name isEqualToString:NSURLPboardType] || [name hasPrefix:@"dyn.ah62d4rv4gu8yc6durvwwaznwmuuha2pxsvw0e55bsmwca7d3sbwu"])
        /* (an array of the URL and its title, as the old type held it) */
        return text ? [NSPropertyListSerialization dataWithPropertyList:@[ text, @"" ] format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL]
                    : nil;
    if ([name isEqualToString:NSFilenamesPboardType] || [name hasPrefix:@"dyn.ah62d4rv4gu8y6y4grf0gn5xbrzw1gydcr7u1e3cytf2gn"]) {
        NSString *path = text ? [[NSURL URLWithString:text] path] : nil;
        return path ? [NSPropertyListSerialization dataWithPropertyList:@[ path ] format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL]
                    : nil;
    }
    return d;
}

static NSString *
modern_type(NSString *type)
{
    if ([type isEqualToString:NSStringPboardType])
        return NSPasteboardTypeString;
    return type;
}

/* CoreFoundation's pasteboards (CFPasteboard_Finch.c): finch-pboardd's, shared with
   every process of the user, or the process's own where it isn't running. */
typedef struct __FinchPasteboard *FinchPasteboardRef;
typedef CFDataRef (*FinchPasteboardProvider)(CFStringRef name, CFIndex seed, uint64_t item, CFStringRef type, void *info);
extern FinchPasteboardRef _FinchPasteboardGet(CFStringRef name);
extern void _FinchPasteboardSetProvider(FinchPasteboardRef pb, FinchPasteboardProvider provider, void *info);
extern CFIndex _FinchPasteboardClear(FinchPasteboardRef pb);
extern CFIndex _FinchPasteboardGetChangeCount(FinchPasteboardRef pb);
extern Boolean _FinchPasteboardPut(FinchPasteboardRef pb, CFIndex seed, uint64_t item, CFStringRef type, CFDataRef data);
extern CFArrayRef _FinchPasteboardCopyItems(FinchPasteboardRef pb, CFIndex *seed);
extern CFDataRef _FinchPasteboardCopyData(FinchPasteboardRef pb, uint64_t item, CFStringRef type);
extern void _FinchPasteboardRelease(FinchPasteboardRef pb);

/* A value as pasteboard data: data as it is, text as UTF-8, a property list as XML. */
static NSData *
data_of(id v)
{
    if (!v)
        return nil;
    if ([v isKindOfClass:[NSData class]])
        return v;
    if ([v isKindOfClass:[NSString class]])
        return [v dataUsingEncoding:NSUTF8StringEncoding];
    return [NSPropertyListSerialization dataWithPropertyList:v format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
}

static NSString *
string_of(NSData *d)
{
    return d ? [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] autorelease] : nil;
}

static id
plist_of(NSData *d)
{
    if (!d)
        return nil;
    id plist = [NSPropertyListSerialization propertyListWithData:d options:0 format:NULL error:NULL];
    return plist ?: string_of(d);
}

@interface NSPasteboard ()
- (NSData *)_finchDataForItem:(uint64_t)item type:(NSString *)type;
@end

/* An item: one being written (its values and data providers, kept here), or one on a
   pasteboard (its types, and data read from the pasteboard when asked for). */
@implementation NSPasteboardItem {
    NSMutableDictionary<NSString *, id> *_values;  /* type -> NSData or NSString or a property list */
    NSMutableArray<NSString *> *_order;
    NSMutableDictionary<NSString *, id> *_providers;
    NSPasteboard *_board;  /* (on a pasteboard) */
    uint64_t _itemID;
    NSArray<NSString *> *_boardTypes;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _values = [[NSMutableDictionary alloc] init];
        _order = [[NSMutableArray alloc] init];
        _providers = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (instancetype)_finchInitWithPasteboard:(NSPasteboard *)board item:(uint64_t)item types:(NSArray *)types
{
    if ((self = [self init])) {
        _board = [board retain];
        _itemID = item;
        _boardTypes = [types copy];
    }
    return self;
}

- (void)dealloc
{
    [_values release];
    [_order release];
    [_providers release];
    [_board release];
    [_boardTypes release];
    [super dealloc];
}

- (uint64_t)_finchItemID { return _itemID; }
- (NSPasteboard *)_finchPasteboard { return _board; }
- (NSDictionary *)_finchProviders { return _providers; }

/* (an item lists its own types, in the order they were given: the pasteboard lists the
   old names too) */
- (NSArray<NSPasteboardType> *)types
{
    return [[(_board ? _boardTypes : _order) copy] autorelease];
}

- (NSPasteboardType)availableTypeFromArray:(NSArray<NSPasteboardType> *)types
{
    NSArray *mine = [self types];
    for (NSString *t in types)
        if ([mine containsObject:t])
            return t;
    return nil;
}

static BOOL
set_value(NSPasteboardItem *self, id value, NSString *type)
{
    if (!type || self->_board)
        return NO;
    type = modern_type(type);
    if (!value) {
        [self->_values removeObjectForKey:type];
        if (!self->_providers[type])
            [self->_order removeObject:type];
        return YES;
    }
    if (![self->_order containsObject:type])
        [self->_order addObject:type];
    self->_values[type] = value;
    return YES;
}

- (BOOL)setData:(NSData *)data forType:(NSPasteboardType)type { return set_value(self, [[data copy] autorelease], type); }
- (BOOL)setString:(NSString *)string forType:(NSPasteboardType)type { return set_value(self, [[string copy] autorelease], type); }
- (BOOL)setPropertyList:(id)propertyList forType:(NSPasteboardType)type { return set_value(self, propertyList, type); }

/* Data a provider gives when it's asked for (as the pasteboard is read). */
- (BOOL)setDataProvider:(id<NSPasteboardItemDataProvider>)dataProvider forTypes:(NSArray<NSPasteboardType> *)types
{
    if (_board || !dataProvider)
        return NO;
    for (NSString *t in types) {
        NSString *m = modern_type(t);
        _providers[m] = dataProvider;
        if (![_order containsObject:m])
            [_order addObject:m];
    }
    return YES;
}

- (NSData *)dataForType:(NSPasteboardType)type
{
    if (_board) {
        if ([_boardTypes containsObject:type])
            return [_board _finchDataForItem:_itemID type:type];
        NSString *modern = translated_from(type, _boardTypes);
        return modern ? data_in_old_form([_board _finchDataForItem:_itemID type:modern], modern, type) : nil;
    }
    return data_of(_values[modern_type(type)]);
}

- (NSString *)stringForType:(NSPasteboardType)type
{
    if (_board)
        return string_of([self dataForType:type]);
    id v = _values[modern_type(type)];
    if ([v isKindOfClass:[NSString class]])
        return v;
    if ([v isKindOfClass:[NSData class]])
        return string_of(v);
    return nil;
}

- (id)propertyListForType:(NSPasteboardType)type
{
    if (_board)
        return plist_of([self dataForType:type]);
    id v = _values[modern_type(type)];
    return [v isKindOfClass:[NSData class]] ? plist_of(v) : v;
}

- (NSArray<NSPasteboardType> *)writableTypesForPasteboard:(NSPasteboard *)pasteboard { return [self types]; }
- (id)pasteboardPropertyListForType:(NSPasteboardType)type { return [self propertyListForType:type]; }
+ (NSArray<NSPasteboardType> *)readableTypesForPasteboard:(NSPasteboard *)pasteboard { return @[]; }

@end

@implementation NSPasteboard {
    NSString *_name;
    FinchPasteboardRef _pb;
    /* what this process wrote, for promised data */
    NSInteger _seed;
    uint64_t _nextItem;
    NSMutableDictionary<NSString *, id> *_owners;      /* item 1's declared types -> their owner (or NSNull) */
    NSMutableDictionary<NSString *, NSData *> *_ownData; /* item 1's data, set by the writer */
    NSMutableDictionary<NSNumber *, id> *_written;      /* item -> the object written there */
}

static NSMutableDictionary *
pasteboards(void)
{
    static NSMutableDictionary *all;
    if (!all)
        all = [[NSMutableDictionary alloc] init];
    return all;
}

static CFDataRef provide(CFStringRef name, CFIndex seed, uint64_t item, CFStringRef type, void *info);

+ (NSPasteboard *)generalPasteboard
{
    return [self pasteboardWithName:NSPasteboardNameGeneral];
}

+ (NSPasteboard *)pasteboardWithName:(NSPasteboardName)name
{
    @synchronized(self) {
        NSPasteboard *pb = pasteboards()[name];
        if (!pb) {
            pb = [[[NSPasteboard alloc] init] autorelease];
            pb->_name = [name copy];
            pb->_pb = _FinchPasteboardGet((CFStringRef)name);
            pb->_owners = [[NSMutableDictionary alloc] init];
            pb->_ownData = [[NSMutableDictionary alloc] init];
            pb->_written = [[NSMutableDictionary alloc] init];
            _FinchPasteboardSetProvider(pb->_pb, provide, pb);
            pasteboards()[name] = pb;
        }
        return pb;
    }
}

+ (NSPasteboard *)pasteboardWithUniqueName
{
    return [self pasteboardWithName:[[NSUUID UUID] UUIDString]];
}

- (void)dealloc
{
    [_name release];
    [_owners release];
    [_ownData release];
    [_written release];
    [super dealloc];
}

- (NSPasteboardName)name { return _name; }
- (NSInteger)changeCount { return _FinchPasteboardGetChangeCount(_pb); }

- (void)releaseGlobally
{
    _FinchPasteboardSetProvider(_pb, NULL, NULL);
    _FinchPasteboardRelease(_pb);
    @synchronized([NSPasteboard class]) {
        [pasteboards() removeObjectForKey:_name];
    }
}

- (NSInteger)prepareForNewContentsWithOptions:(NSPasteboardContentsOptions)options { return [self clearContents]; }

- (NSInteger)clearContents
{
    _seed = _FinchPasteboardClear(_pb);
    _FinchPasteboardSetProvider(_pb, provide, self); /* (the writer's: the Pasteboard Manager may have been) */
    _nextItem = 1;
    [_owners removeAllObjects];
    [_ownData removeAllObjects];
    [_written removeAllObjects];
    return _seed;
}

/* Item 1 (the old API's one item) promised in these types, by the owner. */
- (NSInteger)addTypes:(NSArray<NSPasteboardType> *)newTypes owner:(id)newOwner
{
    if (!_seed || _seed != _FinchPasteboardGetChangeCount(_pb))
        [self clearContents];
    if (_nextItem < 2)
        _nextItem = 2;
    for (NSString *type in newTypes) {
        NSString *t = modern_type(type);
        _owners[t] = newOwner ?: [NSNull null];
        if (!_ownData[t])
            _FinchPasteboardPut(_pb, _seed, 1, (CFStringRef)t, NULL);
    }
    return _seed;
}

- (NSInteger)declareTypes:(NSArray<NSPasteboardType> *)newTypes owner:(id)newOwner
{
    [self clearContents];
    return [self addTypes:newTypes owner:newOwner];
}

/* The data for one of this process's promises: from the owner, the item's provider or
   the written object, on the main thread (where AppKit's objects are asked things). */
- (NSData *)_finchProvide:(uint64_t)item type:(NSString *)type seed:(NSInteger)seed
{
    if (seed != _seed)
        return nil;
    if (item == 1 && _owners[type]) {
        id owner = _owners[type];
        if (!_ownData[type] && owner != [NSNull null] && [owner respondsToSelector:@selector(pasteboard:provideDataForType:)])
            [owner pasteboard:self provideDataForType:type];
        return _ownData[type];
    }
    id o = _written[@(item)];
    if ([o isKindOfClass:[NSPasteboardItem class]]) {
        NSPasteboardItem *pi = o;
        id provider = [pi _finchProviders][type];
        if ([provider respondsToSelector:@selector(pasteboard:item:provideDataForType:)])
            [provider pasteboard:self item:pi provideDataForType:type];
        return [pi dataForType:type];
    }
    if ([o respondsToSelector:@selector(pasteboardPropertyListForType:)])
        return data_of([o pasteboardPropertyListForType:type]);
    return nil;
}

static CFDataRef
provide(CFStringRef name, CFIndex seed, uint64_t item, CFStringRef type, void *info)
{
    NSPasteboard *self = info;
    __block NSData *data = nil;
    void (^ask)(void) = ^{
      data = [[self _finchProvide:item type:(NSString *)type seed:seed] retain];
    };
    if ([NSThread isMainThread])
        ask();
    else
        dispatch_sync(dispatch_get_main_queue(), ask);
    return (CFDataRef)data;
}

static NSData *
nonempty(NSData *d)
{
    return d ?: [NSData data];
}

/* Writes item 1's data in a type (the old API): replaces its promise. */
static BOOL
set_item1(NSPasteboard *self, id value, NSString *type)
{
    if (!type)
        return NO;
    NSString *t = modern_type(type);
    if (!self->_seed || self->_seed != _FinchPasteboardGetChangeCount(self->_pb))
        [self clearContents];
    if (self->_nextItem < 2)
        self->_nextItem = 2;
    NSData *d = nonempty(data_of(value));
    self->_ownData[t] = d;
    return _FinchPasteboardPut(self->_pb, self->_seed, 1, (CFStringRef)t, (CFDataRef)d);
}

- (BOOL)setData:(NSData *)data forType:(NSPasteboardType)dataType { return set_item1(self, data, dataType); }
- (BOOL)setString:(NSString *)string forType:(NSPasteboardType)dataType { return set_item1(self, string, dataType); }
- (BOOL)setPropertyList:(id)plist forType:(NSPasteboardType)dataType { return set_item1(self, plist, dataType); }

- (BOOL)writeObjects:(NSArray<id<NSPasteboardWriting>> *)objects
{
    if (!_seed || _seed != _FinchPasteboardGetChangeCount(_pb))
        [self clearContents];
    for (id o in objects) {
        uint64_t item = _nextItem++;
        if ([o isKindOfClass:[NSPasteboardItem class]]) {
            NSPasteboardItem *pi = o;
            _written[@(item)] = pi;
            NSDictionary *providers = [pi _finchProviders];
            for (NSString *t in [pi types]) {
                if ([t isEqualToString:NSStringPboardType]) /* (the alias of the modern type, written as it) */
                    continue;
                NSData *d = providers[t] ? nil : [pi dataForType:t];
                _FinchPasteboardPut(_pb, _seed, item, (CFStringRef)t, providers[t] ? NULL : (CFDataRef)nonempty(d));
            }
        } else if ([o isKindOfClass:[NSString class]]) {
            _FinchPasteboardPut(_pb, _seed, item, (CFStringRef)NSPasteboardTypeString, (CFDataRef)data_of(o));
        } else if ([o isKindOfClass:[NSURL class]]) {
            NSURL *u = o;
            _FinchPasteboardPut(_pb, _seed, item, (CFStringRef)(u.isFileURL ? NSPasteboardTypeFileURL : NSPasteboardTypeURL),
                                (CFDataRef)data_of(u.absoluteString));
        } else if ([o respondsToSelector:@selector(writableTypesForPasteboard:)]) {
            _written[@(item)] = o;
            for (NSString *t in [o writableTypesForPasteboard:self]) {
                BOOL promised = [o respondsToSelector:@selector(writingOptionsForType:pasteboard:)] &&
                                ([o writingOptionsForType:t pasteboard:self] & NSPasteboardWritingPromised);
                /* (a type with nothing for it now stays listed, asked for when read, as Apple's) */
                NSData *d = promised ? nil : data_of([o pasteboardPropertyListForType:t]);
                _FinchPasteboardPut(_pb, _seed, item, (CFStringRef)modern_type(t), (CFDataRef)d);
            }
        } else {
            return NO;
        }
    }
    return YES;
}

/* --- reading --- */

- (NSData *)_finchDataForItem:(uint64_t)item type:(NSString *)type
{
    return [(NSData *)_FinchPasteboardCopyData(_pb, item, (CFStringRef)type) autorelease];
}

- (NSArray<NSPasteboardItem *> *)pasteboardItems
{
    NSArray *items = [(NSArray *)_FinchPasteboardCopyItems(_pb, NULL) autorelease];
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *d in items)
        [out addObject:[[[NSPasteboardItem alloc] _finchInitWithPasteboard:self item:[d[@"id"] unsignedLongLongValue]
                                                                      types:d[@"types"]] autorelease]];
    return out;
}

- (NSUInteger)indexOfPasteboardItem:(NSPasteboardItem *)pasteboardItem
{
    if (!pasteboardItem)
        return NSNotFound;
    uint64_t itemID = 0;
    if ([pasteboardItem _finchPasteboard] == self) {
        itemID = [pasteboardItem _finchItemID];
    } else {
        for (NSNumber *key in _written)
            if (_written[key] == pasteboardItem) {
                itemID = [key unsignedLongLongValue];
                break;
            }
    }
    if (!itemID)
        return NSNotFound;
    NSArray *items = [self pasteboardItems];
    for (NSUInteger i = 0; i < items.count; i++)
        if ([items[i] _finchItemID] == itemID)
            return i;
    return NSNotFound;
}

- (NSArray<NSPasteboardType> *)types
{
    NSMutableArray *a = [NSMutableArray array];
    for (NSPasteboardItem *item in [self pasteboardItems])
        for (NSString *t in [item types]) {
            if (![a containsObject:t])
                [a addObject:t];
            for (NSString *old in translations(t))
                if (![a containsObject:old])
                    [a addObject:old];
        }
    return a;
}

- (NSPasteboardType)availableTypeFromArray:(NSArray<NSPasteboardType> *)types
{
    NSArray *mine = [self types];
    for (NSString *t in types)
        if ([mine containsObject:t])
            return t;
    return nil;
}

- (BOOL)canReadItemWithDataConformingToTypes:(NSArray<NSString *> *)types
{
    return [self availableTypeFromArray:types] != nil;
}

- (NSData *)dataForType:(NSPasteboardType)dataType
{
    for (NSPasteboardItem *item in [self pasteboardItems]) {
        NSArray *types = [item types];
        if ([types containsObject:dataType] || translated_from(dataType, types)) {
            NSData *d = [item dataForType:dataType];
            if (d)
                return d;
        }
    }
    return nil;
}

- (NSString *)stringForType:(NSPasteboardType)dataType
{
    return string_of([self dataForType:dataType]);
}

- (id)propertyListForType:(NSPasteboardType)dataType
{
    return plist_of([self dataForType:dataType]);
}

/* The item a reader is being made from, for readers that need more than one type of
   it (NSFilePromiseReceiver). */
static __thread NSPasteboardItem *item_being_read;

NSPasteboardItem *
FinchPasteboardItemBeingRead(void)
{
    return item_being_read;
}

/* An NSPasteboardReading class's object from an item: the first of its readable types
   the item has, read as the class asks (data, string, property list or archive). */
static id
read_object(NSPasteboard *pb, NSPasteboardItem *item, Class c)
{
    if (![c respondsToSelector:@selector(readableTypesForPasteboard:)] ||
        ![c instancesRespondToSelector:@selector(initWithPasteboardPropertyList:ofType:)])
        return nil;
    NSArray *have = [item types];
    for (NSString *type in [c readableTypesForPasteboard:pb]) {
        if (![have containsObject:type])
            continue;
        NSPasteboardReadingOptions options = [c respondsToSelector:@selector(readingOptionsForType:pasteboard:)]
                                                 ? [c readingOptionsForType:type pasteboard:pb]
                                                 : NSPasteboardReadingAsData;
        NSData *data = [item dataForType:type];
        id value = data;
        if (options & NSPasteboardReadingAsString)
            value = string_of(data);
        else if (options & NSPasteboardReadingAsPropertyList)
            value = plist_of(data);
        else if (options & NSPasteboardReadingAsKeyedArchive)
            value = data ? [NSKeyedUnarchiver unarchiveObjectWithData:data] : nil;
        if (!value)
            continue;
        NSPasteboardItem *outer = item_being_read;
        item_being_read = item;
        id object = [[[c alloc] initWithPasteboardPropertyList:value ofType:type] autorelease];
        item_being_read = outer;
        if (object)
            return object;
    }
    return nil;
}

- (NSArray *)readObjectsForClasses:(NSArray<Class> *)classArray options:(NSDictionary *)options
{
    NSMutableArray *found = [NSMutableArray array];
    for (NSPasteboardItem *item in [self pasteboardItems])
        for (Class c in classArray) {
            if (c == [NSString class] || [c isSubclassOfClass:[NSString class]]) {
                NSString *s = [[item types] containsObject:NSPasteboardTypeString] ? [item stringForType:NSPasteboardTypeString] : nil;
                if (s) {
                    [found addObject:s];
                    break;
                }
            } else if (c == [NSURL class]) {
                NSArray *types = [item types];
                NSString *s = [types containsObject:NSPasteboardTypeFileURL] ? [item stringForType:NSPasteboardTypeFileURL]
                              : [types containsObject:NSPasteboardTypeURL] ? [item stringForType:NSPasteboardTypeURL]
                                                                           : nil;
                if (s) {
                    [found addObject:[NSURL URLWithString:s]];
                    break;
                }
            } else {
                id object = read_object(self, item, c);
                if (object) {
                    [found addObject:object];
                    break;
                }
            }
        }
    return found;
}

- (BOOL)canReadObjectForClasses:(NSArray<Class> *)classArray options:(NSDictionary *)options
{
    return [[self readObjectsForClasses:classArray options:options] count] > 0;
}

- (BOOL)writeFileContents:(NSString *)filename
{
    NSData *d = [NSData dataWithContentsOfFile:filename];
    return d && [self setData:d forType:NSFileContentsPboardType];
}

- (BOOL)writeFileWrapper:(NSFileWrapper *)wrapper
{
    NSData *data = [wrapper serializedRepresentation];
    return data && [self setData:data forType:NSFileContentsPboardType];
}

- (NSFileWrapper *)readFileWrapper
{
    NSData *data = [self dataForType:NSFileContentsPboardType];
    return data ? [[[NSFileWrapper alloc] initWithSerializedRepresentation:data] autorelease] : nil;
}

- (NSString *)readFileContentsType:(NSPasteboardType)type toFile:(NSString *)filename
{
    NSData *d = [self dataForType:type ?: NSFileContentsPboardType];
    return d && [d writeToFile:filename atomically:YES] ? filename : nil;
}

+ (NSArray<NSPasteboardType> *)typesFilterableTo:(NSPasteboardType)type { return type ? @[ type ] : @[]; }

- (NSPasteboardAccessBehavior)accessBehavior { return NSPasteboardAccessBehaviorAlwaysAllow; }

@end

NSPasteboardType
NSCreateFilenamePboardType(NSString *fileType)
{
    return [NSString stringWithFormat:@"NSTypedFilenamesPboardType:%@", fileType];
}

NSPasteboardType
NSCreateFileContentsPboardType(NSString *fileType)
{
    return [NSString stringWithFormat:@"NSTypedFileContentsPboardType:%@", fileType];
}

NSString *
NSGetFileType(NSPasteboardType pboardType)
{
    NSRange r = [pboardType rangeOfString:@":"];
    return r.location == NSNotFound ? nil : [pboardType substringFromIndex:NSMaxRange(r)];
}

NSArray<NSString *> *
NSGetFileTypes(NSArray<NSPasteboardType> *pboardTypes)
{
    NSMutableArray *a = [NSMutableArray array];
    for (NSString *t in pboardTypes) {
        NSString *f = NSGetFileType(t);
        if (f)
            [a addObject:f];
    }
    return [a count] ? a : nil;
}

@implementation NSPasteboard (FinchSourceIdentity)
/* The signing identifier of the app that wrote the contents (private); not known on Finch's in-process pasteboard. */
- (NSString *)_sourceSigningIdentifier { return nil; }
@end

/* MARK: - Filtering and detection */

@implementation NSPasteboard (FinchFilteringAndDetection)

/* (Finch has no filter services: the pasteboard holds what was given as it is) */
+ (NSPasteboard *)pasteboardByFilteringFile:(NSString *)filename
{
    NSPasteboard *pb = [NSPasteboard pasteboardWithUniqueName];
    [pb declareTypes:@[ NSFilenamesPboardType ] owner:nil];
    [pb setPropertyList:filename ? @[ filename ] : @[] forType:NSFilenamesPboardType];
    return pb;
}

+ (NSPasteboard *)pasteboardByFilteringData:(NSData *)data ofType:(NSPasteboardType)type
{
    NSPasteboard *pb = [NSPasteboard pasteboardWithUniqueName];
    if (type) {
        [pb clearContents];
        [pb setData:data forType:type];
    }
    return pb;
}

+ (NSPasteboard *)pasteboardByFilteringTypesInPasteboard:(NSPasteboard *)pboard { return pboard; }

/* What the pasteboard's text looks like, by the patterns asked about. */
static NSDictionary *
detect_values(NSPasteboard *pb, NSSet *patterns)
{
    NSString *s = [pb stringForType:NSPasteboardTypeString];
    NSMutableDictionary *found = [NSMutableDictionary dictionary];
    if (![s length]) return found;
    NSString *trimmed = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    /* (a web URL when there's an http(s) link in it; a search when there isn't, on one line) */
    BOOL web = NO;
    NSString *firstWeb = nil;
    for (NSTextCheckingResult *r in [[NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeLink error:NULL] matchesInString:s options:0
                                                                                                                      range:NSMakeRange(0, [s length])]) {
        NSString *scheme = [[r.URL scheme] lowercaseString];
        if ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) {
            web = YES;
            firstWeb = [r.URL absoluteString];
            break;
        }
    }
    if ([patterns containsObject:NSPasteboardDetectionPatternProbableWebURL] && web) found[NSPasteboardDetectionPatternProbableWebURL] = firstWeb;
    if ([patterns containsObject:NSPasteboardDetectionPatternProbableWebSearch] && !web && [trimmed length] &&
        [trimmed rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]].location == NSNotFound)
        found[NSPasteboardDetectionPatternProbableWebSearch] = trimmed;
    if ([patterns containsObject:NSPasteboardDetectionPatternNumber]) {
        NSNumberFormatter *f = [[[NSNumberFormatter alloc] init] autorelease];
        f.numberStyle = NSNumberFormatterDecimalStyle;
        NSNumber *n = [f numberFromString:trimmed];
        if (n) found[NSPasteboardDetectionPatternNumber] = n;
    }
    NSTextCheckingTypes types = 0;
    if ([patterns containsObject:NSPasteboardDetectionPatternLink] || [patterns containsObject:NSPasteboardDetectionPatternEmailAddress])
        types |= NSTextCheckingTypeLink;
    if ([patterns containsObject:NSPasteboardDetectionPatternPhoneNumber]) types |= NSTextCheckingTypePhoneNumber;
    if (types) {
        NSDataDetector *d = [NSDataDetector dataDetectorWithTypes:types error:NULL];
        NSMutableArray *links = [NSMutableArray array], *emails = [NSMutableArray array], *phones = [NSMutableArray array];
        for (NSTextCheckingResult *r in [d matchesInString:s options:0 range:NSMakeRange(0, [s length])]) {
            if (r.resultType == NSTextCheckingTypePhoneNumber) [phones addObject:r.phoneNumber];
            else if ([[r.URL scheme] isEqualToString:@"mailto"]) [emails addObject:[r.URL resourceSpecifier]];
            else if (r.URL) [links addObject:r.URL];
        }
        if ([patterns containsObject:NSPasteboardDetectionPatternLink] && [links count]) found[NSPasteboardDetectionPatternLink] = links;
        if ([patterns containsObject:NSPasteboardDetectionPatternEmailAddress] && [emails count])
            found[NSPasteboardDetectionPatternEmailAddress] = emails;
        if ([patterns containsObject:NSPasteboardDetectionPatternPhoneNumber] && [phones count])
            found[NSPasteboardDetectionPatternPhoneNumber] = phones;
    }
    return found;
}

- (void)detectPatternsForPatterns:(NSSet<NSPasteboardDetectionPattern> *)patterns
                completionHandler:(void (^)(NSSet<NSPasteboardDetectionPattern> *, NSError *))completionHandler
{
    NSSet *found = [NSSet setWithArray:[detect_values(self, patterns) allKeys]];
    completionHandler = [[completionHandler copy] autorelease];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{ completionHandler(found, nil); });
}

- (void)detectValuesForPatterns:(NSSet<NSPasteboardDetectionPattern> *)patterns
              completionHandler:(void (^)(NSDictionary<NSPasteboardDetectionPattern, id> *, NSError *))completionHandler
{
    NSDictionary *found = detect_values(self, patterns);
    completionHandler = [[completionHandler copy] autorelease];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{ completionHandler(found, nil); });
}

- (void)detectMetadataForTypes:(NSSet<NSPasteboardMetadataType> *)types
             completionHandler:(void (^)(NSDictionary<NSPasteboardMetadataType, id> *, NSError *))completionHandler
{
    NSMutableDictionary *metadata = [NSMutableDictionary dictionary];
    NSString *type = [[self types] firstObject];
    Class utType = NSClassFromString(@"UTType");
    id contentType = [types containsObject:NSPasteboardMetadataTypeContentType] && type && utType
                         ? [utType performSelector:@selector(typeWithIdentifier:) withObject:type]
                         : nil;
    if (contentType) metadata[NSPasteboardMetadataTypeContentType] = contentType;
    completionHandler = [[completionHandler copy] autorelease];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{ completionHandler(metadata, nil); });
}

@end
