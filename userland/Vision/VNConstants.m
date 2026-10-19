// SPDX-License-Identifier: MIT OR Apache-2.0
#import "VNPrivate.h"

NSString *const VNErrorDomain = @"com.apple.Vision";
double VNVisionVersionNumber = 1.0;
const CGRect VNNormalizedIdentityRect = {{0.0, 0.0}, {1.0, 1.0}};

VNComputeStage const VNComputeStageMain = (VNComputeStage)@"VNComputeStageMain";
VNComputeStage const VNComputeStagePostProcessing = (VNComputeStage)@"VNComputeStagePostProcessing";

VNBarcodeSymbology const VNBarcodeSymbologyAztec = (VNBarcodeSymbology)@"VNBarcodeSymbologyAztec";
VNBarcodeSymbology const VNBarcodeSymbologyCode39 = (VNBarcodeSymbology)@"VNBarcodeSymbologyCode39";
VNBarcodeSymbology const VNBarcodeSymbologyCode39Checksum = (VNBarcodeSymbology)@"VNBarcodeSymbologyCode39Checksum";
VNBarcodeSymbology const VNBarcodeSymbologyCode39FullASCII = (VNBarcodeSymbology)@"VNBarcodeSymbologyCode39FullASCII";
VNBarcodeSymbology const VNBarcodeSymbologyCode39FullASCIIChecksum = (VNBarcodeSymbology)@"VNBarcodeSymbologyCode39FullASCIIChecksum";
VNBarcodeSymbology const VNBarcodeSymbologyCode93 = (VNBarcodeSymbology)@"VNBarcodeSymbologyCode93";
VNBarcodeSymbology const VNBarcodeSymbologyCode93i = (VNBarcodeSymbology)@"VNBarcodeSymbologyCode93i";
VNBarcodeSymbology const VNBarcodeSymbologyCode128 = (VNBarcodeSymbology)@"VNBarcodeSymbologyCode128";
VNBarcodeSymbology const VNBarcodeSymbologyDataMatrix = (VNBarcodeSymbology)@"VNBarcodeSymbologyDataMatrix";
VNBarcodeSymbology const VNBarcodeSymbologyEAN8 = (VNBarcodeSymbology)@"VNBarcodeSymbologyEAN8";
VNBarcodeSymbology const VNBarcodeSymbologyEAN13 = (VNBarcodeSymbology)@"VNBarcodeSymbologyEAN13";
VNBarcodeSymbology const VNBarcodeSymbologyI2of5 = (VNBarcodeSymbology)@"VNBarcodeSymbologyI2of5";
VNBarcodeSymbology const VNBarcodeSymbologyI2of5Checksum = (VNBarcodeSymbology)@"VNBarcodeSymbologyI2of5Checksum";
VNBarcodeSymbology const VNBarcodeSymbologyITF14 = (VNBarcodeSymbology)@"VNBarcodeSymbologyITF14";
VNBarcodeSymbology const VNBarcodeSymbologyPDF417 = (VNBarcodeSymbology)@"VNBarcodeSymbologyPDF417";
VNBarcodeSymbology const VNBarcodeSymbologyQR = (VNBarcodeSymbology)@"VNBarcodeSymbologyQR";
VNBarcodeSymbology const VNBarcodeSymbologyUPCE = (VNBarcodeSymbology)@"VNBarcodeSymbologyUPCE";
VNBarcodeSymbology const VNBarcodeSymbologyCodabar = (VNBarcodeSymbology)@"VNBarcodeSymbologyCodabar";
VNBarcodeSymbology const VNBarcodeSymbologyGS1DataBar = (VNBarcodeSymbology)@"VNBarcodeSymbologyGS1DataBar";
VNBarcodeSymbology const VNBarcodeSymbologyGS1DataBarExpanded = (VNBarcodeSymbology)@"VNBarcodeSymbologyGS1DataBarExpanded";
VNBarcodeSymbology const VNBarcodeSymbologyGS1DataBarLimited = (VNBarcodeSymbology)@"VNBarcodeSymbologyGS1DataBarLimited";
VNBarcodeSymbology const VNBarcodeSymbologyMicroPDF417 = (VNBarcodeSymbology)@"VNBarcodeSymbologyMicroPDF417";
VNBarcodeSymbology const VNBarcodeSymbologyMicroQR = (VNBarcodeSymbology)@"VNBarcodeSymbologyMicroQR";
VNBarcodeSymbology const VNBarcodeSymbologyMSIPlessey = (VNBarcodeSymbology)@"VNBarcodeSymbologyMSIPlessey";

VNImageOption const VNImageOptionProperties = (VNImageOption)@"VNImageOptionProperties";
VNImageOption const VNImageOptionCameraIntrinsics = (VNImageOption)@"VNImageOptionCameraIntrinsics";
VNImageOption const VNImageOptionCIContext = (VNImageOption)@"VNImageOptionCIContext";

VNRecognizedPointGroupKey const VNRecognizedPointGroupKeyAll = (VNRecognizedPointGroupKey)@"VNIPOAll";
VNRecognizedPointGroupKey const VNRecognizedPoint3DGroupKeyAll = (VNRecognizedPointGroupKey)@"VNIPOAll";

VNVideoProcessingOption const VNVideoProcessingOptionFrameCadence = (VNVideoProcessingOption)@"VNVideoProcessingOptionFrameCadence";
VNVideoProcessingOption const VNVideoProcessingOptionTimeInterval = (VNVideoProcessingOption)@"VNVideoProcessingOptionTimeInterval";

VNAnimalIdentifier const VNAnimalIdentifierCat = (VNAnimalIdentifier)@"cat";
VNAnimalIdentifier const VNAnimalIdentifierDog = (VNAnimalIdentifier)@"dog";

