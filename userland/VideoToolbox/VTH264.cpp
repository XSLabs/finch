/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "VTInternal.h"
#include <codec_api.h>
#include <codec_app_def.h>
#include <cstdlib>
#include <cstring>
#include <climits>
#include <new>
#include <vector>

struct Encoder {
    ISVCEncoder *api = nullptr;
    int width = 0;
    int height = 0;
};

struct Decoder {
    ISVCDecoder *api = nullptr;
};

static EProfileIdc
profile_for(CFStringRef profile)
{
    if (profile && CFEqual(profile, kVTProfileLevel_H264_Main_AutoLevel))
        return PRO_MAIN;
    if (profile && CFEqual(profile, kVTProfileLevel_H264_High_AutoLevel))
        return PRO_HIGH;
    return PRO_BASELINE;
}

extern "C" void *
_VTH264EncoderCreate(int width, int height, int frameRate, int bitrate, CFStringRef profile)
{
    if (width <= 0 || height <= 0 || (width & 1) || (height & 1))
        return nullptr;
    auto *encoder = new (std::nothrow) Encoder();
    if (!encoder)
        return nullptr;
    if (WelsCreateSVCEncoder(&encoder->api) != 0 || !encoder->api) {
        delete encoder;
        return nullptr;
    }
    encoder->width = width;
    encoder->height = height;
    SEncParamExt params{};
    if (encoder->api->GetDefaultParams(&params) != 0) {
        WelsDestroySVCEncoder(encoder->api);
        delete encoder;
        return nullptr;
    }
    params.iUsageType = CAMERA_VIDEO_REAL_TIME;
    params.iPicWidth = width;
    params.iPicHeight = height;
    params.iTargetBitrate = bitrate > 0 ? bitrate : width * height * 4;
    params.iMaxBitrate = INT32_MAX;
    params.iRCMode = RC_BITRATE_MODE;
    params.fMaxFrameRate = frameRate > 0 ? (float)frameRate : 30.0f;
    params.iTemporalLayerNum = 1;
    params.iSpatialLayerNum = 1;
    params.uiIntraPeriod = 30;
    params.iNumRefFrame = 1;
    params.iMultipleThreadIdc = 1;
    params.bEnableFrameSkip = true;
    params.bEnableSceneChangeDetect = false;
    params.eSpsPpsIdStrategy = CONSTANT_ID;
    params.sSpatialLayers[0].iVideoWidth = width;
    params.sSpatialLayers[0].iVideoHeight = height;
    params.sSpatialLayers[0].fFrameRate = params.fMaxFrameRate;
    params.sSpatialLayers[0].iSpatialBitrate = params.iTargetBitrate;
    params.sSpatialLayers[0].iMaxSpatialBitrate = INT32_MAX;
    params.sSpatialLayers[0].uiProfileIdc = profile_for(profile);
    params.sSpatialLayers[0].uiLevelIdc = LEVEL_UNKNOWN;
    if (encoder->api->InitializeExt(&params) != 0) {
        WelsDestroySVCEncoder(encoder->api);
        delete encoder;
        return nullptr;
    }
    int quiet = WELS_LOG_QUIET;
    encoder->api->SetOption(ENCODER_OPTION_TRACE_LEVEL, &quiet);
    return encoder;
}

extern "C" void
_VTH264EncoderDestroy(void *context)
{
    auto *encoder = static_cast<Encoder *>(context);
    if (!encoder)
        return;
    if (encoder->api) {
        encoder->api->Uninitialize();
        WelsDestroySVCEncoder(encoder->api);
    }
    delete encoder;
}

extern "C" OSStatus
_VTH264EncoderSetBitrate(void *context, int32_t bitrate)
{
    auto *encoder = static_cast<Encoder *>(context);
    if (!encoder || !encoder->api || bitrate <= 0)
        return kVTParameterErr;
    SBitrateInfo value{};
    value.iLayer = SPATIAL_LAYER_ALL;
    value.iBitrate = bitrate;
    if (encoder->api->SetOption(ENCODER_OPTION_BITRATE, &value) == 0)
        return noErr;
    return kVTPropertyNotSupportedErr;
}

