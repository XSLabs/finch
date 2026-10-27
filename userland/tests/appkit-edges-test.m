/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-appkit-edges-test: AppKit details checked against Apple's on the host:
 * pop-up button cells' state and values, tab views' type, position and border,
 * button cells' object values, cell comparison and old number formats, and the
 * TIFF compression names. (Font metrics are left out: Finch's fonts aren't Apple's.)
 */
#import <AppKit/AppKit.h>
#include <stdio.h>

#define T(...)                                                                                                 \
    @try {                                                                                                     \
        id r = (__VA_ARGS__);                                                                                  \
        printf("%s => %s\n", #__VA_ARGS__, [[[r description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "] UTF8String]); \
    } @catch (NSException * e) {                                                                               \
        printf("%s: %s: %s\n", #__VA_ARGS__, e.name.UTF8String, e.reason.UTF8String);                          \
    }

static void
show_popup(NSPopUpButton *b)
{
    NSPopUpButtonCell *c = b.cell;
    printf("title '%s' obj %s str '%s' state %ld cellstate %ld align %ld sel %ld items %ld int %d\n", c.title.UTF8String,
        [[c.objectValue description] UTF8String], c.stringValue.UTF8String, (long)b.state, (long)c.state, (long)c.alignment,
        (long)b.indexOfSelectedItem, (long)b.numberOfItems, c.intValue);
}

int
main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        [NSApplication sharedApplication];

        NSPopUpButton *b = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 100, 20) pullsDown:NO];
        show_popup(b);
        [b addItemWithTitle:@"One"];
        show_popup(b);
        [b addItemWithTitle:@"Two"];
        show_popup(b);
        [b selectItemAtIndex:1];
        show_popup(b);
        NSPopUpButton *p = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 100, 20) pullsDown:YES];
        [p addItemsWithTitles:@[ @"A", @"B" ]];
        show_popup(p);
        [b removeAllItems];
        show_popup(b);
        NSPopUpButton *q = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 100, 20) pullsDown:NO];
        [q addItemsWithTitles:@[ @"A", @"B", @"C" ]];
        [q selectItemAtIndex:2];
        NSPopUpButtonCell *qc = q.cell;
        printf("int %d integer %ld double %g str %s obj %s state %ld\n", qc.intValue, (long)qc.integerValue, qc.doubleValue,
            qc.stringValue.UTF8String, [[qc.objectValue description] UTF8String], (long)qc.state);
        q.selectedItem.state = NSControlStateValueOff;
        printf("item off: state %ld int %d\n", (long)qc.state, qc.intValue);
        [qc setIntValue:0];
        printf("setIntValue 0: selected %ld\n", (long)q.indexOfSelectedItem);

        NSTabView *t = [NSTabView new];
        for (int ty = 0; ty < 7; ty++) {
            t.tabViewType = ty;
            printf("type %d position %ld border %ld\n", ty, (long)t.tabPosition, (long)t.tabViewBorderType);
        }
        t.tabPosition = NSTabPositionLeft;
        printf("position left: type %ld position %ld border %ld\n", (long)t.tabViewType, (long)t.tabPosition, (long)t.tabViewBorderType);
        t.tabViewBorderType = NSTabViewBorderTypeLine;
        printf("border line: type %ld position %ld border %ld\n", (long)t.tabViewType, (long)t.tabPosition, (long)t.tabViewBorderType);
        t.tabPosition = NSTabPositionNone;
        printf("position none: type %ld position %ld border %ld\n", (long)t.tabViewType, (long)t.tabPosition, (long)t.tabViewBorderType);

        NSButtonCell *bc = [NSButtonCell new];
        T(bc.objectValue);
        T(NSStringFromClass([bc.objectValue class]));
        T(@(bc.alignment));
        bc.state = NSControlStateValueOn;
        T(bc.objectValue);
        bc.allowsMixedState = YES;
        bc.state = NSControlStateValueMixed;
        T(bc.objectValue);
        T(bc.stringValue);

        NSCell *x = [[NSCell alloc] initTextCell:@"Finch"];
        T(@([x compare:@"x"]));
        T(@([x compare:[[NSCell alloc] initTextCell:@"Gin"]]));
        T(NSStringFromSize([x cellSizeForBounds:NSMakeRect(0, 0, 5, 7)]));
        T(([x takeStringValueFrom:nil], x.stringValue));
        NSTIFFCompression types[] = { 1, 2, 3, 4, 5, 6, 7, 8, 32773, 32766, 32771, 32809, 0 };
        for (int i = 0; i < 13; i++)
            printf("compression %lu: %s\n", (unsigned long)types[i],
                [[NSBitmapImageRep localizedNameForTIFFCompressionType:types[i]] ?: @"(null)" UTF8String]);
        NSCell *f = [[NSCell alloc] initTextCell:@""];
        [f setFloatingPointFormat:YES left:4 right:2];
        f.doubleValue = 42.5;
        T(f.stringValue);
        f.doubleValue = 12345.678;
        T(f.stringValue);
        [f setFloatingPointFormat:NO left:3 right:1];
        f.doubleValue = 7;
        T(f.stringValue);
    }
    return 0;
}
