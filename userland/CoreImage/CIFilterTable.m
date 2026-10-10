/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Finch's built-in filters: what each makes of its inputs, on the CPU in the working
 * space (linear, premultiplied). Their names, categories and inputs are Apple's
 * (CIFilterSpecs.inc); the kernels are Finch's own: color adjustments, Porter-Duff
 * compositing and the W3C blend modes, blurs, geometry, generators and reductions.
 */
#import "CoreImage_Finch.h"

/* --- reading inputs --- */

static double
num(CIFilter *f, NSString *key)
{
    return [[f valueForKey:key] doubleValue];
}

static CIImage *
img(CIFilter *f, NSString *key)
{
    id v = [f valueForKey:key];
    return [v isKindOfClass:[CIImage class]] ? v : nil;
}

static CIVector *
vec(CIFilter *f, NSString *key)
{
    id v = [f valueForKey:key];
    return [v isKindOfClass:[CIVector class]] ? v : nil;
}

static void
col(CIFilter *f, NSString *key, float *out)
{
    id v = [f valueForKey:key];
    if ([v isKindOfClass:[CIColor class]])
        [(CIColor *)v _finchWorkingComponents:out];
    else
        out[0] = out[1] = out[2] = out[3] = 0;
}

/* Unpremultiplied, in the working space. */
static void
col_straight(CIFilter *f, NSString *key, float *out)
{
    col(f, key, out);
    if (out[3] > 0)
        for (int i = 0; i < 3; i++)
            out[i] /= out[3];
}

static CGAffineTransform
transform(CIFilter *f, NSString *key)
{
    id v = [f valueForKey:key];
    CGAffineTransform t = CGAffineTransformIdentity;
    if ([v isKindOfClass:[NSAffineTransform class]]) {
        NSAffineTransformStruct s = [v transformStruct];
        t = CGAffineTransformMake(s.m11, s.m12, s.m21, s.m22, s.tX, s.tY);
    } else if ([v isKindOfClass:[NSValue class]]) {
        [v getValue:&t];
    }
    return t;
}

static CGRect
rect_input(CIVector *v)
{
    CGRect r = [v CGRectValue];
    /* Apple's "infinite" default, as its vector rounds it */
    if (r.size.width > 1e307 || r.size.height > 1e307)
        return CGRectInfinite;
    return r;
}

static const float kLuma[3] = {0.2125f, 0.7154f, 0.0721f};

static inline float
luma(const float *p)
{
    return p[0] * kLuma[0] + p[1] * kLuma[1] + p[2] * kLuma[2];
}

static inline float
mixf(float a, float b, float t)
{
    return a + (b - a) * t;
}

static inline float
clampf(float v, float lo, float hi)
{
    return v < lo ? lo : v > hi ? hi : v;
}

#define IMAGE_OR_NIL(var, key)                                                                                  \
    CIImage *var = img(f, key);                                                                                 \
    if (!var)                                                                                                   \
        return nil;

/* --- color adjustment --- */

static CIImage *
out_CIColorControls(CIFilter *f)
{
    IMAGE_OR_NIL(in, kCIInputImageKey);
    float sat = (float)num(f, kCIInputSaturationKey), bright = (float)num(f, kCIInputBrightnessKey),
          contrast = (float)num(f, kCIInputContrastKey);
    /* saturation about the luminance, then contrast about 0.5, then brightness, in linear light */
    return ci_map(in, in.extent, ^(float *p) {
      float l = luma(p);
      for (int c = 0; c < 3; c++)
          p[c] = (mixf(l, p[c], sat) - 0.5f) * contrast + 0.5f + bright;
    });
}

static CIImage *
out_CIExposureAdjust(CIFilter *f)
{
    IMAGE_OR_NIL(in, kCIInputImageKey);
    float k = powf(2, (float)num(f, kCIInputEVKey));
    return ci_map_premultiplied(in, in.extent, ^(float *p) {
      for (int c = 0; c < 3; c++)
          p[c] *= k;
    });
}

static CIImage *
out_CIGammaAdjust(CIFilter *f)
{
    IMAGE_OR_NIL(in, kCIInputImageKey);
    float g = (float)num(f, @"inputPower");
    return ci_map(in, in.extent, ^(float *p) {
      for (int c = 0; c < 3; c++)
          p[c] = powf(fmaxf(p[c], 0), g);
    });
}

static CIImage *
out_CIColorMatrix(CIFilter *f)
{
    IMAGE_OR_NIL(in, kCIInputImageKey);
    struct {
        float m[5][4];
    } M;
    float(*m)[4] = M.m;
    NSString *keys[5] = {@"inputRVector", @"inputGVector", @"inputBVector", @"inputAVector", @"inputBiasVector"};
    for (int i = 0; i < 5; i++) {
        CIVector *v = vec(f, keys[i]);
        for (int j = 0; j < 4; j++)
            m[i][j] = (float)[v valueAtIndex:(size_t)j];
    }
    return ci_map(in, CGRectIsEmpty(in.extent) ? in.extent : (M.m[4][3] > 0 ? CGRectInfinite : in.extent), ^(float *p) {
      float q[4];
      for (int i = 0; i < 4; i++)
          q[i] = p[0] * M.m[i][0] + p[1] * M.m[i][1] + p[2] * M.m[i][2] + p[3] * M.m[i][3] + M.m[4][i];
      memcpy(p, q, sizeof q);
    });
}

static CIImage *
out_CIColorInvert(CIFilter *f)
{
    IMAGE_OR_NIL(in, kCIInputImageKey);
    return ci_map(in, in.extent, ^(float *p) {
      for (int c = 0; c < 3; c++)
          p[c] = 1 - p[c];
    });
}

static CIImage *
out_CIColorMonochrome(CIFilter *f)
{
    IMAGE_OR_NIL(in, kCIInputImageKey);
    struct {
        float v[4];
    } color;
    col_straight(f, kCIInputColorKey, color.v);
    float k = (float)num(f, kCIInputIntensityKey);
    /* the colour overlaid on the luminance, then mixed in by the intensity */
    return ci_map(in, in.extent, ^(float *p) {
      float l = luma(p);
      for (int c = 0; c < 3; c++) {
          float m = l < 0.5f ? 2 * l * color.v[c] : 1 - 2 * (1 - l) * (1 - color.v[c]);
          p[c] = mixf(p[c], m, k);
      }
    });
}

static CIImage *
out_CISepiaTone(CIFilter *f)
{
    IMAGE_OR_NIL(in, kCIInputImageKey);
    float k = (float)num(f, kCIInputIntensityKey);
    /* each channel a power of the luminance (measured against Apple's: warm in the shadows) */
    static const float scale[3] = {1.00065f, 0.98903f, 0.92056f}, power[3] = {0.7825f, 1.083f, 1.912f};
    return ci_map(in, in.extent, ^(float *p) {
      float l = clampf(luma(p), 0, 1);
      for (int c = 0; c < 3; c++)
          p[c] = mixf(p[c], scale[c] * powf(l, power[c]), k);
    });
}

