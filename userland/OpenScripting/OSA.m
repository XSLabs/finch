/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * OpenScripting: the Open Scripting Architecture's client calls (OSA.h, AppleScript.h,
 * OSAGeneric.h), Finch's, over Finch's AppleScript (ASParser, ASInterpreter). There is one
 * scripting component, AppleScript; the generic component and AppleScript's are the same
 * instance (OpenDefaultComponent hands out a token for either), and OSAIDs name compiled
 * scripts, contexts and values in one table.
 *
 * Stored scripts are Finch's: "FnAS", a version and the source in UTF-8, as type 'scpt'.
 * Scripts compiled by Apple's AppleScript ("FasdUAS") hold no source and can't be read
 * yet (errOSADataFormatTooNew). Script files: .scpt, .applescript text, and bundles
 * (.scptd and applets) with Contents/Resources/Scripts/main.scpt.
 */
#import "ASInterpreter.h"
#import <objc/message.h>
#import <Carbon/Carbon.h>

@interface FinchOSAEntry : NSObject
@property (strong) ASScript *script; /* a compiled script or a context */
@property (strong) id value;         /* a value */
@property BOOL modified;
@end
@implementation FinchOSAEntry
@end

static NSMutableDictionary<NSNumber *, FinchOSAEntry *> *table;
static OSAID next_id = 1;
static NSLock *lock;

/* the last error */
static ASError *last_error;
static NSRange last_range;

/* the procs a client installed */
static OSAActiveUPP active_proc;
static SRefCon active_refcon;
static OSASendUPP send_proc;
static SRefCon send_refcon;
static OSACreateAppleEventUPP create_proc;
static SRefCon create_refcon;
static AEEventHandlerUPP resume_proc;
static SRefCon resume_refcon;
static void *create_progress_proc, *create_progress_refcon, *release_progress_proc, *release_progress_refcon;
static CFArrayRef source_attributes;

static void
setup(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = [NSMutableDictionary dictionary];
        lock = [NSLock new];
    });
}

static OSAID
add_entry(FinchOSAEntry *e)
{
    setup();
    [lock lock];
    OSAID i = next_id++;
    table[@(i)] = e;
    [lock unlock];
    return i;
}

static FinchOSAEntry *
entry(OSAID i)
{
    setup();
    [lock lock];
    FinchOSAEntry *e = table[@(i)];
    [lock unlock];
    return e;
}

static OSAError
script_error(ASError *e, NSRange r)
{
    last_error = e;
    last_range = r;
    return errOSAScriptError;
}

/* ---- text and descriptors ---- */

static NSString *
desc_text(const AEDesc *d)
{
    if (!d || d->descriptorType == typeNull)
        return nil;
    Size n = AEGetDescDataSize(d);
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)n];
    AEGetDescData(d, data.mutableBytes, n);
    switch (d->descriptorType) {
    case typeUnicodeText:
        return [[NSString alloc] initWithData:data encoding:NSUTF16LittleEndianStringEncoding];
    case typeUTF16ExternalRepresentation:
        return [[NSString alloc] initWithData:data encoding:NSUTF16StringEncoding];
    case typeUTF8Text:
        return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    case typeChar:
        return [[NSString alloc] initWithData:data encoding:NSMacOSRomanStringEncoding];
    default: {
        AEDesc u = {typeNull, NULL};
        if (AECoerceDesc(d, typeUnicodeText, &u) == noErr) {
            NSString *s = desc_text(&u);
            AEDisposeDesc(&u);
            return s;
        }
        return nil;
    }
    }
}

static OSErr
text_desc(NSString *s, DescType type, AEDesc *out)
{
    if (type == typeChar) {
        NSData *d = [s dataUsingEncoding:NSMacOSRomanStringEncoding allowLossyConversion:YES];
        return AECreateDesc(typeChar, d.bytes, (Size)d.length, out);
    }
    if (type == typeUTF8Text) {
        NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
        return AECreateDesc(typeUTF8Text, d.bytes, (Size)d.length, out);
    }
    NSData *d = [s dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
    return AECreateDesc(typeUnicodeText, d.bytes, (Size)d.length, out);
}

/* AppleScript's classes and constants by their four-character codes */
static NSDictionary<NSString *, NSNumber *> *
class_codes(void)
{
    static NSDictionary *d;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        d = @{
            @"integer" : @((UInt32)'long'), @"real" : @((UInt32)'doub'), @"text" : @((UInt32)'ctxt'), @"string" : @((UInt32)'TEXT'), @"unicode text" : @((UInt32)'utxt'),
            @"list" : @((UInt32)'list'), @"record" : @((UInt32)'reco'), @"boolean" : @((UInt32)'bool'), @"date" : @((UInt32)'ldt '), @"number" : @((UInt32)'nmbr'),
            @"class" : @((UInt32)'pcls'), @"script" : @((UInt32)'scpt'), @"handler" : @((UInt32)'hand'), @"application" : @((UInt32)'capp'), @"alias" : @((UInt32)'alis'),
            @"file" : @((UInt32)'file'), @"constant" : @((UInt32)'enum'), @"item" : @((UInt32)'cobj'), @"missing value" : @((UInt32)'msng'), @"january" : @((UInt32)'jan '),
            @"february" : @((UInt32)'feb '), @"march" : @((UInt32)'mar '), @"april" : @((UInt32)'apr '), @"may" : @((UInt32)'may '), @"june" : @((UInt32)'jun '),
            @"july" : @((UInt32)'jul '), @"august" : @((UInt32)'aug '), @"september" : @((UInt32)'sep '), @"october" : @((UInt32)'oct '), @"november" : @((UInt32)'nov '),
            @"december" : @((UInt32)'dec '), @"monday" : @((UInt32)'mon '), @"tuesday" : @((UInt32)'tue '), @"wednesday" : @((UInt32)'wed '), @"thursday" : @((UInt32)'thu '),
            @"friday" : @((UInt32)'fri '), @"saturday" : @((UInt32)'sat '), @"sunday" : @((UInt32)'sun '), @"yes" : @((UInt32)'yes '), @"no" : @((UInt32)'no  '), @"ask" : @((UInt32)'ask ')
        };
    });
    return d;
}

/* seconds between 1904 and 1970 */
#define MAC_EPOCH_DELTA 2082844800.0

static OSErr value_desc(id v, AEDesc *out);

static OSErr
list_desc(ASList *l, AEDesc *out)
{
    OSErr e = AECreateList(NULL, 0, false, out);
    for (NSUInteger i = 0; !e && i < l.count; i++) {
        AEDesc item = {typeNull, NULL};
        e = value_desc([l objectAtIndex:i], &item);
        if (!e)
            e = AEPutDesc(out, 0, &item);
        AEDisposeDesc(&item);
    }
    return e;
}

