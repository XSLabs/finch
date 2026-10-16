/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Search the items written by CSSearchableIndex. Queries run away from the caller's thread. */
#import "CoreSpotlight_Finch.h"

@interface CSSuggestion (FinchInit)
- (instancetype)initWithFinchString:(NSString *)string kind:(CSSuggestionKind)kind;
@end

@interface CSUserQuery (FinchCount)
- (void)_finchSetFoundSuggestionCount:(NSInteger)count;
@end

static NSString *
query_key(NSString *key)
{
    static NSDictionary *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @{ @"kMDItemTitle" : @"title", @"kMDItemDisplayName" : @"displayName", @"kMDItemTextContent" : @"textContent",
                   @"kMDItemContentType" : @"contentType", @"kMDItemContentTypeTree" : @"contentTypeTree", @"kMDItemKind" : @"kind",
                   @"_kMDItemExternalID" : @"uniqueIdentifier", @"kMDItemUniqueIdentifier" : @"uniqueIdentifier",
                   @"kMDItemAuthors" : @"authors", @"kMDItemKeywords" : @"keywords" };
    });
    return names[key] ?: key;
}

static NSArray<NSString *> *
strings_for_value(id value)
{
    if (!value || value == [NSNull null])
        return @[];
    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableArray *strings = [NSMutableArray array];
        for (id entry in value)
            [strings addObjectsFromArray:strings_for_value(entry)];
        return strings;
    }
    if ([value isKindOfClass:[CSPerson class]]) {
        CSPerson *person = value;
        return [@[ person.displayName ?: @"" ] arrayByAddingObjectsFromArray:person.handles ?: @[]];
    }
    if ([value isKindOfClass:[NSURL class]])
        return @[ [value absoluteString] ?: @"" ];
    if ([value isKindOfClass:[NSString class]])
        return @[ value ];
    if ([value respondsToSelector:@selector(stringValue)])
        return @[ [value stringValue] ?: @"" ];
    return @[ [value description] ?: @"" ];
}

static NSString *
item_text(CSSearchableItem *item)
{
    NSMutableArray *values = [NSMutableArray array];
    for (NSString *key in @[ @"title", @"displayName", @"textContent", @"contentDescription", @"subject", @"kind", @"keywords",
                             @"authors", @"authorNames", @"artist", @"album", @"emailAddresses", @"phoneNumbers" ])
        [values addObjectsFromArray:strings_for_value([item.attributeSet valueForKey:key])];
    return [values componentsJoinedByString:@" "];
}

static BOOL
match_condition(CSSearchableItem *item, NSString *condition)
{
    NSString *pattern = @"^\\s*([A-Za-z_][A-Za-z0-9_.]*)\\s*(==|!=|CONTAINS|LIKE|BEGINSWITH|ENDSWITH|=)\\s*['\"](.*?)['\"]\\s*(?:\\[[cCdD]+\\])?\\s*$";
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:NULL];
    NSTextCheckingResult *match = [regex firstMatchInString:condition options:0 range:NSMakeRange(0, condition.length)];
    if (!match)
        return NO;
    NSString *key = query_key([condition substringWithRange:[match rangeAtIndex:1]]);
    NSString *op = [[condition substringWithRange:[match rangeAtIndex:2]] uppercaseString];
    NSString *expected = [condition substringWithRange:[match rangeAtIndex:3]];
    id value = [key isEqualToString:@"uniqueIdentifier"] ? item.uniqueIdentifier : [item.attributeSet valueForKey:key];
    NSArray<NSString *> *values = strings_for_value(value);
    BOOL found = NO;
    BOOL wildcard = [expected containsString:@"*"];
    NSString *needle = [expected stringByReplacingOccurrencesOfString:@"*" withString:@""];
    for (NSString *candidate in values) {
        NSStringCompareOptions options = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch;
        NSRange range = [candidate rangeOfString:needle options:options];
        if ([op isEqualToString:@"CONTAINS"] || [op isEqualToString:@"LIKE"] || wildcard)
            found = range.location != NSNotFound;
        else if ([op isEqualToString:@"BEGINSWITH"])
            found = [candidate rangeOfString:expected options:options | NSAnchoredSearch].location == 0;
        else if ([op isEqualToString:@"ENDSWITH"])
            found = range.location != NSNotFound && NSMaxRange(range) == candidate.length;
        else
            found = [candidate compare:expected options:options] == NSOrderedSame;
        if (found)
            break;
    }
    return [op isEqualToString:@"!="] ? !found : found;
}