static CIImage *
out_CIColorClamp(CIFilter *f)
{
    IMAGE_OR_NIL(in, kCIInputImageKey);
    CIVector *lo = vec(f, @"inputMinComponents"), *hi = vec(f, @"inputMaxComponents");
    struct {
        float v[4];
    } l, h;
    for (int i = 0; i < 4; i++)
        l.v[i] = (float)[lo valueAtIndex:(size_t)i], h.v[i] = (float)[hi valueAtIndex:(size_t)i];
    return ci_map(in, in.extent, ^(float *p) {
      for (int c = 0; c < 4; c++)
          p[c] = clampf(p[c], l.v[c], h.v[c]);
    });
}

static CIImage *
out_CIMaximumComponent(CIFilter *f)
{
    IMAGE_OR_NIL(in, kCIInputImageKey);
    return ci_map(in, in.extent, ^(float *p) { p[0] = p[1] = p[2] = fmaxf(p[0], fmaxf(p[1], p[2])); });
}

static CIImage *
out_CIMinimumComponent(CIFilter *f)
{
    IMAGE_OR_NIL(in, kCIInputImageKey);
    return ci_map(in, in.extent, ^(float *p) { p[0] = p[1] = p[2] = fminf(p[0], fminf(p[1], p[2])); });
}

static CIImage *
out_CIFalseColor(CIFilter *f)
{
    IMAGE_OR_NIL(in, kCIInputImageKey);
    struct {
        float v[4];
    } c0, c1;
    col_straight(f, @"inputColor0", c0.v);
    col_straight(f, @"inputColor1", c1.v);
    return ci_map(in, in.extent, ^(float *p) {
      float l = luma(p);
      for (int c = 0; c < 3; c++)
          p[c] = mixf(c0.v[c], c1.v[c], l);
    });
}

static CIImage *
out_CIHueAdjust(CIFilter *f)
{
    IMAGE_OR_NIL(in, kCIInputImageKey);
    float a = (float)num(f, kCIInputAngleKey), cs = cosf(a), sn = sinf(a);
    /* a rotation about the grey axis that keeps luminance: L + cos(I - L) + sin K, L each row the
       luminance weights (K measured against Apple's) */
    static const float K[3][3] = {{-0.2125f, -0.7154f, 0.9279f}, {0.1406f, 0.1404f, -0.2845f}, {-0.7875f, 0.7154f, 0.0721f}};
    struct {
        float v[3][3];
    } M;
    for (int i = 0; i < 3; i++)
        for (int j = 0; j < 3; j++)
            M.v[i][j] = kLuma[j] + cs * ((i == j ? 1 : 0) - kLuma[j]) + sn * K[i][j];
    return ci_map(in, in.extent, ^(float *p) {
      float q[3];
      for (int i = 0; i < 3; i++)
          q[i] = M.v[i][0] * p[0] + M.v[i][1] * p[1] + M.v[i][2] * p[2];
      memcpy(p, q, sizeof q);
    });
}

static CIImage *
out_CIWhitePointAdjust(CIFilter *f)
{
    IMAGE_OR_NIL(in, kCIInputImageKey);
    struct {
        float v[4];
    } w;
    col_straight(f, kCIInputColorKey, w.v);
    return ci_map(in, in.extent, ^(float *p) {
      for (int c = 0; c < 3; c++)
          p[c] *= w.v[c];
    });
}

static CIImage *
out_CILinearToSRGBToneCurve(CIFilter *f)
{
    IMAGE_OR_NIL(in, kCIInputImageKey);
    return ci_map(in, in.extent, ^(float *p) {
      for (int c = 0; c < 3; c++)
          p[c] = ci_srgb_from_linear(p[c]);
    });
}

static CIImage *
out_CISRGBToneCurveToLinear(CIFilter *f)
{
    IMAGE_OR_NIL(in, kCIInputImageKey);
    return ci_map(in, in.extent, ^(float *p) {
      for (int c = 0; c < 3; c++)
          p[c] = ci_linear_from_srgb(p[c]);
    });
}

static CIImage *
out_CIColorPolynomial(CIFilter *f)
{
    IMAGE_OR_NIL(in, kCIInputImageKey);
    struct {
        float v[4][4];
    } K;
    float(*k)[4] = K.v;
    NSString *keys[4] = {@"inputRedCoefficients", @"inputGreenCoefficients", @"inputBlueCoefficients", @"inputAlphaCoefficients"};
    for (int i = 0; i < 4; i++)
        for (int j = 0; j < 4; j++)
            k[i][j] = (float)[vec(f, keys[i]) valueAtIndex:(size_t)j];
    return ci_map(in, in.extent, ^(float *p) {
      for (int c = 0; c < 4; c++) {
          float v = p[c];
          p[c] = K.v[c][0] + K.v[c][1] * v + K.v[c][2] * v * v + K.v[c][3] * v * v * v;
      }
    });
}

static CIImage *
out_CIColorCrossPolynomial(CIFilter *f)
{
    IMAGE_OR_NIL(in, kCIInputImageKey);
    struct {
        float v[3][10];
    } K;
    float(*k)[10] = K.v;
    NSString *keys[3] = {@"inputRedCoefficients", @"inputGreenCoefficients", @"inputBlueCoefficients"};
    for (int i = 0; i < 3; i++)
        for (int j = 0; j < 10; j++)
            k[i][j] = (float)[vec(f, keys[i]) valueAtIndex:(size_t)j];
    return ci_map(in, in.extent, ^(float *p) {
      float r = p[0], g = p[1], b = p[2];
      float t[10] = {r, g, b, r * r, g * g, b * b, r * g, g * b, b * r, 1};
      for (int c = 0; c < 3; c++) {
          float v = 0;
          for (int j = 0; j < 10; j++)
              v += K.v[c][j] * t[j];
          p[c] = v;
      }
    });
}

static CIImage *
out_CIColorThreshold(CIFilter *f)
{
    IMAGE_OR_NIL(in, kCIInputImageKey);
    float t = (float)num(f, @"inputThreshold");
    return ci_map(in, in.extent, ^(float *p) {
      for (int c = 0; c < 3; c++)
          p[c] = p[c] > t ? 1 : 0;
    });
}

static CIImage *
out_CIMaskToAlpha(CIFilter *f)
{
    IMAGE_OR_NIL(in, kCIInputImageKey);
    return ci_map_premultiplied(in, in.extent, ^(float *p) {
      float a = p[1]; /* the mask's green, as Apple's takes it */
      p[0] = p[1] = p[2] = p[3] = a;
    });
}

/* --- compositing --- */

typedef void (^CompositeFn)(const float *s, const float *d, float *o);