/* an AppleScript value as an Apple event descriptor */
static OSErr
value_desc(id v, AEDesc *out)
{
    if (!v || ([v isKindOfClass:[ASConstant class]] && [((ASConstant *)v).name isEqualToString:@"missing value"])) {
        DescType t = cMissingValue;
        return AECreateDesc(typeType, &t, sizeof t, out);
    }
    if (ASIsBoolean(v))
        return AECreateDesc([v boolValue] ? typeTrue : typeFalse, NULL, 0, out);
    if (ASIsInteger(v)) {
        long long n = [v longLongValue];
        if (n >= INT32_MIN && n <= INT32_MAX) {
            SInt32 i = (SInt32)n;
            return AECreateDesc(typeSInt32, &i, sizeof i, out);
        }
        double d = (double)n;
        return AECreateDesc(typeIEEE64BitFloatingPoint, &d, sizeof d, out);
    }
    if (ASIsReal(v)) {
        double d = [v doubleValue];
        return AECreateDesc(typeIEEE64BitFloatingPoint, &d, sizeof d, out);
    }
    if ([v isKindOfClass:[NSString class]])
        return text_desc(v, typeUnicodeText, out);
    if ([v isKindOfClass:[ASList class]])
        return list_desc(v, out);
    if ([v isKindOfClass:[ASRecord class]]) {
        ASRecord *r = v;
        OSErr e = AECreateList(NULL, 0, true, out);
        ASList *fields = [ASList new];
        for (NSString *k in r.keys) {
            [fields.items addObject:k];
            [fields.items addObject:[r valueForField:k]];
        }
        AEDesc f = {typeNull, NULL};
        if (!e)
            e = list_desc(fields, &f);
        if (!e)
            e = AEPutParamDesc(out, keyASUserRecordFields, &f);
        AEDisposeDesc(&f);
        return e;
    }
    if ([v isKindOfClass:[NSDate class]]) {
        NSTimeZone *z = [NSTimeZone localTimeZone];
        SInt64 s = (SInt64)([(NSDate *)v timeIntervalSince1970] + MAC_EPOCH_DELTA + [z secondsFromGMTForDate:v]);
        return AECreateDesc(typeLongDateTime, &s, sizeof s, out);
    }
    if ([v isKindOfClass:[ASFile class]]) {
        NSData *u = [[NSURL fileURLWithPath:((ASFile *)v).path].absoluteString dataUsingEncoding:NSUTF8StringEncoding];
        return AECreateDesc(typeFileURL, u.bytes, (Size)u.length, out);
    }
    if ([v isKindOfClass:[ASConstant class]]) {
        NSNumber *code = class_codes()[((ASConstant *)v).name.lowercaseString];
        if (code) {
            DescType t = (DescType)code.unsignedIntValue;
            return AECreateDesc(typeType, &t, sizeof t, out);
        }
    }
    return text_desc(ASDisplay(v), typeUnicodeText, out);
}

/* an Apple event descriptor as an AppleScript value */
static id
desc_value(const AEDesc *d)
{
    switch (d->descriptorType) {
    case typeNull:
        return [ASConstant missingValue];
    case typeTrue:
        return ASBoolean(YES);
    case typeFalse:
        return ASBoolean(NO);
    case typeBoolean: {
        Boolean b = 0;
        AEGetDescData(d, &b, sizeof b);
        return ASBoolean(b != 0);
    }
    case typeSInt16: {
        SInt16 i = 0;
        AEGetDescData(d, &i, sizeof i);
        return @((long long)i);
    }
    case typeSInt32: {
        SInt32 i = 0;
        AEGetDescData(d, &i, sizeof i);
        return @((long long)i);
    }
    case typeSInt64: {
        SInt64 i = 0;
        AEGetDescData(d, &i, sizeof i);
        return ASMakeInteger(i);
    }
    case typeIEEE32BitFloatingPoint: {
        float f = 0;
        AEGetDescData(d, &f, sizeof f);
        return ASMakeReal(f);
    }
    case typeIEEE64BitFloatingPoint: {
        double f = 0;
        AEGetDescData(d, &f, sizeof f);
        return ASMakeReal(f);
    }
    case typeLongDateTime: {
        SInt64 s = 0;
        AEGetDescData(d, &s, sizeof s);
        NSDate *local = [NSDate dateWithTimeIntervalSince1970:(double)s - MAC_EPOCH_DELTA];
        return [local dateByAddingTimeInterval:-[[NSTimeZone localTimeZone] secondsFromGMTForDate:local]];
    }
    case typeFileURL: {
        Size n = AEGetDescDataSize(d);
        NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)n];
        AEGetDescData(d, data.mutableBytes, n);
        NSURL *u = [NSURL URLWithString:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]];
        ASFile *f = [ASFile new];
        f.path = u.path;
        return f;
    }
    case typeType: {
        DescType t = 0;
        AEGetDescData(d, &t, sizeof t);
        if (t == cMissingValue)
            return [ASConstant missingValue];
        for (NSString *name in class_codes())
            if (class_codes()[name].unsignedIntValue == t)
                return [ASConstant classNamed:name];
        return [ASConstant constant:[NSString stringWithFormat:@"«class %c%c%c%c»", (char)(t >> 24), (char)(t >> 16), (char)(t >> 8), (char)t]];
    }
    case typeAEList: {
        ASList *l = [ASList new];
        long n = 0;
        AECountItems(d, &n);
        for (long i = 1; i <= n; i++) {
            AEDesc item = {typeNull, NULL};
            AEKeyword k;
            if (AEGetNthDesc(d, i, typeWildCard, &k, &item) == noErr)
                [l.items addObject:desc_value(&item)];
            AEDisposeDesc(&item);
        }
        return l;
    }
    case typeAERecord: {
        ASRecord *r = [ASRecord new];
        long n = 0;
        AECountItems(d, &n);
        for (long i = 1; i <= n; i++) {
            AEDesc item = {typeNull, NULL};
            AEKeyword k = 0;
            if (AEGetNthDesc(d, i, typeWildCard, &k, &item) != noErr)
                continue;
            if (k == keyASUserRecordFields) {
                ASList *f = desc_value(&item);
                for (NSUInteger j = 0; j + 1 < f.count; j += 2)
                    [r setValue:[f objectAtIndex:j + 1] forField:ASText([f objectAtIndex:j])];
            } else {
                [r setValue:desc_value(&item)
                    forField:[NSString stringWithFormat:@"«class %c%c%c%c»", (char)(k >> 24), (char)(k >> 16), (char)(k >> 8), (char)k]];
            }
            AEDisposeDesc(&item);
        }
        return r;
    }
    default: {
        NSString *s = desc_text(d);
        return s ?: [ASConstant missingValue];
    }
    }
}

