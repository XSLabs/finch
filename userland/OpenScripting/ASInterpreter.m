/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Finch's AppleScript: the interpreter. A script's top level is its run handler; handlers
 * have their own locals and see the script's properties and globals; tell blocks set the
 * target that commands and application properties go to. Errors are ASErrors with
 * AppleScript's numbers and messages (-2753 undefined variable, -1728 can't get, -1700
 * can't make, -128 user canceled, -1708 doesn't understand).
 *
 * The standard additions are Finch's: display dialog / alert / notification and the choose
 * commands through AppKit (loaded when first needed), do shell script through /bin/sh, path
 * to, current date, round, random number, ASCII character / number, offset, delay, say
 * (Finch has no speech yet: nothing), info for, system attribute, open location. Telling
 * an application can activate, launch, open and quit it and read its name, id, version,
 * running and frontmost; other application commands need Apple event terminology, which
 * isn't there yet (-1708).
 */
#import "ASInterpreter.h"
#import <objc/message.h>
#include <dlfcn.h>
#include <math.h>

@implementation ASScript
+ (instancetype)compile:(NSString *)source
{
    ASScript *s = [self scriptWithTree:ASParse(source) name:nil];
    s.source = source;
    return s;
}

+ (instancetype)scriptWithTree:(ASNode *)tree name:(NSString *)name
{
    ASScript *s = [ASScript new];
    s.tree = tree;
    s.name = name;
    s.properties = [NSMutableDictionary dictionary];
    s.handlers = [NSMutableDictionary dictionary];
    for (ASNode *st in s.tree.children)
        if ([st.kind isEqualToString:@"handler"]) {
            ASHandler *h = [ASHandler new];
            h.name = st.name;
            h.parameters = st.value;
            h.body = st.args[@"body"];
            s.handlers[st.name.lowercaseString] = h;
        }
    return s;
}

- (NSString *)description { return self.name.length ? [NSString stringWithFormat:@"«script %@»", self.name] : @"«script»"; }
@end

/* control flow */
@interface ASReturn : NSException
@property (strong) id value;
@end
@implementation ASReturn
@end
@interface ASExit : NSException
@end
@implementation ASExit
@end

static ASError *
err(NSInteger n, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);
static ASError *
err(NSInteger n, NSString *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    NSString *m = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    return [ASError errorWithNumber:n message:m];
}

@implementation ASInterpreter {
    ASScript *_script;
    NSMutableArray<NSMutableDictionary *> *_scopes; /* innermost last; the first is the run handler's */
    NSMutableArray *_tellTargets;
    NSMutableSet *_globalNames;
    id _result;
}

/* properties are set when the script first runs */
- (void)initProperties:(ASScript *)script
{
    for (ASNode *st in script.tree.children)
        if ([st.kind isEqualToString:@"property"] && !script.properties[st.name.lowercaseString])
            script.properties[st.name.lowercaseString] = [self eval:st.args[@"value"]];
}

- (id)run:(ASScript *)script { return [self run:script handler:nil arguments:nil]; }

- (id)run:(ASScript *)script handler:(NSString *)name arguments:(NSArray *)args
{
    _script = script;
    _scopes = [NSMutableArray arrayWithObject:[NSMutableDictionary dictionary]];
    _tellTargets = [NSMutableArray array];
    _globalNames = [NSMutableSet set];
    if (!ASTextItemDelimiters)
        ASTextItemDelimiters = @[ @"" ];
    _result = nil;
    [self initProperties:script];
    if (name)
        return [self callHandler:name arguments:args ?: @[]];
    /* an explicit run handler, else the top level */
    ASHandler *run = script.handlers[@"run"];
    @try {
        if (run)
            return [self callHandler:@"run" arguments:args ?: @[]];
        [self execBlock:script.tree];
    } @catch (ASReturn *r) {
        return r.value;
    }
    return _result;
}

/* ---- variables ---- */

- (BOOL)lookup:(NSString *)name value:(id *)out
{
    NSString *k = name.lowercaseString;
    id v = _scopes.lastObject[k];
    if (!v && ([_globalNames containsObject:k] || _scopes.count == 1))
        v = _scopes.firstObject[k];
    if (!v)
        v = _script.properties[k];
    if (!v)
        v = _scopes.firstObject[k] && [_globalNames containsObject:k] ? _scopes.firstObject[k] : nil;
    if (v)
        *out = v;
    return v != nil;
}

- (void)assign:(NSString *)name value:(id)v
{
    NSString *k = name.lowercaseString;
    if (_script.properties[k] && !_scopes.lastObject[k]) {
        _script.properties[k] = v;
        return;
    }
    if ([_globalNames containsObject:k]) {
        _scopes.firstObject[k] = v;
        return;
    }
    _scopes.lastObject[k] = v;
}

/* ---- statements ---- */

- (void)execBlock:(ASNode *)block
{
    for (ASNode *st in block.children)
        [self exec:st];
}

/* runs a statement; an error from it is placed at the statement unless something inside placed it */
- (void)exec:(ASNode *)st
{
    @try {
        [self execStatement:st];
    } @catch (ASError *e) {
        if (!e.hasRange && st.range.length && ![st.kind isEqualToString:@"block"]) {
            e.range = st.range;
            e.hasRange = YES;
        }
        @throw;
    }
}

- (void)execStatement:(ASNode *)st
{
    NSString *k = st.kind;
    if ([k isEqualToString:@"expr"]) {
        _result = [self eval:st.args[@"value"]];
    } else if ([k isEqualToString:@"set"]) {
        id v = [self eval:st.args[@"value"]];
        [self store:v into:st.args[@"target"]];
        _result = v;
    } else if ([k isEqualToString:@"copy"]) {
        id v = ASDeepCopy([self eval:st.args[@"value"]]);
        [self store:v into:st.args[@"target"]];
        _result = v;
    } else if ([k isEqualToString:@"setclipboard"]) {
        [self setClipboard:[self eval:st.args[@"value"]]];
    } else if ([k isEqualToString:@"if"]) {
        if (ASBool([self eval:st.args[@"cond"]]))
            [self execBlock:st.args[@"then"]];
        else if (st.args[@"else"])
            [self execBlock:st.args[@"else"]];
    } else if ([k isEqualToString:@"repeat"]) {
        [self execRepeat:st];
    } else if ([k isEqualToString:@"exit"]) {
        @throw [ASExit exceptionWithName:@"exit" reason:nil userInfo:nil];
    } else if ([k isEqualToString:@"return"]) {
        ASReturn *r = [[ASReturn alloc] initWithName:@"return" reason:nil userInfo:nil];
        r.value = st.args[@"value"] ? [self eval:st.args[@"value"]] : nil;
        @throw r;
    } else if ([k isEqualToString:@"handler"] || [k isEqualToString:@"property"]) {
        /* defined at compile time / first run */
    } else if ([k isEqualToString:@"try"]) {
        @try {
            [self execBlock:st.args[@"body"]];
        } @catch (ASError *e) {
            if (st.args[@"messageVar"])
                [self assign:st.args[@"messageVar"] value:e.reason ?: @""];
            if (st.args[@"numberVar"])
                [self assign:st.args[@"numberVar"] value:@(e.number)];
            if (st.args[@"handler"])
                [self execBlock:st.args[@"handler"]];
        }
    } else if ([k isEqualToString:@"error"]) {
        NSString *m = st.args[@"message"] ? ASText([self eval:st.args[@"message"]]) : @"An error has occurred.";
        NSInteger n = st.args[@"number"] ? (NSInteger)ASInteger([self eval:st.args[@"number"]]) : -2700;
        ASError *e = [ASError errorWithNumber:n message:m];
        /* placed at the message */
        ASNode *msg = st.args[@"message"];
        if (msg.range.length) {
            e.range = msg.range;
            e.hasRange = YES;
        }
        @throw e;
    } else if ([k isEqualToString:@"tell"]) {
        id target = [self eval:st.args[@"target"]];
        [_tellTargets addObject:target];
        @try {
            [self execBlock:st.args[@"body"]];
        } @finally {
            [_tellTargets removeLastObject];
        }
    } else if ([k isEqualToString:@"log"]) {
        id v = [self eval:st.args[@"value"]];
        if (_logHandler)
            _logHandler([NSString stringWithFormat:@"(*%@*)", [v isKindOfClass:[NSString class]] ? v : [ASDisplay(v) stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"{}"]]]);
    } else if ([k isEqualToString:@"global"]) {
        for (NSString *n in st.value)
            [_globalNames addObject:n.lowercaseString];
    } else if ([k isEqualToString:@"local"]) {
        for (NSString *n in st.value)
            if (!_scopes.lastObject[n.lowercaseString])
                _scopes.lastObject[n.lowercaseString] = [ASConstant missingValue];
    } else if ([k isEqualToString:@"block"]) {
        id cc = st.args[@"considerCase"];
        BOOL saved = ASConsiderCase;
        if (cc)
            ASConsiderCase = [cc boolValue];
        @try {
            [self execBlock:st];
        } @finally {
            ASConsiderCase = saved;
        }
    } else if ([k isEqualToString:@"scriptobj"]) {
        ASScript *obj = [ASScript scriptWithTree:st.args[@"body"] name:st.name];
        ASScript *outer = _script;
        _script = obj;
        @try {
            [self initProperties:obj];
        } @finally {
            _script = outer;
        }
        if (st.name.length)
            [self assign:st.name value:obj];
        _result = obj;
    }
}

