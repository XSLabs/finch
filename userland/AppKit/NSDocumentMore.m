/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The rest of NSDocument and NSDocumentController, as measured against Apple's
 * (document-more-test.m): the deprecated file-name methods (the current ones call an
 * app's overrides of them, NSDocument.m), synchronous saving, locking by the file's
 * user-immutable flag, moving and renaming, duplicating, printing and page layout
 * through NSPrintOperation and NSPageLayout, file-presenter callbacks, scripting
 * commands, user activities and restoration, and the controller's older helpers.
 */
#import "NSView_Finch.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <sys/stat.h>
#include <unistd.h>

@interface NSDocumentController (FinchTypes)
- (NSArray<NSDictionary *> *)_finchDocumentTypes;
@end

static void
call_did(id delegate, SEL sel, id doc, BOOL flag, void *contextInfo)
{
    if (delegate && sel)
        ((void (*)(id, SEL, id, BOOL, void *))objc_msgSend)(delegate, sel, doc, flag, contextInfo);
}

static void
finish_on_main(void (^handler)(NSError *), NSError *error)
{
    if (!handler)
        return;
    [error retain];
    dispatch_async(dispatch_get_main_queue(), ^{
        handler(error);
        [error release];
    });
}

#pragma mark - NSDocument

@implementation NSDocument (FinchMore)

#pragma mark Deprecated file names

- (instancetype)initWithContentsOfFile:(NSString *)absolutePath ofType:(NSString *)typeName
{
    return [self initWithContentsOfURL:[NSURL fileURLWithPath:absolutePath] ofType:typeName error:NULL];
}

- (instancetype)initWithContentsOfURL:(NSURL *)url ofType:(NSString *)typeName
{
    return [self initWithContentsOfURL:url ofType:typeName error:NULL];
}

- (NSString *)fileName { return [[self fileURL] path]; }
- (void)setFileName:(NSString *)fileName { [self setFileURL:fileName ? [NSURL fileURLWithPath:fileName] : nil]; }
- (NSString *)lastComponentOfFileName { return [[self fileURL] lastPathComponent] ?: [self displayName]; }

- (void)setLastComponentOfFileName:(NSString *)str
{
    NSURL *url = [self fileURL];
    if (url)
        [self setFileURL:[[url URLByDeletingLastPathComponent] URLByAppendingPathComponent:str]];
    else
        [self setDisplayName:str];
}

/* (each of these is what the current method would do; an app's override is what the
   current one calls instead) */
- (BOOL)readFromFile:(NSString *)fileName ofType:(NSString *)type
{
    return [self readFromURL:[NSURL fileURLWithPath:fileName] ofType:type error:NULL];
}

- (BOOL)readFromURL:(NSURL *)url ofType:(NSString *)type { return [self readFromURL:url ofType:type error:NULL]; }
- (BOOL)loadDataRepresentation:(NSData *)data ofType:(NSString *)type { return [self readFromData:data ofType:type error:NULL]; }
- (NSData *)dataRepresentationOfType:(NSString *)type { return [self dataOfType:type error:NULL]; }

- (BOOL)loadFileWrapperRepresentation:(NSFileWrapper *)wrapper ofType:(NSString *)type
{
    return [self readFromFileWrapper:wrapper ofType:type error:NULL];
}

- (NSFileWrapper *)fileWrapperRepresentationOfType:(NSString *)type { return [self fileWrapperOfType:type error:NULL]; }
- (BOOL)writeToFile:(NSString *)fileName ofType:(NSString *)type { return [self writeToURL:[NSURL fileURLWithPath:fileName] ofType:type error:NULL]; }
- (BOOL)writeToURL:(NSURL *)url ofType:(NSString *)type { return [self writeToURL:url ofType:type error:NULL]; }

- (BOOL)writeToFile:(NSString *)fullDocumentPath ofType:(NSString *)type originalFile:(NSString *)fullOriginalDocumentPath
      saveOperation:(NSSaveOperationType)saveOperationType
{
    return [self writeToFile:fullDocumentPath ofType:type];
}

- (BOOL)writeWithBackupToFile:(NSString *)fullDocumentPath ofType:(NSString *)type saveOperation:(NSSaveOperationType)saveOperationType
{
    return [self writeSafelyToURL:[NSURL fileURLWithPath:fullDocumentPath] ofType:type forSaveOperation:saveOperationType error:NULL];
}

- (NSDictionary *)fileAttributesToWriteToFile:(NSString *)fullDocumentPath ofType:(NSString *)documentTypeName
                                saveOperation:(NSSaveOperationType)saveOperationType
{
    return [self fileAttributesToWriteToURL:[NSURL fileURLWithPath:fullDocumentPath] ofType:documentTypeName
                           forSaveOperation:saveOperationType originalContentsURL:[self fileURL] error:NULL];
}

- (BOOL)revertToSavedFromFile:(NSString *)fileName ofType:(NSString *)type
{
    return [self revertToContentsOfURL:[NSURL fileURLWithPath:fileName] ofType:type error:NULL];
}

- (BOOL)revertToSavedFromURL:(NSURL *)url ofType:(NSString *)type { return [self revertToContentsOfURL:url ofType:type error:NULL]; }

- (void)saveToFile:(NSString *)fileName saveOperation:(NSSaveOperationType)saveOperation delegate:(id)delegate
    didSaveSelector:(SEL)didSaveSelector contextInfo:(void *)contextInfo
{
    if (!fileName) {
        call_did(delegate, didSaveSelector, self, NO, contextInfo);
        return;
    }
    [self saveToURL:[NSURL fileURLWithPath:fileName] ofType:[self fileType] forSaveOperation:saveOperation delegate:delegate
        didSaveSelector:didSaveSelector contextInfo:contextInfo];
}

#pragma mark Saving

/* The save, waited for (completion handlers run before this returns). */
- (BOOL)saveToURL:(NSURL *)url ofType:(NSString *)typeName forSaveOperation:(NSSaveOperationType)saveOperation error:(NSError **)outError
{
    __block BOOL done = NO, ok = NO;
    __block NSError *failure = nil;
    [self saveToURL:url ofType:typeName forSaveOperation:saveOperation completionHandler:^(NSError *error) {
        done = YES;
        ok = error == nil;
        failure = [error retain];
    }];
    while (!done)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    if (outError)
        *outError = [failure autorelease];
    else
        [failure release];
    return ok;
}

- (void)saveDocumentWithDelegate:(id)delegate didSaveSelector:(SEL)didSaveSelector contextInfo:(void *)contextInfo
{
    if ([self fileURL])
        [self saveToURL:[self fileURL] ofType:[self fileType] forSaveOperation:NSSaveOperation delegate:delegate
            didSaveSelector:didSaveSelector contextInfo:contextInfo];
    else
        [self runModalSavePanelForSaveOperation:NSSaveAsOperation delegate:delegate didSaveSelector:didSaveSelector
                                    contextInfo:contextInfo];
}

- (void)autosaveDocumentWithDelegate:(id)delegate didAutosaveSelector:(SEL)didAutosaveSelector contextInfo:(void *)contextInfo
{
    [self autosaveWithImplicitCancellability:NO completionHandler:^(NSError *error) {
        call_did(delegate, didAutosaveSelector, self, error == nil, contextInfo);
    }];
}

- (NSString *)defaultDraftName { return @"Untitled"; }

#pragma mark Locking

/* Locking sets the file's user-immutable flag (as the Finder's Locked box does). */
- (BOOL)_finchSetImmutable:(BOOL)flag error:(NSError **)error
{
    NSURL *url = [self fileURL];
    if (!url)
        return YES;
    struct stat st;
    if (stat([url fileSystemRepresentation], &st) != 0 ||
        chflags([url fileSystemRepresentation], flag ? (st.st_flags | UF_IMMUTABLE) : (st.st_flags & ~UF_IMMUTABLE)) != 0) {
        if (error)
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{NSURLErrorKey : url}];
        return NO;
    }
    [url removeAllCachedResourceValues];
    return YES;
}

