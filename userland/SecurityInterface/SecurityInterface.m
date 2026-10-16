/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * SecurityInterface panels for Finch's own Security and AppKit. Certificate
 * panels inspect and display real Security objects; edits write trust or
 * keychain settings through Security rather than pretending a change worked.
 */
#import <SecurityInterface/SecurityInterface.h>
#import <SecurityFoundation/SFAuthorization.h>
#import <Security/SecTrustSettings.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>

NSString *const SFAuthorizationPluginViewUserNameKey = @"UserName";
NSString *const SFAuthorizationPluginViewUserShortNameKey = @"UserShortName";

static const void *SIStateKey = &SIStateKey;

@interface SIFinchState : NSObject {
    NSMutableDictionary *_values;
}
- (id)valueForKey:(NSString *)key;
- (void)setValue:(id)value forKey:(NSString *)key;
- (NSDictionary *)allValues;
@end

@implementation SIFinchState
- (instancetype)init
{
    if ((self = [super init]))
        _values = [[NSMutableDictionary alloc] init];
    return self;
}
- (void)dealloc { [_values release]; [super dealloc]; }
- (id)valueForKey:(NSString *)key { return [_values objectForKey:key]; }
- (void)setValue:(id)value forKey:(NSString *)key
{
    if (value)
        [_values setObject:value forKey:key];
    else
        [_values removeObjectForKey:key];
}
- (NSDictionary *)allValues { return _values; }
@end