/* fg over bg, pixel by pixel, on premultiplied values. */
static CIImage *
composite(CIImage *fg, CIImage *bg, CGRect extent, CompositeFn fn)
{
    CompositeFn op = [[fn copy] autorelease];
    return ci_image(extent, ^CIBuf(CGRect r) {
      CIBuf a = ci_render(fg, r), b = ci_render(bg, r);
      for (size_t i = 0; i < a.w * a.h; i++)
          op(a.px + i * 4, b.px + i * 4, b.px + i * 4);
      ci_buf_free(a);
      return b;
    });
}

static CGRect
union_extent(CIImage *a, CIImage *b)
{
    return CGRectUnion(a.extent, b.extent);
}

#define COMPOSITE_INPUTS                                                                                        \
    CIImage *fg = img(f, kCIInputImageKey) ?: [CIImage emptyImage];                                           \
    CIImage *bg = img(f, kCIInputBackgroundImageKey) ?: [CIImage emptyImage];                                 \
    if (!img(f, kCIInputImageKey) && !img(f, kCIInputBackgroundImageKey))                                      \
        return nil;

static CIImage *
out_CISourceOverCompositing(CIFilter *f)
{
    COMPOSITE_INPUTS;
    return composite(fg, bg, union_extent(fg, bg), ^(const float *s, const float *d, float *o) {
      for (int c = 0; c < 4; c++)
          o[c] = s[c] + d[c] * (1 - s[3]);
    });
}

static CIImage *
out_CISourceInCompositing(CIFilter *f)
{
    COMPOSITE_INPUTS;
    return composite(fg, bg, CGRectIntersection(fg.extent, bg.extent), ^(const float *s, const float *d, float *o) {
      float da = d[3];
      for (int c = 0; c < 4; c++)
          o[c] = s[c] * da;
    });
}

static CIImage *
out_CISourceOutCompositing(CIFilter *f)
{
    COMPOSITE_INPUTS;
    return composite(fg, bg, fg.extent, ^(const float *s, const float *d, float *o) {
      float da = d[3];
      for (int c = 0; c < 4; c++)
          o[c] = s[c] * (1 - da);
    });
}

static CIImage *
out_CISourceAtopCompositing(CIFilter *f)
{
    COMPOSITE_INPUTS;
    return composite(fg, bg, bg.extent, ^(const float *s, const float *d, float *o) {
      float sa = s[3], da = d[3];
      for (int c = 0; c < 3; c++)
          o[c] = s[c] * da + d[c] * (1 - sa);
      o[3] = da;
    });
}

static CIImage *
out_CIMultiplyCompositing(CIFilter *f)
{
    COMPOSITE_INPUTS;
    return composite(fg, bg, union_extent(fg, bg), ^(const float *s, const float *d, float *o) {
      for (int c = 0; c < 4; c++)
          o[c] = s[c] * d[c];
    });
}

static CIImage *
out_CIAdditionCompositing(CIFilter *f)
{
    COMPOSITE_INPUTS;
    return composite(fg, bg, union_extent(fg, bg), ^(const float *s, const float *d, float *o) {
      for (int c = 0; c < 4; c++)
          o[c] = s[c] + d[c];
    });
}

static CIImage *
out_CIMinimumCompositing(CIFilter *f)
{
    COMPOSITE_INPUTS;
    return composite(fg, bg, union_extent(fg, bg), ^(const float *s, const float *d, float *o) {
      for (int c = 0; c < 4; c++)
          o[c] = fminf(s[c], d[c]);
    });
}

static CIImage *
out_CIMaximumCompositing(CIFilter *f)
{
    COMPOSITE_INPUTS;
    return composite(fg, bg, union_extent(fg, bg), ^(const float *s, const float *d, float *o) {
      for (int c = 0; c < 4; c++)
          o[c] = fmaxf(s[c], d[c]);
    });
}

/* A separable blend mode B(backdrop, source) on unpremultiplied colours, composited as
   the W3C compositing spec does: co = cs(1 - ab) + cb(1 - as) + as ab B(cb, cs). */
typedef float (^BlendFn)(float cb, float cs);

static CIImage *
blend(CIFilter *f, BlendFn fn)
{
    COMPOSITE_INPUTS;
    BlendFn b = [[fn copy] autorelease];
    return composite(fg, bg, union_extent(fg, bg), ^(const float *s, const float *d, float *o) {
      float as = s[3], ab = d[3];
      float ao = as + ab - as * ab;
      for (int c = 0; c < 3; c++) {
          float cs = as > 0 ? s[c] / as : 0, cb = ab > 0 ? d[c] / ab : 0;
          o[c] = s[c] * (1 - ab) + d[c] * (1 - as) + as * ab * b(cb, cs);
      }
      o[3] = ao;
    });
}

static float
soft_light(float cb, float cs)
{
    if (cs <= 0.5f)
        return cb - (1 - 2 * cs) * cb * (1 - cb);
    float dcb = cb <= 0.25f ? ((16 * cb - 12) * cb + 4) * cb : sqrtf(cb);
    return cb + (2 * cs - 1) * (dcb - cb);
}

static float
hard_light(float cb, float cs)
{
    return cs <= 0.5f ? cb * 2 * cs : 1 - (1 - cb) * (1 - (2 * cs - 1));
}

static CIImage *out_CIMultiplyBlendMode(CIFilter *f) { return blend(f, ^float(float cb, float cs) { return cb * cs; }); }
static CIImage *out_CIScreenBlendMode(CIFilter *f) { return blend(f, ^float(float cb, float cs) { return cb + cs - cb * cs; }); }
static CIImage *out_CIOverlayBlendMode(CIFilter *f) { return blend(f, ^float(float cb, float cs) { return hard_light(cs, cb); }); }
static CIImage *out_CIDarkenBlendMode(CIFilter *f) { return blend(f, ^float(float cb, float cs) { return fminf(cb, cs); }); }
static CIImage *out_CILightenBlendMode(CIFilter *f) { return blend(f, ^float(float cb, float cs) { return fmaxf(cb, cs); }); }
static CIImage *
out_CIColorDodgeBlendMode(CIFilter *f)
{
    return blend(f, ^float(float cb, float cs) { return cb == 0 ? 0 : cs >= 1 ? 1 : fminf(1, cb / (1 - cs)); });
}
static CIImage *
out_CIColorBurnBlendMode(CIFilter *f)
{
    return blend(f, ^float(float cb, float cs) { return cb >= 1 ? 1 : cs <= 0 ? 0 : 1 - fminf(1, (1 - cb) / cs); });
}
static CIImage *out_CISoftLightBlendMode(CIFilter *f) { return blend(f, ^float(float cb, float cs) { return soft_light(cb, cs); }); }
static CIImage *out_CIHardLightBlendMode(CIFilter *f) { return blend(f, ^float(float cb, float cs) { return hard_light(cb, cs); }); }
static CIImage *out_CIDifferenceBlendMode(CIFilter *f) { return blend(f, ^float(float cb, float cs) { return fabsf(cb - cs); }); }
static CIImage *out_CIExclusionBlendMode(CIFilter *f) { return blend(f, ^float(float cb, float cs) { return cb + cs - 2 * cb * cs; }); }
static CIImage *out_CISubtractBlendMode(CIFilter *f) { return blend(f, ^float(float cb, float cs) { return fmaxf(0, cb - cs); }); }
static CIImage *out_CIDivideBlendMode(CIFilter *f) { return blend(f, ^float(float cb, float cs) { return cs > 0 ? fminf(1, cb / cs) : (cb > 0 ? 1 : 0); }); }
static CIImage *out_CILinearBurnBlendMode(CIFilter *f) { return blend(f, ^float(float cb, float cs) { return fmaxf(0, cb + cs - 1); }); }
static CIImage *out_CILinearDodgeBlendMode(CIFilter *f) { return blend(f, ^float(float cb, float cs) { return fminf(1, cb + cs); }); }

