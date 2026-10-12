/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Quick Look: thumbnails (QLThumbnailImageCreate) of an image, a PDF and a text file
 * within the size asked for, QLThumbnailGenerator's best representation (a thumbnail for
 * an image, an icon for a folder) and the shared preview panel. Thumbnails are each
 * system's own drawing, so only sizes and kinds are compared. Compared with Apple's.
 */
#import <AppKit/AppKit.h>
#import <QuickLook/QuickLook.h>
#import <QuickLookThumbnailing/QuickLookThumbnailing.h>
#import <Quartz/Quartz.h>

static NSURL *
make_files(void)
{
    NSURL *dir = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"finch-quicklook-test"] isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:400 pixelsHigh:200 bitsPerSample:8
                                                               samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                                                                colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:32];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToURL:[dir URLByAppendingPathComponent:@"wide.png"] atomically:YES];
    [@"Hello from a text file.\nSecond line.\n" writeToURL:[dir URLByAppendingPathComponent:@"note.txt"] atomically:YES
                                                   encoding:NSUTF8StringEncoding error:NULL];
    NSMutableData *pdf = [NSMutableData data];
    CGDataConsumerRef consumer = CGDataConsumerCreateWithCFData((__bridge CFMutableDataRef)pdf);
    CGRect box = CGRectMake(0, 0, 612, 792);
    CGContextRef c = CGPDFContextCreate(consumer, &box, NULL);
    CGPDFContextBeginPage(c, NULL);
    CGContextFillRect(c, CGRectMake(100, 100, 200, 200));
    CGPDFContextEndPage(c);
    CGPDFContextClose(c);
    CGContextRelease(c);
    CGDataConsumerRelease(consumer);
    [pdf writeToURL:[dir URLByAppendingPathComponent:@"page.pdf"] atomically:YES];
    return dir;
}

int
main(void)
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSURL *dir = make_files();
        for (NSString *name in @[ @"wide.png", @"page.pdf", @"note.txt" ]) {
            CGImageRef im = QLThumbnailImageCreate(NULL, (__bridge CFURLRef)[dir URLByAppendingPathComponent:name], CGSizeMake(128, 128), NULL);
            printf("%-9s thumbnail %d, within 128: %d, wider than tall: %d\n", name.UTF8String, im != NULL,
                   im && CGImageGetWidth(im) <= 128 && CGImageGetHeight(im) <= 128, im && CGImageGetWidth(im) > CGImageGetHeight(im));
            CGImageRelease(im);
        }
        for (NSURL *u in @[ [dir URLByAppendingPathComponent:@"wide.png"], dir ]) {
            QLThumbnailGenerationRequest *r = [[QLThumbnailGenerationRequest alloc] initWithFileAtURL:u size:CGSizeMake(64, 64) scale:2
                                                                                  representationTypes:QLThumbnailGenerationRequestRepresentationTypeAll];
            dispatch_semaphore_t done = dispatch_semaphore_create(0);
            __block long type = -1;
            __block BOOL image = NO;
            [[QLThumbnailGenerator sharedGenerator] generateBestRepresentationForRequest:r
                                                                      completionHandler:^(QLThumbnailRepresentation *rep, NSError *e) {
                                                                          type = rep ? (long)rep.type : -1;
                                                                          image = rep.CGImage != NULL;
                                                                          dispatch_semaphore_signal(done);
                                                                      }];
            dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC));
            printf("%-9s best representation: %s, image %d\n", u.hasDirectoryPath ? "folder" : u.lastPathComponent.UTF8String,
                   type == QLThumbnailRepresentationTypeThumbnail ? "thumbnail" : type == QLThumbnailRepresentationTypeIcon ? "icon" : "none", image);
        }
        printf("panel exists before: %d\n", [QLPreviewPanel sharedPreviewPanelExists]);
        QLPreviewPanel *p = [QLPreviewPanel sharedPreviewPanel];
        printf("panel: %d, is a panel %d, exists after %d, same again %d\n", p != nil, [p isKindOfClass:[NSPanel class]],
               [QLPreviewPanel sharedPreviewPanelExists], p == [QLPreviewPanel sharedPreviewPanel]);
        [[NSFileManager defaultManager] removeItemAtURL:dir error:NULL];
    }
    return 0;
}
