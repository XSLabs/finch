/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * OSAKit: languages and scripts, Finch's, over the OSA calls in Finch's OpenScripting.
 * There is one language, AppleScript. A script keeps its source until it compiles, then
 * an OSAID in the language's component; running it gives an NSAppleEventDescriptor and
 * errors come back as dictionaries (or NSErrors) under the OSAScriptError keys.
 */
#import <OSAKit/OSAKit.h>
#import "OSAKit_Finch.h"

NSString *const OSAScriptErrorMessageKey = @"OSAScriptErrorMessageKey";
NSString *const OSAScriptErrorBriefMessageKey = @"OSAScriptErrorBriefMessageKey";
NSString *const OSAScriptErrorNumberKey = @"OSAScriptErrorNumberKey";
NSString *const OSAScriptErrorPartialResultKey = @"OSAScriptErrorPartialResultKey";
NSString *const OSAScriptErrorOffendingObjectKey = @"OSAScriptErrorOffendingObjectKey";
NSString *const OSAScriptErrorExpectedTypeKey = @"OSAScriptErrorExpectedTypeKey";
NSString *const OSAScriptErrorAppAddressKey = @"OSAScriptErrorAppAddressKey";
NSString *const OSAScriptErrorAppNameKey = @"OSAScriptErrorAppNameKey";
NSString *const OSAScriptErrorRangeKey = @"OSAScriptErrorRangeKey";
NSString *const OSAScriptErrorMessage = @"OSAScriptErrorMessageKey";
NSString *const OSAScriptErrorNumber = @"OSAScriptErrorNumberKey";
NSString *const OSAScriptErrorAppName = @"OSAScriptErrorAppNameKey";
NSString *const OSAScriptErrorBriefMessage = @"OSAScriptErrorBriefMessageKey";
NSString *const OSAScriptErrorRange = @"OSAScriptErrorRangeKey";
NSString *const OSAStorageScriptType = @"script";
NSString *const OSAStorageScriptBundleType = @"script bundle";
NSString *const OSAStorageApplicationType = @"application";
NSString *const OSAStorageApplicationBundleType = @"application bundle";
NSString *const OSAStorageTextType = @"text";

/* ---- languages ---- */

@implementation OSALanguage {
    Component _component;
    ComponentInstance _instance;
    OSALanguageInstance *_shared;
}

static OSALanguage *default_language;

+ (OSALanguage *)_appleScript
{
    static OSALanguage *as;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ComponentDescription d = {kOSAComponentType, kAppleScriptSubtype, 'appl', 0, 0};
        as = [[OSALanguage alloc] initWithComponent:FindNextComponent(NULL, &d)];
    });
    return as;
}

+ (NSArray<OSALanguage *> *)availableLanguages { return @[ [self _appleScript] ]; }

+ (OSALanguage *)languageForName:(NSString *)name
{
    for (OSALanguage *l in [self availableLanguages])
        if ([l.name isEqualToString:name])
            return l;
    return nil;
}

+ (OSALanguage *)languageForSubType:(OSType)subType
{
    return subType == kAppleScriptSubtype || subType == kOSAGenericScriptingComponentSubtype ? [self _appleScript] : nil;
}

+ (OSALanguage *)languageForScriptDataDescriptor:(NSAppleEventDescriptor *)descriptor { return [self _appleScript]; }
+ (OSALanguage *)languageForScript:(OSAScript *)script { return script.language ?: [self _appleScript]; }
+ (OSALanguage *)defaultLanguage { return default_language ?: [self _appleScript]; }
+ (void)setDefaultLanguage:(OSALanguage *)language { default_language = language; }
+ (ComponentInstance)defaultAppleScriptComponentInstance { return [self _appleScript].componentInstance; }

- (instancetype)initWithComponent:(Component)component
{
    if ((self = [super init])) {
        _component = component;
        _instance = OpenComponent(component);
    }
    return self;
}

