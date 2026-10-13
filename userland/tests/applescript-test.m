/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * AppleScript through the OSA calls, OSAKit and NSAppleScript: compiling (the compiled
 * source's form), running (results in source and human form, handlers, the run handler's
 * arguments), errors (number, message, range), descriptors both ways, script info, and the
 * outline parts Script Editor uses. Compared with Apple's.
 */
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <OSAKit/OSAKit.h>
#include <dlfcn.h>
#include <objc/message.h>

static ComponentInstance ci;

static NSString *
text(const AEDesc *d)
{
    Size n = AEGetDescDataSize(d);
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)n];
    AEGetDescData(d, data.mutableBytes, n);
    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"?";
    return [s stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
}

static OSAID
compile(NSString *src, OSAError *err)
{
    AEDesc d;
    const char *u = src.UTF8String;
    AECreateDesc(typeUTF8Text, u, (Size)strlen(u), &d);
    OSAID i = kOSANullScript;
    *err = OSACompile(ci, &d, kOSAModeNull, &i);
    AEDisposeDesc(&d);
    return i;
}

static void
print_error(void)
{
    AEDesc m = {typeNull, NULL}, n = {typeNull, NULL}, r = {typeNull, NULL};
    OSAScriptError(ci, kOSAErrorMessage, typeUTF8Text, &m);
    OSAScriptError(ci, kOSAErrorNumber, typeSInt32, &n);
    OSAScriptError(ci, kOSAErrorRange, typeOSAErrorRange, &r);
    SInt32 num = 0;
    AEGetDescData(&n, &num, sizeof num);
    SInt16 a = -1, b = -1;
    DescType t;
    Size sz;
    AEGetParamPtr(&r, keyOSASourceStart, typeSInt16, &t, &a, sizeof a, &sz);
    AEGetParamPtr(&r, keyOSASourceEnd, typeSInt16, &t, &b, sizeof b, &sz);
    printf("  error %d \"%s\" at %d-%d\n", (int)num, text(&m).UTF8String, a, b);
    AEDisposeDesc(&m);
    AEDisposeDesc(&n);
    AEDisposeDesc(&r);
}

static void
run(NSString *src)
{
    OSAError err;
    OSAID s = compile(src, &err);
    printf("%s\n", [src stringByReplacingOccurrencesOfString:@"\n" withString:@" ¶ "].UTF8String);
    if (err) {
        printf("  compile %d\n", (int)err);
        if (err == errOSAScriptError)
            print_error();
        return;
    }
    OSAID v = kOSANullScript;
    err = OSAExecute(ci, s, kOSANullScript, kOSAModeNull, &v);
    if (err) {
        printf("  execute %d\n", (int)err);
        if (err == errOSAScriptError)
            print_error();
    } else if (v) {
        AEDesc d = {typeNull, NULL}, h = {typeNull, NULL}, c = {typeNull, NULL};
        OSADisplay(ci, v, typeUTF8Text, kOSAModeNull, &d);
        OSADisplay(ci, v, typeUTF8Text, kOSAModeDisplayForHumans, &h);
        OSACoerceToDesc(ci, v, typeWildCard, kOSAModeNull, &c);
        printf("  = %s | %s | %.4s\n", text(&d).UTF8String, text(&h).UTF8String, (char *)&(DescType){CFSwapInt32HostToBig(c.descriptorType)});
        AEDisposeDesc(&d);
        AEDisposeDesc(&h);
        AEDisposeDesc(&c);
        OSADispose(ci, v);
    } else
        printf("  (no result)\n");
    OSADispose(ci, s);
}

static void
source_forms(void)
{
    printf("compiled source:\n");
    NSArray *srcs = @[
        @"set x to {1,2 , 3}\nif x contains 2 then\nset y to x\nend\n",
        @"on double(n)\nreturn n*2\nend\nrepeat with i from 1 to 3\nset z to double(i) -- twice\nend\n",
        @"tell application \"Finder\"\nset n to 1\nend\n(* done *)\n",
        @"try\nerror \"a\" number 3\non error m number n\nset q to {m,n}\nend try\nset r to {name:\"x\", age:3}\n",
    ];
    for (NSString *src in srcs) {
        OSAError err;
        OSAID s = compile(src, &err);
        AEDesc d = {typeNull, NULL};
        OSAGetSource(ci, s, typeUTF8Text, &d);
        printf("---\n%s\n", text(&d).UTF8String);
        AEDisposeDesc(&d);
        long modified = -1, compiled = -1, open = -1;
        OSAGetScriptInfo(ci, s, kOSAScriptIsTypeCompiledScript, &compiled);
        OSAGetScriptInfo(ci, s, kASHasOpenHandler, &open);
        OSAGetScriptInfo(ci, s, kOSAScriptIsModified, &modified);
        printf("  compiled %ld open handler %ld\n", compiled, open);
        OSADispose(ci, s);
    }
}

