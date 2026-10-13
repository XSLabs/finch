/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Finch's AppleScript: the lexer and parser, Finch's own, for AppleScript's English
 * dialect. Statements: set, copy, if (one line or block, else if, else), repeat (forever,
 * N times, while, until, with i from a to b by c, with x in list), exit repeat, return,
 * handlers (on/to name(params)), try / on error [message] [number n], error, tell
 * (block or "to" one statement), log, global, local, property, and considering /
 * ignoring / using terms from / with timeout blocks (their bodies). Expressions follow
 * AppleScript's precedence: unary, ^, * / div mod, + -, &, as, comparisons (with the
 * English forms), not, and, or. References: item 2 of x, items 2 thru 3 of x, last item,
 * every word, text 2 thru 4 of s, a property of x (length of s, button returned of r),
 * x's property; commands with labelled parameters (display dialog "x" buttons {...}).
 */
#import "ASParser.h"
#import "ASValues.h"

@implementation ASNode
+ (instancetype)kind:(NSString *)kind
{
    ASNode *n = [ASNode new];
    n.kind = kind;
    n.children = [NSMutableArray array];
    n.args = [NSMutableDictionary dictionary];
    return n;
}
@end

/* ---- the lexer ---- */

typedef enum { T_WORD, T_NUM, T_STR, T_OP, T_NL, T_EOF } TokType;

@interface ASToken : NSObject {
@public
    TokType type;
    NSString *text, *lower;
    NSRange range;
    BOOL barred; /* |identifier| */
}
@end
@implementation ASToken
@end

static ASError *
syntax(NSString *msg, NSRange r)
{
    ASError *e = [ASError errorWithNumber:-2741 message:msg];
    e.range = r;
    e.hasRange = YES;
    return e;
}

static NSArray<ASToken *> *
lex(NSString *s)
{
    NSMutableArray *out = [NSMutableArray array];
    NSUInteger i = 0, n = s.length;
    NSCharacterSet *wordStart = [NSCharacterSet letterCharacterSet];
    NSMutableCharacterSet *wordChar = [NSMutableCharacterSet alphanumericCharacterSet];
    [wordChar addCharactersInString:@"_"];
    void (^add)(TokType, NSString *, NSRange) = ^(TokType t, NSString *text, NSRange r) {
        ASToken *k = [ASToken new];
        k->type = t;
        k->text = text;
        k->lower = text.lowercaseString;
        k->range = r;
        [out addObject:k];
    };
    while (i < n) {
        unichar c = [s characterAtIndex:i];
        if (c == '\n' || c == '\r') {
            if (!out.count || ((ASToken *)out.lastObject)->type != T_NL)
                add(T_NL, @"\n", NSMakeRange(i, 1));
            i++;
            continue;
        }
        if (c == ' ' || c == '\t' || c == 0xA0) {
            i++;
            continue;
        }
        if (c == 0xAC) { /* ¬ continues the line */
            i++;
            while (i < n && ([s characterAtIndex:i] == ' ' || [s characterAtIndex:i] == '\t'))
                i++;
            if (i < n && ([s characterAtIndex:i] == '\r' || [s characterAtIndex:i] == '\n'))
                i++;
            continue;
        }
        if (c == '-' && i + 1 < n && [s characterAtIndex:i + 1] == '-') {
            while (i < n && [s characterAtIndex:i] != '\n' && [s characterAtIndex:i] != '\r')
                i++;
            continue;
        }
        if (c == '#' && (i == 0 || [s characterAtIndex:i - 1] == '\n' || [s characterAtIndex:i - 1] == ' ' || [s characterAtIndex:i - 1] == '\t')) {
            while (i < n && [s characterAtIndex:i] != '\n' && [s characterAtIndex:i] != '\r')
                i++;
            continue;
        }
        if (c == '(' && i + 1 < n && [s characterAtIndex:i + 1] == '*') {
            int depth = 0;
            NSUInteger start = i;
            while (i < n) {
                if (i + 1 < n && [s characterAtIndex:i] == '(' && [s characterAtIndex:i + 1] == '*') {
                    depth++;
                    i += 2;
                } else if (i + 1 < n && [s characterAtIndex:i] == '*' && [s characterAtIndex:i + 1] == ')') {
                    depth--;
                    i += 2;
                    if (!depth)
                        break;
                } else
                    i++;
            }
            if (depth)
                @throw syntax(@"Expected “*)” but found end of script.", NSMakeRange(start, n - start));
            continue;
        }
        if (c == '"' || c == 0x201C) {
            NSUInteger start = i++;
            NSMutableString *t = [NSMutableString string];
            BOOL closed = NO;
            while (i < n) {
                unichar d = [s characterAtIndex:i];
                if (d == '\\' && i + 1 < n) {
                    unichar e = [s characterAtIndex:i + 1];
                    unichar c = e == 'n' ? '\n' : e == 't' ? '\t' : e == 'r' ? '\r' : e;
                    [t appendFormat:@"%C", c];
                    i += 2;
                    continue;
                }
                if (d == '"' || d == 0x201D) {
                    closed = YES;
                    i++;
                    break;
                }
                [t appendFormat:@"%C", d];
                i++;
            }
            if (!closed)
                @throw syntax(@"Expected “\"” but found end of script.", NSMakeRange(start, n - start));
            add(T_STR, t, NSMakeRange(start, i - start));
            continue;
        }
        if (c == '|') {
            NSUInteger start = ++i;
            while (i < n && [s characterAtIndex:i] != '|')
                i++;
            add(T_WORD, [s substringWithRange:NSMakeRange(start, i - start)], NSMakeRange(start - 1, i - start + 2));
            ((ASToken *)out.lastObject)->barred = YES;
            i++;
            continue;
        }
        if (c == 0xAB) { /* «raw» */
            NSUInteger start = i;
            while (i < n && [s characterAtIndex:i] != 0xBB)
                i++;
            i++;
            add(T_WORD, [s substringWithRange:NSMakeRange(start, MIN(i, n) - start)], NSMakeRange(start, MIN(i, n) - start));
            continue;
        }
        if ((c >= '0' && c <= '9') || (c == '.' && i + 1 < n && [s characterAtIndex:i + 1] >= '0' && [s characterAtIndex:i + 1] <= '9')) {
            NSUInteger start = i;
            while (i < n && [s characterAtIndex:i] >= '0' && [s characterAtIndex:i] <= '9')
                i++;
            if (i < n && [s characterAtIndex:i] == '.' && i + 1 < n && [s characterAtIndex:i + 1] >= '0' && [s characterAtIndex:i + 1] <= '9') {
                i++;
                while (i < n && [s characterAtIndex:i] >= '0' && [s characterAtIndex:i] <= '9')
                    i++;
            }
            if (i < n && ([s characterAtIndex:i] == 'e' || [s characterAtIndex:i] == 'E')) {
                NSUInteger j = i + 1;
                if (j < n && ([s characterAtIndex:j] == '+' || [s characterAtIndex:j] == '-'))
                    j++;
                if (j < n && [s characterAtIndex:j] >= '0' && [s characterAtIndex:j] <= '9') {
                    i = j;
                    while (i < n && [s characterAtIndex:i] >= '0' && [s characterAtIndex:i] <= '9')
                        i++;
                }
            }
            add(T_NUM, [s substringWithRange:NSMakeRange(start, i - start)], NSMakeRange(start, i - start));
            continue;
        }
        if ([wordStart characterIsMember:c] || c == '_') {
            NSUInteger start = i;
            while (i < n && [wordChar characterIsMember:[s characterAtIndex:i]])
                i++;
            add(T_WORD, [s substringWithRange:NSMakeRange(start, i - start)], NSMakeRange(start, i - start));
            continue;
        }
        if ((c == '\'' || c == 0x2019) && i + 1 < n && ([s characterAtIndex:i + 1] == 's' || [s characterAtIndex:i + 1] == 'S') &&
            (i + 2 >= n || ![wordChar characterIsMember:[s characterAtIndex:i + 2]])) {
            add(T_OP, @"'s", NSMakeRange(i, 2));
            i += 2;
            continue;
        }
        NSString *two = i + 1 < n ? [s substringWithRange:NSMakeRange(i, 2)] : nil;
        if ([@[ @"<=", @">=", @"<>", @"/=" ] containsObject:two ?: @""]) {
            NSString *op = [two isEqualToString:@"<="] ? @"≤" : [two isEqualToString:@">="] ? @"≥" : @"≠";
            add(T_OP, op, NSMakeRange(i, 2));
            i += 2;
            continue;
        }
        if ([@"+-*/^&=≠<>≤≥(){},:÷" rangeOfString:[NSString stringWithCharacters:&c length:1]].location != NSNotFound) {
            add(T_OP, [NSString stringWithCharacters:&c length:1], NSMakeRange(i, 1));
            i++;
            continue;
        }
        @throw syntax([NSString stringWithFormat:@"Expected expression but found unknown token."], NSMakeRange(i, 1));
    }
    add(T_EOF, @"", NSMakeRange(n, 0));
    return out;
}

