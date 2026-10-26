/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-openandsavepanel: the open and save panels of sandboxed apps (macOS's
 * "powerbox", a service AppKit runs them in). A sandboxed app can't list the
 * user's folders, so its NSOpenPanel and NSSavePanel ask this per-user agent
 * (Mach service org.finch.openandsavepanel) to show the panel instead. The
 * agent runs unsandboxed as the user, shows Finch's own panel with the app's
 * settings, and for each file the user chose issues a sandbox extension for
 * that app's process alone: read-write, or read-only when the app is only
 * entitled to read (com.apple.security.files.user-selected.read-only). An app
 * with neither entitlement gets nothing. The app consumes the extensions
 * (NSSavePanel.m) and may then use exactly those files.
 *
 * Request: kind ("open" or "save"), title, prompt, message, directory, name,
 * types (filename extensions), and canChooseFiles, canChooseDirectories,
 * multiple, canCreateDirectories, showsHidden. Reply: response (the panel's
 * NSModalResponse), urls and tokens (paths and their extensions, in order).
 */
#import <AppKit/AppKit.h>
#include <bsm/libbsm.h>
#include <pwd.h>
#include <xpc/xpc.h>

#define SERVICE "org.finch.openandsavepanel"
#define READ_WRITE "com.apple.security.files.user-selected.read-write"
#define READ_ONLY "com.apple.security.files.user-selected.read-only"

xpc_object_t xpc_copy_entitlement_for_token(const char *key, audit_token_t *token);
void xpc_dictionary_get_audit_token(xpc_object_t dictionary, audit_token_t *token);
char *sandbox_extension_issue_file_to_process(const char *extension_class, const char *path, uint32_t flags,
    audit_token_t token);

static NSString *string(xpc_object_t request, const char *key)
{
    const char *s = xpc_dictionary_get_string(request, key);
    return s ? [NSString stringWithUTF8String:s] : nil;
}

static bool entitled(audit_token_t *token, const char *key)
{
    xpc_object_t value = xpc_copy_entitlement_for_token(key, token);
    bool yes = value && xpc_get_type(value) == XPC_TYPE_BOOL && xpc_bool_get_value(value);
    if (value)
        xpc_release(value);
    return yes;
}

/* Where the panel starts: the app's folder, unless it's in the app's own
   container (the user picks among their files), else Documents. */
static NSURL *startingFolder(NSString *requested)
{
    NSString *home = [NSString stringWithUTF8String:getpwuid(getuid())->pw_dir];
    NSString *containers = [home stringByAppendingPathComponent:@"Library/Containers"];
    BOOL isDirectory = NO;
    if (requested.length && ![requested hasPrefix:containers] &&
        [[NSFileManager defaultManager] fileExistsAtPath:requested isDirectory:&isDirectory] && isDirectory)
        return [NSURL fileURLWithPath:requested isDirectory:YES];
    return [NSURL fileURLWithPath:[home stringByAppendingPathComponent:@"Documents"] isDirectory:YES];
}

static void handle(xpc_object_t request)
{
    xpc_object_t reply = xpc_dictionary_create_reply(request);
    if (!reply)
        return;
    audit_token_t token;
    xpc_dictionary_get_audit_token(request, &token);
    /* The app's entitlement decides what the user's choice grants. */
    const char *extensionClass = entitled(&token, READ_WRITE) ? "com.apple.app-sandbox.read-write" :
        entitled(&token, READ_ONLY) ? "com.apple.app-sandbox.read" : NULL;
    bool save = [string(request, "kind") isEqualToString:@"save"];
    NSModalResponse response = NSModalResponseCancel;
    xpc_object_t urls = xpc_array_create(NULL, 0), tokens = xpc_array_create(NULL, 0);

    if (extensionClass && !(save && strcmp(extensionClass, "com.apple.app-sandbox.read-write"))) {
        NSSavePanel *panel = save ? [NSSavePanel savePanel] : [NSOpenPanel openPanel];
        if (string(request, "title")) [panel setTitle:string(request, "title")];
        if (string(request, "prompt")) [panel setPrompt:string(request, "prompt")];
        if (string(request, "message")) [panel setMessage:string(request, "message")];
        if (string(request, "name")) [panel setNameFieldStringValue:string(request, "name")];
        [panel setDirectoryURL:startingFolder(string(request, "directory"))];
        [panel setCanCreateDirectories:xpc_dictionary_get_bool(request, "canCreateDirectories")];
        [panel setShowsHiddenFiles:xpc_dictionary_get_bool(request, "showsHidden")];
        xpc_object_t types = xpc_dictionary_get_value(request, "types");
        if (types && xpc_get_type(types) == XPC_TYPE_ARRAY && xpc_array_get_count(types) > 0) {
            NSMutableArray *list = [NSMutableArray array];
            for (size_t i = 0; i < xpc_array_get_count(types); i++)
                if (xpc_array_get_string(types, i))
                    [list addObject:[NSString stringWithUTF8String:xpc_array_get_string(types, i)]];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            [panel setAllowedFileTypes:list];
#pragma clang diagnostic pop
        }
        if (!save) {
            NSOpenPanel *open = (NSOpenPanel *)panel;
            [open setCanChooseFiles:xpc_dictionary_get_bool(request, "canChooseFiles")];
            [open setCanChooseDirectories:xpc_dictionary_get_bool(request, "canChooseDirectories")];
            [open setAllowsMultipleSelection:xpc_dictionary_get_bool(request, "multiple")];
        }
        [NSApp activateIgnoringOtherApps:YES];
        response = [panel runModal];
        if (response == NSModalResponseOK) {
            NSArray<NSURL *> *chosen = save ? @[ [panel URL] ] : [(NSOpenPanel *)panel URLs];
            for (NSURL *url in chosen) {
                char *t = sandbox_extension_issue_file_to_process(extensionClass, url.fileSystemRepresentation, 0,
                    token);
                if (!t)
                    continue;
                xpc_array_set_string(urls, XPC_ARRAY_APPEND, url.fileSystemRepresentation);
                xpc_array_set_string(tokens, XPC_ARRAY_APPEND, t);
                free(t);
            }
        }
    }
    xpc_dictionary_set_int64(reply, "response", response);
    xpc_dictionary_set_value(reply, "urls", urls);
    xpc_dictionary_set_value(reply, "tokens", tokens);
    xpc_release(urls);
    xpc_release(tokens);
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