- (void)lockWithCompletionHandler:(void (^)(NSError *))completionHandler
{
    NSError *error = nil;
    [self _finchSetImmutable:YES error:&error];
    finish_on_main(completionHandler, error);
}

- (void)unlockWithCompletionHandler:(void (^)(NSError *))completionHandler
{
    NSError *error = nil;
    [self _finchSetImmutable:NO error:&error];
    finish_on_main(completionHandler, error);
}

/* (saved first when edited, as Apple's) */
- (void)lockDocumentWithCompletionHandler:(void (^)(BOOL))completionHandler
{
    void (^lock)(void) = ^{
        [self lockWithCompletionHandler:^(NSError *error) {
            if (completionHandler)
                completionHandler(error == nil);
        }];
    };
    if ([self isDocumentEdited] && [self fileURL])
        [self saveToURL:[self fileURL] ofType:[self fileType] forSaveOperation:NSSaveOperation completionHandler:^(NSError *error) {
            if (error) {
                if (completionHandler)
                    completionHandler(NO);
            } else
                lock();
        }];
    else
        lock();
}

- (void)unlockDocumentWithCompletionHandler:(void (^)(BOOL))completionHandler
{
    [self unlockWithCompletionHandler:^(NSError *error) {
        if (completionHandler)
            completionHandler(error == nil);
    }];
}