static SIFinchState *
SIStateFor(id object, BOOL create)
{
    SIFinchState *state = objc_getAssociatedObject(object, SIStateKey);
    if (!state && create) {
        @synchronized (object) {
            state = objc_getAssociatedObject(object, SIStateKey);
            if (!state) {
                state = [[[SIFinchState alloc] init] autorelease];
                objc_setAssociatedObject(object, SIStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    }
    return state;
}

static id SIGet(id object, NSString *key) { return [[[SIStateFor(object, NO) valueForKey:key] retain] autorelease]; }
static void SISet(id object, NSString *key, id value) { [SIStateFor(object, YES) setValue:value forKey:key]; }
static void SISetCopy(id object, NSString *key, id value)
{
    id copy = [value copy];
    SISet(object, key, copy);
    [copy release];
}
static BOOL SIGetBool(id object, NSString *key) { return [SIGet(object, key) boolValue]; }
static void SISetBool(id object, NSString *key, BOOL value) { SISet(object, key, [NSNumber numberWithBool:value]); }
static void SISetNonretained(id object, NSString *key, id value)
{
    SISet(object, key, value ? [NSValue valueWithNonretainedObject:value] : nil);
}
static id SIGetNonretained(id object, NSString *key) { return [SIGet(object, key) nonretainedObjectValue]; }

static NSError *SIStatusError(OSStatus status)
{
    return [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];
}

static void SIInvokeSheetCallback(id delegate, SEL selector, NSWindow *sheet, NSInteger result, void *context)
{
    if (delegate && selector && [delegate respondsToSelector:selector])
        ((void (*)(id, SEL, id, NSInteger, void *))objc_msgSend)(delegate, selector, sheet, result, context);
}

static NSButton *SIButton(NSView *view, NSString *title, NSRect frame, id target, SEL action)
{
    NSButton *button = [[NSButton alloc] initWithFrame:frame];
    [button setTitle:title ?: @""];
    [button setBezelStyle:NSBezelStyleRounded];
    [button setTarget:target];
    [button setAction:action];
    [view addSubview:button];
    return [button autorelease];
}

static NSTextField *SILabel(NSView *view, NSString *value, NSRect frame)
{
    NSTextField *label = [[NSTextField alloc] initWithFrame:frame];
    [label setEditable:NO];
    [label setSelectable:YES];
    [label setBordered:NO];
    [label setDrawsBackground:NO];
    [label setStringValue:value ?: @""];
    [view addSubview:label];
    return [label autorelease];
}

static NSModalResponse SIEndPanel(NSPanel *panel, NSModalResponse result)
{
    NSWindow *parent = SIGet(panel, @"parentWindow");
    if (parent)
        [parent endSheet:panel returnCode:result];
    else
        [[NSApplication sharedApplication] stopModalWithCode:result];
    return result;
}

static void SIStoreSheetCallback(NSPanel *panel, NSWindow *window, id delegate, SEL selector, void *context)
{
    SISet(panel, @"parentWindow", window);
    SISetNonretained(panel, @"modalDelegate", delegate);
    SISet(panel, @"didEndSelector", selector ? NSStringFromSelector(selector) : nil);
    SISet(panel, @"contextInfo", context ? [NSValue valueWithPointer:context] : nil);
}

static void SICertificateSummary(SecCertificateRef certificate, NSString **subject, NSString **expiry)
{
    if (subject)
        *subject = certificate ? [(NSString *)SecCertificateCopySubjectSummary(certificate) autorelease] : @"No certificate selected";
    if (expiry) {
        CFDateRef date = certificate ? SecCertificateCopyNotValidAfterDate(certificate) : NULL;
        *expiry = date ? [NSString stringWithFormat:@"Valid until %@", [(NSDate *)date description]] : @"Validity date unavailable";
        if (date)
            CFRelease(date);
    }
}

static NSString *SITrustMessage(SecTrustRef trust)
{
    if (!trust)
        return @"Review the certificate before trusting it.";
    CFErrorRef error = NULL;
    BOOL valid = SecTrustEvaluateWithError(trust, &error);
    if (error) CFRelease(error);
    return valid ? @"The certificate chain is trusted." : @"The certificate chain could not be trusted.";
}

@interface SFCertificateView (Finch)
- (void)_setTrustDecision:(SecTrustSettingsResult)result;
- (void)_setTrust:(SecTrustRef)trust;
- (OSStatus)_saveTrustDecision;
@end

@interface SFCertificatePanel (Finch)
- (void)_setCertificates:(NSArray *)certificates showGroup:(BOOL)showGroup trust:(SecTrustRef)trust;
- (void)_beginSheetForWindow:(NSWindow *)window modalDelegate:(id)delegate didEndSelector:(SEL)selector contextInfo:(void *)contextInfo;
- (void)_selectCertificate:(id)sender;
@end

@implementation SFCertificateView
- (instancetype)initWithFrame:(NSRect)frame
{
    if ((self = [super initWithFrame:frame]))
        [self setDisplayDetails:YES];
    return self;
}
- (void)dealloc
{
    [super dealloc];
}
- (void)setCertificate:(SecCertificateRef)certificate
{
    if (certificate)
        CFRetain(certificate);
    id old = SIGet(self, @"certificate");
    SISet(self, @"certificate", (id)certificate);
    if (certificate)
        CFRelease(certificate);
    (void)old;
    [self setNeedsDisplay:YES];
}
- (SecCertificateRef)certificate { return (SecCertificateRef)SIGet(self, @"certificate"); }
- (void)setPolicies:(id)policies
{
    if (!policies)
        SISet(self, @"policies", nil);
    else if (CFGetTypeID((CFTypeRef)policies) == SecPolicyGetTypeID())
        SISet(self, @"policies", @[policies]);
    else
        SISetCopy(self, @"policies", policies);
    [self setNeedsDisplay:YES];
}
- (void)_setTrust:(SecTrustRef)trust
{
    if (trust)
        CFRetain(trust);
    SISet(self, @"trust", (id)trust);
    if (trust)
        CFRelease(trust);
    [self setNeedsDisplay:YES];
}
- (NSArray *)policies
{
    NSArray *policies = SIGet(self, @"policies");
    if (policies)
        return policies;
    SecPolicyRef policy = SecPolicyCreateBasicX509();
    if (!policy)
        return @[];
    NSArray *defaults = [NSArray arrayWithObject:(id)policy];
    CFRelease(policy);
    return defaults;
}
- (void)setEditableTrust:(BOOL)editable { SISetBool(self, @"editableTrust", editable); }
- (BOOL)isEditable { return SIGetBool(self, @"editableTrust"); }
- (void)setDisplayTrust:(BOOL)display { SISetBool(self, @"displayTrust", display); [self setNeedsDisplay:YES]; }
- (BOOL)isTrustDisplayed { return SIGetBool(self, @"displayTrust"); }
- (void)setDisplayDetails:(BOOL)display { SISetBool(self, @"displayDetails", display); [self setNeedsDisplay:YES]; }
- (BOOL)detailsDisplayed { return SIGetBool(self, @"displayDetails"); }
- (void)setDetailsDisclosed:(BOOL)disclosed { SISetBool(self, @"detailsDisclosed", disclosed); [self setNeedsDisplay:YES]; }
- (BOOL)detailsDisclosed { return SIGetBool(self, @"detailsDisclosed"); }
- (void)setPoliciesDisclosed:(BOOL)disclosed { SISetBool(self, @"policiesDisclosed", disclosed); [self setNeedsDisplay:YES]; }
- (BOOL)policiesDisclosed { return SIGetBool(self, @"policiesDisclosed"); }
- (void)_setTrustDecision:(SecTrustSettingsResult)result { SISet(self, @"trustDecision", [NSNumber numberWithUnsignedInt:result]); }
- (OSStatus)_saveTrustDecision
{
    if (!self.isEditable)
        return errSecSuccess;
    SecCertificateRef certificate = self.certificate;
    SecTrustSettingsResult decision = [SIGet(self, @"trustDecision") unsignedIntValue];
    if (!certificate || decision == kSecTrustSettingsResultInvalid)
        return errSecParam;
    CFDataRef subject = SecCertificateCopyNormalizedSubjectSequence(certificate);
    CFDataRef issuer = SecCertificateCopyNormalizedIssuerSequence(certificate);
    BOOL isRoot = subject && issuer && CFEqual(subject, issuer);
    if (subject) CFRelease(subject);
    if (issuer) CFRelease(issuer);
    if (isRoot && decision == kSecTrustSettingsResultTrustAsRoot)
        decision = kSecTrustSettingsResultTrustRoot;
    else if (!isRoot && decision == kSecTrustSettingsResultTrustRoot)
        decision = kSecTrustSettingsResultTrustAsRoot;
    NSDictionary *setting = @{(__bridge id)kSecTrustSettingsResult : @(decision)};
    return SecTrustSettingsSetTrustSettings(certificate, kSecTrustSettingsDomainUser, (CFTypeRef)setting);
}
- (void)saveTrustSettings
{
    OSStatus status = [self _saveTrustDecision];
    SISet(self, @"trustSettingsError", status == errSecSuccess ? nil : SIStatusError(status));
}
- (void)drawRect:(NSRect)dirtyRect
{
    [super drawRect:dirtyRect];
    NSString *subject = nil, *expiry = nil;
    SICertificateSummary(self.certificate, &subject, &expiry);
    NSMutableString *text = [NSMutableString stringWithFormat:@"%@\n%@", subject, expiry];
    SecTrustRef trust = (SecTrustRef)SIGet(self, @"trust");
    if (SIGetBool(self, @"displayTrust") && trust) {
        CFErrorRef error = NULL;
        BOOL trusted = SecTrustEvaluateWithError(trust, &error);
        [text appendFormat:@"\nTrust: %@", trusted ? @"trusted" : @"not trusted"];
        if (error)
            CFRelease(error);
    }
    if (SIGetBool(self, @"detailsDisplayed") && SIGetBool(self, @"detailsDisclosed")) {
        CFDataRef der = self.certificate ? SecCertificateCopyData(self.certificate) : NULL;
        if (der)
            [text appendFormat:@"\nCertificate data: %lu bytes", (unsigned long)CFDataGetLength(der)];
        if (der)
            CFRelease(der);
    }
    NSString *message = SIGet(self, @"informativeText");
    if (message.length)
        [text appendFormat:@"\n%@", message];
    NSDictionary *attributes = @{NSFontAttributeName : [NSFont systemFontOfSize:13]};
    [text drawInRect:NSInsetRect(self.bounds, 12, 12) withAttributes:attributes];
}
@end

@implementation SFCertificatePanel
- (instancetype)init
{
    if ((self = [super initWithContentRect:NSMakeRect(0, 0, 460, 260)
                                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                  backing:NSBackingStoreBuffered defer:NO])) {
        [self setTitle:@"Certificate"];
        [self setReleasedWhenClosed:NO];
        NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 460, 260)];
        SFCertificateView *view = [[SFCertificateView alloc] initWithFrame:NSMakeRect(0, 46, 460, 164)];
        [view setDisplayTrust:YES];
        [content addSubview:view];
        [view release];
        NSPopUpButton *chainPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(18, 218, 424, 28) pullsDown:NO];
        [chainPopup setTarget:self];
        [chainPopup setAction:@selector(_selectCertificate:)];
        [content addSubview:chainPopup];
        SISet(self, @"chainPopup", chainPopup);
        [chainPopup release];
        NSButton *alternate = SIButton(content, @"Cancel", NSMakeRect(250, 10, 90, 30), self, @selector(_cancel:));
        NSButton *defaultButton = SIButton(content, @"OK", NSMakeRect(350, 10, 90, 30), self, @selector(_accept:));
        SISet(self, @"certificateView", view);
        SISet(self, @"alternateButton", alternate);
        SISet(self, @"defaultButton", defaultButton);
        [self setContentView:content];
        [content release];
    }
    return self;
}
+ (SFCertificatePanel *)sharedCertificatePanel
{
    static SFCertificatePanel *panel;
    @synchronized (self) { if (!panel) panel = [[self alloc] init]; }
    return panel;
}
- (NSInteger)runModalForCertificates:(NSArray *)certificates showGroup:(BOOL)showGroup
{
    [self _setCertificates:certificates showGroup:showGroup trust:NULL];
    [self setTitle:showGroup && certificates.count > 1 ? @"Certificate Chain" : @"Certificate"];
    SISet(self, @"modalResult", @(NSCancelButton));
    [[NSApplication sharedApplication] runModalForWindow:self];
    return [SIGet(self, @"modalResult") integerValue];
}
- (NSInteger)runModalForTrust:(SecTrustRef)trust showGroup:(BOOL)showGroup
{
    CFArrayRef chain = trust ? SecTrustCopyCertificateChain(trust) : NULL;
    NSArray *certificates = chain ? (NSArray *)chain : @[];
    [self _setCertificates:certificates showGroup:showGroup trust:trust];
    [self setTitle:showGroup && certificates.count > 1 ? @"Certificate Chain" : @"Certificate"];
    SISet(self, @"modalResult", @(NSCancelButton));
    [[NSApplication sharedApplication] runModalForWindow:self];
    NSInteger result = [SIGet(self, @"modalResult") integerValue];
    if (chain) CFRelease(chain);
    return result;
}
- (void)beginSheetForWindow:(NSWindow *)window modalDelegate:(id)delegate didEndSelector:(SEL)selector contextInfo:(void *)contextInfo trust:(SecTrustRef)trust showGroup:(BOOL)showGroup
{
    if (trust) {
        CFArrayRef chain = SecTrustCopyCertificateChain(trust);
        [self _setCertificates:chain ? (NSArray *)chain : @[] showGroup:showGroup trust:trust];
        [self _beginSheetForWindow:window modalDelegate:delegate didEndSelector:selector contextInfo:contextInfo];
        if (chain) CFRelease(chain);
    } else {
        [self beginSheetForWindow:window modalDelegate:delegate didEndSelector:selector contextInfo:contextInfo certificates:@[] showGroup:showGroup];
    }
}
- (void)beginSheetForWindow:(NSWindow *)window modalDelegate:(id)delegate didEndSelector:(SEL)selector contextInfo:(void *)contextInfo certificates:(NSArray *)certificates showGroup:(BOOL)showGroup
{
    [self _setCertificates:certificates showGroup:showGroup trust:NULL];
    [self _beginSheetForWindow:window modalDelegate:delegate didEndSelector:selector contextInfo:contextInfo];
}
- (void)_beginSheetForWindow:(NSWindow *)window modalDelegate:(id)delegate didEndSelector:(SEL)selector contextInfo:(void *)contextInfo
{
    SIStoreSheetCallback(self, window, delegate, selector, contextInfo);
    [window beginSheet:self completionHandler:^(NSModalResponse result) {
        id target = SIGetNonretained(self, @"modalDelegate");
        SEL didEnd = NSSelectorFromString(SIGet(self, @"didEndSelector"));
        void *context = [SIGet(self, @"contextInfo") pointerValue];
        SIInvokeSheetCallback(target, didEnd, self, result == NSModalResponseOK ? NSOKButton : NSCancelButton, context);
        [self orderOut:nil];
    }];
}
- (void)setPolicies:(id)policies { SISet(self, @"policies", policies); [self.certificateView setPolicies:policies]; }
- (NSArray *)policies { return self.certificateView.policies; }
- (void)setDefaultButtonTitle:(NSString *)title { [SIGet(self, @"defaultButton") setTitle:title ?: @"OK"]; }
- (void)setAlternateButtonTitle:(NSString *)title
{
    NSButton *button = SIGet(self, @"alternateButton");
    [button setTitle:title ?: @""];
    [button setHidden:title == nil];
}
- (void)setShowsHelp:(BOOL)showsHelp { SISetBool(self, @"showsHelp", showsHelp); }
- (BOOL)showsHelp { return SIGetBool(self, @"showsHelp"); }
- (void)setHelpAnchor:(NSString *)anchor { SISetCopy(self, @"helpAnchor", anchor); }
- (NSString *)helpAnchor { return SIGet(self, @"helpAnchor"); }
- (SFCertificateView *)certificateView { return SIGet(self, @"certificateView"); }
- (void)_setCertificates:(NSArray *)certificates showGroup:(BOOL)showGroup trust:(SecTrustRef)trust
{
    NSArray *items = [certificates copy] ?: [[NSArray alloc] init];
    SISet(self, @"certificates", items);
    [items release];
    NSArray *visible = showGroup ? (certificates ?: @[]) : (certificates.count ? @[certificates[0]] : @[]);
    SISetCopy(self, @"visibleCertificates", visible);
    NSPopUpButton *popup = SIGet(self, @"chainPopup");
    [popup removeAllItems];
    for (id item in visible) {
        CFStringRef summary = SecCertificateCopySubjectSummary((SecCertificateRef)item);
        [popup addItemWithTitle:summary ? (NSString *)summary : @"Certificate"];
        if (summary) CFRelease(summary);
    }
    [popup setHidden:visible.count < 2];
    SISetBool(self, @"showGroup", showGroup);
    if (trust)
        CFRetain(trust);
    SISet(self, @"trust", (id)trust);
    if (trust)
        CFRelease(trust);
    [self.certificateView _setTrust:trust];
    if (visible.count)
        [popup selectItemAtIndex:0];
    [self _selectCertificate:popup];
}
- (void)_selectCertificate:(id)sender
{
    NSArray *items = SIGet(self, @"visibleCertificates") ?: @[];
    NSInteger index = [sender indexOfSelectedItem];
    SecCertificateRef certificate = index >= 0 && (NSUInteger)index < items.count ? (SecCertificateRef)items[(NSUInteger)index] : NULL;
    [self.certificateView setCertificate:certificate];
}
- (void)_accept:(id)sender
{
    SISet(self, @"modalResult", @(NSOKButton));
    SIEndPanel(self, NSModalResponseOK);
}
- (void)_cancel:(id)sender
{
    SISet(self, @"modalResult", @(NSCancelButton));
    SIEndPanel(self, NSModalResponseCancel);
}
@end