- (void)execRepeat:(ASNode *)st
{
    NSString *how = st.name;
    ASNode *body = st.args[@"body"];
    @try {
        if ([how isEqualToString:@"forever"]) {
            for (;;)
                [self execBlock:body];
        } else if ([how isEqualToString:@"times"]) {
            long long n = ASInteger([self eval:st.args[@"count"]]);
            for (long long i = 0; i < n; i++)
                [self execBlock:body];
        } else if ([how isEqualToString:@"while"]) {
            while (ASBool([self eval:st.args[@"cond"]]))
                [self execBlock:body];
        } else if ([how isEqualToString:@"until"]) {
            while (!ASBool([self eval:st.args[@"cond"]]))
                [self execBlock:body];
        } else if ([how isEqualToString:@"range"]) {
            id from = ASNumberValue([self eval:st.args[@"from"]]), to = ASNumberValue([self eval:st.args[@"to"]]);
            id by = st.args[@"by"] ? ASNumberValue([self eval:st.args[@"by"]]) : @1;
            BOOL ints = ASIsInteger(from) && ASIsInteger(to) && ASIsInteger(by);
            double step = [by doubleValue];
            if (step == 0)
                @throw err(-2700, @"Can’t repeat by zero.");
            for (double i = [from doubleValue]; step > 0 ? i <= [to doubleValue] : i >= [to doubleValue]; i += step) {
                [self assign:st.args[@"var"] value:ints ? @((long long)i) : ASMakeReal(i)];
                [self execBlock:body];
            }
        } else if ([how isEqualToString:@"in"]) {
            id list = [self eval:st.args[@"list"]];
            NSArray *items = [list isKindOfClass:[NSString class]] ? [self pieces:@"character" of:list] : ASListValue(list).items.copy;
            for (id x in items) {
                [self assign:st.args[@"var"] value:x];
                [self execBlock:body];
            }
        }
    } @catch (ASExit *e) {
    }
}

- (void)store:(id)v into:(ASNode *)target
{
    NSString *k = target.kind;
    if ([k isEqualToString:@"var"]) {
        [self assign:target.name value:v];
    } else if ([k isEqualToString:@"tid"]) {
        ASTextItemDelimiters = [v isKindOfClass:[ASList class]] ? [v items].copy : @[ v ];
    } else if ([k isEqualToString:@"list"]) {
        ASList *src = ASListValue(v);
        if (src.count < target.children.count)
            @throw err(-1728, @"Can’t get item %lu of %@.", (unsigned long)src.count + 1, ASDisplay(src));
        for (NSUInteger i = 0; i < target.children.count; i++)
            [self store:[src objectAtIndex:i] into:target.children[i]];
    } else if ([k isEqualToString:@"elem"] && ([target.name isEqualToString:@"item"])) {
        id container = [self eval:target.args[@"container"]];
        if (![container isKindOfClass:[ASList class]])
            @throw err(-10006, @"Can’t set %@ to %@.", ASDisplay(container), ASDisplay(v));
        ASList *l = container;
        NSInteger i = [self indexFor:target count:l.count];
        l.items[(NSUInteger)i] = v;
    } else if ([k isEqualToString:@"prop"]) {
        id container = [self eval:target.args[@"container"]];
        if ([container isKindOfClass:[ASRecord class]]) {
            [(ASRecord *)container setValue:v forField:target.name];
            return;
        }
        if ([container isKindOfClass:[ASScript class]] && ((ASScript *)container).properties[target.name.lowercaseString]) {
            ((ASScript *)container).properties[target.name.lowercaseString] = v;
            return;
        }
        if ([container isKindOfClass:[ASList class]] && ([target.name isEqualToString:@"end"] || [target.name isEqualToString:@"beginning"])) {
            if ([target.name isEqualToString:@"end"])
                [((ASList *)container).items addObject:v];
            else
                [((ASList *)container).items insertObject:v atIndex:0];
            return;
        }
        if ([target.name isEqualToString:@"text item delimiters"]) {
            ASTextItemDelimiters = [v isKindOfClass:[ASList class]] ? [v items].copy : @[ v ];
            return;
        }
        @throw err(-10006, @"Can’t set %@ of %@ to %@.", target.name, ASDisplay(container), ASDisplay(v));
    } else {
        @throw err(-10006, @"Can’t set that to %@.", ASDisplay(v));
    }
}

/* ---- handlers ---- */

- (id)callHandler:(NSString *)name arguments:(NSArray *)args
{
    /* told to a script object: its handler, with its properties */
    ASScript *target = _tellTargets.lastObject;
    if ([target isKindOfClass:[ASScript class]] && target != _script && target.handlers[name.lowercaseString]) {
        ASScript *outer = _script;
        _script = target;
        [_tellTargets addObject:[NSNull null]];
        @try {
            return [self callHandler:name arguments:args];
        } @finally {
            [_tellTargets removeLastObject];
            _script = outer;
        }
    }
    ASHandler *h = _script.handlers[name.lowercaseString];
    if (!h)
        @throw err(-1708, @"«script» doesn’t understand the “%@” message.", name);
    if ([name.lowercaseString isEqualToString:@"run"] && h.parameters.count && args.count == 0)
        args = @[ [ASList new] ];
    if (args.count != h.parameters.count && !([name.lowercaseString isEqualToString:@"run"] || [name.lowercaseString isEqualToString:@"open"]))
        @throw err(-1721, @"%@ doesn’t match the parameters %@ for %@.", ASDisplay([ASList listWithArray:args]),
                   ASDisplay([ASList listWithArray:h.parameters]), h.name);
    NSMutableDictionary *scope = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < h.parameters.count && i < args.count; i++)
        scope[h.parameters[i].lowercaseString] = args[i];
    BOOL top = [name.lowercaseString isEqualToString:@"run"];
    if (top)
        [_scopes.firstObject addEntriesFromDictionary:scope];
    else
        [_scopes addObject:scope];
    id saved = _result;
    _result = nil;
    @try {
        [self execBlock:h.body];
        return _result;
    } @catch (ASReturn *r) {
        return r.value;
    } @finally {
        if (!top)
            [_scopes removeLastObject];
        if (!top)
            _result = saved;
    }
}

/* ---- expressions ---- */

/* evaluates; an error from it is placed at the innermost expression that has a range */
- (id)eval:(ASNode *)n
{
    @try {
        return [self evalNode:n];
    } @catch (ASError *e) {
        if (!e.hasRange && n.range.length) {
            e.range = n.range;
            e.hasRange = YES;
        }
        @throw;
    }
}