/* the value in human form: text without quotes, lists without braces */
static NSString *
human(id v)
{
    if ([v isKindOfClass:[NSString class]])
        return v;
    if ([v isKindOfClass:[ASList class]]) {
        NSMutableArray *a = [NSMutableArray array];
        for (id x in ((ASList *)v).items)
            [a addObject:human(x)];
        return [a componentsJoinedByString:@", "];
    }
    if ([v isKindOfClass:[ASRecord class]]) {
        NSMutableArray *a = [NSMutableArray array];
        for (NSString *k in ((ASRecord *)v).keys)
            [a addObject:[NSString stringWithFormat:@"%@:%@", k, human([(ASRecord *)v valueForField:k])]];
        return [a componentsJoinedByString:@", "];
    }
    return ASDisplay(v);
}

/* ---- the scripting component ---- */

static struct ComponentInstanceRecord the_instance;

ComponentInstance
_FinchOSAComponentInstance(void)
{
    return &the_instance;
}

OSAError
OSAScriptingComponentName(ComponentInstance ci, AEDesc *result)
{
    return text_desc(@"AppleScript English", typeChar, result);
}

OSAError
ASInit(ComponentInstance ci, SInt32 modeFlags, UInt32 minStackSize, UInt32 preferredStackSize, UInt32 maxStackSize, UInt32 minHeapSize,
       UInt32 preferredHeapSize, UInt32 maxHeapSize)
{
    return noErr;
}

/* ---- compiling ---- */

static OSAError
compile(NSString *source, OSAID *io)
{
    if (!source)
        return errOSABadStorageType;
    ASScript *s;
    @try {
        s = [ASScript compile:source];
    } @catch (ASError *e) {
        return script_error(e, e.hasRange ? e.range : NSMakeRange(0, 0));
    }
    FinchOSAEntry *existing = io && *io ? entry(*io) : nil;
    if (existing) {
        existing.script = s;
        existing.value = nil;
        existing.modified = YES;
        return noErr;
    }
    FinchOSAEntry *e = [FinchOSAEntry new];
    e.script = s;
    *io = add_entry(e);
    return noErr;
}

OSAError
OSACompile(ComponentInstance ci, const AEDesc *sourceData, SInt32 modeFlags, OSAID *previousAndResultingScriptID)
{
    return compile(desc_text(sourceData), previousAndResultingScriptID);
}

OSAError
OSAMakeContext(ComponentInstance ci, const AEDesc *contextName, OSAID parentContext, OSAID *resultingContextID)
{
    return compile(@"", resultingContextID);
}

OSAError
OSAGetSource(ComponentInstance ci, OSAID scriptID, DescType desiredType, AEDesc *result)
{
    FinchOSAEntry *e = entry(scriptID);
    if (!e)
        return errOSAInvalidID;
    if (e.value)
        return text_desc(ASDisplay(e.value), desiredType, result);
    if (!e.script.source)
        return errOSASourceNotAvailable;
    return text_desc(ASFormatSource(e.script.source), desiredType == typeWildCard ? typeUnicodeText : desiredType, result);
}

/* ---- source styles ---- */

/* AppleScript's default styles: Verdana 12 with uncompiled text in Menlo. AppKit is loaded
   only when a client asks (Script Editor has it already). */
static NSArray *
default_attributes(void)
{
    Class Font = NSClassFromString(@"NSFont"), Color = NSClassFromString(@"NSColor");
    if (!Font || !Color)
        return @[];
    id (^font)(NSString *) = ^id(NSString *name) {
        id f = ((id(*)(Class, SEL, id, CGFloat))objc_msgSend)(Font, sel_registerName("fontWithName:size:"), name, 12);
        return f ?: ((id(*)(Class, SEL, CGFloat))objc_msgSend)(Font, sel_registerName("userFontOfSize:"), 12);
    };
    id (^rgb)(CGFloat, CGFloat, CGFloat) = ^id(CGFloat r, CGFloat g, CGFloat b) {
        return ((id(*)(Class, SEL, CGFloat, CGFloat, CGFloat, CGFloat))objc_msgSend)(Color, sel_registerName("colorWithCalibratedRed:green:blue:alpha:"),
                                                                                    r, g, b, 1);
    };
    id plain = font(@"Verdana"), bold = font(@"Verdana-Bold"), italic = font(@"Verdana-Italic");
    id black = rgb(0, 0, 0), blue = rgb(0, 0, 1), command = rgb(0, 0.087, 0.69), property = rgb(0.42, 0.02, 0.83), dynamic = rgb(0.27, 0.08, 0.69);
    NSArray *styles = @[
        @[ font(@"Menlo-Regular"), rgb(0.5, 0, 0.5) ], /* uncompiled */
        @[ plain, black ],                             /* normal */
        @[ bold, black ],                              /* language keywords */
        @[ plain, blue ],                              /* application keywords */
        @[ plain, rgb(0.3, 0.305, 0.305) ],            /* comments */
        @[ plain, black ],                             /* literals */
        @[ plain, rgb(0.25, 0.5, 0) ],                 /* variables */
        @[ plain, black ],                             /* strings */
        @[ bold, blue ],                               /* commands */
        @[ plain, blue ],                              /* parameters */
        @[ italic, blue ],                             /* classes */
        @[ plain, property ],                          /* properties */
        @[ italic, property ],                         /* enumerated values */
        @[ bold, command ],                            /* scripting-addition commands */
        @[ plain, command ],                           /* their parameters */
        @[ italic, command ],                          /* their classes */
        @[ plain, dynamic ],                           /* their properties */
        @[ italic, dynamic ],                          /* their enumerated values */
    ];
    NSMutableArray *out = [NSMutableArray array];
    for (NSArray *st in styles)
        [out addObject:@{@"NSFont" : st[0], @"NSColor" : st[1]}];
    return out;
}

static NSArray *
attributes(void)
{
    if (source_attributes)
        return (__bridge NSArray *)source_attributes;
    static NSArray *defaults;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        defaults = default_attributes();
    });
    return defaults;
}

OSAError
ASCopySourceAttributes(ComponentInstance ci, CFArrayRef *result)
{
    if (!result)
        return paramErr;
    *result = CFBridgingRetain([attributes() copy]);
    return noErr;
}

OSAError
ASSetSourceAttributes(ComponentInstance ci, CFArrayRef sourceAttributes)
{
    if (source_attributes)
        CFRelease(source_attributes);
    source_attributes = sourceAttributes ? CFRetain(sourceAttributes) : NULL;
    return noErr;
}

