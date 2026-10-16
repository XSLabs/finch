/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CSSearchableItem and its values. A local item is stored by Finch's CoreSpotlight index;
 * attribute properties keep the values their callers set, including custom attributes.
 */
#import "CoreSpotlight_Finch.h"
#import <objc/runtime.h>

NSString *const CSIndexErrorDomain = @"CSIndexErrorDomain";
NSErrorDomain const CSSearchQueryErrorDomain = @"CSSearchQueryErrorDomain";
NSString *const CSSearchableItemActionType = @"com.apple.corespotlightitem";
NSString *const CSSearchableItemActivityIdentifier = @"kCSSearchableItemActivityIdentifier";
NSString *const CSQueryContinuationActionType = @"com.apple.corespotlightquerycontinuation";
NSString *const CSSearchQueryString = @"kCSSearchQueryString";
NSAttributedStringKey const CSSuggestionHighlightAttributeName = @"CSSuggestionHighlightAttribute";
NSString *const CSActionIdentifier = @"CSActionIdentifier";
NSString *const MDItemContentType = @"kMDItemContentType";
NSString *const MDItemKind = @"kMDItemKind";
NSString *const MDItemUniqueIdentifier = @"_kMDItemExternalID";
NSString *const CSItemSummaryTypeAttachment = @"attachment";
NSString *const CSItemSummaryTypeContact = @"contact";
NSString *const CSItemSummaryTypeDate = @"date";
NSString *const CSItemSummaryTypeText = @"text";

static NSArray<NSString *> *
attributeNames(void)
{
    static NSArray *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      names = @[ @"accountIdentifier", @"accountHandles", @"HTMLContentData", @"textContent", @"authors", @"primaryRecipients",
        @"additionalRecipients", @"hiddenAdditionalRecipients", @"emailHeaders", @"mailboxIdentifiers", @"authorNames",
        @"recipientNames", @"authorEmailAddresses", @"recipientEmailAddresses", @"authorAddresses", @"recipientAddresses",
        @"phoneNumbers", @"emailAddresses", @"instantMessageAddresses", @"likelyJunk", @"isPriority", @"displayName", @"alternateNames",
        @"path", @"contentURL", @"thumbnailURL", @"thumbnailData", @"darkThumbnailURL", @"relatedUniqueIdentifier",
        @"metadataModificationDate", @"contentType", @"contentTypeTree", @"sharedItemContentType", @"actionIdentifiers", @"keywords", @"title", @"version",
        @"userCreated", @"userOwned", @"userCurated", @"rankingHint", @"domainIdentifier", @"textContentSummary",
        @"transcribedTextContent", @"supportsPhoneCall", @"supportsNavigation", @"containerTitle", @"containerDisplayName",
        @"containerIdentifier", @"containerOrder", @"providerDataTypeIdentifiers", @"providerFileTypeIdentifiers",
        @"providerInPlaceFileTypeIdentifiers", @"pixelHeight", @"pixelWidth", @"pixelCount", @"colorSpace", @"bitsPerSample",
        @"flashOn", @"focalLength", @"focalLength35mm", @"acquisitionMake", @"acquisitionModel", @"cameraOwner", @"lensModel",
        @"ISOSpeed", @"orientation", @"layerNames", @"whiteBalance", @"aperture", @"profileName", @"resolutionWidthDPI",
        @"resolutionHeightDPI", @"exposureMode", @"exposureTime", @"EXIFVersion", @"EXIFGPSVersion", @"hasAlphaChannel",
        @"redEyeOn", @"meteringMode", @"maxAperture", @"fNumber", @"exposureProgram", @"exposureTimeString", @"subject",
        @"theme", @"contentDescription", @"identifier", @"audiences", @"fileSize", @"pageCount", @"pageWidth", @"pageHeight",
        @"securityMethod", @"creator", @"encodingApplications", @"kind", @"fontNames", @"editors", @"participants", @"projects",
        @"contentSources", @"comment", @"copyright", @"lastUsedDate", @"contentCreationDate", @"contentModificationDate",
        @"addedDate", @"downloadedDate", @"duration", @"contactKeywords", @"codecs", @"mediaTypes", @"streamable",
        @"totalBitRate", @"videoBitRate", @"audioBitRate", @"deliveryType", @"organizations", @"role", @"languages", @"rights",
        @"publishers", @"contributors", @"coverage", @"rating", @"ratingDescription", @"playCount", @"information", @"director",
        @"producer", @"genre", @"performers", @"originalFormat", @"originalSource", @"local", @"contentRating", @"URL",
        @"audioSampleRate", @"audioChannelCount", @"tempo", @"keySignature", @"timeSignature", @"audioEncodingApplication",
        @"composer", @"lyricist", @"album", @"artist", @"audioTrackNumber", @"recordingDate", @"musicalGenre",
        @"generalMIDISequence", @"musicalInstrumentCategory", @"musicalInstrumentName", @"headline", @"instructions",
        @"thoroughfare", @"subThoroughfare", @"postalCode", @"city", @"stateOrProvince", @"country", @"fullyFormattedAddress",
        @"altitude", @"latitude", @"longitude", @"speed", @"timestamp", @"imageDirection", @"namedLocation", @"GPSTrack",
        @"GPSStatus", @"GPSMeasureMode", @"GPSDOP", @"GPSMapDatum", @"GPSDestLatitude", @"GPSDestLongitude", @"GPSDestBearing",
        @"GPSDestDistance", @"GPSProcessingMethod", @"GPSAreaInformation", @"GPSDateStamp", @"GPSDifferental", @"dueDate",
        @"completionDate", @"startDate", @"endDate", @"importantDates", @"allDay" ];
    });
    return names;
}