- (IBAction)lockDocument:(id)sender { [self lockDocumentWithCompletionHandler:nil]; }
- (IBAction)unlockDocument:(id)sender { [self unlockDocumentWithCompletionHandler:nil]; }

#pragma mark Moving and renaming

- (void)moveToURL:(NSURL *)url completionHandler:(void (^)(NSError *))completionHandler
{
    NSURL *from = [self fileURL];
    NSError *error = nil;
    if (!from || !url)
        error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileNoSuchFileError userInfo:nil];
    else if ([[NSFileManager defaultManager] moveItemAtURL:from toURL:url error:&error]) {
        [self setFileURL:url];
        [self setFileModificationDate:[[[NSFileManager defaultManager] attributesOfItemAtPath:[url path] error:NULL] fileModificationDate]];
    }
    finish_on_main(completionHandler, error);
}

/* The save panel, titled Move To, then the move. */
- (void)moveDocumentWithCompletionHandler:(void (^)(BOOL))completionHandler
{
    NSSavePanel *panel = [NSSavePanel savePanel];
    [panel setTitle:@"Move To"];
    [panel setPrompt:@"Move"];
    [panel setNameFieldStringValue:[[self fileURL] lastPathComponent] ?: [self displayName]];
    if (![self prepareSavePanel:panel] || [panel runModal] != NSModalResponseOK) {
        if (completionHandler)
            completionHandler(NO);
        return;
    }
    if (![self fileURL]) {
        [self saveToURL:[panel URL] ofType:[self fileType] forSaveOperation:NSSaveAsOperation completionHandler:^(NSError *error) {
            if (completionHandler)
                completionHandler(error == nil);
        }];
        return;
    }
    [self moveToURL:[panel URL] completionHandler:^(NSError *error) {
        if (error)
            [self presentError:error];
        if (completionHandler)
            completionHandler(error == nil);
    }];
}

- (IBAction)moveDocument:(id)sender { [self moveDocumentWithCompletionHandler:nil]; }
- (IBAction)renameDocument:(id)sender { [self moveDocumentWithCompletionHandler:nil]; }

/* (no iCloud Drive: nothing to move to) */
- (IBAction)moveDocumentToUbiquityContainer:(id)sender
{
    [self presentError:[NSError errorWithDomain:NSCocoaErrorDomain code:NSFeatureUnsupportedError
                                       userInfo:@{NSLocalizedDescriptionKey : @"iCloud isn't available."}]];
}

#pragma mark Duplicating

- (IBAction)duplicateDocument:(id)sender
{
    [self duplicateDocumentWithDelegate:nil didDuplicateSelector:NULL contextInfo:NULL];
}

