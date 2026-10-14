/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Window restoration, as macOS's Resume: when the app quits (unless the user
 * has NSQuitAlwaysKeepsWindows off), each visible window that's restorable and
 * has a restoration class has its restorable state written to
 * ~/Library/Saved Application State/<bundle id>.savedState/finch-windows.plist
 * (Finch's own format: per window, its restoration class, identifier and a
 * keyed archive of -encodeRestorableStateWithCoder:). At the next launch,
 * before the app finishes launching, each window's class is asked for it
 * (+restoreWindowWithIdentifier:state:completionHandler:), which gets back the
 * window's state (-restoreStateWithCoder:) and is ordered front as it was.
 * A document's window keeps its document's file and autosaved copy, so
 * untitled documents and unsaved changes come back (NSDocument.m).
 * ApplePersistenceIgnoreState skips restoring, as on macOS.
 */
#import "AppKit_Finch.h"
#import "NSView_Finch.h"

static NSString *
state_path(void)
{
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: [[NSProcessInfo processInfo] processName];
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Saved Application State"];
    dir = [dir stringByAppendingPathComponent:[bid stringByAppendingPathExtension:@"savedState"]];
    return [dir stringByAppendingPathComponent:@"finch-windows.plist"];
}

static BOOL
trace(void)
{
    return getenv("FINCH_TRACE_RESTORE") != NULL;
}

#pragma mark - A window's state

@implementation NSWindow (FinchRestoration)

- (void)encodeRestorableStateWithCoder:(NSCoder *)coder
{
    [super encodeRestorableStateWithCoder:coder];
    [coder encodeObject:NSStringFromRect([self frame]) forKey:@"NSWindowFrame"];
    [coder encodeBool:[self isMiniaturized] forKey:@"NSWindowMiniaturized"];
    NSWindowController *wc = [self windowController];
    [wc encodeRestorableStateWithCoder:coder];
    NSDocument *doc = [wc document];
    if (doc) {
        [coder encodeObject:[[doc fileURL] path] forKey:@"FinchDocumentPath"];
        [coder encodeObject:[[doc autosavedContentsFileURL] path] forKey:@"FinchDocumentAutosavedPath"];
        [coder encodeObject:[doc fileType] forKey:@"FinchDocumentType"];
        if (![doc fileURL])
            [coder encodeObject:[doc displayName] forKey:@"FinchDocumentName"];
        /* the document's own state, in an archive of its own so its keys are its own */
        NSKeyedArchiver *a = [[[NSKeyedArchiver alloc] initRequiringSecureCoding:NO] autorelease];
        [doc encodeRestorableStateWithCoder:a];
        [a finishEncoding];
        [coder encodeObject:[a encodedData] forKey:@"FinchDocumentState"];
    }
    id d = [self delegate];
    if ([d respondsToSelector:@selector(window:willEncodeRestorableState:)])
        [d window:self willEncodeRestorableState:coder];
}

- (void)restoreStateWithCoder:(NSCoder *)coder
{
    [super restoreStateWithCoder:coder];
    NSString *frame = [coder decodeObjectForKey:@"NSWindowFrame"];
    if (frame)
        [self setFrame:NSRectFromString(frame) display:NO];
    NSWindowController *wc = [self windowController];
    [wc restoreStateWithCoder:coder];
    NSData *docState = [coder decodeObjectForKey:@"FinchDocumentState"];
    NSDocument *doc = [wc document];
    if (doc && docState) {
        NSKeyedUnarchiver *u = [[[NSKeyedUnarchiver alloc] initForReadingFromData:docState error:NULL] autorelease];
        [u setRequiresSecureCoding:NO];
        [doc restoreStateWithCoder:u];
        [u finishDecoding];
    }
    id d = [self delegate];
    if ([d respondsToSelector:@selector(window:didDecodeRestorableState:)])
        [d window:self didDecodeRestorableState:coder];
}

@end

#pragma mark - Saving and restoring the app's windows

