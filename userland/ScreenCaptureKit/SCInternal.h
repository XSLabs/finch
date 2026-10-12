/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* ScreenCaptureKit's insides, shared between its files. */
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreVideo/CoreVideo.h>
#include "../WindowServer/FinchWSProtocol.h"

/* (CoreGraphics: the window server's capture request) */
CGImageRef FWSCaptureImage(FWSRect rect, uint32_t options, const uint32_t *windows, uint32_t count);

NSError *SCFinchError(SCStreamErrorCode code, NSString *what);
dispatch_queue_t SCFinchQueue(void);

@interface SCContentFilter (Finch)
/* What's captured, in global points. */
- (CGRect)_finchScreenRect;
/* The window server's capture of the content over rect (global points; CGRectNull: all of
   it), in pixels at the display's scale. */
- (CGImageRef)_finchCopyImageOfRect:(CGRect)rect cursor:(BOOL)cursor shadows:(BOOL)shadows;
@end

/* The image drawn into a new pixel buffer of the format, size and placement asked for
   (sourceRect in the image's points, destinationRect in the buffer's pixels; null or empty:
   all of it); NULL if the format isn't one Finch makes. */
CVPixelBufferRef SCFinchPixelBuffer(CGImageRef image, CGFloat scale, OSType format, size_t width, size_t height,
                                    CGRect sourceRect, CGRect destinationRect, BOOL scalesToFit, BOOL preservesAspectRatio,
                                    CGColorRef background, CGRect *contentRectOut);
