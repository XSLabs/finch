/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * AVMetadataItem and AVMutableMetadataItem: a key in a key space (a four-character code
 * for QuickTime user data, ISO user data, iTunes and ID3; a string for QuickTime
 * metadata), its identifier ("udta/%A9nam": the key space's prefix and the key, with
 * bytes outside printable ASCII written %XX), its common key (Apple's table,
 * AVMetadataTables.m), a value and how to read it as a string, number, date or data.
 */
#import "AVFInternal.h"

/* Key spaces whose identifiers have another prefix. */
static NSString *
prefix_for_key_space(NSString *keySpace)
{
    if ([keySpace isEqualToString:AVMetadataKeySpaceID3])
        return @"id3";
    return keySpace;
}

static NSString *
key_space_for_prefix(NSString *prefix)
{
    if ([prefix isEqualToString:@"id3"])
        return AVMetadataKeySpaceID3;
    return prefix;
}

static BOOL
code_key_space(NSString *keySpace)
{
    return [keySpace isEqualToString:AVMetadataKeySpaceQuickTimeUserData] || [keySpace isEqualToString:AVMetadataKeySpaceISOUserData] ||
           [keySpace isEqualToString:AVMetadataKeySpaceiTunes] || [keySpace isEqualToString:AVMetadataKeySpaceID3];
}

static FourCharCode
code_of(id key)
{
    if ([key isKindOfClass:[NSNumber class]])
        return (FourCharCode)[key unsignedIntValue];
    if ([key isKindOfClass:[NSString class]] && [key length] == 4) {
        NSData *d = [key dataUsingEncoding:NSMacOSRomanStringEncoding];
        const uint8_t *b = d.bytes;
        if (d.length == 4)
            return (FourCharCode)b[0] << 24 | (FourCharCode)b[1] << 16 | (FourCharCode)b[2] << 8 | b[3];
    }
    return 0;
}

NSString *
AVFCommonKeyFor(id key, NSString *keySpace)
{
    if (!key || !keySpace)
        return nil;
    BOOL codes = code_key_space(keySpace);
    FourCharCode code = codes ? code_of(key) : 0;
    const char *ks = keySpace.UTF8String;
    const char *sk = codes ? NULL : [[key description] UTF8String];
    for (size_t i = 0; i < AVFIdentifierTableCount; i++) {
        const AVFIdentifierInfo *e = &AVFIdentifierTable[i];
        if (strcmp(e->keySpace, ks))
            continue;
        if (codes ? (!e->stringKey && e->codeKey == code) : (e->stringKey && sk && !strcmp(e->stringKey, sk)))
            return e->commonKey ? @(e->commonKey) : nil;
    }
    return nil;
}

NSArray<AVMetadataItem *> *
AVFCommonMetadata(NSArray<AVMetadataItem *> *items)
{
    /* (Apple's order; contributors aren't among the common metadata) */
    NSArray *order = @[
        AVMetadataCommonKeyTitle, AVMetadataCommonKeyCreator, AVMetadataCommonKeySubject, AVMetadataCommonKeyDescription,
        AVMetadataCommonKeyPublisher, AVMetadataCommonKeyCreationDate, AVMetadataCommonKeyLastModifiedDate,
        AVMetadataCommonKeyType, AVMetadataCommonKeyFormat, AVMetadataCommonKeyIdentifier, AVMetadataCommonKeySource,
        AVMetadataCommonKeyLanguage, AVMetadataCommonKeyRelation, AVMetadataCommonKeyLocation, AVMetadataCommonKeyCopyrights,
        AVMetadataCommonKeyAlbumName, AVMetadataCommonKeyAuthor, AVMetadataCommonKeyArtist, AVMetadataCommonKeyArtwork,
        AVMetadataCommonKeyMake, AVMetadataCommonKeyModel, AVMetadataCommonKeySoftware, AVMetadataCommonKeyAccessibilityDescription
    ];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *ck in order)
        for (AVMetadataItem *m in items)
            if ([m.commonKey isEqualToString:ck]) {
                [out addObject:m];
                break;
            }
    return out;
}

@implementation AVMetadataItem {
@protected
    NSString *_identifier, *_extendedLanguageTag, *_dataType, *_keySpace;
    NSLocale *_locale;
    CMTime _time, _duration;
    id _value, _key;
    NSDictionary *_extraAttributes;
    NSDate *_startDate;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _time = kCMTimeInvalid;
        _duration = kCMTimeInvalid;
    }
    return self;
}