static BOOL
matches_expression(CSSearchableItem *item, NSString *expression)
{
    NSString *trimmed = [expression stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!trimmed.length)
        return YES;
    NSArray<NSString *> *orGroups = [trimmed componentsSeparatedByString:@"||"];
    BOOL hasCondition = NO;
    for (NSString *group in orGroups) {
        NSArray<NSString *> *andParts = [group componentsSeparatedByString:@"&&"];
        BOOL all = YES;
        for (NSString *part in andParts) {
            NSString *condition = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (!condition.length)
                continue;
            hasCondition = YES;
            if (!match_condition(item, condition)) {
                all = NO;
                break;
            }
        }
        if (all && hasCondition)
            return YES;
    }
    if (hasCondition)
        return NO;
    NSString *plain = [[trimmed stringByReplacingOccurrencesOfString:@"\"" withString:@""]
                           stringByReplacingOccurrencesOfString:@"*" withString:@""];
    NSString *text = item_text(item);
    for (NSString *word in [plain componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]])
        if (word.length && [text rangeOfString:word options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location == NSNotFound)
            return NO;
    return YES;
}

static NSArray<CSSearchableItem *> *
matching_items(NSString *query, CSSearchQueryContext *context)
{
    NSMutableArray *items = [NSMutableArray array];
    for (CSSearchableItem *item in FinchCSSearchAllItems()) {
        if (!matches_expression(item, query))
            continue;
        BOOL passesFilters = YES;
        for (NSString *filter in context.filterQueries)
            if (!matches_expression(item, filter)) {
                passesFilters = NO;
                break;
            }
        if (passesFilters)
            [items addObject:item];
    }
    [items sortUsingComparator:^NSComparisonResult(CSSearchableItem *a, CSSearchableItem *b) { return [a compareByRank:b]; }];
    return items;
}

@implementation CSSearchQueryContext {
    NSArray<NSString *> *_fetchAttributes, *_filterQueries;
    NSString *_keyboardLanguage;
    CSSearchQuerySourceOptions _sourceOptions;
}
+ (BOOL)supportsSecureCoding { return YES; }
- (instancetype)init
{
    if ((self = [super init])) {
        _fetchAttributes = @[];
        _filterQueries = @[];
        _sourceOptions = CSSearchQuerySourceOptionDefault;
    }
    return self;
}
- (NSArray *)fetchAttributes { return _fetchAttributes; }
- (void)setFetchAttributes:(NSArray *)value { _fetchAttributes = [value copy] ?: @[]; }
- (NSArray *)filterQueries { return _filterQueries; }
- (void)setFilterQueries:(NSArray *)value { _filterQueries = [value copy] ?: @[]; }
- (NSString *)keyboardLanguage { return _keyboardLanguage; }
- (void)setKeyboardLanguage:(NSString *)value { _keyboardLanguage = [value copy]; }
- (CSSearchQuerySourceOptions)sourceOptions { return _sourceOptions; }
- (void)setSourceOptions:(CSSearchQuerySourceOptions)value { _sourceOptions = value; }
- (id)copyWithZone:(NSZone *)zone
{
    CSSearchQueryContext *copy = [[[self class] allocWithZone:zone] init];
    copy.fetchAttributes = _fetchAttributes;
    copy.filterQueries = _filterQueries;
    copy.keyboardLanguage = _keyboardLanguage;
    copy.sourceOptions = _sourceOptions;
    return copy;
}
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_fetchAttributes forKey:@"fetchAttributes"];
    [coder encodeObject:_filterQueries forKey:@"filterQueries"];
    [coder encodeObject:_keyboardLanguage forKey:@"keyboardLanguage"];
    [coder encodeInteger:_sourceOptions forKey:@"sourceOptions"];
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [self init])) {
        NSSet *classes = [NSSet setWithObjects:[NSArray class], [NSString class], nil];
        _fetchAttributes = [coder decodeObjectOfClasses:classes forKey:@"fetchAttributes"] ?: @[];
        _filterQueries = [coder decodeObjectOfClasses:classes forKey:@"filterQueries"] ?: @[];
        _keyboardLanguage = [coder decodeObjectOfClass:[NSString class] forKey:@"keyboardLanguage"];
        _sourceOptions = [coder decodeIntegerForKey:@"sourceOptions"];
    }
    return self;
}
@end

@interface CSUserQuery ()
- (instancetype)initWithQueryString:(NSString *)query queryContext:(CSSearchQueryContext *)context NS_DESIGNATED_INITIALIZER;
@end

@interface CSSearchQuery ()
- (void)_finchStartReturningSuggestions:(BOOL)suggestions;
@end

