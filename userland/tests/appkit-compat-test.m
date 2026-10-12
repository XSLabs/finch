/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Small behaviours apps depend on, found running them: the standard colours are one
 * object each (apps keep them unretained), CFGetTypeID of any object, which views update
 * their layers instead of drawing, text fields' intrinsic widths (editable or not,
 * scrolling or wrapping), borders and bezels clearing each other, and a label's size
 * following its value under Auto Layout. Compared with Apple's.
 */
#import <AppKit/AppKit.h>
#import <objc/message.h>

@interface Updates : NSView
@end
@implementation Updates
- (void)updateLayer
{
}
@end

@interface Draws : NSView
@end
@implementation Draws
- (void)drawRect:(NSRect)r
{
}
@end

@interface DrawsToo : Draws
@end
@implementation DrawsToo
@end

int
main(void)
{
    @autoreleasepool {
        printf("standard colours, one object each:");
        for (NSString *n in @[ @"blackColor", @"whiteColor", @"clearColor", @"grayColor", @"redColor", @"blueColor", @"brownColor" ]) {
            SEL s = NSSelectorFromString(n);
            id (*send)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
            printf(" %d", send([NSColor class], s) == send([NSColor class], s));
        }
        printf("\n");

        id image = [NSImage new], object = [NSObject new];
        printf("CFGetTypeID: image %lu, object %lu, string is string %d\n", CFGetTypeID((__bridge CFTypeRef)image),
            CFGetTypeID((__bridge CFTypeRef)object), CFGetTypeID((__bridge CFTypeRef)@"x") == CFStringGetTypeID());

        printf("wantsUpdateLayer: NSView %d, updates %d, draws %d, inherits drawing %d\n", [NSView new].wantsUpdateLayer,
            [Updates new].wantsUpdateLayer, [Draws new].wantsUpdateLayer, [DrawsToo new].wantsUpdateLayer);

        printf("text field widths (editable, scrollable, selectable, wraps):\n ");
        for (int ed = 0; ed < 2; ed++)
            for (int sc = 0; sc < 2; sc++)
                for (int sel = 0; sel < 2; sel++)
                    for (int wr = 0; wr < 2; wr++) {
                        NSTextField *f = [NSTextField labelWithString:@"Hello 233"];
                        f.editable = ed;
                        f.cell.scrollable = sc;
                        f.selectable = sel;
                        f.cell.wraps = wr;
                        printf(" %d%d%d%d:%s", ed, sc, sel, wr, f.intrinsicContentSize.width < 0 ? "none" : "own");
                    }
        printf("\n");
        NSTextField *t = [NSTextField textFieldWithString:@"Hello"];
        printf("text field: width %s, scrollable %d", t.intrinsicContentSize.width < 0 ? "none" : "own", t.cell.scrollable);
        t.editable = NO;
        printf(", not editable: width %s\n", t.intrinsicContentSize.width < 0 ? "none" : "own");

        for (Class k in @[ [NSCell class], [NSTextFieldCell class], [NSButtonCell class] ]) {
            NSCell *c = [[k alloc] initTextCell:@"x"];
            c.bezeled = YES;
            c.bordered = NO;
            printf("%s: bezeled after bordered NO %d", NSStringFromClass(k).UTF8String, c.bezeled);
            c.bordered = YES;
            c.bezeled = NO;
            printf(", bordered after bezeled NO %d\n", c.bordered);
        }
        NSTextField *b = [NSTextField textFieldWithString:@"x"];
        b.bordered = NO;
        printf("text field bordered NO: bezeled %d\n", b.bezeled);

        NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 100)];
        NSTextField *l = [NSTextField labelWithString:@""];
        l.translatesAutoresizingMaskIntoConstraints = NO;
        [root addSubview:l];
        [l.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:10].active = YES;
        [l.topAnchor constraintEqualToAnchor:root.topAnchor constant:10].active = YES;
        [root layoutSubtreeIfNeeded];
        CGFloat empty = l.frame.size.width;
        l.stringValue = @"Red value:";
        [root layoutSubtreeIfNeeded];
        CGFloat set = l.frame.size.width;
        l.objectValue = @12345678;
        [root layoutSubtreeIfNeeded];
        printf("label under Auto Layout: grows with its string %d, with a number %d\n", set > empty + 20,
            l.frame.size.width > set);
    }
    return 0;
}