+ (instancetype)_finchItemWithEntry:(AVFMetadataEntry *)entry
{
    AVMetadataItem *m = [[AVMetadataItem alloc] init];
    m->_keySpace = entry->keySpace;
    m->_key = entry->key;
    m->_value = entry->value;
    m->_dataType = entry->dataType;
    m->_identifier = [AVMetadataItem identifierForKey:entry->key keySpace:entry->keySpace];
    if (entry->language)
        m->_locale = [NSLocale localeWithLocaleIdentifier:entry->language];
    return m;
}

- (id)copyWithZone:(NSZone *)zone { return self; }

/* (an immutable copy of a mutable item) */
- (void)_finchTakeFrom:(AVMetadataItem *)o
{
    _identifier = o->_identifier;
    _extendedLanguageTag = o->_extendedLanguageTag;
    _dataType = o->_dataType;
    _keySpace = o->_keySpace;
    _locale = o->_locale;
    _time = o->_time;
    _duration = o->_duration;
    _value = o->_value;
    _key = o->_key;
    _extraAttributes = o->_extraAttributes;
    _startDate = o->_startDate;
}

- (id)mutableCopyWithZone:(NSZone *)zone
{
    AVMutableMetadataItem *m = [AVMutableMetadataItem metadataItem];
    m.keySpace = _keySpace;
    m.key = _key;
    m.identifier = _identifier;
    m.value = _value;
    m.dataType = _dataType;
    m.locale = _locale;
    m.extendedLanguageTag = _extendedLanguageTag;
    m.time = _time;
    m.duration = _duration;
    m.extraAttributes = _extraAttributes;
    m.startDate = _startDate;
    return m;
}

- (AVMetadataIdentifier)identifier { return _identifier; }
- (NSString *)extendedLanguageTag { return _extendedLanguageTag; }
- (NSLocale *)locale { return _locale; }
- (CMTime)time { return _time; }
- (CMTime)duration { return _duration; }
- (NSString *)dataType { return _dataType; }
- (id<NSObject, NSCopying>)value { return _value; }
- (NSDictionary *)extraAttributes { return _extraAttributes; }
- (NSDate *)startDate { return _startDate; }
- (id<NSObject, NSCopying>)key { return _key; }
- (AVMetadataKeySpace)keySpace { return _keySpace; }
- (AVMetadataKey)commonKey { return AVFCommonKeyFor(_key, _keySpace); }

- (NSString *)stringValue
{
    if ([_value isKindOfClass:[NSString class]])
        return _value;
    if ([_value isKindOfClass:[NSNumber class]])
        return [_value stringValue];
    if ([_value isKindOfClass:[NSDate class]])
        return [[[NSISO8601DateFormatter alloc] init] stringFromDate:_value];
    return nil;
}

- (NSNumber *)numberValue
{
    if ([_value isKindOfClass:[NSNumber class]])
        return _value;
    if ([_value isKindOfClass:[NSString class]]) {
        NSScanner *s = [NSScanner scannerWithString:_value];
        double d;
        if ([s scanDouble:&d] && s.atEnd)
            return @(d);
    }
    return nil;
}

- (NSDate *)dateValue
{
    if ([_value isKindOfClass:[NSDate class]])
        return _value;
    if ([_value isKindOfClass:[NSString class]]) {
        NSISO8601DateFormatter *f = [[NSISO8601DateFormatter alloc] init];
        NSDate *d = [f dateFromString:_value];
        if (!d) {
            f.formatOptions = NSISO8601DateFormatWithFullDate;
            d = [f dateFromString:_value];
        }
        return d;
    }
    return nil;
}

- (NSData *)dataValue
{
    if ([_value isKindOfClass:[NSData class]])
        return _value;
    return nil;
}

- (AVKeyValueStatus)statusOfValueForKey:(NSString *)key error:(NSError **)outError { return AVKeyValueStatusLoaded; }