@implementation SFCertificateTrustPanel
+ (SFCertificateTrustPanel *)sharedCertificateTrustPanel
{
    static SFCertificateTrustPanel *panel;
    @synchronized (self) { if (!panel) panel = [[self alloc] init]; }
    return panel;
}
- (NSInteger)runModalForTrust:(SecTrustRef)trust message:(NSString *)message
{
    [self setTitle:@"Certificate Trust"];
    [self setDefaultButtonTitle:@"Trust"];
    [self setAlternateButtonTitle:@"Cancel"];
    [self setInformativeText:message ?: SITrustMessage(trust)];
    [self.certificateView setEditableTrust:YES];
    return [super runModalForTrust:trust showGroup:YES];
}
- (void)_accept:(id)sender
{
    [self.certificateView setEditableTrust:YES];
    [self.certificateView _setTrustDecision:kSecTrustSettingsResultTrustAsRoot];
    OSStatus status = [self.certificateView _saveTrustDecision];
    if (status != errSecSuccess) {
        SISet(self, @"trustSettingsError", SIStatusError(status));
        SISet(self, @"modalResult", @(NSCancelButton));
        SIEndPanel(self, NSModalResponseCancel);
        return;
    }
    [super _accept:sender];
}
- (void)beginSheetForWindow:(NSWindow *)window modalDelegate:(id)delegate didEndSelector:(SEL)selector contextInfo:(void *)contextInfo trust:(SecTrustRef)trust message:(NSString *)message
{
    [self setTitle:@"Certificate Trust"];
    [self setDefaultButtonTitle:@"Trust"];
    [self setAlternateButtonTitle:@"Cancel"];
    [self setInformativeText:message ?: SITrustMessage(trust)];
    [self.certificateView setEditableTrust:YES];
    [super beginSheetForWindow:window modalDelegate:delegate didEndSelector:selector contextInfo:contextInfo trust:trust showGroup:YES];
}
- (void)setInformativeText:(NSString *)text
{
    SISetCopy(self, @"informativeText", text);
    SISet(self.certificateView, @"informativeText", text);
    [self.certificateView setNeedsDisplay:YES];
}
- (NSString *)informativeText { return SIGet(self, @"informativeText") ?: SITrustMessage((SecTrustRef)SIGet(self, @"trust")); }
@end