static void
results(void)
{
    printf("results:\n");
    NSArray *srcs = @[
        @"1 + 2", @"\"a\" & \"b\"", @"{1, \"two\", 3.5, true}", @"{a:1, b:\"x\"}", @"2 ^ 10", @"7 div 2", @"missing value",
        @"(characters 2 thru 3 of \"hello\") as text", @"words of \"one two three\"", @"\"abc\" contains \"b\"", @"set x to 5",
        @"on f(a, b)\nreturn a & b\nend f\nf(\"x\", \"y\")", @"script S\nproperty n : 2\nend script\nn of S",
        @"set AppleScript's text item delimiters to \",\"\nset t to text items of \"a,b,c\"\nset AppleScript's text item delimiters to \"\"\nt",
        @"set x to 1\nrepeat 3 times\nset x to x * 2\nend repeat\nx", @"class of 3", @"offset of \"c\" in \"abc\"", @"\"x\" is in {\"x\"}",
    ];
    for (NSString *src in srcs)
        run(src);
}

static void
errors(void)
{
    printf("errors:\n");
    for (NSString *src in @[ @"set x to", @"1 +", @"error \"boom\" number 42", @"set x to 1\nset y to x + \"a\"", @"item 5 of {1, 2}",
                             @"undefinedThing", @"if true then\nset x to 1" ])
        run(src);
}

static void
events(void)
{
    printf("events:\n");
    OSAError err;
    OSAID s = compile(@"on run argv\nreturn (count of argv) & item 1 of argv\nend run\non greet(who)\nreturn \"hi \" & who\nend greet", &err);
    AppleEvent ev = {typeNull, NULL};
    AEDesc list = {typeNull, NULL};
    AECreateAppleEvent(kCoreEventClass, kAEOpenApplication, NULL, kAutoGenerateReturnID, kAnyTransactionID, &ev);
    AECreateList(NULL, 0, false, &list);
    AEPutPtr(&list, 0, typeUTF8Text, "first", 5);
    AEPutPtr(&list, 0, typeUTF8Text, "second", 6);
    AEPutParamDesc(&ev, keyDirectObject, &list);
    OSAID v = kOSANullScript;
    err = OSAExecuteEvent(ci, &ev, s, kOSAModeNull, &v);
    printf("  run %d\n", (int)err);
    AEDisposeDesc(&ev);
    AEDisposeDesc(&list);

    /* a handler by name, through OSAKit */
    OSAScript *script = [[OSAScript alloc] initWithSource:@"on greet(who)\nreturn \"hi \" & who\nend greet\non add(a, b)\nreturn a + b\nend add"];
    NSDictionary *info = nil;
    NSAppleEventDescriptor *r = [script executeHandlerWithName:@"greet" arguments:@[ @"there" ] error:&info];
    printf("  greet = %s\n", r.stringValue.UTF8String);
    r = [script executeHandlerWithName:@"add" arguments:@[ @2, @3 ] error:&info];
    printf("  add = %d\n", (int)r.int32Value);
    r = [script executeHandlerWithName:@"nothing" arguments:@[] error:&info];
    printf("  nothing = %s error %s\n", r ? "result" : "nil", [info[OSAScriptErrorNumberKey] description].UTF8String);
}

static void
descriptors(void)
{
    printf("descriptors:\n");
    AEDesc list = {typeNull, NULL};
    AECreateList(NULL, 0, false, &list);
    SInt32 i = 7;
    AEPutPtr(&list, 0, typeSInt32, &i, sizeof i);
    AEPutPtr(&list, 0, typeUTF8Text, "eight", 5);
    double d = 9.5;
    AEPutPtr(&list, 0, typeIEEE64BitFloatingPoint, &d, sizeof d);
    OSAID v = kOSANullScript;
    OSAError err = OSACoerceFromDesc(ci, &list, kOSAModeNull, &v);
    AEDesc s = {typeNull, NULL};
    OSADisplay(ci, v, typeUTF8Text, kOSAModeNull, &s);
    printf("  from list %d: %s\n", (int)err, text(&s).UTF8String);
    AEDisposeDesc(&s);
    AEDisposeDesc(&list);
}