/* The non-separable modes (W3C): hue, saturation, colour and luminosity. */
static float
lum3(const float *c)
{
    return 0.3f * c[0] + 0.59f * c[1] + 0.11f * c[2];
}

static void
clip_color(float *c)
{
    float l = lum3(c), n = fminf(c[0], fminf(c[1], c[2])), x = fmaxf(c[0], fmaxf(c[1], c[2]));
    for (int i = 0; i < 3; i++) {
        if (n < 0)
            c[i] = l + (c[i] - l) * l / (l - n);
        if (x > 1)
            c[i] = l + (c[i] - l) * (1 - l) / (x - l);
    }
}

static void
set_lum(float *c, float l)
{
    float d = l - lum3(c);
    for (int i = 0; i < 3; i++)
        c[i] += d;
    clip_color(c);
}

static float
sat3(const float *c)
{
    return fmaxf(c[0], fmaxf(c[1], c[2])) - fminf(c[0], fminf(c[1], c[2]));
}

static void
set_sat(float *c, float s)
{
    int mx = 0, mn = 0;
    for (int i = 1; i < 3; i++) {
        if (c[i] > c[mx])
            mx = i;
        if (c[i] < c[mn])
            mn = i;
    }
    int md = 3 - mx - mn;
    if (mx == mn) {
        c[0] = c[1] = c[2] = 0;
        return;
    }
    c[md] = (c[md] - c[mn]) * s / (c[mx] - c[mn]);
    c[mx] = s;
    c[mn] = 0;
}

typedef void (^NonSeparableFn)(const float *cb, const float *cs, float *out);

static CIImage *
blend_nonseparable(CIFilter *f, NonSeparableFn fn)
{
    COMPOSITE_INPUTS;
    NonSeparableFn b = [[fn copy] autorelease];
    return composite(fg, bg, union_extent(fg, bg), ^(const float *s, const float *d, float *o) {
      float as = s[3], ab = d[3], cs[3], cb[3], r[3];
      for (int c = 0; c < 3; c++)
          cs[c] = as > 0 ? s[c] / as : 0, cb[c] = ab > 0 ? d[c] / ab : 0;
      b(cb, cs, r);
      for (int c = 0; c < 3; c++)
          o[c] = s[c] * (1 - ab) + d[c] * (1 - as) + as * ab * r[c];
      o[3] = as + ab - as * ab;
    });
}

static CIImage *
out_CIHueBlendMode(CIFilter *f)
{
    return blend_nonseparable(f, ^(const float *cb, const float *cs, float *r) {
      memcpy(r, cs, 3 * sizeof(float));
      set_sat(r, sat3(cb));
      set_lum(r, lum3(cb));
    });
}

static CIImage *
out_CISaturationBlendMode(CIFilter *f)
{
    return blend_nonseparable(f, ^(const float *cb, const float *cs, float *r) {
      memcpy(r, cb, 3 * sizeof(float));
      set_sat(r, sat3(cs));
      set_lum(r, lum3(cb));
    });
}

static CIImage *
out_CIColorBlendMode(CIFilter *f)
{
    return blend_nonseparable(f, ^(const float *cb, const float *cs, float *r) {
      memcpy(r, cs, 3 * sizeof(float));
      set_lum(r, lum3(cb));
    });
}

static CIImage *
out_CILuminosityBlendMode(CIFilter *f)
{
    return blend_nonseparable(f, ^(const float *cb, const float *cs, float *r) {
      memcpy(r, cb, 3 * sizeof(float));
      set_lum(r, lum3(cs));
    });
}

static CIImage *
mask_blend(CIFilter *f, BOOL alphaMask)
{
    CIImage *fg = img(f, kCIInputImageKey), *bg = img(f, kCIInputBackgroundImageKey), *mask = img(f, kCIInputMaskImageKey);
    if (!fg)
        return nil;
    if (!bg)
        bg = [CIImage emptyImage];
    if (!mask)
        mask = [CIImage emptyImage];
    CGRect extent = CGRectUnion(CGRectIntersection(fg.extent, mask.extent), bg.extent);
    return ci_image(extent, ^CIBuf(CGRect r) {
      CIBuf a = ci_render(fg, r), b = ci_render(bg, r), m = ci_render(mask, r);
      for (size_t i = 0; i < a.w * a.h; i++) {
          const float *mp = m.px + i * 4;
          float k = alphaMask ? mp[3] : luma(mp); /* a grey mask's luminance, or its alpha */
          for (int c = 0; c < 4; c++)
              b.px[i * 4 + c] = mixf(b.px[i * 4 + c], a.px[i * 4 + c], k);
      }
      ci_buf_free(a);
      ci_buf_free(m);
      return b;
    });
}

static CIImage *out_CIBlendWithMask(CIFilter *f) { return mask_blend(f, NO); }
static CIImage *out_CIBlendWithAlphaMask(CIFilter *f) { return mask_blend(f, YES); }

/* --- blurs --- */

/* A separable convolution with a symmetric kernel of radius n (weights k[0..n]). */
static CIImage *
convolve(CIImage *in, int n, const float *k, CGRect extent)
{
    float *w = malloc(((size_t)n + 1) * sizeof(float));
    memcpy(w, k, ((size_t)n + 1) * sizeof(float));
    NSData *keep = [NSData dataWithBytesNoCopy:w length:((size_t)n + 1) * sizeof(float) freeWhenDone:YES];
    return ci_image(extent, ^CIBuf(CGRect r) {
      const float *kw = keep.bytes;
      CIBuf src = ci_render(in, CGRectInset(r, -n, -n));
      /* horizontal, over the taller rows */
      CIBuf mid = ci_buf_alloc(CGRectInset(r, 0, -n));
      for (size_t y = 0; y < mid.h; y++)
          for (size_t x = 0; x < mid.w; x++) {
              float acc[4] = {0, 0, 0, 0};
              for (int i = -n; i <= n; i++) {
                  const float *p = ci_buf_at(src, x + (size_t)n + (size_t)i, y);
                  float wt = kw[abs(i)];
                  for (int c = 0; c < 4; c++)
                      acc[c] += p[c] * wt;
              }
              memcpy(ci_buf_at(mid, x, y), acc, sizeof acc);
          }
      ci_buf_free(src);
      CIBuf out = ci_buf_alloc(r);
      for (size_t y = 0; y < out.h; y++)
          for (size_t x = 0; x < out.w; x++) {
              float acc[4] = {0, 0, 0, 0};
              for (int i = -n; i <= n; i++) {
                  const float *p = ci_buf_at(mid, x, y + (size_t)n + (size_t)i);
                  float wt = kw[abs(i)];
                  for (int c = 0; c < 4; c++)
                      acc[c] += p[c] * wt;
              }
              memcpy(ci_buf_at(out, x, y), acc, sizeof acc);
          }
      ci_buf_free(mid);
      return out;
    });
}