@interface CSSearchableItemAttributeSet (FinchSearchResults)
- (void)_finchRestrictToAttributes:(NSSet<NSString *> *)attributes;
@end

static NSString *
attributeForSelector(SEL selector, BOOL *setter)
{
    NSString *sel = NSStringFromSelector(selector);
    *setter = NO;
    for (NSString *name in attributeNames()) {
        NSString *getter = name;
        if ([name isEqualToString:@"likelyJunk"] || [name isEqualToString:@"userCreated"] || [name isEqualToString:@"userOwned"] ||
            [name isEqualToString:@"userCurated"] || [name isEqualToString:@"flashOn"] || [name isEqualToString:@"focalLength35mm"] ||
            [name isEqualToString:@"redEyeOn"] || [name isEqualToString:@"streamable"] || [name isEqualToString:@"local"] ||
            [name isEqualToString:@"generalMIDISequence"])
            getter = [NSString stringWithFormat:@"is%@%@", [[name substringToIndex:1] uppercaseString], [name substringFromIndex:1]];
        if ([sel isEqualToString:getter])
            return name;
        NSString *setterName = [NSString stringWithFormat:@"set%@%@:", [[name substringToIndex:1] uppercaseString], [name substringFromIndex:1]];
        if (![name isEqualToString:@"isPriority"] && [sel isEqualToString:setterName]) {
            *setter = YES;
            return name;
        }
    }
    return nil;
}

@implementation CSSearchableItemAttributeSet {
    NSMutableDictionary<NSString *, id> *_finchValues;
    NSMutableDictionary<NSString *, id> *_customValues;
}

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)init
{
    if ((self = [super init])) {
        _finchValues = [NSMutableDictionary dictionary];
        _customValues = [NSMutableDictionary dictionary];
    }
    return self;
}

- (instancetype)initWithItemContentType:(NSString *)identifier
{
    if ((self = [self init])) {
        self.contentType = identifier;
        self.contentTypeTree = identifier.length ? @[ identifier ] : @[];
    }
    return self;
}

- (instancetype)initWithContentType:(UTType *)type
{
    return [self initWithItemContentType:type.identifier ?: @""];
}

