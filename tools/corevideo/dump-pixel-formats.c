/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Writes the pixel format descriptions of Apple's CoreVideo on this Mac as a binary
   property list (an array of dictionaries), with each fill callback (a pointer into
   Apple's code) written as true: Finch's CoreVideo puts its own in their place. Run by
   tools/corevideo/gen-pixel-formats.sh. */
#include <CoreVideo/CoreVideo.h>
#include <stdio.h>

int
main(int argc, char **argv)
{
    CFArrayRef all = CVPixelFormatDescriptionArrayCreateWithAllPixelFormatTypes(NULL);
    CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; i < CFArrayGetCount(all); i++) {
        OSType f;
        CFNumberGetValue(CFArrayGetValueAtIndex(all, i), kCFNumberSInt32Type, &f);
        CFDictionaryRef d = CVPixelFormatDescriptionCreateWithPixelFormatType(NULL, f);
        if (!d)
            continue;
        CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(NULL, 0, d);
        if (CFDictionaryContainsKey(m, kCVPixelFormatFillExtendedPixelsCallback))
            CFDictionarySetValue(m, kCVPixelFormatFillExtendedPixelsCallback, kCFBooleanTrue);
        CFArrayAppendValue(out, m);
        CFRelease(m);
        CFRelease(d);
    }
    CFDataRef data = CFPropertyListCreateData(NULL, out, kCFPropertyListBinaryFormat_v1_0, 0, NULL);
    FILE *fp = fopen(argv[1], "wb");
    fwrite(CFDataGetBytePtr(data), 1, (size_t)CFDataGetLength(data), fp);
    fclose(fp);
    fprintf(stderr, "%ld formats, %ld bytes\n", (long)CFArrayGetCount(out), (long)CFDataGetLength(data));
    return 0;
}