- (void)duplicateDocumentWithDelegate:(id)delegate didDuplicateSelector:(SEL)didDuplicateSelector contextInfo:(void *)contextInfo
{
    NSError *error = nil;
    NSDocument *copy = [self duplicateAndReturnError:&error] ? [[[NSDocumentController sharedDocumentController] documents] lastObject] : nil;
    if (!copy && error)
        [self presentError:error];
    if (delegate && didDuplicateSelector)
        ((void (*)(id, SEL, id, BOOL, void *))objc_msgSend)(delegate, didDuplicateSelector, copy, copy != nil, contextInfo);
}

#pragma mark Printing

- (BOOL)preparePageLayout:(NSPageLayout *)pageLayout { return YES; }
- (BOOL)shouldChangePrintInfo:(NSPrintInfo *)newPrintInfo { return YES; }

- (void)runModalPageLayoutWithPrintInfo:(NSPrintInfo *)printInfo delegate:(id)delegate
                         didRunSelector:(SEL)didRunSelector contextInfo:(void *)contextInfo
{
    NSPageLayout *layout = [NSPageLayout pageLayout];
    BOOL accepted = [self preparePageLayout:layout] && [layout runModalWithPrintInfo:printInfo] == NSModalResponseOK;
    if (accepted && [self shouldChangePrintInfo:printInfo])
        [self setPrintInfo:printInfo];
    call_did(delegate, didRunSelector, self, accepted, contextInfo);
}

- (NSInteger)runModalPageLayoutWithPrintInfo:(NSPrintInfo *)printInfo
{
    NSPageLayout *layout = [NSPageLayout pageLayout];
    return [self preparePageLayout:layout] ? [layout runModalWithPrintInfo:printInfo] : NSModalResponseCancel;
}

- (IBAction)runPageLayout:(id)sender
{
    NSPrintInfo *info = [[[self printInfo] copy] autorelease];
    [self runModalPageLayoutWithPrintInfo:info delegate:nil didRunSelector:NULL contextInfo:NULL];
}

- (void)runModalPrintOperation:(NSPrintOperation *)printOperation delegate:(id)delegate didRunSelector:(SEL)didRunSelector
                   contextInfo:(void *)contextInfo
{
    NSWindow *window = [self windowForSheet];
    if (window && [printOperation showsPrintPanel])
        [printOperation runOperationModalForWindow:window delegate:delegate didRunSelector:didRunSelector contextInfo:contextInfo];
    else
        call_did(delegate, didRunSelector, self, [printOperation runOperation], contextInfo);
}

/* The app's print operation (printOperationWithSettings:error:), run with or without
   the print panel. */
- (void)printDocumentWithSettings:(NSDictionary<NSPrintInfoAttributeKey, id> *)printSettings showPrintPanel:(BOOL)showPrintPanel
                         delegate:(id)delegate didPrintSelector:(SEL)didPrintSelector contextInfo:(void *)contextInfo
{
    NSError *error = nil;
    NSPrintOperation *op = [self printOperationWithSettings:printSettings ?: @{} error:&error];
    if (!op) {
        if (error)
            [self presentError:error];
        call_did(delegate, didPrintSelector, self, NO, contextInfo);
        return;
    }
    [op setShowsPrintPanel:showPrintPanel];
    [self runModalPrintOperation:op delegate:delegate didRunSelector:didPrintSelector contextInfo:contextInfo];
}

- (IBAction)printDocument:(id)sender
{
    [self printDocumentWithSettings:@{} showPrintPanel:YES delegate:nil didPrintSelector:NULL contextInfo:NULL];
}

- (void)printShowingPrintPanel:(BOOL)flag
{
    [self printDocumentWithSettings:@{} showPrintPanel:flag delegate:nil didPrintSelector:NULL contextInfo:NULL];
}

/* Export as PDF: a save panel for the PDF, then the print operation saving to it. */
- (IBAction)saveDocumentToPDF:(id)sender
{
    NSSavePanel *panel = [NSSavePanel savePanel];
    [panel setAllowedFileTypes:@[ @"pdf" ]];
    [panel setNameFieldStringValue:[[[self displayName] stringByDeletingPathExtension] stringByAppendingPathExtension:@"pdf"]];
    if ([panel runModal] != NSModalResponseOK)
        return;
    [self printDocumentWithSettings:@{NSPrintJobDisposition : NSPrintSaveJob, NSPrintJobSavingURL : [panel URL]} showPrintPanel:NO
                           delegate:nil didPrintSelector:NULL contextInfo:NULL];
}