/* ---- the parser ---- */

@interface ASParser : NSObject {
@public
    NSArray<ASToken *> *toks;
    NSUInteger pos;
    NSString *src;
}
@end

static NSDictionary<NSString *, NSArray *> *commands; /* name -> labels */
static NSSet *classNames, *ordinals, *elementWords, *constants;

static void
init_tables(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        commands = @{
            @"display dialog" : @[ @"default answer", @"hidden answer", @"buttons", @"default button", @"cancel button", @"with title",
                                   @"with icon", @"giving up after" ],
            @"display alert" : @[ @"message", @"as", @"buttons", @"default button", @"cancel button", @"giving up after" ],
            @"display notification" : @[ @"with title", @"subtitle", @"sound name" ],
            @"do shell script" : @[ @"with administrator privileges", @"administrator privileges", @"without altering line endings",
                                    @"altering line endings", @"user name", @"password" ],
            @"delay" : @[],
            @"beep" : @[],
            @"say" : @[ @"using", @"speaking rate", @"waiting until completion", @"saving to" ],
            @"count" : @[],
            @"round" : @[ @"rounding" ],
            @"random number" : @[ @"from", @"to", @"with seed" ],
            @"ascii character" : @[],
            @"ascii number" : @[],
            @"current date" : @[],
            @"path to" : @[ @"from" ],
            @"activate" : @[],
            @"quit" : @[],
            @"launch" : @[],
            @"run" : @[],
            @"open" : @[],
            @"open location" : @[],
            @"get" : @[],
            @"choose from list" : @[ @"with prompt", @"default items", @"with title", @"ok button name", @"cancel button name",
                                     @"with multiple selections allowed", @"with empty selection allowed", @"multiple selections allowed",
                                     @"empty selection allowed" ],
            @"info for" : @[],
            @"system attribute" : @[],
            @"time to gmt" : @[],
            @"string id" : @[],
            @"character id" : @[],
            @"system info" : @[],
            @"summarize" : @[],
            @"choose file" : @[ @"with prompt", @"of type", @"default location" ],
            @"choose folder" : @[ @"with prompt", @"default location" ],
        };
        classNames = [NSSet setWithArray:@[ @"text", @"string", @"integer", @"real", @"number", @"list", @"boolean", @"date", @"record",
                                            @"alias", @"file", @"unicode text", @"posix file", @"class", @"constant", @"handler", @"script",
                                            @"application", @"missing value", @"item" ]];
        ordinals = [NSSet setWithArray:@[ @"first", @"second", @"third", @"fourth", @"fifth", @"sixth", @"seventh", @"eighth", @"ninth",
                                          @"tenth", @"last", @"middle", @"some", @"every", @"front", @"back" ]];
        elementWords = [NSSet setWithArray:@[ @"item", @"items", @"character", @"characters", @"word", @"words", @"paragraph", @"paragraphs",
                                              @"text", @"texts", @"text item", @"text items", @"number", @"numbers", @"string", @"strings",
                                              @"list", @"lists", @"record", @"records", @"integer", @"integers", @"real", @"reals" ]];
        constants = [NSSet setWithArray:@[ @"january", @"february", @"march", @"april", @"may", @"june", @"july", @"august", @"september",
                                           @"october", @"november", @"december", @"monday", @"tuesday", @"wednesday", @"thursday",
                                           @"friday", @"saturday", @"sunday", @"stop", @"note", @"caution", @"critical", @"informational",
                                           @"warning", @"yes", @"no", @"ask", @"up", @"down", @"current application" ]];
    });
}

@implementation ASParser

- (ASToken *)tok { return toks[pos]; }
- (ASToken *)tokAt:(NSUInteger)k { return pos + k < toks.count ? toks[pos + k] : toks.lastObject; }
- (BOOL)atEnd { return self.tok->type == T_EOF; }
- (BOOL)atLineEnd { return self.tok->type == T_NL || self.tok->type == T_EOF; }

- (BOOL)isWord:(NSString *)w { return self.tok->type == T_WORD && !self.tok->barred && [self.tok->lower isEqualToString:w]; }
- (BOOL)isWord:(NSString *)w at:(NSUInteger)k
{
    ASToken *t = [self tokAt:k];
    return t->type == T_WORD && !t->barred && [t->lower isEqualToString:w];
}
- (BOOL)isOp:(NSString *)o { return self.tok->type == T_OP && [self.tok->text isEqualToString:o]; }

/* Do the next words spell this phrase? */
- (BOOL)matches:(NSString *)phrase
{
    NSArray *ws = [phrase componentsSeparatedByString:@" "];
    for (NSUInteger k = 0; k < ws.count; k++)
        if (![self isWord:ws[k] at:k])
            return NO;
    return YES;
}

- (BOOL)accept:(NSString *)phrase
{
    if (![self matches:phrase])
        return NO;
    pos += [phrase componentsSeparatedByString:@" "].count;
    return YES;
}

- (void)expect:(NSString *)phrase
{
    if (![self accept:phrase]) {
        /* a block left open to the end: AppleScript says it wanted the line to go on */
        NSString *here = [self describeHere];
        if ([phrase isEqualToString:@"end"] && [here isEqualToString:@"end of script"])
            @throw syntax(@"Expected end of line but found end of script.", [self hereRange]);
        @throw syntax([NSString stringWithFormat:@"Expected “%@” but found %@.", phrase, here], [self hereRange]);
    }
}

- (void)expectOp:(NSString *)o
{
    if (![self isOp:o])
        @throw syntax([NSString stringWithFormat:@"Expected “%@” but found %@.", o, [self describeHere]], [self hereRange]);
    pos++;
}

/* from start to the end of the last token read */
- (NSRange)rangeFrom:(NSUInteger)start
{
    NSUInteger k = pos;
    while (k > 0 && (toks[k - 1]->type == T_NL || toks[k - 1]->type == T_EOF))
        k--;
    NSUInteger end = k > 0 ? NSMaxRange(toks[k - 1]->range) : start;
    return NSMakeRange(start, end > start ? end - start : 0);
}

/* where a syntax error is: the token, or the end of the script with nothing selected */
- (NSRange)hereRange
{
    NSRange r = self.tok->range;
    if ([[self describeHere] isEqualToString:@"end of script"])
        r.length = 0;
    return r;
}

- (NSString *)describeHere
{
    ASToken *t = self.tok;
    switch (t->type) {
    case T_EOF: return @"end of script";
    case T_NL: {
        NSUInteger k = pos;
        while (k < toks.count && toks[k]->type == T_NL)
            k++;
        return k >= toks.count || toks[k]->type == T_EOF ? @"end of script" : @"end of line";
    }
    case T_STR: return @"“\"”";
    case T_NUM: return @"number";
    case T_OP: return [NSString stringWithFormat:@"“%@”", t->text];
    default: return [NSString stringWithFormat:@"“%@”", t->text];
    }
}

- (void)skipNewlines
{
    while (self.tok->type == T_NL)
        pos++;
}

- (void)endOfStatement
{
    if (self.tok->type == T_NL)
        pos++;
    else if (self.tok->type != T_EOF)
        @throw syntax([NSString stringWithFormat:@"Expected end of line but found %@.", [self describeHere]], [self hereRange]);
}

/* ---- statements ---- */

- (BOOL)atBlockEnd
{
    return [self isWord:@"end"] || [self isWord:@"else"] || ([self isWord:@"on"] && [self isWord:@"error" at:1]) || self.atEnd;
}