- (Component)component { return _component; }
- (ComponentInstance)componentInstance { return _instance; }

- (OSALanguageInstance *)sharedLanguageInstance
{
    @synchronized(self) {
        if (!_shared)
            _shared = [[OSALanguageInstance alloc] _initWithLanguage:self instance:_instance];
    }
    return _shared;
}

- (NSString *)name { return @"AppleScript"; }
- (NSString *)info { return @"AppleScript"; }
- (NSString *)version { return @"2.8"; }
- (OSType)type { return kOSAComponentType; }
- (OSType)subType { return kAppleScriptSubtype; }
- (OSType)manufacturer { return 'appl'; }
- (OSALanguageFeatures)features
{
    /* (and a bit above them all that Apple's sets) */
    return OSASupportsCompiling | OSASupportsGetSource | OSASupportsAECoercion | OSASupportsAESending | OSASupportsRecording |
           OSASupportsConvenience | OSASupportsDialects | OSASupportsEventHandling | 0x10000000;
}
- (BOOL)isThreadSafe { return NO; }
- (NSString *)description { return [NSString stringWithFormat:@"<OSALanguage %p: %@>", self, self.name]; }
@end

@implementation OSALanguageInstance {
    OSALanguage *_language;
    ComponentInstance _instance;
    NSAppleEventDescriptor *_defaultTarget;
}

+ (instancetype)languageInstanceWithLanguage:(OSALanguage *)language { return [[self alloc] initWithLanguage:language]; }

- (instancetype)initWithLanguage:(OSALanguage *)language
{
    /* the component keeps no per-instance state that matters yet: share its instance */
    return [self _initWithLanguage:language instance:language.componentInstance];
}

- (instancetype)_initWithLanguage:(OSALanguage *)language instance:(ComponentInstance)instance
{
    if ((self = [super init])) {
        _language = language ?: [OSALanguage defaultLanguage];
        _instance = instance;
    }
    return self;
}

- (OSALanguage *)language { return _language; }
- (ComponentInstance)componentInstance { return _instance; }
- (NSAppleEventDescriptor *)defaultTarget { return _defaultTarget; }

- (void)setDefaultTarget:(NSAppleEventDescriptor *)target
{
    _defaultTarget = target;
    if (target)
        OSASetDefaultTarget(_instance, target.aeDesc);
}

- (NSAttributedString *)richTextFromDescriptor:(NSAppleEventDescriptor *)descriptor
{
    OSAID v = kOSANullScript;
    if (!descriptor || OSACoerceFromDesc(_instance, descriptor.aeDesc, kOSAModeNull, &v) != noErr)
        return nil;
    CFAttributedStringRef s = NULL;
    OSACopyDisplayString(_instance, v, kOSAModeNull, &s);
    OSADispose(_instance, v);
    return CFBridgingRelease(s);
}
@end

/* ---- errors ---- */