extern "C" OSStatus
_VTH264EncoderSetFrameRate(void *context, int32_t frameRate)
{
    auto *encoder = static_cast<Encoder *>(context);
    if (!encoder || !encoder->api || frameRate <= 0)
        return kVTParameterErr;
    float value = (float)frameRate;
    if (encoder->api->SetOption(ENCODER_OPTION_FRAME_RATE, &value) == 0)
        return noErr;
    return kVTPropertyNotSupportedErr;
}

extern "C" OSStatus
_VTH264EncoderSetKeyFrameInterval(void *context, int32_t interval)
{
    auto *encoder = static_cast<Encoder *>(context);
    if (!encoder || !encoder->api || interval <= 0)
        return kVTParameterErr;
    if (encoder->api->SetOption(ENCODER_OPTION_IDR_INTERVAL, &interval) == 0)
        return noErr;
    return kVTPropertyNotSupportedErr;
}

extern "C" OSStatus
_VTH264EncoderSetProfile(void *context, CFStringRef profile)
{
    auto *encoder = static_cast<Encoder *>(context);
    if (!encoder || !encoder->api)
        return kVTInvalidSessionErr;
    SProfileInfo value{};
    value.iLayer = 0;
    value.uiProfileIdc = profile_for(profile);
    if (encoder->api->SetOption(ENCODER_OPTION_PROFILE, &value) == 0)
        return noErr;
    return kVTPropertyNotSupportedErr;
}

extern "C" OSStatus
_VTH264EncoderForceKeyFrame(void *context)
{
    auto *encoder = static_cast<Encoder *>(context);
    if (!encoder || !encoder->api)
        return kVTInvalidSessionErr;
    if (encoder->api->ForceIntraFrame(true) == 0)
        return noErr;
    return kVTVideoEncoderMalfunctionErr;
}

extern "C" OSStatus
_VTH264EncoderEncode(void *context, const uint8_t *y, const uint8_t *u, const uint8_t *v,
                     size_t yStride, size_t uStride, size_t vStride, int64_t timestamp,
                     uint8_t **bytesOut, size_t *lengthOut, Boolean *keyFrameOut)
{
    auto *encoder = static_cast<Encoder *>(context);
    if (!encoder || !encoder->api || !y || !u || !v || !bytesOut || !lengthOut || !keyFrameOut)
        return kVTParameterErr;
    *bytesOut = nullptr;
    *lengthOut = 0;
    *keyFrameOut = false;
    SSourcePicture picture{};
    picture.iColorFormat = videoFormatI420;
    picture.iPicWidth = encoder->width;
    picture.iPicHeight = encoder->height;
    picture.iStride[0] = (int)yStride;
    picture.iStride[1] = (int)uStride;
    picture.iStride[2] = (int)vStride;
    picture.pData[0] = const_cast<uint8_t *>(y);
    picture.pData[1] = const_cast<uint8_t *>(u);
    picture.pData[2] = const_cast<uint8_t *>(v);
    picture.uiTimeStamp = timestamp;
    SFrameBSInfo info{};
    int result = encoder->api->EncodeFrame(&picture, &info);
    if (result != 0)
        return kVTVideoEncoderMalfunctionErr;
    if (info.iFrameSizeInBytes <= 0)
        return noErr;
    std::vector<uint8_t> output;
    output.reserve((size_t)info.iFrameSizeInBytes + 16);
    for (int layer = 0; layer < info.iLayerNum; layer++) {
        const SLayerBSInfo &layerInfo = info.sLayerInfo[layer];
        size_t offset = 0;
        for (int nal = 0; nal < layerInfo.iNalCount; nal++) {
            int nalLength = layerInfo.pNalLengthInByte[nal];
            if (nalLength <= 0)
                continue;
            output.insert(output.end(), layerInfo.pBsBuf + offset, layerInfo.pBsBuf + offset + (size_t)nalLength);
            offset += (size_t)nalLength;
        }
        *keyFrameOut = *keyFrameOut || layerInfo.eFrameType == videoFrameTypeIDR || layerInfo.eFrameType == videoFrameTypeI;
    }
    if (output.empty())
        return kVTVideoEncoderMalfunctionErr;
    *bytesOut = (uint8_t *)malloc(output.size());
    if (!*bytesOut)
        return kVTAllocationFailedErr;
    memcpy(*bytesOut, output.data(), output.size());
    *lengthOut = output.size();
    return noErr;
}