@implementation SFChooseIdentityPanel
- (instancetype)init
{
    if ((self = [super initWithContentRect:NSMakeRect(0, 0, 460, 240)
                                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                  backing:NSBackingStoreBuffered defer:NO])) {
        [self setTitle:@"Choose an Identity"];
        [self setReleasedWhenClosed:NO];
        NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 460, 240)];
        NSTextField *messageField = SILabel(content, @"Choose a certificate identity to use.", NSMakeRect(18, 190, 420, 24));
        NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(18, 150, 420, 28) pullsDown:NO];
        [content addSubview:popup];
        NSButton *alternate = SIButton(content, @"Cancel", NSMakeRect(250, 10, 90, 30), self, @selector(_cancel:));
        NSButton *defaultButton = SIButton(content, @"Choose", NSMakeRect(350, 10, 90, 30), self, @selector(_choose:));
        SISet(self, @"identityPopup", popup);
        SISet(self, @"messageField", messageField);
        SISet(self, @"alternateButton", alternate);
        SISet(self, @"defaultButton", defaultButton);
        [popup release];
        [self setContentView:content];
        [content release];
    }
    return self;
}
+ (SFChooseIdentityPanel *)sharedChooseIdentityPanel
{
    static SFChooseIdentityPanel *panel;
    @synchronized (self) { if (!panel) panel = [[self alloc] init]; }
    return panel;
}
- (NSInteger)runModalForIdentities:(NSArray *)identities message:(NSString *)message
{
    if (!identities.count)
        return NSCancelButton;
    NSPopUpButton *popup = SIGet(self, @"identityPopup");
    [popup removeAllItems];
    SISetCopy(self, @"identities", identities);
    SISet(self, @"identity", nil);
    for (id identity in identities) {
        SecCertificateRef certificate = NULL;
        SecIdentityCopyCertificate((SecIdentityRef)identity, &certificate);
        CFStringRef subject = certificate ? SecCertificateCopySubjectSummary(certificate) : NULL;
        [popup addItemWithTitle:subject ? (NSString *)subject : @"Certificate identity"];
        if (subject) CFRelease(subject);
        if (certificate) CFRelease(certificate);
    }
    [SIGet(self, @"messageField") setStringValue:message ?: @"Choose a certificate identity to use."];
    [self setTitle:@"Choose an Identity"];
    SISet(self, @"modalResult", @(NSCancelButton));
    [[NSApplication sharedApplication] runModalForWindow:self];
    return [SIGet(self, @"modalResult") integerValue];
}
- (void)beginSheetForWindow:(NSWindow *)window modalDelegate:(id)delegate didEndSelector:(SEL)selector contextInfo:(void *)contextInfo identities:(NSArray *)identities message:(NSString *)message
{
    if (!identities.count) {
        SIInvokeSheetCallback(delegate, selector, self, NSCancelButton, contextInfo);
        return;
    }
    SISetCopy(self, @"identities", identities);
    SISet(self, @"identity", nil);
    NSPopUpButton *popup = SIGet(self, @"identityPopup");
    [popup removeAllItems];
    for (id identity in identities) {
        SecCertificateRef certificate = NULL;
        SecIdentityCopyCertificate((SecIdentityRef)identity, &certificate);
        CFStringRef subject = certificate ? SecCertificateCopySubjectSummary(certificate) : NULL;
        [popup addItemWithTitle:subject ? (NSString *)subject : @"Certificate identity"];
        if (subject) CFRelease(subject);
        if (certificate) CFRelease(certificate);
    }
    [SIGet(self, @"messageField") setStringValue:message ?: @"Choose a certificate identity to use."];
    SIStoreSheetCallback(self, window, delegate, selector, contextInfo);
    [window beginSheet:self completionHandler:^(NSModalResponse result) {
        SIInvokeSheetCallback(SIGetNonretained(self, @"modalDelegate"), NSSelectorFromString(SIGet(self, @"didEndSelector")),
                              self, result == NSModalResponseOK ? NSOKButton : NSCancelButton,
                              [SIGet(self, @"contextInfo") pointerValue]);
        [self orderOut:nil];
    }];
}
- (SecIdentityRef)identity { return (SecIdentityRef)SIGet(self, @"identity"); }
- (void)setPolicies:(id)policies { SISetCopy(self, @"policies", policies); }
- (NSArray *)policies { return SIGet(self, @"policies") ?: @[]; }
- (void)setDefaultButtonTitle:(NSString *)title { [SIGet(self, @"defaultButton") setTitle:title ?: @"Choose"]; }
- (void)setAlternateButtonTitle:(NSString *)title
{
    NSButton *button = SIGet(self, @"alternateButton");
    [button setTitle:title ?: @""];
    [button setHidden:title == nil];
}
- (void)setShowsHelp:(BOOL)showsHelp { SISetBool(self, @"showsHelp", showsHelp); }
- (BOOL)showsHelp { return SIGetBool(self, @"showsHelp"); }
- (void)setHelpAnchor:(NSString *)anchor { SISetCopy(self, @"helpAnchor", anchor); }
- (NSString *)helpAnchor { return SIGet(self, @"helpAnchor"); }
- (void)setInformativeText:(NSString *)text { SISetCopy(self, @"informativeText", text); }
- (NSString *)informativeText { return SIGet(self, @"informativeText"); }
- (void)setDomain:(NSString *)domain { SISetCopy(self, @"domain", domain); }
- (NSString *)domain { return SIGet(self, @"domain"); }
- (void)_choose:(id)sender
{
    NSArray *identities = SIGet(self, @"identities");
    NSInteger index = [SIGet(self, @"identityPopup") indexOfSelectedItem];
    if (index < 0 || (NSUInteger)index >= identities.count) index = 0;
    SecIdentityRef identity = identities.count ? (SecIdentityRef)[identities objectAtIndex:(NSUInteger)index] : NULL;
    if (identity) CFRetain(identity);
    id old = SIGet(self, @"identity");
    SISet(self, @"identity", (id)identity);
    if (identity) CFRelease(identity);
    (void)old;
    NSString *domain = self.domain;
    /* Finch Security does not yet implement persistent identity preferences. */
    (void)domain;
    SISet(self, @"modalResult", @(NSOKButton));
    SIEndPanel(self, NSModalResponseOK);
}
- (void)_cancel:(id)sender { SISet(self, @"modalResult", @(NSCancelButton)); SIEndPanel(self, NSModalResponseCancel); }
@end