NSDictionary *
FinchOSAErrorInfo(ComponentInstance ci, OSAError err)
{
    if (err != errOSAScriptError) {
        NSString *m = [NSString stringWithFormat:@"The script couldn’t be run (%d).", (int)err];
        return @{OSAScriptErrorNumberKey : @(err), OSAScriptErrorMessageKey : m, OSAScriptErrorBriefMessageKey : m};
    }
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    AEDesc a = {typeNull, NULL};
    if (OSAScriptError(ci, kOSAErrorNumber, typeSInt32, &a) == noErr) {
        SInt32 n = 0;
        AEGetDescData(&a, &n, sizeof n);
        d[OSAScriptErrorNumberKey] = @(n);
        AEDisposeDesc(&a);
    }
    if (OSAScriptError(ci, kOSAErrorMessage, typeUnicodeText, &a) == noErr) {
        NSString *m = [[NSAppleEventDescriptor alloc] initWithAEDescNoCopy:&a].stringValue;
        if (m) {
            d[OSAScriptErrorMessageKey] = m;
            d[OSAScriptErrorBriefMessageKey] = m;
        }
    }
    if (OSAScriptError(ci, kOSAErrorRange, typeOSAErrorRange, &a) == noErr) {
        SInt16 start = 0, end = 0;
        DescType t;
        Size sz;
        AEGetParamPtr(&a, keyOSASourceStart, typeSInt16, &t, &start, sizeof start, &sz);
        AEGetParamPtr(&a, keyOSASourceEnd, typeSInt16, &t, &end, sizeof end, &sz);
        d[OSAScriptErrorRangeKey] = [NSValue valueWithRange:NSMakeRange((NSUInteger)start, (NSUInteger)MAX(end - start, 0))];
        AEDisposeDesc(&a);
    }
    if (OSAScriptError(ci, kOSAErrorPartialResult, typeWildCard, &a) == noErr) {
        if (a.descriptorType != typeNull)
            d[OSAScriptErrorPartialResultKey] = [[NSAppleEventDescriptor alloc] initWithAEDescNoCopy:&a];
        else
            AEDisposeDesc(&a);
    }
    if (OSAScriptError(ci, kOSAErrorOffendingObject, typeWildCard, &a) == noErr) {
        if (a.descriptorType != typeNull)
            d[OSAScriptErrorOffendingObjectKey] = [[NSAppleEventDescriptor alloc] initWithAEDescNoCopy:&a];
        else
            AEDisposeDesc(&a);
    }
    return d;
}

static NSError *
error_from_info(NSDictionary *info)
{
    NSMutableDictionary *u = [info mutableCopy];
    if (info[OSAScriptErrorMessageKey])
        u[NSLocalizedDescriptionKey] = info[OSAScriptErrorMessageKey];
    if (info[OSAScriptErrorBriefMessageKey])
        u[NSLocalizedFailureReasonErrorKey] = info[OSAScriptErrorBriefMessageKey];
    return [NSError errorWithDomain:NSOSStatusErrorDomain code:[info[OSAScriptErrorNumberKey] integerValue] userInfo:u];
}

/* ---- scripts ---- */

@implementation OSAScript {
    NSString *_source;
    NSURL *_url;
    OSALanguage *_language;
    OSALanguageInstance *_languageInstance;
    OSAID _id;
    NSDate *_date;
    OSAStorageOptions _options;
}

+ (NSDictionary *)defaultTextAttributes
{
    CFArrayRef a = NULL;
    ASCopySourceAttributes([OSALanguage defaultAppleScriptComponentInstance], &a);
    NSArray *styles = CFBridgingRelease(a);
    return styles.count > kASSourceStyleUncompiledText ? styles[kASSourceStyleUncompiledText]
                                                       : @{NSFontAttributeName : [NSFont userFixedPitchFontOfSize:12]};
}

+ (void)sourceStylesChanged
{
    [[NSNotificationCenter defaultCenter] postNotificationName:@"OSASourceStylesChangedNotification" object:nil];
}

+ (NSAppleEventDescriptor *)scriptDataDescriptorWithContentsOfURL:(NSURL *)url
{
    AEDesc d = {typeNull, NULL};
    if (!url || OSAGetScriptDataFromURL((__bridge CFURLRef)url, NULL, 0, &d) != noErr)
        return nil;
    return [[NSAppleEventDescriptor alloc] initWithAEDescNoCopy:&d];
}

+ (instancetype)scriptWithSource:(NSString *)source language:(OSALanguage *)language
{
    return [[self alloc] initWithSource:source language:language];
}

+ (instancetype)scriptWithSource:(NSString *)source fromURL:(NSURL *)url languageInstance:(OSALanguageInstance *)instance
             usingStorageOptions:(OSAStorageOptions)options
{
    return [[self alloc] initWithSource:source fromURL:url languageInstance:instance usingStorageOptions:options];
}