@implementation CSSearchQuery {
    NSString *_queryString;
    CSSearchQueryContext *_queryContext;
    BOOL _cancelled, _started, _finished;
    NSUInteger _foundItemCount;
    void (^_foundItemsHandler)(NSArray<CSSearchableItem *> *);
    void (^_completionHandler)(NSError *);
    NSArray<NSFileProtectionType> *_protectionClasses;
}

- (instancetype)initWithQueryString:(NSString *)query queryContext:(CSSearchQueryContext *)context
{
    if ((self = [super init])) {
        _queryString = [query copy] ?: @"";
        _queryContext = [context copy] ?: [[CSSearchQueryContext alloc] init];
        _protectionClasses = @[];
    }
    return self;
}
- (instancetype)initWithQueryString:(NSString *)query attributes:(NSArray<NSString *> *)attributes
{
    CSSearchQueryContext *context = [[CSSearchQueryContext alloc] init];
    context.fetchAttributes = attributes ?: @[];
    return [self initWithQueryString:query queryContext:context];
}
- (BOOL)isCancelled { @synchronized(self) { return _cancelled; } }
- (NSUInteger)foundItemCount { @synchronized(self) { return _foundItemCount; } }
- (void (^)(NSArray<CSSearchableItem *> *))foundItemsHandler { return _foundItemsHandler; }
- (void)setFoundItemsHandler:(void (^)(NSArray<CSSearchableItem *> *))handler { _foundItemsHandler = [handler copy]; }
- (void (^)(NSError *))completionHandler { return _completionHandler; }
- (void)setCompletionHandler:(void (^)(NSError *))handler { _completionHandler = [handler copy]; }
- (NSArray<NSFileProtectionType> *)protectionClasses { return _protectionClasses; }
- (void)setProtectionClasses:(NSArray<NSFileProtectionType> *)classes { _protectionClasses = [classes copy] ?: @[]; }

- (void)_finchStartReturningSuggestions:(BOOL)includeSuggestions
{
    @synchronized(self) {
        if (_started)
            return;
        _started = YES;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<CSSearchableItem *> *items = matching_items(self->_queryString, self->_queryContext);
        NSMutableArray *suggestions = [NSMutableArray array];
        NSMutableSet *seenTitles = [NSMutableSet set];
        for (CSSearchableItem *item in items) {
            @synchronized(self) { if (self->_cancelled) break; }
            @synchronized(self) { self->_foundItemCount++; }
            void (^found)(NSArray *) = self->_foundItemsHandler;
            if (found)
                found(@[ FinchCSSearchableItemWithFetchedAttributes(item, self->_queryContext.fetchAttributes) ]);
            if (includeSuggestions) {
                NSString *title = item.attributeSet.title ?: item.attributeSet.displayName;
                if (title.length && ![seenTitles containsObject:title]) {
                    [seenTitles addObject:title];
                    [suggestions addObject:[[CSSuggestion alloc] initWithFinchString:title kind:CSSuggestionKindDefault]];
                }
            }
        }
        if (includeSuggestions && [self isKindOfClass:[CSUserQuery class]]) {
            CSUserQuery *userQuery = (CSUserQuery *)self;
            void (^handler)(NSArray *) = userQuery.foundSuggestionsHandler;
            if (handler && suggestions.count)
                handler(suggestions);
            [userQuery _finchSetFoundSuggestionCount:(NSInteger)suggestions.count];
        }
        BOOL cancelled = NO;
        @synchronized(self) {
            self->_finished = YES;
            cancelled = self->_cancelled;
        }
        void (^completion)(NSError *) = self->_completionHandler;
        NSError *error = cancelled ? [NSError errorWithDomain:CSSearchQueryErrorDomain
                                                          code:CSSearchQueryErrorCodeCancelled userInfo:nil] : nil;
        if (completion)
            completion(error);
    });
}
- (void)start { [self _finchStartReturningSuggestions:NO]; }
- (void)cancel { @synchronized(self) { if (!_finished) _cancelled = YES; } }
@end