OSAError
ASGetSourceStyleNames(ComponentInstance ci, SInt32 modeFlags, AEDescList *result)
{
    NSArray *names = @[
        @"New text (uncompiled)", @"Operators, etc.", @"Language keywords", @"Application keywords", @"Comments", @"Values",
        @"Variables and subroutine names", @"Strings", @"Command names", @"Parameter names", @"Classes", @"Properties",
        @"Enumerated values", @"Additions command names", @"Additions parameter names", @"Additions classes", @"Additions properties",
        @"Additions enumerated values"
    ];
    OSErr e = AECreateList(NULL, 0, false, result);
    for (NSString *n in names) {
        AEDesc d = {typeNull, NULL};
        text_desc(n, typeChar, &d);
        AEPutDesc(result, 0, &d);
        AEDisposeDesc(&d);
    }
    return e;
}

OSAError
ASSetSourceStyles(ComponentInstance ci, STHandle sourceStyles)
{
    return noErr;
}

OSAError
ASGetSourceStyles(ComponentInstance ci, STHandle *resultingSourceStyles)
{
    return errOSABadSelector;
}

/* compiled source, styled; run styles from the scripting additions where Apple's does */
CFAttributedStringRef
_FinchOSAStyledSource(NSString *source)
{
    NSString *text = ASFormatSource(source);
    NSArray *attrs = attributes();
    NSMutableAttributedString *s = [[NSMutableAttributedString alloc] initWithString:text attributes:attrs.count > kASStyleNormal ? attrs[kASStyleNormal] : @{}];
    for (NSArray<NSNumber *> *run in ASSourceStyleRuns(text)) {
        NSUInteger style = run[2].unsignedIntegerValue;
        if (style == kASStyleEventName)
            style = 13;
        else if (style == kASStyleParameterName)
            style = 14;
        if (style < attrs.count)
            [s setAttributes:attrs[style] range:NSMakeRange(run[0].unsignedIntegerValue, run[1].unsignedIntegerValue)];
    }
    return CFBridgingRetain(s);
}

OSAError
OSACopySourceString(ComponentInstance ci, OSAID scriptID, SInt32 modeFlags, CFAttributedStringRef *result)
{
    FinchOSAEntry *e = entry(scriptID);
    if (!e)
        return errOSAInvalidID;
    if (!e.script.source)
        return errOSASourceNotAvailable;
    *result = _FinchOSAStyledSource(e.script.source);
    return noErr;
}

/* ---- running ---- */

static OSAError
run(FinchOSAEntry *e, NSString *handler, NSArray *args, OSAID *result)
{
    ASInterpreter *in = [ASInterpreter new];
    in.logHandler = ^(NSString *line) {
        fprintf(stderr, "%s\n", line.UTF8String);
    };
    id v;
    @try {
        v = handler ? [in run:e.script handler:handler arguments:args] : [in run:e.script];
    } @catch (ASError *x) {
        return script_error(x, x.hasRange ? x.range : NSMakeRange(0, 0));
    }
    e.modified = YES;
    if (result) {
        if (v) {
            FinchOSAEntry *r = [FinchOSAEntry new];
            r.value = v;
            *result = add_entry(r);
        } else
            *result = kOSANullScript;
    }
    return noErr;
}

OSAError
OSAExecute(ComponentInstance ci, OSAID compiledScriptID, OSAID contextID, SInt32 modeFlags, OSAID *resultingScriptValueID)
{
    FinchOSAEntry *e = entry(compiledScriptID);
    if (!e || !e.script)
        return errOSAInvalidID;
    return run(e, nil, nil, resultingScriptValueID);
}

OSAError
OSADisplay(ComponentInstance ci, OSAID scriptValueID, DescType desiredType, SInt32 modeFlags, AEDesc *result)
{
    FinchOSAEntry *e = entry(scriptValueID);
    if (!e)
        return errOSAInvalidID;
    id v = e.value ?: e.script;
    NSString *s = (modeFlags & kOSAModeDisplayForHumans) ? human(v) : ASDisplay(v);
    return text_desc(s, desiredType == typeWildCard ? typeUnicodeText : desiredType, result);
}

OSAError
OSACopyDisplayString(ComponentInstance ci, OSAID scriptID, SInt32 modeFlags, CFAttributedStringRef *result)
{
    FinchOSAEntry *e = entry(scriptID);
    if (!e)
        return errOSAInvalidID;
    id v = e.value ?: e.script;
    NSString *s = (modeFlags & kOSAModeDisplayForHumans) ? human(v) : ASDisplay(v);
    *result = _FinchOSAStyledSource(s);
    return noErr;
}

OSAError
OSACompileExecute(ComponentInstance ci, const AEDesc *sourceData, OSAID contextID, SInt32 modeFlags, OSAID *resultingScriptValueID)
{
    OSAID s = 0;
    OSAError err = OSACompile(ci, sourceData, modeFlags, &s);
    if (err)
        return err;
    err = OSAExecute(ci, s, contextID, modeFlags, resultingScriptValueID);
    OSADispose(ci, s);
    return err;
}

OSAError
OSADoScript(ComponentInstance ci, const AEDesc *sourceData, OSAID contextID, DescType desiredType, SInt32 modeFlags, AEDesc *resultingText)
{
    OSAID v = 0;
    OSAError err = OSACompileExecute(ci, sourceData, contextID, modeFlags, &v);
    if (err)
        return err;
    if (!v)
        return text_desc(@"", desiredType, resultingText);
    err = OSADisplay(ci, v, desiredType, modeFlags, resultingText);
    OSADispose(ci, v);
    return err;
}

/* an event to a script: run (aevt/oapp), open (aevt/odoc), or a handler by name (subroutine calls) */
OSAError
OSAExecuteEvent(ComponentInstance ci, const AppleEvent *event, OSAID contextID, SInt32 modeFlags, OSAID *resultingScriptValueID)
{
    FinchOSAEntry *e = entry(contextID);
    if (!e || !e.script)
        return errOSAInvalidID;
    DescType cls = 0, eid = 0, t;
    Size sz;
    AEGetAttributePtr(event, keyEventClassAttr, typeType, &t, &cls, sizeof cls, &sz);
    AEGetAttributePtr(event, keyEventIDAttr, typeType, &t, &eid, sizeof eid, &sz);
    if (cls == kCoreEventClass && (eid == kAEOpenApplication || eid == kAEOpenDocuments)) {
        NSMutableArray *args = [NSMutableArray array];
        AEDesc direct = {typeNull, NULL};
        if (AEGetParamDesc(event, keyDirectObject, typeWildCard, &direct) == noErr) {
            [args addObject:desc_value(&direct)];
            AEDisposeDesc(&direct);
        }
        if (eid == kAEOpenDocuments)
            return e.script.handlers[@"open"] ? run(e, @"open", args, resultingScriptValueID) : errAEEventNotHandled;
        return run(e, e.script.handlers[@"run"] ? @"run" : nil, args.count ? args : nil, resultingScriptValueID);
    }
    if (cls == kASAppleScriptSuite && eid == kASSubroutineEvent) {
        AEDesc name = {typeNull, NULL}, params = {typeNull, NULL};
        if (AEGetParamDesc(event, keyASSubroutineName, typeWildCard, &name) != noErr)
            return errAEEventNotHandled;
        NSString *n = desc_text(&name);
        AEDisposeDesc(&name);
        NSArray *args = @[];
        if (AEGetParamDesc(event, keyDirectObject, typeAEList, &params) == noErr) {
            args = ((ASList *)desc_value(&params)).items;
            AEDisposeDesc(&params);
        }
        if (!e.script.handlers[n.lowercaseString])
            return errAEEventNotHandled;
        return run(e, n, args, resultingScriptValueID);
    }
    return errAEEventNotHandled;
}