#pragma mark Versions and sharing

/* Browse All Versions: Fieldwork's version browser, a sheet choosing among the document's
   saved versions (newest first) to restore. */
- (IBAction)browseDocumentVersions:(id)sender
{
    NSURL *url = [self fileURL];
    NSArray<NSFileVersion *> *versions = url ? [NSFileVersion otherVersionsOfItemAtURL:url] : @[];
    versions = [[versions reverseObjectEnumerator] allObjects];
    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    NSWindow *window = [[[self windowControllers] firstObject] window];
    if (![versions count]) {
        [alert setMessageText:[NSString stringWithFormat:@"“%@” has no other versions.", [self displayName]]];
        [alert setInformativeText:@"A version is kept each time the document is saved."];
        if (window)
            [alert beginSheetModalForWindow:window completionHandler:nil];
        else
            [alert runModal];
        return;
    }
    [alert setMessageText:[NSString stringWithFormat:@"Restore a version of “%@”", [self displayName]]];
    [alert setInformativeText:@"The document's contents are replaced with the version's."];
    [alert addButtonWithTitle:@"Restore"];
    [alert addButtonWithTitle:@"Cancel"];
    NSPopUpButton *popup = [[[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 280, 26) pullsDown:NO] autorelease];
    NSDateFormatter *df = [[[NSDateFormatter alloc] init] autorelease];
    [df setDateStyle:NSDateFormatterMediumStyle];
    /* (with seconds: saves a minute apart or less are told apart) */
    [df setTimeStyle:NSDateFormatterMediumStyle];
    for (NSFileVersion *v in versions)
        [popup addItemWithTitle:[df stringFromDate:[v modificationDate]] ?: [v localizedName]];
    [alert setAccessoryView:popup];
    void (^finish)(NSModalResponse) = ^(NSModalResponse r) {
        if (r != NSAlertFirstButtonReturn)
            return;
        NSFileVersion *chosen = versions[(NSUInteger)[popup indexOfSelectedItem]];
        NSError *error = nil;
        if (![chosen replaceItemAtURL:url options:0 error:&error] ||
            ![self revertToContentsOfURL:url ofType:[self fileType] error:&error])
            [self presentError:error];
    };
    if (window)
        [alert beginSheetModalForWindow:window completionHandler:finish];
    else
        finish([alert runModal]);
}

- (void)stopBrowsingVersionsWithCompletionHandler:(void (^)(void))completionHandler
{
    if (completionHandler)
        dispatch_async(dispatch_get_main_queue(), completionHandler);
}

- (void)prepareSharingServicePicker:(NSSharingServicePicker *)sharingServicePicker {}

- (void)shareDocumentWithSharingService:(NSSharingService *)sharingService completionHandler:(void (^)(BOOL))completionHandler
{
    NSURL *url = [self fileURL];
    BOOL can = url && [sharingService canPerformWithItems:@[ url ]];
    if (can)
        [sharingService performWithItems:@[ url ]];
    if (completionHandler)
        completionHandler(can);
}

- (void)unblockUserInteraction {}
- (void)willNotPresentError:(NSError *)error {}

#pragma mark User activity

static char user_activity_key;

/* As Apple's: a document activity (com.apple.appkit.document) from the start. */
- (NSUserActivity *)userActivity
{
    NSUserActivity *a = objc_getAssociatedObject(self, &user_activity_key);
    if (!a) {
        a = [[[NSUserActivity alloc] initWithActivityType:@"com.apple.appkit.document"] autorelease];
        objc_setAssociatedObject(self, &user_activity_key, a, OBJC_ASSOCIATION_RETAIN);
    }
    return a;
}

- (void)setUserActivity:(NSUserActivity *)userActivity
{
    objc_setAssociatedObject(self, &user_activity_key, userActivity, OBJC_ASSOCIATION_RETAIN);
}

