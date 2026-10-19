/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Time changes and drawing for plain, static AVCaption text. */
#import <AVFoundation/AVCaptionRenderer.h>
#import <AVFoundation/AVCaption.h>
#import <CoreText/CoreText.h>
#import <math.h>

@interface AVCaption (FinchCaptionRendering)
- (CGColorRef)textColorAtIndex:(NSInteger)index range:(NSRange *)range;
- (CGColorRef)backgroundColorAtIndex:(NSInteger)index range:(NSRange *)range;
@end

@interface AVCaptionRendererScene ()
- (instancetype)initWithTimeRange:(CMTimeRange)range hasActiveCaptions:(BOOL)active needsPeriodicRefresh:(BOOL)refresh;
@end

static NSValue *
AVFTimeValue(CMTime time)
{
    return [NSValue valueWithBytes:&time objCType:@encode(CMTime)];
}

static CMTime
AVFTimeFromValue(NSValue *value)
{
    CMTime time;
    [value getValue:&time];
    return time;
}

@implementation AVCaptionRendererScene {
    CMTimeRange _finchTimeRange;
    BOOL _finchHasActiveCaptions;
    BOOL _finchNeedsPeriodicRefresh;
}

- (instancetype)initWithTimeRange:(CMTimeRange)range hasActiveCaptions:(BOOL)active needsPeriodicRefresh:(BOOL)refresh
{
    if ((self = [super init])) {
        _finchTimeRange = range;
        _finchHasActiveCaptions = active;
        _finchNeedsPeriodicRefresh = refresh;
    }
    return self;
}

- (CMTimeRange)timeRange { return _finchTimeRange; }
- (BOOL)hasActiveCaptions { return _finchHasActiveCaptions; }
- (BOOL)needsPeriodicRefresh { return _finchNeedsPeriodicRefresh; }
- (id)copyWithZone:(NSZone *)zone { return self; }

@end

@implementation AVCaptionRenderer {
    NSArray<AVCaption *> *_finchCaptions;
    CGRect _finchBounds;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _finchCaptions = @[];
        _finchBounds = CGRectZero;
    }
    return self;
}

- (NSArray<AVCaption *> *)captions { return _finchCaptions; }
- (void)setCaptions:(NSArray<AVCaption *> *)captions { _finchCaptions = [captions copy] ?: @[]; }
- (CGRect)bounds { return _finchBounds; }
- (void)setBounds:(CGRect)bounds { _finchBounds = bounds; }

