/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * AppKit's smaller classes apps link: toolbar items (menu, separator, tracking
 * separator), titlebar and split-view accessory controllers, table row actions, text
 * attachment cells and view providers, activity-item previews, the scrubber, the speech
 * synthesizer, and the constants they come with; compared with Apple's.
 */
#import <AppKit/AppKit.h>

/* (private names apps import, declared as they link them) */
extern NSString *const NSAppearanceNameTouchBar;
extern NSString *const NSFlowLayoutRowVerticalAlignmentKey;

static const char *
rect(NSRect r)
{
    return NSStringFromRect(r).UTF8String;
}

int
main(void)
{
    @autoreleasepool {
        [NSApplication sharedApplication];

        /* toolbar items */
        NSMenuToolbarItem *m = [[NSMenuToolbarItem alloc] initWithItemIdentifier:@"menu"];
        printf("menu item: %s indicator %d menu %s label '%s' is toolbar item %d\n", m.itemIdentifier.UTF8String, m.showsIndicator,
            m.menu ? "set" : "nil", m.label.UTF8String, [m isKindOfClass:[NSToolbarItem class]]);
        NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Choices"];
        [menu addItemWithTitle:@"One" action:nil keyEquivalent:@""];
        m.menu = menu;
        m.showsIndicator = NO;
        printf("  set: menu %s items %ld indicator %d\n", m.menu.title.UTF8String, (long)m.menu.numberOfItems, m.showsIndicator);
        NSSplitView *split = [[NSSplitView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
        NSTrackingSeparatorToolbarItem *t = [NSTrackingSeparatorToolbarItem trackingSeparatorToolbarItemWithIdentifier:@"track" splitView:split
                                                                                                         dividerIndex:1];
        printf("tracking separator: %s split %d divider %ld\n", t.itemIdentifier.UTF8String, t.splitView == split, (long)t.dividerIndex);
        t.dividerIndex = 0;
        printf("  divider now %ld\n", (long)t.dividerIndex);
        NSToolbarItem *sep = [[NSClassFromString(@"NSSeparatorToolbarItem") alloc] initWithItemIdentifier:@"NSToolbarSeparatorItem"];
        printf("separator item: %s %s\n", NSStringFromClass([sep class]).UTF8String, sep.itemIdentifier.UTF8String);

        /* accessory view controllers */
        NSTitlebarAccessoryViewController *a = [NSTitlebarAccessoryViewController new];
        printf("titlebar accessory: layout %ld full-screen min %g hidden %d adjusts %d\n", (long)a.layoutAttribute, a.fullScreenMinHeight,
            a.hidden, a.automaticallyAdjustsSize);
        a.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 200, 30)];
        a.layoutAttribute = NSLayoutAttributeRight;
        a.hidden = YES;
        printf("  set: layout %ld hidden %d view %s\n", (long)a.layoutAttribute, a.hidden, rect(a.view.frame));
        NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 300)
                                                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered
                                                      defer:YES];
        [w addTitlebarAccessoryViewController:a];
        printf("  window accessories %lu same %d\n", (unsigned long)w.titlebarAccessoryViewControllers.count,
            w.titlebarAccessoryViewControllers.firstObject == a);
        [w removeTitlebarAccessoryViewControllerAtIndex:0];
        printf("  after removal %lu\n", (unsigned long)w.titlebarAccessoryViewControllers.count);
        NSTitlebarAccessoryViewController *b = [NSTitlebarAccessoryViewController new];
        b.view = [NSView new];
        [w insertTitlebarAccessoryViewController:b atIndex:0];
        [w addTitlebarAccessoryViewController:a];
        printf("  inserted then added: %lu first is b %d\n", (unsigned long)w.titlebarAccessoryViewControllers.count,
            w.titlebarAccessoryViewControllers.firstObject == b);
        [a removeFromParentViewController];
        printf("  removeFromParentViewController: %lu\n", (unsigned long)w.titlebarAccessoryViewControllers.count);
        NSSplitViewItemAccessoryViewController *s = [NSSplitViewItemAccessoryViewController new];
        printf("split accessory: hidden %d insets %d\n", s.hidden, s.automaticallyAppliesContentInsets);

        /* row actions */
        __block NSInteger fired = -1;
        NSTableViewRowAction *r = [NSTableViewRowAction rowActionWithStyle:NSTableViewRowActionStyleDestructive title:@"Delete"
                                                                   handler:^(NSTableViewRowAction *action, NSInteger row) {
                                                                     fired = row;
                                                                   }];
        NSColor *bg = [r.backgroundColor colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
        printf("row action: style %ld title %s image %s background %.3f %.3f %.3f\n", (long)r.style, r.title.UTF8String,
            r.image ? "set" : "nil", bg.redComponent, bg.greenComponent, bg.blueComponent);
        NSTableViewRowAction *plain = [NSTableViewRowAction rowActionWithStyle:NSTableViewRowActionStyleRegular title:@"Flag"
                                                                       handler:^(NSTableViewRowAction *action, NSInteger row) {
                                                                       }];
        bg = [plain.backgroundColor colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
        printf("  regular background %.3f %.3f %.3f\n", bg.redComponent, bg.greenComponent, bg.blueComponent);
        plain.backgroundColor = nil;
        bg = [plain.backgroundColor colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
        printf("  reset background %.3f %.3f %.3f\n", bg.redComponent, bg.greenComponent, bg.blueComponent);
        NSTableViewRowAction *copy = [r copy];
        printf("  copy: %s style %ld distinct %d\n", copy.title.UTF8String, (long)copy.style, copy != r);

        /* text attachment cells */
        NSTextAttachmentCell *cell = [NSTextAttachmentCell new];
        printf("attachment cell: size %s baseline %s attachment %s tracks %d type %ld\n", NSStringFromSize(cell.cellSize).UTF8String,
            NSStringFromPoint(cell.cellBaselineOffset).UTF8String, cell.attachment ? "set" : "nil", cell.wantsToTrackMouse, (long)cell.type);
        NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(20, 10)];
        NSTextAttachmentCell *icell = [[NSTextAttachmentCell alloc] initImageCell:img];
        printf("  image cell: size %s baseline %s\n", NSStringFromSize(icell.cellSize).UTF8String, NSStringFromPoint(icell.cellBaselineOffset).UTF8String);
        NSTextAttachment *att = [[NSTextAttachment alloc] initWithData:nil ofType:nil];
        att.attachmentCell = icell;
        printf("  attached: cell's attachment is it %d\n", icell.attachment == att);
        Class token = NSClassFromString(@"NSTokenAttachmentCell");
        printf("token attachment cell: %s subclass %d\n", token ? "present" : "missing", [token isSubclassOfClass:[NSTextAttachmentCell class]]);

        /* view providers */
        NSTextAttachment *va = [NSTextAttachment new];
        NSView *parent = [NSView new];
        NSTextAttachmentViewProvider *vp = [[NSTextAttachmentViewProvider alloc] initWithTextAttachment:va parentView:parent textLayoutManager:nil
                                                                                               location:(id)@0];
        printf("view provider: attachment %d view %s tracks %d\n", vp.textAttachment == va, vp.view ? "set" : "nil",
            vp.tracksTextAttachmentViewBounds);
        [vp loadView];
        printf("  after loadView: view %s\n", vp.view ? "set" : "nil");

        /* activity items */
        NSPreviewRepresentingActivityItem *p = [[NSPreviewRepresentingActivityItem alloc] initWithItem:@"thing" title:@"Title" image:img icon:nil];
        printf("preview item: %s %s image %s icon %s\n", [p.item description].UTF8String, p.title.UTF8String, p.imageProvider ? "provider" : "nil",
            p.iconProvider ? "provider" : "nil");

        /* the scrubber (the Touch Bar's) */
        NSScrubber *sc = [[NSScrubber alloc] initWithFrame:NSMakeRect(0, 0, 300, 30)];
        printf("scrubber: items %ld selected %ld highlighted %ld mode %ld continuous %d floats %d wraps %d layout %s\n", (long)sc.numberOfItems,
            (long)sc.selectedIndex, (long)sc.highlightedIndex, (long)sc.mode, sc.continuous, sc.floatsSelectionViews, (int)sc.itemAlignment,
            NSStringFromClass([sc.scrubberLayout class]).UTF8String);

        /* speech */
        NSSpeechSynthesizer *speech = [NSSpeechSynthesizer new];
        printf("speech: speaking %d any %d volume %.2f rate>0 %d\n", speech.isSpeaking, [NSSpeechSynthesizer isAnyApplicationSpeaking],
            speech.volume, speech.rate > 0);

        /* glass */
        NSGlassEffectView *g = [[NSGlassEffectView alloc] initWithFrame:NSMakeRect(0, 0, 100, 50)];
        printf("glass: radius %g tint %s style %ld content %s subviews %lu\n", g.cornerRadius, g.tintColor ? "set" : "nil", (long)g.style,
            g.contentView ? "set" : "nil", (unsigned long)g.subviews.count);
        NSView *gc = [NSView new];
        g.contentView = gc;
        printf("  content: directly inside %d, inside it %d, subviews %lu\n", gc.superview == g, [gc isDescendantOf:g],
            (unsigned long)g.subviews.count);
        g.cornerRadius = 12;
        g.style = NSGlassEffectViewStyleClear;
        printf("  set: %g %ld\n", g.cornerRadius, (long)g.style);
        Class gv = NSClassFromString(@"NSGlassView");
        printf("private glass view: %s subclass %d\n", gv ? "present" : "missing", [gv isSubclassOfClass:[NSGlassEffectView class]]);
        NSGlassEffectContainerView *gcv = [[NSGlassEffectContainerView alloc] initWithFrame:NSMakeRect(0, 0, 100, 50)];
        printf("glass container: spacing %g content %s\n", gcv.spacing, gcv.contentView ? "set" : "nil");

        /* constants */
        printf("constants: %s | %s | insets %g %g %g %g\n", NSAppearanceNameTouchBar.UTF8String, NSFlowLayoutRowVerticalAlignmentKey.UTF8String,
            NSDirectionalEdgeInsetsZero.top, NSDirectionalEdgeInsetsZero.leading, NSDirectionalEdgeInsetsZero.bottom,
            NSDirectionalEdgeInsetsZero.trailing);
        (void)fired;
    }
    return 0;
}