@implementation SFChooseIdentityTableCellView
@synthesize issuerTextField = _issuerTextField;
@end

@implementation SFKeychainSavePanel
+ (SFKeychainSavePanel *)sharedKeychainSavePanel
{
    static SFKeychainSavePanel *panel;
    @synchronized (self) { if (!panel) panel = [[self alloc] init]; }
    return panel;
}
- (void)setPassword:(NSString *)password
{
    SISetCopy(self, @"password", password);
    NSSecureTextField *field = SIGet(self, @"passwordField");
    if (field)
        [field setStringValue:password ?: @""];
}
- (SecKeychainRef)keychain { return (SecKeychainRef)SIGet(self, @"keychain"); }
- (NSError *)error { return SIGet(self, @"error"); }
- (void)_ensurePasswordField
{
    if (SIGet(self, @"passwordField"))
        return;
    NSView *accessory = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 280, 38)];
    NSSecureTextField *field = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 4, 260, 28)];
    [field setPlaceholderString:@"Keychain password"];
    [accessory addSubview:field];
    [self setAccessoryView:accessory];
    SISet(self, @"passwordField", field);
    NSString *password = SIGet(self, @"password");
    if (password)
        [field setStringValue:password];
    [field release];
    [accessory release];
}
- (OSStatus)_createKeychainAtURL:(NSURL *)url
{
    if (!url.isFileURL)
        return errSecParam;
    [self _ensurePasswordField];
    NSString *password = SIGet(self, @"password") ?: [SIGet(self, @"passwordField") stringValue];
    const char *bytes = password ? [password UTF8String] : "";
    SecKeychainRef keychain = NULL;
    OSStatus status = SecKeychainCreate(url.fileSystemRepresentation, (UInt32)strlen(bytes), bytes, false, NULL, &keychain);
    if (status == errSecSuccess) {
        id old = SIGet(self, @"keychain");
        SISet(self, @"keychain", (id)keychain);
        (void)old;
        CFRelease(keychain);
        SISet(self, @"error", nil);
    } else {
        SISet(self, @"error", SIStatusError(status));
    }
    return status;
}
- (NSInteger)runModalForDirectory:(NSString *)path file:(NSString *)name
{
    [self _ensurePasswordField];
    if (path)
        [self setDirectoryURL:[NSURL fileURLWithPath:path isDirectory:YES]];
    if (name)
        [self setNameFieldStringValue:name];
    if ([self runModal] != NSModalResponseOK)
        return NSCancelButton;
    return [self _createKeychainAtURL:self.URL] == errSecSuccess ? NSOKButton : NSCancelButton;
}
- (void)beginSheetForDirectory:(NSString *)path file:(NSString *)name modalForWindow:(NSWindow *)window modalDelegate:(id)delegate didEndSelector:(SEL)selector contextInfo:(void *)contextInfo
{
    [self _ensurePasswordField];
    if (path) [self setDirectoryURL:[NSURL fileURLWithPath:path isDirectory:YES]];
    if (name) [self setNameFieldStringValue:name];
    [window beginSheet:self completionHandler:^(NSModalResponse result) {
        NSInteger code = result == NSModalResponseOK && [self _createKeychainAtURL:self.URL] == errSecSuccess ? NSOKButton : NSCancelButton;
        SIInvokeSheetCallback(delegate, selector, self, code, contextInfo);
    }];
}
@end