+ (instancetype)scriptWithDataDescriptor:(NSAppleEventDescriptor *)data fromURL:(NSURL *)url languageInstance:(OSALanguageInstance *)instance
                     usingStorageOptions:(OSAStorageOptions)options
                                   error:(NSError **)error
{
    return [[self alloc] initWithScriptDataDescriptor:data fromURL:url languageInstance:instance usingStorageOptions:options error:error];
}

- (instancetype)init { return [self initWithSource:@""]; }
- (instancetype)initWithSource:(NSString *)source { return [self initWithSource:source language:nil]; }

- (instancetype)initWithSource:(NSString *)source language:(OSALanguage *)language
{
    return [self initWithSource:source fromURL:nil languageInstance:(language ?: [OSALanguage defaultLanguage]).sharedLanguageInstance
            usingStorageOptions:OSANull];
}

- (instancetype)initWithSource:(NSString *)source fromURL:(NSURL *)url languageInstance:(OSALanguageInstance *)instance
           usingStorageOptions:(OSAStorageOptions)options
{
    if ((self = [super init])) {
        _source = [source copy] ?: @"";
        _languageInstance = instance ?: [OSALanguage defaultLanguage].sharedLanguageInstance;
        _language = _languageInstance.language;
        _options = options;
        if (!(options & OSADontSetScriptLocation))
            _url = [url copy];
    }
    return self;
}

- (instancetype)initWithContentsOfURL:(NSURL *)url error:(NSDictionary<NSString *, id> **)errorInfo
{
    NSError *e = nil;
    self = [self initWithContentsOfURL:url languageInstance:nil usingStorageOptions:OSANull error:&e];
    if (!self && errorInfo)
        *errorInfo = e.userInfo;
    return self;
}

- (instancetype)initWithContentsOfURL:(NSURL *)url language:(OSALanguage *)language error:(NSDictionary<NSString *, id> **)errorInfo
{
    NSError *e = nil;
    self = [self initWithContentsOfURL:url languageInstance:language.sharedLanguageInstance usingStorageOptions:OSANull error:&e];
    if (!self && errorInfo)
        *errorInfo = e.userInfo;
    return self;
}

- (instancetype)initWithContentsOfURL:(NSURL *)url languageInstance:(OSALanguageInstance *)instance
                  usingStorageOptions:(OSAStorageOptions)options
                                error:(NSError **)error
{
    NSAppleEventDescriptor *d = [OSAScript scriptDataDescriptorWithContentsOfURL:url];
    if (!d) {
        if (error)
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError userInfo:@{NSURLErrorKey : url ?: [NSNull null]}];
        return nil;
    }
    return [self initWithScriptDataDescriptor:d fromURL:url languageInstance:instance usingStorageOptions:options error:error];
}

- (instancetype)initWithCompiledData:(NSData *)data error:(NSDictionary<NSString *, id> **)errorInfo
{
    NSError *e = nil;
    self = [self initWithCompiledData:data fromURL:nil usingStorageOptions:OSANull error:&e];
    if (!self && errorInfo)
        *errorInfo = e.userInfo;
    return self;
}

- (instancetype)initWithCompiledData:(NSData *)data fromURL:(NSURL *)url usingStorageOptions:(OSAStorageOptions)options error:(NSError **)error
{
    NSAppleEventDescriptor *d = [NSAppleEventDescriptor descriptorWithDescriptorType:typeOSAGenericStorage data:data];
    return [self initWithScriptDataDescriptor:d fromURL:url languageInstance:nil usingStorageOptions:options error:error];
}

