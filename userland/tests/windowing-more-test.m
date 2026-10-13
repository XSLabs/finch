/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Window, view and controller API beyond the basics: view-controller presentation
 * through an animator (presenting and presented controllers, dismissal), transitions
 * between child controllers, view safe areas and layout regions, window content
 * borders, title bars and close boxes, PDF of a window's contents, cursor rects,
 * the newer cursors, toolbar item removal, mnemonics, table grid and selection
 * enumerators, cell entry types, Core Data settings kept by object controllers,
 * application helpers and event touches. Compared with Apple's.
 */
#import <AppKit/AppKit.h>

@interface FocusTarget : NSView
@property BOOL refuseResign;
@end
@implementation FocusTarget
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)resignFirstResponder { return !self.refuseResign; }
@end

@interface FocusObserver : NSObject
@property NSUInteger changes;
@property (weak) NSResponder *lastResponder;
@end
@implementation FocusObserver
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    self.changes++;
    self.lastResponder = [object firstResponder];
}
@end

@interface LogAnimator : NSObject <NSViewControllerPresentationAnimator>
@property NSMutableArray *log;
@end
@implementation LogAnimator
- (void)animatePresentationOfViewController:(NSViewController *)vc fromViewController:(NSViewController *)from
{
    [self.log addObject:[NSString stringWithFormat:@"present %@ from %@", vc.title, from.title]];
}
- (void)animateDismissalOfViewController:(NSViewController *)vc fromViewController:(NSViewController *)from
{
    [self.log addObject:[NSString stringWithFormat:@"dismiss %@ from %@", vc.title, from.title]];
}
@end

static NSViewController *
controller(NSString *title)
{
    NSViewController *vc = [[NSViewController alloc] init];
    vc.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 100, 80)];
    vc.title = title;
    return vc;
}

