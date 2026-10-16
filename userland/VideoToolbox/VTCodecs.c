/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "VTInternal.h"
#include <dav1d/dav1d.h>
#include <vpx/vp8dx.h>
#include <vpx/vpx_decoder.h>
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    vpx_codec_ctx_t context;
    Boolean initialized;
} VTVpxDecoder;

typedef struct {
    Dav1dContext *context;
} VTDav1dDecoder;

void
_VTDecodedFrameFree(VTDecodedFrame *frame)
{
    if (!frame) return;
    free(frame->data);
    memset(frame, 0, sizeof(*frame));
}

static OSStatus
copy_vpx_image(const vpx_image_t *image, VTDecodedFrame *frame)
{
    if (!image || !frame || image->d_w == 0 || image->d_h == 0)
        return kVTVideoDecoderBadDataErr;
    if (image->fmt != VPX_IMG_FMT_I420 && image->fmt != VPX_IMG_FMT_YV12 && image->fmt != VPX_IMG_FMT_I42016)
        return kVTVideoDecoderUnsupportedDataFormatErr;
    size_t width = image->d_w, height = image->d_h;
    size_t chromaWidth = (width + 1) / 2, chromaHeight = (height + 1) / 2;
    size_t ySize = width * height, chromaSize = chromaWidth * chromaHeight;
    uint8_t *data = malloc(ySize + chromaSize * 2);
    if (!data)
        return kVTAllocationFailedErr;
    int highBit = image->fmt == VPX_IMG_FMT_I42016;
    unsigned shift = image->bit_depth > 8 ? image->bit_depth - 8 : 0;
    const uint8_t *uPlane = image->planes[VPX_PLANE_U];
    const uint8_t *vPlane = image->planes[VPX_PLANE_V];
    if (image->fmt == VPX_IMG_FMT_YV12) {
        uPlane = image->planes[VPX_PLANE_V];
        vPlane = image->planes[VPX_PLANE_U];
    }
    for (size_t y = 0; y < height; y++) {
        if (highBit) {
            const uint16_t *src = (const uint16_t *)(image->planes[VPX_PLANE_Y] + y * image->stride[VPX_PLANE_Y]);
            for (size_t x = 0; x < width; x++) data[y * width + x] = (uint8_t)(src[x] >> shift);
        } else {
            memcpy(data + y * width, image->planes[VPX_PLANE_Y] + y * image->stride[VPX_PLANE_Y], width);
        }
    }
    for (size_t y = 0; y < chromaHeight; y++) for (size_t x = 0; x < chromaWidth; x++) {
        size_t index = y * chromaWidth + x;
        if (highBit) {
            const uint16_t *u = (const uint16_t *)(uPlane + y * image->stride[VPX_PLANE_U]);
            const uint16_t *v = (const uint16_t *)(vPlane + y * image->stride[VPX_PLANE_V]);
            data[ySize + index] = (uint8_t)(u[x] >> shift);
            data[ySize + chromaSize + index] = (uint8_t)(v[x] >> shift);
        } else {
            data[ySize + index] = uPlane[y * image->stride[VPX_PLANE_U] + x];
            data[ySize + chromaSize + index] = vPlane[y * image->stride[VPX_PLANE_V] + x];
        }
    }
    _VTDecodedFrameFree(frame);
    frame->width = (int32_t)width;
    frame->height = (int32_t)height;
    frame->data = data;
    frame->size = ySize + chromaSize * 2;
    frame->yStride = width;
    frame->uStride = frame->vStride = chromaWidth;
    frame->bitsPerComponent = highBit ? (int)image->bit_depth : 8;
    return noErr;
}

void *
_VTVpxDecoderCreate(CMVideoCodecType codecType, int threads)
{
    vpx_codec_iface_t *iface = codecType == kCMVideoCodecType_VP9 ? vpx_codec_vp9_dx() :
                               codecType == VTCodecTypeVP8 ? vpx_codec_vp8_dx() : NULL;
    if (!iface)
        return NULL;
    VTVpxDecoder *decoder = calloc(1, sizeof(*decoder));
    if (!decoder)
        return NULL;
    vpx_codec_dec_cfg_t config = {(unsigned int)(threads > 0 ? threads : 1), 0, 0};
    if (vpx_codec_dec_init(&decoder->context, iface, &config, 0) != VPX_CODEC_OK) {
        free(decoder);
        return NULL;
    }
    decoder->initialized = true;
    return decoder;
}

void
_VTVpxDecoderDestroy(void *context)
{
    VTVpxDecoder *decoder = context;
    if (!decoder) return;
    if (decoder->initialized) vpx_codec_destroy(&decoder->context);
    free(decoder);
}

OSStatus
_VTVpxDecoderDecode(void *context, const uint8_t *bytes, size_t length, VTDecodedFrame *frame)
{
    VTVpxDecoder *decoder = context;
    if (!decoder || !decoder->initialized || !bytes || !length || length > UINT_MAX || !frame)
        return kVTParameterErr;
    if (vpx_codec_decode(&decoder->context, bytes, (unsigned int)length, NULL, 0) != VPX_CODEC_OK)
        return kVTVideoDecoderBadDataErr;
    vpx_codec_iter_t iterator = NULL;
    vpx_image_t *image;
    while ((image = vpx_codec_get_frame(&decoder->context, &iterator)) != NULL) {
        OSStatus status = copy_vpx_image(image, frame);
        if (status != noErr) return status;
    }
    return noErr;
}