static CIImage *
gaussian(CIImage *in, double sigma)
{
    if (sigma <= 0)
        return in;
    /* the normal curve integrated over each pixel, out to 3 sigma, as Apple's */
    int n = (int)nearbyint(sigma * 3);
    if (n < 1)
        n = 1;
    float *k = malloc(((size_t)n + 1) * sizeof(float));
    double sum = 0, s2 = sigma * M_SQRT2;
    for (int i = 0; i <= n; i++) {
        k[i] = (float)((erf((i + 0.5) / s2) - erf((i - 0.5) / s2)) / 2);
        sum += i ? 2 * k[i] : k[i];
    }
    for (int i = 0; i <= n; i++)
        k[i] /= (float)sum;
    CGRect extent = CGRectIsInfinite(in.extent) ? CGRectInfinite : CGRectInset(in.extent, -n, -n);
    CIImage *out = convolve(in, n, k, extent);
    free(k);
    return out;
}

static CIImage *
out_CIGaussianBlur(CIFilter *f)
{
    IMAGE_OR_NIL(in, kCIInputImageKey);
    return gaussian(in, num(f, kCIInputRadiusKey));
}

static CIImage *
out_CIBoxBlur(CIFilter *f)
{
    IMAGE_OR_NIL(in, kCIInputImageKey);
    /* a square of the largest odd size within the radius */
    int r = (int)floor(num(f, kCIInputRadiusKey));
    int n = r >= 1 ? (r - 1) / 2 : 0;
    if (n <= 0)
        return in;
    float *k = malloc(((size_t)n + 1) * sizeof(float));
    for (int i = 0; i <= n; i++)
        k[i] = 1.0f / (2 * n + 1);
    CGRect extent = CGRectIsInfinite(in.extent) ? CGRectInfinite : CGRectInset(in.extent, -n, -n);
    CIImage *out = convolve(in, n, k, extent);
    free(k);
    return out;
}

/* A 2-D kernel given by a weight function over a square of radius n. */
static CIImage *
convolve2d(CIImage *in, int n, float (^weight)(int dx, int dy), CGRect extent)
{
    size_t side = (size_t)(2 * n + 1);
    float *w = malloc(side * side * sizeof(float));
    double sum = 0;
    for (int y = -n; y <= n; y++)
        for (int x = -n; x <= n; x++)
            sum += w[(size_t)(y + n) * side + (size_t)(x + n)] = weight(x, y);
    for (size_t i = 0; i < side * side; i++)
        w[i] = sum > 0 ? (float)(w[i] / sum) : 0;
    NSData *keep = [NSData dataWithBytesNoCopy:w length:side * side * sizeof(float) freeWhenDone:YES];
    return ci_image(extent, ^CIBuf(CGRect r) {
      const float *kw = keep.bytes;
      CIBuf src = ci_render(in, CGRectInset(r, -n, -n));
      CIBuf out = ci_buf_alloc(r);
      for (size_t y = 0; y < out.h; y++)
          for (size_t x = 0; x < out.w; x++) {
              float acc[4] = {0, 0, 0, 0};
              for (size_t j = 0; j < side; j++)
                  for (size_t i = 0; i < side; i++) {
                      float wt = kw[j * side + i];
                      if (wt == 0)
                          continue;
                      const float *p = ci_buf_at(src, x + i, y + j);
                      for (int c = 0; c < 4; c++)
                          acc[c] += p[c] * wt;
                  }
              memcpy(ci_buf_at(out, x, y), acc, sizeof acc);
          }
      ci_buf_free(src);
      return out;
    });
}

static CIImage *
out_CIDiscBlur(CIFilter *f)
{
    IMAGE_OR_NIL(in, kCIInputImageKey);
    double radius = num(f, kCIInputRadiusKey);
    int n = (int)ceil(radius);
    if (n <= 0)
        return in;
    CGRect extent = CGRectIsInfinite(in.extent) ? CGRectInfinite : CGRectInset(in.extent, -n, -n);
    return convolve2d(in, n, ^float(int dx, int dy) { return dx * dx + dy * dy <= radius * radius ? 1 : 0; }, extent);
}

static CIImage *
out_CIMotionBlur(CIFilter *f)
{
    IMAGE_OR_NIL(in, kCIInputImageKey);
    double radius = num(f, kCIInputRadiusKey), angle = num(f, kCIInputAngleKey);
    int n = (int)ceil(radius);
    if (n <= 0)
        return in;
    double cx = cos(angle), sy = sin(angle);
    CGRect extent = CGRectIsInfinite(in.extent) ? CGRectInfinite : CGRectInset(in.extent, -n, -n);
    return convolve2d(in, n, ^float(int dx, int dy) {
      /* within half a pixel of the line through the centre along the angle */
      double along = dx * cx + dy * sy, across = fabs(-dx * sy + dy * cx);
      return fabs(along) <= radius && across <= 0.5 ? 1 : 0;
    }, extent);
}

static CIImage *
out_CIUnsharpMask(CIFilter *f)
{
    IMAGE_OR_NIL(in, kCIInputImageKey);
    CIImage *blurred = gaussian(in, num(f, kCIInputRadiusKey));
    float k = (float)num(f, kCIInputIntensityKey);
    /* the colour pushed away from its (unpremultiplied) blur */
    return ci_image(in.extent, ^CIBuf(CGRect r) {
      CIBuf a = ci_render(in, r), b = ci_render(blurred, r);
      for (size_t i = 0; i < a.w * a.h; i++) {
          float *p = a.px + i * 4, *q = b.px + i * 4;
          float pa = p[3], qa = q[3];
          for (int c = 0; c < 3; c++) {
              float v = pa > 0 ? p[c] / pa : 0, bl = qa > 0 ? q[c] / qa : 0;
              p[c] = (v + (v - bl) * k) * pa;
          }
      }
      ci_buf_free(b);
      return a;
    });
}