@implementation SFKeychainSettingsPanel
- (instancetype)init
{
    if ((self = [super initWithContentRect:NSMakeRect(0, 0, 420, 220)
                                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                  backing:NSBackingStoreBuffered defer:NO])) {
        [self setTitle:@"Keychain Settings"];
        [self setReleasedWhenClosed:NO];
        NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 420, 220)];
        NSButton *lockSleep = [[NSButton alloc] initWithFrame:NSMakeRect(20, 155, 360, 26)];
        [lockSleep setButtonType:NSButtonTypeSwitch]; [lockSleep setTitle:@"Lock when the computer sleeps"];
        NSButton *autoLock = [[NSButton alloc] initWithFrame:NSMakeRect(20, 120, 360, 26)];
        [autoLock setButtonType:NSButtonTypeSwitch]; [autoLock setTitle:@"Lock after a period of inactivity"];
        NSTextField *minutes = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 80, 100, 26)];
        SILabel(content, @"Minutes before locking:", NSMakeRect(130, 80, 240, 26));
        [content addSubview:lockSleep]; [content addSubview:autoLock]; [content addSubview:minutes];
        SIButton(content, @"Cancel", NSMakeRect(210, 10, 90, 30), self, @selector(_cancel:));
        SIButton(content, @"Save", NSMakeRect(310, 10, 90, 30), self, @selector(_save:));
        SISet(self, @"lockOnSleepControl", lockSleep); SISet(self, @"autoLockControl", autoLock); SISet(self, @"minutesField", minutes);
        [lockSleep release]; [autoLock release]; [minutes release];
        [self setContentView:content]; [content release];
    }
    return self;
}
+ (SFKeychainSettingsPanel *)sharedKeychainSettingsPanel
{
    static SFKeychainSettingsPanel *panel;
    @synchronized (self) { if (!panel) panel = [[self alloc] init]; }
    return panel;
}
- (NSInteger)runModalForSettings:(SecKeychainSettings *)settings keychain:(SecKeychainRef)keychain
{
    if (settings && settings->version != SEC_KEYCHAIN_SETTINGS_VERS1) {
        SISet(self, @"error", SIStatusError(errSecParam));
        return NSCancelButton;
    }
    SecKeychainSettings current = {SEC_KEYCHAIN_SETTINGS_VERS1, false, false, 0};
    if (settings && settings->version == SEC_KEYCHAIN_SETTINGS_VERS1)
        current = *settings;
    else if (SecKeychainCopySettings(keychain, &current) != errSecSuccess)
        return NSCancelButton;
    [SIGet(self, @"lockOnSleepControl") setState:current.lockOnSleep ? NSControlStateValueOn : NSControlStateValueOff];
    [SIGet(self, @"autoLockControl") setState:current.useLockInterval ? NSControlStateValueOn : NSControlStateValueOff];
    [SIGet(self, @"minutesField") setStringValue:[NSString stringWithFormat:@"%u", current.lockInterval / 60]];
    SISet(self, @"settingsPointer", settings ? [NSValue valueWithPointer:settings] : nil);
    SISet(self, @"keychain", (id)keychain);
    [[NSApplication sharedApplication] runModalForWindow:self];
    return [SIGet(self, @"modalResult") integerValue];
}
- (void)beginSheetForWindow:(NSWindow *)window modalDelegate:(id)delegate didEndSelector:(SEL)selector contextInfo:(void *)contextInfo settings:(SecKeychainSettings *)settings keychain:(SecKeychainRef)keychain
{
    if (settings && settings->version != SEC_KEYCHAIN_SETTINGS_VERS1) {
        SISet(self, @"error", SIStatusError(errSecParam));
        SIInvokeSheetCallback(delegate, selector, self, NSCancelButton, contextInfo);
        return;
    }
    SecKeychainSettings current = {SEC_KEYCHAIN_SETTINGS_VERS1, false, false, 0};
    if (settings && settings->version == SEC_KEYCHAIN_SETTINGS_VERS1)
        current = *settings;
    else if (SecKeychainCopySettings(keychain, &current) != errSecSuccess) {
        SIInvokeSheetCallback(delegate, selector, self, NSCancelButton, contextInfo);
        return;
    }
    [SIGet(self, @"lockOnSleepControl") setState:current.lockOnSleep ? NSControlStateValueOn : NSControlStateValueOff];
    [SIGet(self, @"autoLockControl") setState:current.useLockInterval ? NSControlStateValueOn : NSControlStateValueOff];
    [SIGet(self, @"minutesField") setStringValue:[NSString stringWithFormat:@"%u", current.lockInterval / 60]];
    SISet(self, @"settingsPointer", settings ? [NSValue valueWithPointer:settings] : nil);
    SISet(self, @"keychain", (id)keychain);
    SIStoreSheetCallback(self, window, delegate, selector, contextInfo);
    [window beginSheet:self completionHandler:^(NSModalResponse result) {
        NSInteger code = result == NSModalResponseOK ? NSOKButton : NSCancelButton;
        SIInvokeSheetCallback(SIGetNonretained(self, @"modalDelegate"), NSSelectorFromString(SIGet(self, @"didEndSelector")), self, code, [SIGet(self, @"contextInfo") pointerValue]);
        [self orderOut:nil];
    }];
}
- (void)_save:(id)sender
{
    NSInteger minutes = [[SIGet(self, @"minutesField") stringValue] integerValue];
    if (minutes < 0 || (uint64_t)minutes > UINT32_MAX / 60) {
        SISet(self, @"error", SIStatusError(errSecParam));
        return;
    }
    SecKeychainSettings settings = {SEC_KEYCHAIN_SETTINGS_VERS1,
        [SIGet(self, @"lockOnSleepControl") state] == NSControlStateValueOn,
        [SIGet(self, @"autoLockControl") state] == NSControlStateValueOn,
        (UInt32)(minutes * 60)};
    OSStatus status = SecKeychainSetSettings((SecKeychainRef)SIGet(self, @"keychain"), &settings);
    if (status != errSecSuccess) {
        SISet(self, @"error", SIStatusError(status));
        SISet(self, @"modalResult", @(NSCancelButton));
        SIEndPanel(self, NSModalResponseCancel);
        return;
    }
    SecKeychainSettings *output = [SIGet(self, @"settingsPointer") pointerValue];
    if (output) *output = settings;
    SISet(self, @"error", nil);
    SISet(self, @"modalResult", @(NSOKButton));
    SIEndPanel(self, NSModalResponseOK);
}
- (void)_cancel:(id)sender { SISet(self, @"modalResult", @(NSCancelButton)); SIEndPanel(self, NSModalResponseCancel); }
@end

@interface SIRights : NSObject {
    AuthorizationItem *_items;
    AuthorizationRights _rights;
}
- (void)setRightString:(AuthorizationString)name;
- (void)setRights:(const AuthorizationRights *)rights;
- (AuthorizationRights *)rights;
@end