- (ASNode *)parseBlock
{
    ASNode *b = [ASNode kind:@"block"];
    [self skipNewlines];
    while (![self atBlockEnd]) {
        [b.children addObject:[self parseStatement]];
        [self skipNewlines];
    }
    return b;
}

- (void)expectEnd:(NSString *)what
{
    [self expect:@"end"];
    if (what)
        [self accept:what];
    else if (self.tok->type == T_WORD && !self.atLineEnd)
        pos++;
}

- (NSString *)identifier
{
    ASToken *t = self.tok;
    if (t->type != T_WORD)
        @throw syntax([NSString stringWithFormat:@"Expected variable name but found %@.", [self describeHere]], [self hereRange]);
    pos++;
    return t->text;
}

- (ASNode *)parseStatement
{
    NSUInteger start = self.tok->range.location;
    ASNode *n = [self parseStatementInner];
    /* to the end of its last token */
    NSUInteger k = pos;
    while (k > 0 && (toks[k - 1]->type == T_NL || toks[k - 1]->type == T_EOF))
        k--;
    NSUInteger end = k > 0 ? NSMaxRange(toks[k - 1]->range) : start;
    n.range = NSMakeRange(start, end > start ? end - start : 0);
    return n;
}

- (ASNode *)parseStatementInner
{
    if ([self accept:@"set"]) {
        ASNode *n = [ASNode kind:@"set"];
        if ([self accept:@"the clipboard to"]) {
            n.kind = @"setclipboard";
            n.args[@"value"] = [self parseExpr];
            [self endOfStatement];
            return n;
        }
        n.args[@"target"] = [self parseTarget];
        [self expect:@"to"];
        n.args[@"value"] = [self parseExpr];
        [self endOfStatement];
        return n;
    }
    if ([self accept:@"copy"]) {
        ASNode *n = [ASNode kind:@"copy"];
        n.args[@"value"] = [self parseExpr];
        [self expect:@"to"];
        n.args[@"target"] = [self parseTarget];
        [self endOfStatement];
        return n;
    }
    if ([self accept:@"if"]) {
        ASNode *n = [ASNode kind:@"if"];
        n.args[@"cond"] = [self parseExpr];
        [self accept:@"then"];
        if (!self.atLineEnd) {
            n.args[@"then"] = [self parseSimpleStatementAsBlock];
            return n;
        }
        n.args[@"then"] = [self parseBlock];
        if ([self accept:@"else"]) {
            if ([self matches:@"if"]) {
                ASNode *b = [ASNode kind:@"block"];
                [b.children addObject:[self parseElseIf]];
                n.args[@"else"] = b;
                return n;
            }
            n.args[@"else"] = [self parseBlock];
        }
        [self expectEnd:@"if"];
        [self endOfStatement];
        return n;
    }
    if ([self accept:@"repeat"])
        return [self parseRepeat];
    if ([self accept:@"exit"]) {
        [self accept:@"repeat"];
        [self endOfStatement];
        return [ASNode kind:@"exit"];
    }
    if ([self accept:@"return"]) {
        ASNode *n = [ASNode kind:@"return"];
        if (!self.atLineEnd)
            n.args[@"value"] = [self parseExpr];
        [self endOfStatement];
        return n;
    }
    if (([self isWord:@"on"] || [self isWord:@"to"]) && [self tokAt:1]->type == T_WORD)
        return [self parseHandler];
    if ([self accept:@"try"])
        return [self parseTry];
    if ([self accept:@"error"]) {
        ASNode *n = [ASNode kind:@"error"];
        if (!self.atLineEnd && ![self isWord:@"number"])
            n.args[@"message"] = [self parseExpr];
        if ([self accept:@"number"])
            n.args[@"number"] = [self parseExpr];
        while ([self accept:@"partial result"] || [self accept:@"from"] || [self accept:@"to"])
            [self parseExpr];
        [self endOfStatement];
        return n;
    }
    if ([self accept:@"tell"]) {
        ASNode *n = [ASNode kind:@"tell"];
        n.args[@"target"] = [self parseExpr];
        if ([self accept:@"to"]) {
            n.args[@"body"] = [self parseSimpleStatementAsBlock];
            return n;
        }
        [self endOfStatement];
        n.args[@"body"] = [self parseBlock];
        [self expectEnd:@"tell"];
        [self endOfStatement];
        return n;
    }
    if ([self accept:@"log"]) {
        ASNode *n = [ASNode kind:@"log"];
        n.args[@"value"] = [self parseExpr];
        [self endOfStatement];
        return n;
    }
    if ([self isWord:@"global"] || [self isWord:@"local"]) {
        ASNode *n = [ASNode kind:self.tok->lower];
        pos++;
        NSMutableArray *names = [NSMutableArray arrayWithObject:[self identifier]];
        while ([self isOp:@","]) {
            pos++;
            [names addObject:[self identifier]];
        }
        n.value = names;
        [self endOfStatement];
        return n;
    }
    if ([self accept:@"property"] || [self accept:@"prop"]) {
        ASNode *n = [ASNode kind:@"property"];
        n.name = [self identifier];
        [self expectOp:@":"];
        n.args[@"value"] = [self parseExpr];
        [self endOfStatement];
        return n;
    }
    if ([self isWord:@"script"] && ([self tokAt:1]->type == T_WORD || [self tokAt:1]->type == T_NL)) {
        pos++;
        ASNode *n = [ASNode kind:@"scriptobj"];
        n.name = self.atLineEnd ? @"" : [self identifier];
        [self endOfStatement];
        n.args[@"body"] = [self parseBlock];
        [self expectEnd:@"script"];
        [self endOfStatement];
        return n;
    }
    if ([self isWord:@"considering"] || [self isWord:@"ignoring"]) {
        /* only case is honoured; the other attributes are noted and ignored */
        BOOL considering = [self isWord:@"considering"];
        pos++;
        BOOL cased = NO;
        while (!self.atLineEnd) {
            if ([self isWord:@"case"])
                cased = YES;
            pos++;
        }
        [self endOfStatement];
        ASNode *b = [self parseBlock];
        [self expect:@"end"];
        while (!self.atLineEnd)
            pos++;
        [self endOfStatement];
        if (cased)
            b.args[@"considerCase"] = ASBoolean(considering);
        return b;
    }
    if ([self accept:@"using terms from"] || [self matches:@"with timeout"] || [self matches:@"with transaction"]) {
        while (!self.atLineEnd)
            pos++;
        [self endOfStatement];
        ASNode *b = [self parseBlock];
        [self expect:@"end"];
        while (!self.atLineEnd)
            pos++;
        [self endOfStatement];
        return b;
    }
    ASNode *n = [ASNode kind:@"expr"];
    n.args[@"value"] = [self parseExpr];
    [self endOfStatement];
    return n;
}

- (ASNode *)parseElseIf
{
    [self expect:@"if"];
    ASNode *n = [ASNode kind:@"if"];
    n.args[@"cond"] = [self parseExpr];
    [self accept:@"then"];
    n.args[@"then"] = [self parseBlock];
    if ([self accept:@"else"]) {
        if ([self matches:@"if"]) {
            ASNode *b = [ASNode kind:@"block"];
            [b.children addObject:[self parseElseIf]];
            n.args[@"else"] = b;
            return n;
        }
        n.args[@"else"] = [self parseBlock];
    }
    [self expectEnd:@"if"];
    [self endOfStatement];
    return n;
}

- (ASNode *)parseSimpleStatementAsBlock
{
    ASNode *b = [ASNode kind:@"block"];
    [b.children addObject:[self parseStatement]];
    return b;
}

- (ASNode *)parseRepeat
{
    ASNode *n = [ASNode kind:@"repeat"];
    if ([self accept:@"while"]) {
        n.name = @"while";
        n.args[@"cond"] = [self parseExpr];
    } else if ([self accept:@"until"]) {
        n.name = @"until";
        n.args[@"cond"] = [self parseExpr];
    } else if ([self accept:@"with"]) {
        n.args[@"var"] = [self identifier];
        if ([self accept:@"from"]) {
            n.name = @"range";
            n.args[@"from"] = [self parseExpr];
            if (![self accept:@"thru"] && ![self accept:@"through"])
                [self expect:@"to"];
            n.args[@"to"] = [self parseExpr];
            if ([self accept:@"by"])
                n.args[@"by"] = [self parseExpr];
        } else {
            [self expect:@"in"];
            n.name = @"in";
            n.args[@"list"] = [self parseExpr];
        }
    } else if (!self.atLineEnd) {
        n.name = @"times";
        n.args[@"count"] = [self parseExpr];
        [self expect:@"times"];
    } else {
        n.name = @"forever";
    }
    [self endOfStatement];
    n.args[@"body"] = [self parseBlock];
    [self expectEnd:@"repeat"];
    [self endOfStatement];
    return n;
}