static CIImage *
morphology(CIFilter *f, BOOL maximum)
{
    IMAGE_OR_NIL(in, kCIInputImageKey);
    double radius = num(f, kCIInputRadiusKey);
    int n = (int)ceil(radius);
    if (n <= 0)
        return in;
    CGRect extent = CGRectIsInfinite(in.extent) ? CGRectInfinite : CGRectInset(in.extent, maximum ? -n : n, maximum ? -n : n);
    return ci_image(extent, ^CIBuf(CGRect r) {
      CIBuf src = ci_render(in, CGRectInset(r, -n, -n));
      CIBuf out = ci_buf_alloc(r);
      for (size_t y = 0; y < out.h; y++)
          for (size_t x = 0; x < out.w; x++) {
              float acc[4];
              for (int c = 0; c < 4; c++)
                  acc[c] = maximum ? -INFINITY : INFINITY;
              for (int j = -n; j <= n; j++)
                  for (int i = -n; i <= n; i++) {
                      if (i * i + j * j > radius * radius)
                          continue;
                      const float *p = ci_buf_at(src, x + (size_t)(n + i), y + (size_t)(n + j));
                      for (int c = 0; c < 4; c++)
                          acc[c] = maximum ? fmaxf(acc[c], p[c]) : fminf(acc[c], p[c]);
                  }
              memcpy(ci_buf_at(out, x, y), acc, sizeof acc);
          }
      ci_buf_free(src);
      return out;
    });
}

static CIImage *out_CIMorphologyMaximum(CIFilter *f) { return morphology(f, YES); }
static CIImage *out_CIMorphologyMinimum(CIFilter *f) { return morphology(f, NO); }

/* --- geometry --- */

static CIImage *
out_CIAffineTransform(CIFilter *f)
{
    IMAGE_OR_NIL(in, kCIInputImageKey);
    return [in imageByApplyingTransform:transform(f, kCIInputTransformKey)];
}

static CIImage *
out_CICrop(CIFilter *f)
{
    IMAGE_OR_NIL(in, kCIInputImageKey);
    CGRect r = rect_input(vec(f, @"inputRectangle"));
    return CGRectIsInfinite(r) ? in : [in imageByCroppingToRect:r];
}

static double
lanczos3(double x)
{
    x = fabs(x);
    if (x < 1e-9)
        return 1;
    if (x >= 3)
        return 0;
    return 3 * sin(M_PI * x) * sin(M_PI * x / 3) / (M_PI * M_PI * x * x);
}

/* Weights of the source pixels for an output pixel (centre at x), scale s along this axis. */
static void
lanczos_taps(double center, double s, long *first, int *count, float *w, int max)
{
    double support = s < 1 ? 3 / s : 3, fs = s < 1 ? s : 1;
    long a = (long)floor(center - support), b = (long)ceil(center + support);
    int n = 0;
    double sum = 0;
    for (long i = a; i <= b && n < max; i++, n++) {
        w[n] = (float)lanczos3((i + 0.5 - center) * fs);
        sum += w[n];
    }
    for (int i = 0; i < n; i++)
        w[i] = sum != 0 ? (float)(w[i] / sum) : 0;
    *first = a;
    *count = n;
}

static CIImage *
out_CILanczosScaleTransform(CIFilter *f)
{
    IMAGE_OR_NIL(in, kCIInputImageKey);
    double sy = num(f, kCIInputScaleKey), sx = sy * num(f, kCIInputAspectRatioKey);
    if (sx <= 0 || sy <= 0)
        return [CIImage emptyImage];
    CGRect e = in.extent;
    if (CGRectIsInfinite(e))
        return [in imageByApplyingTransform:CGAffineTransformMakeScale(sx, sy)];
    CGRect extent = CGRectMake(e.origin.x * sx, e.origin.y * sy, ceil(e.size.width * sx), ceil(e.size.height * sy));
    CIImage *source = in; /* transparent around it, as Apple's */
    return [ci_image(extent, ^CIBuf(CGRect r) {
      /* separable Lanczos-3: rows of the source first, then columns */
      CGRect need = CGRectIntegral(CGRectMake(r.origin.x / sx - 4 / fmin(sx, 1), r.origin.y / sy - 4 / fmin(sy, 1),
                                              r.size.width / sx + 8 / fmin(sx, 1), r.size.height / sy + 8 / fmin(sy, 1)));
      CIBuf src = ci_render(source, need);
      CIBuf mid = ci_buf_alloc(CGRectMake(r.origin.x, need.origin.y, r.size.width, need.size.height));
      float w[256];
      for (size_t x = 0; x < mid.w; x++) {
          long first;
          int count;
          lanczos_taps((r.origin.x + x + 0.5) / sx, sx, &first, &count, w, 256);
          for (size_t y = 0; y < mid.h; y++) {
              float acc[4] = {0, 0, 0, 0};
              for (int i = 0; i < count; i++) {
                  long sxp = first + i - (long)need.origin.x;
                  sxp = sxp < 0 ? 0 : sxp >= (long)src.w ? (long)src.w - 1 : sxp;
                  const float *p = ci_buf_at(src, (size_t)sxp, y);
                  for (int c = 0; c < 4; c++)
                      acc[c] += p[c] * w[i];
              }
              memcpy(ci_buf_at(mid, x, y), acc, sizeof acc);
          }
      }
      ci_buf_free(src);
      CIBuf out = ci_buf_alloc(r);
      for (size_t y = 0; y < out.h; y++) {
          long first;
          int count;
          lanczos_taps((r.origin.y + y + 0.5) / sy, sy, &first, &count, w, 256);
          for (size_t x = 0; x < out.w; x++) {
              float acc[4] = {0, 0, 0, 0};
              for (int i = 0; i < count; i++) {
                  long syp = first + i - (long)need.origin.y;
                  syp = syp < 0 ? 0 : syp >= (long)mid.h ? (long)mid.h - 1 : syp;
                  const float *p = ci_buf_at(mid, x, (size_t)syp);
                  for (int c = 0; c < 4; c++)
                      acc[c] += p[c] * w[i];
              }
              memcpy(ci_buf_at(out, x, y), acc, sizeof acc);
          }
      }
      ci_buf_free(mid);
      return out;
    }) imageByCroppingToRect:CGRectMake(e.origin.x * sx, e.origin.y * sy, e.size.width * sx, e.size.height * sy)];
}

static CIImage *
out_CIStraightenFilter(CIFilter *f)
{
    IMAGE_OR_NIL(in, kCIInputImageKey);
    double angle = num(f, kCIInputAngleKey);
    CGRect e = in.extent;
    if (CGRectIsInfinite(e) || angle == 0)
        return in;
    double w = e.size.width, h = e.size.height, c = fabs(cos(angle)), s = fabs(sin(angle));
    double scale = fmax(c + (h / w) * s, c + (w / h) * s);
    CGPoint mid = CGPointMake(CGRectGetMidX(e), CGRectGetMidY(e));
    CGAffineTransform t = CGAffineTransformMakeTranslation(mid.x, mid.y);
    t = CGAffineTransformRotate(t, angle);
    t = CGAffineTransformScale(t, scale, scale);
    t = CGAffineTransformTranslate(t, -mid.x, -mid.y);
    return [[in imageByApplyingTransform:t] imageByCroppingToRect:e];
}

