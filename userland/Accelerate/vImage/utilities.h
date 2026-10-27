/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Shared by vImage's utilities and its CoreVideo utilities: converters between
 * vImage_CGImageFormats, and the CoreVideo half of converters to and from video formats.
 */
#ifndef FINCH_VIMAGE_UTILITIES_H
#define FINCH_VIMAGE_UTILITIES_H

#include "common.h"
#include <ColorSync/ColorSync.h>

struct vImageCVConversion;

/* a new converter with nothing set (one reference) */
vImageConverterRef vimage_converter_alloc(void);
/* makes a new converter one between CoreGraphics and CoreVideo formats (it takes cv) */
void vimage_converter_set_cv(vImageConverterRef converter, const struct vImageCVConversion *cv);
/* a ColorSync transform between two colour spaces (NULL is sRGB) */
ColorSyncTransformRef vimage_make_transform(CGColorSpaceRef from, CGColorSpaceRef to, CGColorRenderingIntent intent);
/* a converter's CG-to-CG conversion of one buffer */
vImage_Error vimage_convert_cg(vImageConverterRef converter, const vImage_Buffer *src, const vImage_Buffer *dest);

/* the CoreVideo side (cv-utilities.c) */
void vimage_cv_release(const struct vImageCVConversion *cv);
const vImageBufferTypeCode *vimage_cv_source_order(const struct vImageCVConversion *cv);
const vImageBufferTypeCode *vimage_cv_destination_order(const struct vImageCVConversion *cv);
vImage_Error vimage_cv_convert(vImageConverterRef converter, const struct vImageCVConversion *cv,
                               const vImage_Buffer *srcs, const vImage_Buffer *dests, vImage_Flags flags);

#endif
