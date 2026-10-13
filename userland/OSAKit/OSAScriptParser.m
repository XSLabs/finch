/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * OSAKit: the script outline parser, Finch's. Script Editor's navigation bar lists a
 * script's handlers, properties and script objects; this finds them line by line (a
 * handler runs from "on name" or "to name" to its "end"), with the source ranges of each
 * and of its name. Also the terminology manager (its cache of terms).
 */
#import "OSAKit_Finch.h"

@implementation OSAScriptElement

+ (instancetype)element { return [self new]; }

- (instancetype)init
{
    if ((self = [super init]))
        _subElements = [NSMutableArray array];
    return self;
}

- (NSString *)title { return _name ?: @""; }

- (instancetype)initWithCoder:(NSCoder *)c
{
    if ((self = [self init])) {
        _name = [c decodeObjectForKey:@"name"];
        _text = [c decodeObjectForKey:@"text"];
        _range = [[c decodeObjectOfClass:[NSValue class] forKey:@"range"] rangeValue];
        _nameRange = [[c decodeObjectOfClass:[NSValue class] forKey:@"nameRange"] rangeValue];
        _subElements = [[c decodeObjectForKey:@"subElements"] mutableCopy] ?: [NSMutableArray array];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)c
{
    [c encodeObject:_name forKey:@"name"];
    [c encodeObject:_text forKey:@"text"];
    [c encodeObject:[NSValue valueWithRange:_range] forKey:@"range"];
    [c encodeObject:[NSValue valueWithRange:_nameRange] forKey:@"nameRange"];
    [c encodeObject:_subElements forKey:@"subElements"];
}

- (NSString *)description { return [NSString stringWithFormat:@"<%@ %@ %@>", self.class, _name, NSStringFromRange(_range)]; }
@end

@implementation OSAPropertyElement
@end
@implementation OSAGlobalElement
@end
@implementation OSAScriptObjectElement
@end

@implementation OSAHandlerElement
- (NSString *)title { return self.name ?: @""; }
@end
@implementation OSAEventHandlerElement
@end
@implementation OSACommandHandlerElement
@end

@implementation OSAScriptParser

+ (NSArray<NSString *> *)keywords
{
    return @[
        @"about", @"above", @"after", @"against", @"and", @"apart from", @"around", @"as", @"aside from", @"at", @"back", @"before",
        @"beginning", @"behind", @"below", @"beneath", @"beside", @"between", @"but", @"by", @"considering", @"contain", @"contains",
        @"continue", @"copy", @"div", @"does", @"eighth", @"else", @"end", @"equal", @"equals", @"error", @"every", @"exit", @"false",
        @"fifth", @"first", @"for", @"fourth", @"from", @"front", @"get", @"given", @"global", @"if", @"ignoring", @"in", @"instead of",
        @"into", @"is", @"it", @"its", @"last", @"local", @"me", @"middle", @"mod", @"my", @"ninth", @"not", @"of", @"on", @"onto",
        @"or", @"out of", @"over", @"prop", @"property", @"put", @"ref", @"reference", @"repeat", @"return", @"returning", @"script",
        @"second", @"set", @"seventh", @"since", @"sixth", @"some", @"tell", @"tenth", @"that", @"the", @"then", @"third", @"through",
        @"thru", @"timeout", @"times", @"to", @"transaction", @"true", @"try", @"until", @"where", @"while", @"whose", @"with", @"without"
    ];
}

+ (instancetype)parserWithText:(NSString *)text { return [[self alloc] initWithText:text]; }
+ (instancetype)parserWithScript:(OSAScript *)script { return [[self alloc] initWithScript:script]; }
- (instancetype)init { return [self initWithText:@""]; }

- (instancetype)initWithText:(NSString *)text
{
    if ((self = [super init])) {
        _text = [text copy] ?: @"";
        _needsParsed = YES;
    }
    return self;
}

- (instancetype)initWithScript:(OSAScript *)script
{
    if ((self = [self initWithText:script.source]))
        _script = script;
    return self;
}

- (void)setText:(NSString *)text
{
    _text = [text copy];
    _needsParsed = YES;
}

- (void)setScript:(OSAScript *)script
{
    _script = script;
    self.text = script.source;
}

- (OSAScriptElement *)element
{
    if (_needsParsed)
        [self parse];
    return _element;
}

/* the words of a line (letters, digits, underscores, |barred|) with their ranges */
static NSArray<NSValue *> *
words(NSString *s, NSRange line)
{
    NSMutableArray *out = [NSMutableArray array];
    NSUInteger i = line.location, end = NSMaxRange(line);
    NSMutableCharacterSet *w = [NSMutableCharacterSet alphanumericCharacterSet];
    [w addCharactersInString:@"_"];
    while (i < end) {
        unichar c = [s characterAtIndex:i];
        if (c == '-' && i + 1 < end && [s characterAtIndex:i + 1] == '-')
            break;
        if (c == '"') {
            NSUInteger j = i + 1;
            while (j < end && [s characterAtIndex:j] != '"')
                j += [s characterAtIndex:j] == '\\' ? 2 : 1;
            i = j + 1;
            continue;
        }
        if (c == '|') {
            NSUInteger j = i + 1;
            while (j < end && [s characterAtIndex:j] != '|')
                j++;
            [out addObject:[NSValue valueWithRange:NSMakeRange(i, MIN(j + 1, end) - i)]];
            i = j + 1;
            continue;
        }
        if ([w characterIsMember:c]) {
            NSUInteger j = i;
            while (j < end && [w characterIsMember:[s characterAtIndex:j]])
                j++;
            [out addObject:[NSValue valueWithRange:NSMakeRange(i, j - i)]];
            i = j;
            continue;
        }
        i++;
    }
    return out;
}

- (BOOL)parse
{
    NSString *s = _text ?: @"";
    OSAScriptElement *root = [OSAScriptObjectElement element];
    root.range = NSMakeRange(0, s.length);
    root.rangeOfSubElements = root.range;
    root.text = s;
    NSMutableArray<OSAScriptElement *> *stack = [NSMutableArray arrayWithObject:root];
    NSMutableArray<NSString *> *blocks = [NSMutableArray array]; /* what each open block is, "" for control blocks */
    NSUInteger pos = 0;
    while (pos < s.length) {
        NSRange line = [s lineRangeForRange:NSMakeRange(pos, 0)];
        pos = NSMaxRange(line);
        NSArray<NSValue *> *ws = words(s, line);
        if (!ws.count)
            continue;
        NSString *(^word)(NSUInteger) = ^NSString *(NSUInteger k) {
            return k < ws.count ? [s substringWithRange:ws[k].rangeValue].lowercaseString : @"";
        };
        NSString *w0 = word(0), *w1 = word(1);
        NSString *trimmed = [[s substringWithRange:line] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        OSAScriptElement *top = stack.lastObject;
        if ([w0 isEqualToString:@"end"]) {
            NSString *b = blocks.lastObject;
            if (blocks.count)
                [blocks removeLastObject];
            if (b.length && stack.count > 1) {
                OSAScriptElement *e = stack.lastObject;
                [stack removeLastObject];
                e.range = NSMakeRange(e.range.location, NSMaxRange(line) - e.range.location);
                if (NSMaxRange(line) < e.range.location)
                    e.range = NSMakeRange(e.range.location, 0);
                e.rangeOfSubElements = NSMakeRange(NSMaxRange(e.nameRange), NSMaxRange(line) - NSMaxRange(e.nameRange));
                e.text = [s substringWithRange:e.range];
            }
            continue;
        }
        if (([w0 isEqualToString:@"on"] || [w0 isEqualToString:@"to"]) && ws.count > 1 && ![w1 isEqualToString:@"error"]) {
            OSAHandlerElement *h = [@[ @"run", @"open", @"idle", @"quit", @"reopen" ] containsObject:w1] ? [OSAEventHandlerElement element]
                                                                                                          : [OSAHandlerElement element];
            h.nameRange = ws[1].rangeValue;
            h.name = [s substringWithRange:h.nameRange];
            /* a handler's range is its body: from the line after "on" through its "end" */
            h.range = NSMakeRange(NSMaxRange(line), 0);
            [top.subElements addObject:h];
            [stack addObject:h];
            [blocks addObject:@"handler"];
            continue;
        }
        if ([w0 isEqualToString:@"script"] && ws.count > 1) {
            OSAScriptObjectElement *o = [OSAScriptObjectElement element];
            o.nameRange = ws[1].rangeValue;
            o.name = [s substringWithRange:o.nameRange];
            o.range = line;
            [top.subElements addObject:o];
            [stack addObject:o];
            [blocks addObject:@"script"];
            continue;
        }
        if (([w0 isEqualToString:@"property"] || [w0 isEqualToString:@"prop"]) && ws.count > 1) {
            OSAPropertyElement *p = [OSAPropertyElement element];
            p.nameRange = ws[1].rangeValue;
            p.name = [s substringWithRange:p.nameRange];
            p.range = line;
            p.text = trimmed;
            [top.subElements addObject:p];
            continue;
        }
        if ([w0 isEqualToString:@"global"]) {
            for (NSUInteger k = 1; k < ws.count; k++) {
                /* (Apple's leaves a global's name unset) */
                OSAGlobalElement *g = [OSAGlobalElement element];
                g.nameRange = ws[k].rangeValue;
                g.range = line;
                g.text = trimmed;
                [top.subElements addObject:g];
            }
            continue;
        }
        /* control blocks, so their "end" isn't taken for a handler's */
        NSString *lastWord = word(ws.count - 1);
        BOOL opens = ([w0 isEqualToString:@"if"] && [lastWord isEqualToString:@"then"]) ||
                     [w0 isEqualToString:@"repeat"] || [w0 isEqualToString:@"try"] || [w0 isEqualToString:@"considering"] ||
                     [w0 isEqualToString:@"ignoring"] || ([w0 isEqualToString:@"using"] && [w1 isEqualToString:@"terms"]) ||
                     ([w0 isEqualToString:@"with"] && ([w1 isEqualToString:@"timeout"] || [w1 isEqualToString:@"transaction"]));
        if ([w0 isEqualToString:@"tell"]) {
            BOOL to = NO;
            for (NSUInteger k = 1; k < ws.count; k++)
                if ([word(k) isEqualToString:@"to"])
                    to = YES;
            opens = !to;
        }
        if (opens)
            [blocks addObject:@""];
    }
    _element = root;
    _needsParsed = NO;
    return YES;
}

- (NSArray<NSString *> *)eventHandlerNames
{
    NSMutableArray *out = [NSMutableArray array];
    for (OSAScriptElement *e in self.element.subElements)
        if ([e isKindOfClass:[OSAHandlerElement class]])
            [out addObject:e.name];
    return out;
}
@end

@implementation OSATerminologyManager

+ (instancetype)sharedTerminologyManager
{
    static OSATerminologyManager *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [OSATerminologyManager new];
    });
    return shared;
}

- (instancetype)init
{
    if ((self = [super init]))
        _terms = [NSMutableArray array];
    return self;
}

- (NSString *)_cachePath
{
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    return [caches stringByAppendingPathComponent:@"com.apple.OSAKit"];
}

- (NSString *)_pathForTerminologyCacheFile { return [self._cachePath stringByAppendingPathComponent:@"Terminology.plist"]; }

- (void)addTerms:(NSArray *)terms
{
    for (id t in terms)
        if (![_terms containsObject:t])
            [_terms addObject:t];
}

- (void)readTerms
{
    NSArray *a = [NSArray arrayWithContentsOfFile:self._pathForTerminologyCacheFile];
    if (a)
        [self addTerms:a];
}

- (void)writeTerms
{
    [[NSFileManager defaultManager] createDirectoryAtPath:self._cachePath withIntermediateDirectories:YES attributes:nil error:NULL];
    [_terms writeToFile:self._pathForTerminologyCacheFile atomically:YES];
}

- (void)_writeTerms { [self writeTerms]; }
@end