static CIImage *
out_CIAffineClamp(CIFilter *f)
{
    IMAGE_OR_NIL(in, kCIInputImageKey);
    return [[in imageByClampingToExtent] imageByApplyingTransform:transform(f, kCIInputTransformKey)];
}

/* --- generators --- */

static CIImage *
generator(float (^weight)(double x, double y), const float *c0, const float *c1)
{
    struct {
        float v[4];
    } a, b;
    memcpy(a.v, c0, sizeof a.v);
    memcpy(b.v, c1, sizeof b.v);
    float (^w)(double, double) = [[weight copy] autorelease];
    return ci_image(CGRectInfinite, ^CIBuf(CGRect r) {
      CIBuf out = ci_buf_alloc(r);
      for (size_t y = 0; y < out.h; y++)
          for (size_t x = 0; x < out.w; x++) {
              float t = w(r.origin.x + x + 0.5, r.origin.y + y + 0.5);
              float *p = ci_buf_at(out, x, y);
              for (int c = 0; c < 4; c++)
                  p[c] = mixf(a.v[c], b.v[c], t);
          }
      return out;
    });
}

static CIImage *
out_CIConstantColorGenerator(CIFilter *f)
{
    id c = [f valueForKey:kCIInputColorKey];
    return [c isKindOfClass:[CIColor class]] ? [CIImage imageWithColor:c] : nil;
}

static CIImage *
out_CICheckerboardGenerator(CIFilter *f)
{
    float c0[4], c1[4];
    col(f, @"inputColor0", c0);
    col(f, @"inputColor1", c1);
    CGPoint center = [vec(f, kCIInputCenterKey) CGPointValue];
    double w = num(f, kCIInputWidthKey);
    if (w <= 0)
        return [CIImage imageWithColor:[f valueForKey:@"inputColor0"]];
    return generator(^float(double x, double y) {
      long ix = (long)floor((x - center.x) / w), iy = (long)floor((y - center.y) / w);
      return ((ix + iy) & 1) ? 1 : 0;
    }, c0, c1);
}

static CIImage *
out_CIStripesGenerator(CIFilter *f)
{
    float c0[4], c1[4];
    col(f, @"inputColor0", c0);
    col(f, @"inputColor1", c1);
    CGPoint center = [vec(f, kCIInputCenterKey) CGPointValue];
    double w = num(f, kCIInputWidthKey);
    if (w <= 0)
        return [CIImage imageWithColor:[f valueForKey:@"inputColor0"]];
    return generator(^float(double x, double y) { return ((long)floor((x - center.x) / w) & 1) ? 0 : 1; }, c0, c1);
}

static CIImage *
linear_gradient(CIFilter *f, BOOL smooth)
{
    float c0[4], c1[4];
    col(f, @"inputColor0", c0);
    col(f, @"inputColor1", c1);
    CGPoint p0 = [vec(f, @"inputPoint0") CGPointValue], p1 = [vec(f, @"inputPoint1") CGPointValue];
    double dx = p1.x - p0.x, dy = p1.y - p0.y, len2 = dx * dx + dy * dy;
    return generator(^float(double x, double y) {
      double t = len2 > 0 ? ((x - p0.x) * dx + (y - p0.y) * dy) / len2 : 0;
      t = t < 0 ? 0 : t > 1 ? 1 : t;
      if (smooth)
          t = t * t * (3 - 2 * t);
      return (float)t;
    }, c0, c1);
}

static CIImage *out_CILinearGradient(CIFilter *f) { return linear_gradient(f, NO); }
static CIImage *out_CISmoothLinearGradient(CIFilter *f) { return linear_gradient(f, YES); }

static CIImage *
out_CIRadialGradient(CIFilter *f)
{
    float c0[4], c1[4];
    col(f, @"inputColor0", c0);
    col(f, @"inputColor1", c1);
    CGPoint c = [vec(f, kCIInputCenterKey) CGPointValue];
    double r0 = num(f, @"inputRadius0"), r1 = num(f, @"inputRadius1");
    return generator(^float(double x, double y) {
      double d = hypot(x - c.x, y - c.y);
      double t = r1 != r0 ? (d - r0) / (r1 - r0) : (d >= r1 ? 1 : 0);
      return (float)(t < 0 ? 0 : t > 1 ? 1 : t);
    }, c0, c1);
}

/* --- stylize and reductions --- */

static CIImage *
out_CIPixellate(CIFilter *f)
{
    IMAGE_OR_NIL(in, kCIInputImageKey);
    CGPoint center = [vec(f, kCIInputCenterKey) CGPointValue];
    double scale = fmax(1, num(f, kCIInputScaleKey));
    BOOL encoded = [in _finchIsEncodedSource];
    CGRect extent = CGRectIsInfinite(in.extent) ? CGRectInfinite : CGRectInset(in.extent, -scale / 2, -scale / 2);
    return ci_image(extent, ^CIBuf(CGRect r) {
      /* each cell is the image sampled (bilinearly, in a source's own encoding, as Apple's) at its centre */
      CGRect cells = CGRectIntegral(CGRectInset(r, -scale - 1, -scale - 1));
      CIBuf src = ci_render(in, cells);
      if (encoded)
          for (size_t i = 0; i < src.w * src.h; i++) {
              float *p = src.px + i * 4;
              for (int c = 0; c < 3; c++)
                  p[c] = p[3] > 0 ? ci_srgb_from_linear(p[c] / p[3]) * p[3] : 0;
          }
      CIBuf out = ci_buf_alloc(r);
      for (size_t y = 0; y < out.h; y++)
          for (size_t x = 0; x < out.w; x++) {
              double px = r.origin.x + x + 0.5, py = r.origin.y + y + 0.5;
              double cx = center.x + (floor((px - center.x) / scale) + 0.5) * scale;
              double cy = center.y + (floor((py - center.y) / scale) + 0.5) * scale;
              double fx = cx - src.r.origin.x - 0.5, fy = cy - src.r.origin.y - 0.5;
              long x0 = (long)floor(fx), y0 = (long)floor(fy);
              float tx = (float)(fx - x0), ty = (float)(fy - y0), *o = ci_buf_at(out, x, y);
              for (int j = 0; j < 2; j++)
                  for (int i = 0; i < 2; i++) {
                      long sx = x0 + i, sy = y0 + j;
                      if (sx < 0 || sy < 0 || sx >= (long)src.w || sy >= (long)src.h)
                          continue;
                      float wt = (i ? tx : 1 - tx) * (j ? ty : 1 - ty);
                      const float *p = ci_buf_at(src, (size_t)sx, (size_t)sy);
                      for (int c = 0; c < 4; c++)
                          o[c] += p[c] * wt;
                  }
              if (encoded)
                  for (int c = 0; c < 3; c++)
                      o[c] = o[3] > 0 ? ci_linear_from_srgb(o[c] / o[3]) * o[3] : 0;
          }
      ci_buf_free(src);
      return out;
    });
}