static void
osakit(void)
{
    printf("OSAKit:\n");
    OSALanguage *l = [OSALanguage defaultLanguage];
    printf("  language %s type %.4s sub %.4s features %lx\n", l.name.UTF8String, (char *)&(OSType){CFSwapInt32HostToBig(l.type)},
           (char *)&(OSType){CFSwapInt32HostToBig(l.subType)}, (unsigned long)l.features);
    printf("  by name %s, %s\n", [OSALanguage languageForName:@"AppleScript"].name.UTF8String,
           [OSALanguage languageForName:@"applescript"].name.UTF8String);
    OSAScript *s = [[OSAScript alloc] initWithSource:@"set x to {1,2}\nreturn x"];
    printf("  compiled before %d\n", s.isCompiled);
    NSDictionary *info = nil;
    BOOL ok = [s compileAndReturnError:&info];
    printf("  compile %d, compiled %d, source [%s]\n", ok, s.isCompiled, [s.source stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"].UTF8String);
    printf("  rich text [%s]\n", [s.richTextSource.string stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"].UTF8String);
    NSAttributedString *display = nil;
    NSAppleEventDescriptor *r = [s executeAndReturnDisplayValue:&display error:&info];
    printf("  result %ld items, display [%s]\n", (long)r.numberOfItems, display.string.UTF8String);

    OSAScript *bad = [[OSAScript alloc] initWithSource:@"set x to"];
    ok = [bad compileAndReturnError:&info];
    printf("  bad: %d %s %s %s\n", ok, [info[OSAScriptErrorNumberKey] description].UTF8String,
           [info[OSAScriptErrorMessageKey] UTF8String], NSStringFromRange([info[OSAScriptErrorRangeKey] rangeValue]).UTF8String);
    OSAScript *fails = [[OSAScript alloc] initWithSource:@"error \"no\" number 5"];
    r = [fails executeAndReturnError:&info];
    printf("  fails: %s %s %s\n", r ? "result" : "nil", [info[OSAScriptErrorNumberKey] description].UTF8String,
           [info[OSAScriptErrorBriefMessageKey] UTF8String]);

    /* saving and reading back */
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"finch-applescript-test.scpt"];
    ok = [s writeToURL:[NSURL fileURLWithPath:path] ofType:OSAStorageScriptType error:&info];
    OSAScript *back = [[OSAScript alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] error:&info];
    printf("  saved %d, read back %d, compiled %d, source [%s]\n", ok, back != nil, back.isCompiled,
           [back.source stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"].UTF8String);
    r = [back executeAndReturnError:&info];
    printf("  runs: %ld items\n", (long)r.numberOfItems);
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    NSString *txt = [NSTemporaryDirectory() stringByAppendingPathComponent:@"finch-applescript-test.applescript"];
    ok = [s writeToURL:[NSURL fileURLWithPath:txt] ofType:OSAStorageTextType error:&info];
    printf("  text %d: [%s]\n", ok, [[NSString stringWithContentsOfFile:txt encoding:NSUTF8StringEncoding error:NULL] stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"].UTF8String);
    [[NSFileManager defaultManager] removeItemAtPath:txt error:NULL];

    /* the outline */
    Class Parser = NSClassFromString(@"OSAScriptParser");
    id p = [Parser performSelector:@selector(parserWithText:) withObject:@"property a : 1\nglobal g\non run\nend run\non helper(x)\nif x then\nend if\nend helper\nscript Inner\nend script\n"];
    [p performSelector:@selector(parse)];
    id root = [p performSelector:@selector(element)];
    for (id e in [root performSelector:@selector(subElements)]) {
        NSRange nr = ((NSRange(*)(id, SEL))(void *)objc_msgSend)(e, @selector(nameRange));
        NSRange rr = ((NSRange(*)(id, SEL))(void *)objc_msgSend)(e, @selector(range));
        /* (Apple's run handler and global have odd ranges) */
        BOOL ranges = ![e isKindOfClass:NSClassFromString(@"OSAEventHandlerElement")] && ![e isKindOfClass:NSClassFromString(@"OSAGlobalElement")];
        printf("  %s %s", [NSStringFromClass([e class]) UTF8String], [[e performSelector:@selector(name)] UTF8String]);
        if (ranges)
            printf(" name %s range %s", NSStringFromRange(nr).UTF8String, NSStringFromRange(rr).UTF8String);
        printf("\n");
    }
}

static void
nsapplescript(void)
{
    printf("NSAppleScript:\n");
    NSAppleScript *s = [[NSAppleScript alloc] initWithSource:@"return {\"a\", 1 + 1}"];
    NSDictionary *info = nil;
    NSAppleEventDescriptor *r = [s executeAndReturnError:&info];
    printf("  compiled %d, %ld items: %s %d\n", s.isCompiled, (long)r.numberOfItems, [r descriptorAtIndex:1].stringValue.UTF8String,
           (int)[r descriptorAtIndex:2].int32Value);
    NSAppleScript *bad = [[NSAppleScript alloc] initWithSource:@"set x to"];
    BOOL ok = [bad compileAndReturnError:&info];
    printf("  bad %d: %s %s %s\n", ok, [info[NSAppleScriptErrorNumber] description].UTF8String, [info[NSAppleScriptErrorMessage] UTF8String],
           NSStringFromRange([info[NSAppleScriptErrorRange] rangeValue]).UTF8String);
    r = [[[NSAppleScript alloc] initWithSource:@"error \"nope\" number 9"] executeAndReturnError:&info];
    printf("  fails %s: %s %s\n", r ? "result" : "nil", [info[NSAppleScriptErrorNumber] description].UTF8String,
           [info[NSAppleScriptErrorBriefMessage] UTF8String]);
    printf("  rich [%s]\n", [s.richTextSource.string stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"].UTF8String);
}

int
main(void)
{
    @autoreleasepool {
        Dl_info info;
        dladdr((void *)OSACompile, &info);
        printf("%s\n", info.dli_fname);
        ci = OpenDefaultComponent(kOSAComponentType, kAppleScriptSubtype);
        AEDesc name = {typeNull, NULL};
        OSAScriptingComponentName(ci, &name);
        printf("component %s\n", text(&name).UTF8String);
        source_forms();
        results();
        errors();
        events();
        descriptors();
        osakit();
        nsapplescript();
    }
    return 0;
}
