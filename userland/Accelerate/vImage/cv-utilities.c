/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * vImage's CoreVideo utilities (vImage_CVUtilities.h).
 */
#include "utilities.h"

struct vImageCVConversion {
    vImageBufferTypeCode srcOrder[5], dstOrder[5];
};

void vimage_cv_release(const struct vImageCVConversion *cv) { free((void *)cv); }

const vImageBufferTypeCode *vimage_cv_source_order(const struct vImageCVConversion *cv) { return cv->srcOrder; }

const vImageBufferTypeCode *vimage_cv_destination_order(const struct vImageCVConversion *cv) { return cv->dstOrder; }

vImage_Error vimage_cv_convert(vImageConverterRef converter, const struct vImageCVConversion *cv,
                               const vImage_Buffer *srcs, const vImage_Buffer *dests, vImage_Flags flags)
{
    (void)converter, (void)cv, (void)srcs, (void)dests, (void)flags;
    return kvImageInternalError;
}
