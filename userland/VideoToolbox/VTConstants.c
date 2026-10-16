/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include <VideoToolbox/VideoToolbox.h>

/* VideoToolbox exposes these names as stable CFString values. */
const CFStringRef kVTVideoEncoderSpecification_EncoderID = CFSTR("EncoderID");
const CFStringRef kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder = CFSTR("EnableHardwareAcceleratedVideoDecoder");
const CFStringRef kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder = CFSTR("RequireHardwareAcceleratedVideoDecoder");
const CFStringRef kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder = CFSTR("EnableHardwareAcceleratedVideoEncoder");
const CFStringRef kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder = CFSTR("RequireHardwareAcceleratedVideoEncoder");
const CFStringRef kVTVideoEncoderSpecification_EnableLowLatencyRateControl = CFSTR("EnableLowLatencyRateControl");

const CFStringRef kVTPropertyTypeKey = CFSTR("Type");
const CFStringRef kVTPropertyType_Enumeration = CFSTR("Enumeration");
const CFStringRef kVTPropertyType_Boolean = CFSTR("Boolean");
const CFStringRef kVTPropertyType_Number = CFSTR("Number");
const CFStringRef kVTPropertyReadWriteStatusKey = CFSTR("ReadWriteStatus");
const CFStringRef kVTPropertyReadWriteStatus_ReadOnly = CFSTR("ReadOnly");
const CFStringRef kVTPropertyReadWriteStatus_ReadWrite = CFSTR("ReadWrite");
const CFStringRef kVTPropertyShouldBeSerializedKey = CFSTR("ShouldBeSerialized");
const CFStringRef kVTPropertySupportedValueMinimumKey = CFSTR("SupportedValueMinimum");
const CFStringRef kVTPropertySupportedValueMaximumKey = CFSTR("SupportedValueMaximum");
const CFStringRef kVTPropertySupportedValueListKey = CFSTR("SupportedValueList");
const CFStringRef kVTPropertyDocumentationKey = CFSTR("Documentation");

const CFStringRef kVTCompressionPropertyKey_AllowFrameReordering = CFSTR("AllowFrameReordering");
const CFStringRef kVTCompressionPropertyKey_AverageBitRate = CFSTR("AverageBitRate");
const CFStringRef kVTCompressionPropertyKey_BaseLayerFrameRateFraction = CFSTR("BaseLayerFrameRateFraction");
const CFStringRef kVTCompressionPropertyKey_CalculateMeanSquaredError = CFSTR("CalculateMeanSquaredError");
const CFStringRef kVTCompressionPropertyKey_ColorPrimaries = CFSTR("ColorPrimaries");
const CFStringRef kVTCompressionPropertyKey_ContentLightLevelInfo = CFSTR("ContentLightLevelInfo");
const CFStringRef kVTCompressionPropertyKey_DataRateLimits = CFSTR("DataRateLimits");
const CFStringRef kVTCompressionPropertyKey_EncoderID = CFSTR("EncoderID");
const CFStringRef kVTCompressionPropertyKey_ExpectedFrameRate = CFSTR("ExpectedFrameRate");
const CFStringRef kVTCompressionPropertyKey_HDRMetadataInsertionMode = CFSTR("HDRMetadataInsertionMode");
const CFStringRef kVTCompressionPropertyKey_MasteringDisplayColorVolume = CFSTR("MasteringDisplayColorVolume");
const CFStringRef kVTCompressionPropertyKey_MaxFrameDelayCount = CFSTR("MaxFrameDelayCount");
const CFStringRef kVTCompressionPropertyKey_MaxKeyFrameInterval = CFSTR("MaxKeyFrameInterval");
const CFStringRef kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration = CFSTR("MaxKeyFrameIntervalDuration");
const CFStringRef kVTCompressionPropertyKey_OutputBitDepth = CFSTR("OutputBitDepth");
const CFStringRef kVTCompressionPropertyKey_PixelTransferProperties = CFSTR("PixelTransferProperties");
const CFStringRef kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality = CFSTR("PrioritizeEncodingSpeedOverQuality");
const CFStringRef kVTCompressionPropertyKey_ProfileLevel = CFSTR("ProfileLevel");
const CFStringRef kVTCompressionPropertyKey_RealTime = CFSTR("RealTime");
const CFStringRef kVTCompressionPropertyKey_ReferenceBufferCount = CFSTR("ReferenceBufferCount");
const CFStringRef kVTCompressionPropertyKey_TransferFunction = CFSTR("TransferFunction");
const CFStringRef kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder = CFSTR("UsingHardwareAcceleratedVideoEncoder");
const CFStringRef kVTCompressionPropertyKey_YCbCrMatrix = CFSTR("YCbCrMatrix");