- (void)loadValuesAsynchronouslyForKeys:(NSArray<NSString *> *)keys completionHandler:(void (^)(void))handler
{
    if (handler)
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), handler);
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p, identifier=%@, keySpace=%@, key class = %@, key=%@, commonKey=%@, "
                                      @"extendedLanguageTag=%@, dataType=%@, time=%@, duration=%@, startDate=%@, extras=%@, value=%@>",
                                      NSStringFromClass([self class]), self, _identifier, _keySpace, NSStringFromClass([_key class]),
                                      _key, self.commonKey, _extendedLanguageTag, _dataType,
                                      CMTIME_IS_VALID(_time) ? @(CMTimeGetSeconds(_time)) : @"invalid",
                                      CMTIME_IS_VALID(_duration) ? @(CMTimeGetSeconds(_duration)) : @"invalid", _startDate,
                                      _extraAttributes, _value];
}

#pragma mark Identifiers

+ (AVMetadataIdentifier)identifierForKey:(id)key keySpace:(AVMetadataKeySpace)keySpace
{
    if (!key || !keySpace)
        return nil;
    for (size_t i = 0; i < AVFIdentifierTableCount; i++) {
        const AVFIdentifierInfo *e = &AVFIdentifierTable[i];
        if (strcmp(e->keySpace, keySpace.UTF8String))
            continue;
        if (e->stringKey ? [[key description] isEqualToString:@(e->stringKey)] : (code_key_space(keySpace) && code_of(key) == e->codeKey))
            return @(e->identifier);
    }
    NSString *k = code_key_space(keySpace) ? AVFKeyString(code_of(key)) : [key description];
    return [NSString stringWithFormat:@"%@/%@", prefix_for_key_space(keySpace), k];
}

+ (AVMetadataKeySpace)keySpaceForIdentifier:(AVMetadataIdentifier)identifier
{
    for (size_t i = 0; i < AVFIdentifierTableCount; i++)
        if ([identifier isEqualToString:@(AVFIdentifierTable[i].identifier)])
            return @(AVFIdentifierTable[i].keySpace);
    NSRange slash = [identifier rangeOfString:@"/"];
    return slash.location == NSNotFound ? nil : key_space_for_prefix([identifier substringToIndex:slash.location]);
}

+ (id)keyForIdentifier:(AVMetadataIdentifier)identifier
{
    for (size_t i = 0; i < AVFIdentifierTableCount; i++) {
        const AVFIdentifierInfo *e = &AVFIdentifierTable[i];
        if ([identifier isEqualToString:@(e->identifier)])
            return e->stringKey ? @(e->stringKey) : @((int32_t)e->codeKey);
    }
    NSRange slash = [identifier rangeOfString:@"/"];
    if (slash.location == NSNotFound)
        return nil;
    NSString *keySpace = key_space_for_prefix([identifier substringToIndex:slash.location]);
    NSString *k = [identifier substringFromIndex:NSMaxRange(slash)];
    if (!code_key_space(keySpace))
        return k;
    /* %XX escapes back to bytes, then the code */
    NSMutableData *bytes = [NSMutableData data];
    for (NSUInteger i = 0; i < k.length;) {
        unichar c = [k characterAtIndex:i];
        if (c == '%' && i + 2 < k.length) {
            unsigned v = 0;
            [[NSScanner scannerWithString:[k substringWithRange:NSMakeRange(i + 1, 2)]] scanHexInt:&v];
            uint8_t b = (uint8_t)v;
            [bytes appendBytes:&b length:1];
            i += 3;
        } else {
            uint8_t b = (uint8_t)c;
            [bytes appendBytes:&b length:1];
            i++;
        }
    }
    if (bytes.length != 4)
        return k;
    const uint8_t *b = bytes.bytes;
    return @((int32_t)((uint32_t)b[0] << 24 | (uint32_t)b[1] << 16 | (uint32_t)b[2] << 8 | b[3]));
}

#pragma mark Filtering

+ (NSArray<AVMetadataItem *> *)metadataItemsFromArray:(NSArray<AVMetadataItem *> *)items withLocale:(NSLocale *)locale
{
    NSMutableArray *out = [NSMutableArray array];
    for (AVMetadataItem *m in items)
        if ([m.locale.localeIdentifier isEqualToString:locale.localeIdentifier])
            [out addObject:m];
    return out;
}