- (void)updateUserActivityState:(NSUserActivity *)activity {}

#pragma mark File presentation

- (NSURL *)presentedItemURL { return [self fileURL]; }

- (NSOperationQueue *)presentedItemOperationQueue
{
    static NSOperationQueue *queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = [[NSOperationQueue alloc] init];
        [queue setMaxConcurrentOperationCount:1];
    });
    return queue;
}

/* (callbacks come on the presenter queue; the document changes on the main thread) */
- (void)presentedItemDidMoveToURL:(NSURL *)newURL
{
    [newURL retain];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setFileURL:newURL];
        [newURL release];
    });
}

/* Changed on disk: an unedited document reads it again. */
- (void)presentedItemDidChange
{
    dispatch_async(dispatch_get_main_queue(), ^{
        NSURL *url = [self fileURL];
        NSDate *now = [[[NSFileManager defaultManager] attributesOfItemAtPath:[url path] error:NULL] fileModificationDate];
        if (url && now && ![now isEqualToDate:[self fileModificationDate]] && ![self isDocumentEdited]) {
            if ([self revertToContentsOfURL:url ofType:[self fileType] error:NULL])
                [self setFileModificationDate:now];
        }
    });
}

- (void)relinquishPresentedItemToReader:(void (^)(void (^)(void)))reader
{
    if (reader)
        reader(^{
        });
}

- (void)relinquishPresentedItemToWriter:(void (^)(void (^)(void)))writer
{
    if (writer)
        writer(^{
        });
}

- (void)savePresentedItemChangesWithCompletionHandler:(void (^)(NSError *))completionHandler
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self autosaveWithImplicitCancellability:NO completionHandler:^(NSError *error) {
            if (completionHandler)
                completionHandler(error);
        }];
    });
}

/* (the document stays open, as Apple's: its file is simply gone) */
- (void)accommodatePresentedItemDeletionWithCompletionHandler:(void (^)(NSError *))completionHandler
{
    if (completionHandler)
        completionHandler(nil);
}

- (void)presentedItemDidGainVersion:(NSFileVersion *)version {}
- (void)presentedItemDidLoseVersion:(NSFileVersion *)version {}
- (void)presentedItemDidResolveConflictVersion:(NSFileVersion *)version {}
- (void)presentedItemDidChangeUbiquityAttributes:(NSSet<NSURLResourceKey> *)attributes {}

#pragma mark Scripting

/* save: "in" a file, "as" a type, else to the document's own file. */
- (id)handleSaveScriptCommand:(NSScriptCommand *)command
{
    NSDictionary *args = [command evaluatedArguments];
    NSURL *url = args[@"File"] ?: [self fileURL];
    NSString *type = args[@"FileType"] ?: [self fileType];
    if (!url) {
        [command setScriptErrorNumber:-1];
        return nil;
    }
    NSError *error = nil;
    if (![self saveToURL:url ofType:type forSaveOperation:args[@"File"] ? NSSaveAsOperation : NSSaveOperation error:&error]) {
        [command setScriptErrorNumber:(int)[error code]];
        [command setScriptErrorString:[error localizedDescription]];
    }
    return nil;
}

/* close: saving first when asked ("yes"), closing unedited or when told not to save. */
- (id)handleCloseScriptCommand:(NSCloseCommand *)command
{
    NSSaveOptions options = [command respondsToSelector:@selector(saveOptions)] ? [command saveOptions] : NSSaveOptionsAsk;
    if (options == NSSaveOptionsYes && [self isDocumentEdited] && [self fileURL])
        [self saveToURL:[self fileURL] ofType:[self fileType] forSaveOperation:NSSaveOperation error:NULL];
    [self close];
    return nil;
}

- (id)handlePrintScriptCommand:(NSScriptCommand *)command
{
    NSDictionary *args = [command evaluatedArguments];
    BOOL dialog = [args[@"ShowPrintDialog"] boolValue];
    [self printDocumentWithSettings:args[@"PrintSettings"] ?: @{} showPrintPanel:dialog delegate:nil didPrintSelector:NULL contextInfo:NULL];
    return nil;
}