@implementation NSApplication (FinchRestoration)

/* As macOS's "Close windows when quitting an application", off: windows are kept. */
- (BOOL)_finchKeepsWindows
{
    id keep = [[NSUserDefaults standardUserDefaults] objectForKey:@"NSQuitAlwaysKeepsWindows"];
    return keep ? [keep boolValue] : YES;
}

- (void)_finchForgetWindows
{
    [[NSFileManager defaultManager] removeItemAtPath:state_path() error:NULL];
}

/* The windows to keep, back to front. */
- (void)_finchSaveWindows
{
    NSMutableArray *entries = [NSMutableArray array];
    NSArray *ordered = [[[self orderedWindows] reverseObjectEnumerator] allObjects];
    for (NSWindow *w in ordered) {
        if (![w isRestorable] || [w isSheet] || (![w isVisible] && ![w isMiniaturized]))
            continue;
        Class cls = [w restorationClass];
        if (!cls)
            continue;
        NSKeyedArchiver *a = [[[NSKeyedArchiver alloc] initRequiringSecureCoding:NO] autorelease];
        [w encodeRestorableStateWithCoder:a];
        [a finishEncoding];
        NSMutableDictionary *e = [NSMutableDictionary dictionary];
        e[@"class"] = NSStringFromClass(cls);
        e[@"identifier"] = [w identifier] ?: @"";
        e[@"state"] = [a encodedData];
        if (w == [self keyWindow])
            e[@"key"] = @YES;
        [entries addObject:e];
        if (trace())
            fprintf(stderr, "restore: keep %s window %s (%s)\n", NSStringFromClass(cls).UTF8String,
                    [[w title] UTF8String], NSStringFromRect([w frame]).UTF8String);
    }
    NSString *path = state_path();
    if (![entries count]) {
        [self _finchForgetWindows];
        return;
    }
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES attributes:nil error:NULL];
    [@{@"windows" : entries} writeToFile:path atomically:YES];
}

/* The windows kept at the last quit, each from its restoration class; how many came back.
   The saved state is used once. */
- (NSUInteger)_finchRestoreWindows
{
    NSString *path = state_path();
    NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:path];
    [self _finchForgetWindows];
    if (![saved isKindOfClass:[NSDictionary class]] ||
        [[NSUserDefaults standardUserDefaults] boolForKey:@"ApplePersistenceIgnoreState"])
        return 0;
    __block NSUInteger restored = 0;
    __block NSWindow *key = nil;
    for (NSDictionary *e in saved[@"windows"]) {
        if (![e isKindOfClass:[NSDictionary class]])
            continue;
        Class cls = NSClassFromString(e[@"class"]);
        NSData *data = e[@"state"];
        if (!cls || ![cls respondsToSelector:@selector(restoreWindowWithIdentifier:state:completionHandler:)] ||
            ![data isKindOfClass:[NSData class]])
            continue;
        NSKeyedUnarchiver *state = [[[NSKeyedUnarchiver alloc] initForReadingFromData:data error:NULL] autorelease];
        if (!state)
            continue;
        [state setRequiresSecureCoding:NO];
        BOOL wantsKey = [e[@"key"] boolValue];
        [cls restoreWindowWithIdentifier:e[@"identifier"] state:state completionHandler:^(NSWindow *w, NSError *error) {
            if (trace())
                fprintf(stderr, "restore: %s gave %s%s\n", NSStringFromClass(cls).UTF8String,
                        w ? [[w title] UTF8String] : "no window", error ? [[error description] UTF8String] : "");
            if (!w)
                return;
            [w restoreStateWithCoder:state];
            BOOL mini = [state decodeBoolForKey:@"NSWindowMiniaturized"];
            [w orderFront:nil];
            if (mini)
                [w miniaturize:nil];
            else if (wantsKey)
                key = w;
            restored++;
        }];
    }
    [key makeKeyAndOrderFront:nil];
    return restored;
}

@end