OSAError
OSADoEvent(ComponentInstance ci, const AppleEvent *event, OSAID contextID, SInt32 modeFlags, AppleEvent *reply)
{
    OSAID v = 0;
    OSAError err = OSAExecuteEvent(ci, event, contextID, modeFlags, &v);
    if (reply && reply->descriptorType != typeNull) {
        if (err == errOSAScriptError && last_error) {
            SInt32 n = (SInt32)last_error.number;
            AEPutParamPtr(reply, keyErrorNumber, typeSInt32, &n, sizeof n);
            AEDesc m = {typeNull, NULL};
            text_desc(last_error.reason ?: @"", typeUnicodeText, &m);
            AEPutParamDesc(reply, keyErrorString, &m);
            AEDisposeDesc(&m);
        } else if (!err && v) {
            AEDesc r = {typeNull, NULL};
            if (OSACoerceToDesc(ci, v, typeWildCard, modeFlags, &r) == noErr)
                AEPutParamDesc(reply, keyDirectObject, &r);
            AEDisposeDesc(&r);
        }
    }
    if (v)
        OSADispose(ci, v);
    return err;
}

/* ---- errors ---- */

OSAError
OSAScriptError(ComponentInstance ci, OSType selector, DescType desiredType, AEDesc *result)
{
    if (!last_error)
        return errOSAInvalidID;
    switch (selector) {
    case kOSAErrorNumber: {
        SInt32 n = (SInt32)last_error.number;
        if (desiredType == typeSInt16) {
            SInt16 s = (SInt16)n;
            return AECreateDesc(typeSInt16, &s, sizeof s, result);
        }
        return AECreateDesc(typeSInt32, &n, sizeof n, result);
    }
    case kOSAErrorMessage:
    case kOSAErrorBriefMessage:
        return text_desc(last_error.reason ?: @"", desiredType == typeWildCard ? typeUnicodeText : desiredType, result);
    case kOSAErrorPartialResult:
        return last_error.partialResult ? value_desc(last_error.partialResult, result) : AECreateDesc(typeNull, NULL, 0, result);
    case kOSAErrorOffendingObject:
        return last_error.offendingObject ? value_desc(last_error.offendingObject, result) : AECreateDesc(typeNull, NULL, 0, result);
    case kOSAErrorExpectedType:
        return AECreateDesc(typeNull, NULL, 0, result);
    case kOSAErrorApp:
        return AECreateDesc(typeNull, NULL, 0, result);
    case kOSAErrorRange: {
        AEDesc r = {typeNull, NULL};
        OSErr e = AECreateList(NULL, 0, true, &r);
        SInt16 a = (SInt16)MIN(last_range.location, (NSUInteger)INT16_MAX), b = (SInt16)MIN(NSMaxRange(last_range), (NSUInteger)INT16_MAX);
        AEPutParamPtr(&r, keyOSASourceStart, typeSInt16, &a, sizeof a);
        AEPutParamPtr(&r, keyOSASourceEnd, typeSInt16, &b, sizeof b);
        if (!e)
            e = AECoerceDesc(&r, typeOSAErrorRange, result);
        if (e) {
            r.descriptorType = typeOSAErrorRange;
            *result = r;
            return noErr;
        }
        AEDisposeDesc(&r);
        return e;
    }
    }
    return errOSABadSelector;
}

/* ---- IDs ---- */

OSAError
OSADispose(ComponentInstance ci, OSAID scriptID)
{
    setup();
    [lock lock];
    [table removeObjectForKey:@(scriptID)];
    [lock unlock];
    return noErr;
}

OSAError
OSACopyID(ComponentInstance ci, OSAID fromID, OSAID *toID)
{
    FinchOSAEntry *e = entry(fromID);
    if (!e)
        return errOSAInvalidID;
    FinchOSAEntry *to = *toID ? entry(*toID) : nil;
    if (!to) {
        to = [FinchOSAEntry new];
        *toID = add_entry(to);
    }
    to.script = e.script;
    to.value = e.value;
    return noErr;
}

OSAError
OSACopyScript(ComponentInstance ci, OSAID fromID, OSAID *toID)
{
    FinchOSAEntry *e = entry(fromID);
    if (!e)
        return errOSAInvalidID;
    FinchOSAEntry *c = [FinchOSAEntry new];
    if (e.script) {
        c.script = [ASScript compile:e.script.source ?: @""];
        [c.script.properties addEntriesFromDictionary:e.script.properties];
    }
    c.value = e.value;
    *toID = add_entry(c);
    return noErr;
}

OSAError
OSASetScriptInfo(ComponentInstance ci, OSAID scriptID, OSType selector, long value)
{
    FinchOSAEntry *e = entry(scriptID);
    if (!e)
        return errOSAInvalidID;
    if (selector == kOSAScriptIsModified)
        e.modified = value != 0;
    return noErr;
}

OSAError
OSAGetScriptInfo(ComponentInstance ci, OSAID scriptID, OSType selector, long *result)
{
    FinchOSAEntry *e = entry(scriptID);
    if (!e)
        return errOSAInvalidID;
    switch (selector) {
    case kOSAScriptIsModified:
        *result = e.modified;
        return noErr;
    case kOSAScriptIsTypeCompiledScript:
        *result = e.script != nil;
        return noErr;
    case kOSAScriptIsTypeScriptValue:
        *result = e.value != nil;
        return noErr;
    case kOSAScriptIsTypeScriptContext:
        *result = e.script != nil;
        return noErr;
    case kOSAScriptBestType:
        *result = typeOSAGenericStorage;
        return noErr;
    case kOSACanGetSource:
        *result = e.script.source != nil || e.value != nil;
        return noErr;
    case kASHasOpenHandler:
        *result = e.script.handlers[@"open"] != nil;
        return noErr;
    }
    return errOSABadSelector;
}