- (ASNode *)parseHandler
{
    pos++; /* on / to */
    ASNode *n = [ASNode kind:@"handler"];
    n.name = [self identifier];
    NSMutableArray *params = [NSMutableArray array];
    if ([self isOp:@"("]) {
        pos++;
        while (![self isOp:@")"]) {
            [params addObject:[self identifier]];
            if ([self isOp:@","])
                pos++;
        }
        pos++;
    } else {
        /* "on run argv", "on open theFiles": a direct parameter without parentheses */
        while (!self.atLineEnd) {
            if (self.tok->type == T_WORD)
                [params addObject:self.tok->text];
            pos++;
        }
    }
    n.value = params;
    [self endOfStatement];
    n.args[@"body"] = [self parseBlock];
    [self expect:@"end"];
    if (!self.atLineEnd)
        pos++;
    [self endOfStatement];
    return n;
}

- (ASNode *)parseTry
{
    ASNode *n = [ASNode kind:@"try"];
    [self endOfStatement];
    n.args[@"body"] = [self parseBlock];
    if ([self accept:@"on error"]) {
        if (self.tok->type == T_WORD && ![self isWord:@"number"] && !self.atLineEnd)
            n.args[@"messageVar"] = [self identifier];
        if ([self accept:@"number"])
            n.args[@"numberVar"] = [self identifier];
        while (!self.atLineEnd) /* partial result, from, to */
            pos++;
        [self endOfStatement];
        n.args[@"handler"] = [self parseBlock];
    }
    [self expectEnd:@"try"];
    [self endOfStatement];
    return n;
}

/* An assignable: a variable, a list of them, or a reference (item 1 of x, my x, x's y). */
- (ASNode *)parseTarget
{
    if ([self accept:@"my"]) {
        ASNode *v = [ASNode kind:@"var"];
        v.name = [self identifier];
        return v;
    }
    if ([self matches:@"applescript's text item delimiters"] || [self matches:@"text item delimiters"]) {
        [self accept:@"applescript's"];
        [self accept:@"applescript"];
        if ([self isOp:@"'s"])
            pos++;
        [self expect:@"text item delimiters"];
        return [ASNode kind:@"tid"];
    }
    if ([self isWord:@"applescript"] && [self tokAt:1]->type == T_OP && [[self tokAt:1]->text isEqualToString:@"'s"]) {
        pos += 2;
        [self expect:@"text item delimiters"];
        return [ASNode kind:@"tid"];
    }
    return [self parsePostfix];
}

/* ---- expressions ---- */

- (ASNode *)parseExpr { return [self parseOr]; }

- (ASNode *)binop:(NSString *)op left:(ASNode *)l right:(ASNode *)r
{
    ASNode *n = [ASNode kind:@"binop"];
    n.name = op;
    [n.children addObject:l];
    [n.children addObject:r];
    if (l.range.length && r.range.length)
        n.range = NSUnionRange(l.range, r.range);
    return n;
}

- (ASNode *)parseOr
{
    ASNode *l = [self parseAnd];
    while ([self accept:@"or"])
        l = [self binop:@"or" left:l right:[self parseAnd]];
    return l;
}

- (ASNode *)parseAnd
{
    ASNode *l = [self parseNot];
    while ([self accept:@"and"])
        l = [self binop:@"and" left:l right:[self parseNot]];
    return l;
}

- (ASNode *)parseNot
{
    if ([self accept:@"not"]) {
        ASNode *n = [ASNode kind:@"not"];
        [n.children addObject:[self parseNot]];
        return n;
    }
    return [self parseComparison];
}

/* The comparison operators, longest English forms first. */
- (NSString *)comparisonOp
{
    static NSArray *forms;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        forms = @[
            @[ @"is greater than or equal to", @"≥" ], @[ @"is less than or equal to", @"≤" ], @[ @"is not greater than", @"≤" ],
            @[ @"is not less than", @"≥" ], @[ @"is greater than", @">" ], @[ @"is less than", @"<" ], @[ @"greater than", @">" ],
            @[ @"less than", @"<" ], @[ @"comes before", @"<" ], @[ @"comes after", @">" ], @[ @"is not equal to", @"≠" ],
            @[ @"is equal to", @"=" ], @[ @"does not equal", @"≠" ], @[ @"isn't equal to", @"≠" ], @[ @"equals", @"=" ],
            @[ @"is not in", @"notin" ], @[ @"is in", @"in" ], @[ @"is contained by", @"in" ], @[ @"is not contained by", @"notin" ],
            @[ @"does not contain", @"notcontains" ], @[ @"doesn't contain", @"notcontains" ], @[ @"contains", @"contains" ],
            @[ @"does not start with", @"notstarts" ], @[ @"does not begin with", @"notstarts" ], @[ @"starts with", @"starts" ],
            @[ @"start with", @"starts" ], @[ @"begins with", @"starts" ], @[ @"begin with", @"starts" ], @[ @"does not end with", @"notends" ],
            @[ @"ends with", @"ends" ], @[ @"end with", @"ends" ], @[ @"is not", @"≠" ], @[ @"isn't", @"≠" ], @[ @"is", @"=" ]
        ];
    });
    if (self.tok->type == T_OP && [@[ @"=", @"≠", @"<", @">", @"≤", @"≥" ] containsObject:self.tok->text]) {
        NSString *op = self.tok->text;
        pos++;
        return op;
    }
    for (NSArray *f in forms)
        if ([self accept:f[0]])
            return f[1];
    return nil;
}

- (ASNode *)parseComparison
{
    ASNode *l = [self parseAs];
    NSString *op;
    while ((op = [self comparisonOp]))
        l = [self binop:op left:l right:[self parseAs]];
    return l;
}

- (ASNode *)parseAs
{
    ASNode *l = [self parseConcat];
    while ([self accept:@"as"]) {
        ASNode *n = [ASNode kind:@"as"];
        [n.children addObject:l];
        n.name = [self className];
        l = n;
    }
    return l;
}

- (NSString *)className
{
    for (NSString *two in @[ @"unicode text", @"posix file", @"styled text" ])
        if ([self accept:two])
            return two;
    if ([self isOp:@"("]) { /* as (text) */
        pos++;
        NSString *c = [self className];
        [self expectOp:@")"];
        return c;
    }
    return [self identifier].lowercaseString;
}

- (ASNode *)parseConcat
{
    ASNode *l = [self parseAdditive];
    while ([self isOp:@"&"]) {
        pos++;
        l = [self binop:@"&" left:l right:[self parseAdditive]];
    }
    return l;
}

- (ASNode *)parseAdditive
{
    ASNode *l = [self parseMultiplicative];
    while ([self isOp:@"+"] || [self isOp:@"-"]) {
        NSString *op = self.tok->text;
        pos++;
        l = [self binop:op left:l right:[self parseMultiplicative]];
    }
    return l;
}

- (ASNode *)parseMultiplicative
{
    ASNode *l = [self parsePower];
    for (;;) {
        NSString *op = nil;
        if ([self isOp:@"*"] || [self isOp:@"/"] || [self isOp:@"÷"]) {
            op = [self isOp:@"÷"] ? @"/" : self.tok->text;
            pos++;
        } else if ([self accept:@"div"])
            op = @"div";
        else if ([self accept:@"mod"])
            op = @"mod";
        else
            break;
        l = [self binop:op left:l right:[self parsePower]];
    }
    return l;
}

- (ASNode *)parsePower
{
    ASNode *l = [self parseUnary];
    if ([self isOp:@"^"]) {
        pos++;
        return [self binop:@"^" left:l right:[self parsePower]];
    }
    return l;
}

