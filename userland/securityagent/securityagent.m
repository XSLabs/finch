/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-securityagent: the password dialog authorization asks with (macOS's
 * SecurityAgent). authd, when a right needs an administrator's (or a user's)
 * password and the caller allows interaction, asks this per-user agent (Mach
 * service org.finch.securityagent, in the logged-in user's domain) to ask the
 * person at the screen. The name and password go to authd only, which checks
 * them with PAM and that this program is who answered; the app that asked never
 * sees them.
 *
 * Request: right, group (the group the password must belong to, if any),
 * client (the asking program's path), user (the name to suggest), retry (the
 * last password was wrong). Reply: cancelled, or user and password.
 */
#import <AppKit/AppKit.h>
#include <xpc/xpc.h>

#define SERVICE "org.finch.securityagent"

@interface FinchAgentDialog : NSObject
@property (strong) NSPanel *panel;
@property (strong) NSTextField *user;
@property (strong) NSSecureTextField *password;
@property NSModalResponse response;
@end

@implementation FinchAgentDialog
- (void)ok:(id)sender { [NSApp stopModalWithCode:NSModalResponseOK]; }
- (void)cancel:(id)sender { [NSApp stopModalWithCode:NSModalResponseCancel]; }
@end

/* Escape anywhere in the dialog cancels it. */
@interface FinchAgentPanel : NSPanel
@end
@implementation FinchAgentPanel
- (void)cancelOperation:(id)sender { [NSApp stopModalWithCode:NSModalResponseCancel]; }
@end

static NSString *string(xpc_object_t request, const char *key)
{
    const char *s = xpc_dictionary_get_string(request, key);
    return s ? [NSString stringWithUTF8String:s] : nil;
}

static NSTextField *label(NSString *text, NSRect frame, BOOL bold)
{
    NSTextField *t = [NSTextField wrappingLabelWithString:text];
    [t setFrame:frame];
    if (bold)
        [t setFont:[NSFont boldSystemFontOfSize:13]];
    return t;
}

static void handle(xpc_object_t request)
{
    xpc_object_t reply = xpc_dictionary_create_reply(request);
    if (!reply)
        return;
    NSString *client = [string(request, "client") lastPathComponent] ?: @"A program";
    NSString *group = string(request, "group");
    BOOL retry = xpc_dictionary_get_bool(request, "retry");

    FinchAgentDialog *d = [[FinchAgentDialog alloc] init];
    NSPanel *panel = [[FinchAgentPanel alloc] initWithContentRect:NSMakeRect(0, 0, 420, 230)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    [panel setTitle:@"Authorization"];
    [panel setLevel:NSModalPanelWindowLevel];
    NSView *v = [panel contentView];
    [v addSubview:label([NSString stringWithFormat:@"%@ wants to make changes.", client],
        NSMakeRect(20, 186, 380, 20), YES)];
    NSString *detail = [group isEqualToString:@"admin"] ?
        @"Enter an administrator’s name and password to allow this." :
        @"Enter your password to allow this.";
    if (retry)
        detail = [@"The name or password was wrong. " stringByAppendingString:detail];
    [v addSubview:label(detail, NSMakeRect(20, 146, 380, 36), NO)];
    [v addSubview:label(@"User Name:", NSMakeRect(20, 112, 100, 20), NO)];
    [v addSubview:label(@"Password:", NSMakeRect(20, 80, 100, 20), NO)];
    d.user = [[NSTextField alloc] initWithFrame:NSMakeRect(125, 110, 275, 24)];
    [d.user setStringValue:string(request, "user") ?: @""];
    d.password = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(125, 78, 275, 24)];
    [v addSubview:d.user];
    [v addSubview:d.password];
    /* Return in either field answers, as the default button does. */
    [d.user setTarget:d];
    [d.user setAction:@selector(ok:)];
    [d.password setTarget:d];
    [d.password setAction:@selector(ok:)];
    [d.user setNextKeyView:d.password];
    [d.password setNextKeyView:d.user];
    NSButton *ok = [NSButton buttonWithTitle:@"OK" target:d action:@selector(ok:)];
    [ok setFrame:NSMakeRect(310, 20, 90, 30)];
    [ok setKeyEquivalent:@"\r"];
    NSButton *cancel = [NSButton buttonWithTitle:@"Cancel" target:d action:@selector(cancel:)];
    [cancel setFrame:NSMakeRect(210, 20, 90, 30)];
    [cancel setKeyEquivalent:@"\e"];
    [v addSubview:ok];
    [v addSubview:cancel];
    d.panel = panel;

    [panel center];
    [NSApp activateIgnoringOtherApps:YES];
    [panel makeKeyAndOrderFront:nil];
    /* The name first, selected: typing replaces the suggestion. */
    [panel makeFirstResponder:d.user];
    [[d.user currentEditor] selectAll:nil];
    NSModalResponse r = [NSApp runModalForWindow:panel];
    [panel orderOut:nil];

    if (r == NSModalResponseOK) {
        xpc_dictionary_set_string(reply, "user", [[d.user stringValue] UTF8String]);
        xpc_dictionary_set_string(reply, "password", [[d.password stringValue] UTF8String]);
    } else
        xpc_dictionary_set_bool(reply, "cancelled", true);
    [d.password setStringValue:@""];
    xpc_connection_send_message(xpc_dictionary_get_remote_connection(request), reply);
    xpc_release(reply);
}

int main(void)
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        xpc_connection_t listener = xpc_connection_create_mach_service(SERVICE, dispatch_get_main_queue(),
            XPC_CONNECTION_MACH_SERVICE_LISTENER);
        xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) {
            if (xpc_get_type(peer) != XPC_TYPE_CONNECTION)
                return;
            xpc_connection_set_event_handler(peer, ^(xpc_object_t message) {
                if (xpc_get_type(message) == XPC_TYPE_DICTIONARY)
                    handle(message);
            });
            xpc_connection_resume(peer);
        });
        xpc_connection_resume(listener);
        [NSApp finishLaunching];
        [NSApp run];
    }
    return 0;
}