@implementation SIRights
- (void)dealloc
{
    for (UInt32 i = 0; i < _rights.count; i++) {
        free((void *)_items[i].name);
        free(_items[i].value);
    }
    free(_items);
    [super dealloc];
}
- (void)setRightString:(AuthorizationString)name
{
    AuthorizationItem item = {name, 0, NULL, 0};
    AuthorizationRights rights = {1, &item};
    [self setRights:&rights];
}
- (void)setRights:(const AuthorizationRights *)rights
{
    for (UInt32 i = 0; i < _rights.count; i++) { free((void *)_items[i].name); free(_items[i].value); }
    free(_items); _items = NULL; _rights.count = 0; _rights.items = NULL;
    if (!rights || !rights->count)
        return;
    _items = calloc(rights->count, sizeof(*_items));
    if (!_items)
        return;
    _rights.count = rights->count; _rights.items = _items;
    for (UInt32 i = 0; i < rights->count; i++) {
        const AuthorizationItem *source = &rights->items[i];
        _items[i].name = source->name ? strdup(source->name) : NULL;
        _items[i].valueLength = source->valueLength;
        _items[i].flags = source->flags;
        if (source->valueLength && source->value) {
            _items[i].value = malloc(source->valueLength);
            if (_items[i].value) memcpy(_items[i].value, source->value, source->valueLength);
        }
    }
}
- (AuthorizationRights *)rights { return &_rights; }
@end

@interface SIAuthorizationTimerProxy : NSObject {
    SFAuthorizationView *_view;
}
- (instancetype)initWithView:(SFAuthorizationView *)view;
- (void)fire:(NSTimer *)timer;
- (void)invalidate;
@end

@implementation SIAuthorizationTimerProxy
- (instancetype)initWithView:(SFAuthorizationView *)view
{
    if ((self = [super init]))
        _view = view;
    return self;
}
- (void)fire:(NSTimer *)timer
{
    if (_view)
        [_view updateStatus:timer];
}
- (void)invalidate { _view = nil; }
@end

@implementation SFAuthorizationView
- (instancetype)initWithFrame:(NSRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        NSButton *button = [[NSButton alloc] initWithFrame:self.bounds];
        [button setTitle:@"Unlock"];
        [button setBezelStyle:NSBezelStyleRounded];
        [button setTarget:self]; [button setAction:@selector(_toggle:)]
        ;
        [button setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
        [self addSubview:button];
        SISet(self, @"button", button);
        [button release];
        SISet(self, @"authorizationState", @(SFAuthorizationStartupState));
        SISet(self, @"enabled", @YES);
        SISet(self, @"flags", @(kAuthorizationFlagDefaults));
    }
    return self;
}
- (void)dealloc
{
    [(NSTimer *)SIGet(self, @"timer") invalidate];
    [(SIAuthorizationTimerProxy *)SIGet(self, @"timerProxy") invalidate];
    [super dealloc];
}
- (void)setString:(AuthorizationString)string { SIRights *rights = SIGet(self, @"rights"); if (!rights) { rights = [[[SIRights alloc] init] autorelease]; SISet(self, @"rights", rights); } [rights setRightString:string]; }
- (void)setAuthorizationRights:(const AuthorizationRights *)rights { SIRights *copy = [[[SIRights alloc] init] autorelease]; [copy setRights:rights]; SISet(self, @"rights", copy); }
- (AuthorizationRights *)authorizationRights { return [(SIRights *)SIGet(self, @"rights") rights]; }
- (SFAuthorization *)authorization
{
    SFAuthorization *authorization = SIGet(self, @"authorization");
    if (!authorization) { authorization = [SFAuthorization authorization]; SISet(self, @"authorization", authorization); }
    return authorization;
}
- (BOOL)updateStatus:(id)sender
{
    AuthorizationRights *rights = self.authorizationRights;
    BOOL authorized = rights && rights->count && [self.authorization permitWithRights:rights environment:NULL flags:[SIGet(self, @"flags") unsignedIntValue] authorizedRights:NULL] == errAuthorizationSuccess;
    BOOL wasAuthorized = SIGetBool(self, @"authorized");
    SFAuthorizationViewState previousState = self.authorizationState;
    SISetBool(self, @"authorized", authorized);
    SISet(self, @"authorizationState", @(authorized ? SFAuthorizationViewUnlockedState : SFAuthorizationViewLockedState));
    [SIGet(self, @"button") setTitle:authorized ? @"Lock" : @"Unlock"];
    id delegate = SIGetNonretained(self, @"delegate");
    if (delegate && (authorized != wasAuthorized || previousState == SFAuthorizationStartupState)) {
        SEL selector = authorized ? @selector(authorizationViewDidAuthorize:) : @selector(authorizationViewDidDeauthorize:);
        if ([delegate respondsToSelector:selector])
            ((void (*)(id, SEL, id))objc_msgSend)(delegate, selector, self);
    }
    return authorized;
}
- (void)setAutoupdate:(BOOL)enabled { [self setAutoupdate:enabled interval:30.0]; }
- (void)setAutoupdate:(BOOL)enabled interval:(NSTimeInterval)interval
{
    [(NSTimer *)SIGet(self, @"timer") invalidate];
    [(SIAuthorizationTimerProxy *)SIGet(self, @"timerProxy") invalidate];
    SISet(self, @"timer", nil);
    SISet(self, @"timerProxy", nil);
    SISetBool(self, @"autoupdate", enabled);
    if (enabled) {
        SIAuthorizationTimerProxy *proxy = [[SIAuthorizationTimerProxy alloc] initWithView:self];
        SISet(self, @"timerProxy", proxy);
        NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:MAX(interval, 1.0) target:proxy selector:@selector(fire:) userInfo:nil repeats:YES];
        SISet(self, @"timer", timer);
        [proxy release];
    }
}
- (SFAuthorizationViewState)authorizationState { return (SFAuthorizationViewState)[SIGet(self, @"authorizationState") integerValue]; }
- (void)setEnabled:(BOOL)enabled { SISetBool(self, @"enabled", enabled); [SIGet(self, @"button") setEnabled:enabled]; }
- (BOOL)isEnabled { return SIGetBool(self, @"enabled"); }
- (void)setFlags:(AuthorizationFlags)flags { SISet(self, @"flags", @(flags)); }
- (void)setDelegate:(id)delegate { SISetNonretained(self, @"delegate", delegate); }
- (id)delegate { return SIGetNonretained(self, @"delegate"); }
- (BOOL)authorize:(id)sender
{
    AuthorizationRights *rights = self.authorizationRights;
    if (!rights || !rights->count)
        return NO;
    NSError *error = nil;
    BOOL authorized = [self.authorization obtainWithRights:rights flags:[SIGet(self, @"flags") unsignedIntValue] | kAuthorizationFlagInteractionAllowed environment:NULL authorizedRights:NULL error:&error];
    SISet(self, @"lastError", error);
    if (authorized) {
        SISetBool(self, @"authorized", YES);
        SISet(self, @"authorizationState", @(SFAuthorizationViewUnlockedState));
        id delegate = self.delegate;
        if ([delegate respondsToSelector:@selector(authorizationViewDidAuthorize:)])
            ((void (*)(id, SEL, id))objc_msgSend)(delegate, @selector(authorizationViewDidAuthorize:), self);
    } else if ([self.delegate respondsToSelector:@selector(authorizationViewDidCancelAuthorization:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(self.delegate, @selector(authorizationViewDidCancelAuthorization:), self);
    }
    [SIGet(self, @"button") setTitle:authorized ? @"Lock" : @"Unlock"];
    return authorized;
}
- (BOOL)deauthorize:(id)sender
{
    id delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(authorizationViewShouldDeauthorize:)] &&
        !((BOOL (*)(id, SEL, id))objc_msgSend)(delegate, @selector(authorizationViewShouldDeauthorize:), self))
        return NO;
    [self.authorization invalidateCredentials:YES];
    SISetBool(self, @"authorized", NO);
    SISet(self, @"authorizationState", @(SFAuthorizationViewLockedState));
    if ([delegate respondsToSelector:@selector(authorizationViewDidDeauthorize:)])
        ((void (*)(id, SEL, id))objc_msgSend)(delegate, @selector(authorizationViewDidDeauthorize:), self);
    [SIGet(self, @"button") setTitle:@"Unlock"];
    return YES;
}
- (void)_toggle:(id)sender { if (SIGetBool(self, @"authorized")) [self deauthorize:sender]; else [self authorize:sender]; }
@end