- (NSArray<AVCaptionRendererScene *> *)captionSceneChangesInRange:(CMTimeRange)consideredTimeRange
{
    if (!CMTIMERANGE_IS_VALID(consideredTimeRange) || !CMTIME_IS_NUMERIC(consideredTimeRange.start) ||
        !(CMTIME_IS_NUMERIC(consideredTimeRange.duration) || CMTIME_IS_POSITIVE_INFINITY(consideredTimeRange.duration)) ||
        CMTimeCompare(consideredTimeRange.duration, kCMTimeZero) <= 0)
        return @[];

    CMTime end = CMTimeRangeGetEnd(consideredTimeRange);
    CMTime sceneStart = kCMTimeInvalid, sceneEnd = kCMTimeInvalid;
    NSMutableArray<NSValue *> *boundaries = [NSMutableArray array];
    for (AVCaption *caption in _finchCaptions) {
        CMTime start = CMTimeCompare(caption.timeRange.start, consideredTimeRange.start) < 0 ? consideredTimeRange.start : caption.timeRange.start;
        CMTime captionEnd = CMTimeRangeGetEnd(caption.timeRange);
        CMTime stop = CMTIME_IS_NUMERIC(end) && CMTimeCompare(captionEnd, end) > 0 ? end : captionEnd;
        if (CMTimeCompare(start, stop) < 0) {
            if (!CMTIME_IS_NUMERIC(sceneStart) || CMTimeCompare(start, sceneStart) < 0)
                sceneStart = start;
            if (!CMTIME_IS_NUMERIC(sceneEnd) || CMTimeCompare(stop, sceneEnd) > 0)
                sceneEnd = stop;
            [boundaries addObject:AVFTimeValue(start)];
            if (CMTIME_IS_NUMERIC(stop))
                [boundaries addObject:AVFTimeValue(stop)];
        }
    }
    if (!CMTIME_IS_NUMERIC(sceneStart) || !CMTIME_IS_NUMERIC(sceneEnd))
        return @[];
    [boundaries addObject:AVFTimeValue(sceneStart)];
    [boundaries addObject:AVFTimeValue(sceneEnd)];
    [boundaries sortUsingComparator:^NSComparisonResult(NSValue *a, NSValue *b) {
        int result = CMTimeCompare(AVFTimeFromValue(a), AVFTimeFromValue(b));
        return result < 0 ? NSOrderedAscending : result > 0 ? NSOrderedDescending : NSOrderedSame;
    }];
    NSMutableArray<NSValue *> *unique = [NSMutableArray array];
    for (NSValue *value in boundaries)
        if (!unique.count || CMTimeCompare(AVFTimeFromValue(unique.lastObject), AVFTimeFromValue(value)) != 0)
            [unique addObject:value];

    NSMutableArray<AVCaptionRendererScene *> *scenes = [NSMutableArray array];
    for (NSUInteger i = 0; i + 1 < unique.count; i++) {
        CMTime start = AVFTimeFromValue(unique[i]), stop = AVFTimeFromValue(unique[i + 1]);
        if (CMTimeCompare(start, stop) >= 0)
            continue;
        CMTime midpoint = CMTimeAdd(start, CMTimeMultiplyByFloat64(CMTimeSubtract(stop, start), 0.5));
        BOOL active = NO;
        for (AVCaption *caption in _finchCaptions)
            if (CMTimeRangeContainsTime(caption.timeRange, midpoint)) {
                active = YES;
                break;
            }
        if (CMTimeCompare(start, sceneStart) < 0 || CMTimeCompare(stop, sceneEnd) > 0)
            continue;
        BOOL refresh = NO;
        if (active)
            for (AVCaption *caption in _finchCaptions)
                if (CMTimeRangeContainsTime(caption.timeRange, midpoint) &&
                    (caption.animation != AVCaptionAnimationNone || caption.region.scroll != AVCaptionRegionScrollNone)) {
                    refresh = YES;
                    break;
                }
        [scenes addObject:[[AVCaptionRendererScene alloc] initWithTimeRange:CMTimeRangeFromTimeToTime(start, stop)
                                                          hasActiveCaptions:active needsPeriodicRefresh:refresh]];
    }
    return scenes;
}

- (void)renderInContext:(CGContextRef)context forTime:(CMTime)time
{
    if (!context || !CMTIME_IS_NUMERIC(time) || CGRectIsEmpty(_finchBounds))
        return;
    CGFloat fontSize = MAX(12.0, MIN(42.0, _finchBounds.size.height * 0.065));
    CGFloat baseline = CGRectGetMinY(_finchBounds) + fontSize;
    CGContextSaveGState(context);
    CGContextClipToRect(context, _finchBounds);
    for (AVCaption *caption in _finchCaptions) {
        if (!CMTimeRangeContainsTime(caption.timeRange, time) || !caption.text.length)
            continue;
        CTFontRef font = CTFontCreateWithName(CFSTR("Helvetica"), fontSize, NULL);
        NSMutableDictionary *attributes = [NSMutableDictionary dictionaryWithObjectsAndKeys:
            (__bridge id)font, (id)kCTFontAttributeName,
            (__bridge id)CGColorGetConstantColor(kCGColorWhite), (id)kCTForegroundColorAttributeName, nil];
        CGColorRef color = [caption textColorAtIndex:0 range:NULL];
        if (color) {
            attributes[(id)kCTForegroundColorAttributeName] = (__bridge id)color;
            CGColorRelease(color);
        }
        NSAttributedString *text = [[NSAttributedString alloc] initWithString:caption.text attributes:attributes];
        CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)text);
        double width = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
        CGFloat x = CGRectGetMinX(_finchBounds) + 8.0;
        if (caption.textAlignment == AVCaptionTextAlignmentCenter)
            x = CGRectGetMidX(_finchBounds) - width / 2.0;
        else if (caption.textAlignment == AVCaptionTextAlignmentRight)
            x = CGRectGetMaxX(_finchBounds) - width - 8.0;
        CGColorRef background = [caption backgroundColorAtIndex:0 range:NULL];
        if (background) {
            CGContextSetFillColorWithColor(context, background);
            CGContextFillRect(context, CGRectMake(x - 4.0, baseline - 3.0, width + 8.0, fontSize + 6.0));
            CGColorRelease(background);
        }
        CGContextSetTextPosition(context, x, baseline);
        CTLineDraw(line, context);
        CFRelease(line);
        CFRelease(font);
        baseline += fontSize * 1.25;
    }
    CGContextRestoreGState(context);
}

@end