- (id)evalNode:(ASNode *)n
{
    NSString *k = n.kind;
    if ([k isEqualToString:@"lit"])
        return n.value;
    if ([k isEqualToString:@"var"])
        return [self variable:n.name];
    if ([k isEqualToString:@"list"]) {
        ASList *l = [ASList new];
        for (ASNode *c in n.children)
            [l.items addObject:[self eval:c]];
        return l;
    }
    if ([k isEqualToString:@"record"]) {
        ASRecord *r = [ASRecord new];
        for (NSUInteger i = 0; i < n.children.count; i++)
            [r setValue:[self eval:n.children[i]] forField:n.value[i]];
        return r;
    }
    if ([k isEqualToString:@"neg"]) {
        id v = ASNumberValue([self eval:n.children[0]]);
        return ASIsInteger(v) ? ASMakeInteger(-[v longLongValue]) : ASMakeReal(-[v doubleValue]);
    }
    if ([k isEqualToString:@"not"])
        return ASBoolean(!ASBool([self eval:n.children[0]]));
    if ([k isEqualToString:@"binop"])
        return [self binop:n];
    if ([k isEqualToString:@"as"])
        return [self coerce:[self eval:n.children[0]] to:n.name];
    if ([k isEqualToString:@"elem"])
        return [self element:n];
    if ([k isEqualToString:@"prop"])
        return [self property:n.name of:n.args[@"container"] ? [self eval:n.args[@"container"]] : self.implicitTarget];
    if ([k isEqualToString:@"call"]) {
        NSMutableArray *args = [NSMutableArray array];
        for (ASNode *c in n.children)
            [args addObject:[self eval:c]];
        return [self callHandler:n.name arguments:args];
    }
    if ([k isEqualToString:@"cmd"])
        return [self command:n];
    if ([k isEqualToString:@"app"]) {
        ASApplication *a = [ASApplication new];
        a.name = n.value;
        if ([n.name isEqualToString:@"id"]) {
            NSString *name = [self appNameForBundleID:n.value];
            a.name = name ?: n.value;
        }
        return a;
    }
    if ([k isEqualToString:@"date"])
        return [self parseDate:ASText([self eval:n.children[0]])];
    if ([k isEqualToString:@"file"]) {
        NSString *t = ASText([self eval:n.children[0]]);
        if ([n.name isEqualToString:@"posix"]) {
            ASFile *f = [ASFile new];
            f.path = t;
            return f;
        }
        return ASCoerce(t, n.name);
    }
    @throw err(-2700, @"Can’t evaluate %@.", k);
}

- (id)implicitTarget { return _tellTargets.lastObject; }

- (id)variable:(NSString *)name
{
    NSString *k = name.lowercaseString;
    if ([k isEqualToString:@"result"])
        return _result ?: [ASConstant missingValue];
    if ([k isEqualToString:@"it"])
        return _tellTargets.lastObject ?: [ASConstant constant:@"me"];
    if ([k isEqualToString:@"me"])
        return [ASConstant constant:@"me"];
    id v;
    if ([self lookup:name value:&v])
        return v;
    /* inside tell application: one of its properties */
    if ([self.implicitTarget isKindOfClass:[ASApplication class]]) {
        @try {
            return [self property:k of:self.implicitTarget];
        } @catch (ASError *e) {
        }
    }
    if (_script.handlers[k])
        return _script.handlers[k];
    @throw err(-2753, @"The variable %@ is not defined.", name);
}

/* ---- operators ---- */

static id
arith(NSString *op, id a, id b)
{
    a = ASNumberValue(a);
    b = ASNumberValue(b);
    BOOL ints = ASIsInteger(a) && ASIsInteger(b);
    if ([op isEqualToString:@"/"]) {
        if ([b doubleValue] == 0)
            @throw err(-2701, @"Can’t divide %@ by zero.", ASDisplay(a));
        return ASMakeReal([a doubleValue] / [b doubleValue]);
    }
    if ([op isEqualToString:@"^"])
        return ASMakeReal(pow([a doubleValue], [b doubleValue]));
    if ([op isEqualToString:@"div"]) {
        if ([b doubleValue] == 0)
            @throw err(-2701, @"Can’t divide %@ by zero.", ASDisplay(a));
        return ASMakeInteger((long long)trunc([a doubleValue] / [b doubleValue]));
    }
    if ([op isEqualToString:@"mod"]) {
        if ([b doubleValue] == 0)
            @throw err(-2701, @"Can’t divide %@ by zero.", ASDisplay(a));
        if (ints)
            return ASMakeInteger([a longLongValue] % [b longLongValue]);
        return ASMakeReal(fmod([a doubleValue], [b doubleValue]));
    }
    if (ints) {
        long long x = [a longLongValue], y = [b longLongValue], r = 0;
        BOOL over = NO;
        if ([op isEqualToString:@"+"])
            over = __builtin_add_overflow(x, y, &r);
        else if ([op isEqualToString:@"-"])
            over = __builtin_sub_overflow(x, y, &r);
        else
            over = __builtin_mul_overflow(x, y, &r);
        if (!over)
            return ASMakeInteger(r);
    }
    double x = [a doubleValue], y = [b doubleValue];
    double r = [op isEqualToString:@"+"] ? x + y : [op isEqualToString:@"-"] ? x - y : x * y;
    return ASMakeReal(r);
}

- (id)concat:(id)a with:(id)b
{
    if ([a isKindOfClass:[NSString class]])
        return [a stringByAppendingString:ASText(b)];
    if ([a isKindOfClass:[ASRecord class]] && [b isKindOfClass:[ASRecord class]]) {
        ASRecord *r = ASDeepCopy(a);
        for (NSString *k in ((ASRecord *)b).keys)
            if (![r valueForField:k])
                [r setValue:[(ASRecord *)b valueForField:k] forField:k];
        return r;
    }
    ASList *l = [ASList listWithArray:ASListValue(a).items];
    if ([b isKindOfClass:[ASList class]])
        [l.items addObjectsFromArray:[b items]];
    else if ([b isKindOfClass:[ASRecord class]])
        [l.items addObjectsFromArray:ASListValue(b).items];
    else
        [l.items addObject:b];
    return l;
}

static BOOL
contains(id container, id x)
{
    if ([container isKindOfClass:[NSString class]])
        return [container rangeOfString:ASText(x) options:NSCaseInsensitiveSearch].location != NSNotFound;
    if ([container isKindOfClass:[ASList class]]) {
        ASList *l = container;
        if ([x isKindOfClass:[ASList class]]) {
            ASList *sub = x;
            if (!sub.count)
                return YES;
            for (NSUInteger i = 0; i + sub.count <= l.count; i++) {
                BOOL all = YES;
                for (NSUInteger j = 0; j < sub.count && all; j++)
                    all = ASEqual([l objectAtIndex:i + j], [sub objectAtIndex:j]);
                if (all)
                    return YES;
            }
            return NO;
        }
        for (id y in l)
            if (ASEqual(y, x))
                return YES;
        return NO;
    }
    if ([container isKindOfClass:[ASRecord class]] && [x isKindOfClass:[ASRecord class]]) {
        for (NSString *k in ((ASRecord *)x).keys) {
            id v = [(ASRecord *)container valueForField:k];
            if (!v || !ASEqual(v, [(ASRecord *)x valueForField:k]))
                return NO;
        }
        return YES;
    }
    return ASEqual(container, x);
}