- (ASNode *)parseUnary
{
    if ([self isOp:@"-"] || [self isOp:@"+"]) {
        NSString *op = self.tok->text;
        NSUInteger start = self.tok->range.location;
        pos++;
        ASNode *x = [self parseUnary];
        if ([op isEqualToString:@"+"])
            return x;
        ASNode *n = [ASNode kind:@"neg"];
        [n.children addObject:x];
        n.range = [self rangeFrom:start];
        return n;
    }
    return [self parsePostfix];
}

- (ASNode *)parsePostfix
{
    NSUInteger start = self.tok->range.location;
    ASNode *x = [self parseReference];
    if (!x.range.length)
        x.range = [self rangeFrom:start];
    while ([self isOp:@"'s"]) {
        pos++;
        ASNode *p = [self parseReferenceWithContainer:x];
        x = p;
        x.range = [self rangeFrom:start];
    }
    return x;
}

/* After "x's": a property or element phrase applying to x. */
- (ASNode *)parseReferenceWithContainer:(ASNode *)container
{
    ASNode *elem = [self tryElementSpecifier];
    if (elem) {
        elem.args[@"container"] = container;
        return elem;
    }
    ASNode *p = [ASNode kind:@"prop"];
    p.name = [self propertyName];
    p.args[@"container"] = container;
    return p;
}

/* A property's name: one or more words (quoted form, POSIX path, button returned, ...). */
- (NSString *)propertyName
{
    static NSArray *multi;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        multi = @[ @"quoted form", @"posix path", @"button returned", @"text returned", @"gave up", @"time string", @"date string",
                   @"short date string", @"text item delimiters", @"current date", @"number of items" ];
    });
    for (NSString *m in multi)
        if ([self accept:m])
            return m;
    return [self identifier].lowercaseString;
}

/* item 2, items 1 thru 3, last item, every word, text 2 thru 4, character -1, words, paragraphs ... */
- (ASNode *)tryElementSpecifier
{
    if ([self matches:@"string id"] || [self matches:@"character id"])
        return nil;
    NSUInteger save = pos;
    NSString *ordinal = nil;
    if (self.tok->type == T_WORD && [ordinals containsObject:self.tok->lower] && ![self isOp:@"("]) {
        ordinal = self.tok->lower;
        pos++;
    }
    NSString *cls = nil;
    if ([self matches:@"text items"] || [self matches:@"text item"]) {
        cls = [self isWord:@"items" at:1] ? @"text items" : @"text item";
        pos += 2;
    } else if (self.tok->type == T_WORD && [elementWords containsObject:self.tok->lower]) {
        cls = self.tok->lower;
        pos++;
    }
    if (!cls) {
        pos = save;
        return nil;
    }
    BOOL plural = [cls hasSuffix:@"s"] && ![cls isEqualToString:@"text items"] ? YES : [cls isEqualToString:@"text items"];
    NSString *singular = plural ? [cls substringToIndex:cls.length - 1] : cls;
    ASNode *n = [ASNode kind:@"elem"];
    n.name = singular;
    if (ordinal) {
        n.args[@"ordinal"] = ordinal;
    } else if (plural && ([self isWord:@"of"] || [self isWord:@"in"] || self.atLineEnd || [self isOp:@")"] || [self isOp:@","] ||
                          [self isOp:@"}"] || [self isOp:@"&"])) {
        n.args[@"ordinal"] = @"every";
    } else if ([cls isEqualToString:@"text"] || [cls isEqualToString:@"string"] || [cls isEqualToString:@"number"] ||
               [cls isEqualToString:@"list"] || [cls isEqualToString:@"integer"] || [cls isEqualToString:@"real"] ||
               [cls isEqualToString:@"record"]) {
        /* "text 2 thru 4", or else the class name itself (as text, class of x is text) */
        if (self.tok->type != T_NUM && ![self isOp:@"-"] && !(self.tok->type == T_WORD && ![self isWord:@"of"] &&
                                                               ![self isWord:@"thru"] && ![classNames containsObject:self.tok->lower] &&
                                                               ![commands objectForKey:self.tok->lower])) {
            pos = save;
            return nil;
        }
        n.args[@"index"] = [self parseUnaryNoReference];
        if ([self accept:@"thru"] || [self accept:@"through"])
            n.args[@"to"] = [self parseUnaryNoReference];
    } else {
        if ([self isWord:@"of"] || self.atLineEnd) {
            pos = save;
            return nil;
        }
        n.args[@"index"] = [self parseUnaryNoReference];
        if ([self accept:@"thru"] || [self accept:@"through"])
            n.args[@"to"] = [self parseUnaryNoReference];
    }
    return n;
}

/* An index: a number, a variable, a parenthesised expression, a negative number. */
- (ASNode *)parseUnaryNoReference
{
    if ([self isOp:@"-"]) {
        pos++;
        ASNode *n = [ASNode kind:@"neg"];
        [n.children addObject:[self parseUnaryNoReference]];
        return n;
    }
    return [self parsePrimary];
}

- (ASNode *)parseReference
{
    /* "the" is noise, as in AppleScript */
    if ([self isWord:@"the"] && [self tokAt:1]->type == T_WORD)
        pos++;
    if ([self accept:@"clipboard"]) {
        ASNode *n = [ASNode kind:@"cmd"];
        n.name = @"the clipboard";
        return n;
    }
    if ([self accept:@"number of"]) {
        ASNode *n = [ASNode kind:@"prop"];
        n.name = @"count";
        n.args[@"container"] = [self parseReference];
        return n;
    }
    NSUInteger start = self.tok->range.location;
    ASNode *elem = [self tryElementSpecifier];
    if (elem) {
        /* (an element's range is its specifier, without the container: "item 5") */
        elem.range = [self rangeFrom:start];
        if ([self accept:@"of"] || [self accept:@"in"])
            elem.args[@"container"] = [self parseReference];
        return elem;
    }
    /* property of container: one to three plain words, then "of" */
    if (self.tok->type == T_WORD && ![commands objectForKey:self.tok->lower]) {
        for (NSUInteger k = 1; k <= 4; k++) {
            if ([self isWord:@"of" at:k]) {
                BOOL plain = YES;
                /* (not across a keyword: "set q to items of x" has no property "q to items") */
                static NSSet *stops;
                static dispatch_once_t once;
                dispatch_once(&once, ^{
                    stops = [NSSet setWithArray:@[ @"to", @"thru", @"through", @"from", @"into", @"as", @"by", @"is", @"and", @"or", @"not",
                                                   @"then", @"with", @"without", @"in", @"else", @"contains", @"returning", @"given" ]];
                });
                for (NSUInteger j = 0; j < k; j++)
                    if ([self tokAt:j]->type != T_WORD || [self isWord:@"of" at:j] || [stops containsObject:[self tokAt:j]->lower])
                        plain = NO;
                if (!plain)
                    break;
                /* "offset of" and "number of items in" are handled elsewhere */
                if ([self isWord:@"offset"])
                    break;
                NSMutableArray *ws = [NSMutableArray array];
                for (NSUInteger j = 0; j < k; j++)
                    [ws addObject:[self tokAt:j]->lower];
                pos += k + 1;
                ASNode *p = [ASNode kind:@"prop"];
                p.name = [ws componentsJoinedByString:@" "];
                p.args[@"container"] = [self parseReference];
                return p;
            }
            if ([self tokAt:k]->type != T_WORD)
                break;
        }
    }
    return [self parsePrimary];
}

- (ASNode *)literal:(id)v
{
    ASNode *n = [ASNode kind:@"lit"];
    n.value = v;
    return n;
}