#pragma mark Restoration

+ (NSArray<NSString *> *)restorableStateKeyPaths { return @[]; }
+ (NSArray<Class> *)allowedClassesForRestorableStateKeyPath:(NSString *)keyPath { return @[]; }

- (void)encodeRestorableStateWithCoder:(NSCoder *)coder backgroundQueue:(NSOperationQueue *)queue
{
    [self encodeRestorableStateWithCoder:coder];
}

- (void)restoreDocumentWindowWithIdentifier:(NSUserInterfaceItemIdentifier)identifier state:(NSCoder *)state
                          completionHandler:(void (^)(NSWindow *, NSError *))completionHandler
{
    if (![[self windowControllers] count])
        [self makeWindowControllers];
    NSWindow *found = nil;
    for (NSWindowController *wc in [self windowControllers])
        if (!found || [[[wc window] identifier] isEqualToString:identifier])
            found = [wc window];
    if (completionHandler)
        completionHandler(found, found ? nil : [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil]);
}

@end

#pragma mark - NSDocumentController

@implementation NSDocumentController (FinchMoreHelpers)

static char create_ui_key;

- (BOOL)shouldCreateUI
{
    NSNumber *n = objc_getAssociatedObject(self, &create_ui_key);
    return n ? [n boolValue] : YES;
}

- (void)setShouldCreateUI:(BOOL)flag { objc_setAssociatedObject(self, &create_ui_key, @(flag), OBJC_ASSOCIATION_RETAIN); }

/* The type an extension names in the app's declared document types (old-style names
   by extension), else nil, as Apple's. */
- (NSString *)typeFromFileExtension:(NSString *)fileNameExtensionOrHFSFileType
{
    NSString *ext = [fileNameExtensionOrHFSFileType lowercaseString];
    for (NSDictionary *t in [self _finchDocumentTypes]) {
        for (NSString *e in t[@"CFBundleTypeExtensions"])
            if ([[e lowercaseString] isEqualToString:ext])
                return t[@"CFBundleTypeName"] ?: [t[@"LSItemContentTypes"] firstObject];
    }
    return nil;
}

- (NSArray *)fileExtensionsFromType:(NSString *)typeName
{
    for (NSDictionary *t in [self _finchDocumentTypes])
        if ([t[@"CFBundleTypeName"] isEqualToString:typeName] || [t[@"LSItemContentTypes"] containsObject:typeName]) {
            NSArray *exts = t[@"CFBundleTypeExtensions"];
            if ([exts count])
                return exts;
            NSMutableArray *out = [NSMutableArray array];
            for (NSString *uti in t[@"LSItemContentTypes"])
                [out addObjectsFromArray:[[UTType typeWithIdentifier:uti] tags][UTTagClassFilenameExtension] ?: @[]];
            return out;
        }
    return nil;
}

/* As Apple's: the File menu's Share item, its submenu filled when shown. */
- (NSMenuItem *)standardShareMenuItem
{
    NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle:@"Share" action:@selector(submenuAction:) keyEquivalent:@""] autorelease];
    [item setSubmenu:[[[NSMenu alloc] initWithTitle:@"Share"] autorelease]];
    return item;
}

- (id)documentForFileName:(NSString *)fileName { return fileName ? [self documentForURL:[NSURL fileURLWithPath:fileName]] : nil; }

- (NSArray *)fileNamesFromRunningOpenPanel { return [[self URLsFromRunningOpenPanel] valueForKey:@"path"]; }

- (void)beginOpenPanelWithCompletionHandler:(void (^)(NSArray<NSURL *> *))completionHandler
{
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    [panel setAllowsMultipleSelection:YES];
    [self beginOpenPanel:panel forTypes:[self allowedTypesForOpenPanel] completionHandler:^(NSInteger result) {
        if (completionHandler)
            completionHandler(result == NSModalResponseOK ? [panel URLs] : nil);
    }];
}