- (instancetype)initWithScriptDataDescriptor:(NSAppleEventDescriptor *)data fromURL:(NSURL *)url languageInstance:(OSALanguageInstance *)instance
                         usingStorageOptions:(OSAStorageOptions)options
                                       error:(NSError **)error
{
    if (!(self = [self initWithSource:@"" fromURL:url languageInstance:instance usingStorageOptions:options]))
        return nil;
    OSAID i = kOSANullScript;
    OSAError err = OSALoad(self._componentInstance, data.aeDesc, kOSAModeNull, &i);
    if (err) {
        if (error)
            *error = err == errOSAScriptError ? error_from_info(FinchOSAErrorInfo(self._componentInstance, err))
                                              : [NSError errorWithDomain:NSOSStatusErrorDomain code:err userInfo:nil];
        return nil;
    }
    _id = i;
    _source = nil;
    if (url)
        _date = [[NSFileManager defaultManager] attributesOfItemAtPath:url.path error:NULL].fileModificationDate;
    return self;
}

- (void)dealloc
{
    if (_id)
        OSADispose(self._componentInstance, _id);
}

- (id)copyWithZone:(NSZone *)zone
{
    OSAScript *c = [[OSAScript alloc] initWithSource:_source ?: @"" fromURL:_url languageInstance:_languageInstance usingStorageOptions:_options];
    if (_id) {
        OSAID i = kOSANullScript;
        if (OSACopyScript(self._componentInstance, _id, &i) == noErr)
            c->_id = i;
        c->_source = nil;
    }
    c->_date = _date;
    return c;
}

- (ComponentInstance)_componentInstance { return _languageInstance.componentInstance; }
- (OSAID)_scriptID { return _id; }

/* the source as given, until there's only the compiled script */
- (NSString *)source
{
    if (_source || !_id)
        return _source ?: @"";
    NSString *s = [self sourceAndReturnError:NULL];
    return s ?: @"";
}

- (NSString *)sourceAndReturnError:(NSError **)error
{
    if (_source || !_id)
        return _source;
    AEDesc d = {typeNull, NULL};
    OSAError err = OSAGetSource(self._componentInstance, _id, typeUnicodeText, &d);
    if (err) {
        if (error)
            *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:err userInfo:nil];
        return nil;
    }
    return [[NSAppleEventDescriptor alloc] initWithAEDescNoCopy:&d].stringValue;
}

- (NSURL *)url { return _url; }
- (void)setURL:(NSURL *)url { _url = [url copy]; }
- (NSString *)name { return _url.lastPathComponent.stringByDeletingPathExtension; }
- (NSDate *)date { return _date; }
- (void)setDate:(NSDate *)date { _date = date; }
- (OSALanguage *)language { return _language; }

- (void)setLanguage:(OSALanguage *)language
{
    _language = language;
    _languageInstance = language.sharedLanguageInstance;
}

- (OSALanguageInstance *)languageInstance { return _languageInstance; }

- (void)setLanguageInstance:(OSALanguageInstance *)instance
{
    _languageInstance = instance;
    _language = instance.language;
}

- (NSAppleEventDescriptor *)defaultTarget { return _languageInstance.defaultTarget; }
- (void)setDefaultTarget:(NSAppleEventDescriptor *)target { _languageInstance.defaultTarget = target; }
- (BOOL)isCompiled { return _id != kOSANullScript; }

- (BOOL)hasOpenHandler
{
    long has = 0;
    if (![self compileAndReturnError:NULL])
        return NO;
    OSAGetScriptInfo(self._componentInstance, _id, kASHasOpenHandler, &has);
    return has != 0;
}

- (BOOL)compileAndReturnError:(NSDictionary<NSString *, id> **)errorInfo
{
    if (_id)
        return YES;
    NSAppleEventDescriptor *src = [NSAppleEventDescriptor descriptorWithString:_source ?: @""];
    OSAID i = kOSANullScript;
    OSAError err = OSACompile(self._componentInstance, src.aeDesc, kOSAModeCompileIntoContext, &i);
    if (err) {
        if (errorInfo)
            *errorInfo = FinchOSAErrorInfo(self._componentInstance, err);
        return NO;
    }
    _id = i;
    return YES;
}