- (id)binop:(ASNode *)n
{
    NSString *op = n.name;
    if ([op isEqualToString:@"and"]) {
        if (!ASBool([self eval:n.children[0]]))
            return ASBoolean(NO);
        return ASBoolean(ASBool([self eval:n.children[1]]));
    }
    if ([op isEqualToString:@"or"]) {
        if (ASBool([self eval:n.children[0]]))
            return ASBoolean(YES);
        return ASBoolean(ASBool([self eval:n.children[1]]));
    }
    id a = [self eval:n.children[0]], b = [self eval:n.children[1]];
    if ([@[ @"+", @"-", @"*", @"/", @"^", @"div", @"mod" ] containsObject:op]) {
        if ([a isKindOfClass:[NSDate class]] && ([op isEqualToString:@"+"] || [op isEqualToString:@"-"])) {
            if ([op isEqualToString:@"-"] && [b isKindOfClass:[NSDate class]])
                return ASMakeInteger((long long)[(NSDate *)a timeIntervalSinceDate:b]);
            double s = ASReal(b);
            return [(NSDate *)a dateByAddingTimeInterval:[op isEqualToString:@"+"] ? s : -s];
        }
        /* a value that can't be a number: the error is at that operand */
        @try {
            return arith(op, a, b);
        } @catch (ASError *e) {
            if (!e.hasRange && e.offendingObject) {
                ASNode *at = e.offendingObject == b ? n.children[1] : e.offendingObject == a ? n.children[0] : nil;
                if (at.range.length) {
                    e.range = at.range;
                    e.hasRange = YES;
                }
            }
            @throw;
        }
    }
    if ([op isEqualToString:@"&"])
        return [self concat:a with:b];
    if ([op isEqualToString:@"="])
        return ASBoolean(ASEqual(a, b));
    if ([op isEqualToString:@"≠"])
        return ASBoolean(!ASEqual(a, b));
    if ([op isEqualToString:@"<"])
        return ASBoolean(ASCompare(a, b) == NSOrderedAscending);
    if ([op isEqualToString:@">"])
        return ASBoolean(ASCompare(a, b) == NSOrderedDescending);
    if ([op isEqualToString:@"≤"])
        return ASBoolean(ASCompare(a, b) != NSOrderedDescending);
    if ([op isEqualToString:@"≥"])
        return ASBoolean(ASCompare(a, b) != NSOrderedAscending);
    if ([op isEqualToString:@"contains"])
        return ASBoolean(contains(a, b));
    if ([op isEqualToString:@"notcontains"])
        return ASBoolean(!contains(a, b));
    if ([op isEqualToString:@"in"])
        return ASBoolean(contains(b, a));
    if ([op isEqualToString:@"notin"])
        return ASBoolean(!contains(b, a));
    if ([op isEqualToString:@"starts"] || [op isEqualToString:@"notstarts"]) {
        BOOL r;
        if ([a isKindOfClass:[ASList class]])
            r = [a count] && ASEqual([a objectAtIndex:0], [b isKindOfClass:[ASList class]] && [b count] ? [b objectAtIndex:0] : b);
        else
            r = [ASText(a).lowercaseString hasPrefix:ASText(b).lowercaseString];
        return ASBoolean([op isEqualToString:@"starts"] ? r : !r);
    }
    if ([op isEqualToString:@"ends"] || [op isEqualToString:@"notends"]) {
        BOOL r;
        if ([a isKindOfClass:[ASList class]])
            r = [a count] && ASEqual([a items].lastObject, [b isKindOfClass:[ASList class]] && [b count] ? [b items].lastObject : b);
        else
            r = [ASText(a).lowercaseString hasSuffix:ASText(b).lowercaseString];
        return ASBoolean([op isEqualToString:@"ends"] ? r : !r);
    }
    @throw err(-2700, @"Unknown operator %@.", op);
}

- (id)coerce:(id)v to:(NSString *)cls
{
    if ([v isKindOfClass:[ASConstant class]] && [cls isEqualToString:@"integer"]) {
        NSArray *months = @[ @"January", @"February", @"March", @"April", @"May", @"June", @"July", @"August", @"September", @"October",
                             @"November", @"December" ];
        NSUInteger i = [months indexOfObject:((ASConstant *)v).name];
        if (i != NSNotFound)
            return @(i + 1);
        NSArray *days = @[ @"Sunday", @"Monday", @"Tuesday", @"Wednesday", @"Thursday", @"Friday", @"Saturday" ];
        i = [days indexOfObject:((ASConstant *)v).name];
        if (i != NSNotFound)
            return @(i + 1);
    }
    if ([cls isEqualToString:@"list"] && [v isKindOfClass:[NSString class]])
        return [ASList listWithArray:@[ v ]];
    return ASCoerce(v, cls);
}

/* ---- elements ---- */