/* ---- values and descriptors ---- */

OSAError
OSACoerceFromDesc(ComponentInstance ci, const AEDesc *scriptData, SInt32 modeFlags, OSAID *resultingScriptID)
{
    FinchOSAEntry *e = [FinchOSAEntry new];
    e.value = desc_value(scriptData);
    *resultingScriptID = add_entry(e);
    return noErr;
}

OSAError
OSACoerceToDesc(ComponentInstance ci, OSAID scriptID, DescType desiredType, SInt32 modeFlags, AEDesc *result)
{
    FinchOSAEntry *e = entry(scriptID);
    if (!e)
        return errOSAInvalidID;
    AEDesc d = {typeNull, NULL};
    OSErr err = value_desc(e.value ?: e.script, &d);
    if (err)
        return err;
    if (desiredType == typeWildCard || desiredType == d.descriptorType) {
        *result = d;
        return noErr;
    }
    err = AECoerceDesc(&d, desiredType, result);
    AEDisposeDesc(&d);
    return err;
}

/* ---- storing and loading ---- */

static const char magic[4] = {'F', 'n', 'A', 'S'};

OSAError
OSAStore(ComponentInstance ci, OSAID scriptID, DescType desiredType, SInt32 modeFlags, AEDesc *result)
{
    FinchOSAEntry *e = entry(scriptID);
    if (!e || !e.script)
        return errOSAInvalidID;
    if (desiredType != typeOSAGenericStorage && desiredType != kOSAScriptResourceType && desiredType != typeAppleScript &&
        desiredType != typeWildCard)
        return errOSABadStorageType;
    NSMutableData *d = [NSMutableData dataWithBytes:magic length:4];
    uint32_t version = 1;
    [d appendBytes:&version length:4];
    [d appendData:[(e.script.source ?: @"") dataUsingEncoding:NSUTF8StringEncoding]];
    return AECreateDesc(typeOSAGenericStorage, d.bytes, (Size)d.length, result);
}

static NSString *
stored_source(NSData *d, OSAError *err)
{
    if (d.length >= 8 && !memcmp(d.bytes, magic, 4))
        return [[NSString alloc] initWithData:[d subdataWithRange:NSMakeRange(8, d.length - 8)] encoding:NSUTF8StringEncoding];
    if (d.length >= 7 && !memcmp(d.bytes, "FasdUAS", 7)) {
        *err = errOSADataFormatTooNew;
        return nil;
    }
    /* text */
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (!s)
        *err = errOSABadStorageType;
    return s;
}

OSAError
OSALoad(ComponentInstance ci, const AEDesc *scriptData, SInt32 modeFlags, OSAID *resultingScriptID)
{
    Size n = AEGetDescDataSize(scriptData);
    NSMutableData *d = [NSMutableData dataWithLength:(NSUInteger)n];
    AEGetDescData(scriptData, d.mutableBytes, n);
    OSAError err = noErr;
    NSString *src = scriptData->descriptorType == typeUnicodeText || scriptData->descriptorType == typeUTF8Text ||
                            scriptData->descriptorType == typeChar
                        ? desc_text(scriptData)
                        : stored_source(d, &err);
    if (!src)
        return err ?: errOSABadStorageType;
    *resultingScriptID = 0;
    return compile(src, resultingScriptID);
}

OSAError
OSALoadExecute(ComponentInstance ci, const AEDesc *scriptData, OSAID contextID, SInt32 modeFlags, OSAID *resultingScriptValueID)
{
    OSAID s = 0;
    OSAError err = OSALoad(ci, scriptData, modeFlags, &s);
    if (err)
        return err;
    err = OSAExecute(ci, s, contextID, modeFlags, resultingScriptValueID);
    OSADispose(ci, s);
    return err;
}

/* the script file inside a bundle, or the file */
static NSURL *
script_file(NSURL *url)
{
    BOOL dir = NO;
    if ([[NSFileManager defaultManager] fileExistsAtPath:url.path isDirectory:&dir] && dir) {
        NSURL *main = [url URLByAppendingPathComponent:@"Contents/Resources/Scripts/main.scpt"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:main.path])
            return main;
        return [url URLByAppendingPathComponent:@"Contents/Resources/Scripts/main.applescript"];
    }
    return url;
}

OSAError
OSAGetScriptDataFromURL(CFURLRef scriptURL, Boolean *storable, SInt32 modeFlags, AEDesc *resultingScriptData)
{
    NSURL *u = script_file((__bridge NSURL *)scriptURL);
    NSData *d = [NSData dataWithContentsOfURL:u];
    if (!d)
        return fnfErr;
    BOOL text = [u.pathExtension.lowercaseString isEqualToString:@"applescript"];
    if (storable)
        *storable = !text;
    if (text)
        return AECreateDesc(typeUTF8Text, d.bytes, (Size)d.length, resultingScriptData);
    return AECreateDesc(typeOSAGenericStorage, d.bytes, (Size)d.length, resultingScriptData);
}

OSAError
OSALoadScriptData(ComponentInstance ci, const AEDesc *scriptData, CFURLRef fromURL, SInt32 modeFlags, OSAID *resultingScriptID)
{
    return OSALoad(ci, scriptData, modeFlags, resultingScriptID);
}

static NSURL *
fsref_url(const FSRef *ref)
{
    return CFBridgingRelease(CFURLCreateFromFSRef(NULL, ref));
}

OSAError
OSALoadFile(ComponentInstance ci, const FSRef *scriptFile, Boolean *storable, SInt32 modeFlags, OSAID *resultingScriptID)
{
    NSURL *u = fsref_url(scriptFile);
    if (!u)
        return fnfErr;
    AEDesc d = {typeNull, NULL};
    OSAError err = OSAGetScriptDataFromURL((__bridge CFURLRef)u, storable, modeFlags, &d);
    if (err)
        return err;
    err = OSALoad(ci, &d, modeFlags, resultingScriptID);
    AEDisposeDesc(&d);
    return err;
}

OSAError
OSAStoreFile(ComponentInstance ci, OSAID scriptID, DescType desiredType, SInt32 modeFlags, const FSRef *scriptFile)
{
    NSURL *u = fsref_url(scriptFile);
    if (!u)
        return fnfErr;
    AEDesc d = {typeNull, NULL};
    OSAError err = OSAStore(ci, scriptID, desiredType, modeFlags, &d);
    if (err)
        return err;
    Size n = AEGetDescDataSize(&d);
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)n];
    AEGetDescData(&d, data.mutableBytes, n);
    AEDisposeDesc(&d);
    return [data writeToURL:script_file(u) atomically:YES] ? noErr : ioErr;
}