- (ASNode *)parsePrimary
{
    ASToken *t = self.tok;
    if (t->type == T_NUM) {
        pos++;
        NSString *s = t->text;
        BOOL isReal = [s rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@".eE"]].location != NSNotFound;
        if (!isReal) {
            long long v = s.longLongValue;
            /* integer literals beyond AppleScript's range are reals */
            if (s.length > 18 || v > 536870911)
                return [self literal:ASMakeReal(s.doubleValue)];
            return [self literal:@(v)];
        }
        return [self literal:ASMakeReal(s.doubleValue)];
    }
    if (t->type == T_STR) {
        pos++;
        return [self literal:t->text];
    }
    if ([self isOp:@"("]) {
        pos++;
        [self skipNewlines];
        ASNode *e = [self parseExpr];
        [self skipNewlines];
        [self expectOp:@")"];
        return e;
    }
    if ([self isOp:@"{"])
        return [self parseListOrRecord];
    if (t->type == T_WORD && !t->barred) {
        NSString *w = t->lower;
        if ([w isEqualToString:@"true"] || [w isEqualToString:@"false"]) {
            pos++;
            return [self literal:ASBoolean([w isEqualToString:@"true"])];
        }
        if ([self accept:@"missing value"])
            return [self literal:[ASConstant missingValue]];
        if ([self accept:@"current application"])
            return [self literal:[ASConstant constant:@"current application"]];
        if ([w isEqualToString:@"pi"]) {
            pos++;
            return [self literal:ASMakeReal(M_PI)];
        }
        NSDictionary *chars = @{@"tab" : @"\t", @"return" : @"\r", @"linefeed" : @"\n", @"space" : @" ", @"quote" : @"\""};
        if (chars[w]) {
            pos++;
            return [self literal:chars[w]];
        }
        if ([w isEqualToString:@"result"] || [w isEqualToString:@"it"] || [w isEqualToString:@"me"]) {
            pos++;
            ASNode *n = [ASNode kind:@"var"];
            n.name = w;
            return n;
        }
        if ([w isEqualToString:@"my"]) {
            pos++;
            return [self parsePrimary];
        }
        if (([w isEqualToString:@"application"] || [w isEqualToString:@"app"]) && [self tokAt:1]->type == T_STR) {
            pos++;
            ASNode *n = [ASNode kind:@"app"];
            n.value = self.tok->text;
            pos++;
            return n;
        }
        if ([w isEqualToString:@"application"] && [self isWord:@"id" at:1] && [self tokAt:2]->type == T_STR) {
            pos += 2;
            ASNode *n = [ASNode kind:@"app"];
            n.value = self.tok->text;
            n.name = @"id";
            pos++;
            return n;
        }
        if ([w isEqualToString:@"date"] && [self tokAt:1]->type != T_OP) {
            pos++;
            ASNode *n = [ASNode kind:@"date"];
            [n.children addObject:[self parsePrimary]];
            return n;
        }
        if ([self accept:@"posix file"]) {
            ASNode *n = [ASNode kind:@"file"];
            n.name = @"posix";
            [n.children addObject:[self parsePrimary]];
            return n;
        }
        if (([w isEqualToString:@"file"] || [w isEqualToString:@"alias"]) && ([self tokAt:1]->type == T_STR || [self tokAt:1]->type == T_WORD)) {
            if ([self tokAt:1]->type == T_STR || ![@[ @"of", @"to", @"then" ] containsObject:[self tokAt:1]->lower]) {
                pos++;
                ASNode *n = [ASNode kind:@"file"];
                n.name = w;
                [n.children addObject:[self parsePrimary]];
                return n;
            }
        }
        if ([self accept:@"offset of"]) {
            ASNode *n = [ASNode kind:@"cmd"];
            n.name = @"offset";
            n.args[@"of"] = [self parseConcat];
            [self expect:@"in"];
            n.args[@"in"] = [self parseConcat];
            return n;
        }
        if ([self accept:@"number of"]) {
            ASNode *n = [ASNode kind:@"prop"];
            n.name = @"count";
            n.args[@"container"] = [self parseReference];
            return n;
        }
        /* commands, longest phrase first */
        NSString *cmd = nil;
        for (NSString *c in [commands.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
                 return [@(b.length) compare:@(a.length)];
             }])
            if ([self matches:c]) {
                cmd = c;
                break;
            }
        if (cmd && ![self isOp:@"("] && !([cmd isEqualToString:@"run"] && [self tokAt:1]->type == T_OP)) {
            pos += [cmd componentsSeparatedByString:@" "].count;
            return [self parseCommand:cmd];
        }
        if ([classNames containsObject:w] || [constants containsObject:w]) {
            NSString *two = [NSString stringWithFormat:@"%@ %@", w, [self tokAt:1]->lower];
            if ([classNames containsObject:two]) {
                pos += 2;
                return [self literal:[ASConstant classNamed:two]];
            }
            pos++;
            return [self literal:[classNames containsObject:w] ? [ASConstant classNamed:w] : [ASConstant constant:t->text.capitalizedString]];
        }
    }
    if (t->type == T_WORD) {
        pos++;
        if ([self isOp:@"("]) {
            pos++;
            ASNode *n = [ASNode kind:@"call"];
            n.name = t->text;
            [self skipNewlines];
            while (![self isOp:@")"]) {
                [n.children addObject:[self parseExpr]];
                [self skipNewlines];
                if ([self isOp:@","])
                    pos++;
                else if (![self isOp:@")"])
                    @throw syntax([NSString stringWithFormat:@"Expected “,” or “)” but found %@.", [self describeHere]], [self hereRange]);
                [self skipNewlines];
            }
            pos++;
            return n;
        }
        ASNode *n = [ASNode kind:@"var"];
        n.name = t->text;
        return n;
    }
    @throw syntax([NSString stringWithFormat:@"Expected expression but found %@.", [self describeHere]], [self hereRange]);
}

- (ASNode *)parseListOrRecord
{
    pos++; /* { */
    [self skipNewlines];
    if ([self isOp:@"}"]) {
        pos++;
        return [ASNode kind:@"list"];
    }
    BOOL record = self.tok->type == T_WORD && [self tokAt:1]->type == T_OP && [[self tokAt:1]->text isEqualToString:@":"];
    ASNode *n = [ASNode kind:record ? @"record" : @"list"];
    NSMutableArray *keys = [NSMutableArray array];
    for (;;) {
        [self skipNewlines];
        if (record) {
            NSMutableArray *ws = [NSMutableArray array];
            while (self.tok->type == T_WORD)
                [ws addObject:[self identifier]];
            [keys addObject:[ws componentsJoinedByString:@" "]];
            [self expectOp:@":"];
        }
        [n.children addObject:[self parseExpr]];
        [self skipNewlines];
        if ([self isOp:@","]) {
            pos++;
            continue;
        }
        [self expectOp:@"}"];
        break;
    }
    n.value = keys;
    return n;
}

- (ASNode *)parseCommand:(NSString *)cmd
{
    ASNode *n = [ASNode kind:@"cmd"];
    n.name = cmd;
    NSArray *labels = [commands[cmd] sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [@(b.length) compare:@(a.length)];
    }];
    BOOL (^atLabel)(void) = ^BOOL {
        for (NSString *l in labels)
            if ([self matches:l])
                return YES;
        return [self matches:@"with"] || [self matches:@"without"];
    };
    if ([cmd isEqualToString:@"path to"]) {
        /* the folder's name: the words up to the line's end or a label */
        NSMutableArray *ws = [NSMutableArray array];
        while (self.tok->type == T_WORD && ![self isWord:@"from"] && ![self isWord:@"as"] && ![self isWord:@"of"])
            [ws addObject:[self identifier].lowercaseString];
        if (ws.count)
            n.args[@"direct"] = [self literal:[ws componentsJoinedByString:@" "]];
        else if (!self.atLineEnd && ![self isOp:@")"])
            n.args[@"direct"] = [self parseAs];
    } else if ([cmd isEqualToString:@"round"] || [cmd isEqualToString:@"random number"] || ![self commandHasNoDirect:cmd]) {
        if ([cmd isEqualToString:@"count"] || [cmd isEqualToString:@"get"])
            [self accept:@"of"];
        if (!self.atLineEnd && ![self isOp:@")"] && ![self isOp:@","] && ![self isOp:@"}"] && !atLabel() && ![self isWord:@"then"] &&
            ![self isWord:@"and"] && ![self isWord:@"or"] && ![self isOp:@"&"] && !(self.tok->type == T_OP && [@[ @"=", @"≠", @"<", @">", @"+", @"*", @"/" ] containsObject:self.tok->text]))
            n.args[@"direct"] = [self parseAs];
    }
    for (;;) {
        NSString *found = nil;
        for (NSString *l in labels)
            if ([self matches:l]) {
                found = l;
                break;
            }
        if (found) {
            pos += [found componentsSeparatedByString:@" "].count;
            BOOL flag = [found hasPrefix:@"with "] && [@[ @"with administrator privileges", @"with multiple selections allowed",
                                                         @"with empty selection allowed" ] containsObject:found];
            if (flag || [found isEqualToString:@"multiple selections allowed"] || [found isEqualToString:@"empty selection allowed"] ||
                [found isEqualToString:@"administrator privileges"]) {
                n.args[[found stringByReplacingOccurrencesOfString:@"with " withString:@""]] = [self literal:@YES];
                continue;
            }
            if ([found isEqualToString:@"without altering line endings"]) {
                n.args[@"altering line endings"] = [self literal:@NO];
                continue;
            }
            if ([found isEqualToString:@"rounding"]) {
                NSMutableArray *ws = [NSMutableArray array];
                while (self.tok->type == T_WORD && !self.atLineEnd)
                    [ws addObject:[self identifier].lowercaseString];
                n.args[@"rounding"] = [self literal:[ws componentsJoinedByString:@" "]];
                continue;
            }
            n.args[found] = [self parseAs];
            continue;
        }
        break;
    }
    return n;
}