- (NSArray *)pieces:(NSString *)cls of:(id)container
{
    if ([container isKindOfClass:[ASList class]]) {
        NSArray *all = [container items];
        if ([cls isEqualToString:@"item"])
            return all;
        /* items of a class: text, number, integer, real, list, record */
        NSMutableArray *a = [NSMutableArray array];
        for (id x in all) {
            NSString *c = ASClassName(x);
            if ([cls isEqualToString:c] || ([cls isEqualToString:@"number"] && ASIsNumber(x)) ||
                ([cls isEqualToString:@"string"] && [c isEqualToString:@"text"]))
                [a addObject:x];
        }
        return a;
    }
    if ([container isKindOfClass:[ASRecord class]])
        return ASListValue(container).items;
    NSString *s = ASText(container);
    NSMutableArray *a = [NSMutableArray array];
    if ([cls isEqualToString:@"character"] || [cls isEqualToString:@"item"]) {
        [s enumerateSubstringsInRange:NSMakeRange(0, s.length) options:NSStringEnumerationByComposedCharacterSequences
                           usingBlock:^(NSString *sub, NSRange r, NSRange er, BOOL *stop) { [a addObject:sub]; }];
    } else if ([cls isEqualToString:@"word"]) {
        [s enumerateSubstringsInRange:NSMakeRange(0, s.length) options:NSStringEnumerationByWords
                           usingBlock:^(NSString *sub, NSRange r, NSRange er, BOOL *stop) { [a addObject:sub]; }];
    } else if ([cls isEqualToString:@"paragraph"]) {
        NSString *norm = [[s stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
        [a addObjectsFromArray:[norm componentsSeparatedByString:@"\n"]];
        if (a.count && [a.lastObject length] == 0 && s.length)
            [a removeLastObject];
        if (!s.length)
            [a removeAllObjects];
    } else if ([cls isEqualToString:@"text item"]) {
        NSString *d = ASTextItemDelimiters.count ? ASText(ASTextItemDelimiters[0]) : @"";
        if (!d.length)
            return [self pieces:@"character" of:s];
        [a addObjectsFromArray:[s componentsSeparatedByString:d]];
    } else {
        @throw err(-1728, @"Can’t get every %@ of %@.", cls, ASDisplay(container));
    }
    return a;
}

- (NSInteger)indexFor:(ASNode *)n count:(NSUInteger)count
{
    long long i = ASInteger([self eval:n.args[@"index"]]);
    if (i < 0)
        i = (long long)count + i + 1;
    if (i < 1 || i > (long long)count)
        @throw err(-1728, @"Can’t get %@ %lld of %@.", n.name, ASInteger([self eval:n.args[@"index"]]),
                   ASDisplay(n.args[@"container"] ? [self eval:n.args[@"container"]] : nil));
    return (NSInteger)(i - 1);
}

- (id)element:(ASNode *)n
{
    id container = n.args[@"container"] ? [self eval:n.args[@"container"]] : self.implicitTarget;
    if (!container)
        @throw err(-1728, @"Can’t get %@.", n.name);
    NSString *cls = n.name;
    BOOL text = [container isKindOfClass:[NSString class]];
    /* text 2 thru 4 of s: a substring */
    if (text && [cls isEqualToString:@"text"] && n.args[@"index"]) {
        NSString *s = container;
        long long a = ASInteger([self eval:n.args[@"index"]]), b = n.args[@"to"] ? ASInteger([self eval:n.args[@"to"]]) : a;
        if (a < 0) a = (long long)s.length + a + 1;
        if (b < 0) b = (long long)s.length + b + 1;
        if (a > b) { long long t = a; a = b; b = t; }
        if (a < 1 || b > (long long)s.length)
            @throw err(-1728, @"Can’t get text %lld thru %lld of %@.", a, b, ASDisplay(s));
        return [s substringWithRange:NSMakeRange((NSUInteger)(a - 1), (NSUInteger)(b - a + 1))];
    }
    NSArray *all = [self pieces:cls of:container];
    NSString *ord = n.args[@"ordinal"];
    if ([ord isEqualToString:@"every"])
        return [ASList listWithArray:all];
    if (ord) {
        NSDictionary *nth = @{@"first" : @1, @"front" : @1, @"second" : @2, @"third" : @3, @"fourth" : @4, @"fifth" : @5, @"sixth" : @6,
                              @"seventh" : @7, @"eighth" : @8, @"ninth" : @9, @"tenth" : @10};
        NSInteger i;
        if (nth[ord])
            i = [nth[ord] integerValue] - 1;
        else if ([ord isEqualToString:@"last"] || [ord isEqualToString:@"back"])
            i = (NSInteger)all.count - 1;
        else if ([ord isEqualToString:@"middle"])
            i = all.count ? (NSInteger)((all.count - 1) / 2) : -1;
        else
            i = all.count ? (NSInteger)arc4random_uniform((uint32_t)all.count) : -1;
        if (i < 0 || i >= (NSInteger)all.count)
            @throw err(-1728, @"Can’t get %@ %@ of %@.", ord, cls, ASDisplay(container));
        return all[(NSUInteger)i];
    }
    if (n.args[@"to"]) {
        long long a = ASInteger([self eval:n.args[@"index"]]), b = ASInteger([self eval:n.args[@"to"]]);
        if (a < 0) a = (long long)all.count + a + 1;
        if (b < 0) b = (long long)all.count + b + 1;
        if (a > b) { long long t = a; a = b; b = t; }
        if (a < 1 || b > (long long)all.count)
            @throw err(-1728, @"Can’t get %@s %lld thru %lld of %@.", cls, a, b, ASDisplay(container));
        NSArray *sub = [all subarrayWithRange:NSMakeRange((NSUInteger)(a - 1), (NSUInteger)(b - a + 1))];
        return [ASList listWithArray:sub];
    }
    return all[(NSUInteger)[self indexFor:n count:all.count]];
}

/* ---- properties ---- */

- (id)property:(NSString *)name of:(id)v
{
    if ([v isKindOfClass:[ASScript class]]) {
        id p = ((ASScript *)v).properties[name.lowercaseString];
        if (p)
            return p;
        if ([name isEqualToString:@"class"])
            return [ASConstant classNamed:@"script"];
        if ([name isEqualToString:@"name"] && ((ASScript *)v).name)
            return ((ASScript *)v).name;
        @throw err(-1728, @"Can’t get %@ of %@.", name, ASDisplay(v));
    }
    if ([v isKindOfClass:[ASRecord class]]) {
        id f = [(ASRecord *)v valueForField:name];
        if (f)
            return f;
        if ([name isEqualToString:@"length"] || [name isEqualToString:@"count"])
            return @(((ASRecord *)v).keys.count);
        if ([name isEqualToString:@"class"])
            return [ASConstant classNamed:@"record"];
        @throw err(-1728, @"Can’t get %@ of %@.", name, ASDisplay(v));
    }
    if ([name isEqualToString:@"class"])
        return [ASConstant classNamed:ASClassName(v)];
    if ([name isEqualToString:@"length"] || [name isEqualToString:@"count"]) {
        if ([v isKindOfClass:[NSString class]])
            return @([self pieces:@"character" of:v].count);
        if ([v isKindOfClass:[ASList class]])
            return @([v count]);
    }
    if ([name isEqualToString:@"contents"])
        return v;
    if ([v isKindOfClass:[ASList class]]) {
        if ([name isEqualToString:@"rest"])
            return [ASList listWithArray:[v count] ? [[v items] subarrayWithRange:NSMakeRange(1, [v count] - 1)] : @[]];
        if ([name isEqualToString:@"reverse"])
            return [ASList listWithArray:[[v items] reverseObjectEnumerator].allObjects];
    }
    if ([v isKindOfClass:[NSString class]]) {
        if ([name isEqualToString:@"quoted form"])
            return [NSString stringWithFormat:@"'%@'", [v stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
        if ([name isEqualToString:@"id"]) {
            NSMutableArray *ids = [NSMutableArray array];
            NSString *s = v;
            for (NSUInteger i = 0; i < s.length;) {
                NSRange r = [s rangeOfComposedCharacterSequenceAtIndex:i];
                UTF32Char c;
                [[s substringWithRange:r] getBytes:&c maxLength:4 usedLength:NULL encoding:NSUTF32LittleEndianStringEncoding options:0
                                              range:NSMakeRange(0, r.length) remainingRange:NULL];
                [ids addObject:@(c)];
                i = NSMaxRange(r);
            }
            return ids.count == 1 ? ids[0] : [ASList listWithArray:ids];
        }
        if ([name isEqualToString:@"posix path"]) {
            ASFile *f = ASCoerce(v, @"file");
            return f.path;
        }
    }
    if ([v isKindOfClass:[ASFile class]]) {
        NSString *p = ((ASFile *)v).path;
        if ([name isEqualToString:@"posix path"]) {
            BOOL dir = NO;
            if ([[NSFileManager defaultManager] fileExistsAtPath:p isDirectory:&dir] && dir && ![p hasSuffix:@"/"])
                return [p stringByAppendingString:@"/"];
            return p;
        }
        if ([name isEqualToString:@"name"])
            return p.lastPathComponent;
    }
    if ([v isKindOfClass:[NSDate class]])
        return [self dateProperty:name of:v];
    if ([v isKindOfClass:[ASApplication class]])
        return [self appProperty:name of:v];
    if ([name isEqualToString:@"text item delimiters"])
        return [ASList listWithArray:ASTextItemDelimiters];
    @throw err(-1728, @"Can’t get %@ of %@.", name, ASDisplay(v));
}

- (id)dateProperty:(NSString *)name of:(NSDate *)d
{
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDateComponents *c = [cal components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitWeekday |
                                          NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond
                                 fromDate:d];
    NSArray *months = @[ @"January", @"February", @"March", @"April", @"May", @"June", @"July", @"August", @"September", @"October",
                         @"November", @"December" ];
    NSArray *days = @[ @"Sunday", @"Monday", @"Tuesday", @"Wednesday", @"Thursday", @"Friday", @"Saturday" ];
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    if ([name isEqualToString:@"year"]) return @(c.year);
    if ([name isEqualToString:@"month"]) return [ASConstant constant:months[(NSUInteger)c.month - 1]];
    if ([name isEqualToString:@"day"]) return @(c.day);
    if ([name isEqualToString:@"weekday"]) return [ASConstant constant:days[(NSUInteger)c.weekday - 1]];
    if ([name isEqualToString:@"hours"]) return @(c.hour);
    if ([name isEqualToString:@"minutes"]) return @(c.minute);
    if ([name isEqualToString:@"seconds"]) return @(c.second);
    if ([name isEqualToString:@"time"]) return @(c.hour * 3600 + c.minute * 60 + c.second);
    if ([name isEqualToString:@"time string"]) {
        f.dateFormat = @"h:mm:ss\u202Fa";
        return [f stringFromDate:d];
    }
    if ([name isEqualToString:@"date string"]) {
        f.dateFormat = @"EEEE, MMMM d, y";
        return [f stringFromDate:d];
    }
    if ([name isEqualToString:@"short date string"]) {
        f.dateFormat = @"y-MM-dd";
        return [f stringFromDate:d];
    }
    @throw err(-1728, @"Can’t get %@ of %@.", name, ASDisplay(d));
}

/* ---- dates ---- */

- (NSDate *)parseDate:(NSString *)s
{
    NSDataDetector *det = [NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeDate error:NULL];
    NSArray *formats = @[ @"EEEE, MMMM d, y 'at' h:mm:ss a", @"M/d/y h:mm:ss a", @"M/d/y h:mm a", @"M/d/y", @"MMMM d, y", @"y-MM-dd",
                          @"y-MM-dd HH:mm:ss", @"MMMM d, y h:mm:ss a", @"h:mm:ss a", @"h:mm a" ];
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    for (NSString *fmt in formats) {
        f.dateFormat = fmt;
        NSDate *d = [f dateFromString:s];
        if (d) {
            if ([fmt hasPrefix:@"h:"]) { /* a time alone: today */
                NSCalendar *cal = [NSCalendar currentCalendar];
                NSDateComponents *t = [cal components:NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond fromDate:d];
                return [cal dateBySettingHour:t.hour minute:t.minute second:t.second ofDate:[NSDate date] options:0];
            }
            return d;
        }
    }
    NSTextCheckingResult *r = [det firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
    if (r.date)
        return r.date;
    @throw err(-30720, @"Invalid date and time date %@.", s);
}

/* ---- applications ---- */

- (Class)appKit:(NSString *)cls
{
    Class c = NSClassFromString(cls);
    if (!c) {
        dlopen("/System/Library/Frameworks/AppKit.framework/AppKit", RTLD_LAZY);
        c = NSClassFromString(cls);
    }
    return c;
}

- (NSString *)appNameForBundleID:(NSString *)bid
{
    id ws = [[self appKit:@"NSWorkspace"] performSelector:@selector(sharedWorkspace)];
    NSURL *u = [ws performSelector:@selector(URLForApplicationWithBundleIdentifier:) withObject:bid];
    return u.URLByDeletingPathExtension.lastPathComponent;
}

- (NSURL *)appURL:(ASApplication *)app
{
    id ws = [[self appKit:@"NSWorkspace"] performSelector:@selector(sharedWorkspace)];
    for (NSString *dir in @[ @"/Applications", @"/System/Applications", @"/System/Applications/Utilities", @"/Applications/Utilities",
                             [NSHomeDirectory() stringByAppendingPathComponent:@"Applications"], @"/System/Library/CoreServices" ]) {
        NSString *p = [[dir stringByAppendingPathComponent:app.name] stringByAppendingPathExtension:@"app"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:p])
            return [NSURL fileURLWithPath:p];
    }
    NSURL *u = [ws performSelector:@selector(URLForApplicationWithBundleIdentifier:) withObject:app.name];
    if (u)
        return u;
    @throw err(-2700, @"Can’t get application \"%@\".", app.name);
}

- (NSArray *)runningInstances:(ASApplication *)app
{
    NSString *bid = [NSBundle bundleWithURL:[self appURL:app]].bundleIdentifier;
    Class ra = [self appKit:@"NSRunningApplication"];
    return bid ? [ra performSelector:@selector(runningApplicationsWithBundleIdentifier:) withObject:bid] : @[];
}

- (id)appProperty:(NSString *)name of:(ASApplication *)app
{
    if ([name isEqualToString:@"name"])
        return [[NSFileManager defaultManager] displayNameAtPath:[self appURL:app].path].stringByDeletingPathExtension;
    if ([name isEqualToString:@"id"])
        return [NSBundle bundleWithURL:[self appURL:app]].bundleIdentifier ?: [ASConstant missingValue];
    if ([name isEqualToString:@"version"])
        return [NSBundle bundleWithURL:[self appURL:app]].infoDictionary[@"CFBundleShortVersionString"] ?: [ASConstant missingValue];
    if ([name isEqualToString:@"running"])
        return @([self runningInstances:app].count > 0);
    if ([name isEqualToString:@"frontmost"]) {
        id r = [self runningInstances:app].firstObject;
        return @(r && ((BOOL(*)(id, SEL))objc_msgSend)(r, sel_registerName("isActive")));
    }
    if ([name isEqualToString:@"class"])
        return [ASConstant classNamed:@"application"];
    @throw err(-1728, @"Can’t get %@ of %@.", name, ASDisplay(app));
}

- (id)appCommand:(NSString *)cmd app:(ASApplication *)app direct:(id)direct
{
    id ws = [[self appKit:@"NSWorkspace"] performSelector:@selector(sharedWorkspace)];
    if ([cmd isEqualToString:@"activate"] || [cmd isEqualToString:@"launch"] || [cmd isEqualToString:@"run"]) {
        NSURL *u = [self appURL:app];
        id running = [self runningInstances:app].firstObject;
        if (running && [cmd isEqualToString:@"activate"])
            ((BOOL(*)(id, SEL, NSUInteger))objc_msgSend)(running, sel_registerName("activateWithOptions:"), 1 << 1);
        else if (!running)
            ((id(*)(id, SEL, id, NSUInteger, id, id *))objc_msgSend)(ws, sel_registerName("launchApplicationAtURL:options:configuration:error:"), u,
                                                                  [cmd isEqualToString:@"activate"] ? 0 : (1 << 4) /* without activation */, @{}, NULL);
        return nil;
    }
    if ([cmd isEqualToString:@"quit"]) {
        for (id r in [self runningInstances:app])
            ((BOOL(*)(id, SEL))objc_msgSend)(r, sel_registerName("terminate"));
        return nil;
    }
    if ([cmd isEqualToString:@"open"]) {
        NSMutableArray *urls = [NSMutableArray array];
        for (id x in ASListValue(direct))
            [urls addObject:[NSURL fileURLWithPath:[x isKindOfClass:[ASFile class]] ? ((ASFile *)x).path : ASText(x)]];
        ((void (*)(id, SEL, id, id, id, id))objc_msgSend)(ws, sel_registerName("openURLs:withApplicationAtURL:configuration:completionHandler:"),
                                                       urls, [self appURL:app], [[self appKit:@"NSWorkspaceOpenConfiguration"] new], nil);
        return nil;
    }
    @throw err(-1708, @"%@ got an error: Finch can’t send “%@” to %@ yet.", ASDisplay(app), cmd, app.name);
}

/* ---- commands ---- */

- (id)direct:(ASNode *)n { return n.args[@"direct"] ? [self eval:n.args[@"direct"]] : nil; }
- (id)arg:(NSString *)label of:(ASNode *)n { return n.args[label] ? [self eval:n.args[label]] : nil; }

- (id)command:(ASNode *)n
{
    NSString *c = n.name;
    id target = self.implicitTarget;
    if ([target isKindOfClass:[ASApplication class]] &&
        [@[ @"activate", @"quit", @"launch", @"run", @"open" ] containsObject:c])
        return [self appCommand:c app:target direct:[self direct:n]];
    if ([@[ @"activate", @"quit", @"launch" ] containsObject:c]) {
        id d = [self direct:n];
        if ([d isKindOfClass:[ASApplication class]])
            return [self appCommand:c app:d direct:nil];
        if ([c isEqualToString:@"activate"]) {
            id app = [[self appKit:@"NSApplication"] performSelector:@selector(sharedApplication)];
            ((void (*)(id, SEL, BOOL))objc_msgSend)(app, sel_registerName("activateIgnoringOtherApps:"), YES);
        }
        return nil;
    }
    if ([c isEqualToString:@"get"])
        return [self direct:n];
    if ([c isEqualToString:@"run"]) {
        id d = [self direct:n];
        if ([d isKindOfClass:[ASApplication class]])
            return [self appCommand:@"run" app:d direct:nil];
        if ([d isKindOfClass:[ASHandler class]])
            return [self callHandler:((ASHandler *)d).name arguments:@[]];
        return [self callHandler:@"run" arguments:@[]];
    }
    if ([c isEqualToString:@"count"]) {
        id d = [self direct:n];
        if ([d isKindOfClass:[NSString class]])
            return @([self pieces:@"character" of:d].count);
        return @(ASListValue(d).count);
    }
    if ([c isEqualToString:@"current date"])
        return [NSDate dateWithTimeIntervalSince1970:floor([NSDate date].timeIntervalSince1970)];
    if ([c isEqualToString:@"time to gmt"])
        return @([[NSTimeZone localTimeZone] secondsFromGMT]);
    if ([c isEqualToString:@"offset"]) {
        NSString *of = ASText([self eval:n.args[@"of"]]), *in = ASText([self eval:n.args[@"in"]]);
        NSRange r = [in rangeOfString:of options:NSCaseInsensitiveSearch];
        return @(r.location == NSNotFound ? 0 : r.location + 1);
    }
    if ([c isEqualToString:@"round"]) {
        double x = ASReal([self direct:n]);
        NSString *how = n.args[@"rounding"] ? [self eval:n.args[@"rounding"]] : @"to nearest";
        double r = [how isEqualToString:@"up"] ? ceil(x) : [how isEqualToString:@"down"] ? floor(x)
                   : [how isEqualToString:@"toward zero"] ? trunc(x)
                   : [how isEqualToString:@"as taught in school"] ? (x < 0 ? -floor(-x + 0.5) : floor(x + 0.5))
                                                                  : nearbyint(x);
        return ASMakeInteger((long long)r);
    }
    if ([c isEqualToString:@"random number"]) {
        id d = [self direct:n], from = [self arg:@"from" of:n], to = [self arg:@"to" of:n];
        if (d && !from && !to) {
            to = d;
            from = @0;
        }
        if (!from && !to)
            return ASMakeReal(arc4random() / (double)UINT32_MAX);
        from = from ? ASNumberValue(from) : @0;
        to = to ? ASNumberValue(to) : @1;
        if (ASIsInteger(from) && ASIsInteger(to)) {
            long long a = [from longLongValue], b = [to longLongValue];
            if (a > b) { long long t = a; a = b; b = t; }
            return @(a + (long long)arc4random_uniform((uint32_t)(b - a + 1)));
        }
        double a = [from doubleValue], b = [to doubleValue];
        return ASMakeReal(a + (b - a) * (arc4random() / (double)UINT32_MAX));
    }
    if ([c isEqualToString:@"ascii character"] || [c isEqualToString:@"string id"] || [c isEqualToString:@"character id"]) {
        id d = [self direct:n];
        NSMutableString *s = [NSMutableString string];
        for (id x in ASListValue(d)) {
            UTF32Char ch = (UTF32Char)ASInteger(x);
            [s appendString:[[NSString alloc] initWithBytes:&ch length:4 encoding:NSUTF32LittleEndianStringEncoding]];
        }
        return s;
    }
    if ([c isEqualToString:@"ascii number"]) {
        NSString *s = ASText([self direct:n]);
        return s.length ? @([s characterAtIndex:0]) : @0;
    }
    if ([c isEqualToString:@"delay"]) {
        double s = n.args[@"direct"] ? ASReal([self direct:n]) : 1;
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:MAX(0, s)]];
        return nil;
    }
    if ([c isEqualToString:@"beep"]) {
        void (*b)(void) = (void (*)(void))dlsym(RTLD_DEFAULT, "NSBeep");
        if (!b) {
            dlopen("/System/Library/Frameworks/AppKit.framework/AppKit", RTLD_LAZY);
            b = (void (*)(void))dlsym(RTLD_DEFAULT, "NSBeep");
        }
        long long times = n.args[@"direct"] ? ASInteger([self direct:n]) : 1;
        for (long long i = 0; i < times && b; i++)
            b();
        return nil;
    }
    if ([c isEqualToString:@"say"])
        return nil; /* Finch has no speech synthesis yet */
    if ([c isEqualToString:@"do shell script"])
        return [self shell:n];
    if ([c isEqualToString:@"path to"])
        return [self pathTo:n];
    if ([c isEqualToString:@"system attribute"]) {
        id d = [self direct:n];
        if (!d)
            return [ASList listWithArray:[NSProcessInfo processInfo].environment.allKeys];
        return [NSProcessInfo processInfo].environment[ASText(d)] ?: @"";
    }
    if ([c isEqualToString:@"system info"]) {
        ASRecord *r = [ASRecord new];
        NSProcessInfo *pi = [NSProcessInfo processInfo];
        NSOperatingSystemVersion v = pi.operatingSystemVersion;
        [r setValue:@"2.8" forField:@"AppleScript version"];
        [r setValue:[NSString stringWithFormat:@"%ld.%ld.%ld", (long)v.majorVersion, (long)v.minorVersion, (long)v.patchVersion]
           forField:@"system version"];
        [r setValue:NSUserName() forField:@"short user name"];
        [r setValue:NSFullUserName() forField:@"long user name"];
        [r setValue:NSHomeDirectory() forField:@"home directory"];
        [r setValue:pi.hostName forField:@"host name"];
        [r setValue:@(pi.physicalMemory / 1048576) forField:@"physical memory"];
        return r;
    }
    if ([c isEqualToString:@"info for"]) {
        id d = [self direct:n];
        NSString *p = [d isKindOfClass:[ASFile class]] ? ((ASFile *)d).path : ASText(d);
        NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:NULL];
        if (!a)
            @throw err(-43, @"File %@ wasn’t found.", ASHFSPath(p));
        ASRecord *r = [ASRecord new];
        [r setValue:p.lastPathComponent forField:@"name"];
        [r setValue:ASBoolean([a[NSFileType] isEqualToString:NSFileTypeDirectory]) forField:@"folder"];
        [r setValue:@([a[NSFileSize] longLongValue]) forField:@"size"];
        [r setValue:a[NSFileCreationDate] ?: [ASConstant missingValue] forField:@"creation date"];
        [r setValue:a[NSFileModificationDate] ?: [ASConstant missingValue] forField:@"modification date"];
        [r setValue:ASBoolean(![p.lastPathComponent hasPrefix:@"."]) forField:@"visible"];
        return r;
    }
    if ([c isEqualToString:@"open location"]) {
        id ws = [[self appKit:@"NSWorkspace"] performSelector:@selector(sharedWorkspace)];
        [ws performSelector:@selector(openURL:) withObject:[NSURL URLWithString:ASText([self direct:n])]];
        return nil;
    }
    if ([c isEqualToString:@"open"]) {
        id ws = [[self appKit:@"NSWorkspace"] performSelector:@selector(sharedWorkspace)];
        for (id x in ASListValue([self direct:n]))
            [ws performSelector:@selector(openURL:)
                     withObject:[NSURL fileURLWithPath:[x isKindOfClass:[ASFile class]] ? ((ASFile *)x).path : ASText(x)]];
        return nil;
    }
    if ([c isEqualToString:@"display dialog"] || [c isEqualToString:@"display alert"])
        return [self dialog:n alert:[c isEqualToString:@"display alert"]];
    if ([c isEqualToString:@"display notification"])
        return [self notify:n];
    if ([c isEqualToString:@"choose from list"])
        return [self chooseFromList:n];
    if ([c isEqualToString:@"choose file"] || [c isEqualToString:@"choose folder"])
        return [self chooseFile:n folder:[c isEqualToString:@"choose folder"]];
    if ([c isEqualToString:@"the clipboard"]) {
        id pb = [[self appKit:@"NSPasteboard"] performSelector:@selector(generalPasteboard)];
        return [pb performSelector:@selector(stringForType:) withObject:@"public.utf8-plain-text"] ?: @"";
    }
    if ([c isEqualToString:@"summarize"])
        return ASText([self direct:n]);
    @throw err(-1708, @"“%@” isn’t available in Finch’s AppleScript yet.", c);
}

- (id)shell:(ASNode *)n
{
    NSString *cmd = ASText([self direct:n]);
    NSTask *t = [NSTask new];
    t.launchPath = @"/bin/sh";
    t.arguments = @[ @"-c", cmd ];
    NSPipe *out = [NSPipe pipe], *errp = [NSPipe pipe];
    t.standardOutput = out;
    t.standardError = errp;
    @try {
        [t launch];
    } @catch (NSException *e) {
        @throw err(-2700, @"%@", e.reason);
    }
    NSData *o = [out.fileHandleForReading readDataToEndOfFile];
    NSData *e = [errp.fileHandleForReading readDataToEndOfFile];
    [t waitUntilExit];
    NSString *s = [[NSString alloc] initWithData:o encoding:NSUTF8StringEncoding] ?: @"";
    if (t.terminationStatus != 0) {
        NSString *m = [[[NSString alloc] initWithData:e encoding:NSUTF8StringEncoding] ?: @"" stringByTrimmingCharactersInSet:
                                                                                              [NSCharacterSet newlineCharacterSet]];
        ASError *x = [ASError errorWithNumber:t.terminationStatus message:m.length ? m : [NSString stringWithFormat:@"The command exited with a non-zero status."]];
        @throw x;
    }
    if ([s hasSuffix:@"\n"])
        s = [s substringToIndex:s.length - 1];
    id altering = [self arg:@"altering line endings" of:n];
    if (!altering || ASBool(altering))
        s = [s stringByReplacingOccurrencesOfString:@"\n" withString:@"\r"];
    return s;
}

- (id)pathTo:(ASNode *)n
{
    id d = [self direct:n];
    NSString *what = d ? ASText(d).lowercaseString : @"me";
    NSString *home = NSHomeDirectory();
    NSDictionary *places = @{
        @"home folder" : home,
        @"desktop" : [home stringByAppendingPathComponent:@"Desktop"],
        @"desktop folder" : [home stringByAppendingPathComponent:@"Desktop"],
        @"documents folder" : [home stringByAppendingPathComponent:@"Documents"],
        @"downloads folder" : [home stringByAppendingPathComponent:@"Downloads"],
        @"music folder" : [home stringByAppendingPathComponent:@"Music"],
        @"movies folder" : [home stringByAppendingPathComponent:@"Movies"],
        @"pictures folder" : [home stringByAppendingPathComponent:@"Pictures"],
        @"public folder" : [home stringByAppendingPathComponent:@"Public"],
        @"applications folder" : @"/Applications",
        @"utilities folder" : @"/Applications/Utilities",
        @"library folder" : @"/Library",
        @"system folder" : @"/System",
        @"startup disk" : @"/",
        @"temporary items" : NSTemporaryDirectory(),
        @"temporary items folder" : NSTemporaryDirectory(),
        @"application support" : @"/Library/Application Support",
        @"preferences" : [home stringByAppendingPathComponent:@"Library/Preferences"],
        @"fonts" : @"/Library/Fonts",
        @"scripts folder" : @"/Library/Scripts",
    };
    NSString *p = places[what];
    if (!p && ([what isEqualToString:@"me"] || [what isEqualToString:@"current application"]))
        p = [NSBundle mainBundle].bundlePath;
    if (!p)
        @throw err(-1728, @"Can’t make %@ into type constant.", what);
    if (![p hasSuffix:@"/"])
        p = [p stringByAppendingString:@"/"];
    ASFile *f = [ASFile new];
    f.path = [p isEqualToString:@"//"] ? @"/" : p;
    f.isAlias = YES;
    return f;
}

- (id)dialog:(ASNode *)n alert:(BOOL)isAlert
{
    Class NSAlertC = [self appKit:@"NSAlert"];
    id app = [[self appKit:@"NSApplication"] performSelector:@selector(sharedApplication)];
    (void)app;
    id alert = [NSAlertC new];
    NSString *text = ASText([self direct:n] ?: @"");
    if (isAlert) {
        [alert setValue:text forKey:@"messageText"];
        id m = [self arg:@"message" of:n];
        if (m)
            [alert setValue:ASText(m) forKey:@"informativeText"];
    } else {
        id title = [self arg:@"with title" of:n];
        [alert setValue:title ? ASText(title) : @"" forKey:@"messageText"];
        [alert setValue:text forKey:@"informativeText"];
    }
    NSArray *buttons = n.args[@"buttons"] ? ASListValue([self arg:@"buttons" of:n]).items : (isAlert ? @[ @"OK" ] : @[ @"Cancel", @"OK" ]);
    id defaultButton = [self arg:@"default button" of:n];
    id cancelButton = [self arg:@"cancel button" of:n];
    NSString *defaultName = defaultButton ? (ASIsNumber(defaultButton) ? ASText(buttons[(NSUInteger)ASInteger(defaultButton) - 1]) : ASText(defaultButton))
                                          : (n.args[@"buttons"] ? nil : ASText(buttons.lastObject));
    NSString *cancelName = cancelButton ? (ASIsNumber(cancelButton) ? ASText(buttons[(NSUInteger)ASInteger(cancelButton) - 1]) : ASText(cancelButton))
                                        : ([buttons containsObject:@"Cancel"] ? @"Cancel" : nil);
    /* NSAlert lays its first button out rightmost: add them right to left */
    NSMutableArray *added = [NSMutableArray array];
    for (id b in buttons.reverseObjectEnumerator) {
        id button = [alert performSelector:@selector(addButtonWithTitle:) withObject:ASText(b)];
        [button setValue:[ASText(b) isEqualToString:defaultName ?: @""] ? @"\r" : ([ASText(b) isEqualToString:cancelName ?: @""] ? @"\e" : @"")
                  forKey:@"keyEquivalent"];
        [added addObject:ASText(b)];
    }
    id field = nil;
    id answer = [self arg:@"default answer" of:n];
    if (answer && !isAlert) {
        field = [[self appKit:@"NSTextField"] performSelector:@selector(textFieldWithString:) withObject:ASText(answer)];
        [field setValue:[NSValue valueWithRect:NSMakeRect(0, 0, 260, 24)] forKey:@"frame"];
        [alert setValue:field forKey:@"accessoryView"];
    }
    id giving = [self arg:@"giving up after" of:n];
    __block BOOL gaveUp = NO;
    if (giving) {
        NSTimer *timer = [NSTimer timerWithTimeInterval:ASReal(giving) repeats:NO block:^(NSTimer *t) {
            gaveUp = YES;
            id a = [[self appKit:@"NSApplication"] performSelector:@selector(sharedApplication)];
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(a, sel_registerName("stopModalWithCode:"), 1000);
        }];
        [[NSRunLoop currentRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    }
    NSInteger code = ((NSInteger(*)(id, SEL))objc_msgSend)(alert, sel_registerName("runModal"));
    NSString *pressed = gaveUp ? @"" : (code >= 1000 && code - 1000 < (NSInteger)added.count ? added[(NSUInteger)(code - 1000)] : @"");
    if (!gaveUp && cancelName && [pressed isEqualToString:cancelName])
        @throw err(-128, @"User canceled.");
    ASRecord *r = [ASRecord new];
    [r setValue:pressed forField:@"button returned"];
    if (field)
        [r setValue:[field valueForKey:@"stringValue"] forField:@"text returned"];
    if (giving)
        [r setValue:@(gaveUp) forField:@"gave up"];
    return r;
}

- (id)notify:(ASNode *)n
{
    Class C = NSClassFromString(@"NSUserNotification");
    Class center = NSClassFromString(@"NSUserNotificationCenter");
    if (!C) {
        dlopen("/System/Library/Frameworks/Foundation.framework/Foundation", RTLD_LAZY);
        C = NSClassFromString(@"NSUserNotification");
        center = NSClassFromString(@"NSUserNotificationCenter");
    }
    id note = [C new];
    [note setValue:ASText([self arg:@"with title" of:n] ?: @"Script Editor") forKey:@"title"];
    if (n.args[@"subtitle"])
        [note setValue:ASText([self arg:@"subtitle" of:n]) forKey:@"subtitle"];
    [note setValue:ASText([self direct:n] ?: @"") forKey:@"informativeText"];
    id c = [center performSelector:@selector(defaultUserNotificationCenter)];
    [c performSelector:@selector(deliverNotification:) withObject:note];
    return nil;
}

- (id)chooseFromList:(ASNode *)n
{
    NSArray *items = ASListValue([self direct:n]).items;
    id alert = [[self appKit:@"NSAlert"] new];
    [alert setValue:ASText([self arg:@"with prompt" of:n] ?: @"Please make your selection:") forKey:@"messageText"];
    [alert performSelector:@selector(addButtonWithTitle:) withObject:ASText([self arg:@"ok button name" of:n] ?: @"OK")];
    [alert performSelector:@selector(addButtonWithTitle:) withObject:ASText([self arg:@"cancel button name" of:n] ?: @"Cancel")];
    id popup = [[[self appKit:@"NSPopUpButton"] alloc] init];
    [popup setValue:[NSValue valueWithRect:NSMakeRect(0, 0, 240, 26)] forKey:@"frame"];
    for (id x in items)
        [popup performSelector:@selector(addItemWithTitle:) withObject:ASText(x)];
    id def = [self arg:@"default items" of:n];
    if (def && ASListValue(def).count)
        [popup performSelector:@selector(selectItemWithTitle:) withObject:ASText([ASListValue(def) objectAtIndex:0])];
    [alert setValue:popup forKey:@"accessoryView"];
    NSInteger code = ((NSInteger(*)(id, SEL))objc_msgSend)(alert, sel_registerName("runModal"));
    if (code != 1000)
        return ASBoolean(NO);
    NSInteger i = ((NSInteger(*)(id, SEL))objc_msgSend)(popup, sel_registerName("indexOfSelectedItem"));
    return [ASList listWithArray:i >= 0 && i < (NSInteger)items.count ? @[ items[(NSUInteger)i] ] : @[]];
}

- (id)chooseFile:(ASNode *)n folder:(BOOL)folder
{
    id panel = [[self appKit:@"NSOpenPanel"] performSelector:@selector(openPanel)];
    [panel setValue:@(!folder) forKey:@"canChooseFiles"];
    [panel setValue:@(folder) forKey:@"canChooseDirectories"];
    id prompt = [self arg:@"with prompt" of:n];
    if (prompt)
        [panel setValue:ASText(prompt) forKey:@"message"];
    NSInteger code = ((NSInteger(*)(id, SEL))objc_msgSend)(panel, sel_registerName("runModal"));
    if (code != 1)
        @throw err(-128, @"User canceled.");
    NSURL *u = [panel valueForKey:@"URL"];
    ASFile *f = [ASFile new];
    f.path = folder ? [u.path stringByAppendingString:@"/"] : u.path;
    f.isAlias = YES;
    return f;
}

- (void)setClipboard:(id)v
{
    id pb = [[self appKit:@"NSPasteboard"] performSelector:@selector(generalPasteboard)];
    [pb performSelector:@selector(clearContents)];
    ((BOOL(*)(id, SEL, id, id))objc_msgSend)(pb, sel_registerName("setString:forType:"), ASText(v), @"public.utf8-plain-text");
}

@end
