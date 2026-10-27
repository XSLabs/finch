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
        /* combo boxes, segmented controls, menus */
 T(@([NSComboBoxCell new].isEditable)); T(@([[NSComboBoxCell alloc] initTextCell:@"x"].isEditable)); T(@([[NSComboBox alloc] initWithFrame:NSMakeRect(0,0,100,20)].isEditable)); T(@([[[NSComboBox alloc] initWithFrame:NSMakeRect(0,0,100,20)].cell isEditable])); T(@([NSTextFieldCell new].isEditable)); T(@([[NSTextFieldCell alloc] initTextCell:@"x"].isEditable));
 NSSegmentedControl *s=[NSSegmentedControl segmentedControlWithLabels:@[@"A",@"B"] trackingMode:NSSegmentSwitchTrackingSelectOne target:nil action:nil];
 for (int i=-1;i<3;i++){ T(@([s imageScalingForSegment:i])); T(@([s tagForSegment:i])); T(@([s isSelectedForSegment:i])); T(@([s widthForSegment:i])); T([s labelForSegment:i]); T(@([s isEnabledForSegment:i])); }
 T(([s setSelected:YES forSegment:-1], @"ok")); T(([s setSelected:YES forSegment:5], @"ok")); T(([s setLabel:@"Z" forSegment:5], @"ok")); T(([s setTag:3 forSegment:7], @"ok")); T(([s setWidth:3 forSegment:7], @"ok"));
 NSSegmentedControl *e=[NSSegmentedControl new]; T(@(e.segmentCount)); T(@([e imageScalingForSegment:0]));
 T([NSString stringWithFormat:@"%p", [NSMenu menuZone]]==nil?@"nil":@"nonnull");
 NSMenu *m=[NSMenu new]; T(([m insertItem:[NSMenuItem new] atIndex:3], @"ok"));

        /* pasteboard types and pattern detection */
        {
 NSPasteboard *pb=[NSPasteboard pasteboardWithUniqueName];
 [pb clearContents]; [pb setString:@"x" forType:NSPasteboardTypeString]; printf("clear+setString: %s\n", [[pb.types componentsJoinedByString:@","] UTF8String]);
 [pb declareTypes:@[NSPasteboardTypeString] owner:nil]; [pb setString:@"x" forType:NSPasteboardTypeString]; printf("declare: %s\n", [[pb.types componentsJoinedByString:@","] UTF8String]);
 [pb clearContents]; [pb writeObjects:@[@"x"]]; printf("writeObjects: %s\n", [[pb.types componentsJoinedByString:@","] UTF8String]);
 [pb declareTypes:@[NSStringPboardType] owner:nil]; [pb setString:@"x" forType:NSStringPboardType]; printf("declare legacy: %s\n", [[pb.types componentsJoinedByString:@","] UTF8String]);
 [pb clearContents]; [pb setData:[NSData data] forType:NSPasteboardTypePNG]; printf("png: %s\n", [[pb.types componentsJoinedByString:@","] UTF8String]);
 [pb declareTypes:@[NSPasteboardTypePNG] owner:nil]; printf("declare png: %s\n", [[pb.types componentsJoinedByString:@","] UTF8String]);

        }
        {
 NSSet *all=[NSSet setWithObjects:NSPasteboardDetectionPatternProbableWebURL,NSPasteboardDetectionPatternProbableWebSearch,NSPasteboardDetectionPatternNumber,NSPasteboardDetectionPatternLink,NSPasteboardDetectionPatternPhoneNumber,NSPasteboardDetectionPatternEmailAddress,nil];
 for (NSString *str in @[@"https://example.com/a",@"hello world",@"42",@"1,234.5",@"mail me at a@b.com",@"call 555-123-4567",@"see http://x.org and http://y.org"]) {
  NSPasteboard *pb=[NSPasteboard pasteboardWithUniqueName]; [pb clearContents]; [pb setString:str forType:NSPasteboardTypeString];
  __block NSSet *got=nil; [pb detectPatternsForPatterns:all completionHandler:^(NSSet *s, NSError *e __attribute__((unused))){ got=s?:[NSSet set]; }];
  NSDate *u=[NSDate dateWithTimeIntervalSinceNow:5]; while(!got && [u timeIntervalSinceNow]>0) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
  NSMutableArray *names=[NSMutableArray array]; for (NSString *p in got) [names addObject:[p componentsSeparatedByString:@"."].lastObject]; [names sortUsingSelector:@selector(compare:)];
  printf("%s: %s\n", str.UTF8String, [names componentsJoinedByString:@","].UTF8String);
  [pb releaseGlobally]; }

        }
        {
            NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:2 pixelsHigh:2 bitsPerSample:8
                                                                     samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                                                                      colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
            NSPasteboard *pb = [NSPasteboard pasteboardWithUniqueName];
            [pb clearContents];
            [pb setData:[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] forType:NSPasteboardTypePNG];
            NSBitmapImageRep *back = [NSBitmapImageRep imageRepWithData:[pb dataForType:NSPasteboardTypeTIFF]];
            printf("tiff from png: %ldx%ld\n", (long)back.pixelsWide, (long)back.pixelsHigh);
            [pb releaseGlobally];
        }
    }
    return 0;
}
