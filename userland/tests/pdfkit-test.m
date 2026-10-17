/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Generate a small PDF in memory, then compare PDFKit's read and save behavior. */
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <PDFKit/PDFKit.h>
#include <stdio.h>
#include <string.h>

static NSData *MakePDF(void)
{
    CGRect pageBox = CGRectMake(0, 0, 300, 400);
    CFMutableDataRef data = CFDataCreateMutable(kCFAllocatorDefault, 0);
    if (!data) return nil;
    CGDataConsumerRef consumer = CGDataConsumerCreateWithCFData(data);
    if (!consumer) { CFRelease(data); return nil; }
    CGContextRef context = CGPDFContextCreate(consumer, &pageBox, NULL);
    CGDataConsumerRelease(consumer);
    if (!context) { CFRelease(data); return nil; }

    CFURLRef firstURL = CFURLCreateWithString(kCFAllocatorDefault, CFSTR("https://example.com/one"), NULL);
    CFURLRef secondURL = CFURLCreateWithString(kCFAllocatorDefault, CFSTR("https://example.com/two"), NULL);
    const char *words[] = { "first needle", "second needle" };
    for (NSUInteger i = 0; i < 2; i++) {
        CGPDFContextBeginPage(context, NULL);
        CGContextSelectFont(context, "Helvetica", 14, kCGEncodingMacRoman);
        CGContextSetTextDrawingMode(context, kCGTextFill);
        CGContextShowTextAtPoint(context, 36, 340, words[i], strlen(words[i]));
        CGPDFContextSetURLForRect(context, i ? secondURL : firstURL, CGRectMake(35, 330, 120, 24));
        CGPDFContextEndPage(context);
    }
    CGPDFContextClose(context);
    CGContextRelease(context);
    if (firstURL) CFRelease(firstURL);
    if (secondURL) CFRelease(secondURL);
    NSData *result = [[NSData alloc] initWithBytes:CFDataGetBytePtr(data) length:(NSUInteger)CFDataGetLength(data)];
    CFRelease(data);
    return [result autorelease];
}

static NSString *URLForPage(PDFPage *page)
{
    for (PDFAnnotation *annotation in page.annotations) {
        if ([annotation.action isKindOfClass:[PDFActionURL class]]) {
            NSString *url = [[(PDFActionURL *)annotation.action URL] absoluteString];
            return url ?: @"(none)";
        }
    }
    return @"(none)";
}

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    puts("PDFKit");
    NSData *source = MakePDF();
    PDFDocument *document = [[PDFDocument alloc] initWithData:source];
    if (!document) { puts("document=failed"); [pool drain]; return 1; }

    PDFOutline *root = [[PDFOutline alloc] init];
    PDFOutline *chapter = [[PDFOutline alloc] init];
    chapter.label = @"Second page";
    PDFDestination *destination = [[PDFDestination alloc] initWithPage:[document pageAtIndex:1] atPoint:CGPointMake(36, 340)];
    chapter.destination = destination;
    [root insertChild:chapter atIndex:0];
    document.outlineRoot = root;
    document.documentAttributes = @{ PDFDocumentTitleAttribute: @"Finch PDF test" };

    NSString *text = document.string ?: @"";
    NSArray *matches = [document findString:@"needle" withOptions:NSCaseInsensitiveSearch];
    PDFPage *first = [document pageAtIndex:0];
    PDFPage *second = [document pageAtIndex:1];
    printf("pages=%lu text=%d/%d search=%lu\n", (unsigned long)document.pageCount,
           (int)[text containsString:@"first needle"], (int)[text containsString:@"second needle"],
           (unsigned long)matches.count);
    printf("links=%lu/%lu urls=%s/%s\n", (unsigned long)first.annotations.count,
           (unsigned long)second.annotations.count, URLForPage(first).UTF8String, URLForPage(second).UTF8String);
    printf("outline=%s target=%ld\n", [document.outlineRoot childAtIndex:0].label.UTF8String,
           (long)[document indexForPage:[document.outlineRoot childAtIndex:0].destination.page]);

    NSData *saved = [document dataRepresentation];
    PDFDocument *reopened = saved ? [[PDFDocument alloc] initWithData:saved] : nil;
    if (reopened) {
        printf("roundtrip=%lu links=%lu/%lu outline=%lu title=%s\n",
               (unsigned long)reopened.pageCount,
               (unsigned long)[[reopened pageAtIndex:0].annotations count],
               (unsigned long)[[reopened pageAtIndex:1].annotations count],
               (unsigned long)reopened.outlineRoot.numberOfChildren,
               [[reopened documentAttributes][PDFDocumentTitleAttribute] UTF8String]);
    } else {
        puts("roundtrip=failed");
    }

    PDFView *view = [[PDFView alloc] initWithFrame:NSMakeRect(0, 0, 300, 400)];
    view.document = document;
    view.displayMode = kPDFDisplaySinglePage;
    [view goToPage:second];
    printf("view=%ld/%ld\n", (long)[document indexForPage:view.currentPage], (long)view.displayMode);

    BOOL success = reopened != nil;
    [view release]; [reopened release]; [destination release]; [chapter release]; [root release]; [document release];
    [pool drain];
    return success ? 0 : 1;
}
