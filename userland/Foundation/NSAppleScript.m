/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSAppleScript, over the Open Scripting Architecture's calls (Finch's OpenScripting, in
 * Carbon), which Foundation looks up when a script is first compiled, as Apple's loads
 * the AppleScript component. A script keeps its source; compiling gives it an OSAID;
 * errors come back as dictionaries under the NSAppleScriptError keys.
 */
#import <Foundation/Foundation.h>
#include <CoreServices/CoreServices.h> /* types only: AE is NSAppleEventDescriptor's */
#include <dlfcn.h>

typedef SInt32 FinchOSAID;
static struct {
    ComponentInstance ci;
    OSErr (*compile)(ComponentInstance, const AEDesc *, SInt32, FinchOSAID *);
    OSErr (*execute)(ComponentInstance, FinchOSAID, FinchOSAID, SInt32, FinchOSAID *);
    OSErr (*executeEvent)(ComponentInstance, const AppleEvent *, FinchOSAID, SInt32, FinchOSAID *);
    OSErr (*coerceToDesc)(ComponentInstance, FinchOSAID, DescType, SInt32, AEDesc *);
    OSErr (*scriptError)(ComponentInstance, OSType, DescType, AEDesc *);
    OSErr (*dispose)(ComponentInstance, FinchOSAID);
    OSErr (*load)(ComponentInstance, const AEDesc *, SInt32, FinchOSAID *);
    OSErr (*getScriptData)(CFURLRef, Boolean *, SInt32, AEDesc *);
    OSErr (*copySourceString)(ComponentInstance, FinchOSAID, SInt32, CFAttributedStringRef *);
} osa;

static BOOL
load_osa(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/Frameworks/Carbon.framework/Carbon", RTLD_LAZY | RTLD_GLOBAL);
        if (!h)
            return;
        ComponentInstance (*open)(OSType, OSType) = (ComponentInstance (*)(OSType, OSType))dlsym(h, "OpenDefaultComponent");
        osa.compile = (OSErr (*)(ComponentInstance, const AEDesc *, SInt32, FinchOSAID *))dlsym(h, "OSACompile");
        osa.execute = (OSErr (*)(ComponentInstance, FinchOSAID, FinchOSAID, SInt32, FinchOSAID *))dlsym(h, "OSAExecute");
        osa.executeEvent = (OSErr (*)(ComponentInstance, const AppleEvent *, FinchOSAID, SInt32, FinchOSAID *))dlsym(h, "OSAExecuteEvent");
        osa.coerceToDesc = (OSErr (*)(ComponentInstance, FinchOSAID, DescType, SInt32, AEDesc *))dlsym(h, "OSACoerceToDesc");
        osa.scriptError = (OSErr (*)(ComponentInstance, OSType, DescType, AEDesc *))dlsym(h, "OSAScriptError");
        osa.dispose = (OSErr (*)(ComponentInstance, FinchOSAID))dlsym(h, "OSADispose");
        osa.load = (OSErr (*)(ComponentInstance, const AEDesc *, SInt32, FinchOSAID *))dlsym(h, "OSALoad");
        osa.getScriptData = (OSErr (*)(CFURLRef, Boolean *, SInt32, AEDesc *))dlsym(h, "OSAGetScriptDataFromURL");
        osa.copySourceString = (OSErr (*)(ComponentInstance, FinchOSAID, SInt32, CFAttributedStringRef *))dlsym(h, "OSACopySourceString");
        if (open)
            osa.ci = open('osa ', 'ascr');
    });
    return osa.ci && osa.compile && osa.execute;
}

/* the last OSA error, in NSAppleScript's form */
static NSDictionary *
error_info(OSErr err)
{
    if (err != -1753 /* errOSAScriptError */ || !osa.scriptError) {
        NSString *m = err == -1762 ? @"AppleScript isn’t available." : [NSString stringWithFormat:@"The script couldn’t be run (%d).", (int)err];
        return @{NSAppleScriptErrorNumber : @(err), NSAppleScriptErrorMessage : m, NSAppleScriptErrorBriefMessage : m};
    }
    /* (Foundation reads descriptors through NSAppleEventDescriptor, which loads AE itself) */
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    AEDesc a = {typeNull, NULL};
    if (osa.scriptError(osa.ci, keyErrorNumber, typeSInt32, &a) == noErr)
        d[NSAppleScriptErrorNumber] = @([[[[NSAppleEventDescriptor alloc] initWithAEDescNoCopy:&a] autorelease] int32Value]);
    if (osa.scriptError(osa.ci, keyErrorString, typeUnicodeText, &a) == noErr) {
        NSString *m = [[[NSAppleEventDescriptor alloc] initWithAEDescNoCopy:&a] autorelease].stringValue;
        if (m) {
            d[NSAppleScriptErrorMessage] = m;
            d[NSAppleScriptErrorBriefMessage] = m;
        }
    }
    if (osa.scriptError(osa.ci, 'erng', 'erng', &a) == noErr) {
        NSAppleEventDescriptor *r = [[[NSAppleEventDescriptor alloc] initWithAEDescNoCopy:&a] autorelease];
        SInt32 start = [r paramDescriptorForKeyword:'srcs'].int32Value, end = [r paramDescriptorForKeyword:'srce'].int32Value;
        d[NSAppleScriptErrorRange] = [NSValue valueWithRange:NSMakeRange((NSUInteger)start, (NSUInteger)MAX(end - start, 0))];
    }
    return d;
}