const CFStringRef kVTEncodeFrameOptionKey_BaseFrameQP = CFSTR("BaseFrameQP");
const CFStringRef kVTEncodeFrameOptionKey_ForceKeyFrame = CFSTR("ForceKeyFrame");
const CFStringRef kVTHDRMetadataInsertionMode_Auto = CFSTR("Auto");

#define VT_PROFILE(name, value) const CFStringRef name = CFSTR(value)
VT_PROFILE(kVTProfileLevel_H264_Baseline_AutoLevel, "H264_Baseline_AutoLevel");
VT_PROFILE(kVTProfileLevel_H264_Baseline_3_0, "H264_Baseline_3_0");
VT_PROFILE(kVTProfileLevel_H264_Baseline_3_1, "H264_Baseline_3_1");
VT_PROFILE(kVTProfileLevel_H264_Baseline_3_2, "H264_Baseline_3_2");
VT_PROFILE(kVTProfileLevel_H264_Baseline_4_0, "H264_Baseline_4_0");
VT_PROFILE(kVTProfileLevel_H264_Baseline_4_1, "H264_Baseline_4_1");
VT_PROFILE(kVTProfileLevel_H264_Baseline_4_2, "H264_Baseline_4_2");
VT_PROFILE(kVTProfileLevel_H264_Baseline_5_0, "H264_Baseline_5_0");
VT_PROFILE(kVTProfileLevel_H264_Baseline_5_1, "H264_Baseline_5_1");
VT_PROFILE(kVTProfileLevel_H264_Baseline_5_2, "H264_Baseline_5_2");
VT_PROFILE(kVTProfileLevel_H264_Main_AutoLevel, "H264_Main_AutoLevel");
VT_PROFILE(kVTProfileLevel_H264_Main_3_0, "H264_Main_3_0");
VT_PROFILE(kVTProfileLevel_H264_Main_3_1, "H264_Main_3_1");
VT_PROFILE(kVTProfileLevel_H264_Main_3_2, "H264_Main_3_2");
VT_PROFILE(kVTProfileLevel_H264_Main_4_0, "H264_Main_4_0");
VT_PROFILE(kVTProfileLevel_H264_Main_4_1, "H264_Main_4_1");
VT_PROFILE(kVTProfileLevel_H264_Main_4_2, "H264_Main_4_2");
VT_PROFILE(kVTProfileLevel_H264_Main_5_0, "H264_Main_5_0");
VT_PROFILE(kVTProfileLevel_H264_Main_5_1, "H264_Main_5_1");
VT_PROFILE(kVTProfileLevel_H264_Main_5_2, "H264_Main_5_2");
VT_PROFILE(kVTProfileLevel_H264_High_AutoLevel, "H264_High_AutoLevel");
VT_PROFILE(kVTProfileLevel_H264_High_3_0, "H264_High_3_0");
VT_PROFILE(kVTProfileLevel_H264_High_3_1, "H264_High_3_1");
VT_PROFILE(kVTProfileLevel_H264_High_3_2, "H264_High_3_2");
VT_PROFILE(kVTProfileLevel_H264_High_4_0, "H264_High_4_0");
VT_PROFILE(kVTProfileLevel_H264_High_4_1, "H264_High_4_1");
VT_PROFILE(kVTProfileLevel_H264_High_4_2, "H264_High_4_2");
VT_PROFILE(kVTProfileLevel_H264_High_5_0, "H264_High_5_0");
VT_PROFILE(kVTProfileLevel_H264_High_5_1, "H264_High_5_1");
VT_PROFILE(kVTProfileLevel_H264_High_5_2, "H264_High_5_2");
VT_PROFILE(kVTProfileLevel_HEVC_Main_AutoLevel, "HEVC_Main_AutoLevel");
VT_PROFILE(kVTProfileLevel_HEVC_Main10_AutoLevel, "HEVC_Main10_AutoLevel");
VT_PROFILE(kVTProfileLevel_HEVC_Main42210_AutoLevel, "HEVC_Main42210_AutoLevel");

const CFStringRef kVTSampleAttachmentKey_QualityMetrics = CFSTR("QualityMetrics");
const CFStringRef kVTSampleAttachmentQualityMetricsKey_ChromaBlueMeanSquaredError = CFSTR("ChromaBlueMeanSquaredError");
const CFStringRef kVTSampleAttachmentQualityMetricsKey_ChromaRedMeanSquaredError = CFSTR("ChromaRedMeanSquaredError");
const CFStringRef kVTSampleAttachmentQualityMetricsKey_LumaMeanSquaredError = CFSTR("LumaMeanSquaredError");