@implementation CSSuggestion {
    NSAttributedString *_localizedAttributedSuggestion;
    CSSuggestionKind _suggestionKind;
}
+ (BOOL)supportsSecureCoding { return YES; }
- (instancetype)initWithFinchString:(NSString *)string kind:(CSSuggestionKind)kind
{
    if ((self = [super init])) {
        _localizedAttributedSuggestion = [[NSAttributedString alloc] initWithString:string ?: @""];
        _suggestionKind = kind;
    }
    return self;
}
- (NSAttributedString *)localizedAttributedSuggestion { return _localizedAttributedSuggestion; }
- (CSSuggestionKind)suggestionKind { return _suggestionKind; }
- (NSComparisonResult)compareByRank:(CSSuggestion *)other { return [self compare:other]; }
- (NSComparisonResult)compare:(CSSuggestion *)other
{
    return [[_localizedAttributedSuggestion string] localizedCaseInsensitiveCompare:[other.localizedAttributedSuggestion string]];
}
- (id)copyWithZone:(NSZone *)zone { return self; }
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_localizedAttributedSuggestion forKey:@"suggestion"];
    [coder encodeInteger:_suggestionKind forKey:@"kind"];
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSAttributedString *string = [coder decodeObjectOfClass:[NSAttributedString class] forKey:@"suggestion"];
    return [self initWithFinchString:string.string kind:[coder decodeIntegerForKey:@"kind"]];
}
@end

@implementation CSUserQueryContext {
    CSSuggestion *_currentSuggestion;
    BOOL _enableRankedResults, _disableSemanticSearch;
    NSInteger _maxResultCount, _maxSuggestionCount, _maxRankedResultCount;
}
+ (instancetype)userQueryContext { return [[self alloc] init]; }
+ (instancetype)userQueryContextWithCurrentSuggestion:(CSSuggestion *)suggestion
{
    CSUserQueryContext *context = [[self alloc] init];
    context->_currentSuggestion = suggestion;
    return context;
}
- (instancetype)init
{
    if ((self = [super init])) {
        _enableRankedResults = YES;
        _maxResultCount = 100;
        _maxSuggestionCount = 10;
        _maxRankedResultCount = 10;
    }
    return self;
}
- (BOOL)enableRankedResults { return _enableRankedResults; }
- (void)setEnableRankedResults:(BOOL)value { _enableRankedResults = value; }
- (BOOL)disableSemanticSearch { return _disableSemanticSearch; }
- (void)setDisableSemanticSearch:(BOOL)value { _disableSemanticSearch = value; }
- (NSInteger)maxResultCount { return _maxResultCount; }
- (void)setMaxResultCount:(NSInteger)value { _maxResultCount = MAX(0, value); }
- (NSInteger)maxSuggestionCount { return _maxSuggestionCount; }
- (void)setMaxSuggestionCount:(NSInteger)value { _maxSuggestionCount = MAX(0, value); }
- (NSInteger)maxRankedResultCount { return _maxRankedResultCount; }
- (void)setMaxRankedResultCount:(NSInteger)value { _maxRankedResultCount = MAX(0, value); }
@end

@implementation CSUserQuery {
    NSInteger _foundSuggestionCount;
    void (^_foundSuggestionsHandler)(NSArray<CSSuggestion *> *);
}
+ (void)prepare {}
+ (void)prepareProtectionClasses:(NSArray<NSFileProtectionType> *)protectionClasses { (void)protectionClasses; }
- (instancetype)initWithUserQueryString:(NSString *)query userQueryContext:(CSUserQueryContext *)context
{
    return [super initWithQueryString:query ?: @"" queryContext:context];
}
- (instancetype)initWithQueryString:(NSString *)query queryContext:(CSSearchQueryContext *)context
{
    return [super initWithQueryString:query queryContext:context];
}
- (NSInteger)foundSuggestionCount { return _foundSuggestionCount; }
- (void)_finchSetFoundSuggestionCount:(NSInteger)count { _foundSuggestionCount = count; }
- (void (^)(NSArray<CSSuggestion *> *))foundSuggestionsHandler { return _foundSuggestionsHandler; }
- (void)setFoundSuggestionsHandler:(void (^)(NSArray<CSSuggestion *> *))handler { _foundSuggestionsHandler = [handler copy]; }
- (void)start { [self _finchStartReturningSuggestions:YES]; }
- (void)cancel { [super cancel]; }
- (void)userEngagedWithItem:(CSSearchableItem *)item visibleItems:(NSArray<CSSearchableItem *> *)visibleItems userInteractionType:(CSUserInteraction)type
{
    (void)visibleItems;
    (void)type;
    item.attributeSet.rankingHint = @([item.attributeSet.rankingHint doubleValue] + 1.0);
    item.isUpdate = YES;
    [[CSSearchableIndex defaultSearchableIndex] indexSearchableItems:@[ item ] completionHandler:nil];
}
- (void)userEngagedWithSuggestion:(CSSuggestion *)suggestion visibleSuggestions:(NSArray<CSSuggestion *> *)visibleSuggestions userInteractionType:(CSUserInteraction)type
{
    (void)suggestion;
    (void)visibleSuggestions;
    (void)type;
}
@end