- (BOOL)respondsToSelector:(SEL)selector
{
    BOOL setter;
    return [super respondsToSelector:selector] || attributeForSelector(selector, &setter) != nil;
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector
{
    BOOL setter;
    if (attributeForSelector(selector, &setter))
        return [NSMethodSignature signatureWithObjCTypes:setter ? "v@:@" : "@@:"];
    return [super methodSignatureForSelector:selector];
}

- (void)forwardInvocation:(NSInvocation *)invocation
{
    BOOL setter;
    NSString *key = attributeForSelector(invocation.selector, &setter);
    if (!key) {
        [super forwardInvocation:invocation];
        return;
    }
    if (setter) {
        __unsafe_unretained id value;
        [invocation getArgument:&value atIndex:2];
        if (value)
            _finchValues[key] = value;
        else
            [_finchValues removeObjectForKey:key];
    } else {
        __unsafe_unretained id value = _finchValues[key];
        [invocation setReturnValue:&value];
    }
}

- (void)setValue:(id)value forKey:(NSString *)key
{
    if ([attributeNames() containsObject:key]) {
        if (value)
            _finchValues[key] = value;
        else
            [_finchValues removeObjectForKey:key];
        return;
    }
    [super setValue:value forKey:key];
}

- (id)valueForKey:(NSString *)key
{
    if ([attributeNames() containsObject:key])
        return _finchValues[key];
    return [super valueForKey:key];
}

- (void)setValue:(id)value forCustomKey:(CSCustomAttributeKey *)key
{
    if (!key.keyName.length)
        return;
    if (value)
        _customValues[key.keyName] = value;
    else
        [_customValues removeObjectForKey:key.keyName];
}

- (id)valueForCustomKey:(CSCustomAttributeKey *)key { return _customValues[key.keyName]; }
- (void)_finchRestrictToAttributes:(NSSet<NSString *> *)attributes
{
    for (NSString *key in [_finchValues.allKeys copy])
        if (![attributes containsObject:key])
            [_finchValues removeObjectForKey:key];
    for (NSString *key in [_customValues.allKeys copy])
        if (![attributes containsObject:key])
            [_customValues removeObjectForKey:key];
}
- (id)copyWithZone:(NSZone *)zone
{
    CSSearchableItemAttributeSet *copy = [[[self class] allocWithZone:zone] init];
    copy->_finchValues = [_finchValues mutableCopy];
    copy->_customValues = [_customValues mutableCopy];
    return copy;
}
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_finchValues forKey:@"attributes"];
    [coder encodeObject:_customValues forKey:@"customAttributes"];
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [self init])) {
        _finchValues = [[coder decodeObjectOfClass:[NSDictionary class] forKey:@"attributes"] mutableCopy] ?: [NSMutableDictionary dictionary];
        _customValues = [[coder decodeObjectOfClass:[NSDictionary class] forKey:@"customAttributes"] mutableCopy] ?: [NSMutableDictionary dictionary];
    }
    return self;
}

@end

CSSearchableItem *
FinchCSSearchableItemWithFetchedAttributes(CSSearchableItem *item, NSArray<NSString *> *attributes)
{
    CSSearchableItem *copy = [item copy];
    NSMutableSet *keep = [NSMutableSet set];
    for (NSString *key in attributes ?: @[]) {
        if ([key isKindOfClass:[NSString class]])
            [keep addObject:key];
    }
    [copy.attributeSet _finchRestrictToAttributes:keep];
    return copy;
}