+ (NSArray<AVMetadataItem *> *)metadataItemsFromArray:(NSArray<AVMetadataItem *> *)items withKey:(id)key keySpace:(AVMetadataKeySpace)keySpace
{
    NSMutableArray *out = [NSMutableArray array];
    for (AVMetadataItem *m in items) {
        BOOL keyMatches = !key;
        if (key) {
            if ([keySpace isEqualToString:AVMetadataKeySpaceCommon])
                keyMatches = [m.commonKey isEqual:key];
            else
                keyMatches = [m.key isEqual:key] || (code_key_space(m.keySpace) && code_of(m.key) == code_of(key) && code_of(key));
        }
        BOOL spaceMatches = !keySpace || [keySpace isEqualToString:AVMetadataKeySpaceCommon] || [m.keySpace isEqualToString:keySpace];
        if (keyMatches && spaceMatches)
            [out addObject:m];
    }
    return out;
}

+ (NSArray<AVMetadataItem *> *)metadataItemsFromArray:(NSArray<AVMetadataItem *> *)items filteredByIdentifier:(AVMetadataIdentifier)identifier
{
    NSMutableArray *out = [NSMutableArray array];
    for (AVMetadataItem *m in items)
        if ([m.identifier isEqualToString:identifier])
            [out addObject:m];
    return out;
}

+ (NSArray<AVMetadataItem *> *)metadataItemsFromArray:(NSArray<AVMetadataItem *> *)items
             filteredAndSortedAccordingToPreferredLanguages:(NSArray<NSString *> *)languages
{
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *lang in languages)
        for (AVMetadataItem *m in items) {
            NSString *code = m.locale.languageCode ?: m.extendedLanguageTag;
            if (code && [lang hasPrefix:code] && ![out containsObject:m])
                [out addObject:m];
        }
    return out;
}

+ (NSArray<AVMetadataItem *> *)metadataItemsFromArray:(NSArray<AVMetadataItem *> *)items filteredByMetadataItemFilter:(AVMetadataItemFilter *)filter
{
    return items;
}

+ (AVMetadataItem *)metadataItemWithPropertiesOfMetadataItem:(AVMetadataItem *)metadataItem
                                         valueLoadingHandler:(void (^)(AVMetadataItemValueRequest *))handler
{
    return [metadataItem copy];
}

@end

@implementation AVMutableMetadataItem

+ (AVMutableMetadataItem *)metadataItem { return [[self alloc] init]; }

- (id)copyWithZone:(NSZone *)zone
{
    AVMetadataItem *m = [[AVMetadataItem alloc] init];
    [m _finchTakeFrom:self];
    return m;
}

- (void)setIdentifier:(AVMetadataIdentifier)identifier
{
    _identifier = [identifier copy];
    if (identifier) {
        _keySpace = [AVMetadataItem keySpaceForIdentifier:identifier];
        _key = [AVMetadataItem keyForIdentifier:identifier];
    }
}

- (void)setKeySpace:(AVMetadataKeySpace)keySpace
{
    _keySpace = [keySpace copy];
    _identifier = _key && _keySpace ? [AVMetadataItem identifierForKey:_key keySpace:_keySpace] : nil;
}

- (void)setKey:(id<NSObject, NSCopying>)key
{
    _key = [(id)key copyWithZone:nil];
    _identifier = _key && _keySpace ? [AVMetadataItem identifierForKey:_key keySpace:_keySpace] : nil;
}

- (void)setExtendedLanguageTag:(NSString *)tag { _extendedLanguageTag = [tag copy]; }
- (void)setLocale:(NSLocale *)locale { _locale = [locale copy]; }
- (void)setTime:(CMTime)time { _time = time; }
- (void)setDuration:(CMTime)duration { _duration = duration; }
- (void)setDataType:(NSString *)dataType { _dataType = [dataType copy]; }
- (void)setValue:(id<NSObject, NSCopying>)value { _value = [(id)value copyWithZone:nil]; }
- (void)setExtraAttributes:(NSDictionary *)extraAttributes { _extraAttributes = [extraAttributes copy]; }
- (void)setStartDate:(NSDate *)startDate { _startDate = [startDate copy]; }

@end

@implementation AVMetadataItemFilter
+ (AVMetadataItemFilter *)metadataItemFilterForSharing { return [[self alloc] init]; }
@end

@implementation AVMetadataItemValueRequest
- (AVMetadataItem *)metadataItem { return nil; }
- (void)respondWithValue:(id<NSObject, NSCopying>)value {}
- (void)respondWithError:(NSError *)error {}
@end