- (id)makeUntitledDocumentOfType:(NSString *)type { return [self makeUntitledDocumentOfType:type error:NULL]; }
- (id)makeDocumentWithContentsOfFile:(NSString *)fileName ofType:(NSString *)type
{
    return [self makeDocumentWithContentsOfURL:[NSURL fileURLWithPath:fileName] ofType:type error:NULL];
}
- (id)makeDocumentWithContentsOfURL:(NSURL *)url ofType:(NSString *)type
{
    return [self makeDocumentWithContentsOfURL:url ofType:type error:NULL];
}

- (id)openDocumentWithContentsOfFile:(NSString *)fileName display:(BOOL)display
{
    return [self openDocumentWithContentsOfURL:[NSURL fileURLWithPath:fileName] display:display error:NULL];
}

- (id)openDocumentWithContentsOfURL:(NSURL *)url display:(BOOL)display
{
    return [self openDocumentWithContentsOfURL:url display:display error:NULL];
}

- (id)openUntitledDocumentOfType:(NSString *)type display:(BOOL)display
{
    NSDocument *doc = [self makeUntitledDocumentOfType:type error:NULL];
    if (!doc)
        return nil;
    [self addDocument:doc];
    if (display) {
        [doc makeWindowControllers];
        [doc showWindows];
    }
    return doc;
}

/* A document for a file, read from another (an autosaved copy, say). */
- (BOOL)reopenDocumentForURL:(NSURL *)urlOrNil withContentsOfURL:(NSURL *)contentsURL error:(NSError **)outError
{
    NSString *type = [self typeForContentsOfURL:contentsURL error:outError];
    NSDocument *doc = type ? [self makeDocumentForURL:urlOrNil withContentsOfURL:contentsURL ofType:type error:outError] : nil;
    if (!doc)
        return NO;
    [self addDocument:doc];
    [doc makeWindowControllers];
    [doc showWindows];
    return YES;
}

- (void)reopenDocumentForURL:(NSURL *)urlOrNil withContentsOfURL:(NSURL *)contentsURL display:(BOOL)displayDocument
           completionHandler:(void (^)(NSDocument *, BOOL, NSError *))completionHandler
{
    NSError *error = nil;
    NSString *type = [self typeForContentsOfURL:contentsURL error:&error];
    NSDocument *doc = type ? [self makeDocumentForURL:urlOrNil withContentsOfURL:contentsURL ofType:type error:&error] : nil;
    if (doc) {
        [self addDocument:doc];
        if (displayDocument) {
            [doc makeWindowControllers];
            [doc showWindows];
        }
    }
    if (completionHandler)
        completionHandler(doc, NO, doc ? nil : error);
}

/* A new untitled document with the file's contents (a copy of the file read, when
   copying), named as given; nil when no document class reads the file's type. */
- (__kindof NSDocument *)duplicateDocumentWithContentsOfURL:(NSURL *)url copying:(BOOL)duplicateByCopying
                                                displayName:(NSString *)displayNameOrNil error:(NSError **)outError
{
    NSString *type = url ? [self typeForContentsOfURL:url error:outError] : nil;
    Class cls = type ? [self documentClassForType:type] : Nil;
    if (!cls) {
        if (outError && !*outError)
            *outError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnknownError userInfo:url ? @{NSURLErrorKey : url} : nil];
        return nil;
    }
    NSURL *source = url;
    if (duplicateByCopying) {
        NSURL *tmp = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
        tmp = [tmp URLByAppendingPathExtension:[url pathExtension]];
        if (![[NSFileManager defaultManager] copyItemAtURL:url toURL:tmp error:outError])
            return nil;
        source = tmp;
    }
    NSDocument *doc = [[[cls alloc] initForURL:nil withContentsOfURL:source ofType:type error:outError] autorelease];
    if (duplicateByCopying)
        [[NSFileManager defaultManager] removeItemAtURL:source error:NULL];
    if (!doc)
        return nil;
    if (displayNameOrNil)
        [doc setDisplayName:displayNameOrNil];
    [self addDocument:doc];
    if ([self shouldCreateUI]) {
        [doc makeWindowControllers];
        [doc showWindows];
    }
    return doc;
}

@end