OSAError
OSALoadExecuteFile(ComponentInstance ci, const FSRef *scriptFile, OSAID contextID, SInt32 modeFlags, OSAID *resultingScriptValueID)
{
    OSAID s = 0;
    OSAError err = OSALoadFile(ci, scriptFile, NULL, modeFlags, &s);
    if (err)
        return err;
    err = OSAExecute(ci, s, contextID, modeFlags, resultingScriptValueID);
    OSADispose(ci, s);
    return err;
}

OSAError
OSADoScriptFile(ComponentInstance ci, const FSRef *scriptFile, OSAID contextID, DescType desiredType, SInt32 modeFlags, AEDesc *resultingText)
{
    OSAID v = 0;
    OSAError err = OSALoadExecuteFile(ci, scriptFile, contextID, modeFlags, &v);
    if (err)
        return err;
    if (!v)
        return text_desc(@"", desiredType, resultingText);
    err = OSADisplay(ci, v, desiredType, modeFlags, resultingText);
    OSADispose(ci, v);
    return err;
}

/* ---- properties and handlers of a script ---- */

OSAError
OSAGetPropertyNames(ComponentInstance ci, SInt32 modeFlags, OSAID contextID, AEDescList *result)
{
    FinchOSAEntry *e = entry(contextID);
    if (!e || !e.script)
        return errOSAInvalidID;
    AECreateList(NULL, 0, false, result);
    for (NSString *k in e.script.properties) {
        AEDesc d = {typeNull, NULL};
        text_desc(k, typeUnicodeText, &d);
        AEPutDesc(result, 0, &d);
        AEDisposeDesc(&d);
    }
    return noErr;
}

OSAError
OSAGetProperty(ComponentInstance ci, SInt32 modeFlags, OSAID contextID, const AEDesc *variableName, OSAID *result)
{
    FinchOSAEntry *e = entry(contextID);
    if (!e || !e.script)
        return errOSAInvalidID;
    id v = e.script.properties[desc_text(variableName).lowercaseString];
    if (!v)
        return errOSAScriptError;
    FinchOSAEntry *r = [FinchOSAEntry new];
    r.value = v;
    *result = add_entry(r);
    return noErr;
}

OSAError
OSASetProperty(ComponentInstance ci, SInt32 modeFlags, OSAID contextID, const AEDesc *variableName, OSAID scriptValueID)
{
    FinchOSAEntry *e = entry(contextID), *v = entry(scriptValueID);
    if (!e || !e.script || !v)
        return errOSAInvalidID;
    e.script.properties[desc_text(variableName).lowercaseString] = v.value ?: v.script;
    return noErr;
}

OSAError
OSAGetHandlerNames(ComponentInstance ci, SInt32 modeFlags, OSAID contextID, AEDescList *result)
{
    FinchOSAEntry *e = entry(contextID);
    if (!e || !e.script)
        return errOSAInvalidID;
    AECreateList(NULL, 0, false, result);
    for (ASHandler *h in e.script.handlers.allValues) {
        AEDesc d = {typeNull, NULL};
        text_desc(h.name, typeUnicodeText, &d);
        AEPutDesc(result, 0, &d);
        AEDisposeDesc(&d);
    }
    return noErr;
}

OSAError
OSAGetHandler(ComponentInstance ci, SInt32 modeFlags, OSAID contextID, const AEDesc *handlerName, OSAID *result)
{
    FinchOSAEntry *e = entry(contextID);
    if (!e || !e.script)
        return errOSAInvalidID;
    ASHandler *h = e.script.handlers[desc_text(handlerName).lowercaseString];
    if (!h)
        return errOSAScriptError;
    FinchOSAEntry *r = [FinchOSAEntry new];
    r.value = h;
    *result = add_entry(r);
    return noErr;
}

OSAError
OSASetHandler(ComponentInstance ci, SInt32 modeFlags, OSAID contextID, const AEDesc *handlerName, OSAID compiledScriptID)
{
    return errOSABadSelector;
}

OSAError ASGetProperty(ComponentInstance ci, OSAID c, const AEDesc *n, OSAID *r) { return OSAGetProperty(ci, 0, c, n, r); }
OSAError ASSetProperty(ComponentInstance ci, OSAID c, const AEDesc *n, OSAID v) { return OSASetProperty(ci, 0, c, n, v); }
OSAError ASGetHandler(ComponentInstance ci, OSAID c, const AEDesc *n, OSAID *r) { return OSAGetHandler(ci, 0, c, n, r); }
OSAError ASSetHandler(ComponentInstance ci, OSAID c, const AEDesc *n, OSAID s) { return OSASetHandler(ci, 0, c, n, s); }

/* ---- procs ---- */

OSAError
OSASetActiveProc(ComponentInstance ci, OSAActiveUPP p, SRefCon r)
{
    active_proc = p;
    active_refcon = r;
    return noErr;
}

OSAError
OSAGetActiveProc(ComponentInstance ci, OSAActiveUPP *p, SRefCon *r)
{
    if (p)
        *p = active_proc;
    if (r)
        *r = active_refcon;
    return noErr;
}

OSAError
OSASetSendProc(ComponentInstance ci, OSASendUPP p, SRefCon r)
{
    send_proc = p;
    send_refcon = r;
    return noErr;
}

OSAError
OSAGetSendProc(ComponentInstance ci, OSASendUPP *p, SRefCon *r)
{
    if (p)
        *p = send_proc;
    if (r)
        *r = send_refcon;
    return noErr;
}

OSAError
OSASetCreateProc(ComponentInstance ci, OSACreateAppleEventUPP p, SRefCon r)
{
    create_proc = p;
    create_refcon = r;
    return noErr;
}

OSAError
OSAGetCreateProc(ComponentInstance ci, OSACreateAppleEventUPP *p, SRefCon *r)
{
    if (p)
        *p = create_proc;
    if (r)
        *r = create_refcon;
    return noErr;
}

OSAError
OSASetResumeDispatchProc(ComponentInstance ci, AEEventHandlerUPP p, SRefCon r)
{
    resume_proc = p;
    resume_refcon = r;
    return noErr;
}

OSAError
OSAGetResumeDispatchProc(ComponentInstance ci, AEEventHandlerUPP *p, SRefCon *r)
{
    if (p)
        *p = resume_proc;
    if (r)
        *r = resume_refcon;
    return noErr;
}

/* private: Script Editor's progress callbacks */
OSAError
OSASetCreateProgressProc(ComponentInstance ci, void *p, void *r)
{
    create_progress_proc = p;
    create_progress_refcon = r;
    return noErr;
}

