/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * What CoreImage's parts share. An image is a recipe: its extent and a block that
 * renders any rectangle of it. Rendering works as Apple's CoreImage does by default,
 * in extended linear sRGB with premultiplied alpha, on 32-bit floats (Apple's uses
 * half floats on the GPU; results agree to the 8-bit outputs apps see).
 */
#import <CoreImage/CoreImage.h>
#import <Foundation/Foundation.h>
#include <math.h>

/* Apple's classes declare their initializers in ways Finch's implementations needn't follow. */
#pragma clang diagnostic ignored "-Wobjc-designated-initializers"
#pragma clang diagnostic ignored "-Wobjc-autosynthesis-property-ivar-name-match"

/* Formats Apple's exports but doesn't declare. */
extern const CIFormat kCIFormatXRGB8, kCIFormatBGRX8, kCIFormatXBGR8;

/* A rectangle of pixels in the working space: RGBA premultiplied, rows from the
   bottom (CoreImage's coordinates, y up). */
typedef struct {
    CGRect r; /* integral */
    size_t w, h;
    float *px; /* w * h * 4 */
} CIBuf;

CIBuf ci_buf_alloc(CGRect r); /* zeroed */
void ci_buf_free(CIBuf b);
static inline float *
ci_buf_at(CIBuf b, size_t x, size_t y)
{
    return b.px + (y * b.w + x) * 4;
}

typedef CIBuf (^CIRenderBlock)(CGRect r);

/* An image of this extent, drawn by render (which gets integral rectangles). */
CIImage *ci_image(CGRect extent, CIRenderBlock render);
/* Renders r (made integral) of an image: transparent outside its extent. */
CIBuf ci_render(CIImage *image, CGRect r);
/* The pixels a per-pixel filter needs: the input over r, then fn on each pixel's
   unpremultiplied components (alpha last), premultiplied again after. */
CIImage *ci_map(CIImage *input, CGRect extent, void (^fn)(float *rgba));
/* As ci_map, on premultiplied components. */
CIImage *ci_map_premultiplied(CIImage *input, CGRect extent, void (^fn)(float *rgba));

static inline float
ci_linear_from_srgb(float v)
{
    float a = fabsf(v);
    float l = a <= 0.04045f ? a / 12.92f : powf((a + 0.055f) / 1.055f, 2.4f);
    return v < 0 ? -l : l;
}

static inline float
ci_srgb_from_linear(float v)
{
    float a = fabsf(v);
    float s = a <= 0.0031308f ? a * 12.92f : 1.055f * powf(a, 1 / 2.4f) - 0.055f;
    return v < 0 ? -s : s;
}

/* Whether a color space's transfer is linear (output written without the sRGB curve). */
BOOL ci_space_is_linear(CGColorSpaceRef space);

/* An image's pixels as a premultiplied sRGB RGBA8 CGImage over r (y up). */
CGImageRef ci_create_cgimage(CIImage *image, CGRect r, CIFormat format, CGColorSpaceRef space);
/* Writes r of an image to memory in a format and color space (NULL: no matching). */
void ci_write(CIImage *image, void *data, size_t rowBytes, CGRect r, CIFormat format, CGColorSpaceRef space);

@interface CIColor ()
- (void)_finchWorkingComponents:(float *)out;
@end

@interface CIImage ()
- (instancetype)_finchInitWithExtent:(CGRect)extent render:(CIRenderBlock)render;
- (CIBuf)_finchRender:(CGRect)r;
- (BOOL)_finchIsEncodedSource;
@end

/* The filters: CIFilterTable.m. */
typedef struct CIFilterInput {
    const char *key;
    const char *cls;  /* NSNumber, CIImage, CIVector, CIColor, NSValue, NSString, NSData, ... */
    const char *type; /* kCIAttributeType... value, or NULL */
    const char *displayName;
    double def, min, max, sliderMin, sliderMax, identity;
    unsigned flags; /* which of def..identity are given */
    const char *defString; /* a CIVector or CIColor default ("V[150 150]", "C1 1 1 1") */
    const char *identityString; /* the same, for the identity */
} CIFilterInput;

enum { CI_DEF = 1, CI_MIN = 2, CI_MAX = 4, CI_SMIN = 8, CI_SMAX = 16, CI_IDENTITY = 32 };

typedef struct CIFilterDescription {
    const char *name;
    const char *displayName;
    const char *categories[10];
    const char *availableMac, *availableIOS;
    CIFilterInput inputs[12];
    CIImage *(*output)(CIFilter *filter);
    const char *outputs[3]; /* when not just outputImage */
} CIFilterDescription;

const CIFilterDescription *ci_filter_description(NSString *name);
CIImage *ci_blend_named(NSString *name, CIImage *fg, CIImage *bg);
NSArray<NSString *> *ci_filter_names(void);

@interface CIFilter ()
- (const CIFilterDescription *)_finchDescription;
@end