- (BOOL)commandHasNoDirect:(NSString *)cmd
{
    return [@[ @"current date", @"time to gmt", @"system info" ] containsObject:cmd];
}

@end

ASNode *
ASParse(NSString *source)
{
    init_tables();
    ASParser *p = [ASParser new];
    p->src = source;
    p->toks = lex(source ?: @"");
    p->pos = 0;
    ASNode *b = [p parseBlock];
    if (!p.atEnd)
        @throw syntax([NSString stringWithFormat:@"Expected end of line, etc. but found %@.", [p describeHere]], [p hereRange]);
    return b;
}

static NSSet *language_keywords(void);

/* AppleScript's compiled form, rebuilt from the tokens: lines indented with tabs by their
   blocks, one space between terms (none inside brackets, ", " in lists), keywords in lower
   case, ">=" and the like as their symbols, "app" as "application",
   and a bare "end" naming its block ("end if", "end repeat", "end tell", "end fact"). */
static BOOL
is_open_bracket(ASToken *t)
{
    return t->type == T_OP && ([t->text isEqualToString:@"("] || [t->text isEqualToString:@"{"]);
}

static BOOL
is_close(ASToken *t)
{
    return t->type == T_OP && ([t->text isEqualToString:@")"] || [t->text isEqualToString:@"}"] || [t->text isEqualToString:@","] ||
                               [t->text isEqualToString:@"'s"]);
}

static NSString *
token_text(NSString *src, ASToken *t)
{
    if (t->type == T_WORD && !t->barred) {
        NSString *l = t->lower;
        if ([l isEqualToString:@"app"])
            return @"application";
        if ([language_keywords() containsObject:l] || commands[l] || [classNames containsObject:l] || [elementWords containsObject:l] ||
            [ordinals containsObject:l])
            return l;
        return t->text;
    }
    if (t->type == T_OP) {
        NSDictionary *ops = @{ @">=" : @"≥", @"<=" : @"≤", @"<>" : @"≠", @"!=" : @"≠" };
        return ops[t->text] ?: t->text;
    }
    return [src substringWithRange:t->range];
}