OSAError
OSAGetCreateProgressProc(ComponentInstance ci, void **p, void **r)
{
    if (p)
        *p = create_progress_proc;
    if (r)
        *r = create_progress_refcon;
    return noErr;
}

OSAError
OSASetReleaseProgressProc(ComponentInstance ci, void *p, void *r)
{
    release_progress_proc = p;
    release_progress_refcon = r;
    return noErr;
}

OSAError
OSAGetReleaseProgressProc(ComponentInstance ci, void **p, void **r)
{
    if (p)
        *p = release_progress_proc;
    if (r)
        *r = release_progress_refcon;
    return noErr;
}

OSAError OSASetDefaultTarget(ComponentInstance ci, const AEAddressDesc *target) { return noErr; }
OSAError OSAStartRecording(ComponentInstance ci, OSAID *compiledScriptToModifyID) { return errOSABadSelector; }
OSAError OSAStopRecording(ComponentInstance ci, OSAID compiledScriptID) { return errOSABadSelector; }

/* ---- dialects ---- */

OSAError
OSASetCurrentDialect(ComponentInstance ci, short dialectCode)
{
    return dialectCode == 0 ? noErr : errOSANoSuchDialect;
}

OSAError
OSAGetCurrentDialect(ComponentInstance ci, short *resultingDialectCode)
{
    *resultingDialectCode = 0;
    return noErr;
}

OSAError
OSAAvailableDialectCodeList(ComponentInstance ci, AEDesc *result)
{
    AECreateList(NULL, 0, false, result);
    SInt16 code = 0;
    return AEPutPtr(result, 0, typeSInt16, &code, sizeof code);
}

OSAError
OSAGetDialectInfo(ComponentInstance ci, short dialectCode, OSType selector, AEDesc *result)
{
    if (dialectCode != 0)
        return errOSANoSuchDialect;
    if (selector == keyOSADialectName)
        return text_desc(@"English", typeChar, result);
    if (selector == keyOSADialectCode) {
        SInt16 c = 0;
        return AECreateDesc(typeSInt16, &c, sizeof c, result);
    }
    return errOSABadSelector;
}

OSAError
OSAAvailableDialects(ComponentInstance ci, AEDesc *result)
{
    AECreateList(NULL, 0, false, result);
    AEDesc info = {typeNull, NULL}, name = {typeNull, NULL};
    AECreateList(NULL, 0, true, &info);
    text_desc(@"English", typeChar, &name);
    AEPutParamDesc(&info, keyOSADialectName, &name);
    SInt16 c = 0;
    AEPutParamPtr(&info, keyOSADialectCode, typeSInt16, &c, sizeof c);
    AEPutDesc(result, 0, &info);
    AEDisposeDesc(&name);
    AEDisposeDesc(&info);
    return noErr;
}

/* ---- the generic component ---- */

OSAError
OSAGetDefaultScriptingComponent(ComponentInstance gci, ScriptingComponentSelector *scriptingSubType)
{
    *scriptingSubType = kAppleScriptSubtype;
    return noErr;
}

OSAError OSASetDefaultScriptingComponent(ComponentInstance gci, ScriptingComponentSelector s) { return noErr; }

OSAError
OSAGetScriptingComponent(ComponentInstance gci, ScriptingComponentSelector s, ComponentInstance *scriptingInstance)
{
    *scriptingInstance = &the_instance;
    return noErr;
}

OSAError
OSAGetScriptingComponentFromStored(ComponentInstance gci, const AEDesc *scriptData, ScriptingComponentSelector *scriptingSubType)
{
    *scriptingSubType = kAppleScriptSubtype;
    return noErr;
}

OSAError OSAGenericToRealID(ComponentInstance gci, OSAID *theScriptID, ComponentInstance *theExactComponent)
{
    if (theExactComponent)
        *theExactComponent = &the_instance;
    return noErr;
}

OSAError OSARealToGenericID(ComponentInstance gci, OSAID *theScriptID, ComponentInstance theExactComponent) { return noErr; }

/* ---- storage types on data ---- */

OSErr
OSAGetStorageType(AEDataStorage scriptData, DescType *dscType)
{
    *dscType = kAppleScriptSubtype;
    return noErr;
}

OSErr OSAAddStorageType(AEDataStorage scriptData, DescType dscType) { return noErr; }
OSErr OSARemoveStorageType(AEDataStorage scriptData) { return noErr; }

/* ---- terminology and scriptable files ---- */

OSAError
OSAGetSysTerminology(ComponentInstance ci, SInt32 modeFlags, short terminologyID, AEDesc *terminologyList)
{
    return errOSACantGetTerminology;
}

/* the sdef an application carries (OSAScriptingDefinition in its Info.plist) */
OSAError
OSACopyScriptingDefinitionFromURL(CFURLRef url, SInt32 modeFlags, CFDataRef *sdef)
{
    NSBundle *b = [NSBundle bundleWithURL:(__bridge NSURL *)url];
    NSString *name = [b objectForInfoDictionaryKey:@"OSAScriptingDefinition"];
    NSURL *f = name ? [b URLForResource:name.stringByDeletingPathExtension withExtension:name.pathExtension.length ? name.pathExtension : @"sdef"]
                    : nil;
    if (!f && [((__bridge NSURL *)url).pathExtension isEqualToString:@"sdef"])
        f = (__bridge NSURL *)url;
    NSData *d = f ? [NSData dataWithContentsOfURL:f] : nil;
    if (!d)
        return errOSACantGetTerminology;
    *sdef = CFBridgingRetain(d);
    return noErr;
}

OSAError
OSACopyScriptingDefinition(const FSRef *ref, SInt32 modeFlags, CFDataRef *sdef)
{
    NSURL *u = fsref_url(ref);
    return u ? OSACopyScriptingDefinitionFromURL((__bridge CFURLRef)u, modeFlags, sdef) : fnfErr;
}

Boolean
OSAIsScriptableURL(CFURLRef url)
{
    NSBundle *b = [NSBundle bundleWithURL:(__bridge NSURL *)url];
    return [b objectForInfoDictionaryKey:@"OSAScriptingDefinition"] != nil || [[b objectForInfoDictionaryKey:@"NSAppleScriptEnabled"] boolValue];
}

Boolean
OSAIsScriptableRef(const FSRef *ref)
{
    NSURL *u = fsref_url(ref);
    return u ? OSAIsScriptableURL((__bridge CFURLRef)u) : false;
}

/* the keys an applet's Info.plist uses */
const CFStringRef OSAAppletStayOpenKey = CFSTR("OSAAppletStayOpen");
const CFStringRef OSAAppletShowStartupScreenKey = CFSTR("OSAAppletShowStartupScreen");