static NSAppleEventDescriptor *
descriptor_for(ComponentInstance ci, OSAID v)
{
    if (!v)
        return [NSAppleEventDescriptor nullDescriptor];
    AEDesc d = {typeNull, NULL};
    OSAError err = OSACoerceToDesc(ci, v, typeWildCard, kOSAModeNull, &d);
    if (err)
        return [NSAppleEventDescriptor nullDescriptor];
    return [[NSAppleEventDescriptor alloc] initWithAEDescNoCopy:&d];
}

- (NSAppleEventDescriptor *)_execute:(NSAppleEventDescriptor *)event display:(NSAttributedString **)display error:(NSDictionary<NSString *, id> **)errorInfo
{
    if (![self compileAndReturnError:errorInfo])
        return nil;
    ComponentInstance ci = self._componentInstance;
    OSAID v = kOSANullScript;
    OSAError err = event ? OSAExecuteEvent(ci, event.aeDesc, _id, kOSAModeNull, &v) : OSAExecute(ci, _id, kOSANullScript, kOSAModeNull, &v);
    if (err) {
        if (errorInfo)
            *errorInfo = FinchOSAErrorInfo(ci, err);
        return nil;
    }
    NSAppleEventDescriptor *r = descriptor_for(ci, v);
    if (display) {
        CFAttributedStringRef s = NULL;
        if (v && OSACopyDisplayString(ci, v, kOSAModeNull, &s) == noErr)
            *display = CFBridgingRelease(s);
        else
            *display = [[NSAttributedString alloc] initWithString:@""];
    }
    if (v)
        OSADispose(ci, v);
    return r;
}

- (NSAppleEventDescriptor *)executeAndReturnError:(NSDictionary<NSString *, id> **)errorInfo { return [self _execute:nil display:NULL error:errorInfo]; }

- (NSAppleEventDescriptor *)executeAppleEvent:(NSAppleEventDescriptor *)event error:(NSDictionary<NSString *, id> **)errorInfo
{
    return [self _execute:event display:NULL error:errorInfo];
}

- (NSAppleEventDescriptor *)executeAndReturnDisplayValue:(NSAttributedString **)displayValue error:(NSDictionary<NSString *, id> **)errorInfo
{
    return [self _execute:nil display:displayValue error:errorInfo];
}

- (NSAppleEventDescriptor *)executeHandlerWithName:(NSString *)name arguments:(NSArray *)arguments error:(NSDictionary<NSString *, id> **)errorInfo
{
    NSAppleEventDescriptor *event = [NSAppleEventDescriptor appleEventWithEventClass:kASAppleScriptSuite eventID:kASSubroutineEvent
                                                                    targetDescriptor:[NSAppleEventDescriptor nullDescriptor]
                                                                            returnID:kAutoGenerateReturnID
                                                                       transactionID:kAnyTransactionID];
    [event setParamDescriptor:[NSAppleEventDescriptor descriptorWithString:name.lowercaseString] forKeyword:keyASSubroutineName];
    NSAppleEventDescriptor *list = [NSAppleEventDescriptor listDescriptor];
    for (id a in arguments) {
        NSAppleEventDescriptor *d = [a isKindOfClass:[NSAppleEventDescriptor class]] ? a
                                    : [a isKindOfClass:[NSNumber class]]           ? [NSAppleEventDescriptor descriptorWithInt32:[a intValue]]
                                                                                   : [NSAppleEventDescriptor descriptorWithString:[a description]];
        [list insertDescriptor:d atIndex:0];
    }
    [event setParamDescriptor:list forKeyword:keyDirectObject];
    return [self _execute:event display:NULL error:errorInfo];
}