/* the comment (and continuation) text in a gap the lexer skipped */
static NSString *
gap_text(NSString *src, NSUInteger a, NSUInteger b, BOOL *continued)
{
    NSString *g = [src substringWithRange:NSMakeRange(a, b - a)];
    if ([g rangeOfString:@"¬"].location != NSNotFound && continued)
        *continued = YES;
    NSUInteger i = NSNotFound;
    for (NSString *m in @[ @"--", @"(*", @"#" ]) {
        NSUInteger k = [g rangeOfString:m].location;
        if (k < i)
            i = k;
    }
    if (i == NSNotFound)
        return nil;
    return [[g substringFromIndex:i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

/* The text between two lines' terms, line by line: the first part ends the line before
   (a comment there goes on that line), whole lines in between are kept (blank, or a
   comment, indented), and the last part starts the next line (returned, a comment before
   its first term; at the end of the script it's a line of its own). */
static NSString *
emit_gap(NSString *src, NSUInteger from, NSUInteger to, NSMutableArray<NSString *> *out, NSUInteger depth, BOOL atEnd)
{
    NSString *g = [src substringWithRange:NSMakeRange(from, to - from)];
    g = [[g stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    NSArray<NSString *> *parts = [g componentsSeparatedByString:@"\n"];
    NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];
    NSString *indent = [@"" stringByPaddingToLength:depth withString:@"\t" startingAtIndex:0];
    NSString *lead = nil;
    for (NSUInteger i = 0; i < parts.count; i++) {
        NSString *p = [parts[i] stringByTrimmingCharactersInSet:ws];
        BOOL firstPart = i == 0, lastPart = i == parts.count - 1;
        if (firstPart && out.count && (parts.count > 1 || !atEnd)) {
            if (p.length)
                out[out.count - 1] = [NSString stringWithFormat:@"%@ %@", out.lastObject, p];
            continue;
        }
        if (lastPart && !atEnd) {
            lead = p.length ? p : nil;
            continue;
        }
        if (lastPart && !p.length)
            continue;
        [out addObject:p.length ? [indent stringByAppendingString:p] : @""];
    }
    return lead;
}

NSString *
ASFormatSource(NSString *source)
{
    init_tables();
    source = source ?: @"";
    NSArray<ASToken *> *toks = lex(source);
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSMutableArray<NSString *> *blocks = [NSMutableArray array];
    NSUInteger last = 0, t = 0;
    while (t < toks.count && toks[t]->type != T_EOF) {
        /* one logical line */
        NSUInteger first = t;
        while (t < toks.count && toks[t]->type != T_NL && toks[t]->type != T_EOF)
            t++;
        NSArray<ASToken *> *line = [toks subarrayWithRange:NSMakeRange(first, t - first)];
        if (!line.count) {
            t++;
            continue;
        }
        NSString *w0 = line[0]->type == T_WORD ? line[0]->lower : @"";
        NSString *w1 = line.count > 1 && line[1]->type == T_WORD ? line[1]->lower : @"";
        BOOL closes = [w0 isEqualToString:@"end"], reopens = [w0 isEqualToString:@"else"] || ([w0 isEqualToString:@"on"] && [w1 isEqualToString:@"error"]);
        NSUInteger depth = blocks.count - ((closes || reopens) && blocks.count ? 1 : 0);
        /* what lies between the previous line and this one: its trailing comment, blank
           lines and comment lines, and a comment before this line's first term */
        NSString *lead = emit_gap(source, last, line[0]->range.location, out, depth, NO);
        NSMutableString *l = [NSMutableString string];
        [l appendString:[@"" stringByPaddingToLength:depth withString:@"\t" startingAtIndex:0]];
        if (lead)
            [l appendFormat:@"%@ ", lead];
        BOOL property = [w0 isEqualToString:@"property"] || [w0 isEqualToString:@"prop"];
        BOOL unary = NO;
        for (NSUInteger i = 0; i < line.count; i++) {
            ASToken *k = line[i];
            if (i) {
                BOOL continued = NO;
                NSString *c = gap_text(source, NSMaxRange(line[i - 1]->range), k->range.location, &continued);
                if (c)
                    [l appendFormat:@" %@", c];
                ASToken *p = line[i - 1];
                BOOL space = YES;
                if (is_close(k) || is_open_bracket(p) || unary)
                    space = NO;
                else if ((k->type == T_OP && [k->text isEqualToString:@":"]) || (p->type == T_OP && [p->text isEqualToString:@":"]))
                    space = property;
                else if (k->type == T_OP && [k->text isEqualToString:@"("] && p->type == T_WORD && !p->barred &&
                         ![language_keywords() containsObject:p->lower])
                    space = NO; /* a handler call */
                if (continued)
                    [l appendFormat:@" ¬\n%@\t", [@"" stringByPaddingToLength:depth withString:@"\t" startingAtIndex:0]];
                else if (space)
                    [l appendString:@" "];
            }
            /* a minus that negates: at the start, after an operator or bracket, or after a keyword */
            unary = NO;
            if (k->type == T_OP && [k->text isEqualToString:@"-"]) {
                ASToken *p = i ? line[i - 1] : nil;
                unary = !p || (p->type == T_OP && ![p->text isEqualToString:@")"] && ![p->text isEqualToString:@"}"]) ||
                        (p->type == T_WORD && !p->barred && [language_keywords() containsObject:p->lower]);
            }
            /* (a repeat's range reads "from a to b") */
            if ([w0 isEqualToString:@"repeat"] && k->type == T_WORD && ([k->lower isEqualToString:@"thru"] || [k->lower isEqualToString:@"through"]))
                [l appendString:@"to"];
            else
                [l appendString:token_text(source, k)];
        }
        last = NSMaxRange(line.lastObject->range);
        /* blocks */
        if (closes) {
            NSString *b = blocks.lastObject;
            if (b && line.count == 1)
                [l appendFormat:@" %@", b];
            if (blocks.count)
                [blocks removeLastObject];
        } else if (!reopens) {
            NSString *opened = nil;
            BOOL hasTo = NO;
            for (ASToken *k in line)
                if (k->type == T_WORD && [k->lower isEqualToString:@"to"])
                    hasTo = YES;
            ASToken *lastTok = line.lastObject;
            if ([w0 isEqualToString:@"if"] && lastTok->type == T_WORD && [lastTok->lower isEqualToString:@"then"])
                opened = @"if";
            else if ([w0 isEqualToString:@"repeat"] || [w0 isEqualToString:@"try"] || [w0 isEqualToString:@"considering"] ||
                     [w0 isEqualToString:@"ignoring"] || [w0 isEqualToString:@"script"])
                opened = w0;
            else if ([w0 isEqualToString:@"tell"] && !hasTo)
                opened = @"tell";
            else if ([w0 isEqualToString:@"using"] && [w1 isEqualToString:@"terms"])
                opened = @"using terms from";
            else if ([w0 isEqualToString:@"with"] && ([w1 isEqualToString:@"timeout"] || [w1 isEqualToString:@"transaction"]))
                opened = w1;
            else if (([w0 isEqualToString:@"on"] || [w0 isEqualToString:@"to"]) && line.count > 1 && line[1]->type == T_WORD)
                opened = line[1]->text;
            if (opened)
                [blocks addObject:opened];
        }
        [out addObject:l];
        t++;
    }
    /* comments after the last statement */
    if (last < source.length)
        emit_gap(source, last, source.length, out, blocks.count, YES);
    while (out.count && !out.lastObject.length)
        [out removeLastObject];
    unichar end = source.length ? [source characterAtIndex:source.length - 1] : 0;
    return [[out componentsJoinedByString:@"\n"] stringByAppendingString:end == '\n' || end == '\r' ? @"\n" : @""];
}

/* ---- styling ---- */

static NSSet *
language_keywords(void)
{
    static NSSet *k;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        k = [NSSet setWithArray:@[
            @"about", @"above", @"after", @"against", @"and", @"apart from", @"around", @"as", @"aside from", @"at", @"back", @"before",
            @"beginning", @"behind", @"below", @"beneath", @"beside", @"between", @"but", @"by", @"considering", @"contain", @"contains",
            @"continue", @"copy", @"div", @"does", @"eighth", @"else", @"end", @"equal", @"equals", @"error", @"every", @"exit", @"false",
            @"fifth", @"first", @"for", @"fourth", @"from", @"front", @"get", @"given", @"global", @"if", @"ignoring", @"in", @"instead of",
            @"into", @"is", @"it", @"its", @"last", @"local", @"me", @"middle", @"mod", @"my", @"ninth", @"not", @"of", @"on", @"onto",
            @"or", @"out of", @"over", @"prop", @"property", @"put", @"ref", @"reference", @"repeat", @"return", @"returning", @"script",
            @"second", @"set", @"seventh", @"since", @"sixth", @"some", @"tell", @"tenth", @"that", @"the", @"then", @"third", @"through",
            @"thru", @"timeout", @"times", @"to", @"transaction", @"true", @"try", @"until", @"where", @"while", @"whose", @"with",
            @"without", @"starts", @"ends", @"begins", @"than", @"greater", @"less", @"comes", @"after", @"using", @"terms", @"application",
            @"missing", @"value", @"result", @"text", @"item", @"items"
        ]];
    });
    return k;
}

/* Style runs for the source as AppleScript colours it: {location, length, kASSourceStyle...}. */
NSArray<NSArray<NSNumber *> *> *
ASSourceStyleRuns(NSString *source)
{
    init_tables();
    NSMutableArray *runs = [NSMutableArray array];
    NSArray<ASToken *> *toks = lex(source ?: @"");
    void (^run)(NSRange, int) = ^(NSRange r, int style) {
        if (r.length)
            [runs addObject:@[ @(r.location), @(r.length), @(style) ]];
    };
    /* comments are what the lexer skipped between tokens */
    void (^gap)(NSUInteger, NSUInteger) = ^(NSUInteger a, NSUInteger b) {
        NSUInteger i = a;
        while (i < b) {
            unichar c = [source characterAtIndex:i];
            BOOL dash = c == '-' && i + 1 < b && [source characterAtIndex:i + 1] == '-';
            BOOL paren = c == '(' && i + 1 < b && [source characterAtIndex:i + 1] == '*';
            if (dash || paren || c == '#') {
                NSUInteger e = i;
                if (paren) {
                    NSRange close = [source rangeOfString:@"*)" options:NSBackwardsSearch range:NSMakeRange(i, b - i)];
                    e = close.location == NSNotFound ? b : NSMaxRange(close);
                } else {
                    while (e < b && [source characterAtIndex:e] != '\n' && [source characterAtIndex:e] != '\r')
                        e++;
                }
                run(NSMakeRange(i, e - i), kASStyleComment);
                i = e;
            } else
                i++;
        }
    };
    NSUInteger last = 0;
    NSArray *labels = nil;
    for (NSUInteger t = 0; t < toks.count; t++) {
        ASToken *k = toks[t];
        if (k->type == T_EOF)
            break;
        if (k->range.location > last)
            gap(last, k->range.location);
        last = NSMaxRange(k->range);
        if (k->type == T_NL) {
            labels = nil;
            continue;
        }
        if (k->type == T_STR) {
            run(k->range, kASStyleString);
            continue;
        }
        if (k->type == T_NUM) {
            run(k->range, kASStyleLiteral);
            continue;
        }
        if (k->type == T_OP) {
            run(k->range, kASStyleNormal);
            continue;
        }
        if (k->barred) {
            run(k->range, kASStyleUserSymbol);
            continue;
        }
        /* the longest phrase that's a command, a parameter label of the current command or a
           built-in term */
        NSUInteger best = 0;
        int style = kASStyleUserSymbol;
        NSMutableString *phrase = [NSMutableString string];
        for (NSUInteger w = 0; w < 4 && t + w < toks.count && toks[t + w]->type == T_WORD; w++) {
            if (w)
                [phrase appendString:@" "];
            [phrase appendString:toks[t + w]->lower];
            if (commands[phrase] && ![phrase isEqualToString:@"get"] && ![phrase isEqualToString:@"count"]) {
                best = w + 1;
                style = kASStyleEventName;
            } else if ([labels containsObject:phrase]) {
                best = w + 1;
                style = kASStyleParameterName;
            } else if (w > 0 && [language_keywords() containsObject:phrase]) {
                best = w + 1;
                style = kASStyleLanguageKeyword;
            }
        }
        if (best) {
            if (style == kASStyleEventName)
                labels = commands[phrase.length ? [[[phrase componentsSeparatedByString:@" "] subarrayWithRange:NSMakeRange(0, best)]
                                                      componentsJoinedByString:@" "]
                                                : @""];
            NSRange r = NSUnionRange(k->range, toks[t + best - 1]->range);
            run(r, style);
            last = NSMaxRange(r);
            t += best - 1;
            continue;
        }
        NSString *w = k->lower;
        if ([language_keywords() containsObject:w])
            style = kASStyleLanguageKeyword;
        else if ([classNames containsObject:w] || [elementWords containsObject:w])
            style = kASStyleClass;
        else if ([constants containsObject:w])
            style = kASStyleEnumValue;
        else if ([w isEqualToString:@"count"] || [w isEqualToString:@"get"])
            style = kASStyleEventName;
        run(k->range, style);
    }
    if (last < source.length)
        gap(last, source.length);
    return runs;
}