extern "C" void *
_VTH264DecoderCreate(void)
{
    auto *decoder = new (std::nothrow) Decoder();
    if (!decoder)
        return nullptr;
    if (WelsCreateDecoder(&decoder->api) != 0 || !decoder->api) {
        delete decoder;
        return nullptr;
    }
    SDecodingParam params{};
    params.sVideoProperty.eVideoBsType = VIDEO_BITSTREAM_AVC;
    params.uiTargetDqLayer = 255;
    params.eEcActiveIdc = ERROR_CON_FRAME_COPY;
    if (decoder->api->Initialize(&params) != 0) {
        WelsDestroyDecoder(decoder->api);
        delete decoder;
        return nullptr;
    }
    return decoder;
}

extern "C" void
_VTH264DecoderDestroy(void *context)
{
    auto *decoder = static_cast<Decoder *>(context);
    if (!decoder)
        return;
    if (decoder->api) {
        decoder->api->Uninitialize();
        WelsDestroyDecoder(decoder->api);
    }
    delete decoder;
}

extern "C" OSStatus
_VTH264DecoderDecode(void *context, const uint8_t *bytes, size_t length, VTDecodedFrame *frame)
{
    auto *decoder = static_cast<Decoder *>(context);
    if (!decoder || !decoder->api || !bytes || !length || !frame || length > INT_MAX)
        return kVTParameterErr;
    memset(frame, 0, sizeof(*frame));
    uint8_t *planes[3] = {nullptr, nullptr, nullptr};
    SBufferInfo info{};
    DECODING_STATE state = decoder->api->DecodeFrameNoDelay(bytes, (int)length, planes, &info);
    if (state & (dsBitstreamError | dsInvalidArgument | dsOutOfMemory | dsDstBufNeedExpan))
        return kVTVideoDecoderBadDataErr;
    if (info.iBufferStatus != 1)
        return noErr;
    int width = info.UsrData.sSystemBuffer.iWidth;
    int height = info.UsrData.sSystemBuffer.iHeight;
    if (width <= 0 || height <= 0 || !planes[0] || !planes[1] || !planes[2])
        return kVTVideoDecoderMalfunctionErr;
    size_t chromaWidth = ((size_t)width + 1) / 2, chromaHeight = ((size_t)height + 1) / 2;
    size_t ySize = (size_t)width * height, chromaSize = chromaWidth * chromaHeight;
    frame->data = (uint8_t *)malloc(ySize + 2 * chromaSize);
    if (!frame->data)
        return kVTAllocationFailedErr;
    frame->width = width; frame->height = height;
    frame->size = ySize + 2 * chromaSize;
    frame->yStride = (size_t)width; frame->uStride = frame->vStride = chromaWidth;
    frame->bitsPerComponent = 8;
    const int *strides = info.UsrData.sSystemBuffer.iStride;
    for (int row = 0; row < height; row++)
        memcpy(frame->data + (size_t)row * frame->yStride, planes[0] + (size_t)row * strides[0], (size_t)width);
    for (size_t row = 0; row < chromaHeight; row++) {
        memcpy(frame->data + ySize + row * chromaWidth, planes[1] + row * (size_t)strides[1], chromaWidth);
        memcpy(frame->data + ySize + chromaSize + row * chromaWidth, planes[2] + row * (size_t)strides[2], chromaWidth);
    }
    return noErr;
}