@implementation SFAuthorizationPluginView
- (instancetype)initWithCallbacks:(const AuthorizationCallbacks *)callbacks andEngineRef:(AuthorizationEngineRef)engineRef
{
    if ((self = [super init])) {
        if (callbacks) SISet(self, @"callbacks", [NSData dataWithBytes:callbacks length:sizeof(*callbacks)]);
        SISet(self, @"engineRef", [NSValue valueWithPointer:engineRef]);
        SISetBool(self, @"enabled", YES);
    }
    return self;
}
- (AuthorizationEngineRef)engineRef { return [SIGet(self, @"engineRef") pointerValue]; }
- (const AuthorizationCallbacks *)callbacks
{
    NSData *data = SIGet(self, @"callbacks");
    return data.length == sizeof(AuthorizationCallbacks) ? (const AuthorizationCallbacks *)data.bytes : NULL;
}
- (void)buttonPressed:(SFButtonType)button
{
    const AuthorizationCallbacks *callbacks = self.callbacks;
    if (!callbacks || !callbacks->SetResult)
        return;
    callbacks->SetResult(self.engineRef, button == SFButtonTypeCancel ? kAuthorizationResultUserCanceled : kAuthorizationResultDeny);
}
- (NSError *)lastError { return SIGet(self, @"lastError"); }
- (void)didActivate { SISetBool(self, @"active", YES); }
- (void)willActivateWithUser:(NSDictionary *)user
{
    NSTextField *field = SIGet(self, @"userField");
    NSString *name = user[SFAuthorizationPluginViewUserShortNameKey] ?: user[SFAuthorizationPluginViewUserNameKey];
    if (field && name) [field setStringValue:name];
}
- (void)didDeactivate { SISetBool(self, @"active", NO); }
- (NSView *)viewForType:(SFViewType)type
{
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 394, type == SFViewTypeIdentityAndCredentials ? 88 : 48)];
    NSTextField *user = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 48, 360, 28)];
    [user setPlaceholderString:@"User name"];
    [view addSubview:user];
    SISet(self, @"userField", user);
    [user release];
    if (type == SFViewTypeIdentityAndCredentials) {
        NSSecureTextField *password = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 8, 360, 28)];
        [password setPlaceholderString:@"Password"];
        [view addSubview:password];
        SISet(self, @"passwordField", password);
        [password release];
    }
    [view setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    return [view autorelease];
}
- (NSView *)firstKeyView { return SIGet(self, @"userField"); }
- (NSResponder *)firstResponder { return SIGet(self, @"userField"); }
- (NSView *)lastKeyView { return SIGet(self, @"passwordField") ?: SIGet(self, @"userField"); }
- (void)setEnabled:(BOOL)enabled
{
    SISetBool(self, @"enabled", enabled);
    [SIGet(self, @"userField") setEnabled:enabled];
    [SIGet(self, @"passwordField") setEnabled:enabled];
}
- (void)displayView
{
    SISet(self, @"lastError", [NSError errorWithDomain:NSOSStatusErrorDomain code:errAuthorizationInternal userInfo:@{NSLocalizedDescriptionKey : @"Finch has no system authorization UI service."}]);
}
- (void)setButton:(SFButtonType)button enabled:(BOOL)enabled { SISet(self, button == SFButtonTypeCancel ? @"cancelEnabled" : @"okEnabled", @(enabled)); }
- (void)updateView { }
@end

/* A small real cache for an internal class imported by Mail and Xcode. */
@interface SFIconCache : NSObject
+ (instancetype)sharedCache;
- (id)objectForKey:(id)key;
- (void)setObject:(id)object forKey:(id)key;
- (void)removeObjectForKey:(id)key;
- (void)removeAllObjects;
@end
@implementation SFIconCache {
    NSCache *_cache;
}
+ (instancetype)sharedCache
{
    static SFIconCache *cache;
    @synchronized (self) { if (!cache) cache = [[self alloc] init]; }
    return cache;
}
- (instancetype)init { if ((self = [super init])) _cache = [[NSCache alloc] init]; return self; }
- (void)dealloc { [_cache release]; [super dealloc]; }
- (id)objectForKey:(id)key { return [_cache objectForKey:key]; }
- (void)setObject:(id)object forKey:(id)key { if (object && key) [_cache setObject:object forKey:key]; }
- (void)removeObjectForKey:(id)key { if (key) [_cache removeObjectForKey:key]; }
- (void)removeAllObjects { [_cache removeAllObjects]; }
@end