@implementation NSUserActivity (CSSearchableItemAttributeSet)
- (CSSearchableItemAttributeSet *)contentAttributeSet
{
    return objc_getAssociatedObject(self, @selector(contentAttributeSet));
}
- (void)setContentAttributeSet:(CSSearchableItemAttributeSet *)attributeSet
{
    objc_setAssociatedObject(self, @selector(contentAttributeSet), [attributeSet copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
@end

@implementation CSSearchableItem {
    NSString *_uniqueIdentifier;
    NSString *_domainIdentifier;
    NSDate *_expirationDate;
    CSSearchableItemAttributeSet *_attributeSet;
    BOOL _isUpdate;
    CSSearchableItemUpdateListenerOptions _updateListenerOptions;
}

+ (BOOL)supportsSecureCoding { return YES; }
- (instancetype)init
{
    return [self initWithUniqueIdentifier:nil domainIdentifier:nil attributeSet:[[CSSearchableItemAttributeSet alloc] init]];
}
- (instancetype)initWithUniqueIdentifier:(NSString *)identifier domainIdentifier:(NSString *)domain attributeSet:(CSSearchableItemAttributeSet *)attributes
{
    if ((self = [super init])) {
        _uniqueIdentifier = [identifier copy] ?: [NSUUID UUID].UUIDString;
        _domainIdentifier = [domain copy];
        _expirationDate = [NSDate dateWithTimeIntervalSinceNow:30.0 * 24.0 * 60.0 * 60.0];
        _attributeSet = attributes ?: [[CSSearchableItemAttributeSet alloc] init];
    }
    return self;
}
- (NSString *)uniqueIdentifier { return _uniqueIdentifier; }
- (void)setUniqueIdentifier:(NSString *)value { _uniqueIdentifier = [value copy] ?: [NSUUID UUID].UUIDString; }
- (NSString *)domainIdentifier { return _domainIdentifier; }
- (void)setDomainIdentifier:(NSString *)value { _domainIdentifier = [value copy]; }
- (NSDate *)expirationDate { return _expirationDate; }
- (void)setExpirationDate:(NSDate *)value { _expirationDate = [value copy] ?: [NSDate distantFuture]; }
- (CSSearchableItemAttributeSet *)attributeSet { return _attributeSet; }
- (void)setAttributeSet:(CSSearchableItemAttributeSet *)value { _attributeSet = value ?: [[CSSearchableItemAttributeSet alloc] init]; }
- (BOOL)isUpdate { return _isUpdate; }
- (void)setIsUpdate:(BOOL)value { _isUpdate = value; }
- (CSSearchableItemUpdateListenerOptions)updateListenerOptions { return _updateListenerOptions; }
- (void)setUpdateListenerOptions:(CSSearchableItemUpdateListenerOptions)value { _updateListenerOptions = value; }
- (NSComparisonResult)compareByRank:(CSSearchableItem *)other
{
    double left = [_attributeSet.rankingHint doubleValue], right = [other.attributeSet.rankingHint doubleValue];
    if (left != right)
        return left > right ? NSOrderedAscending : NSOrderedDescending;
    NSString *a = _attributeSet.title ?: _attributeSet.displayName ?: _uniqueIdentifier;
    NSString *b = other.attributeSet.title ?: other.attributeSet.displayName ?: other.uniqueIdentifier;
    return [a localizedCaseInsensitiveCompare:b];
}
- (id)copyWithZone:(NSZone *)zone
{
    CSSearchableItem *copy = [[[self class] allocWithZone:zone] initWithUniqueIdentifier:_uniqueIdentifier domainIdentifier:_domainIdentifier
                                                                                  attributeSet:[_attributeSet copy]];
    copy.expirationDate = _expirationDate;
    copy.isUpdate = _isUpdate;
    copy.updateListenerOptions = _updateListenerOptions;
    return copy;
}
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_uniqueIdentifier forKey:@"uniqueIdentifier"];
    [coder encodeObject:_domainIdentifier forKey:@"domainIdentifier"];
    [coder encodeObject:_expirationDate forKey:@"expirationDate"];
    [coder encodeObject:_attributeSet forKey:@"attributeSet"];
    [coder encodeBool:_isUpdate forKey:@"isUpdate"];
    [coder encodeInteger:_updateListenerOptions forKey:@"updateListenerOptions"];
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    CSSearchableItemAttributeSet *attributes = [coder decodeObjectOfClass:[CSSearchableItemAttributeSet class] forKey:@"attributeSet"];
    if ((self = [self initWithUniqueIdentifier:[coder decodeObjectOfClass:[NSString class] forKey:@"uniqueIdentifier"]
                                 domainIdentifier:[coder decodeObjectOfClass:[NSString class] forKey:@"domainIdentifier"]
                                      attributeSet:attributes])) {
        _expirationDate = [coder decodeObjectOfClass:[NSDate class] forKey:@"expirationDate"] ?: [NSDate distantFuture];
        _isUpdate = [coder decodeBoolForKey:@"isUpdate"];
        _updateListenerOptions = [coder decodeIntegerForKey:@"updateListenerOptions"];
    }
    return self;
}
@end

@implementation CSPerson {
    NSString *_displayName, *_handleIdentifier, *_contactIdentifier;
    NSArray<NSString *> *_handles;
}
+ (BOOL)supportsSecureCoding { return YES; }
- (instancetype)initWithDisplayName:(NSString *)name handles:(NSArray<NSString *> *)handles handleIdentifier:(NSString *)identifier
{
    if ((self = [super init])) {
        _displayName = [name copy];
        _handles = [handles copy] ?: @[];
        _handleIdentifier = [identifier copy] ?: @"";
    }
    return self;
}
- (NSString *)displayName { return _displayName; }
- (NSArray *)handles { return _handles; }
- (NSString *)handleIdentifier { return _handleIdentifier; }
- (NSString *)contactIdentifier { return _contactIdentifier; }
- (void)setContactIdentifier:(NSString *)value { _contactIdentifier = [value copy]; }
- (id)copyWithZone:(NSZone *)zone
{
    CSPerson *copy = [[[self class] allocWithZone:zone] initWithDisplayName:_displayName handles:_handles handleIdentifier:_handleIdentifier];
    copy.contactIdentifier = _contactIdentifier;
    return copy;
}
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_displayName forKey:@"displayName"];
    [coder encodeObject:_handles forKey:@"handles"];
    [coder encodeObject:_handleIdentifier forKey:@"handleIdentifier"];
    [coder encodeObject:_contactIdentifier forKey:@"contactIdentifier"];
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSSet *classes = [NSSet setWithObjects:[NSArray class], [NSString class], nil];
    if ((self = [self initWithDisplayName:[coder decodeObjectOfClass:[NSString class] forKey:@"displayName"]
                                  handles:[coder decodeObjectOfClasses:classes forKey:@"handles"]
                          handleIdentifier:[coder decodeObjectOfClass:[NSString class] forKey:@"handleIdentifier"]]))
        _contactIdentifier = [[coder decodeObjectOfClass:[NSString class] forKey:@"contactIdentifier"] copy];
    return self;
}
@end