- (NSAttributedString *)richTextSource
{
    if (!_id)
        return [[NSAttributedString alloc] initWithString:_source ?: @"" attributes:[OSAScript defaultTextAttributes]];
    CFAttributedStringRef s = NULL;
    if (OSACopySourceString(self._componentInstance, _id, kOSAModeNull, &s) != noErr)
        return nil;
    return CFBridgingRelease(s);
}

- (NSAttributedString *)richTextFromDescriptor:(NSAppleEventDescriptor *)descriptor
{
    return [_languageInstance richTextFromDescriptor:descriptor];
}

- (NSData *)compiledDataForType:(NSString *)type usingStorageOptions:(OSAStorageOptions)options error:(NSDictionary<NSString *, id> **)errorInfo
{
    if ([type isEqualToString:OSAStorageTextType])
        return [self.source dataUsingEncoding:NSUTF8StringEncoding];
    if (![self compileAndReturnError:errorInfo])
        return nil;
    AEDesc d = {typeNull, NULL};
    OSAError err = OSAStore(self._componentInstance, _id, typeOSAGenericStorage, (SInt32)(options & 0xffff), &d);
    if (err) {
        if (errorInfo)
            *errorInfo = FinchOSAErrorInfo(self._componentInstance, err);
        return nil;
    }
    return [[NSAppleEventDescriptor alloc] initWithAEDescNoCopy:&d].data;
}

- (BOOL)writeToURL:(NSURL *)url ofType:(NSString *)type error:(NSDictionary<NSString *, id> **)errorInfo
{
    return [self writeToURL:url ofType:type usingStorageOptions:OSANull error:errorInfo];
}

/* text, a script, or a script bundle; applets need an applet shell Finch doesn't have yet */
- (BOOL)writeToURL:(NSURL *)url ofType:(NSString *)type usingStorageOptions:(OSAStorageOptions)options error:(NSDictionary<NSString *, id> **)errorInfo
{
    if ([type isEqualToString:OSAStorageApplicationType] || [type isEqualToString:OSAStorageApplicationBundleType]) {
        if (errorInfo)
            *errorInfo = @{OSAScriptErrorNumberKey : @(errOSABadStorageType),
                           OSAScriptErrorMessageKey : @"Finch can’t save scripts as applications yet.",
                           OSAScriptErrorBriefMessageKey : @"Finch can’t save scripts as applications yet."};
        return NO;
    }
    NSData *d = [self compiledDataForType:type usingStorageOptions:options error:errorInfo];
    if (!d)
        return NO;
    NSURL *file = url;
    if ([type isEqualToString:OSAStorageScriptBundleType]) {
        NSURL *scripts = [url URLByAppendingPathComponent:@"Contents/Resources/Scripts"];
        [[NSFileManager defaultManager] createDirectoryAtURL:scripts withIntermediateDirectories:YES attributes:nil error:NULL];
        NSDictionary *info = @{@"CFBundleIdentifier" : [@"com.apple.ScriptEditor.id." stringByAppendingString:url.lastPathComponent.stringByDeletingPathExtension],
                               @"CFBundleName" : url.lastPathComponent.stringByDeletingPathExtension,
                               @"CFBundlePackageType" : @"????"};
        [info writeToURL:[url URLByAppendingPathComponent:@"Contents/Info.plist"] error:NULL];
        file = [scripts URLByAppendingPathComponent:@"main.scpt"];
    }
    NSError *e = nil;
    if (![d writeToURL:file options:NSDataWritingAtomic error:&e]) {
        if (errorInfo)
            *errorInfo = @{OSAScriptErrorNumberKey : @(e.code), OSAScriptErrorMessageKey : e.localizedDescription ?: @"",
                           OSAScriptErrorBriefMessageKey : e.localizedDescription ?: @""};
        return NO;
    }
    if (!(options & OSADontSetScriptLocation))
        _url = url;
    return YES;
}

- (NSString *)description { return [NSString stringWithFormat:@"<OSAScript %p: %@>", self, _url ?: (self.isCompiled ? @"compiled" : @"source")]; }
@end