int
main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        [NSApplication sharedApplication];
        printf("Windowing more\n");

        /* presentation */
        NSViewController *a = controller(@"A"), *b = controller(@"B"), *c = controller(@"C");
        LogAnimator *anim = [LogAnimator new];
        anim.log = [NSMutableArray array];
        [a presentViewController:b animator:anim];
        printf("presented: b by %s, a presents %lu, log %s\n", b.presentingViewController.title.UTF8String,
            (unsigned long)a.presentedViewControllers.count, [anim.log componentsJoinedByString:@"; "].UTF8String);
        [b presentViewController:c animator:anim];
        printf("chain: c by %s, b presents %lu\n", c.presentingViewController.title.UTF8String, (unsigned long)b.presentedViewControllers.count);
        [b dismissViewController:c];
        [a dismissViewController:b];
        printf("dismissed: b presenter %s, a presents %lu, log %s\n", b.presentingViewController ? "set" : "nil",
            (unsigned long)a.presentedViewControllers.count, [anim.log componentsJoinedByString:@"; "].UTF8String);
        printf("controller defaults: origin %s, source %s, extension %s\n", NSStringFromPoint(a.preferredScreenOrigin).UTF8String,
            a.sourceItemView ? "set" : "nil", a.extensionContext ? "set" : "nil");

        /* transitions */
        NSViewController *parent = controller(@"P");
        NSViewController *x = controller(@"X"), *y = controller(@"Y");
        [parent addChildViewController:x];
        [parent addChildViewController:y];
        [parent.view addSubview:x.view];
        __block BOOL done = NO;
        [parent transitionFromViewController:x toViewController:y options:NSViewControllerTransitionNone completionHandler:^{ done = YES; }];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        printf("transition: done %d, x in %d, y in %d\n", done, x.view.superview == parent.view, y.view.superview == parent.view);

        /* views */
        NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 200, 100)];
        printf("safe area: %s insets %g %g, full screen %d\n", NSStringFromRect(v.safeAreaRect).UTF8String, v.safeAreaInsets.top,
            v.safeAreaInsets.left, v.isInFullScreenMode);
        printf("guides: %s %s, margins %g\n", v.safeAreaLayoutGuide ? "safe" : "-", v.layoutMarginsGuide ? "margins" : "-",
            v.additionalSafeAreaInsets.top);
        printf("smart magnification: %s\n", NSStringFromRect([v rectForSmartMagnificationAtPoint:NSMakePoint(10, 10) inRect:v.bounds]).UTF8String);
        printf("compact metrics: %d\n", v.prefersCompactControlSizeMetrics);

        /* windows */
        NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 300, 200)
                                                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                    backing:NSBackingStoreBuffered
                                                      defer:YES];
        NSWindow *plain = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 50, 50) styleMask:NSWindowStyleMaskBorderless
                                                        backing:NSBackingStoreBuffered
                                                          defer:YES];
        printf("title bar %d close box %d; borderless %d %d\n", w.hasTitleBar, w.hasCloseBox, plain.hasTitleBar, plain.hasCloseBox);
        printf("window style frame follows window: %d", NSEqualSizes(w.frame.size, w.contentView.superview.frame.size));
        w.styleMask |= NSWindowStyleMaskFullSizeContentView;
        printf(" -> %d", NSEqualSizes(w.frame.size, w.contentView.superview.frame.size));
        w.styleMask &= ~NSWindowStyleMaskFullSizeContentView;
        printf(" -> %d\n", NSEqualSizes(w.frame.size, w.contentView.superview.frame.size));
        FocusTarget *first = [FocusTarget new], *second = [FocusTarget new];
        [w.contentView addSubview:first];
        [w.contentView addSubview:second];
        FocusObserver *focus = [FocusObserver new];
        [w addObserver:focus forKeyPath:@"firstResponder" options:NSKeyValueObservingOptionNew context:NULL];
        [w makeFirstResponder:first];
        BOOL notifiedFirst = focus.changes > 0 && focus.lastResponder == first;
        focus.changes = 0;
        first.refuseResign = YES;
        BOOL refused = ![w makeFirstResponder:second] && focus.changes == 0 && w.firstResponder == first;
        first.refuseResign = NO;
        [w makeFirstResponder:second];
        BOOL notifiedSecond = focus.changes > 0 && focus.lastResponder == second;
        focus.changes = 0;
        [w makeFirstResponder:nil];
        BOOL notifiedWindow = focus.changes > 0 && focus.lastResponder == w;
        printf("focus observer: first %d refused %d second %d window %d\n", notifiedFirst, refused, notifiedSecond, notifiedWindow);
        [w removeObserver:focus forKeyPath:@"firstResponder"];
        first.nextKeyView = second;
        second.nextKeyView = first;
        [w makeFirstResponder:first];
        NSEvent *tab = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0
            timestamp:0 windowNumber:w.windowNumber context:nil characters:@"\t" charactersIgnoringModifiers:@"\t"
            isARepeat:NO keyCode:48];
        NSEvent *backtab = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagShift
            timestamp:0 windowNumber:w.windowNumber context:nil characters:@"\x19" charactersIgnoringModifiers:@"\x19"
            isARepeat:NO keyCode:48];
        [w sendEvent:tab];
        BOOL forward = w.firstResponder == second;
        [w sendEvent:backtab];
        printf("plain view tab: forward %d backward %d\n", forward, w.firstResponder == first);
        NSTextView *editor = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 80, 40)];
        [w.contentView addSubview:editor];
        editor.nextKeyView = first;
        [w makeFirstResponder:editor];
        [w sendEvent:tab];
        printf("text view tab: stayed %d inserted %d\n", w.firstResponder == editor, [editor.string isEqualToString:@"\t"]);
        [w makeFirstResponder:nil];
        [editor removeFromSuperview];
        [first removeFromSuperview];
        [second removeFromSuperview];
        printf("content border: %g auto %d\n", [w contentBorderThicknessForEdge:NSRectEdgeMinY],
            [w autorecalculatesContentBorderThicknessForEdge:NSRectEdgeMinY]);
        [w setContentBorderThickness:32 forEdge:NSRectEdgeMinY];
        [w setAutorecalculatesContentBorderThickness:NO forEdge:NSRectEdgeMinY];
        printf("content border set: %g auto %d\n", [w contentBorderThicknessForEdge:NSRectEdgeMinY],
            [w autorecalculatesContentBorderThicknessForEdge:NSRectEdgeMinY]);
        printf("cursor rects: %d", w.areCursorRectsEnabled);
        [w disableCursorRects];
        printf(" -> %d", w.areCursorRectsEnabled);
        [w enableCursorRects];
        printf(" -> %d\n", w.areCursorRectsEnabled);
        printf("scale %g, backing %ld preferred %ld, sRGB gamut %d\n", w.userSpaceScaleFactor, (long)w.backingLocation,
            (long)w.preferredBackingLocation, [w canRepresentDisplayGamut:NSDisplayGamutSRGB]);
        NSData *pdf = [w dataWithPDFInsideRect:NSMakeRect(0, 0, 100, 100)];
        printf("window pdf: %s\n", pdf.length > 4 && !memcmp(pdf.bytes, "%PDF", 4) ? "pdf" : "none");

        /* cursors, toolbars, mnemonics */
        printf("cursors: %d %d %d %d\n", NSCursor.zoomInCursor != nil, NSCursor.zoomOutCursor != nil, NSCursor.columnResizeCursor != nil,
            NSCursor.rowResizeCursor != nil);
        NSToolbar *tb = [[NSToolbar alloc] initWithIdentifier:@"t"];
        printf("toolbar accessory: %s %g %g\n", tb.fullScreenAccessoryView ? "set" : "nil", tb.fullScreenAccessoryViewMinHeight,
            tb.fullScreenAccessoryViewMaxHeight);
        NSButton *button = [NSButton buttonWithTitle:@"x" target:nil action:nil];
        [button setTitleWithMnemonic:@"&Save && Close"];
        NSTextField *field = [NSTextField labelWithString:@""];
        [field setTitleWithMnemonic:@"Na&me"];
        printf("mnemonics: [%s] [%s]\n", button.title.UTF8String, field.stringValue.UTF8String);

        /* tables and cells */
        NSTableView *table = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)];
        printf("table grid: %d", table.drawsGrid);
        [table setDrawsGrid:YES];
        printf(" -> %d mask %lu, enumerator %s\n", table.drawsGrid, (unsigned long)table.gridStyleMask,
            [table selectedRowEnumerator] ? "set" : "nil");
        NSCell *cell = [[NSCell alloc] initTextCell:@"x"];
        printf("cell: entry %ld tint %lu\n", (long)cell.entryType, (unsigned long)cell.controlTint);
        NSButtonCell *bc = [[NSButtonCell alloc] initTextCell:@"b"];
        printf("button cell gradient %lu\n", (unsigned long)bc.gradientType);

        /* object controller's Core Data settings */
        NSObjectController *oc = [[NSObjectController alloc] init];
        printf("object controller: entity %s, lazy %d, context %s\n", oc.entityName.UTF8String ?: "nil", oc.usesLazyFetching,
            oc.managedObjectContext ? "set" : "nil");
        oc.entityName = @"Thing";
        oc.usesLazyFetching = YES;
        oc.fetchPredicate = [NSPredicate predicateWithValue:YES];
        printf("  set: %s %d %s\n", oc.entityName.UTF8String, oc.usesLazyFetching, oc.fetchPredicate.predicateFormat.UTF8String);

        /* application */
        NSRange found = NSMakeRange(NSNotFound, 0);
        BOOL hit = [NSApp searchString:@"pre" inUserInterfaceItemString:@"Preferences…" searchRange:NSMakeRange(0, 12) foundRange:&found];
        printf("search: %d %s; ordered documents %lu\n", hit, NSStringFromRange(found).UTF8String, (unsigned long)NSApp.orderedDocuments.count);

        /* events */
        NSEvent *e = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0
                                         context:nil eventNumber:0 clickCount:1 pressure:1];
        @try {
            printf("touches: %lu\n", (unsigned long)[e touchesMatchingPhase:NSTouchPhaseAny inView:nil].count);
        } @catch (NSException *ex) {
            printf("touches: raises %s\n", ex.name.UTF8String);
        }
    }
    return 0;
}
