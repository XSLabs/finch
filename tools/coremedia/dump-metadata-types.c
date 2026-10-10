/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Writes the metadata data types Apple's CoreMedia on this Mac registers (each type,
   its description, the types it conforms to and, for those QuickTime knows, its
   well-known type number, as a metadata format description records it), base types
   first, as a binary property list. Run by tools/coremedia/gen-metadata-types.sh. */
#include <CoreMedia/CoreMedia.h>
#include <stdio.h>

int
main(int argc, char **argv)
{
    CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    CFMutableArrayRef types = CFArrayCreateMutableCopy(NULL, 0, CMMetadataDataTypeRegistryGetBaseDataTypes());
    const CFStringRef named[] = {kCMMetadataBaseDataType_AffineTransformF64,kCMMetadataBaseDataType_BMP,kCMMetadataBaseDataType_DimensionsF32,kCMMetadataBaseDataType_ExtendedRasterRectangleValue,kCMMetadataBaseDataType_Float32,kCMMetadataBaseDataType_Float64,kCMMetadataBaseDataType_GIF,kCMMetadataBaseDataType_JPEG,kCMMetadataBaseDataType_JSON,kCMMetadataBaseDataType_PerspectiveTransformF64,kCMMetadataBaseDataType_PNG,kCMMetadataBaseDataType_PointF32,kCMMetadataBaseDataType_PolygonF32,kCMMetadataBaseDataType_PolylineF32,kCMMetadataBaseDataType_RasterRectangleValue,kCMMetadataBaseDataType_RawData,kCMMetadataBaseDataType_RectF32,kCMMetadataBaseDataType_SInt16,kCMMetadataBaseDataType_SInt32,kCMMetadataBaseDataType_SInt64,kCMMetadataBaseDataType_SInt8,kCMMetadataBaseDataType_UInt16,kCMMetadataBaseDataType_UInt32,kCMMetadataBaseDataType_UInt64,kCMMetadataBaseDataType_UInt8,kCMMetadataBaseDataType_UTF16,kCMMetadataBaseDataType_UTF8,kCMMetadataDataType_QuickTimeMetadataDirection,kCMMetadataDataType_QuickTimeMetadataLocation_ISO6709,kCMMetadataDataType_QuickTimeMetadataMilliLux,kCMMetadataDataType_QuickTimeMetadataUUID};
    for (size_t i = 0; i < sizeof named / sizeof named[0]; i++)
        if (!CFArrayContainsValue(types, CFRangeMake(0, CFArrayGetCount(types)), named[i]))
            CFArrayAppendValue(types, named[i]);
    for (CFIndex i = 0; i < CFArrayGetCount(types); i++) {
        CFStringRef t = CFArrayGetValueAtIndex(types, i);
        if (!CMMetadataDataTypeRegistryDataTypeIsRegistered(t))
            continue;
        CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFDictionarySetValue(d, CFSTR("type"), t);
        CFStringRef desc = CMMetadataDataTypeRegistryGetDataTypeDescription(t);
        if (desc)
            CFDictionarySetValue(d, CFSTR("description"), desc);
        CFArrayRef conforming = CMMetadataDataTypeRegistryGetConformingDataTypes(t);
        if (conforming)
            CFDictionarySetValue(d, CFSTR("conforming"), conforming);
        CFDictionarySetValue(d, CFSTR("base"), CMMetadataDataTypeRegistryDataTypeIsBaseDataType(t) ? kCFBooleanTrue : kCFBooleanFalse);
        /* (the well-known number: how a format description's key table records the type) */
        const void *k[] = {kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier, kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType};
        const void *v[] = {CFSTR("mdta/x"), t};
        CFDictionaryRef spec = CFDictionaryCreate(NULL, k, v, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFArrayRef specs = CFArrayCreate(NULL, (const void **)&spec, 1, &kCFTypeArrayCallBacks);
        CMFormatDescriptionRef fd = NULL;
        if (!CMMetadataFormatDescriptionCreateWithMetadataSpecifications(NULL, kCMMetadataFormatType_Boxed, specs, &fd) && fd) {
            CFDictionaryRef key = CMMetadataFormatDescriptionGetKeyWithLocalID(fd, 1);
            CFNumberRef ns = key ? CFDictionaryGetValue(key, CFSTR("MetadataKeyDataTypeNameSpace")) : NULL;
            CFDataRef code = key ? CFDictionaryGetValue(key, CFSTR("MetadataKeyDataType")) : NULL;
            int n = -1;
            if (ns && CFNumberGetValue(ns, kCFNumberIntType, &n) && n == 0 && code && CFDataGetLength(code) == 4) {
                const UInt8 *b = CFDataGetBytePtr(code);
                int wellKnown = b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3];
                CFNumberRef w = CFNumberCreate(NULL, kCFNumberIntType, &wellKnown);
                CFDictionarySetValue(d, CFSTR("wellKnown"), w);
                CFRelease(w);
            }
            CFRelease(fd);
        }
        CFRelease(specs);
        CFRelease(spec);
        CFArrayAppendValue(out, d);
        CFRelease(d);
    }
    CFDataRef data = CFPropertyListCreateData(NULL, out, kCFPropertyListBinaryFormat_v1_0, 0, NULL);
    FILE *fp = fopen(argv[1], "wb");
    fwrite(CFDataGetBytePtr(data), 1, (size_t)CFDataGetLength(data), fp);
    fclose(fp);
    fprintf(stderr, "%ld types, %ld bytes\n", (long)CFArrayGetCount(out), (long)CFDataGetLength(data));
    return 0;
}