@implementation NSAppleScript

- (instancetype)initWithSource:(NSString *)source
{
    if ((self = [super init]))
        _source = [source copy];
    return self;
}

/* a text file keeps its source; a compiled script is loaded */
- (instancetype)initWithContentsOfURL:(NSURL *)url error:(NSDictionary<NSString *, id> **)errorInfo
{
    if (!(self = [super init]))
        return nil;
    AEDesc d = {typeNull, NULL};
    OSErr err = load_osa() && osa.getScriptData ? osa.getScriptData((CFURLRef)url, NULL, 0, &d) : -43;
    if (err == noErr && d.descriptorType == typeUTF8Text) {
        NSString *s = [[[NSAppleEventDescriptor alloc] initWithAEDescNoCopy:&d] autorelease].stringValue;
        _source = [s copy];
        return self;
    }
    if (err == noErr) {
        FinchOSAID i = 0;
        err = osa.load(osa.ci, &d, 0, &i);
        [[[NSAppleEventDescriptor alloc] initWithAEDescNoCopy:&d] release];
        _compiledScriptID = (unsigned int)i;
    }
    if (err) {
        if (errorInfo)
            *errorInfo = err == -43 ? @{NSAppleScriptErrorNumber : @(-43), NSAppleScriptErrorMessage : @"The file couldn’t be opened.",
                                        NSAppleScriptErrorBriefMessage : @"The file couldn’t be opened."}
                                    : error_info(err);
        [self release];
        return nil;
    }
    return self;
}

- (void)dealloc
{
    if (_compiledScriptID && osa.dispose)
        osa.dispose(osa.ci, (FinchOSAID)_compiledScriptID);
    [_source release];
    [super dealloc];
}

- (NSString *)source { return _source; }
- (BOOL)isCompiled { return _compiledScriptID != 0; }

- (BOOL)compileAndReturnError:(NSDictionary<NSString *, id> **)errorInfo
{
    if (_compiledScriptID)
        return YES;
    if (!load_osa()) {
        if (errorInfo)
            *errorInfo = error_info(-1762);
        return NO;
    }
    NSAppleEventDescriptor *src = [NSAppleEventDescriptor descriptorWithString:_source ?: @""];
    FinchOSAID i = 0;
    OSErr err = osa.compile(osa.ci, src.aeDesc, 0, &i);
    if (err) {
        if (errorInfo)
            *errorInfo = error_info(err);
        return NO;
    }
    _compiledScriptID = (unsigned int)i;
    return YES;
}

static NSAppleEventDescriptor *
result_descriptor(FinchOSAID v)
{
    if (!v)
        return [NSAppleEventDescriptor nullDescriptor];
    AEDesc d = {typeNull, NULL};
    OSErr err = osa.coerceToDesc(osa.ci, v, typeWildCard, 0, &d);
    osa.dispose(osa.ci, v);
    if (err)
        return [NSAppleEventDescriptor nullDescriptor];
    return [[[NSAppleEventDescriptor alloc] initWithAEDescNoCopy:&d] autorelease];
}

- (NSAppleEventDescriptor *)executeAndReturnError:(NSDictionary<NSString *, id> **)errorInfo
{
    if (![self compileAndReturnError:errorInfo])
        return nil;
    FinchOSAID v = 0;
    OSErr err = osa.execute(osa.ci, (FinchOSAID)_compiledScriptID, 0, 0, &v);
    if (err) {
        if (errorInfo)
            *errorInfo = error_info(err);
        return nil;
    }
    return result_descriptor(v);
}

- (NSAppleEventDescriptor *)executeAppleEvent:(NSAppleEventDescriptor *)event error:(NSDictionary<NSString *, id> **)errorInfo
{
    if (![self compileAndReturnError:errorInfo])
        return nil;
    FinchOSAID v = 0;
    OSErr err = osa.executeEvent ? osa.executeEvent(osa.ci, event.aeDesc, (FinchOSAID)_compiledScriptID, 0, &v) : -1762;
    if (err) {
        if (errorInfo)
            *errorInfo = error_info(err);
        return nil;
    }
    return result_descriptor(v);
}

/* for AppKit's richTextSource: the compiled source, styled */
- (NSAttributedString *)_finchRichTextSource
{
    if (![self compileAndReturnError:NULL] || !osa.copySourceString)
        return nil;
    CFAttributedStringRef s = NULL;
    if (osa.copySourceString(osa.ci, (FinchOSAID)_compiledScriptID, 0, &s) != noErr)
        return nil;
    return [(NSAttributedString *)s autorelease];
}

- (id)copyWithZone:(NSZone *)zone { return [[NSAppleScript alloc] initWithSource:_source]; }

@end
