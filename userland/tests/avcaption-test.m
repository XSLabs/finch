/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Compare caption text, time, style, ruby text, and region values. */
#import <AVFoundation/AVCaption.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static void
print_region(const char *label, AVCaptionRegion *region)
{
    printf("%s %s %.0f/%ld %.0f/%ld %.0f/%ld %.0f/%ld %ld %ld %ld\n", label,
        region.identifier.UTF8String ?: "-", region.origin.x.value, (long)region.origin.x.units,
        region.origin.y.value, (long)region.origin.y.units, region.size.width.value, (long)region.size.width.units,
        region.size.height.value, (long)region.size.height.units, (long)region.scroll,
        (long)region.displayAlignment, (long)region.writingMode);
}

int
main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        printf("%s\n", class_getImageName([AVCaption class]));
        AVMutableCaptionRegion *region = [[AVMutableCaptionRegion alloc] initWithIdentifier:@"main"];
        region.origin = AVCaptionPointMake(AVCaptionDimensionMake(10, AVCaptionUnitsTypePercent), AVCaptionDimensionMake(20, AVCaptionUnitsTypePercent));
        region.size = AVCaptionSizeMake(AVCaptionDimensionMake(80, AVCaptionUnitsTypePercent), AVCaptionDimensionMake(60, AVCaptionUnitsTypePercent));
        region.displayAlignment = AVCaptionRegionDisplayAlignmentCenter;
        region.writingMode = AVCaptionRegionWritingModeLeftToRightAndTopToBottom;
        printf("region %s %.0f/%ld %.0f/%ld %.0f/%.0f %ld %ld %ld\n", region.identifier.UTF8String,
            region.origin.x.value, (long)region.origin.x.units, region.origin.y.value, (long)region.origin.y.units,
            region.size.width.value, region.size.height.value, (long)region.scroll, (long)region.displayAlignment, (long)region.writingMode);
        AVCaptionRegion *top = AVCaptionRegion.appleITTTopRegion;
        AVCaptionRegion *bottom = AVCaptionRegion.appleITTBottomRegion;
        AVCaptionRegion *left = AVCaptionRegion.appleITTLeftRegion;
        AVCaptionRegion *right = AVCaptionRegion.appleITTRightRegion;
        AVCaptionRegion *subRip = AVCaptionRegion.subRipTextBottomRegion;
        print_region("top", top);
        print_region("bottom", bottom);
        print_region("left", left);
        print_region("right", right);
        print_region("subrip", subRip);

        AVMutableCaption *caption = [[AVMutableCaption alloc] initWithText:@"hello" timeRange:CMTimeRangeMake(CMTimeMake(2, 1), CMTimeMake(3, 1))];
        caption.region = region;
        caption.textAlignment = AVCaptionTextAlignmentCenter;
        caption.animation = AVCaptionAnimationCharacterReveal;
        [caption setFontWeight:AVCaptionFontWeightBold inRange:NSMakeRange(0, 2)];
        [caption setFontStyle:AVCaptionFontStyleItalic inRange:NSMakeRange(2, 3)];
        [caption setDecoration:AVCaptionDecorationUnderline inRange:NSMakeRange(0, 5)];
        [caption setTextCombine:AVCaptionTextCombineTwoDigits inRange:NSMakeRange(3, 2)];
        AVCaptionRuby *ruby = [[AVCaptionRuby alloc] initWithText:@"greeting" position:AVCaptionRubyPositionAfter alignment:AVCaptionRubyAlignmentCenter];
        [caption setRuby:ruby inRange:NSMakeRange(0, 2)];
        NSRange firstRange = NSMakeRange(0, 0), styleRange = NSMakeRange(0, 0), rubyRange = NSMakeRange(0, 0), combineRange = NSMakeRange(0, 0);
        printf("caption %s %.0f+%.0f %ld %ld region=%s\n", caption.text.UTF8String,
            CMTimeGetSeconds(caption.timeRange.start), CMTimeGetSeconds(caption.timeRange.duration),
            (long)caption.textAlignment, (long)caption.animation, caption.region.identifier.UTF8String);
        AVCaptionFontWeight weight = [caption fontWeightAtIndex:0 range:&firstRange];
        AVCaptionFontStyle style = [caption fontStyleAtIndex:2 range:&styleRange];
        AVCaptionDecoration decoration = [caption decorationAtIndex:0 range:NULL];
        AVCaptionRuby *readRuby = [caption rubyAtIndex:0 range:&rubyRange];
        AVCaptionTextCombine combine = [caption textCombineAtIndex:3 range:&combineRange];
        printf("styles %ld/%lu %ld/%lu %ld ruby=%s/%ld/%ld/%lu combine=%ld/%lu\n",
            (long)weight, (unsigned long)firstRange.length, (long)style, (unsigned long)styleRange.length,
            (long)decoration, readRuby.text.UTF8String, (long)readRuby.position, (long)readRuby.alignment,
            (unsigned long)rubyRange.length, (long)combine, (unsigned long)combineRange.length);
        AVCaption *immutable = [caption copy];
        AVMutableCaption *mutableCopy = [caption mutableCopy];
        mutableCopy.text = @"new";
        printf("copies %d %d %s %ld\n", immutable == caption, mutableCopy != caption,
            mutableCopy.text.UTF8String, (long)[mutableCopy fontWeightAtIndex:0 range:NULL]);
        CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGFloat components[] = { 1, 0, 0, 1 };
        CGColorRef color = CGColorCreate(colorSpace, components);
        [caption setTextColor:color inRange:NSMakeRange(0, 2)];
        CGColorRef readColor = [caption textColorAtIndex:0 range:&firstRange];
        printf("color %d/%lu\n", readColor && CGColorEqualToColor(color, readColor), (unsigned long)firstRange.length);
        if (readColor) CGColorRelease(readColor);
        CGColorRelease(color);
        CGColorSpaceRelease(colorSpace);
    }
    return 0;
}