typedef enum { AREA_AVERAGE, AREA_MAXIMUM, AREA_MINIMUM } AreaOp;

static CIImage *
area(CIFilter *f, AreaOp op)
{
    IMAGE_OR_NIL(in, kCIInputImageKey);
    CGRect e = CGRectIntegral(CGRectIntersection([vec(f, kCIInputExtentKey) CGRectValue], in.extent));
    CGRect at = CGRectMake(0, 0, 1, 1);
    return ci_image(at, ^CIBuf(CGRect r) {
      CIBuf out = ci_buf_alloc(r);
      if (CGRectIsEmpty(e))
          return out;
      CIBuf src = ci_render(in, e);
      double acc[4] = {0, 0, 0, 0};
      for (int c = 0; c < 4; c++)
          acc[c] = op == AREA_MAXIMUM ? -INFINITY : op == AREA_MINIMUM ? INFINITY : 0;
      size_t n = src.w * src.h;
      for (size_t i = 0; i < n; i++)
          for (int c = 0; c < 4; c++) {
              double v = src.px[i * 4 + c];
              acc[c] = op == AREA_AVERAGE ? acc[c] + v : op == AREA_MAXIMUM ? fmax(acc[c], v) : fmin(acc[c], v);
          }
      for (int c = 0; c < 4; c++)
          if (op == AREA_AVERAGE)
              acc[c] /= (double)(n ? n : 1);
      ci_buf_free(src);
      for (size_t i = 0; i < out.w * out.h; i++)
          for (int c = 0; c < 4; c++)
              out.px[i * 4 + c] = (float)acc[c];
      return out;
    });
}

static CIImage *out_CIAreaAverage(CIFilter *f) { return area(f, AREA_AVERAGE); }
static CIImage *out_CIAreaMaximum(CIFilter *f) { return area(f, AREA_MAXIMUM); }
static CIImage *out_CIAreaMinimum(CIFilter *f) { return area(f, AREA_MINIMUM); }

/* CIBlendKernel's built-in kernels, by name: the filter, or a Porter-Duff operator. */
CIImage *
ci_blend_named(NSString *name, CIImage *fg, CIImage *bg)
{
    NSDictionary *filters = @{
        @"sourceOver" : @"CISourceOverCompositing", @"sourceIn" : @"CISourceInCompositing",
        @"sourceOut" : @"CISourceOutCompositing", @"sourceAtop" : @"CISourceAtopCompositing",
        @"componentAdd" : @"CIAdditionCompositing", @"componentMultiply" : @"CIMultiplyCompositing",
        @"componentMin" : @"CIMinimumCompositing", @"componentMax" : @"CIMaximumCompositing",
        @"multiply" : @"CIMultiplyBlendMode", @"screen" : @"CIScreenBlendMode", @"overlay" : @"CIOverlayBlendMode",
        @"darken" : @"CIDarkenBlendMode", @"lighten" : @"CILightenBlendMode", @"colorDodge" : @"CIColorDodgeBlendMode",
        @"colorBurn" : @"CIColorBurnBlendMode", @"hardLight" : @"CIHardLightBlendMode", @"softLight" : @"CISoftLightBlendMode",
        @"difference" : @"CIDifferenceBlendMode", @"exclusion" : @"CIExclusionBlendMode", @"hue" : @"CIHueBlendMode",
        @"saturation" : @"CISaturationBlendMode", @"color" : @"CIColorBlendMode", @"luminosity" : @"CILuminosityBlendMode",
        @"subtract" : @"CISubtractBlendMode", @"divide" : @"CIDivideBlendMode", @"linearBurn" : @"CILinearBurnBlendMode",
        @"linearDodge" : @"CILinearDodgeBlendMode",
    };
    NSString *filter = filters[name];
    if (filter) {
        CIFilter *f = [CIFilter filterWithName:filter];
        [f setValue:fg forKey:kCIInputImageKey];
        [f setValue:bg forKey:kCIInputBackgroundImageKey];
        return f.outputImage;
    }
    CGRect u = CGRectUnion(fg.extent, bg.extent);
    if ([name isEqualToString:@"clear"])
        return [CIImage emptyImage];
    if ([name isEqualToString:@"source"])
        return fg;
    if ([name isEqualToString:@"destination"])
        return bg;
    if ([name isEqualToString:@"destinationOver"])
        return composite(bg, fg, u, ^(const float *s, const float *d, float *o) {
          for (int c = 0; c < 4; c++)
              o[c] = s[c] + d[c] * (1 - s[3]);
        });
    if ([name isEqualToString:@"destinationIn"])
        return composite(fg, bg, CGRectIntersection(fg.extent, bg.extent), ^(const float *s, const float *d, float *o) {
          float sa = s[3];
          for (int c = 0; c < 4; c++)
              o[c] = d[c] * sa;
        });
    if ([name isEqualToString:@"destinationOut"])
        return composite(fg, bg, bg.extent, ^(const float *s, const float *d, float *o) {
          float sa = s[3];
          for (int c = 0; c < 4; c++)
              o[c] = d[c] * (1 - sa);
        });
    if ([name isEqualToString:@"destinationAtop"])
        return composite(fg, bg, fg.extent, ^(const float *s, const float *d, float *o) {
          float sa = s[3], da = d[3];
          for (int c = 0; c < 3; c++)
              o[c] = d[c] * sa + s[c] * (1 - da);
          o[3] = sa;
        });
    if ([name isEqualToString:@"exclusiveOr"])
        return composite(fg, bg, u, ^(const float *s, const float *d, float *o) {
          float sa = s[3], da = d[3];
          for (int c = 0; c < 4; c++)
              o[c] = s[c] * (1 - da) + d[c] * (1 - sa);
        });
    return nil;
}

/* --- the table --- */

static const CIFilterDescription filters[] = {
#include "CIFilterSpecs.inc"
};

const CIFilterDescription *
ci_filter_description(NSString *name)
{
    static NSDictionary *byName;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      NSMutableDictionary *d = [NSMutableDictionary dictionary];
      for (size_t i = 0; i < sizeof filters / sizeof *filters; i++)
          d[@(filters[i].name)] = [NSValue valueWithPointer:&filters[i]];
      byName = [d copy];
    });
    return name ? [byName[name] pointerValue] : NULL;
}

NSArray<NSString *> *
ci_filter_names(void)
{
    static NSArray *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      NSMutableArray *a = [NSMutableArray array];
      for (size_t i = 0; i < sizeof filters / sizeof *filters; i++)
          [a addObject:@(filters[i].name)];
      [a sortUsingSelector:@selector(compare:)];
      names = [a copy];
    });
    return names;
}