const CFStringRef kVTPixelTransferPropertyKey_ScalingMode = CFSTR("ScalingMode");
const CFStringRef kVTScalingMode_Normal = CFSTR("Normal");
const CFStringRef kVTScalingMode_CropSourceToCleanAperture = CFSTR("CropSourceToCleanAperture");
const CFStringRef kVTScalingMode_Letterbox = CFSTR("Letterbox");
const CFStringRef kVTScalingMode_Trim = CFSTR("Trim");
const CFStringRef kVTPixelTransferPropertyKey_DestinationCleanAperture = CFSTR("DestinationCleanAperture");
const CFStringRef kVTPixelTransferPropertyKey_DestinationPixelAspectRatio = CFSTR("DestinationPixelAspectRatio");
const CFStringRef kVTPixelTransferPropertyKey_DownsamplingMode = CFSTR("DownsamplingMode");
const CFStringRef kVTDownsamplingMode_Decimate = CFSTR("Decimate");
const CFStringRef kVTDownsamplingMode_Average = CFSTR("Average");
const CFStringRef kVTPixelTransferPropertyKey_DestinationColorPrimaries = CFSTR("DestinationColorPrimaries");
const CFStringRef kVTPixelTransferPropertyKey_DestinationTransferFunction = CFSTR("DestinationTransferFunction");
const CFStringRef kVTPixelTransferPropertyKey_DestinationICCProfile = CFSTR("DestinationICCProfile");
const CFStringRef kVTPixelTransferPropertyKey_DestinationYCbCrMatrix = CFSTR("DestinationYCbCrMatrix");
const CFStringRef kVTPixelTransferPropertyKey_RealTime = CFSTR("RealTime");

const CFStringRef kVTPixelRotationPropertyKey_Rotation = CFSTR("Rotation");
const CFStringRef kVTImageRotationPropertyKey_Rotation = CFSTR("Rotation");
const CFStringRef kVTRotation_0 = CFSTR("0");
const CFStringRef kVTRotation_CW90 = CFSTR("90");
const CFStringRef kVTRotation_180 = CFSTR("180");
const CFStringRef kVTRotation_CCW90 = CFSTR("270");
const CFStringRef kVTPixelRotationPropertyKey_FlipHorizontalOrientation = CFSTR("FlipHorizontalOrientation");
const CFStringRef kVTPixelRotationPropertyKey_FlipVerticalOrientation = CFSTR("FlipVerticalOrientation");

const CFStringRef kVTVideoEncoderListOption_IncludeStandardDefinitionDVEncoders = CFSTR("IncludeStandardDefinitionDVEncoders");
const CFStringRef kVTVideoEncoderList_CodecType = CFSTR("CodecType");
const CFStringRef kVTVideoEncoderList_EncoderID = CFSTR("EncoderID");
const CFStringRef kVTVideoEncoderList_CodecName = CFSTR("CodecName");
const CFStringRef kVTVideoEncoderList_EncoderName = CFSTR("EncoderName");
const CFStringRef kVTVideoEncoderList_DisplayName = CFSTR("DisplayName");
const CFStringRef kVTVideoEncoderList_GPURegistryID = CFSTR("GPURegistryID");
const CFStringRef kVTVideoEncoderList_SupportedSelectionProperties = CFSTR("SupportedSelectionProperties");
const CFStringRef kVTVideoEncoderList_PerformanceRating = CFSTR("PerformanceRating");
const CFStringRef kVTVideoEncoderList_QualityRating = CFSTR("QualityRating");
const CFStringRef kVTVideoEncoderList_InstanceLimit = CFSTR("InstanceLimit");
const CFStringRef kVTVideoEncoderList_IsHardwareAccelerated = CFSTR("IsHardwareAccelerated");
const CFStringRef kVTVideoEncoderList_SupportsFrameReordering = CFSTR("SupportsFrameReordering");
const CFStringRef kVTVideoEncoderList_SupportsMultiPass = CFSTR("SupportsMultiPass");

const CFStringRef kVTExtensionProperties_ExtensionIdentifierKey = CFSTR("ExtensionIdentifier");
const CFStringRef kVTExtensionProperties_ExtensionNameKey = CFSTR("ExtensionName");
const CFStringRef kVTExtensionProperties_ContainingBundleNameKey = CFSTR("ContainingBundleName");
const CFStringRef kVTExtensionProperties_ExtensionURLKey = CFSTR("ExtensionURL");
const CFStringRef kVTExtensionProperties_ContainingBundleURLKey = CFSTR("ContainingBundleURL");