@implementation CSCustomAttributeKey {
    NSString *_keyName;
    BOOL _searchable, _searchableByDefault, _unique, _multiValued;
}
+ (BOOL)supportsSecureCoding { return YES; }
- (instancetype)initWithKeyName:(NSString *)name
{
    return [self initWithKeyName:name searchable:YES searchableByDefault:NO unique:NO multiValued:NO];
}
- (instancetype)initWithKeyName:(NSString *)name searchable:(BOOL)searchable searchableByDefault:(BOOL)byDefault unique:(BOOL)unique multiValued:(BOOL)multi
{
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"];
    if (!name.length || [name rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound || [name hasPrefix:@"kMD"])
        return nil;
    if ((self = [super init])) {
        _keyName = [name copy];
        _searchable = searchable;
        _searchableByDefault = byDefault;
        _unique = unique;
        _multiValued = multi;
    }
    return self;
}
- (NSString *)keyName { return _keyName; }
- (BOOL)isSearchable { return _searchable; }
- (BOOL)isSearchableByDefault { return _searchableByDefault; }
- (BOOL)isUnique { return _unique; }
- (BOOL)isMultiValued { return _multiValued; }
- (id)copyWithZone:(NSZone *)zone { return self; }
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_keyName forKey:@"keyName"];
    [coder encodeBool:_searchable forKey:@"searchable"];
    [coder encodeBool:_searchableByDefault forKey:@"searchableByDefault"];
    [coder encodeBool:_unique forKey:@"unique"];
    [coder encodeBool:_multiValued forKey:@"multiValued"];
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    return [self initWithKeyName:[coder decodeObjectOfClass:[NSString class] forKey:@"keyName"]
                      searchable:[coder decodeBoolForKey:@"searchable"]
             searchableByDefault:[coder decodeBoolForKey:@"searchableByDefault"]
                           unique:[coder decodeBoolForKey:@"unique"]
                      multiValued:[coder decodeBoolForKey:@"multiValued"]];
}
@end

@implementation CSLocalizedString {
    NSDictionary<NSString *, NSString *> *_localizedStrings;
    NSString *_localizedValue;
}
- (instancetype)initWithLocalizedStrings:(NSDictionary *)strings
{
    if ((self = [super init])) {
        _localizedStrings = [strings copy] ?: @{};
        NSArray<NSString *> *languages = [NSLocale preferredLanguages];
        for (NSString *language in languages) {
            NSString *value = _localizedStrings[language] ?: _localizedStrings[[language componentsSeparatedByString:@"-"].firstObject];
            if (value) { _localizedValue = [value copy]; break; }
        }
        if (!_localizedValue)
            _localizedValue = [_localizedStrings[@"en"] copy] ?: _localizedStrings.allValues.firstObject ?: @"";
    }
    return self;
}
- (NSString *)localizedString { return _localizedValue; }
- (NSUInteger)length { return _localizedValue.length; }
- (unichar)characterAtIndex:(NSUInteger)index { return [_localizedValue characterAtIndex:index]; }
- (void)getCharacters:(unichar *)buffer range:(NSRange)range { [_localizedValue getCharacters:buffer range:range]; }
@end

@implementation CSImportExtension
- (void)beginRequestWithExtensionContext:(NSExtensionContext *)context
{
    NSError *error = [NSError errorWithDomain:CSIndexErrorDomain code:CSIndexErrorCodeIndexingUnsupported
                                     userInfo:@{ NSLocalizedDescriptionKey : @"Spotlight file import extensions are unavailable on Finch." }];
    [context cancelRequestWithError:error];
}
- (BOOL)updateAttributes:(CSSearchableItemAttributeSet *)attributes forFileAtURL:(NSURL *)contentURL error:(NSError **)error
{
    (void)attributes;
    (void)contentURL;
    if (error)
        *error = [NSError errorWithDomain:CSIndexErrorDomain code:CSIndexErrorCodeIndexingUnsupported
                                 userInfo:@{ NSLocalizedDescriptionKey : @"Finch has no file metadata importer installed." }];
    return NO;
}
@end