void *
_VTDav1dDecoderCreate(int threads)
{
    VTDav1dDecoder *decoder = calloc(1, sizeof(*decoder));
    if (!decoder)
        return NULL;
    Dav1dSettings settings;
    dav1d_default_settings(&settings);
    settings.n_threads = threads > 0 ? threads : 1;
    settings.max_frame_delay = 1;
    settings.apply_grain = 1;
    if (dav1d_open(&decoder->context, &settings) < 0) {
        free(decoder);
        return NULL;
    }
    return decoder;
}

void
_VTDav1dDecoderDestroy(void *context)
{
    VTDav1dDecoder *decoder = context;
    if (!decoder) return;
    dav1d_close(&decoder->context);
    free(decoder);
}

static OSStatus
copy_dav1d_picture(const Dav1dPicture *picture, VTDecodedFrame *frame)
{
    if (!picture || !frame || picture->p.w <= 0 || picture->p.h <= 0 || picture->p.layout != DAV1D_PIXEL_LAYOUT_I420)
        return kVTVideoDecoderUnsupportedDataFormatErr;
    size_t width = (size_t)picture->p.w, height = (size_t)picture->p.h;
    size_t chromaWidth = (width + 1) / 2, chromaHeight = (height + 1) / 2;
    size_t ySize = width * height, chromaSize = chromaWidth * chromaHeight;
    uint8_t *data = malloc(ySize + 2 * chromaSize);
    if (!data)
        return kVTAllocationFailedErr;
    if (picture->p.bpc == 8) {
        for (size_t y = 0; y < height; y++)
            memcpy(data + y * width, (const uint8_t *)picture->data[0] + y * (size_t)picture->stride[0], width);
        for (size_t y = 0; y < chromaHeight; y++) {
            memcpy(data + ySize + y * chromaWidth, (const uint8_t *)picture->data[1] + y * (size_t)picture->stride[1], chromaWidth);
            memcpy(data + ySize + chromaSize + y * chromaWidth, (const uint8_t *)picture->data[2] + y * (size_t)picture->stride[1], chromaWidth);
        }
    } else if (picture->p.bpc == 10) {
        for (size_t y = 0; y < height; y++) {
            const uint16_t *src = (const uint16_t *)((const uint8_t *)picture->data[0] + y * (size_t)picture->stride[0]);
            for (size_t x = 0; x < width; x++) data[y * width + x] = (uint8_t)((src[x] + 2) >> 2);
        }
        for (size_t y = 0; y < chromaHeight; y++) {
            const uint16_t *u = (const uint16_t *)((const uint8_t *)picture->data[1] + y * (size_t)picture->stride[1]);
            const uint16_t *v = (const uint16_t *)((const uint8_t *)picture->data[2] + y * (size_t)picture->stride[1]);
            for (size_t x = 0; x < chromaWidth; x++) {
                data[ySize + y * chromaWidth + x] = (uint8_t)((u[x] + 2) >> 2);
                data[ySize + chromaSize + y * chromaWidth + x] = (uint8_t)((v[x] + 2) >> 2);
            }
        }
    } else {
        free(data);
        return kVTVideoDecoderUnsupportedDataFormatErr;
    }
    _VTDecodedFrameFree(frame);
    frame->width = (int32_t)width;
    frame->height = (int32_t)height;
    frame->data = data;
    frame->size = ySize + 2 * chromaSize;
    frame->yStride = width;
    frame->uStride = frame->vStride = chromaWidth;
    frame->bitsPerComponent = picture->p.bpc;
    return noErr;
}

OSStatus
_VTDav1dDecoderDecode(void *context, const uint8_t *bytes, size_t length, VTDecodedFrame *frame)
{
    VTDav1dDecoder *decoder = context;
    if (!decoder || !decoder->context || !bytes || !length || !frame)
        return kVTParameterErr;
    Dav1dData data = {0};
    uint8_t *copy = dav1d_data_create(&data, length);
    if (!copy)
        return kVTAllocationFailedErr;
    memcpy(copy, bytes, length);
    int result = dav1d_send_data(decoder->context, &data);
    if (result == -EAGAIN) {
        Dav1dPicture ready = {0};
        while (dav1d_get_picture(decoder->context, &ready) == 0) {
            OSStatus status = copy_dav1d_picture(&ready, frame);
            dav1d_picture_unref(&ready);
            if (status != noErr) { dav1d_data_unref(&data); return status; }
        }
        result = dav1d_send_data(decoder->context, &data);
    }
    dav1d_data_unref(&data);
    if (result < 0)
        return kVTVideoDecoderBadDataErr;
    Dav1dPicture picture = {0};
    while (dav1d_get_picture(decoder->context, &picture) == 0) {
        OSStatus status = copy_dav1d_picture(&picture, frame);
        dav1d_picture_unref(&picture);
        if (status != noErr) return status;
    }
    return noErr;
}
