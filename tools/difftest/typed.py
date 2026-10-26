#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Build safe, type-driven cases from Clang's SDK declaration details."""
from __future__ import annotations

import json
import re
from collections import Counter
from pathlib import Path


MAX_CASES = 8


FRAMEWORK_SCOPES = {
    "Security": {
        "functions": {
            "SecCertificateCopyData", "SecCertificateCopyKey", "SecCertificateCopyNormalizedIssuerSequence",
            "SecCertificateCopyNormalizedSubjectSequence", "SecCertificateCopySerialNumberData",
            "SecCertificateCopySubjectSummary", "SecCertificateCopyValues", "SecCertificateCreateWithData",
            "SecCertificateGetTypeID", "SecKeyCopyAttributes", "SecKeyCopyExternalRepresentation",
            "SecKeyCopyKeyExchangeResult", "SecKeyCopyPublicKey", "SecKeyCreateDecryptedData",
            "SecKeyCreateEncryptedData", "SecKeyCreateSignature", "SecKeyCreateWithData",
            "SecKeyGetBlockSize", "SecKeyGetTypeID", "SecKeyIsAlgorithmSupported", "SecKeyVerifySignature",
            "SecPolicyCopyProperties", "SecPolicyCreateBasicX509", "SecPolicyCreateSSL",
            "SecPolicyCreateWithProperties", "SecPolicyGetTypeID", "SecRandomCopyBytes",
            "SecTrustCopyProperties", "SecTrustCopyPublicKey", "SecTrustCreateWithCertificates",
            "SecTrustEvaluateWithError", "SecTrustGetTrustResult", "SecTrustGetTypeID",
            "SecTrustSetAnchorCertificates", "SecTrustSetPolicies", "SecTrustSetVerifyDate",
        },
        "variables": ("kSecAttrCan", "kSecAttrEffectiveKeySize", "kSecAttrIsPermanent", "kSecAttrKeyClass",
                       "kSecAttrKeySizeInBits", "kSecAttrKeyType", "kSecKeyAlgorithmECDHKeyExchange",
                       "kSecKeyAlgorithmECDSASignature", "kSecKeyAlgorithmRSAEncryptionOAEP",
                       "kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256", "kSecOIDX509V1",
                       "kSecPolicyAppleSSL", "kSecPolicyAppleX509Basic", "kSecPolicyClient", "kSecPolicyName",
                       "kSecPolicyOid", "kSecRandomDefault"),
    },
    "CoreVideo": {
        "prefixes": ("CVBuffer", "CVImageBuffer", "CVPixelBuffer", "CVPixelFormatDescription"),
        "variables": ("kCVImageBuffer", "kCVPixelBuffer", "kCVPixelFormat", "kCVAttachmentMode"),
    },
    "CoreMedia": {
        "prefixes": ("CMTime", "CMTimeRange", "CMTimeMapping", "CMBlockBuffer", "CMSampleBuffer",
                     "CMFormatDescription", "CMVideoFormatDescription", "CMClock", "CMTimebase"),
        "variables": ("kCMTime", "kCMMediaType", "kCMVideoCodecType", "kCMTimeRoundingMethod"),
    },
    "CoreServices": {
        "functions": {
            "FSCompareFSRefs", "FSIsFSRefValid", "FSPathMakeRef", "FSPathMakeRefWithOptions", "FSRefMakePath",
            "LSCopyDisplayNameForURL", "LSCopyItemInfoForURL", "UTTypeConformsTo", "UTTypeCopyAllTagsWithClass",
            "UTTypeCopyDeclaration", "UTTypeCopyDescription", "UTTypeCopyPreferredTagWithClass",
            "UTTypeCreateAllIdentifiersForTag", "UTTypeCreatePreferredIdentifierForTag", "UTTypeEqual",
            "UTTypeIsDeclared", "UTTypeIsDynamic",
        },
        "variables": ("kUTTagClass", "kUTType"),
    },
    "QuartzCore": {
        "prefixes": ("CATransform3D",),
        "variables": ("kCA",),
    },
    "CoreImage": {
        "variables": ("kCI",),
    },
    "UniformTypeIdentifiers": {
        "prefixes": ("UTType",),
        "variables": ("kUTType", "kUTTagClass"),
    },
    "CFNetwork": {
        "prefixes": ("CFHTTPMessage",),
        "variables": ("kCFStreamPropertyHTTP", "kCFStreamPropertySSL"),
    },
    "ColorSync": {
        "variables": ("kColorSync", "kCM"),
    },
    "Contacts": {
        "variables": ("CN",),
    },
    "CoreData": {
        "variables": ("NS",),
    },
    "CoreLocation": {"functions": set(), "variables": ()},
    "Network": {
        "functions": {
            "nw_endpoint_create_host", "nw_endpoint_get_type", "nw_endpoint_get_hostname",
            "nw_endpoint_get_port", "nw_endpoint_is_equal", "nw_protocol_copy_tcp_definition",
            "nw_protocol_copy_tls_definition", "nw_protocol_copy_udp_definition",
        },
        "variables": ("kNW",),
    },
    "Metal": {
        "variables": ("MTL", "kMTL"),
    },
    "CoreSpotlight": {
        "variables": ("CS",),
    },
    "AVFAudio": {
        "variables": ("AVAudio",),
    },
    "PDFKit": {"variables": ("PDF", "kPDF")},
    "Quartz/PDFKit": {"variables": ("PDF", "kPDF")},
    "Quartz": {
        "functions": {
            "CVColorPrimariesGetIntegerCodePointForString", "CVColorPrimariesGetStringForIntegerCodePoint",
            "CVImageBufferCreateColorSpaceFromAttachments", "CVTransferFunctionGetIntegerCodePointForString",
            "CVTransferFunctionGetStringForIntegerCodePoint", "CVYCbCrMatrixGetIntegerCodePointForString",
            "CVYCbCrMatrixGetStringForIntegerCodePoint",
        },
        "prefixes": ("CATransform3D",),
        "variables": ("k", "CA", "CI", "IK", "PDF", "QC", "QL"),
    },
    "Quartz/ImageKit": {"variables": ("IK",)},
    "AVFoundation": {
        "functions": {"AVMakeRectWithAspectRatioInsideRect"},
        "variables": ("AV",),
    },
    "AudioToolbox": {"variables": ("kAudio", "kAudioUnit", "kAudioComponent")},
    "CoreMIDI": {"variables": ("MIDI", "kMIDI")},
    "IOKit": {
        "functions": {"IOCFSerialize", "IOCFUnserialize", "IOCFUnserializeBinary", "IOCFUnserializeWithSize",
                       "IOHIDManagerGetTypeID", "IOHIDValueGetTypeID",
                       "IORegistryEntryIDMatching", "IOServiceMatching", "IOServiceNameMatching"},
        "variables": ("kIO",),
    },
    "SystemConfiguration": {
        "functions": {
            "SCBondStatusGetTypeID", "SCCopyLastError", "SCDynamicStoreGetTypeID",
            "SCDynamicStoreKeyCreateComputerName", "SCDynamicStoreKeyCreateConsoleUser",
            "SCDynamicStoreKeyCreateHostNames", "SCDynamicStoreKeyCreateLocation", "SCError",
            "SCErrorString", "SCPreferencesGetTypeID",
        },
        "variables": ("kSC", "kCFErrorDomainSystemConfiguration"),
    },
    "OpenDirectory": {"variables": ("OD",)},
    "OpenDirectory/CFOpenDirectory": {"variables": ("kOD",)},
    "StoreKit": {"variables": ("SK",)},
    "LinkPresentation": {"variables": ("LP",)},
    "Accelerate": {"prefixes": ("vDSP", "vForce", "vImage"), "variables": ("kvImage",)},
}


def _framework_scope_reason(framework: str, name: str, *, variable: bool = False) -> str | None:
    scope = FRAMEWORK_SCOPES.get(framework)
    if not scope:
        return None
    if framework == "CoreLocation":
        return "loading Finch CoreLocation aborts because its Objective-C classes collide with Apple's private location framework"
    if framework == "CoreMedia":
        if name in {"CMClockGetTime", "CMClockGetAnchorTime"}:
            return "reads the live host clock, so its value changes between the two runs"
        if name == "CMClockInvalidate":
            return "would invalidate the process-wide host clock used by other tests"
        if name == "CMTimeCodeFormatDescriptionCreate":
            return "needs a valid timecode format description, which the shared inputs do not build"
    if variable:
        if any(name.startswith(prefix) for prefix in scope.get("variables", ())):
            return None
    elif name in scope.get("functions", ()) or any(name.startswith(prefix) for prefix in scope.get("prefixes", ())):
        if framework == "CoreMedia" and name.endswith("Show"):
            return "diagnostic output is outside the selected CoreMedia scope"
        if framework == "CoreMedia" and re.search(r"Timer|DispatchSource|Queue|MemoryPool", name):
            return "needs a run loop, dispatch source, or queue model outside this comparison"
        return None
    if framework == "Security" and name.startswith("SecItem"):
        return "keychain APIs are outside this test because they use persistent user data"
    if framework == "CoreServices" and name.startswith("LSCopy"):
        return "depends on the host's installed applications or default handlers"
    return f"outside the selected deterministic {framework} API scope"


VALUE_CLASS_SCOPES = {
    "CoreImage": {
        "CIColor", "CIContext", "CIFilter", "CIFilterShape", "CIImage", "CIImageAccumulator", "CIVector",
        "CIKernel", "CIColorKernel", "CIWarpKernel", "CIBlendKernel", "CIQRCodeDescriptor",
        "CIAztecCodeDescriptor", "CIPDF417CodeDescriptor", "CIDataMatrixCodeDescriptor",
    },
    "Contacts": {
        "CNContact", "CNMutableContact", "CNContactFormatter", "CNPhoneNumber", "CNLabeledValue",
        "CNPostalAddress", "CNMutablePostalAddress", "CNPostalAddressFormatter", "CNSocialProfile",
    },
    "CoreData": {
        "NSFetchRequest", "NSExpressionDescription", "NSEntityDescription", "NSPropertyDescription",
        "NSAttributeDescription", "NSRelationshipDescription", "NSFetchedPropertyDescription",
        "NSManagedObjectModel", "NSEntityMapping", "NSPropertyMapping", "NSMappingModel",
        "NSFetchIndexDescription", "NSFetchIndexElementDescription", "NSPersistentStoreDescription",
        "NSBatchUpdateRequest", "NSBatchDeleteRequest", "NSMergePolicy",
    },
    "CoreLocation": {"CLLocation", "CLCircularRegion", "CLRegion", "CLVisit", "CLHeading", "CLPlacemark"},
    "Metal": {
        "MTLTextureDescriptor", "MTLRenderPassDescriptor", "MTLRenderPipelineDescriptor",
        "MTLComputePipelineDescriptor", "MTLDepthStencilDescriptor", "MTLStencilDescriptor",
        "MTLSamplerDescriptor", "MTLVertexDescriptor", "MTLVertexAttributeDescriptor",
        "MTLVertexBufferLayoutDescriptor", "MTLRenderPipelineColorAttachmentDescriptor",
        "MTLArgumentDescriptor", "MTLIndirectCommandBufferDescriptor", "MTLFunctionConstantValues",
    },
    "CoreSpotlight": {
        "CSSearchableItemAttributeSet", "CSSearchableItem", "CSLocalizedString",
        "CSPerson", "CSCustomAttributeKey",
    },
    "AVFAudio": {
        "AVAudioFormat", "AVAudioChannelLayout", "AVAudioTime", "AVAudioPCMBuffer",
        "AVAudioCompressedBuffer", "AVAudioConverter", "AVAudioEngine",
    },
    "PDFKit": {
        "PDFDocument", "PDFPage", "PDFSelection", "PDFDestination", "PDFOutline", "PDFBorder",
        "PDFAnnotation", "PDFAction", "PDFActionURL", "PDFActionGoTo", "PDFAppearanceCharacteristics",
        "PDFActionNamed", "PDFActionResetForm", "PDFView", "PDFThumbnailView",
        "PDFAnnotationTextWidget", "PDFAnnotationButtonWidget", "PDFAnnotationChoiceWidget",
        "PDFAnnotationLine", "PDFAnnotationFreeText", "PDFAnnotationLink", "PDFAnnotationMarkup",
        "PDFAnnotationInk", "PDFAnnotationCircle", "PDFAnnotationPopup", "PDFAnnotationSquare",
        "PDFAnnotationStamp", "PDFAnnotationText",
    },
    "Quartz/PDFKit": {
        "PDFDocument", "PDFPage", "PDFSelection", "PDFDestination", "PDFOutline", "PDFBorder",
        "PDFAnnotation", "PDFAction", "PDFActionURL", "PDFActionGoTo", "PDFAppearanceCharacteristics",
        "PDFActionNamed", "PDFActionResetForm", "PDFView", "PDFThumbnailView",
        "PDFAnnotationTextWidget", "PDFAnnotationButtonWidget", "PDFAnnotationChoiceWidget",
        "PDFAnnotationLine", "PDFAnnotationFreeText", "PDFAnnotationLink", "PDFAnnotationMarkup",
        "PDFAnnotationInk", "PDFAnnotationCircle", "PDFAnnotationPopup", "PDFAnnotationSquare",
        "PDFAnnotationStamp", "PDFAnnotationText",
    },
    "Quartz": {
        "CIColor", "CIContext", "CIFilter", "CIFilterShape", "CIImage", "CIImageAccumulator", "CIVector",
        "CIKernel", "CIColorKernel", "CIWarpKernel", "CIBlendKernel", "CIQRCodeDescriptor",
        "CIAztecCodeDescriptor", "CIPDF417CodeDescriptor", "CIDataMatrixCodeDescriptor",
        "CAAnimation", "CAAnimationGroup", "CABasicAnimation", "CAConstraint", "CAConstraintLayoutManager",
        "CAEDRMetadata", "CAEmitterCell", "CAEmitterLayer", "CAGradientLayer", "CAKeyframeAnimation",
        "CALayer", "CAMediaTimingFunction", "CAPropertyAnimation", "CAReplicatorLayer", "CAScrollLayer",
        "CAShapeLayer", "CASpringAnimation", "CATextLayer", "CATiledLayer", "CATransition", "CAValueFunction",
        "PDFDocument", "PDFPage", "PDFSelection", "PDFDestination", "PDFOutline", "PDFBorder",
        "PDFAnnotation", "PDFAction", "PDFActionURL", "PDFActionGoTo", "PDFAppearanceCharacteristics",
        "PDFActionNamed", "PDFActionResetForm", "PDFView", "PDFThumbnailView",
        "PDFAnnotationTextWidget", "PDFAnnotationButtonWidget", "PDFAnnotationChoiceWidget",
        "PDFAnnotationLine", "PDFAnnotationFreeText", "PDFAnnotationLink", "PDFAnnotationMarkup",
        "PDFAnnotationInk", "PDFAnnotationCircle", "PDFAnnotationPopup", "PDFAnnotationSquare",
        "PDFAnnotationStamp", "PDFAnnotationText",
    },
    "Quartz/ImageKit": {"IKSaveOptions", "IKImageView", "IKImageBrowserView", "IKImageBrowserCell"},
    "AVFoundation": {
        "AVAsset", "AVURLAsset", "AVAssetTrack", "AVAssetTrackSegment", "AVMetadataItem", "AVMutableMetadataItem",
        "AVAssetExportSession", "AVAssetImageGenerator", "AVAssetReader", "AVAssetReaderOutput",
        "AVAssetReaderTrackOutput", "AVPlayerItem", "AVPlayerItemTrack",
        "AVComposition", "AVCompositionTrack", "AVCompositionTrackSegment", "AVMutableComposition",
        "AVMutableCompositionTrack", "AVAudioMix", "AVMutableAudioMix", "AVAudioMixInputParameters",
        "AVMutableAudioMixInputParameters", "AVVideoComposition", "AVMutableVideoComposition",
        "AVVideoCompositionInstruction", "AVMutableVideoCompositionInstruction",
        "AVVideoCompositionLayerInstruction", "AVMutableVideoCompositionLayerInstruction",
        "AVCaption", "AVMutableCaption", "AVCaptionRegion", "AVMutableCaptionRegion", "AVCaptionRuby",
        "AVTextStyleRule", "AVTimedMetadataGroup", "AVMutableTimedMetadataGroup", "AVMetadataItemFilter",
        "AVDateRangeMetadataGroup", "AVMutableDateRangeMetadataGroup", "AVMediaSelection",
        "AVMutableMediaSelection", "AVMediaSelectionGroup", "AVMediaSelectionOption", "AVAssetTrackGroup",
        "AVAudioFormat", "AVAudioChannelLayout", "AVAudioTime", "AVAudioPCMBuffer",
        "AVAudioCompressedBuffer", "AVAudioConverter", "AVAudioEngine",
    },
    "OpenDirectory": {"ODAttributeMap", "ODConfiguration", "ODMappings", "ODModuleEntry", "ODRecordMap"},
    "StoreKit": {"SKMutablePayment", "SKPayment", "SKPaymentDiscount"},
    "LinkPresentation": {"LPLinkMetadata"},
    "AudioToolbox": set(),
    "CoreMIDI": set(),
}


def _objc_framework_scope_reason(framework: str, method: dict) -> str | None:
    class_name = method.get("class", "")
    selector = method.get("selector", "")
    if framework == "AVFoundation" and class_name == "AVMutableDateRangeMetadataGroup" and selector in {
        "setEndDate:", "setItems:", "setStartDate:",
    }:
        return "Apple crashes when these setters receive the generated fixed date-range object"
    if framework in {"AVFAudio", "AVFoundation"} and class_name == "AVAudioEngine":
        if selector not in {
            "init", "attachedNodes", "isInManualRenderingMode", "isRunning", "mainMixerNode",
            "manualRenderingFormat", "manualRenderingMaximumFrameCount", "manualRenderingSampleTime",
        }:
            return "would open, run, render, or rewire an audio graph beyond its fixed idle values"
    if framework in {"PDFKit", "Quartz/PDFKit", "Quartz"} and class_name.startswith("PDFAnnotation") and selector in {
        "font", "setFont:",
    }:
        return "the generated annotation lacks the page appearance data Apple needs for its font getter and setter"
    if framework == "Quartz" and class_name == "CIImage" and re.search(r"DepthData|EffectsMatte", selector, re.I):
        return "needs a valid camera depth or portrait matte object, which the fixed image fixture does not build"
    if framework == "Quartz/ImageKit" and class_name == "IKImageView" and selector == "zoomImageToRect:":
        return "needs a displayed image view, which this detached value test does not create"
    if framework == "CoreLocation":
        return "loading Finch CoreLocation aborts because its Objective-C classes collide with Apple's private location framework"
    if framework == "QuartzCore":
        if not class_name.startswith("CA") or class_name in {
            "CADisplayLink", "CAMetalDisplayLink", "CAMetalLayer", "CARemoteLayerServer", "CARenderer", "CATransaction",
        }:
            return "needs a display, renderer, GPU, or process-wide animation state"
        if re.search(r"(?:current|presentationLayer|render|display|draw|convertTime|beginTime|timeOffset)", selector, re.I):
            return "depends on animation time or a render target"
        if selector in {"getControlPointAtIndex:values:", "initWithPerceptualDuration:bounce:"}:
            return "needs an API-specific buffer or a bounded spring input"
    elif framework in {"CoreImage", "Contacts", "CoreData", "CoreLocation", "Metal", "CoreSpotlight", "AVFAudio",
                       "PDFKit", "Quartz/PDFKit", "Quartz", "Quartz/ImageKit", "AVFoundation", "OpenDirectory",
                       "StoreKit", "LinkPresentation", "AudioToolbox", "CoreMIDI"}:
        metal_value_object = framework == "Metal" and class_name.startswith("MTL") and (
            class_name.endswith("Descriptor") or class_name == "MTLFunctionConstantValues")
        if class_name not in VALUE_CLASS_SCOPES[framework] and not metal_value_object:
            return f"outside the selected deterministic {framework} value API scope"
        if framework == "AVFoundation" and class_name in {
            "AVAssetVariant", "AVAssetVariantQualifier", "AVAssetVariantVideoAttributes",
            "AVAssetVariantAudioAttributes", "AVFrameRateRange",
        }:
            return "needs asset selection, streaming variants, or date-range metadata not present in the fixed movie"
        if framework == "AVFoundation" and class_name in {"AVMediaSelection", "AVMutableMediaSelection"} and re.search(
                r"selectedMediaOption|selectMediaOption|mediaSelectionCriteriaCanBeApplied", selector):
            return "needs a media-selection group that the generated movie does not contain"
        if framework == "Quartz" and class_name.startswith("CA") and selector in {
            "getControlPointAtIndex:values:", "initWithPerceptualDuration:bounce:",
        }:
            return "needs an API-specific buffer or a bounded spring input"
        allowed_asset_url = framework == "AVFoundation" and class_name in {"AVAsset", "AVURLAsset"} and selector in {
            "assetWithURL:", "URLAssetWithURL:options:", "initWithURL:options:",
        }
        allowed_pdf_url = framework in {"PDFKit", "Quartz/PDFKit", "Quartz"} and class_name == "PDFActionURL" and selector in {
            "URL", "setURL:",
        }
        allowed_link_url = framework == "LinkPresentation" and class_name == "LPLinkMetadata" and selector in {
            "originalURL", "setOriginalURL:", "URL", "setURL:",
        }
        allowed_storekit_product_id = framework == "StoreKit" and class_name in {"SKPayment", "SKMutablePayment"} and selector in {
            "productIdentifier", "setProductIdentifier:",
        }
        if framework in {"PDFKit", "Quartz/PDFKit", "Quartz", "Quartz/ImageKit", "AVFoundation", "StoreKit", "LinkPresentation"} and not allowed_asset_url and not allowed_pdf_url and not allowed_storekit_product_id and re.search(
                r"(?:URL|File|Path|Write|Save|Export|Print|Load|Request|Fetch|Download|Purchase|PaymentQueue|ProductRequest|Receipt|Playback|Player|Capture|Camera|Device|Hardware|Network|PresentationController)",
                selector, re.I):
            if allowed_link_url:
                pass
            else:
                return "reads a file, uses a service, or changes state outside this fixed-value comparison"
        if framework == "Quartz" and class_name.startswith("CA") and re.search(
                r"(?:current|presentationLayer|render|display|draw|convertTime|beginTime|timeOffset)", selector, re.I):
            return "depends on animation time or a render target"
        if framework == "Quartz" and class_name.startswith("CI") and re.search(
                r"(?:filterNames|filterCategories|render|startTask|device|gpu|^apply|MetalLibraryData|MetalString)",
                selector, re.I):
            return "depends on installed filters, a render target, or GPU state"
        if framework == "Quartz" and class_name.startswith("CI") and selector == "imageByApplyingGaussianBlurWithSigma:":
            return "builds an expensive lazy blur graph on the host implementation"
        if framework == "AVFoundation" and re.search(
                r"(?:CurrentTime|Clock|HostTime|Playback|VideoOutput|AudioOutput|Reader|Writer|Export|ImageGenerator|Capture|Player|ResourceLoader)",
                selector, re.I):
            return "depends on media playback, I/O, a live clock, or capture hardware"
        if framework == "OpenDirectory" and class_name in {"ODModuleEntry", "ODRecordMap"} and re.search(
                r"(?:password|authentication|record|node|query|session|search|fetch|save|delete|write)", selector, re.I):
            return "uses directory records or credentials"
        if framework == "StoreKit" and re.search(
                r"(?:CloudService|Storefront|Request|Queue|Transaction|Download|Receipt|Purchase|Payment|Present|Show|Load)",
                selector, re.I):
            return "uses a store account, product service, receipt, or purchase flow"
        if framework == "LinkPresentation" and class_name != "LPLinkMetadata":
            return "creates a view or loads link metadata"
        if framework == "CoreData" and re.search(
                r"(?:PersistentStore|persistentStore|executeRequest|performBlock|obtainPermanent|deleteObject|insertNewObject|refreshObject)",
                selector):
            return "uses a persistent store or changes managed object state"
        if framework == "CoreData" and class_name == "NSManagedObjectModel" and selector.startswith("mergedModelFromBundles:"):
            return "loads model files from installed application bundles"
        if framework == "CoreLocation" and re.search(r"(?:request|start|stop|monitor|authorization|locationManager)", selector, re.I):
            return "depends on location permission or hardware state"
        if framework == "Metal" and re.search(
                r"(?:device|registry|capture|commandQueue|newBuffer|newTexture|newPipeline|newFunction|newLibrary|(?:vertex|fragment|compute)Function|function$)",
                selector, re.I):
            return "depends on a Metal device or GPU state"
        if framework == "Metal" and selector == "setSamplePositions:count:":
            return "the host asserts unless a sample count is already supported by a render target"
        if framework == "Metal" and selector == "getSamplePositions:count:" and class_name != "MTLRenderPassDescriptor":
            return "the getter needs a sample count configured by a render target"
        if framework == "CoreImage" and re.search(r"(?:filterNames|filterCategories|render|startTask|device|gpu)", selector, re.I):
            return "depends on installed filters, a render target, or GPU state"
        if framework == "CoreImage" and (
                selector.startswith("apply") or "MetalLibraryData" in selector or "MetalString" in selector):
            return "needs a render target, GPU library, or API-specific kernel arguments"
        if framework == "CoreImage" and selector == "imageByApplyingGaussianBlurWithSigma:":
            return "builds an expensive lazy blur graph on the host implementation"
        if framework == "CoreSpotlight" and re.search(r"(?:index|search|query|fetch|delete|update|begin|end)", selector, re.I):
            return "uses the shared Spotlight index or starts a search"
        if framework == "AVFAudio" and re.search(
                r"(?:engine|device|render|play|record|input|output|hostTime|audioTimeStamp|audioBufferList|ChannelData|streamDescription|layout$|initWithSettings|initWithCMAudioFormatDescription)",
                selector, re.I):
            return "depends on an audio device, live clock, callback, or raw audio buffer"
        if framework == "Contacts" and class_name == "CNContactFormatter" and selector == "style":
            return None
    elif framework == "UniformTypeIdentifiers":
        if class_name != "UTType":
            return "outside the selected UniformTypeIdentifiers value API scope"
    elif framework in {"CFNetwork", "ColorSync", "Network"}:
        return f"outside the selected deterministic {framework} C API scope"
    return None
POOL_DESCRIPTIONS = {
    "integer": [0, 1, -1, 2, -2, "minimum", "maximum"],
    "floating": [0.0, "negative-zero", "positive-infinity", "negative-infinity", "nan", "subnormal", 0.5],
    "boolean": [False, True],
    "range": [[0, 0], [0, 1], [1, 0]],
    "string": ["empty", "ASCII", "unicode/combining/emoji/RTL", "long-65536"],
    "number": [0, 1, -1, "minimum", "maximum", 0.5, "nan"],
    "date": [0, -1, 700000000, 800000000],
    "data": ["empty", "small-binary", "UTF-8"],
    "array": ["empty", "mixed", "strings"],
    "dictionary": ["empty", "mixed"],
    "set": ["empty", "mixed"],
    "URL": ["https://example.invalid/a%20b?q=1#part", "mailto:finch@example.invalid", "relative/path"],
    "locale": ["en_US_POSIX", "fr_CA", "ar_EG"],
    "time-zone": ["UTC", "America/Toronto", "Asia/Kathmandu"],
    "calendar": ["gregorian", "iso8601"],
    "character-set": ["ASCII", "letters", "custom/unicode"],
    "color": ["sRGB", "gray", "catalog/system"],
    "font": ["system/12pt", "Helvetica/13pt", "Noto Sans/18pt", "unknown name"],
    "image": ["memory/2x2", "memory/4x3", "bitmap/pixels"],
    "geometry": ["origin", "positive rectangle", "edge insets", "transform"],
    "appearance": ["Aqua", "Dark Aqua"],
    "pasteboard": ["private named board", "string data", "declared types"],
}


SIDE_EFFECT_RULES = (
    ("diagnostic output", re.compile(r"^CFShowStr$")),
    ("user-defaults", re.compile(r"NSUserDefaults|CFPreferences", re.I)),
    ("notifications", re.compile(r"CFUserNotification|NSDistributedNotification|NSUserNotification|DistributedLock|DarwinNotify|GetDarwinNotifyCenter", re.I)),
    ("network", re.compile(r"URLSession|URLConnection|CFHost|NSHost|CFSocket|SocketToHost|Network|HTTP|WebSocket|Bonjour|NSNetService|NS(?:Input|Output)?Stream|Ubiquitous|checkResourceIsReachable|(?:load|fetch|request|download).*?(?:URL|Host)|(?:URL|Host).*?(?:load|fetch|request|download)", re.I)),
    ("processes", re.compile(r"NSTask|NSWorkspace|NSXPC|NSConnection|NSMachPort|NSPort|LaunchApplication|LaunchProcess|Spawn|ForkProcess|CreateProcess|BackgroundActivityScheduler", re.I)),
    ("blocking", re.compile(r"\bCFRunLoopRun(?:InMode)?\b", re.I)),
    ("blocking", re.compile(r"NSCondition|NSLock|NSRecursiveLock|waitUntilFinished|waitUntilDate|waitForDataInBackgroundAndNotify|lockWhenCondition|lockBeforeDate|waitForCompletion|sleepForTimeInterval|performSelector:onThread", re.I)),
    ("autorelease-pools", re.compile(r"NSAutoreleasePool", re.I)),
    ("processes", re.compile(r"NSOperationQueue|NSOperation -start|NSBackgroundActivityScheduler", re.I)),
    ("streams", re.compile(r"(?:WithStream|toStream|FromStream|StreamWith)", re.I)),
    ("filesystem", re.compile(r"NSFile|FileHandle|FileCoordinator|FileWrapper|FileVersion|NSMetadataQuery|NSBundle|CFURL(?:CreateDataAndPropertiesFromResource|WriteDataAndPropertiesToResource|ResourceIsReachable|SetResourcePropert)|(?:read|write|create|remove|move|copy|replace|load|fetch|archive|init).*?(?:File|URL|Path)|(?:File|URL|Path).*?(?:write|create|remove|move|copy|replace|load|fetch|archive|init)|(?:to|From|WithContentsOf)(?:File|URL|Path)|resourceValues|ResourceValue|BookmarkData|AccessingSecurityScopedResource|WriteToFile|WriteToURL|CreateDirectory|MoveItem|CopyItem|RemoveItem|ReplaceItem|CreateFile|OpenFile|check.*Reachable|isReachable", re.I)),
    ("window-system", re.compile(r"CGDisplay|CGSession|CGEvent|CGPreflightListenEventAccess|CGRequestListenEventAccess|CGWindow|CGS|CGScreen|CGWarpMouse|CGAssociateMouse|CGCursor|CGGetLastMouseDelta", re.I)),
)

FOUNDATION_CALLBACK_METHODS = {
    "NSArray -differenceFromArray:withOptions:usingEquivalenceTest:",
    "NSArray -enumerateObjectsAtIndexes:options:usingBlock:",
    "NSArray -enumerateObjectsUsingBlock:",
    "NSArray -enumerateObjectsWithOptions:usingBlock:",
    "NSArray -indexOfObjectAtIndexes:options:passingTest:",
    "NSArray -indexOfObjectPassingTest:",
    "NSArray -indexOfObjectWithOptions:passingTest:",
    "NSArray -indexesOfObjectsAtIndexes:options:passingTest:",
    "NSArray -indexesOfObjectsPassingTest:",
    "NSArray -indexesOfObjectsWithOptions:passingTest:",
    "NSAttributedString -enumerateAttribute:inRange:options:usingBlock:",
    "NSAttributedString -enumerateAttributesInRange:options:usingBlock:",
    "NSData -enumerateByteRangesUsingBlock:",
    "NSDictionary -enumerateKeysAndObjectsUsingBlock:",
    "NSDictionary -enumerateKeysAndObjectsWithOptions:usingBlock:",
    "NSDictionary -keysOfEntriesPassingTest:",
    "NSDictionary -keysOfEntriesWithOptions:passingTest:",
    "NSIndexSet -enumerateIndexesInRange:options:usingBlock:",
    "NSIndexSet -enumerateIndexesUsingBlock:",
    "NSIndexSet -enumerateIndexesWithOptions:usingBlock:",
    "NSIndexSet -enumerateRangesInRange:options:usingBlock:",
    "NSIndexSet -enumerateRangesUsingBlock:",
    "NSIndexSet -enumerateRangesWithOptions:usingBlock:",
    "NSIndexSet -indexInRange:options:passingTest:",
    "NSIndexSet -indexPassingTest:",
    "NSIndexSet -indexWithOptions:passingTest:",
    "NSIndexSet -indexesInRange:options:passingTest:",
    "NSIndexSet -indexesPassingTest:",
    "NSIndexSet -indexesWithOptions:passingTest:",
    "NSOrderedSet -differenceFromOrderedSet:withOptions:usingEquivalenceTest:",
    "NSOrderedSet -enumerateObjectsAtIndexes:options:usingBlock:",
    "NSOrderedSet -enumerateObjectsUsingBlock:",
    "NSOrderedSet -enumerateObjectsWithOptions:usingBlock:",
    "NSOrderedSet -indexOfObjectAtIndexes:options:passingTest:",
    "NSOrderedSet -indexOfObjectPassingTest:",
    "NSOrderedSet -indexOfObjectWithOptions:passingTest:",
    "NSOrderedSet -indexesOfObjectsAtIndexes:options:passingTest:",
    "NSOrderedSet -indexesOfObjectsPassingTest:",
    "NSOrderedSet -indexesOfObjectsWithOptions:passingTest:",
    "NSRegularExpression -enumerateMatchesInString:options:range:usingBlock:",
    "NSSet -enumerateObjectsUsingBlock:",
    "NSSet -enumerateObjectsWithOptions:usingBlock:",
    "NSSet -objectsPassingTest:",
    "NSSet -objectsWithOptions:passingTest:",
    "NSString -enumerateLinesUsingBlock:",
    "NSString -enumerateSubstringsInRange:options:usingBlock:",
}


APPKIT_HEADLESS_CLASSES = {
    "NSColor", "NSColorSpace", "NSColorList", "NSFont", "NSFontDescriptor", "NSFontManager",
    "NSBezierPath", "NSAffineTransform", "NSImage", "NSImageRep", "NSBitmapImageRep",
    "NSAttributedString", "NSMutableAttributedString", "NSParagraphStyle", "NSMutableParagraphStyle",
    "NSTextTab", "NSShadow", "NSGradient", "NSCursor", "NSAppearance", "NSEvent", "NSTouch",
    "NSLayoutConstraint", "NSLayoutAnchor", "NSLayoutXAxisAnchor", "NSLayoutYAxisAnchor",
    "NSLayoutDimension", "NSLayoutGuide", "NSView", "NSPasteboard", "NSValue", "NSPrintInfo",
    "NSCell", "NSMenuItem", "NSMenu", "NSTableColumn", "NSControl", "NSButton", "NSTextField",
    "NSComboBox", "NSSegmentedControl", "NSSlider", "NSLevelIndicator", "NSProgressIndicator", "NSBox",
    "NSPopUpButton", "NSTabView", "NSTabViewItem", "NSMatrix", "NSTextStorage", "NSLayoutManager",
    "NSTextContainer", "NSTextView", "NSScrollView", "NSGridView", "NSGridRow", "NSGridColumn", "NSGridCell",
    "NSRulerView", "NSRulerMarker", "NSButtonCell", "NSSliderCell", "NSSegmentedCell",
    "NSPopUpButtonCell", "NSComboBoxCell", "NSLevelIndicatorCell", "NSTextFieldCell", "NSImageCell",
}

APPKIT_VALUE_CELL_SELECTORS = {
    "NSButtonCell": {
        "initTextCell:", "initImageCell:",
        "title", "setTitle:", "attributedTitle", "setAttributedTitle:", "alternateTitle", "setAlternateTitle:",
        "attributedAlternateTitle", "setAttributedAlternateTitle:", "bezelStyle", "setBezelStyle:",
        "highlightsBy", "setHighlightsBy:", "showsStateBy", "setShowsStateBy:", "alternateImage", "setAlternateImage:",
        "imagePosition", "setImagePosition:", "imageScaling", "setImageScaling:", "keyEquivalent", "setKeyEquivalent:",
        "keyEquivalentModifierMask", "setKeyEquivalentModifierMask:", "isTransparent", "setTransparent:",
        "isOpaque", "setOpaque:", "imageDimsWhenDisabled", "setImageDimsWhenDisabled:",
        "showsBorderOnlyWhileMouseInside", "setShowsBorderOnlyWhileMouseInside:", "backgroundColor", "setBackgroundColor:",
        "gradientType", "setGradientType:", "keyEquivalentFont", "setKeyEquivalentFont:",
    },
    "NSSliderCell": {
        "init",
        "minValue", "setMinValue:", "maxValue", "setMaxValue:", "altIncrementValue", "setAltIncrementValue:",
        "sliderType", "setSliderType:", "isVertical", "setVertical:", "trackRect", "knobThickness",
        "numberOfTickMarks", "setNumberOfTickMarks:", "tickMarkPosition", "setTickMarkPosition:",
        "allowsTickMarkValuesOnly", "setAllowsTickMarkValuesOnly:", "prefersTrackingUntilMouseUp", "setPrefersTrackingUntilMouseUp:",
    },
    "NSSegmentedCell": {
        "init",
        "segmentCount", "setSegmentCount:", "selectedSegment", "setSelectedSegment:", "trackingMode", "setTrackingMode:",
        "segmentStyle", "setSegmentStyle:", "labelForSegment:", "setLabel:forSegment:", "imageForSegment:",
        "setImage:forSegment:", "widthForSegment:", "setWidth:forSegment:", "isEnabledForSegment:",
        "setEnabled:forSegment:", "toolTipForSegment:", "setToolTip:forSegment:",
    },
    "NSPopUpButtonCell": {
        "initTextCell:pullsDown:",
        "menu", "setMenu:", "pullsDown", "setPullsDown:", "autoenablesItems", "setAutoenablesItems:",
        "preferredEdge", "setPreferredEdge:", "usesItemFromMenu", "setUsesItemFromMenu:",
        "altersStateOfSelectedItem", "setAltersStateOfSelectedItem:", "itemArray", "numberOfItems", "lastItem",
        "selectedItem", "indexOfSelectedItem", "itemTitles", "titleOfSelectedItem", "arrowPosition", "setArrowPosition:",
    },
    "NSComboBoxCell": {
        "initTextCell:",
        "hasVerticalScroller", "setHasVerticalScroller:", "intercellSpacing", "setIntercellSpacing:",
        "itemHeight", "setItemHeight:", "numberOfVisibleItems", "setNumberOfVisibleItems:", "buttonBordered", "setButtonBordered:",
        "usesDataSource", "setUsesDataSource:", "indexOfSelectedItem", "numberOfItems", "completes", "setCompletes:",
        "objectValueOfSelectedItem", "objectValues", "addItemWithObjectValue:", "addItemsWithObjectValues:",
        "removeAllItems", "selectItemAtIndex:", "selectItemWithObjectValue:",
    },
    "NSLevelIndicatorCell": {
        "init",
        "levelIndicatorStyle", "setLevelIndicatorStyle:", "minValue", "setMinValue:", "maxValue", "setMaxValue:",
        "warningValue", "setWarningValue:", "criticalValue", "setCriticalValue:", "tickMarkPosition", "setTickMarkPosition:",
        "numberOfTickMarks", "setNumberOfTickMarks:", "numberOfMajorTickMarks", "setNumberOfMajorTickMarks:",
    },
    "NSTextFieldCell": {
        "initTextCell:",
        "backgroundColor", "setBackgroundColor:", "drawsBackground", "setDrawsBackground:", "textColor", "setTextColor:",
        "isBordered", "setBordered:", "isBezeled", "setBezeled:", "isEditable", "setEditable:", "isSelectable", "setSelectable:",
        "acceptsFirstResponder", "setAcceptsFirstResponder:", "bezelStyle", "setBezelStyle:", "placeholderString", "setPlaceholderString:",
        "placeholderAttributedString", "setPlaceholderAttributedString:", "allowedInputSourceLocales", "setAllowedInputSourceLocales:",
    },
    "NSImageCell": {
        "initImageCell:",
        "imageAlignment", "setImageAlignment:", "imageScaling", "setImageScaling:", "imageFrameStyle", "setImageFrameStyle:",
    },
}

APPKIT_VIEW_VALUE_SELECTORS = {
    "init", "initWithFrame:", "leadingAnchor", "trailingAnchor", "leftAnchor", "rightAnchor",
    "topAnchor", "bottomAnchor", "widthAnchor", "heightAnchor", "centerXAnchor", "centerYAnchor",
    "firstBaselineAnchor", "lastBaselineAnchor", "safeAreaLayoutGuide", "layoutMarginsGuide",
    "superview", "subviews", "window", "enclosingScrollView", "opaqueAncestor",
    "removeFromSuperview", "removeFromSuperviewWithoutNeedingDisplay", "isDescendantOf:",
    "ancestorSharedWithView:", "viewWithTag:", "hitTest:", "mouse:inRect:",
    "frame", "setFrame:", "bounds", "setBounds:", "frameOrigin", "setFrameOrigin:",
    "frameSize", "setFrameSize:", "boundsOrigin", "setBoundsOrigin:", "boundsSize", "setBoundsSize:",
    "frameRotation", "setFrameRotation:", "frameCenterRotation", "setFrameCenterRotation:",
    "boundsRotation", "setBoundsRotation:", "translateOriginToPoint:", "scaleUnitSquareToSize:",
    "rotateByAngle:", "backingAlignedRect:options:", "centerScanRect:",
    "convertPoint:fromView:", "convertPoint:toView:", "convertSize:fromView:", "convertSize:toView:",
    "convertRect:fromView:", "convertRect:toView:", "convertPointToLayer:", "convertPointFromLayer:",
    "convertSizeToLayer:", "convertSizeFromLayer:", "convertRectToLayer:", "convertRectFromLayer:",
    "needsToDrawRect:", "wantsDefaultClipping", "visibleRect", "tag", "isFlipped", "isHidden",
    "isHiddenOrHasHiddenAncestor", "setHidden:", "isOpaque", "autoresizingMask",
    "setAutoresizingMask:", "autoresizesSubviews", "setAutoresizesSubviews:",
    "postsFrameChangedNotifications", "setPostsFrameChangedNotifications:",
    "isRotatedFromBase", "isRotatedOrScaledFromBase", "canDrawConcurrently", "setCanDrawConcurrently:",
    "canDraw", "needsDisplay", "setNeedsDisplay:", "setNeedsDisplayInRect:",
    "layerContentsRedrawPolicy", "setLayerContentsRedrawPolicy:", "layerContentsPlacement",
    "setLayerContentsPlacement:", "wantsLayer", "setWantsLayer:", "wantsUpdateLayer", "layer", "setLayer:",
    "canDrawSubviewsIntoLayer", "setCanDrawSubviewsIntoLayer:", "needsLayout", "setNeedsLayout:",
    "alphaValue", "setAlphaValue:", "layerUsesCoreImageFilters", "setLayerUsesCoreImageFilters:",
    "backgroundFilters", "setBackgroundFilters:", "compositingFilter", "setCompositingFilter:",
    "contentFilters", "setContentFilters:", "shadow", "setShadow:", "clipsToBounds", "setClipsToBounds:",
    "toolTip", "setToolTip:", "inLiveResize", "preservesContentDuringLiveResize", "rectPreservedDuringLiveResize",
    "needsPanelToBecomeKey", "mouseDownCanMoveWindow", "wantsRestingTouches", "setWantsRestingTouches:",
    "rectForSmartMagnificationAtPoint:inRect:", "userInterfaceLayoutDirection", "setUserInterfaceLayoutDirection:",
    "preparedContentRect", "setPreparedContentRect:", "allowsVibrancy", "prepareForReuse",
    "intrinsicContentSize", "fittingSize", "alignmentRectInsets", "hasAmbiguousLayout",
    "alignmentRectForFrame:", "frameForAlignmentRect:", "contentCompressionResistancePriorityForOrientation:",
    "setContentCompressionResistancePriority:forOrientation:", "contentHuggingPriorityForOrientation:",
    "setContentHuggingPriority:forOrientation:", "constraints", "constraintsAffectingLayoutForOrientation:",
    "needsUpdateConstraints", "setNeedsUpdateConstraints:", "updateConstraints", "updateConstraintsForSubtreeIfNeeded",
    "invalidateIntrinsicContentSize", "layout", "layoutSubtreeIfNeeded", "postsBoundsChangedNotifications",
    "setPostsBoundsChangedNotifications:", "firstBaselineOffsetFromTop", "lastBaselineOffsetFromBottom",
    "baselineOffsetFromBottom", "safeAreaInsets", "safeAreaRect", "additionalSafeAreaInsets",
    "setAdditionalSafeAreaInsets:", "canBecomeKeyView", "shouldDrawColor", "edgeInsetsForLayoutRegion:",
    "rectForLayoutRegion:", "layoutGuideForLayoutRegion:", "layoutGuides", "adjustScroll:",
    "scrollRectToVisible:", "scrollPoint:", "prepareContentInRect:", "viewDidHide", "viewDidUnhide",
    "translatesAutoresizingMaskIntoConstraints", "setTranslatesAutoresizingMaskIntoConstraints:",
    "defaultFocusRingType", "requiresConstraintBasedLayout",
}

APPKIT_TEXT_VIEW_SELECTORS = {
    "initWithFrame:", "initWithFrame:textContainer:", "textStorage", "textContainer", "layoutManager",
    "initUsingTextLayoutManager:", "textViewUsingTextLayoutManager:", "textLayoutManager", "textContentStorage",
    "replaceTextContainer:", "textContainerOrigin", "invalidateTextContainerOrigin", "setConstrainedFrameSize:",
    "string", "setString:", "selectedRange", "setSelectedRange:", "selectedRanges", "setSelectedRanges:",
    "typingAttributes", "setTypingAttributes:", "isRichText", "setRichText:", "isEditable", "setEditable:",
    "isSelectable", "setSelectable:", "isFieldEditor", "setFieldEditor:", "allowsUndo", "setAllowsUndo:",
    "drawsBackground", "setDrawsBackground:", "backgroundColor", "setBackgroundColor:", "font", "setFont:",
    "textColor", "setTextColor:", "alignment", "setAlignment:", "insertionPointColor", "setInsertionPointColor:",
    "textContainerInset", "setTextContainerInset:", "isHorizontallyResizable", "setHorizontallyResizable:",
    "isVerticallyResizable", "setVerticallyResizable:", "maxSize", "setMaxSize:", "minSize", "setMinSize:",
    "setAlignment:range:", "setBaseWritingDirection:range:", "selectionRangeForProposedRange:granularity:",
    "setNeedsDisplayInRect:avoidAdditionalLayout:", "characterIndexForInsertionAtPoint:",
    "performValidatedReplacementInRange:withAttributedString:", "usesAdaptiveColorMappingForDarkAppearance",
    "setUsesAdaptiveColorMappingForDarkAppearance:", "stronglyReferencesTextStorage",
    "acceptsGlyphInfo", "setAcceptsGlyphInfo:", "allowsDocumentBackgroundColorChange",
    "setAllowsDocumentBackgroundColorChange:", "allowsImageEditing", "setAllowsImageEditing:",
    "automaticDashSubstitutionEnabled", "setAutomaticDashSubstitutionEnabled:",
    "automaticDataDetectionEnabled", "setAutomaticDataDetectionEnabled:",
    "automaticLinkDetectionEnabled", "setAutomaticLinkDetectionEnabled:",
    "automaticQuoteSubstitutionEnabled", "setAutomaticQuoteSubstitutionEnabled:",
    "automaticTextReplacementEnabled", "setAutomaticTextReplacementEnabled:",
    "defaultParagraphStyle", "displaysLinkToolTips", "setDisplaysLinkToolTips:",
    "importsGraphics", "setImportsGraphics:", "inlinePredictionType", "setInlinePredictionType:",
    "linkTextAttributes", "setLinkTextAttributes:", "markedTextAttributes", "setMarkedTextAttributes:",
    "selectedTextAttributes", "setSelectedTextAttributes:", "selectionAffinity", "setSelectionAffinity:",
    "selectionGranularity", "setSelectionGranularity:", "textHighlightAttributes", "setTextHighlightAttributes:",
    "usesFindPanel", "setUsesFindPanel:", "usesFontPanel", "setUsesFontPanel:",
    "usesRuler", "setUsesRuler:", "writablePasteboardTypes", "readablePasteboardTypes",
}

APPKIT_SCROLL_VIEW_SELECTORS = {
    "initWithFrame:", "contentSize", "contentSizeForFrameSize:hasHorizontalScroller:hasVerticalScroller:borderType:",
    "frameSizeForContentSize:hasHorizontalScroller:hasVerticalScroller:borderType:", "hasHorizontalScroller",
    "setHasHorizontalScroller:", "hasVerticalScroller", "setHasVerticalScroller:", "autohidesScrollers",
    "setAutohidesScrollers:", "borderType", "setBorderType:", "scrollerStyle", "setScrollerStyle:",
    "horizontalScrollElasticity", "setHorizontalScrollElasticity:", "verticalScrollElasticity",
    "setVerticalScrollElasticity:", "contentInsets", "setContentInsets:", "documentView", "setDocumentView:",
    "contentView", "scrollerKnobStyle", "setScrollerKnobStyle:", "lineScroll", "setLineScroll:",
    "pageScroll", "setPageScroll:", "scrollsDynamically", "setScrollsDynamically:",
}

APPKIT_CONTROL_SELECTORS = {
    "NSControl": {
        "initWithFrame:", "alignment", "setAlignment:", "allowsExpansionToolTips", "setAllowsExpansionToolTips:",
        "controlSize", "setControlSize:", "doubleValue", "setDoubleValue:", "floatValue", "setFloatValue:",
        "font", "setFont:", "ignoresMultiClick", "setIgnoresMultiClick:", "intValue", "setIntValue:",
        "integerValue", "setIntegerValue:", "isContinuous", "setContinuous:", "isEnabled", "setEnabled:",
        "lineBreakMode", "setLineBreakMode:", "objectValue", "setObjectValue:", "refusesFirstResponder",
        "setRefusesFirstResponder:", "stringValue", "tag", "setTag:", "usesSingleLineMode", "setUsesSingleLineMode:",
        "sendActionOn:", "sizeThatFits:", "sizeToFit",
    },
    "NSButton": {
        "initWithFrame:", "allowsMixedState", "setAllowsMixedState:", "alternateImage", "setAlternateImage:",
        "alternateTitle", "setAlternateTitle:", "attributedAlternateTitle", "setAttributedAlternateTitle:",
        "attributedTitle", "setAttributedTitle:", "bezelColor", "setBezelColor:", "bezelStyle", "setBezelStyle:",
        "bordered", "setBordered:", "contentTintColor", "setContentTintColor:", "hasDestructiveAction",
        "setHasDestructiveAction:", "image", "setImage:", "imageHugsTitle", "setImageHugsTitle:",
        "imagePosition", "setImagePosition:", "imageScaling", "setImageScaling:", "isTransparent", "setTransparent:",
        "keyEquivalent", "setKeyEquivalent:", "keyEquivalentModifierMask", "setKeyEquivalentModifierMask:",
        "state", "setState:", "title", "setTitle:", "isSpringLoaded", "setSpringLoaded:", "isBordered", "isEnabled",
    },
    "NSTextField": {
        "initWithFrame:", "allowsCharacterPickerTouchBarItem", "setAllowsCharacterPickerTouchBarItem:",
        "allowsDefaultTighteningForTruncation", "setAllowsDefaultTighteningForTruncation:", "allowsEditingTextAttributes",
        "setAllowsEditingTextAttributes:", "allowsWritingTools", "setAllowsWritingTools:", "allowsWritingToolsAffordance",
        "setAllowsWritingToolsAffordance:", "backgroundColor", "setBackgroundColor:", "bezelStyle", "setBezelStyle:",
        "drawsBackground", "setDrawsBackground:", "importsGraphics", "setImportsGraphics:", "automaticTextCompletionEnabled",
        "setAutomaticTextCompletionEnabled:", "isBezeled", "setBezeled:", "isBordered", "setBordered:",
        "isEditable", "setEditable:", "isSelectable", "setSelectable:", "lineBreakStrategy", "setLineBreakStrategy:",
        "maximumNumberOfLines", "setMaximumNumberOfLines:", "placeholderAttributedString", "setPlaceholderAttributedString:",
        "placeholderString", "setPlaceholderString:", "preferredMaxLayoutWidth", "setPreferredMaxLayoutWidth:",
        "resolvesNaturalAlignmentWithBaseWritingDirection", "setResolvesNaturalAlignmentWithBaseWritingDirection:",
        "textColor", "setTextColor:", "stringValue", "setStringValue:",
    },
    "NSComboBox": {
        "initWithFrame:", "completes", "setCompletes:", "hasVerticalScroller", "setHasVerticalScroller:",
        "intercellSpacing", "setIntercellSpacing:", "isButtonBordered", "setButtonBordered:", "itemHeight", "setItemHeight:",
        "indexOfSelectedItem", "numberOfItems", "numberOfVisibleItems", "setNumberOfVisibleItems:",
        "objectValueOfSelectedItem", "objectValues", "usesDataSource", "addItemWithObjectValue:",
        "addItemsWithObjectValues:", "deselectItemAtIndex:", "indexOfItemWithObjectValue:",
        "itemObjectValueAtIndex:", "removeAllItems", "removeItemAtIndex:", "removeItemWithObjectValue:",
        "selectItemAtIndex:", "selectItemWithObjectValue:",
    },
    "NSSegmentedControl": {
        "initWithFrame:", "doubleValueForSelectedSegment", "indexOfSelectedItem", "segmentCount", "setSegmentCount:",
        "segmentDistribution", "setSegmentDistribution:", "segmentStyle", "setSegmentStyle:", "selectedSegment",
        "setSelectedSegment:", "trackingMode", "setTrackingMode:", "alignmentForSegment:", "imageForSegment:",
        "imageScalingForSegment:", "isEnabledForSegment:", "isSelectedForSegment:", "labelForSegment:",
        "selectSegmentWithTag:", "setAlignment:forSegment:", "setEnabled:forSegment:", "setImage:forSegment:",
        "setImageScaling:forSegment:", "setLabel:forSegment:", "setSelected:forSegment:", "setTag:forSegment:",
        "setToolTip:forSegment:", "setWidth:forSegment:", "tagForSegment:", "toolTipForSegment:", "widthForSegment:",
    },
    "NSProgressIndicator": {
        "initWithFrame:", "controlSize", "setControlSize:", "controlTint", "setControlTint:", "doubleValue", "setDoubleValue:",
        "isBezeled", "setBezeled:", "isDisplayedWhenStopped", "setDisplayedWhenStopped:", "isIndeterminate", "setIndeterminate:",
        "maxValue", "setMaxValue:", "minValue", "setMinValue:", "style", "usesThreadedAnimation",
    },
    "NSBox": {
        "initWithFrame:", "borderType", "setBorderType:", "borderColor", "setBorderColor:", "borderWidth", "setBorderWidth:",
        "boxType", "setBoxType:", "contentView", "contentViewMargins", "setContentViewMargins:", "fillColor", "setFillColor:",
        "isTransparent", "setTransparent:", "title", "setTitle:", "titleFont", "setTitleFont:", "titlePosition", "setTitlePosition:",
    },
    "NSSlider": {
        "initWithFrame:", "allowsTickMarkValuesOnly", "setAllowsTickMarkValuesOnly:", "altIncrementValue", "setAltIncrementValue:",
        "isVertical", "knobThickness", "maxValue", "setMaxValue:", "minValue", "setMinValue:", "neutralValue", "setNeutralValue:",
        "numberOfTickMarks", "setNumberOfTickMarks:", "sliderType", "tickMarkPosition", "tintProminence", "trackFillColor",
        "setKnobThickness:", "setTitle:", "setTitleColor:", "setTitleFont:", "title", "titleColor", "titleFont",
    },
    "NSLevelIndicator": {
        "initWithFrame:", "criticalFillColor", "setCriticalFillColor:", "criticalValue", "setCriticalValue:",
        "drawsTieredCapacityLevels", "setDrawsTieredCapacityLevels:", "fillColor", "setFillColor:", "isEditable", "setEditable:",
        "levelIndicatorStyle", "setLevelIndicatorStyle:", "maxValue", "setMaxValue:", "minValue", "setMinValue:",
        "numberOfMajorTickMarks", "setNumberOfMajorTickMarks:", "numberOfTickMarks", "setNumberOfTickMarks:",
        "placeholderVisibility", "setPlaceholderVisibility:", "ratingImage", "setRatingImage:",
        "ratingPlaceholderImage", "setRatingPlaceholderImage:", "tickMarkPosition", "warningFillColor", "warningValue",
    },
    "NSPopUpButton": {
        "initWithFrame:pullsDown:", "altersStateOfSelectedItem", "setAltersStateOfSelectedItem:",
        "autoenablesItems", "setAutoenablesItems:", "indexOfSelectedItem", "itemArray", "itemTitles", "lastItem",
        "numberOfItems", "preferredEdge", "setPreferredEdge:", "pullsDown", "setPullsDown:", "selectedItem", "selectedTag",
        "usesItemFromMenu", "setUsesItemFromMenu:", "titleOfSelectedItem", "addItemWithTitle:", "addItemsWithTitles:",
        "indexOfItemWithRepresentedObject:", "indexOfItemWithTag:", "indexOfItemWithTitle:", "insertItemWithTitle:atIndex:",
        "itemAtIndex:", "itemTitleAtIndex:", "itemWithTitle:", "removeAllItems", "removeItemAtIndex:",
        "removeItemWithTitle:", "selectItemAtIndex:", "selectItemWithTag:", "selectItemWithTitle:", "setTitle:",
        "synchronizeTitleAndSelectedItem",
    },
    "NSTabView": {
        "initWithFrame:", "allowsTruncatedLabels", "setAllowsTruncatedLabels:", "contentRect", "controlSize", "setControlSize:",
        "controlTint", "setControlTint:", "drawsBackground", "setDrawsBackground:", "font", "setFont:", "minimumSize",
        "numberOfTabViewItems", "selectedTabViewItem", "tabPosition", "setTabPosition:", "tabViewBorderType", "setTabViewBorderType:",
        "tabViewItems", "tabViewType", "addTabViewItem:", "indexOfTabViewItem:", "indexOfTabViewItemWithIdentifier:",
        "insertTabViewItem:atIndex:", "removeTabViewItem:", "selectFirstTabViewItem:", "selectLastTabViewItem:",
        "selectNextTabViewItem:", "selectPreviousTabViewItem:", "selectTabViewItem:", "selectTabViewItemAtIndex:",
        "selectTabViewItemWithIdentifier:", "tabViewItemAtIndex:",
    },
    "NSTabViewItem": {
        "initWithIdentifier:", "color", "setColor:", "identifier", "setIdentifier:", "image", "setImage:",
        "initialFirstResponder", "setInitialFirstResponder:", "label", "setLabel:", "toolTip", "setToolTip:", "view", "setView:",
        "tabState", "tabView",
    },
    "NSMatrix": {
        "initWithFrame:", "allowsEmptySelection", "setAllowsEmptySelection:", "autocalculatesCellSize", "setAutorecalculatesCellSize:",
        "autosizesCells", "setAutosizesCells:", "backgroundColor", "setBackgroundColor:", "cellBackgroundColor", "setCellBackgroundColor:",
        "cellSize", "setCellSize:", "cells", "drawsBackground", "setDrawsBackground:", "drawsCellBackground", "setDrawsCellBackground:",
        "intercellSpacing", "setIntercellSpacing:", "isAutoscroll", "setAutoscroll:", "isSelectionByRect", "setSelectionByRect:",
        "keyCell", "setKeyCell:", "mode", "setMode:", "numberOfColumns", "numberOfRows", "selectedCell", "selectedCells",
        "selectedColumn", "selectedRow", "tabKeyTraversesCells", "setTabKeyTraversesCells:", "cellAtRow:column:",
        "cellFrameAtRow:column:", "cellWithTag:", "deselectAllCells", "deselectSelectedCell", "getNumberOfRows:columns:",
        "getRow:column:ofCell:", "makeCellAtRow:column:", "selectCellAtRow:column:", "selectCellWithTag:",
        "setState:atRow:column:", "toolTipForCell:",
    },
    "NSGridView": {
        "gridViewWithNumberOfColumns:rows:", "numberOfColumns", "numberOfRows", "rowAtIndex:", "columnAtIndex:",
        "indexOfColumn:", "indexOfRow:", "cellAtColumnIndex:rowIndex:", "cellForView:", "xPlacement", "yPlacement",
        "setColumnSpacing:", "setRowAlignment:", "setRowSpacing:",
    },
    "NSGridRow": {
        "gridView", "numberOfCells", "topPadding", "yPlacement", "setBottomPadding:", "setHeight:", "setHidden:",
        "setRowAlignment:", "mergeCellsInRange:",
    },
    "NSGridColumn": {
        "gridView", "numberOfCells", "trailingPadding", "width", "xPlacement", "setHidden:",
        "setLeadingPadding:", "cellAtIndex:", "mergeCellsInRange:",
    },
    "NSGridCell": {
        "column", "row", "xPlacement", "yPlacement", "setRowAlignment:",
    },
    "NSRulerView": {
        "initWithScrollView:orientation:", "orientation", "setOrientation:", "baselineLocation", "requiredThickness",
        "measurementUnits", "setMeasurementUnits:", "originOffset", "setOriginOffset:", "reservedThicknessForMarkers",
        "setReservedThicknessForMarkers:", "reservedThicknessForAccessoryView", "setReservedThicknessForAccessoryView:",
        "ruleThickness", "setRuleThickness:", "markers", "setMarkers:", "addMarker:", "removeMarker:", "isFlipped",
    },
    "NSRulerMarker": {
        "initWithRulerView:markerLocation:image:imageOrigin:", "ruler", "markerLocation", "setMarkerLocation:",
        "image", "setImage:", "imageOrigin", "setImageOrigin:", "isMovable", "setMovable:", "isRemovable",
        "setRemovable:", "representedObject", "setRepresentedObject:", "imageRectInRuler", "thicknessRequiredInRuler",
    },
}

APPKIT_UNSAFE_SELECTORS = {
    "NSBezierPath": re.compile(r"^(?:fill|stroke|clip|addClip|setClip|draw|setAssociatedPoints:atIndex:|elementAtIndex:associatedPoints:)"),
    "NSGradient": re.compile(r"^draw"),
    "NSImage": re.compile(r"^(?:draw|lockFocus|unlockFocus|dragFrom|hitTestRect|bestRepresentationForRect|CGImageForProposedRect)"),
    "NSCursor": re.compile(r"^(?:push|pop|set|hide|unhide|setOnMouseEntered)"),
    "NSFontManager": re.compile(r"^(?:fontPanel|fontMenu|orderFront|setFontPanelFactory|sendAction|setSelectedFont|availableFonts|availableFontFamilies|availableFontNamesMatchingFontDescriptor|availableFontNamesWithTraits|collectionNames)"),
    "NSPrintInfo": re.compile(r"^(?:sharedPrintInfo|defaultPrinter|setDefaultPrinter)"),
    # Pasteboard counters come from separate host and Finch pasteboard services.
    "NSPasteboard": re.compile(r"^(?:changeCount|clearContents|prepareForNewContentsWithOptions:)"),
    "NSEvent": re.compile(r"^(?:mouseLocation|pressedMouseButtons|startPeriodic|stopPeriodic|addGlobalMonitor|addLocalMonitor|removeMonitor|setMouseCoalescing|eventWithEventRef)"),
    "NSImageRep": re.compile(r"^(?:draw)"),
    "NSBitmapImageRep": re.compile(r"^(?:getBitmapDataPlanes:|initForIncrementalLoad)$"),
    "NSCell": re.compile(r"^(?:draw|calcDrawInfo|highlight|track|startTracking|continueTracking|stopTracking|edit|select|endEditing|resetCursor|menuForEvent|setUpFieldEditor|fieldEditor|sendAction|performClick|getPeriodicDelay|focusRingMask|hitTestForEvent)"),
    "NSMenu": re.compile(r"^(?:popUp|cancelTracking|update$|performActionForItemAtIndex|performKeyEquivalent|menuBarVisible$|setMenuBarVisible:)"),
}


def _appkit_c_scope(name: str, variable: bool = False) -> bool:
    if variable:
        return bool(re.match(r"^NS(?:AppearanceName|UserInterfaceItemIdentifier)", name))
    return bool(re.match(r"^NS(?:Make(?:Point|Size|Rect)|(?:Min|Max|Mid)[XY]|DivideRect|InsetRect|OffsetRect|IntegralRect|StandardizeRect|UnionRect|IntersectionRect|Contains(?:Rect|Point)|Equal(?:Rects|Sizes|Points)|IsEmpty(?:Rect|Size)|MouseInRect|PointInRect|RectFromCGRect|RectToCGRect|PointFromCGPoint|SizeFromCGSize|EdgeInsets)", name))


def _appkit_skip(method: dict) -> str | None:
    class_name = method.get("class", "")
    selector = method.get("selector", "")
    if class_name == "NSWindow" and method.get("class_method") and selector in {
        "frameRectForContentRect:styleMask:", "contentRectForFrameRect:styleMask:"
    }:
        return None
    if class_name not in APPKIT_HEADLESS_CLASSES:
        return "outside the selected AppKit headless API scope"
    if class_name == "NSTouch":
        return "touch values require a real input event"
    if class_name in {"NSLayoutManager", "NSTextStorage", "NSTextContainer"} and re.match(
            r"^(?:draw|show|display|print|writeTo|readFrom)", selector, re.I):
        return "needs a drawing context, printer, or file"
    if class_name == "NSLayoutManager" and selector == "getGlyphs:range:":
        return "needs a glyph buffer sized for the layout manager's current glyph range"
    if class_name == "NSLayoutManager" and selector == "setExtraLineFragmentRect:usedRect:textContainer:":
        return "needs extra line-fragment values produced by a configured typesetter"
    if class_name == "NSView" and selector not in APPKIT_VIEW_VALUE_SELECTORS:
        return "outside the selected AppKit headless API scope"
    if class_name == "NSTextView" and selector not in APPKIT_TEXT_VIEW_SELECTORS:
        return "outside the selected AppKit headless API scope"
    if class_name == "NSScrollView" and selector not in APPKIT_SCROLL_VIEW_SELECTORS:
        return "outside the selected AppKit headless API scope"
    if class_name in APPKIT_CONTROL_SELECTORS and selector not in APPKIT_CONTROL_SELECTORS[class_name]:
        return "outside the selected AppKit detached-control scope"
    if class_name in APPKIT_VALUE_CELL_SELECTORS and selector not in APPKIT_VALUE_CELL_SELECTORS[class_name]:
        return "outside the selected AppKit headless cell-value scope"
    if class_name in {"NSMenu", "NSCell"}:
        pattern = APPKIT_UNSAFE_SELECTORS.get(class_name)
        if pattern and pattern.search(selector):
            return "needs a menu event, drawing context, or input state"
    if class_name == "NSPasteboard" and method.get("class_method") and selector != "pasteboardWithName:":
        return "pasteboard must use a private named board"
    if class_name == "NSPrintInfo" and selector in {
        "init", "dictionary", "printer", "setPrinter:", "imageablePageBounds", "PMPrintSession", "PMPageFormat", "PMPrintSettings",
        "printSettings", "setUpPrintOperationDefaultValues", "updateFromPMPageFormat", "updateFromPMPrintSettings",
        "takeSettingsFromPDFInfo:",
    }:
        return "depends on printer settings or the host printing system"
    pattern = APPKIT_UNSAFE_SELECTORS.get(class_name)
    if pattern and pattern.search(selector):
        return "needs a drawing context, window, or system input state"
    if class_name == "NSEvent" and selector in {"modifierFlags", "pressedMouseButtons", "mouseLocation"}:
        return "depends on the host's current input state"
    return None


def _clean_type(value: str) -> str:
    value = re.sub(r"\b(?:const|volatile|restrict|__kindof|_Nullable|_Nonnull|_Null_unspecified|nullable|nonnull|__nullable|__nonnull|CF_AVAILABLE|CF_DEPRECATED|NS_AVAILABLE|NS_DEPRECATED|API_AVAILABLE|API_DEPRECATED|NS_RETURNS_RETAINED|NS_RETURNS_NOT_RETAINED|CF_RETURNS_RETAINED|CF_RETURNS_NOT_RETAINED)\b", " ", value)
    value = re.sub(r"\s+", " ", value).strip()
    return value


def _base_type(value: str) -> str:
    value = _clean_type(value)
    value = re.sub(r"\[[^]]*\]", " ", value)
    return value.replace("*", " ").strip()


def _is_cf_ref(value: str) -> bool:
    return "*" not in value and bool(re.fullmatch(r"(?:CF|CG|CT|CV|CM|Sec)[A-Za-z0-9_]*Ref", _base_type(value)))


_NON_CF_GRAPHICS_REFS = {
    "CGPDFArrayRef", "CGPDFDictionaryRef", "CGPDFObjectRef", "CGPDFStreamRef", "CGPDFStringRef",
    "CGPDFContentStreamRef", "CGPDFOperatorTableRef", "CGPDFScannerRef",
}


def _is_cf_string_alias(value: str) -> bool:
    return _base_type(value) in {
        "CFCalendarIdentifier", "CFDateFormatterKey", "CFLocaleIdentifier", "CFLocaleKey", "CFNotificationName",
        "CFNumberFormatterKey", "CFRunLoopMode", "CFStreamPropertyKey", "CFStringTransformIdentifier",
    }


def _is_objc_object(value: str) -> bool:
    base = _base_type(value)
    if _is_function_pointer(value) or _scalar_kind(value) or _pointer_depth(value) > 1:
        return False
    if base in {"id", "Class", "instancetype", "ObjectType", "KeyType", "ValueType", "NSComparator"} or re.fullmatch(r"id<[^>]+>", base):
        if base == "id<NSPredicateValidating>":
            return False
        return True
    base = base.split("<", 1)[0].strip()
    named_string = base.startswith("NS") and base.endswith(("Key", "Name", "Identifier", "Domain"))
    named_string = named_string or base.startswith("AV") and base.endswith(
        ("Key", "Name", "Identifier", "Domain", "Type", "Format", "Mode", "Option"))
    named_string = named_string or base in {
        "NSStringTransform", "NSLinguisticTagScheme",
        "CALayerContentsFilter", "CALayerContentsGravity", "CALayerCornerCurve",
        "CAMediaTimingFunctionName", "CAEmitterLayerEmitterMode", "CAEmitterLayerEmitterShape",
        "CAShapeLayerFillRule", "CAShapeLayerLineCap", "CAShapeLayerLineJoin",
        "CATextLayerAlignmentMode", "CATextLayerTruncationMode", "CATransitionType",
        "CATransitionSubtype", "CAValueFunctionName",
    }
    if _is_cf_string_alias(value) or named_string:
        return True
    if base in {"NSZone", "NSDecimal", "NSHashEnumerator", "NSMapEnumerator", "NSPredicateValidating", "NSHashTableCallBacks",
                "NSMapTableKeyCallBacks", "NSMapTableValueCallBacks", "NSUncaughtExceptionHandler"}:
        return False
    return bool("*" in value and re.fullmatch(
        r"(?:NS|__NS|CA|CI|UT|CN|CL|MTL|AV|PDF|IK|OD|SK|LP|AU|MIDI)[A-Za-z0-9_]+", base))


def _pointer_depth(value: str) -> int:
    depth = 0
    generic_depth = 0
    for character in _clean_type(value):
        if character == "<":
            generic_depth += 1
        elif character == ">" and generic_depth:
            generic_depth -= 1
        elif character == "*" and generic_depth == 0:
            depth += 1
    return depth


def _is_function_pointer(value: str) -> bool:
    return bool(re.search(r"\(\s*\*|\(\s*\^|\(\s*\*\s*\w+\s*\)", value))


def _enum_pool(parameter: dict, enum_values: list[dict]) -> list[int]:
    names = {_clean_type(parameter.get("type", "")), _clean_type(parameter.get("desugared_type", ""))}
    enum_match = re.search(r"\benum\s+(\w+)", " ".join(names))
    if enum_match:
        names.add(enum_match.group(1))
    prefixes = {
        "CFStringEncoding": ("kCFStringEncoding",),
        "CFStringCompareFlags": ("kCFCompare",),
        "CFNumberFormatterStyle": ("kCFNumberFormatter",),
        "CFDateFormatterStyle": ("kCFDateFormatter",),
    }
    type_name = _base_type(parameter.get("type", ""))
    wanted_prefixes = prefixes.get(type_name, ())
    values = []
    for entry in enum_values:
        matched_enum = entry.get("enum") in names or entry.get("enum") and re.search(
            rf"\b{re.escape(entry['enum'])}\b", " ".join(names))
        matched_prefix = any(entry.get("name", "").startswith(prefix) for prefix in wanted_prefixes)
        if matched_enum or matched_prefix:
            try:
                numeric = int(str(entry.get("value")), 0)
            except ValueError:
                continue
            if numeric not in values:
                values.append(numeric)
    return values[:MAX_CASES]


def _category(name: str) -> str:
    lower = name.lower()
    if "string" in lower or "character" in lower or "tokenizer" in lower:
        return "strings"
    if "number" in lower or "decimal" in lower or "math" in lower:
        return "numbers"
    if "date" in lower or "calendar" in lower or "timezone" in lower or "time_zone" in lower:
        return "dates"
    if "url" in lower or "uri" in lower:
        return "urls"
    if "data" in lower or "stream" in lower:
        return "data"
    if "array" in lower or "dictionary" in lower or "set" in lower or "collection" in lower:
        return "collections"
    if "error" in lower or "exception" in lower:
        return "errors"
    return "other"


def _skip_reason(name: str, framework: str = "") -> str | None:
    for category, pattern in SIDE_EFFECT_RULES:
        if framework == "CFNetwork" and category == "network" and name.startswith("CFHTTPMessage"):
            continue
        if framework == "CFNetwork" and category == "filesystem" and name == "CFHTTPMessageCopyRequestURL":
            continue
        if framework == "Foundation" and category == "filesystem" and name in {
            "NSFileWrapper -setFileAttributes:", "NSFileWrapper -fileWrappers", "NSFileWrapper -setFilename:",
            "NSFileWrapper -isDirectory", "NSFileWrapper -isRegularFile", "NSFileWrapper -isSymbolicLink",
            "NSFileWrapper -setPreferredFilename:", "NSFileWrapper -regularFileContents",
            "NSFileWrapper -serializedRepresentation", "NSFileWrapper -addFileWrapper:",
            "NSFileWrapper -addRegularFileWithContents:preferredFilename:",
            "NSFileWrapper -addSymbolicLinkWithDestination:preferredFilename:",
            "NSFileWrapper -initDirectoryWithFileWrappers:", "NSFileWrapper -initRegularFileWithContents:",
            "NSFileWrapper -initSymbolicLinkWithDestination:", "NSFileWrapper -keyForFileWrapper:",
            "NSFileWrapper -removeFileWrapper", "NSFileWrapper -symbolicLinkDestination",
        }:
            continue
        if framework == "CoreData" and category == "filesystem" and name in {
            "NSPersistentStoreDescription -initWithURL:",
            "NSPersistentStoreDescription +persistentStoreDescriptionWithURL:",
        }:
            continue
        if pattern.search(name):
            return f"side-effect category: {category}"
    if name == "CFGetRetainCount":
        return "runtime-specific value: retain counts are not stable across implementations"
    if name == "NSOrderedCollectionDifference -initWithChanges:":
        return "needs paired ordered-collection changes with valid indexes"
    if name == "NSArray -addObserver:toObjectsAtIndexes:forKeyPath:options:context:":
        return "registers a KVO observer without a safe cleanup context"
    if name in {"NSDeallocateObject", "NSDecrementExtraRefCountWasZero", "NSExtraRefCount"}:
        return "object lifetime helper needs a privately owned runtime object"
    if name.startswith("NSXMLDocument -objectByApplyingXSLT"):
        return "XSLT engine is not included in Finch"
    if name.startswith("NSByteCountFormatter ") and "stringFrom" in name:
        return "uses the current locale and this formatter has no locale setting"
    if name.startswith("NSEnergyFormatter ") and re.search(r"(?:stringFrom|unitStringFrom)", name):
        return "chooses localized energy names without a formatter locale setting"
    if name in {
        "NSProgress -becomeCurrentWithPendingUnitCount:",
        "NSProgress -resignCurrent",
        "NSProgress -performAsCurrentWithPendingUnitCount:usingBlock:",
        "NSProgress -publish",
        "NSProgress -unpublish",
        "NSProgress +addSubscriberForFileURL:withPublishingHandler:",
        "NSProgress +removeSubscriber:",
    }:
        return "changes thread-wide progress or publishes through the file system"
    if name in {
        "CTFontDrawImageFromAdaptiveImageProviderAtPoint",
        "CTFontGetTypographicBoundsForAdaptiveImageProvider",
    }:
        return "adaptive image provider protocol object needs a host image provider"
    if name == "CGImageCreateWithJPEGDataProvider":
        return "the input pool has no valid in-memory JPEG fixture"
    if name == "NSExpression -initWithExpressionType:":
        return "abstract NSExpression cannot be instantiated directly"
    if name == "NSObject +setKeys:triggerChangeNotificationsForDependentKey:":
        return "registers process-wide KVO dependencies and cannot be reset between cases"
    if name.startswith("CTFontManager") and re.search(r"Enable|Register|Unregister", name):
        return "changes process-wide font registration state"
    return None


def _int_values(parameter: dict, function_name: str = "") -> list[int]:
    qtype = _clean_type(parameter.get("type", ""))
    desugared = _clean_type(parameter.get("desugared_type", qtype))
    typename = _base_type(desugared or qtype)
    name = parameter.get("name", "").lower()
    if function_name.startswith("CMTime") and "scale" in name:
        return [1, 2, 30, 60000]
    if function_name.startswith("CVPixelBuffer") and name in {"planeindex", "plane"}:
        return [0, 1]
    if name in {"width", "height", "widthinpixels", "heightinpixels"}:
        return [1, 2, 8]
    if name in {"bytesperrow", "rowbytes"} and function_name.startswith(("CG", "CGBitmap")):
        return [256]
    if function_name == "CGImageMaskCreate" and name in {"bitspercomponent", "bitsperpixel"}:
        return [8]
    if name in {"bytesperpixel", "bitsperpixel"} and function_name.startswith("CG"):
        return [32]
    if name == "bitspercomponent" and function_name.startswith("CG"):
        return [8]
    if "power" in name:
        return [0, 1, 2, 3]
    if function_name == "CTGlyphInfoCreateWithGlyph" and "glyph" in name:
        return [1, 2, 3, 4, 5]
    if name in {"basedirection", "direction", "writingdirection"}:
        # NSWritingDirection has only Natural, LTR, and RTL as documented inputs.
        return [-1, 0, 1]
    if (name.startswith("idx") or any(word in name for word in
            ("index", "indices", "location", "loc", "offset", "position", "start", "end"))):
        return [0, 1]
    if "page" in name:
        return [1, 2, 4]
    if "byte" in name:
        return [0, 1, 2, 16]
    if "scale" in name:
        return [-2, 0, 2]
    if any(word in name for word in ("flags", "options", "mask")):
        return [0, 1, 2]
    if any(word in name for word in ("length", "count", "capacity", "size", "limit", "bits", "num", "len")):
        # These values stay inside the small objects the input pool creates.
        return [0, 1, 2]
    if "hour" in name:
        return [0, 1, 12]
    if "minute" in name or "second" in name:
        return [0, 1, 59]
    if "month" in name:
        return [1, 2, 12]
    if "day" in name:
        return [1, 2, 28]
    if "year" in name or name == "value":
        return [0, 1, -1, 2]
    if "unsigned" in desugared or typename.startswith("u") or typename in ("size_t", "NSUInteger", "CFOptionFlags"):
        return [0, 1, 2, 255, 65535, 2**32 - 1, 2**64 - 1]
    if "char" in typename:
        return [0, 1, -1, 127, -128]
    if "short" in typename:
        return [0, 1, -1, 32767, -32768]
    if "long long" in desugared or typename in ("int64_t", "NSInteger", "CFIndex", "long"):
        return [0, 1, -1, 2**63 - 1, -(2**63)]
    return [0, 1, -1, 2**31 - 1, -(2**31)]


def _float_values() -> list[str]:
    return ["0.0", "-0.0", "INFINITY", "-INFINITY", "NAN", "0x1p-1074", "0.5"]


def _is_time_type(value: str) -> bool:
    return _base_type(value) in {"CFAbsoluteTime", "CFTimeInterval", "NSTimeInterval"}


def _scalar_kind(value: str) -> str | None:
    clean = _clean_type(value)
    base = _base_type(clean)
    if base.startswith("struct "):
        base = base[7:].strip()
    if base in ("BOOL", "Boolean", "bool", "_Bool"):
        return "bool"
    if base in ("float", "double", "long double", "CGFloat", "CFAbsoluteTime", "CFTimeInterval", "NSTimeInterval"):
        return "float"
    if base in ("CFRange", "NSRange"):
        return "range"
    if base in {"AVAudioFramePosition", "AudioChannelLayoutTag"}:
        return "integer"
    if base == "NSLayoutPriority":
        return "float"
    if base in ("CGPoint", "CGSize", "CGRect", "NSPoint", "NSSize", "NSRect", "NSEdgeInsets",
        "NSAffineTransformStruct", "CGAffineTransform", "CATransform3D", "CMTime", "CMTimeRange",
                "CMTimeMapping", "CMSampleTimingInfo", "CMVideoDimensions", "MTLSize", "MTLOrigin",
        "MTLRegion", "MTLClearColor", "MTLSamplePosition", "MTL4BufferRange", "NSOperatingSystemVersion"):
        return "struct"
    if base in ("void", "id", "Class", "SEL", "instancetype"):
        return None
    if re.fullmatch(r"(?:unsigned|signed)?\s*(?:char|short|int|long|long long|size_t|ssize_t|NSUInteger|NSInteger|CFIndex|CFOptionFlags|CFTypeID|CFStringEncoding|CFNumberType|CFCalendarUnit|CFStringCompareFlags|unichar|UniChar|UTF32Char|UInt8|UInt16|UInt32|UInt64|SInt8|SInt16|SInt32|SInt64|uint8_t|uint16_t|uint32_t|uint64_t|int8_t|int16_t|int32_t|int64_t|CGGlyph|CGFontIndex|CTFontTableTag|NSComparisonResult|CFComparisonResult)", base):
        return "integer"
    if base in {
        "NSGlyph", "NSTIFFCompression", "NSControlTint", "NSColorSystemEffect",
        "NSHorizontalDirections", "NSVerticalDirections", "NSCursorFrameResizePosition",
        "NSControlSize", "NSCompositingOperation", "NSWindingRule", "NSLayoutAttribute",
        "NSLayoutConstraintOrientation", "NSTextAlignment", "NSPaperOrientation",
        "NSFontDescriptorSymbolicTraits", "CNContactFormatterStyle", "CNPostalAddressFormatterStyle",
        "CNContactSortOrder", "CNContactType", "NSCellAttribute", "NSControlStateValue",
        "NSCursorFrameResizeDirections", "NSLayoutRelation", "NSRectEdge", "NSDeleteRule",
        "NSComparisonPredicateModifier", "NSFormattingContext", "NSDateFormatterBehavior",
        "NSNumberFormatterBehavior", "NSItemProviderRepresentationVisibility", "NSKeyValueChange",
        "NSRelativePosition", "NSNotificationCoalescing", "NSByteCountFormatterUnits",
        "NSDateComponentsFormatterZeroFormattingBehavior", "NSAttributedStringMarkdownInterpretedSyntax",
        "NSSelectionGranularity", "NSSelectionAffinity", "NSTextLayoutOrientation",
        "NSViewLayerContentsPlacement", "NSImageAlignment", "NSImageScaling", "NSSegmentSwitchTracking",
        "NSGrammaticalGender", "NSGrammaticalNumber", "NSGrammaticalPartOfSpeech",
        "NSOperationQueuePriority", "NSInsertionPosition", "NSSearchPathDirectory",
        "NSDataCompressionAlgorithm", "NSTestComparisonOperation", "MTLBlendFactor", "MTLBlendOperation",
        "MTLStencilOperation", "MTLCompareFunction", "MTLSamplerMinMagFilter", "MTLSamplerMipFilter",
        "MTLPrimitiveTopologyClass", "MTLAccelerationStructureUsage", "MTLBindingAccess",
        "MTLStepFunction", "MTLCaptureDestination", "MTLCommandBufferErrorOption", "MTLIOPriority",
        "MTLMutability", "MTLLoadAction", "MTLStoreAction", "MTLTensorUsage", "MTLTextureUsage",
        "MTLTextureSwizzleChannels", "MTLVertexStepFunction", "MTLCurveBasis", "MTLCurveEndCaps",
        "MTLMatrixLayout", "CIDataMatrixCodeECCVersion",
    }:
        return "integer"
    # The name pattern below would read these structs as integers.
    if base in {"CFGregorianUnits", "CFGregorianDate"}:
        return None
    if re.fullmatch(r"(?:NS|CF|CG|CT|CV|CM|Sec|CA|CI|UT|CN|CL|MTL|AV)[A-Za-z0-9_]*(?:Options|Flags|Mask|Style|Type|Unit|Mode|Kind|Format|Encoding|Result|Return|State|Status|Policy|Level|Order|Direction|Phase|Quality|RoundingMode|Model|Intent|Info|Scale|Count|Index|Dimensions|Operation|Factor|Usage|Attribute|Rule|Relation|Value|Modifier|Visibility|Coalescing|Units|Priority|Compression|Behavior|Position|ResizeDirections|TopologyClass|EndCaps|Mutability|Access|StepFunction|Destination)", base):
        return "integer"
    if base in {"OSStatus", "OSErr", "OSType", "FourCharCode", "CMItemCount", "CMItemIndex", "CMTimeScale", "CMVideoCodecType", "CMMediaType", "CVReturn"}:
        return "integer"
    return None


def _c_input(parameter: dict, index: int, enum_values: list[dict], function_name: str,
             nonempty_objects: bool = False, framework: str = "") -> tuple[str, list[str], list[str]] | tuple[None, str, None]:
    """Return expression, declarations, output readers; reject unsafe unknown pointers."""
    qtype = parameter.get("type", "")
    clean = _clean_type(qtype)
    base = _base_type(clean)
    name = parameter.get("name", f"arg{index}")
    case_index = f"typed_case_{index}"
    safe_name = re.sub(r"\W+", "_", name)
    local = f"typed_arg_{index}"
    if _is_function_pointer(qtype):
        return None, "callback parameters need API-specific safe blocks", None
    if framework == "CoreServices" and base == "CFStringRef" and function_name.startswith("UTType"):
        lower = name.lower()
        if "tagclass" in lower:
            return "(CFStringRef)kUTTagClassFilenameExtension", [], []
        if "conforming" in lower:
            return '(CFStringRef)CFSTR("public.image")', [], []
        if "tag" in lower:
            return f'(CFStringRef)(({case_index} & 1) ? CFSTR("png") : CFSTR("txt"))', [], []
        if any(word in lower for word in ("uti", "identifier", "type")):
            return f'(CFStringRef)(({case_index} & 1) ? CFSTR("public.jpeg") : CFSTR("public.plain-text"))', [], []
    if framework == "CoreVideo" and "*" not in clean and base in {"CFDictionaryRef", "CFMutableDictionaryRef"} and function_name.startswith("CVPixelBuffer"):
        return f"({qtype})auto_cv_attributes({case_index}, {json.dumps(function_name)}, {json.dumps(name)})", [], []
    if "*" not in clean and base.startswith("CV") and base.endswith("Ref"):
        if framework == "CoreVideo" or framework == "CoreMedia":
            expr = f"({qtype})auto_cv_input(\"{base}\", {case_index}, {json.dumps(function_name)}, {json.dumps(name)})"
            if parameter.get("nullable"):
                expr = f"({qtype})({case_index} == 7 ? NULL : {expr})"
            return expr, [], []
    if "*" not in clean and base.startswith("CM") and base.endswith("Ref"):
        expr = f"({qtype})auto_cm_input(\"{base}\", {case_index}, {json.dumps(function_name)}, {json.dumps(name)})"
        if parameter.get("nullable"):
            expr = f"({qtype})({case_index} == 7 ? NULL : {expr})"
        return expr, [], []
    if "*" not in clean and base.startswith("Sec") and base.endswith("Ref"):
        expr = f"({qtype})auto_security_input(\"{base}\", {case_index}, {json.dumps(function_name)}, {json.dumps(name)})"
        if parameter.get("nullable"):
            expr = f"({qtype})({case_index} == 7 ? NULL : {expr})"
        return expr, [], []
    if base == "CFAllocatorRef":
        if "deallocator" in name.lower():
            return "kCFAllocatorNull", [], []
        return "kCFAllocatorDefault", [], []
    if base == "CFNotificationCenterRef":
        return "(CFNotificationCenterRef)CFNotificationCenterGetLocalCenter()", [], []
    if _is_cf_string_alias(qtype):
        if base == "CFLocaleIdentifier":
            return f"(CFLocaleIdentifier)auto_locale_identifier({case_index})", [], []
        constant = {
            "CFCalendarIdentifier": "kCFGregorianCalendar",
            "CFDateFormatterKey": "kCFDateFormatterTimeZone",
            "CFLocaleKey": "kCFLocaleIdentifier",
            "CFNotificationName": "kCFTimeZoneSystemTimeZoneDidChangeNotification",
            "CFNumberFormatterKey": "kCFNumberFormatterDecimalSeparator",
            "CFRunLoopMode": "kCFRunLoopDefaultMode",
            "CFStreamPropertyKey": "kCFStreamPropertyDataWritten",
            "CFStringTransformIdentifier": "kCFStringTransformToLatin",
        }.get(base)
        if constant:
            return f"({qtype}){constant}", [], []
        return None, f"no declared string constant for {base}", None
    if _is_objc_object(qtype):
        type_literal = json.dumps(qtype)
        expr = f"({qtype})auto_object(@{type_literal}, {case_index})"
        if parameter.get("nullable"):
            expr = f"({qtype})({case_index} == 7 ? NULL : {expr})"
        return expr, [], []
    if base.startswith(("CG", "CT")) and base.endswith("Ref"):
        supported = {
            "CGColorSpaceRef", "CGColorRef", "CGPathRef", "CGMutablePathRef", "CGContextRef",
            "CGImageRef", "CGDataProviderRef", "CGDataConsumerRef", "CGFontRef", "CGImageSourceRef",
            "CGImageDestinationRef", "CGPDFDocumentRef", "CGPDFPageRef", "CGPDFContentStreamRef",
            "CGPDFOperatorTableRef", "CGPDFScannerRef", "CTFontRef", "CTFontDescriptorRef",
            "CTLineRef", "CTFramesetterRef",
        }
        if base not in supported:
            if parameter.get("nullable"):
                return f"({qtype})NULL", [], []
            return None, f"no safe object factory for {base}", None
        expr = f"({qtype})auto_graphics_input(\"{base}\", {case_index}, {json.dumps(function_name)}, {json.dumps(name)})"
        safe_null = (function_name, name) != ("CGImageCreateCopyWithContentHeadroom", "image")
        if parameter.get("nullable") and safe_null:
            expr = f"({qtype})({case_index} == 7 ? NULL : {expr})"
        return expr, [], []
    if _is_cf_ref(qtype):
        if framework == "CFNetwork" and base == "CFHTTPMessageRef":
            return f"(CFHTTPMessageRef)auto_cfnetwork_message({json.dumps(function_name)}, {json.dumps(name)}, {case_index})", [], []
        if base == "CFReadStreamRef":
            return f"(CFReadStreamRef)auto_cf_input(\"CFReadStreamRef\", {case_index}, 0, {json.dumps(function_name)}, {json.dumps(name)})", [], []
        if base == "CFWriteStreamRef":
            return f"(CFWriteStreamRef)auto_cf_input(\"CFWriteStreamRef\", {case_index}, 0, {json.dumps(function_name)}, {json.dumps(name)})", [], []
        if base in ("CFTypeRef", "CFPropertyListRef", "CFArrayRef", "CFMutableArrayRef", "CFDictionaryRef", "CFMutableDictionaryRef", "CFSetRef", "CFMutableSetRef", "CFBagRef", "CFMutableBagRef", "CFStringRef", "CFMutableStringRef", "CFDataRef", "CFMutableDataRef", "CFDateRef", "CFNumberRef", "CFBooleanRef", "CFNullRef", "CFURLRef", "CFUUIDRef", "CFCharacterSetRef", "CFMutableCharacterSetRef", "CFLocaleRef", "CFTimeZoneRef", "CFCalendarRef", "CFErrorRef", "CFAttributedStringRef", "CFMutableAttributedStringRef", "CFDateFormatterRef", "CFNumberFormatterRef"):
            nonempty = int(nonempty_objects or bool(re.search(r"Index|Indices|Range|Bytes|Character|Substring|Delete|Replace|Insert|Append|Localizations|Combining", function_name, re.I)))
            expr = f"({qtype})auto_cf_input(\"{base}\", {case_index}, {nonempty}, {json.dumps(function_name)}, {json.dumps(name)})"
            safe_null = (function_name, name) not in {
                ("CGColorGetConstantColor", "colorName"),
                ("CGFontGetGlyphWithGlyphName", "name"),
            }
            if parameter.get("nullable") and safe_null:
                expr = f"({qtype})({case_index} == 7 ? NULL : {expr})"
            return expr, [], []
        if parameter.get("nullable"):
            return f"({qtype})NULL", [], []
        return None, f"no safe object factory for {base}", None

    if base == "CFTypeID":
        return f"(CFTypeID)auto_type_id({case_index})", [], []
    if base == "CFStringEncoding" and function_name in {
        "CFStringCreateWithCString", "CFStringCreateWithCStringNoCopy", "CFStringAppendCString"
    }:
        values_name = f"typed_encoding_{index}"
        decl = f"static const CFStringEncoding {values_name}[] = {{kCFStringEncodingMacRoman, kCFStringEncodingWindowsLatin1, kCFStringEncodingISOLatin1, kCFStringEncodingASCII, kCFStringEncodingUTF8}};"
        return f"({qtype}){values_name}[{case_index} % (sizeof({values_name}) / sizeof({values_name}[0]))]", [decl], []
    if function_name == "CFDataCreateMutableCopy" and name.lower() == "capacity":
        return f"({qtype})0", [], []
    if function_name == "CFStringGetHyphenationLocationBeforeIndex" and name.lower() == "location":
        values_name = f"typed_hyphenation_location_{index}"
        decl = f"static const CFIndex {values_name}[] = {{5, 8}};"
        return f"({qtype}){values_name}[{case_index} % 2]", [decl], []
    if function_name in {"CFStringGetFileSystemRepresentation", "CFURLGetFileSystemRepresentation"} and "len" in name.lower():
        return f"({qtype})65537", [], []
    if function_name == "CFNumberCreate" and base == "CFNumberType":
        return "(CFNumberType)kCFNumberSInt64Type", [], []
    if function_name == "CFNumberFormatterCreateStringWithValue" and base == "CFNumberType":
        return "(CFNumberType)kCFNumberDoubleType", [], []
    if function_name == "CGImageMetadataTagCreate" and base == "CGImageMetadataType":
        return "(CGImageMetadataType)kCGImageMetadataTypeString", [], []
    if function_name == "CGBitmapContextCreate" and name.lower() == "bitmapinfo":
        return "(CGBitmapInfo)(kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big)", [], []
    if function_name == "CGImageCreate" and name.lower() == "bitmapinfo":
        return "(CGBitmapInfo)(kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big)", [], []
    if function_name == "CTFontDescriptorCreateCopyWithFamily" and name.lower() == "family":
        return '(CFStringRef)CFSTR("Helvetica")', [], []
    if function_name == "CTFontDescriptorCreateMatchingFontDescriptors" and name.lower() == "mandatoryattributes":
        return f"({qtype})NULL", [], []
    if function_name == "CTTypesetterCreateWithAttributedStringAndOptions" and name.lower() == "options":
        return f"({qtype})NULL", [], []
    if function_name == "CTFramesetterSuggestFrameSizeWithConstraints" and name.lower() == "frameattributes":
        return f"({qtype})NULL", [], []

    if framework == "CoreVideo" and base == "OSType":
        return f"({qtype})(({case_index} & 1) ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)", [], []
    if framework == "CoreMedia":
        if base in {"OSType", "FourCharCode", "CMMediaType"}:
            if "mediaType" in name.lower():
                return f"({qtype})kCMMediaType_Video", [], []
            if "codec" in name.lower() or "subtype" in name.lower():
                return f"({qtype})kCMVideoCodecType_JPEG", [], []
            return f"({qtype})'vide'", [], []

    if function_name == "CFNumberCreate" and _pointer_depth(qtype) == 1 and "void" in base and "value" in name.lower():
        decl = f"static const int64_t {local}[] = {{0, 1, -1, INT64_MAX, INT64_MIN, 42, -257, 255}};"
        return f"(const void *)&{local}[{case_index} % (sizeof({local}) / sizeof({local}[0]))]", [decl], []
    if function_name == "CFNumberFormatterCreateStringWithValue" and _pointer_depth(qtype) == 1 and "void" in base and "value" in name.lower():
        decl = f"static const double {local}[] = {{0.0, -0.0, 0.5, -1.25, 42.0, 1e6, 1e-6, 3.14159}};"
        return f"(const void *)&{local}[{case_index} % (sizeof({local}) / sizeof({local}[0]))]", [decl], []

    scalar_kind = _scalar_kind(qtype) if not _pointer_depth(qtype) else None
    if scalar_kind == "integer":
        choices = _enum_pool(parameter, enum_values)
        if choices:
            values_name = f"typed_enum_{index}"
            decl = f"static const long long {values_name}[] = {{{', '.join(str(v) for v in choices)}}};"
            return f"({qtype}){values_name}[{case_index} % (sizeof({values_name}) / sizeof({values_name}[0]))]", [decl], []
        values = _int_values(parameter, function_name)
        values_name = f"typed_int_{index}"
        unsigned = "unsigned" in _clean_type(parameter.get("desugared_type", qtype)) or base.startswith("u") or base in ("size_t", "NSUInteger", "CFOptionFlags", "CFTypeID", "UInt8", "UInt16", "UInt32", "UInt64")
        if unsigned:
            literal_values = [f"{value}ULL" if value >= 0 else f"({value})" for value in values]
            storage_type = "unsigned long long"
        else:
            literal_values = ["(-9223372036854775807LL - 1LL)" if value == -(2**63) else f"{value}LL" for value in values]
            storage_type = "long long"
        decl = f"static const {storage_type} {values_name}[] = {{{', '.join(literal_values)}}};"
        return f"({qtype}){values_name}[{case_index} % (sizeof({values_name}) / sizeof({values_name}[0]))]", [decl], []
    if scalar_kind == "bool":
        return f"({qtype})({case_index} & 1)", [], []
    if scalar_kind == "float":
        if function_name == "NSDivideRect" and "amount" in name.lower():
            values = f"typed_ns_geometry_{index}"
            return f"(CGFloat){values}[{case_index} % 4]", [f"static const CGFloat {values}[] = {{0, 1, 2, 5}};"], []
        if function_name in {"NSInsetRect", "NSOffsetRect"}:
            values = f"typed_ns_geometry_{index}"
            return f"(CGFloat){values}[{case_index} % 4]", [f"static const CGFloat {values}[] = {{0, 1, -1, 2}};"], []
        if (base == "CGFloat" and function_name.startswith(("CTFont", "CTLine")) and
                any(word in name.lower() for word in ("size", "pointsize"))):
            return f"({qtype})auto_font_size({case_index})", [], []
        if function_name.startswith(("CG", "CT")):
            if function_name == "CTLineCreateJustifiedLine" and "factor" in name.lower():
                return f"({qtype})auto_text_factor({case_index})", [], []
            if function_name.startswith("CTLine") and "width" in name.lower():
                return f"({qtype})auto_text_width({case_index})", [], []
            return f"({qtype})auto_graphics_real({case_index})", [], []
        return f"({qtype})auto_time({case_index})" if _is_time_type(qtype) else f"({qtype})auto_real({case_index})", [], []
    if scalar_kind == "range":
        if base == "CFRange":
            if function_name == "CFStringGetHyphenationLocationBeforeIndex":
                return "CFRangeMake(0, 11)", [], []
            if function_name == "CTFramesetterSuggestFrameSizeWithConstraints":
                return "CFRangeMake(0, 10)", [], []
            return f"CFRangeMake(0, (CFIndex)({case_index} & 1))", [], []
        return None, "NSRange is unavailable in this CoreFoundation C input context", None
    if scalar_kind == "struct":
        if base == "CATransform3D":
            return f"({qtype})auto_transform3d({case_index})", [], []
        if base == "MTLSize":
            return f"({qtype})MTLSizeMake(8, 4, 1)", [], []
        if base == "MTLOrigin":
            return f"({qtype})MTLOriginMake(1, 2, 0)", [], []
        if base == "MTLRegion":
            return f"({qtype})MTLRegionMake2D(1, 2, 8, 4)", [], []
        if base == "MTLClearColor":
            return f"({qtype})MTLClearColorMake(0.25, 0.5, 0.75, 1.0)", [], []
        if base == "MTLSamplePosition":
            return f"({qtype}){{0.25f, 0.75f}}", [], []
        if base == "NSOperatingSystemVersion":
            return f"({qtype}){{15, 0, 1}}", [], []
        if base == "CMTime":
            return f"({qtype})auto_cm_time({case_index})", [], []
        if base == "CMTimeRange":
            return f"({qtype})auto_cm_time_range({case_index})", [], []
        if base == "CMTimeMapping":
            return f"({qtype})auto_cm_time_mapping({case_index})", [], []
        if base == "CMSampleTimingInfo":
            return f"({qtype})auto_cm_sample_timing({case_index})", [], []
        if base == "CMVideoDimensions":
            return f"({qtype}){{(int32_t)(320 + ({case_index} & 1) * 160), (int32_t)(240 + ({case_index} & 1) * 120)}}", [], []
        if base in ("NSRect", "NSPoint", "NSSize"):
            constructor = {"NSRect": "NSMakeRect(1, 2, 5, 7)", "NSPoint": "NSMakePoint(3, -2)",
                           "NSSize": "NSMakeSize(4, 6)"}[base]
            return f"({qtype}){constructor}", [], []
        if base in ("CGRect", "CGPoint", "CGSize"):
            if function_name.startswith(("CG", "CT")):
                if base == "CGPoint":
                    return f"auto_point({case_index})", [], []
                if base == "CGSize":
                    if function_name == "CTFramesetterSuggestFrameSizeWithConstraints":
                        return "CGSizeMake(256, 256)", [], []
                    return f"auto_size({case_index})", [], []
                return f"auto_rect({case_index})", [], []
            constructor = {"CGRect": "CGRectMake(1, 2, 5, 7)", "CGPoint": "CGPointMake(3, -2)",
                           "CGSize": "CGSizeMake(4, 6)"}[base]
            return f"({qtype}){constructor}", [], []
        if base == "NSEdgeInsets":
            return f"({qtype}){{1, 2, 3, 4}}", [], []
        if base == "NSAffineTransformStruct":
            return f"({qtype}){{1.25, 0.5, -0.25, 2.0, 3.0, -4.0}}", [], []
        if base == "CGAffineTransform":
            if function_name.startswith(("CG", "CT")):
                return f"auto_affine({case_index})", [], []
            return f"({qtype})CGAffineTransformMake(1.25, 0.5, -0.25, 2.0, 3.0, -4.0)", [], []
        return f"({qtype}){{0}}", [], []

    depth = _pointer_depth(clean)
    if depth:
        if depth > 2:
            return None, f"unsupported {depth}-level pointer parameter", None
        if depth == 1 and base == "NSDecimal":
            number = f"typed_decimal_number_{index}"
            initial = f"[NSDecimalNumber decimalNumberWithString:decimal_values_{index}[{case_index} % 4]]" if "const" in qtype else "[NSDecimalNumber zero]"
            declarations = [
                f"static NSString *const decimal_values_{index}[] = {{@\"0\", @\"1.25\", @\"-1.5\", @\"999999.125\"}};",
                f"NSDecimalNumber *{number} = {initial};",
                f"NSDecimal {local} = [{number} decimalValue];",
            ]
            reader = f"auto_print(auto_canonical([NSDecimalNumber decimalNumberWithDecimal:{local}]));"
            return f"({qtype})&{local}", declarations, [reader]
        pointee_type = re.sub(r"\s*\*+", "", clean).strip()
        if framework == "CoreMedia" and depth == 1 and pointee_type in {
            "CMTime", "CMTimeRange", "CMTimeMapping", "CMSampleTimingInfo", "CMVideoDimensions"
        }:
            if "const" in qtype:
                expression = {
                    "CMTime": f"auto_cm_time({case_index})",
                    "CMTimeRange": f"auto_cm_time_range({case_index})",
                    "CMTimeMapping": f"auto_cm_time_mapping({case_index})",
                    "CMSampleTimingInfo": f"auto_cm_sample_timing({case_index})",
                    "CMVideoDimensions": "(CMVideoDimensions){640, 480}",
                }[pointee_type]
                decl = f"const {pointee_type} {local} = {expression};"
                return f"({qtype})&{local}", [decl], []
            decl = f"{pointee_type} {local} = {{0}};"
            reader = _c_return(pointee_type, local)[0]
            return f"({qtype})&{local}", [decl], [reader]
        if depth == 1 and pointee_type == "CGFloat" and "const" in qtype:
            if function_name == "CGColorSpaceCreateCalibratedGray":
                values = "0.95047, 1.0, 1.08883" if "white" in name.lower() else "0, 0, 0"
                decl = f"static const CGFloat {local}[3] = {{{values}}};"
                return f"({qtype}){local}", [decl], []
            if function_name == "CGColorSpaceCreateCalibratedRGB":
                if "white" in name.lower():
                    values = "0.95047, 1.0, 1.08883"
                elif "black" in name.lower():
                    values = "0, 0, 0"
                elif "gamma" in name.lower():
                    values = "1, 1, 1"
                else:
                    values = "0.4124, 0.2126, 0.0193, 0.3576, 0.7152, 0.1192, 0.1805, 0.0722, 0.9505"
                decl = f"static const CGFloat {local}[9] = {{{values}}};"
                return f"({qtype}){local}", [decl], []
            if function_name == "CGColorSpaceCreateLab":
                values = "0.95047, 1.0, 1.08883" if "white" in name.lower() else "-100, 100, -100, 100"
                decl = f"static const CGFloat {local}[4] = {{{values}}};"
                return f"({qtype}){local}", [decl], []
            decl = f"static const CGFloat {local}[8] = {{0, 0.2, 0.4, 0.6, 0.8, 1, 0.5, 0.25}};"
            return f"({qtype}){local}", [decl], []
        if depth == 1 and pointee_type == "CGPoint" and "const" in qtype and name.lower() in {"points", "vertices"}:
            decl = f"static const CGPoint {local}[4] = {{{{0, 0}}, {{4, 0}}, {{4, 4}}, {{0, 4}}}};"
            return f"({qtype}){local}", [decl], []
        if depth == 1 and pointee_type == "CGRect" and "const" in qtype and name.lower() in {"rects", "rectangles"}:
            decl = f"const CGRect {local}[4] = {{CGRectMake(0, 0, 4, 4), CGRectMake(1, 1, 2, 2), CGRectMake(2, 0, 3, 3), CGRectMake(0, 0, 1, 1)}};"
            return f"({qtype}){local}", [decl], []
        if depth == 1 and "CGPath" in function_name and any(word in name.lower() for word in ("length", "dash")):
            decl = f"static const CGFloat {local}[8] = {{2, 1, 3, 2, 1, 1, 4, 2}};"
            return f"({qtype}){local}", [decl], []
        if depth == 1 and "CGBitmapContextCreate" == function_name and name.lower() == "data":
            decl = f"UInt8 {local}[16384] = {{0}};"
            return f"(void *){local}", [decl], []
        if re.search(r"\b(?:char|signed char|unsigned char|UInt8|SInt8|uint8_t|int8_t)\s*\*", clean) and depth == 1:
            if function_name in {"CFAttributedStringGetBidiLevelsAndResolvedDirections", "CFAttributedStringGetStatisticalWritingDirections"} and re.search(r"bidi|level|direction", name, re.I):
                decl = f"UInt8 {local}[256] = {{0}};"
                return f"({qtype}){local}", [decl], [f"auto_print_bytes({local}, sizeof({local}));"]
            if function_name in ("CFStringCreateWithBytes", "CFStringCreateWithBytesNoCopy") and "bytes" in name.lower():
                decl = f"static const UInt8 {local}[] = {{'a', 'b', 'c', 0xc3, 0xa9}};"
                return f"({qtype}){local}", [decl], []
            if "const" in qtype:
                if re.search(r"\b(?:UInt8|SInt8|uint8_t|int8_t|unsigned char)\b", clean):
                    decl = f"static const UInt8 {local}[] = {{0, 1, 127, 128, 254, 255}};"
                    return f"({qtype}){local}", [decl], []
                return f"(const char *)samples[{case_index} % SAMPLE_COUNT]", [], []
            if any(word in name.lower() for word in ("buffer", "output", "result", "out")):
                if function_name in {"CFStringGetFileSystemRepresentation", "CFURLGetFileSystemRepresentation"}:
                    decl = f"UInt8 {local}[65537] = {{0}};"
                    return f"({qtype}){local}", [decl], [f"auto_print_cstring((const char *){local});"]
                decl = f"UInt8 {local}[256] = {{0}};"
                return f"({qtype}){local}", [decl], [f"auto_print_bytes({local}, sizeof({local}));"]
            return f"({qtype})samples[{case_index} % SAMPLE_COUNT]", [], []
        if re.search(r"\b(?:UniChar|unichar|UTF16Char)\s*\*", clean) and depth == 1:
            if "const" in qtype:
                decl = f"static const UniChar {local}[] = {{'a', 0x00e9, 0x4e2d, 0}};"
                return f"({qtype}){local}", [decl], []
            decl = f"UniChar {local}[256] = {{0}};"
            return f"({qtype}){local}", [decl], [f"auto_print_bytes((const UInt8 *){local}, sizeof({local}));"]
        if depth == 1 and "void" in base and "const" in qtype:
            if any(word in name.lower() for word in ("bytes", "buffer", "characters")):
                decl = f"static const UInt8 {local}[] = {{0, 1, 127, 128, 254, 255}};"
                return f"({qtype}){local}", [decl], []
            return f"({qtype})auto_cf_input(\"CFTypeRef\", {case_index}, 0, {json.dumps(function_name)}, {json.dumps(name)})", [], []
        if depth == 2 and "void" in base and any(word in name.lower() for word in ("values", "keys")):
            if function_name.startswith(("CFArrayGetValues", "CFDictionaryGetKeysAndValues", "CFSetGetValues", "CFBagGetValues")):
                decl = f"const void *{local}[32] = {{0}};"
                return f"({qtype}){local}", [decl], [f"auto_print_cf((CFTypeRef){local}[0]);"]
            decl = f"const void *{local}[4] = {{(CFTypeRef)auto_cf_input(\"CFStringRef\", {case_index}, 1, {json.dumps(function_name)}, {json.dumps(name)}), (CFTypeRef)auto_cf_input(\"CFNumberRef\", {case_index}, 0, {json.dumps(function_name)}, {json.dumps(name)}), NULL, NULL}};"
            return f"({qtype}){local}", [decl], []
        if "CallBacks" in base and depth == 1:
            symbol = {
                "CFArrayCallBacks": "kCFTypeArrayCallBacks",
                "CFDictionaryKeyCallBacks": "kCFTypeDictionaryKeyCallBacks",
                "CFDictionaryValueCallBacks": "kCFTypeDictionaryValueCallBacks",
                "CFSetCallBacks": "kCFTypeSetCallBacks",
                "CFBagCallBacks": "kCFTypeBagCallBacks",
            }.get(base)
            if symbol:
                return f"({qtype})&{symbol}", [], []
        pointee = base
        if pointee == "void":
            if parameter.get("nullable") and "valuePtr" not in name and "buffer" not in name.lower():
                return "NULL", [], []
            if any(word in name.lower() for word in ("value", "buffer", "bytes", "result", "out", "destination")):
                decl = f"long double {local}[16] = {{0}};"
                return f"(void *){local}", [decl], [f"auto_print_bytes((const UInt8 *){local}, sizeof({local}));"]
            return None, "void pointer has no documented input or output role", None
        if depth == 1 and pointee in ("CFRange", "NSRange"):
            decl = f"{pointee} {local} = {{0, 0}};" if pointee == "CFRange" else ""
            # NSRange is not part of a CoreFoundation C harness.
            if not decl:
                return None, "unsupported range pointer in this framework", None
            return f"({qtype})&{local}", [decl], [f"printf(\"%ld,%ld\", (long){local}.location, (long){local}.length);"]
        if depth == 1 and pointee in ("NSPoint", "NSSize", "NSRect"):
            constructors = {
                "NSPoint": "NSMakePoint(3, -2)",
                "NSSize": "NSMakeSize(4, 6)",
                "NSRect": "NSMakeRect(1, 2, 5, 7)",
            }
            decl = f"{pointee} {local} = {constructors[pointee]};"
            if "const" in qtype:
                return f"({qtype})&{local}", [decl], []
            reader = _c_return(pointee, local)[0]
            return f"({qtype})&{local}", [decl], [reader]
        if depth == 1 and pointee == "CATransform3D":
            if "const" in qtype:
                return f"({qtype})&(CATransform3D){{1,0,0,0,0,1,0,0,0,0,1,0,1,2,0,1}}", [], []
            decl = f"CATransform3D {local} = auto_transform3d({case_index});"
            return f"({qtype})&{local}", [decl], [_c_return(pointee, local)[0]]
        if depth == 1 and _scalar_kind(pointee) in ("integer", "bool", "float", "struct"):
            if "const" in qtype:
                if pointee == "CGAffineTransform":
                    decl = f"const {pointee} {local} = auto_affine({case_index});"
                elif pointee == "CGPoint":
                    decl = f"const {pointee} {local} = auto_point({case_index});"
                elif pointee == "CGSize":
                    decl = f"const {pointee} {local} = auto_size({case_index});"
                elif pointee == "CGRect":
                    decl = f"const {pointee} {local} = auto_rect({case_index});"
                else:
                    return None, "input pointer lacks a safe backing value", None
                return f"({qtype})&{local}", [decl], []
            if pointee == "CGAffineTransform":
                init = f"auto_affine({case_index})"
            elif pointee == "CGPoint":
                init = f"auto_point({case_index})"
            elif pointee == "CGSize":
                init = f"auto_size({case_index})"
            elif pointee == "CGRect":
                init = f"auto_rect({case_index})"
            else:
                init = "{0}" if _scalar_kind(pointee) == "struct" else "0"
            decl = f"{pointee} {local} = {init};"
            if pointee in {"CGRect", "CGPoint", "CGSize", "CGAffineTransform"}:
                reader = _c_return(pointee, local)[0]
            elif pointee in {"CGGlyph", "CGFontIndex"} and any(word in name.lower() for word in ("glyph", "advance")):
                declaration = f"{pointee} {local}[32] = {{0}};"
                decl = declaration
                reader = f"auto_print_bytes((const UInt8 *){local}, sizeof({local}));"
            elif _scalar_kind(pointee) == "float":
                reader = f"printf(\"%a\", (double){local});"
            else:
                reader = f"printf(\"%lld\", (long long){local});"
            return f"({qtype}){local}" if "[32]" in decl else f"({qtype})&{local}", [decl], [reader]
        if depth == 1 and _is_cf_ref(pointee):
            decl = f"{pointee} {local} = NULL;"
            return f"({qtype})&{local}", [decl], [f"auto_print_cf((CFTypeRef){local});"]
        return None, f"no safe value builder for pointer type {qtype}", None
    return None, f"no safe input pool for type {qtype}", None


def _c_return(type_name: str, variable: str = "typed_result") -> tuple[str | None, str | None]:
    clean = _clean_type(type_name)
    base = _base_type(clean)
    if base == "void" and "*" not in clean:
        return 'fputs("void", stdout);', None
    if base == "CFTypeID":
        return f"auto_print_typeid({variable});", None
    if base in _NON_CF_GRAPHICS_REFS:
        return f'printf("pointer:%s", {variable} ? "nonnull" : "null");', None
    if _is_cf_ref(clean):
        if base == "CFHTTPMessageRef":
            return f"auto_cfnetwork_print_message({variable});", None
        return f"auto_print_cf((CFTypeRef){variable});", None
    if _is_cf_string_alias(clean):
        return f"auto_print_cf((CFTypeRef){variable});", None
    if _is_objc_object(clean):
        return f"auto_print(auto_canonical({variable}));", None
    if base == "CMTime":
        return f"auto_print_cm_time({variable});", None
    if base == "CMTimeRange":
        return f"auto_print_cm_time_range({variable});", None
    if base == "CMTimeMapping":
        return f"auto_print_cm_time_mapping({variable});", None
    if base == "CMSampleTimingInfo":
        return f"auto_print_cm_sample_timing({variable});", None
    if base == "CMVideoDimensions":
        return f'printf("dimensions:%d,%d", {variable}.width, {variable}.height);', None
    if "*" in clean:
        if "char *" in clean:
            return f"auto_print_cstring((const char *){variable});", None
        return f'printf("pointer:%s", {variable} ? "nonnull" : "null");', None
    scalar = _scalar_kind(clean)
    if scalar == "float":
        return f'printf("%a", (double){variable});', None
    if scalar == "range" and base == "CFRange":
        return f'printf("%ld,%ld", (long){variable}.location, (long){variable}.length);', None
    if scalar == "struct":
        if base == "CATransform3D":
            return (f'printf("transform3d:%a,%a,%a,%a,%a,%a,%a,%a,%a,%a,%a,%a,%a,%a,%a,%a", '
                    f'(double){variable}.m11, (double){variable}.m12, (double){variable}.m13, (double){variable}.m14, '
                    f'(double){variable}.m21, (double){variable}.m22, (double){variable}.m23, (double){variable}.m24, '
                    f'(double){variable}.m31, (double){variable}.m32, (double){variable}.m33, (double){variable}.m34, '
                    f'(double){variable}.m41, (double){variable}.m42, (double){variable}.m43, (double){variable}.m44);'), None
        if base == "NSPoint":
            return f'printf("point:%.5f,%.5f", (double){variable}.x, (double){variable}.y);', None
        if base == "NSSize":
            return f'printf("size:%.5f,%.5f", (double){variable}.width, (double){variable}.height);', None
        if base == "NSRect":
            return f'printf("rect:%.5f,%.5f,%.5f,%.5f", (double){variable}.origin.x, (double){variable}.origin.y, (double){variable}.size.width, (double){variable}.size.height);', None
        if base == "NSEdgeInsets":
            return f'printf("edge-insets:%.5f,%.5f,%.5f,%.5f", (double){variable}.top, (double){variable}.left, (double){variable}.bottom, (double){variable}.right);', None
        if base == "NSAffineTransformStruct":
            return f'printf("transform:%.5f,%.5f,%.5f,%.5f,%.5f,%.5f", (double){variable}.m11, (double){variable}.m12, (double){variable}.m21, (double){variable}.m22, (double){variable}.tX, (double){variable}.tY);', None
        if base in ("CGPoint", "CGSize", "CGRect", "CGAffineTransform"):
            if base == "CGPoint":
                appkit_code = f'printf("point:%.5f,%.5f", (double){variable}.x, (double){variable}.y);'
                graphics_code = f'printf("%a,%a", (double){variable}.x, (double){variable}.y);'
            elif base == "CGSize":
                appkit_code = f'printf("size:%.5f,%.5f", (double){variable}.width, (double){variable}.height);'
                graphics_code = f'printf("%a,%a", (double){variable}.width, (double){variable}.height);'
            elif base == "CGRect":
                appkit_code = f'printf("rect:%.5f,%.5f,%.5f,%.5f", (double){variable}.origin.x, (double){variable}.origin.y, (double){variable}.size.width, (double){variable}.size.height);'
                graphics_code = f'printf("%a,%a,%a,%a", (double){variable}.origin.x, (double){variable}.origin.y, (double){variable}.size.width, (double){variable}.size.height);'
            else:
                appkit_code = f'printf("transform:%.5f,%.5f,%.5f,%.5f,%.5f,%.5f", (double){variable}.a, (double){variable}.b, (double){variable}.c, (double){variable}.d, (double){variable}.tx, (double){variable}.ty);'
                graphics_code = f'printf("%a,%a,%a,%a,%a,%a", (double){variable}.a, (double){variable}.b, (double){variable}.c, (double){variable}.d, (double){variable}.tx, (double){variable}.ty);'
            return f"#ifdef FINCH_DIFFTEST_APPKIT\n{appkit_code}\n#else\n{graphics_code}\n#endif", None
    if scalar in ("integer", "bool"):
        if "unsigned" in clean or base.startswith("u") or base in ("size_t", "NSUInteger", "CFOptionFlags", "CFTypeID", "UInt8", "UInt16", "UInt32", "UInt64"):
            return f'printf("%llu", (unsigned long long){variable});', None
        return f'printf("%lld", (long long){variable});', None
    return None, f"unsupported return type {type_name}"


def _make_c_function(function: dict, enum_values: list[dict], finch_symbols: set[str],
                     framework: str = "") -> tuple[str | None, str | None]:
    name = function["name"]
    reason = _skip_reason(name, framework)
    if reason:
        return None, reason
    if function.get("inline"):
        return None, "SDK inline function has no Finch framework implementation to compare"
    if function.get("symbol") not in finch_symbols:
        return None, "Finch framework does not export this C symbol"
    if function.get("variadic"):
        return None, "variadic functions need API-specific format arguments"
    return_type = _clean_type(function.get("return_type", ""))
    return_code, reason = _c_return(return_type)
    if reason:
        return None, reason
    if name in {"CGFontCopyTableTags", "CTFontCopyAvailableTables"}:
        return_code = "auto_print_cgfont_table_tags(typed_result);"
    if name == "CGPDFContentStreamGetStreams":
        return_code = 'printf("array-count:%ld", typed_result ? (long)CFArrayGetCount(typed_result) : -1L);'
    declarations = []
    arguments = []
    readers = []
    font_checks = []
    parameters = function.get("parameters", [])
    nonempty_objects = any(re.search(r"range|index|indices|idx|position|location|\bloc\b", p.get("name", ""), re.I)
                           for p in parameters)
    for index, parameter in enumerate(parameters):
        declarations.append(f"const size_t typed_case_{index} = (case_index * {index * 2 + 1} + {index}) % {MAX_CASES};")
        expr, decl, out = _c_input(parameter, index, enum_values, name, nonempty_objects, framework)
        if expr is None:
            return None, decl
        declarations.extend(decl)
        readers.extend(out)
        qtype = parameter.get("type", "")
        base = _base_type(qtype)
        if base in {"CTFontRef", "CGFontRef"}:
            local = f"typed_object_{index}"
            declarations.append(f"{qtype} {local} = {expr};")
            arguments.append(local)
            font_checks.append(
                f'if (!auto_font_is_available((CFTypeRef){local}, typed_case_{index})) '
                f'{{ printf("%zu\\tfont-unavailable\\n", case_index); continue; }}')
        elif _is_cf_ref(qtype) and base.startswith("CFMutable"):
            local = f"typed_object_{index}"
            declarations.append(f"{qtype} {local} = {expr};")
            arguments.append(local)
            readers.append(f"auto_print_cf((CFTypeRef){local});")
        else:
            arguments.append(expr)
    case_count = MAX_CASES if function.get("parameters") else 1
    func_name = "typed_c_" + re.sub(r"\W+", "_", name)
    lines = [f"static void {func_name}(void)", "{", f"    for (size_t case_index = 0; case_index < {case_count}; case_index++) {{"]
    lines.extend(f"        {decl}" for decl in declarations)
    lines.extend(f"        {check}" for check in font_checks)
    call = f"{name}({', '.join(arguments)})"
    if _base_type(return_type) == "void" and "*" not in return_type:
        lines.append(f"        {call};")
        lines.append('        printf("%zu\\t", case_index);')
        lines.append(f"        {return_code}")
    else:
        lines.append(f"        {return_type} typed_result = {call};")
        lines.append('        printf("%zu\\t", case_index);')
        lines.append(f"        {return_code}")
    for reader in readers:
        lines.append('        putchar(\'\\t\');')
        lines.append(f"        {reader}")
    if base_return_type := _base_type(return_type):
        if base_return_type in {"CTFontRef", "CGFontRef"}:
            lines.append("        putchar('\\t');")
            lines.append("        auto_print_font_status((CFTypeRef)typed_result, case_index);")
    lines.extend(["        putchar('\\n');", "    }", "}"])
    return "\n".join(lines), None


def _make_c_variable(variable: dict, finch_symbols: set[str]) -> tuple[str | None, str | None]:
    name = variable["name"]
    if variable.get("symbol") not in finch_symbols:
        return None, "Finch framework does not export this C symbol"
    declared_type = variable.get("type", "")
    qtype = declared_type
    base = _base_type(qtype)
    if name.startswith("kCFAllocator"):
        printer = f'printf("pointer:%s", {name} ? "nonnull" : "null");'
    elif _base_type(qtype) == "CFTypeID":
        printer = f"auto_print_typeid({name});"
    elif _is_cf_ref(qtype):
        printer = f"auto_print_cf((CFTypeRef){name});"
    elif _is_cf_string_alias(qtype):
        printer = f"auto_print_cf((CFTypeRef){name});"
    else:
        # Public NSString aliases such as NSFileAttributeKey and
        # NSExceptionName are pointers after Clang resolves their typedef.
        qtype = variable.get("desugared_type", qtype)
        base = _base_type(qtype)
        if _is_objc_object(qtype):
            printer = f"auto_print(auto_canonical({name}));"
        elif _scalar_kind(qtype) == "float":
            printer = f'printf("%a", (double){name});'
        elif _scalar_kind(qtype) in ("integer", "bool"):
            cast = "unsigned long long" if "unsigned" in qtype or base.startswith("u") else "long long"
            printer = f'printf("%llu", ({cast}){name});' if cast.startswith("unsigned") else f'printf("%lld", ({cast}){name});'
        elif _scalar_kind(qtype) == "range" and base == "CFRange":
            printer = f'printf("%ld,%ld", (long){name}.location, (long){name}.length);'
        elif "char *" in qtype:
            printer = f"auto_print_cstring((const char *){name});"
        elif "*" in qtype:
            printer = f'printf("pointer:%s", {name} ? "nonnull" : "null");'
        else:
            return None, f"no canonical reader for variable type {declared_type}"
    func_name = "typed_v_" + re.sub(r"\W+", "_", name)
    return f"static void {func_name}(void) {{ {printer} putchar('\\n'); }}", None


def _c_runtime() -> str:
    return r'''
static double auto_real(size_t index)
{
    static const double values[] = {0.0, -0.0, INFINITY, -INFINITY, NAN, 0x1p-1074, 0.5};
    return values[index % (sizeof(values) / sizeof(values[0]))];
}

static double auto_font_size(size_t index)
{
    static const double sizes[] = {12, 16, 20, 24};
    return sizes[index % (sizeof(sizes) / sizeof(sizes[0]))];
}

static double auto_text_factor(size_t index)
{
    static const double factors[] = {0, 0.25, 0.5, 0.75, 1};
    return factors[index % (sizeof(factors) / sizeof(factors[0]))];
}

static double auto_text_width(size_t index)
{
    static const double widths[] = {96, 128, 192, 256};
    return widths[index % (sizeof(widths) / sizeof(widths[0]))];
}

static double auto_graphics_real(size_t index)
{
    static const double values[] = {0, 0.5, 1, 2, 4, 12.5, 64, 1.5};
    return values[index % (sizeof(values) / sizeof(values[0]))];
}

#ifdef FINCH_DIFFTEST_QUARTZCORE
static CATransform3D auto_transform3d(size_t index)
{
    CATransform3D value = CATransform3DIdentity;
    value.m41 = (CGFloat)(index % 3);
    value.m42 = 2;
    return value;
}
#endif

static double auto_time(size_t index)
{
    static const double values[] = {0.0, -1.0, 700000000.0, 800000000.0,
        1000000000.0, 123456789.0, 31536000.0, 86400.0};
    return values[index % (sizeof(values) / sizeof(values[0]))];
}

#if defined(FINCH_DIFFTEST_GRAPHICS)
static CGPoint auto_point(size_t index)
{
    static const CGFloat values[] = {0, 1, -2, 12.5, 100};
    CGFloat x = values[index % (sizeof(values) / sizeof(values[0]))];
    CGFloat y = values[(index * 3 + 1) % (sizeof(values) / sizeof(values[0]))];
    return CGPointMake(x, y);
}

static CGSize auto_size(size_t index)
{
    static const CGFloat values[] = {0, 1, 2, 12.5, 64};
    return CGSizeMake(values[index % (sizeof(values) / sizeof(values[0]))],
        values[(index * 3 + 1) % (sizeof(values) / sizeof(values[0]))]);
}

static CGRect auto_rect(size_t index)
{
    CGPoint origin = auto_point(index);
    CGSize size = auto_size(index + 1);
    return CGRectMake(origin.x, origin.y, size.width, size.height);
}

static CGAffineTransform auto_affine(size_t index)
{
    static const CGFloat shifts[] = {0, 1, -2, 0.5, 3};
    return CGAffineTransformMake(1, 0, 0, 1,
        shifts[index % (sizeof(shifts) / sizeof(shifts[0]))],
        shifts[(index * 3 + 1) % (sizeof(shifts) / sizeof(shifts[0]))]);
}

static CFDataRef auto_png_data(void)
{
    static const UInt8 png[] = {
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
        0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4,
        0x89, 0x00, 0x00, 0x00, 0x0a, 0x49, 0x44, 0x41,
        0x54, 0x78, 0x9c, 0x63, 0x00, 0x01, 0x00, 0x00,
        0x05, 0x00, 0x01, 0x0d, 0x0a, 0x2d, 0xb4, 0x00,
        0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae,
        0x42, 0x60, 0x82
    };
    return CFDataCreate(kCFAllocatorDefault, png, sizeof(png));
}

static CFDataRef auto_pdf_data(void)
{
    CGRect page = CGRectMake(0, 0, 64, 48);
    CFMutableDataRef data = CFDataCreateMutable(kCFAllocatorDefault, 0);
    CGDataConsumerRef consumer = CGDataConsumerCreateWithCFData(data);
    CGContextRef context = consumer ? CGPDFContextCreate(consumer, &page, NULL) : NULL;
    if (context) {
        CGPDFContextBeginPage(context, NULL);
        CGContextFillRect(context, CGRectMake(4, 5, 20, 12));
        CGPDFContextEndPage(context);
        CGContextRelease(context);
    }
    if (consumer) CGDataConsumerRelease(consumer);
    return data;
}

#if defined(FINCH_DIFFTEST_CORETEXT)
static CTFontRef auto_ct_font(size_t index)
{
    static CFStringRef names[] = {CFSTR("Helvetica"), CFSTR("Times"), CFSTR("Courier"), CFSTR("Inter-Regular")};
    return CTFontCreateWithName(names[index % (sizeof(names) / sizeof(names[0]))],
        (CGFloat[]){12, 16, 20, 24}[index % 4], NULL);
}
#endif

static Boolean auto_font_is_available(CFTypeRef font, size_t index)
{
    if (!font) return false;
    CFStringRef actual = NULL;
#if defined(FINCH_DIFFTEST_CORETEXT)
    if (CFGetTypeID(font) == CTFontGetTypeID()) actual = CTFontCopyPostScriptName((CTFontRef)font);
#endif
    if (!actual && CFGetTypeID(font) == CGFontGetTypeID()) actual = CGFontCopyPostScriptName((CGFontRef)font);
    if (!actual) return false;
    static CFStringRef appleNames[] = {CFSTR("Helvetica"), CFSTR("Times-Roman"), CFSTR("Courier"), CFSTR("Inter-Regular")};
    static CFStringRef finchNames[] = {CFSTR("LiberationSans"), CFSTR("LiberationSerif"), CFSTR("LiberationMono"), CFSTR("Inter-Regular")};
    CFStringRef expected = getenv("FINCH_FONT_DIRS") ? finchNames[index % 4] : appleNames[index % 4];
    Boolean available = CFStringCompare(actual, expected, 0) == kCFCompareEqualTo;
    CFRelease(actual);
    return available;
}

static void auto_print_font_status(CFTypeRef font, size_t index)
{
    fputs(auto_font_is_available(font, index) ? "font-available" : "font-unavailable", stdout);
}

static void auto_print_cgfont_table_tags(CFArrayRef tags)
{
    if (!tags) { fputs("null", stdout); return; }
    fputs("tags:[", stdout);
    for (CFIndex i = 0; i < CFArrayGetCount(tags); i++) {
        if (i) putchar(',');
        const void *value = CFArrayGetValueAtIndex(tags, i);
        uintptr_t raw = (uintptr_t)value;
        uint32_t tag = (uint32_t)raw;
        if (raw > UINT32_MAX)
            CFNumberGetValue((CFNumberRef)value, kCFNumberSInt32Type, (int32_t *)&tag);
        printf("%08x", tag);
    }
    putchar(']');
}

static CFTypeRef auto_graphics_input(const char *type, size_t index,
    const char *function_name, const char *parameter_name)
{
    (void)parameter_name;
    if (!strcmp(type, "CGColorSpaceRef")) {
        if (strstr(function_name, "ContentHeadroom"))
            return CGColorSpaceCreateWithName(kCGColorSpaceExtendedSRGB);
        return CGColorSpaceCreateDeviceRGB();
    }
    if (!strcmp(type, "CGColorRef")) {
        CGFloat components[] = {0.25, 0.5, 0.75, 1};
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGColorRef color = CGColorCreate(space, components);
        CGColorSpaceRelease(space); return color;
    }
    if (!strcmp(type, "CGPathRef") || !strcmp(type, "CGMutablePathRef")) {
        CGMutablePathRef path = CGPathCreateMutable();
        CGPathAddRect(path, NULL, auto_rect(index));
        if (strstr(function_name, "ContainsPoint")) CGPathAddEllipseInRect(path, NULL, CGRectMake(1, 1, 4, 4));
        return path;
    }
    if (!strcmp(type, "CGContextRef")) {
        size_t width = 16, height = 16, stride = width * 4;
        UInt8 *pixels = calloc(height, stride);
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = CGBitmapContextCreate(pixels, width, height, 8, stride, space,
            kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        CGColorSpaceRelease(space);
        return context;
    }
    if (!strcmp(type, "CGImageRef")) {
        size_t width = 2, height = 2, stride = width * 4;
        UInt8 pixels[] = {32, 96, 192, 255, 192, 96, 32, 255,
                          192, 96, 32, 255, 32, 96, 192, 255};
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = CGBitmapContextCreate(pixels, width, height, 8, stride, space,
            kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        CGColorSpaceRelease(space);
        CGImageRef image = context ? CGBitmapContextCreateImage(context) : NULL;
        if (context) CGContextRelease(context); return image;
    }
    if (!strcmp(type, "CGDataProviderRef")) {
        if (!strcmp(function_name, "CGDataProviderGetInfo")) {
            static UInt8 info_data[] = {1, 2, 3, 4};
            static int info_token;
            return CGDataProviderCreateWithData(&info_token, info_data, sizeof(info_data), NULL);
        }
        CFDataRef data = NULL;
        if (!strcmp(function_name, "CGImageCreate") || !strcmp(function_name, "CGImageMaskCreate")) {
            UInt8 bytes[16384] = {0};
            data = CFDataCreate(kCFAllocatorDefault, bytes, sizeof(bytes));
        } else {
            data = strstr(function_name, "PDF") ? auto_pdf_data() : auto_png_data();
        }
        CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
        CFRelease(data); return provider;
    }
    if (!strcmp(type, "CGDataConsumerRef")) {
        CFMutableDataRef data = CFDataCreateMutable(kCFAllocatorDefault, 0);
        CGDataConsumerRef consumer = CGDataConsumerCreateWithCFData(data);
        CFRelease(data); return consumer;
    }
    if (!strcmp(type, "CGFontRef")) {
        static CFStringRef names[] = {CFSTR("Helvetica"), CFSTR("Times"), CFSTR("Courier"), CFSTR("Inter-Regular")};
        return CGFontCreateWithFontName(names[index % 4]);
    }
#if defined(FINCH_DIFFTEST_IMAGEIO)
    if (!strcmp(type, "CGImageSourceRef")) {
        CFDataRef data = auto_png_data();
        CGImageSourceRef source = CGImageSourceCreateWithData(data, NULL);
        CFRelease(data); return source;
    }
    if (!strcmp(type, "CGImageDestinationRef")) {
        CFMutableDataRef data = CFDataCreateMutable(kCFAllocatorDefault, 0);
        CGImageDestinationRef destination = CGImageDestinationCreateWithData(data, CFSTR("public.png"), 1, NULL);
        CFRelease(data);
        if (destination && strcmp(function_name, "CGImageDestinationCopyImageSource")) {
            CFTypeRef image = auto_graphics_input("CGImageRef", index, function_name, parameter_name);
            if (image) { CGImageDestinationAddImage(destination, (CGImageRef)image, NULL); CFRelease(image); }
        }
        return destination;
    }
#endif
    if (!strcmp(type, "CGPDFDocumentRef")) {
        CFDataRef data = auto_pdf_data();
        CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
        CGPDFDocumentRef document = CGPDFDocumentCreateWithProvider(provider);
        if (provider) CGDataProviderRelease(provider); CFRelease(data); return document;
    }
    if (!strcmp(type, "CGPDFPageRef")) {
        CGPDFDocumentRef document = auto_graphics_input("CGPDFDocumentRef", index, function_name, parameter_name);
        return document ? CGPDFPageRetain(CGPDFDocumentGetPage(document, 1)) : NULL;
    }
    if (!strcmp(type, "CGPDFContentStreamRef")) {
        CGPDFPageRef page = auto_graphics_input("CGPDFPageRef", index, function_name, parameter_name);
        return page ? CGPDFContentStreamCreateWithPage(page) : NULL;
    }
    if (!strcmp(type, "CGPDFOperatorTableRef")) return CGPDFOperatorTableCreate();
    if (!strcmp(type, "CGPDFScannerRef")) {
        CGPDFContentStreamRef stream = auto_graphics_input("CGPDFContentStreamRef", index, function_name, parameter_name);
        CGPDFOperatorTableRef table = CGPDFOperatorTableCreate();
        CGPDFScannerRef scanner = stream ? CGPDFScannerCreate(stream, table, NULL) : NULL;
        if (stream) CGPDFContentStreamRelease(stream);
        if (table) CGPDFOperatorTableRelease(table);
        return scanner;
    }
#if defined(FINCH_DIFFTEST_CORETEXT)
    if (!strcmp(type, "CTFontRef")) return auto_ct_font(index);
    if (!strcmp(type, "CTFontDescriptorRef")) {
        CTFontRef font = auto_ct_font(index);
        CTFontDescriptorRef descriptor = font ? CTFontCopyFontDescriptor(font) : NULL;
        if (font) CFRelease(font); return descriptor;
    }
    if (!strcmp(type, "CTLineRef")) {
        CTFontRef font = auto_ct_font(index);
        if (!font) return NULL;
        CFStringRef string = CFSTR("Finch text 123");
        const void *keys[] = {kCTFontAttributeName}; const void *values[] = {font};
        CFDictionaryRef attributes = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFAttributedStringRef attributed = CFAttributedStringCreate(kCFAllocatorDefault, string, attributes);
        CTLineRef line = CTLineCreateWithAttributedString(attributed);
        CFRelease(attributed); CFRelease(attributes); CFRelease(font); return line;
    }
    if (!strcmp(type, "CTFramesetterRef")) {
        CFAttributedStringRef attributed = CFAttributedStringCreate(kCFAllocatorDefault, CFSTR("Finch text"), NULL);
        CTFramesetterRef result = CTFramesetterCreateWithAttributedString(attributed);
        CFRelease(attributed); return result;
    }
#endif
    return NULL;
}
#endif /* FINCH_DIFFTEST_GRAPHICS */

static void auto_print_cstring(const char *value)
{
    if (!value) { fputs("null", stdout); return; }
    for (const unsigned char *p = (const unsigned char *)value; *p; p++) printf("%02x", *p);
}

static void auto_print_bytes(const UInt8 *value, size_t length)
{
    for (size_t i = 0; i < length; i++) printf("%02x", value[i]);
}

static CFStringRef auto_cf_canonical(CFTypeRef value);

static void auto_append_hex(CFMutableStringRef out, const UInt8 *bytes, size_t length)
{
    for (size_t i = 0; i < length; i++) CFStringAppendFormat(out, NULL, CFSTR("%02x"), bytes[i]);
}

static CFComparisonResult auto_compare_cf_text(const void *left, const void *right, void *context)
{
    (void)context;
    return CFStringCompare((CFStringRef)left, (CFStringRef)right, 0);
}

static CFStringRef auto_string(size_t index, int nonempty)
{
    static const size_t choices[] = {0, 3, 8, 15, SAMPLE_COUNT - 1};
    static const size_t nonempty_choices[] = {3, 8, 15, SAMPLE_COUNT - 1};
    if (nonempty) {
        const char *text = samples[nonempty_choices[index % (sizeof(nonempty_choices) / sizeof(nonempty_choices[0]))]];
        return CFStringCreateWithBytes(kCFAllocatorDefault, (const UInt8 *)text, (CFIndex)strlen(text), kCFStringEncodingUTF8, false);
    }
    const char *text = samples[choices[index % (sizeof(choices) / sizeof(choices[0]))]];
    return CFStringCreateWithBytes(kCFAllocatorDefault, (const UInt8 *)text, (CFIndex)strlen(text), kCFStringEncodingUTF8, false);
}

static CFStringRef auto_locale_identifier(size_t index)
{
    static CFStringRef values[] = {CFSTR("en_US_POSIX"), CFSTR("fr_CA"), CFSTR("ar_EG")};
    return values[index % (sizeof(values) / sizeof(values[0]))];
}

static CFTypeID auto_type_id(size_t index)
{
    switch (index % 8) {
        case 0: return CFStringGetTypeID();
        case 1: return CFNumberGetTypeID();
        case 2: return CFArrayGetTypeID();
        case 3: return CFDictionaryGetTypeID();
        case 4: return CFSetGetTypeID();
        case 5: return CFDataGetTypeID();
        case 6: return CFDateGetTypeID();
        default: return CFURLGetTypeID();
    }
}

static CFTypeRef auto_cf_input(const char *type, size_t index, int nonempty,
    const char *function_name, const char *parameter_name)
{
    CFStringRef s = auto_string(index, nonempty);
    if (!strcmp(function_name, "CFDateFormatterCreateDateFormatFromTemplate")) {
        static CFStringRef templates[] = {CFSTR("yMd"), CFSTR("MMMMd"), CFSTR("Hm"), CFSTR("EEE")};
        CFRelease(s); s = CFStringCreateCopy(kCFAllocatorDefault,
            templates[index % (sizeof(templates) / sizeof(templates[0]))]);
    }
    static const double numberValues[] = {0.0, -0.0, INFINITY, -INFINITY, NAN, 0x1p-1074, 0.5, 1.0, -1.0};
    double value = numberValues[index % (sizeof(numberValues) / sizeof(numberValues[0]))];
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &value);
    static const UInt8 bytes[] = {0, 1, 127, 128, 254, 255};
    Boolean needData = nonempty || !strcmp(function_name, "CGDataProviderCreateWithCFData");
    CFIndex dataLength = needData ? (CFIndex)(index % sizeof(bytes) + 1) : (CFIndex)(index % (sizeof(bytes) + 1));
    CFDataRef data = CFDataCreate(kCFAllocatorDefault, bytes, dataLength);
    CFDateRef date = CFDateCreate(kCFAllocatorDefault, (CFAbsoluteTime[]){0, -1, 700000000, 800000000}[index % 4]);
#if defined(FINCH_DIFFTEST_IMAGEIO)
    if (!strcmp(type, "CFTypeRef") && !strcmp(function_name, "CGImageMetadataTagCreate") &&
        !strcmp(parameter_name, "value")) {
        CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date);
        return CFStringCreateCopy(kCFAllocatorDefault, CFSTR("2026-10-16T12:00:00Z"));
    }
#endif
    if (!strcmp(type, "CFTypeRef") && !strcmp(function_name, "CTFontManagerCompareFontFamilyNames")) {
        CFRelease(number); CFRelease(data); CFRelease(date); return s;
    }
    if (!strcmp(type, "CFTypeRef") && !strcmp(function_name, "CFNumberFormatterSetProperty") &&
        !strcmp(parameter_name, "value")) {
        CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date);
        return CFStringCreateCopy(kCFAllocatorDefault, CFSTR("."));
    }
    if (!strcmp(type, "CFTypeRef") && !strcmp(function_name, "CFDateFormatterSetProperty") &&
        !strcmp(parameter_name, "value")) {
        CFTimeZoneRef zone = CFTimeZoneCreateWithName(kCFAllocatorDefault, CFSTR("UTC"), false);
        CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date); return zone;
    }
    if (!strcmp(type, "CFStringRef") || !strcmp(type, "CFMutableStringRef")) {
#if defined(FINCH_DIFFTEST_CORETEXT)
        if (!strcmp(function_name, "CTFontDescriptorCreateCopyWithFamily") && !strcmp(parameter_name, "family")) {
            CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date);
            return CFStringCreateCopy(kCFAllocatorDefault, CFSTR("Helvetica"));
        }
        if (!strcmp(function_name, "CTGlyphInfoCreateWithGlyphName") && !strcmp(parameter_name, "glyphName")) {
            static CFStringRef glyphNames[] = {CFSTR("A"), CFSTR("a"), CFSTR("space"), CFSTR("period"), CFSTR("zero")};
            CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date);
            return (CFTypeRef)CFRetain(glyphNames[index % (sizeof(glyphNames) / sizeof(glyphNames[0]))]);
        }
#endif
#if defined(FINCH_DIFFTEST_IMAGEIO)
        if (!strcmp(function_name, "CGImageMetadataTagCreate")) {
            CFStringRef result = NULL;
            if (!strcmp(parameter_name, "xmlns")) result = CFSTR("http://ns.adobe.com/exif/1.0/");
            else if (!strcmp(parameter_name, "prefix")) result = CFSTR("exif");
            else if (!strcmp(parameter_name, "name")) result = CFSTR("DateTimeOriginal");
            if (result) {
                CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date);
                return (CFTypeRef)CFRetain(result);
            }
        }
#endif
#if defined(FINCH_DIFFTEST_GRAPHICS)
        if (!strcmp(function_name, "CGColorGetConstantColor")) {
            CFStringRef colorNames[] = {kCGColorWhite, kCGColorBlack, kCGColorClear};
            CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date);
            return (CFTypeRef)CFRetain(colorNames[index % (sizeof(colorNames) / sizeof(colorNames[0]))]);
        }
#endif
        if (!strcmp(function_name, "CGFontGetGlyphWithGlyphName") && !strcmp(parameter_name, "name")) {
            static CFStringRef glyphNames[] = {CFSTR("A"), CFSTR("a"), CFSTR("space"), CFSTR("period"), CFSTR("zero")};
            CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date);
            return (CFTypeRef)CFRetain(glyphNames[index % (sizeof(glyphNames) / sizeof(glyphNames[0]))]);
        }
        if ((!strcmp(function_name, "CTFontCreateWithName") || !strcmp(function_name, "CTFontCreateWithNameAndOptions") ||
             !strcmp(function_name, "CGFontCreateWithFontName")) &&
            (strstr(parameter_name, "name") || strstr(parameter_name, "Name"))) {
            static CFStringRef fontNames[] = {CFSTR("Helvetica"), CFSTR("Times"), CFSTR("Courier"), CFSTR("Inter-Regular")};
            CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date);
            return (CFTypeRef)CFRetain(fontNames[index % (sizeof(fontNames) / sizeof(fontNames[0]))]);
        }
        if (!strcmp(function_name, "CFLocaleGetLanguageCharacterDirection") ||
            !strcmp(function_name, "CFLocaleGetLanguageLineDirection")) {
            static const char *languages[] = {"en", "ar", "he"};
            CFStringRef result = CFStringCreateWithCString(kCFAllocatorDefault,
                languages[index % (sizeof(languages) / sizeof(languages[0]))], kCFStringEncodingUTF8);
            CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date); return result;
        }
        if (!strcmp(function_name, "CFStringGetHyphenationLocationBeforeIndex")) {
            CFStringRef result = CFStringCreateCopy(kCFAllocatorDefault, CFSTR("hyphenation"));
            CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date); return result;
        }
        if (!strcmp(function_name, "CFStringCreateByCombiningStrings")) {
            CFRelease(s); s = CFStringCreateCopy(kCFAllocatorDefault, CFSTR(", "));
        }
        if (!strcmp(type, "CFMutableStringRef")) {
            CFMutableStringRef result = CFStringCreateMutableCopy(kCFAllocatorDefault, 0, s);
            CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date); return result;
        }
        CFRelease(number); CFRelease(data); CFRelease(date); return s;
    }
    if (!strcmp(type, "CFMutableDataRef") &&
        (strstr(function_name, "ImageDestination") || !strcmp(function_name, "CGDataConsumerCreateWithCFData"))) {
        CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date);
        return CFDataCreateMutable(kCFAllocatorDefault, 0);
    }
#if defined(FINCH_DIFFTEST_IMAGEIO)
    if (!strcmp(type, "CFDataRef") && (!strcmp(function_name, "CGImageSourceCreateWithData") || strstr(function_name, "ImageSource"))) {
        CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date); return auto_png_data();
    }
#endif
    if (!strcmp(type, "CFDataRef") && !strcmp(function_name, "CFStringCreateFromExternalRepresentation")) {
        static const UInt8 utf8[] = {'a', 'b', 'c', 0xc3, 0xa9};
        CFRelease(s); CFRelease(number); CFRelease(date);
        CFIndex length = index % 2 ? 5 : 3;
        CFRelease(data); return CFDataCreate(kCFAllocatorDefault, utf8, length);
    }
    if (!strcmp(type, "CFArrayRef") && !strcmp(function_name, "CGGradientCreateWithColors")) {
#if defined(FINCH_DIFFTEST_GRAPHICS)
        CGColorRef colors[] = {CGColorCreateGenericRGB(0.1, 0.2, 0.3, 1), CGColorCreateGenericRGB(0.8, 0.5, 0.2, 1)};
        CFArrayRef result = CFArrayCreate(kCFAllocatorDefault, (const void **)colors, 2,
            &kCFTypeArrayCallBacks);
        CGColorRelease(colors[0]); CGColorRelease(colors[1]);
        CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date); return result;
#endif
    }
    if (!strcmp(type, "CFNumberRef")) { CFRelease(s); CFRelease(data); CFRelease(date); return number; }
    if (!strcmp(type, "CFDateRef")) { CFRelease(s); CFRelease(number); CFRelease(data); return date; }
    if (!strcmp(type, "CFDataRef") || !strcmp(type, "CFMutableDataRef")) {
        if (!strcmp(type, "CFMutableDataRef")) {
            CFMutableDataRef result = CFDataCreateMutableCopy(kCFAllocatorDefault, 0, data);
            CFRelease(data); CFRelease(s); CFRelease(number); CFRelease(date); return result;
        }
        CFRelease(s); CFRelease(number); CFRelease(date); return data;
    }
    if (!strcmp(type, "CFBooleanRef")) {
        CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date);
        return (CFTypeRef)CFRetain(index & 1 ? kCFBooleanTrue : kCFBooleanFalse);
    }
    if (!strcmp(type, "CFNullRef")) {
        CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date); return (CFTypeRef)CFRetain(kCFNull);
    }
    if (!strcmp(type, "CFURLRef")) {
        CFRelease(number); CFRelease(data); CFRelease(date); CFRelease(s);
        static CFStringRef urls[] = {
            CFSTR("https://example.invalid/a%20b?q=1#part"),
            CFSTR("mailto:finch@example.invalid"),
            CFSTR("relative/path")
        };
        CFStringRef text = urls[index % (sizeof(urls) / sizeof(urls[0]))];
        return CFURLCreateWithString(kCFAllocatorDefault, text, NULL);
    }
    if (!strcmp(type, "CFUUIDRef")) {
        CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date);
        return CFUUIDCreateFromString(kCFAllocatorDefault, CFSTR("68753a44-4d6f-1226-9c60-0050e4c00067"));
    }
    if (!strcmp(type, "CFCharacterSetRef") || !strcmp(type, "CFMutableCharacterSetRef")) {
        CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date);
        CFCharacterSetRef set = CFCharacterSetCreateWithCharactersInString(kCFAllocatorDefault, CFSTR("aé中🙂"));
        if (!strcmp(type, "CFMutableCharacterSetRef")) {
            CFMutableCharacterSetRef mutable = CFCharacterSetCreateMutableCopy(kCFAllocatorDefault, set);
            CFRelease(set); return mutable;
        }
        return set;
    }
    if (!strcmp(type, "CFLocaleRef")) {
        CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date);
        if (strstr(function_name, "Hyphenation"))
            return CFLocaleCreate(kCFAllocatorDefault, CFSTR("en_US"));
        static CFStringRef identifiers[] = {CFSTR("en_US_POSIX"), CFSTR("fr_CA"), CFSTR("ar_EG")};
        return CFLocaleCreate(kCFAllocatorDefault, identifiers[index % (sizeof(identifiers) / sizeof(identifiers[0]))]);
    }
    if (!strcmp(type, "CFTimeZoneRef")) {
        CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date);
        static CFStringRef names[] = {CFSTR("UTC"), CFSTR("America/Toronto"), CFSTR("Asia/Kathmandu")};
        return CFTimeZoneCreateWithName(kCFAllocatorDefault, names[index % (sizeof(names) / sizeof(names[0]))], true);
    }
    if (!strcmp(type, "CFCalendarRef")) {
        CFLocaleRef locale = CFLocaleCreate(kCFAllocatorDefault, CFSTR("en_US_POSIX"));
        CFTimeZoneRef zone = CFTimeZoneCreateWithName(kCFAllocatorDefault, CFSTR("UTC"), false);
        CFCalendarRef result = CFCalendarCreateWithIdentifier(kCFAllocatorDefault,
            index & 1 ? kCFISO8601Calendar : kCFGregorianCalendar);
        CFCalendarSetLocale(result, locale); CFCalendarSetTimeZone(result, zone);
        CFRelease(locale); CFRelease(zone);
        CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date);
        return result;
    }
    if (!strcmp(type, "CFDateFormatterRef")) {
        CFLocaleRef locale = CFLocaleCreate(kCFAllocatorDefault, CFSTR("en_US_POSIX"));
        CFDateFormatterRef result = CFDateFormatterCreate(kCFAllocatorDefault, locale, kCFDateFormatterNoStyle, kCFDateFormatterNoStyle);
        CFRelease(locale); CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date); return result;
    }
    if (!strcmp(type, "CFReadStreamRef")) {
        CFReadStreamRef result = CFReadStreamCreateWithBytesNoCopy(kCFAllocatorDefault, bytes, dataLength, kCFAllocatorNull);
        CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date); return result;
    }
    if (!strcmp(type, "CFWriteStreamRef")) {
        CFWriteStreamRef result = CFWriteStreamCreateWithAllocatedBuffers(kCFAllocatorDefault, kCFAllocatorDefault);
        CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date); return result;
    }
    if (!strcmp(type, "CFNumberFormatterRef")) {
        CFLocaleRef locale = CFLocaleCreate(kCFAllocatorDefault, CFSTR("en_US_POSIX"));
        CFNumberFormatterRef result = CFNumberFormatterCreate(kCFAllocatorDefault, locale, kCFNumberFormatterDecimalStyle);
        CFRelease(locale); CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date); return result;
    }
    if (!strcmp(type, "CFErrorRef")) {
        CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date);
        return CFErrorCreate(kCFAllocatorDefault, CFSTR("org.finch.difftest"), 1, NULL);
    }
    if (!strcmp(type, "CFAttributedStringRef") || !strcmp(type, "CFMutableAttributedStringRef")) {
        CFRelease(number); CFRelease(data); CFRelease(date);
        CFAttributedStringRef result = CFAttributedStringCreate(kCFAllocatorDefault, s, NULL);
        CFRelease(s);
        if (!strcmp(type, "CFMutableAttributedStringRef")) {
            CFMutableAttributedStringRef mutable = CFAttributedStringCreateMutableCopy(kCFAllocatorDefault, 0, result);
            CFRelease(result); return mutable;
        }
        return result;
    }
    if (!strcmp(type, "CFBagRef") || !strcmp(type, "CFMutableBagRef")) {
        const void *values[] = {s, number};
        CFIndex count = nonempty || index % 4 != 0 ? 2 : 0;
        CFBagRef result = CFBagCreate(kCFAllocatorDefault, count ? values : NULL, count, &kCFTypeBagCallBacks);
        CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date);
        if (!strcmp(type, "CFMutableBagRef")) {
            CFMutableBagRef mutable = CFBagCreateMutableCopy(kCFAllocatorDefault, 0, result);
            CFRelease(result); return mutable;
        }
        return result;
    }
    if (!strcmp(type, "CFArrayRef") || !strcmp(type, "CFMutableArrayRef") || !strcmp(type, "CFPropertyListRef") || !strcmp(type, "CFTypeRef")) {
        Boolean localizations = strstr(function_name, "Localizations") != NULL;
        Boolean combiningStrings = !strcmp(function_name, "CFStringCreateByCombiningStrings");
        CFStringRef firstString = localizations ? auto_locale_identifier(index) : s;
        CFStringRef secondString = localizations ? auto_locale_identifier(index + 1) :
            (combiningStrings ? CFSTR("Finch") : NULL);
        const void *values[] = {firstString, (localizations || combiningStrings) ? secondString : number};
        CFIndex count = (localizations || combiningStrings) ? 2 : (nonempty || index % 4 != 0 ? 2 : 0);
        CFArrayRef result = CFArrayCreate(kCFAllocatorDefault, count ? values : NULL, count, &kCFTypeArrayCallBacks);
        CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date);
        if (!strcmp(type, "CFMutableArrayRef")) {
            CFMutableArrayRef mutable = CFArrayCreateMutableCopy(kCFAllocatorDefault, 0, result);
            CFRelease(result); return mutable;
        }
        return result;
    }
    if (!strcmp(type, "CFDictionaryRef") || !strcmp(type, "CFMutableDictionaryRef")) {
        const void *keys[] = {CFSTR("text"), CFSTR("number")};
        const void *values[] = {s, number};
        CFIndex count = nonempty || index % 4 != 0 ? 2 : 0;
        if (!strcmp(function_name, "CFLocaleCreateLocaleIdentifierFromComponents")) {
            keys[0] = kCFLocaleLanguageCode; keys[1] = kCFLocaleCountryCode;
            values[0] = CFSTR("en"); values[1] = CFSTR("CA"); count = 2;
        } else if (!strcmp(function_name, "CFTimeZoneSetAbbreviationDictionary")) {
            keys[0] = CFSTR("EST"); keys[1] = CFSTR("PST");
            values[0] = CFSTR("America/Toronto"); values[1] = CFSTR("America/Los_Angeles"); count = 2;
        }
        CFDictionaryRef result = CFDictionaryCreate(kCFAllocatorDefault, count ? keys : NULL, count ? values : NULL, count,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date);
        if (!strcmp(type, "CFMutableDictionaryRef")) {
            CFMutableDictionaryRef mutable = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, result);
            CFRelease(result); return mutable;
        }
        return result;
    }
    if (!strcmp(type, "CFSetRef") || !strcmp(type, "CFMutableSetRef")) {
        const void *values[] = {s, number};
        CFIndex count = nonempty || index % 4 != 0 ? 2 : 0;
        CFSetRef result = CFSetCreate(kCFAllocatorDefault, count ? values : NULL, count, &kCFTypeSetCallBacks);
        CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date);
        if (!strcmp(type, "CFMutableSetRef")) {
            CFMutableSetRef mutable = CFSetCreateMutableCopy(kCFAllocatorDefault, 0, result);
            CFRelease(result); return mutable;
        }
        return result;
    }
    CFRelease(s); CFRelease(number); CFRelease(data); CFRelease(date); return NULL;
}

static CFStringRef auto_type_name(CFTypeID type)
{
    CFStringRef name = CFCopyTypeIDDescription(type);
    if (name && CFEqual(name, CFSTR("FigClock"))) {
        CFRelease(name);
        return CFStringCreateCopy(kCFAllocatorDefault, CFSTR("CMClock"));
    }
    if (name && CFEqual(name, CFSTR("FigTimebase"))) {
        CFRelease(name);
        return CFStringCreateCopy(kCFAllocatorDefault, CFSTR("CMTimebase"));
    }
    return name;
}

static CFStringRef auto_cf_canonical(CFTypeRef value)
{
    if (!value) return CFStringCreateCopy(kCFAllocatorDefault, CFSTR("null"));
    CFTypeID type = CFGetTypeID(value);
    if (type == CFStringGetTypeID()) {
        CFStringRef string = (CFStringRef)value;
        CFIndex cap = CFStringGetMaximumSizeForEncoding(CFStringGetLength(string), kCFStringEncodingUTF8) + 1;
        UInt8 *bytes = malloc((size_t)cap);
        CFMutableStringRef out = CFStringCreateMutable(kCFAllocatorDefault, 0);
        CFStringAppend(out, CFSTR("string:"));
        if (!bytes || !CFStringGetCString(string, (char *)bytes, cap, kCFStringEncodingUTF8)) CFStringAppend(out, CFSTR("unencodable"));
        else auto_append_hex(out, bytes, strlen((const char *)bytes));
        free(bytes); return out;
    }
    if (type == CFNumberGetTypeID()) {
        double number = 0;
        CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, &number);
        char text[96]; snprintf(text, sizeof(text), "number:%a", number);
        return CFStringCreateWithCString(kCFAllocatorDefault, text, kCFStringEncodingUTF8);
    }
    if (type == CFBooleanGetTypeID()) {
        return CFStringCreateWithFormat(kCFAllocatorDefault, NULL, CFSTR("bool:%d"), CFBooleanGetValue((CFBooleanRef)value));
    }
    if (type == CFDateGetTypeID()) {
        return CFStringCreateWithFormat(kCFAllocatorDefault, NULL, CFSTR("date:%a"), CFDateGetAbsoluteTime((CFDateRef)value));
    }
    if (type == CFDataGetTypeID()) {
        CFDataRef data = (CFDataRef)value;
        CFMutableStringRef out = CFStringCreateMutable(kCFAllocatorDefault, 0);
        CFStringAppendFormat(out, NULL, CFSTR("data:%ld:"), (long)CFDataGetLength(data));
        auto_append_hex(out, CFDataGetBytePtr(data), (size_t)CFDataGetLength(data)); return out;
    }
    if (type == CFURLGetTypeID()) {
        CFMutableStringRef out = CFStringCreateMutable(kCFAllocatorDefault, 0);
        CFStringAppend(out, CFSTR("url:"));
        CFStringRef string = CFURLGetString((CFURLRef)value);
        CFStringRef inner = auto_cf_canonical(string); CFStringAppend(out, inner); CFRelease(inner); return out;
    }
    if (type == CFErrorGetTypeID()) {
        CFErrorRef error = (CFErrorRef)value;
        CFStringRef domain = auto_cf_canonical(CFErrorGetDomain(error));
        CFMutableStringRef out = CFStringCreateMutable(kCFAllocatorDefault, 0);
        CFStringAppendFormat(out, NULL, CFSTR("error:%@:%ld"), domain, (long)CFErrorGetCode(error));
        CFRelease(domain); return out;
    }
    if (type == CFUUIDGetTypeID()) {
        CFStringRef string = CFUUIDCreateString(kCFAllocatorDefault, (CFUUIDRef)value);
        CFStringRef result = auto_cf_canonical(string); CFRelease(string); return result;
    }
    if (type == CFArrayGetTypeID()) {
        CFArrayRef array = (CFArrayRef)value;
        CFMutableStringRef out = CFStringCreateMutable(kCFAllocatorDefault, 0); CFStringAppend(out, CFSTR("array:["));
        for (CFIndex i = 0; i < CFArrayGetCount(array); i++) {
            if (i) CFStringAppend(out, CFSTR(","));
            CFStringRef part = auto_cf_canonical(CFArrayGetValueAtIndex(array, i)); CFStringAppend(out, part); CFRelease(part);
        }
        CFStringAppend(out, CFSTR("]")); return out;
    }
    if (type == CFSetGetTypeID() || type == CFBagGetTypeID()) {
        CFIndex count = type == CFSetGetTypeID() ? CFSetGetCount((CFSetRef)value) : CFBagGetCount((CFBagRef)value);
        const void **values = calloc((size_t)(count ? count : 1), sizeof(void *));
        if (type == CFSetGetTypeID()) CFSetGetValues((CFSetRef)value, values); else CFBagGetValues((CFBagRef)value, values);
        CFMutableArrayRef parts = CFArrayCreateMutable(kCFAllocatorDefault, count, &kCFTypeArrayCallBacks);
        for (CFIndex i = 0; i < count; i++) { CFStringRef part = auto_cf_canonical(values[i]); CFArrayAppendValue(parts, part); CFRelease(part); }
        CFArraySortValues(parts, CFRangeMake(0, count), auto_compare_cf_text, NULL);
        CFMutableStringRef out = CFStringCreateMutable(kCFAllocatorDefault, 0); CFStringAppend(out, CFSTR("set:{"));
        for (CFIndex i = 0; i < count; i++) { if (i) CFStringAppend(out, CFSTR(",")); CFStringAppend(out, CFArrayGetValueAtIndex(parts, i)); }
        CFStringAppend(out, CFSTR("}")); CFRelease(parts); free(values); return out;
    }
    if (type == CFDictionaryGetTypeID()) {
        CFDictionaryRef dictionary = (CFDictionaryRef)value; CFIndex count = CFDictionaryGetCount(dictionary);
        const void **keys = calloc((size_t)(count ? count : 1), sizeof(void *));
        const void **values = calloc((size_t)(count ? count : 1), sizeof(void *));
        CFDictionaryGetKeysAndValues(dictionary, keys, values);
        CFMutableArrayRef pairs = CFArrayCreateMutable(kCFAllocatorDefault, count, &kCFTypeArrayCallBacks);
        for (CFIndex i = 0; i < count; i++) {
            CFStringRef key = auto_cf_canonical(keys[i]);
            CFStringRef val;
            if (CFGetTypeID(keys[i]) == CFStringGetTypeID() &&
                CFEqual(keys[i], CFSTR("FillExtendedPixelsCallback")) &&
                CFGetTypeID(values[i]) == CFDataGetTypeID())
                val = CFStringCreateCopy(kCFAllocatorDefault, CFSTR("function-pointer"));
            else
                val = auto_cf_canonical(values[i]);
            CFStringRef pair = CFStringCreateWithFormat(kCFAllocatorDefault, NULL, CFSTR("%@=%@"), key, val);
            CFArrayAppendValue(pairs, pair); CFRelease(key); CFRelease(val); CFRelease(pair);
        }
        CFArraySortValues(pairs, CFRangeMake(0, count), auto_compare_cf_text, NULL);
        CFMutableStringRef out = CFStringCreateMutable(kCFAllocatorDefault, 0); CFStringAppend(out, CFSTR("dictionary:{"));
        for (CFIndex i = 0; i < count; i++) { if (i) CFStringAppend(out, CFSTR(",")); CFStringAppend(out, CFArrayGetValueAtIndex(pairs, i)); }
        CFStringAppend(out, CFSTR("}")); CFRelease(pairs); free(keys); free(values); return out;
    }
    if (type == CFLocaleGetTypeID()) {
        CFStringRef identifier = CFLocaleGetIdentifier((CFLocaleRef)value);
        return CFStringCreateWithFormat(kCFAllocatorDefault, NULL, CFSTR("locale:%@"), identifier);
    }
    if (type == CFTimeZoneGetTypeID()) {
        CFStringRef name = CFTimeZoneGetName((CFTimeZoneRef)value);
        return CFStringCreateWithFormat(kCFAllocatorDefault, NULL, CFSTR("timezone:%@:%ld"), name,
            (long)CFTimeZoneGetSecondsFromGMT((CFTimeZoneRef)value, 700000000));
    }
    if (type == CFCalendarGetTypeID()) {
        CFStringRef identifier = CFCalendarGetIdentifier((CFCalendarRef)value);
        return CFStringCreateWithFormat(kCFAllocatorDefault, NULL, CFSTR("calendar:%@"), identifier);
    }
    if (type == CFAttributedStringGetTypeID()) {
        CFStringRef string = CFAttributedStringGetString((CFAttributedStringRef)value);
        CFStringRef inner = auto_cf_canonical(string);
        CFStringRef result = CFStringCreateWithFormat(kCFAllocatorDefault, NULL, CFSTR("attributed:%@"), inner);
        CFRelease(inner); return result;
    }
    CFStringRef typeName = auto_type_name(type);
    if (!typeName) return CFStringCreateCopy(kCFAllocatorDefault, CFSTR("object:opaque"));
    CFMutableStringRef out = CFStringCreateMutable(kCFAllocatorDefault, 0);
    CFStringAppend(out, CFSTR("object:type:")); CFStringAppend(out, typeName); CFRelease(typeName);
    return out;
}

static void auto_print_cf(CFTypeRef value)
{
    CFStringRef text = auto_cf_canonical(value);
    CFIndex cap = CFStringGetMaximumSizeForEncoding(CFStringGetLength(text), kCFStringEncodingUTF8) + 1;
    UInt8 *bytes = malloc((size_t)cap);
    if (!bytes || !CFStringGetCString(text, (char *)bytes, cap, kCFStringEncodingUTF8)) fputs("<unencodable>", stdout);
    else auto_print_cstring((const char *)bytes);
    free(bytes); CFRelease(text);
}

static void auto_print_typeid(CFTypeID type)
{
    if (type == CFMessagePortGetTypeID()) { fputs("typeid:CFMessagePort", stdout); return; }
    CFStringRef description = auto_type_name(type);
    if (!description) { fputs("typeid:unknown", stdout); return; }
    CFIndex capacity = CFStringGetMaximumSizeForEncoding(CFStringGetLength(description), kCFStringEncodingUTF8) + 1;
    char *bytes = malloc((size_t)capacity);
    if (!bytes || !CFStringGetCString(description, bytes, capacity, kCFStringEncodingUTF8))
        fputs("typeid:unavailable", stdout);
    else {
        fputs("typeid:", stdout);
        auto_print_cstring(bytes);
    }
    free(bytes);
    CFRelease(description);
}

#ifdef FINCH_DIFFTEST_CFNETWORK
static CFHTTPMessageRef auto_cfnetwork_message(const char *function_name, const char *parameter_name, size_t index)
{
    Boolean response = strstr(parameter_name, "response") != NULL ||
        strstr(function_name, "GetResponse") != NULL || strstr(function_name, "CopyResponse") != NULL;
    if (response)
        return CFHTTPMessageCreateResponse(kCFAllocatorDefault, 200, CFSTR("OK"), kCFHTTPVersion1_1);
    CFURLRef url = CFURLCreateWithString(kCFAllocatorDefault, CFSTR("https://example.invalid/fixed/path"), NULL);
    CFHTTPMessageRef message = CFHTTPMessageCreateRequest(kCFAllocatorDefault, CFSTR("GET"), url, kCFHTTPVersion1_1);
    CFRelease(url);
    if (message) {
        CFHTTPMessageSetHeaderFieldValue(message, CFSTR("X-Finch-Test"), index & 1 ? CFSTR("two") : CFSTR("one"));
        static const UInt8 body[] = {'f', 'i', 'n', 'c', 'h'};
        CFDataRef data = CFDataCreate(kCFAllocatorDefault, body, sizeof(body));
        CFHTTPMessageSetBody(message, data);
        CFRelease(data);
    }
    return message;
}

static void auto_cfnetwork_print_message(CFHTTPMessageRef message)
{
    if (!message) { fputs("null", stdout); return; }
    Boolean request = CFHTTPMessageIsRequest(message);
    CFStringRef first = request ? CFHTTPMessageCopyRequestMethod(message) : CFHTTPMessageCopyResponseStatusLine(message);
    CFStringRef version = CFHTTPMessageCopyVersion(message);
    CFDictionaryRef headers = CFHTTPMessageCopyAllHeaderFields(message);
    CFDataRef body = CFHTTPMessageCopyBody(message);
    CFURLRef url = request ? CFHTTPMessageCopyRequestURL(message) : NULL;
    printf("http-message:%d:", request);
    auto_print_cf(first); putchar(':'); auto_print_cf(version); putchar(':');
    auto_print_cf(headers); putchar(':'); auto_print_cf(body); putchar(':'); auto_print_cf(url);
    if (first) CFRelease(first); if (version) CFRelease(version); if (headers) CFRelease(headers);
    if (body) CFRelease(body); if (url) CFRelease(url);
}
#endif
'''


def _objc_runtime() -> str:
    return r'''
#import <objc/runtime.h>

@interface FinchDifftestKVCObject : NSObject {
@public
    NSString *_name;
    NSNumber *_age;
    NSArray *_items;
    NSMutableSet *_tags;
    NSMutableOrderedSet *_orderedItems;
}
@end

@implementation FinchDifftestKVCObject
- (instancetype)init
{
    if ((self = [super init])) {
        _name = [@"Finch" copy];
        _age = [@36 retain];
        _items = [[NSArray alloc] initWithObjects:@"one", @"two", nil];
        _tags = [[NSMutableSet alloc] initWithObjects:@"one", @"two", nil];
        _orderedItems = [[NSMutableOrderedSet alloc] initWithObjects:@"one", @"two", nil];
    }
    return self;
}
- (void)dealloc
{
    [_name release]; [_age release]; [_items release]; [_tags release]; [_orderedItems release]; [super dealloc];
}
- (NSString *)name { return _name; }
- (void)setName:(NSString *)name
{
    if (_name != name) { [name retain]; [_name release]; _name = name; }
}
- (NSNumber *)age { return _age; }
- (void)setAge:(NSNumber *)age
{
    if (_age != age) { [age retain]; [_age release]; _age = age; }
}
- (NSArray *)items { return _items; }
- (void)setItems:(NSArray *)items
{
    if (_items != items) { [items retain]; [_items release]; _items = items; }
}
- (NSMutableSet *)tags { return _tags; }
- (void)setTags:(NSMutableSet *)tags
{
    if (_tags != tags) { [tags retain]; [_tags release]; _tags = tags; }
}
- (NSMutableOrderedSet *)orderedItems { return _orderedItems; }
- (void)setOrderedItems:(NSMutableOrderedSet *)items
{
    if (_orderedItems != items) { [items retain]; [_orderedItems release]; _orderedItems = items; }
}
@end

static NSString *auto_clean_type(NSString *type)
{
    NSString *clean = [type stringByReplacingOccurrencesOfString:@"const" withString:@""];
    for (NSString *word in @[@"_Nullable", @"_Nonnull", @"_Null_unspecified", @"__nullable", @"__nonnull", @"nullable", @"nonnull", @"__kindof"])
        clean = [clean stringByReplacingOccurrencesOfString:word withString:@""];
    return [clean stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *auto_hex(NSString *value)
{
    value = [value stringByReplacingOccurrencesOfString:@"0x[0-9a-fA-F]+" withString:@"<ADDRESS>"
        options:NSRegularExpressionSearch range:NSMakeRange(0, value.length)];
    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO];
    const unsigned char *bytes = data.bytes;
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < data.length; i++) [out appendFormat:@"%02x", bytes[i]];
    return out;
}

static NSString *auto_canonical(id value);

#ifdef FINCH_DIFFTEST_APPKIT
static NSInteger auto_appkit_component(double value)
{
    if (!isfinite(value)) return (NSInteger)0x7fffffff;
    return (NSInteger)llround(value * 100000.0);
}

static NSInteger auto_appkit_geometry(double value)
{
    if (!isfinite(value)) return (NSInteger)0x7fffffff;
    return (NSInteger)llround(value * 100.0);
}

static NSString *auto_appkit_color_description(NSColor *color)
{
    __block NSString *description = nil;
    void (^readColor)(void) = ^{
        NSColor *component = [color colorUsingType:NSColorTypeComponentBased];
        NSColor *rgb = [component colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
        NSString *catalog = @"";
        if (color.type == NSColorTypeCatalog)
            catalog = [NSString stringWithFormat:@"%@/%@:", color.catalogNameComponent ?: @"", color.colorNameComponent ?: @""];
        if (rgb) description = [NSString stringWithFormat:@"color:%@%ld,%ld,%ld,%ld", auto_hex(catalog),
            (long)auto_appkit_component(rgb.redComponent), (long)auto_appkit_component(rgb.greenComponent),
            (long)auto_appkit_component(rgb.blueComponent), (long)auto_appkit_component(rgb.alphaComponent)];
        else description = [NSString stringWithFormat:@"color:%ld:%ld", (long)color.type,
            (long)auto_appkit_component(color.alphaComponent)];
    };
    NSAppearance *appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    if (appearance) [appearance performAsCurrentDrawingAppearance:readColor];
    else readColor();
    return description ?: @"color:unavailable";
}

static NSString *auto_appkit_private_name(NSString *name)
{
    if ([name hasPrefix:@"org.finch.difftest."]) return @"<private-pasteboard>";
    return name ?: @"";
}
#endif

static NSString *auto_canonical(id value)
{
    if (!value || value == NSNull.null) return @"null";
#ifdef FINCH_DIFFTEST_COREIMAGE
    if ([value isKindOfClass:CIFilter.class]) {
        CIFilter *filter = value;
        return [NSString stringWithFormat:@"ci-filter:%@:%@:%@", auto_hex(filter.name ?: @""),
            auto_canonical(filter.inputKeys ?: @[]), auto_canonical(filter.outputKeys ?: @[])];
    }
    if ([value isKindOfClass:CIKernel.class]) {
        CIKernel *kernel = value;
        return [NSString stringWithFormat:@"ci-kernel:%@:%@", NSStringFromClass([value class]), auto_hex(kernel.name ?: @"")];
    }
    if ([value isKindOfClass:CIQRCodeDescriptor.class]) {
        CIQRCodeDescriptor *descriptor = value;
        return [NSString stringWithFormat:@"ci-qr:%@:%ld:%u:%ld", auto_canonical(descriptor.errorCorrectedPayload),
            (long)descriptor.symbolVersion, (unsigned int)descriptor.maskPattern, (long)descriptor.errorCorrectionLevel];
    }
    if ([value isKindOfClass:CIAztecCodeDescriptor.class]) {
        CIAztecCodeDescriptor *descriptor = value;
        return [NSString stringWithFormat:@"ci-aztec:%@:%d:%ld:%ld", auto_canonical(descriptor.errorCorrectedPayload),
            descriptor.isCompact, (long)descriptor.layerCount, (long)descriptor.dataCodewordCount];
    }
    if ([value isKindOfClass:CIPDF417CodeDescriptor.class]) {
        CIPDF417CodeDescriptor *descriptor = value;
        return [NSString stringWithFormat:@"ci-pdf417:%@:%d:%ld:%ld", auto_canonical(descriptor.errorCorrectedPayload),
            descriptor.isCompact, (long)descriptor.rowCount, (long)descriptor.columnCount];
    }
    if ([value isKindOfClass:CIDataMatrixCodeDescriptor.class]) {
        CIDataMatrixCodeDescriptor *descriptor = value;
        return [NSString stringWithFormat:@"ci-datamatrix:%@:%ld:%ld:%ld", auto_canonical(descriptor.errorCorrectedPayload),
            (long)descriptor.rowCount, (long)descriptor.columnCount, (long)descriptor.eccVersion];
    }
#endif
#ifdef FINCH_DIFFTEST_COREDATA
    if ([value isKindOfClass:NSPersistentStoreDescription.class]) {
        NSPersistentStoreDescription *description = value;
        return [NSString stringWithFormat:@"coredata-store-description:%@:%@:%@:%@:%d:%a:%d:%d:%d:%@:%@",
            auto_hex(description.type ?: @""), auto_hex(description.configuration ?: @""),
            auto_canonical(description.URL), auto_canonical(description.options), description.isReadOnly,
            description.timeout, description.shouldAddStoreAsynchronously,
            description.shouldMigrateStoreAutomatically, description.shouldInferMappingModelAutomatically,
            auto_canonical(description.sqlitePragmas), auto_canonical(description.cloudKitContainerOptions)];
    }
    if ([value isKindOfClass:NSFetchIndexElementDescription.class]) {
        NSFetchIndexElementDescription *element = value;
        return [NSString stringWithFormat:@"coredata-index-element:%@:%lu:%d",
            auto_hex(element.propertyName ?: @""), (unsigned long)element.collationType, element.isAscending];
    }
    if ([value isKindOfClass:NSFetchIndexDescription.class]) {
        NSFetchIndexDescription *index = value;
        return [NSString stringWithFormat:@"coredata-index:%@:%@:%@",
            auto_hex(index.name ?: @""), auto_canonical(index.elements ?: @[]),
            auto_canonical(index.partialIndexPredicate)];
    }
    if ([value isKindOfClass:NSBatchUpdateRequest.class]) {
        NSBatchUpdateRequest *request = value;
        return [NSString stringWithFormat:@"coredata-batch-update:%@:%@:%d:%lu:%@",
            auto_hex(request.entityName ?: @""), auto_canonical(request.predicate), request.includesSubentities,
            (unsigned long)request.resultType, auto_canonical(request.propertiesToUpdate ?: @{})];
    }
    if ([value isKindOfClass:NSBatchDeleteRequest.class]) {
        NSBatchDeleteRequest *request = value;
        return [NSString stringWithFormat:@"coredata-batch-delete:%@:%lu",
            auto_canonical(request.fetchRequest), (unsigned long)request.resultType];
    }
    if ([value isKindOfClass:NSMergePolicy.class])
        return [NSString stringWithFormat:@"coredata-merge-policy:%lu", (unsigned long)[(NSMergePolicy *)value mergeType]];
#endif
#ifdef FINCH_DIFFTEST_CORESPOTLIGHT
    if ([value isKindOfClass:CSSearchableItemAttributeSet.class]) {
        CSSearchableItemAttributeSet *attributes = value;
        return [NSString stringWithFormat:@"spotlight-attributes:%@:%@:%@:%@:%@:%@:%@",
            auto_hex(attributes.contentType ?: @""), auto_hex(attributes.title ?: @""),
            auto_hex(attributes.displayName ?: @""), auto_hex(attributes.contentDescription ?: @""),
            auto_canonical(attributes.contentURL), auto_canonical(attributes.keywords ?: @[]),
            auto_canonical(attributes.authors ?: @[])];
    }
    if ([value isKindOfClass:CSSearchableItem.class]) {
        CSSearchableItem *item = value;
        return [NSString stringWithFormat:@"spotlight-item:%@:%@:%@:%a:%d:%lu",
            auto_hex(item.uniqueIdentifier ?: @""), auto_hex(item.domainIdentifier ?: @""),
            auto_canonical(item.attributeSet), item.expirationDate.timeIntervalSinceReferenceDate,
            item.isUpdate, (unsigned long)item.updateListenerOptions];
    }
    if ([value isKindOfClass:CSPerson.class]) {
        CSPerson *person = value;
        return [NSString stringWithFormat:@"spotlight-person:%@:%@:%@:%@",
            auto_hex(person.displayName ?: @""), auto_canonical(person.handles),
            auto_hex(person.handleIdentifier ?: @""), auto_hex(person.contactIdentifier ?: @"")];
    }
    if ([value isKindOfClass:CSCustomAttributeKey.class]) {
        CSCustomAttributeKey *key = value;
        return [NSString stringWithFormat:@"spotlight-key:%@:%d:%d:%d:%d", auto_hex(key.keyName ?: @""),
            key.searchable, key.searchableByDefault, key.unique, key.multiValued];
    }
#endif
#ifdef FINCH_DIFFTEST_AVFAUDIO
    if ([value isKindOfClass:AVAudioFormat.class]) {
        AVAudioFormat *format = value;
        return [NSString stringWithFormat:@"audio-format:%ld:%lu:%a:%d:%d:%@", (long)format.commonFormat,
            (unsigned long)format.channelCount, format.sampleRate, format.isInterleaved, format.isStandard,
            auto_canonical(format.channelLayout)];
    }
    if ([value isKindOfClass:AVAudioChannelLayout.class]) {
        AVAudioChannelLayout *layout = value;
        return [NSString stringWithFormat:@"audio-layout:%u:%u", (unsigned int)layout.layoutTag,
            (unsigned int)layout.channelCount];
    }
    if ([value isKindOfClass:AVAudioTime.class]) {
        AVAudioTime *time = value;
        return [NSString stringWithFormat:@"audio-time:%d:%lld:%a:%d", time.isSampleTimeValid,
            (long long)time.sampleTime, time.sampleRate, time.isHostTimeValid];
    }
    if ([value isKindOfClass:AVAudioPCMBuffer.class]) {
        AVAudioPCMBuffer *buffer = value;
        return [NSString stringWithFormat:@"audio-buffer:%@:%u:%u:%lu", auto_canonical(buffer.format),
            (unsigned int)buffer.frameCapacity, (unsigned int)buffer.frameLength, (unsigned long)buffer.stride];
    }
    if ([value isKindOfClass:AVAudioCompressedBuffer.class]) {
        AVAudioCompressedBuffer *buffer = value;
        return [NSString stringWithFormat:@"audio-compressed-buffer:%@:%u:%u:%ld:%u:%u",
            auto_canonical(buffer.format), (unsigned int)buffer.packetCapacity,
            (unsigned int)buffer.packetCount, (long)buffer.maximumPacketSize,
            (unsigned int)buffer.byteCapacity, (unsigned int)buffer.byteLength];
    }
    if ([value isKindOfClass:AVAudioConverter.class]) {
        AVAudioConverter *converter = value;
        return [NSString stringWithFormat:@"audio-converter:%@:%@:%ld:%@:%d:%d:%ld:%ld",
            auto_canonical(converter.inputFormat), auto_canonical(converter.outputFormat),
            (long)converter.sampleRateConverterQuality, auto_canonical(converter.sampleRateConverterAlgorithm),
            converter.downmix, converter.dither, (long)converter.primeMethod,
            (long)converter.maximumOutputPacketSize];
    }
#endif
#ifdef FINCH_DIFFTEST_AVFOUNDATION
    if ([value isKindOfClass:AVMetadataItem.class]) {
        AVMetadataItem *item = value;
        return [NSString stringWithFormat:@"av-metadata:%@:%@:%@:%@:%@", auto_hex(item.identifier ?: @""),
            auto_hex(item.keySpace ?: @""), auto_hex(item.dataType ?: @""), auto_canonical(item.key),
            auto_canonical(item.value)];
    }
    if ([value isKindOfClass:AVAssetTrack.class]) {
        AVAssetTrack *track = value;
        CMTimeRange range = track.timeRange;
        CGAffineTransform transform = track.preferredTransform;
        return [NSString stringWithFormat:@"av-track:%@:%lld:%d:%lld:%d:%a:%a:%a:%a:%a:%a:%a:%a",
            auto_hex(track.mediaType ?: @""), range.start.value, range.start.timescale,
            range.duration.value, range.duration.timescale, track.naturalSize.width, track.naturalSize.height,
            transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty];
    }
    if ([value isKindOfClass:AVAsset.class]) {
        AVAsset *asset = value;
        CMTime duration = asset.duration;
        NSMutableArray *metadata = [NSMutableArray array];
        for (AVMetadataItem *item in asset.commonMetadata) [metadata addObject:auto_canonical(item) ?: @"null"];
        NSArray *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
        NSArray *audioTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
        return [NSString stringWithFormat:@"av-asset:%lld:%d:%d:%d:%d:%lu:%lu:%@", duration.value,
            duration.timescale, asset.isPlayable, asset.isExportable, asset.isReadable,
            (unsigned long)videoTracks.count, (unsigned long)audioTracks.count, auto_canonical(metadata)];
    }
#endif
#ifdef FINCH_DIFFTEST_PDFKIT
    if ([value isKindOfClass:PDFDocument.class]) {
        PDFDocument *document = value;
        return [NSString stringWithFormat:@"pdf-document:%lu:%@:%@", (unsigned long)document.pageCount,
            auto_hex(document.string ?: @""), auto_hex([document documentAttributes][PDFDocumentTitleAttribute] ?: @"")];
    }
    if ([value isKindOfClass:PDFPage.class]) {
        PDFPage *page = value;
        CGRect bounds = [page boundsForBox:kPDFDisplayBoxMediaBox];
        return [NSString stringWithFormat:@"pdf-page:%ld:%@:%a:%a:%a:%a:%lu", (long)page.rotation,
            auto_hex(page.string ?: @""), bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height,
            (unsigned long)page.annotations.count];
    }
    if ([value isKindOfClass:PDFSelection.class])
        return [NSString stringWithFormat:@"pdf-selection:%@:%lu", auto_hex([(PDFSelection *)value string] ?: @""),
            (unsigned long)[(PDFSelection *)value pages].count];
    if ([value isKindOfClass:PDFView.class]) {
        PDFView *view = value;
        return [NSString stringWithFormat:@"pdf-view:%@:%ld:%ld:%d:%d", auto_canonical(view.document),
            (long)view.displayMode, (long)view.displayBox, view.displaysPageBreaks, view.autoScales];
    }
#endif
#ifdef FINCH_DIFFTEST_STOREKIT
    if ([value isKindOfClass:SKPayment.class]) {
        SKPayment *payment = value;
        return [NSString stringWithFormat:@"storekit-payment:%@:%ld:%@:%@:%d:%@",
            auto_hex(payment.productIdentifier ?: @""), (long)payment.quantity,
            auto_hex(payment.applicationUsername ?: @""), auto_canonical(payment.requestData),
            payment.simulatesAskToBuyInSandbox, auto_canonical(payment.paymentDiscount)];
    }
    if ([value isKindOfClass:SKPaymentDiscount.class]) {
        SKPaymentDiscount *discount = value;
        return [NSString stringWithFormat:@"storekit-discount:%@:%@:%@:%@:%@", auto_hex(discount.identifier ?: @""),
            auto_hex(discount.keyIdentifier ?: @""), auto_canonical(discount.nonce),
            auto_hex(discount.signature ?: @""), auto_canonical(discount.timestamp)];
    }
#endif
#ifdef FINCH_DIFFTEST_LINKPRESENTATION
    if ([value isKindOfClass:LPLinkMetadata.class]) {
        LPLinkMetadata *metadata = value;
        return [NSString stringWithFormat:@"link-metadata:%@:%@:%@", auto_hex(metadata.title ?: @""),
            auto_canonical(metadata.originalURL), auto_canonical(metadata.URL)];
    }
#endif
    if ([value isKindOfClass:NSDateComponentsFormatter.class]) {
        NSDateComponentsFormatter *formatter = value;
        return [NSString stringWithFormat:@"date-components-formatter:%lu:%d:%d:%d:%d:%lu:%lu:%ld:%ld:%@",
            (unsigned long)formatter.allowedUnits, formatter.allowsFractionalUnits, formatter.collapsesLargestUnit,
            formatter.includesApproximationPhrase, formatter.includesTimeRemainingPhrase,
            (unsigned long)formatter.maximumUnitCount, (unsigned long)formatter.zeroFormattingBehavior,
            (long)formatter.unitsStyle, (long)formatter.formattingContext,
            auto_hex(formatter.calendar.locale.localeIdentifier ?: @"")];
    }
    if ([value isKindOfClass:NSPersonNameComponentsFormatter.class]) {
        NSPersonNameComponentsFormatter *formatter = value;
        return [NSString stringWithFormat:@"person-name-formatter:%ld:%d:%@", (long)formatter.style,
            formatter.isPhonetic, auto_hex(formatter.locale.localeIdentifier ?: @"")];
    }
    if ([value isKindOfClass:NSByteCountFormatter.class]) {
        NSByteCountFormatter *formatter = value;
        return [NSString stringWithFormat:@"byte-count-formatter:%lu:%ld:%d:%d:%d:%d:%d:%ld",
            (unsigned long)formatter.allowedUnits, (long)formatter.countStyle, formatter.allowsNonnumericFormatting,
            formatter.includesUnit, formatter.includesCount, formatter.includesActualByteCount,
            formatter.isAdaptive, (long)formatter.formattingContext];
    }
    if ([value isKindOfClass:NSEnergyFormatter.class]) {
        NSEnergyFormatter *formatter = value;
        return [NSString stringWithFormat:@"energy-formatter:%ld:%d:%ld:%@", (long)formatter.unitStyle,
            formatter.isForFoodEnergyUse, (long)formatter.numberFormatter.numberStyle,
            auto_hex(formatter.numberFormatter.locale.localeIdentifier ?: @"")];
    }
    if ([value isKindOfClass:NSMeasurementFormatter.class]) {
        NSMeasurementFormatter *formatter = value;
        return [NSString stringWithFormat:@"measurement-formatter:%ld:%lu:%ld:%@:%@", (long)formatter.unitStyle,
            (unsigned long)formatter.unitOptions, (long)formatter.numberFormatter.numberStyle,
            auto_hex(formatter.locale.localeIdentifier ?: @""),
            auto_hex(formatter.numberFormatter.locale.localeIdentifier ?: @"")];
    }
    if ([value isKindOfClass:NSMeasurement.class]) {
        NSMeasurement *measurement = value;
        return [NSString stringWithFormat:@"measurement:%a:%@", measurement.doubleValue, auto_canonical(measurement.unit)];
    }
    if ([value isKindOfClass:NSUnit.class]) {
        NSUnit *unit = value;
        return [NSString stringWithFormat:@"unit:%@", auto_hex(unit.symbol ?: @"")];
    }
    if ([value isKindOfClass:NSPersonNameComponents.class]) {
        NSPersonNameComponents *components = value;
        return [NSString stringWithFormat:@"person-name:%@:%@:%@:%@:%@:%@:%@", auto_hex(components.namePrefix ?: @""),
            auto_hex(components.givenName ?: @""), auto_hex(components.middleName ?: @""),
            auto_hex(components.familyName ?: @""), auto_hex(components.nameSuffix ?: @""),
            auto_hex(components.nickname ?: @""), auto_canonical(components.phoneticRepresentation)];
    }
    if ([value isKindOfClass:NSScanner.class]) {
        NSScanner *scanner = value;
        return [NSString stringWithFormat:@"scanner:%@:%lu:%d:%d:%@", auto_hex(scanner.string ?: @""),
            (unsigned long)scanner.scanLocation, scanner.caseSensitive, scanner.isAtEnd,
            auto_canonical(scanner.charactersToBeSkipped)];
    }
    if ([value isKindOfClass:NSFileWrapper.class]) {
        NSFileWrapper *wrapper = value;
        BOOL isDirectory = wrapper.isDirectory;
        BOOL isRegularFile = wrapper.isRegularFile;
        BOOL isSymbolicLink = wrapper.isSymbolicLink;
        NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
        for (NSString *key in @[NSFileType, NSFilePosixPermissions, NSFileSize])
            if (wrapper.fileAttributes[key]) attributes[key] = wrapper.fileAttributes[key];
        NSData *contents = isRegularFile ? wrapper.regularFileContents : nil;
        NSDictionary *children = isDirectory ? wrapper.fileWrappers : nil;
        NSURL *destination = isSymbolicLink ? wrapper.symbolicLinkDestinationURL : nil;
        return [NSString stringWithFormat:@"file-wrapper:%d:%d:%d:%@:%@:%@:%@:%@:%@", isDirectory,
            isRegularFile, isSymbolicLink, auto_hex(wrapper.filename ?: @""),
            auto_hex(wrapper.preferredFilename ?: @""), auto_canonical(attributes),
            auto_canonical(contents), auto_canonical(children ?: @{}), auto_canonical(destination)];
    }
    if ([value isKindOfClass:NSProgress.class]) {
        NSProgress *progress = value;
        return [NSString stringWithFormat:@"progress:%lld:%lld:%a:%d:%d:%d:%d:%d:%d:%d:%@:%@:%@:%@", progress.totalUnitCount,
            progress.completedUnitCount, progress.fractionCompleted, progress.isCancellable, progress.isPausable,
            progress.isCancelled, progress.isFinished, progress.isIndeterminate, progress.isPaused, progress.isOld,
            auto_hex(progress.kind ?: @""), auto_hex(progress.localizedDescription ?: @""),
            auto_hex(progress.localizedAdditionalDescription ?: @""),
            auto_canonical(progress.userInfo ?: @{})];
    }
#ifdef FINCH_DIFFTEST_APPKIT
    if ([value isKindOfClass:NSColor.class]) {
        return auto_appkit_color_description(value);
    }
    if ([value isKindOfClass:NSCell.class]) {
        NSCell *cell = value;
        return [NSString stringWithFormat:@"cell:%@:%@:%@:%ld:%d:%d:%ld:%ld:%@:%@",
            auto_hex(cell.title ?: @""), auto_canonical(cell.objectValue), auto_hex(cell.stringValue ?: @""),
            (long)cell.state, cell.isEnabled, cell.isEditable, (long)cell.alignment, (long)cell.controlSize,
            auto_canonical(cell.font), auto_canonical(cell.image)];
    }
    if ([value isKindOfClass:NSMenuItem.class]) {
        NSMenuItem *item = value;
        return [NSString stringWithFormat:@"menu-item:%@:%@:%ld:%d:%d:%ld:%d:%@",
            auto_hex(item.title ?: @""), auto_hex(item.keyEquivalent ?: @""), (long)item.state,
            item.isEnabled, item.isHidden, (long)item.indentationLevel, item.isSeparatorItem,
            auto_canonical(item.submenu)];
    }
    if ([value isKindOfClass:NSMenu.class]) {
        NSMenu *menu = value;
        return [NSString stringWithFormat:@"menu:%@:%@", auto_hex(menu.title ?: @""), auto_canonical(menu.itemArray ?: @[])];
    }
    if ([value isKindOfClass:NSTableColumn.class]) {
        NSTableColumn *column = value;
        return [NSString stringWithFormat:@"table-column:%@:%ld:%ld:%ld:%d", auto_canonical(column.identifier),
            (long)auto_appkit_geometry(column.width), (long)auto_appkit_geometry(column.minWidth),
            (long)auto_appkit_geometry(column.maxWidth), column.isHidden];
    }
    if ([value isKindOfClass:NSColorSpace.class]) {
        NSColorSpace *space = value;
        return [NSString stringWithFormat:@"color-space:%ld:%ld:%@", (long)space.colorSpaceModel,
            (long)space.numberOfColorComponents, auto_hex(space.localizedName ?: @"")];
    }
    if ([value isKindOfClass:NSColorList.class]) {
        NSColorList *list = value;
        return [NSString stringWithFormat:@"color-list:%@:%@", auto_hex(list.name ?: @""), auto_canonical(list.allKeys ?: @[])];
    }
    if ([value isKindOfClass:NSFont.class]) {
        NSFont *font = value;
        return [NSString stringWithFormat:@"font:%@:%@:%ld:%ld", auto_hex(font.fontName ?: @""),
            auto_hex(font.familyName ?: @""), (long)auto_appkit_component(font.pointSize),
            (long)font.fontDescriptor.symbolicTraits];
    }
    if ([value isKindOfClass:NSFontDescriptor.class]) {
        NSFontDescriptor *descriptor = value;
        return [NSString stringWithFormat:@"font-descriptor:%@:%ld:%lu", auto_canonical(descriptor.fontAttributes),
            (long)auto_appkit_component(descriptor.pointSize), (unsigned long)descriptor.symbolicTraits];
    }
    if ([value isKindOfClass:NSBezierPath.class]) {
        NSBezierPath *path = value;
        NSRect bounds = path.bounds;
        NSPoint point = path.elementCount ? path.currentPoint : NSZeroPoint;
        return [NSString stringWithFormat:@"bezier-path:%ld:%ld,%ld,%ld,%ld:%ld,%ld:%ld",
            (long)path.elementCount, (long)auto_appkit_geometry(bounds.origin.x),
            (long)auto_appkit_geometry(bounds.origin.y), (long)auto_appkit_geometry(bounds.size.width),
            (long)auto_appkit_geometry(bounds.size.height), (long)auto_appkit_geometry(point.x),
            (long)auto_appkit_geometry(point.y), (long)auto_appkit_geometry(path.lineWidth)];
    }
    if ([value isKindOfClass:NSAffineTransform.class]) {
        NSAffineTransformStruct t = [(NSAffineTransform *)value transformStruct];
        return [NSString stringWithFormat:@"affine-transform:%ld,%ld,%ld,%ld,%ld,%ld",
            (long)auto_appkit_geometry(t.m11), (long)auto_appkit_geometry(t.m12),
            (long)auto_appkit_geometry(t.m21), (long)auto_appkit_geometry(t.m22),
            (long)auto_appkit_geometry(t.tX), (long)auto_appkit_geometry(t.tY)];
    }
    if ([value isKindOfClass:NSBitmapImageRep.class]) {
        NSBitmapImageRep *rep = value;
        NSUInteger length = MIN((NSUInteger)MAX(0, rep.bytesPerRow * rep.pixelsHigh), (NSUInteger)16);
        const unsigned char *pixels = rep.bitmapData;
        NSMutableString *bytes = [NSMutableString string];
        for (NSUInteger i = 0; pixels && i < length; i++) [bytes appendFormat:@"%02x", pixels[i]];
        return [NSString stringWithFormat:@"bitmap:%ldx%ld:%ld:%ld:%@", (long)rep.pixelsWide,
            (long)rep.pixelsHigh, (long)rep.samplesPerPixel, (long)rep.bitsPerSample, bytes];
    }
    if ([value isKindOfClass:NSImageRep.class]) {
        NSImageRep *rep = value;
        NSSize size = rep.size;
        return [NSString stringWithFormat:@"image-rep:%ldx%ld:%ld,%ld:%d:%@", (long)rep.pixelsWide,
            (long)rep.pixelsHigh, (long)auto_appkit_geometry(size.width), (long)auto_appkit_geometry(size.height),
            rep.hasAlpha, auto_hex(rep.colorSpaceName ?: @"")];
    }
    if ([value isKindOfClass:NSImage.class]) {
        NSImage *image = value;
        NSSize size = image.size;
        return [NSString stringWithFormat:@"image:%ld,%ld:%@", (long)auto_appkit_geometry(size.width),
            (long)auto_appkit_geometry(size.height), auto_canonical(image.representations ?: @[])];
    }
    if ([value isKindOfClass:NSParagraphStyle.class]) {
        NSParagraphStyle *style = value;
        return [NSString stringWithFormat:@"paragraph:%ld:%ld:%ld,%ld,%ld,%ld,%ld:%@", (long)style.alignment,
            (long)style.baseWritingDirection, (long)auto_appkit_geometry(style.lineSpacing),
            (long)auto_appkit_geometry(style.paragraphSpacing), (long)auto_appkit_geometry(style.firstLineHeadIndent),
            (long)auto_appkit_geometry(style.headIndent), (long)auto_appkit_geometry(style.tailIndent),
            auto_canonical(style.tabStops ?: @[])];
    }
    if ([value isKindOfClass:NSTextTab.class]) {
        NSTextTab *tab = value;
        return [NSString stringWithFormat:@"text-tab:%ld:%ld:%@", (long)tab.tabStopType,
            (long)auto_appkit_geometry(tab.location), auto_canonical(tab.options ?: @{})];
    }
    if ([value isKindOfClass:NSShadow.class]) {
        NSShadow *shadow = value;
        NSSize offset = shadow.shadowOffset;
        return [NSString stringWithFormat:@"shadow:%ld,%ld:%ld:%@", (long)auto_appkit_geometry(offset.width),
            (long)auto_appkit_geometry(offset.height), (long)auto_appkit_geometry(shadow.shadowBlurRadius),
            auto_canonical(shadow.shadowColor)];
    }
    if ([value isKindOfClass:NSGradient.class]) {
        NSGradient *gradient = value;
        return [NSString stringWithFormat:@"gradient:%ld:%@:%@", (long)gradient.numberOfColorStops,
            auto_canonical([gradient interpolatedColorAtLocation:0.0]),
            auto_canonical([gradient interpolatedColorAtLocation:1.0])];
    }
    if ([value isKindOfClass:NSCursor.class]) {
        NSCursor *cursor = value;
        return [NSString stringWithFormat:@"cursor:%@:%ld,%ld", auto_canonical(cursor.image),
            (long)auto_appkit_geometry(cursor.hotSpot.x), (long)auto_appkit_geometry(cursor.hotSpot.y)];
    }
    if ([value isKindOfClass:NSAppearance.class])
        return [NSString stringWithFormat:@"appearance:%@", auto_hex([(NSAppearance *)value name] ?: @"")];
    if ([value isKindOfClass:NSEvent.class]) {
        NSEvent *event = value;
        NSPoint point = event.locationInWindow;
        return [NSString stringWithFormat:@"event:%ld:%ld,%ld:%lu:%ld:%ld:%ld:%ld", (long)event.type,
            (long)auto_appkit_geometry(point.x), (long)auto_appkit_geometry(point.y),
            (unsigned long)event.modifierFlags, (long)auto_appkit_geometry(event.timestamp),
            (long)event.windowNumber, (long)event.clickCount, (long)auto_appkit_component(event.pressure)];
    }
    if ([value isKindOfClass:NSLayoutManager.class]) {
        NSLayoutManager *manager = value;
        return [NSString stringWithFormat:@"layout-manager:%@:%lu:%lu:%d:%d", auto_canonical(manager.textStorage.string ?: @""),
            (unsigned long)manager.textContainers.count, (unsigned long)manager.numberOfGlyphs,
            manager.usesFontLeading, manager.allowsNonContiguousLayout];
    }
    if ([value isKindOfClass:NSTextContainer.class]) {
        NSTextContainer *container = value;
        NSSize size = container.containerSize;
        return [NSString stringWithFormat:@"text-container:%ld,%ld:%ld:%lu:%lu:%lu:%d:%d",
            (long)auto_appkit_geometry(size.width), (long)auto_appkit_geometry(size.height),
            (long)auto_appkit_geometry(container.lineFragmentPadding), (unsigned long)container.maximumNumberOfLines,
            (unsigned long)container.lineBreakMode, (unsigned long)container.layoutOrientation,
            container.widthTracksTextView, container.heightTracksTextView];
    }
    if ([value isKindOfClass:NSTextView.class]) {
        NSTextView *textView = value;
        NSRange selection = textView.selectedRange;
        return [NSString stringWithFormat:@"text-view:%@:%lu,%lu:%d:%d:%d:%d",
            auto_canonical(textView.string ?: @""), (unsigned long)selection.location,
            (unsigned long)selection.length, textView.isRichText, textView.isEditable,
            textView.isSelectable, textView.allowsUndo];
    }
    if ([value isKindOfClass:NSScrollView.class]) {
        NSScrollView *scrollView = value;
        NSSize size = scrollView.contentSize;
        NSRect frame = scrollView.frame;
        return [NSString stringWithFormat:@"scroll-view:%ld,%ld:%ld,%ld:%lu:%d:%d:%d:%d:%d",
            (long)auto_appkit_geometry(frame.size.width), (long)auto_appkit_geometry(frame.size.height),
            (long)auto_appkit_geometry(size.width), (long)auto_appkit_geometry(size.height),
            (unsigned long)scrollView.borderType, scrollView.hasHorizontalScroller,
            scrollView.hasVerticalScroller, scrollView.autohidesScrollers,
            (int)scrollView.scrollerStyle, (int)scrollView.horizontalScrollElasticity];
    }
    if ([value isKindOfClass:NSButton.class]) {
        NSButton *button = value;
        return [NSString stringWithFormat:@"button:%@:%@:%@:%@:%ld:%d:%d:%@:%@", auto_canonical(button.cell),
            auto_hex(button.title ?: @""), auto_hex(button.alternateTitle ?: @""), auto_canonical(button.image),
            (long)button.state, button.allowsMixedState, button.isBordered, auto_canonical(button.alternateImage),
            auto_canonical(button.contentTintColor)];
    }
    if ([value isKindOfClass:NSTextField.class]) {
        NSTextField *field = value;
        return [NSString stringWithFormat:@"text-field:%@:%@:%d:%d:%d:%d:%ld", auto_canonical(field.cell),
            auto_hex(field.placeholderString ?: @""), field.isEditable, field.isSelectable, field.isBordered,
            field.drawsBackground, (long)auto_appkit_geometry(field.preferredMaxLayoutWidth)];
    }
    if ([value isKindOfClass:NSComboBox.class]) {
        NSComboBox *combo = value;
        return [NSString stringWithFormat:@"combo:%@:%@:%ld:%ld:%ld:%d:%d:%@", auto_canonical(combo.cell),
            auto_canonical(combo.objectValues), (long)combo.numberOfItems, (long)combo.indexOfSelectedItem,
            (long)combo.numberOfVisibleItems, combo.completes, combo.usesDataSource,
            auto_hex(combo.stringValue ?: @"")];
    }
    if ([value isKindOfClass:NSSegmentedControl.class]) {
        NSSegmentedControl *control = value;
        NSMutableArray *labels = [NSMutableArray array];
        for (NSInteger i = 0; i < control.segmentCount; i++) {
            id label = [control labelForSegment:i];
            [labels addObject:label ?: [NSNull null]];
        }
        return [NSString stringWithFormat:@"segmented:%@:%ld:%ld:%ld:%@", auto_canonical(control.cell),
            (long)control.segmentCount, (long)control.selectedSegment, (long)control.trackingMode,
            auto_canonical(labels)];
    }
    if ([value isKindOfClass:NSProgressIndicator.class]) {
        NSProgressIndicator *indicator = value;
        return [NSString stringWithFormat:@"progress:%ld:%ld:%a:%a:%a:%d:%d:%d", (long)indicator.style,
            (long)indicator.controlSize, indicator.doubleValue, indicator.minValue, indicator.maxValue,
            indicator.isIndeterminate, indicator.isBezeled, indicator.isDisplayedWhenStopped];
    }
    if ([value isKindOfClass:NSSlider.class]) {
        NSSlider *slider = value;
        return [NSString stringWithFormat:@"slider:%@:%a:%a:%a:%a:%ld:%ld:%ld:%d:%d", auto_canonical(slider.cell),
            slider.doubleValue, slider.minValue, slider.maxValue, slider.altIncrementValue,
            (long)slider.sliderType, (long)slider.tickMarkPosition, (long)slider.numberOfTickMarks,
            slider.isVertical, slider.allowsTickMarkValuesOnly];
    }
    if ([value isKindOfClass:NSLevelIndicator.class]) {
        NSLevelIndicator *indicator = value;
        return [NSString stringWithFormat:@"level-indicator:%@:%a:%a:%a:%a:%a:%ld:%ld:%ld:%d", auto_canonical(indicator.cell),
            indicator.doubleValue, indicator.minValue, indicator.maxValue, indicator.warningValue, indicator.criticalValue,
            (long)indicator.levelIndicatorStyle, (long)indicator.tickMarkPosition, (long)indicator.numberOfTickMarks,
            indicator.drawsTieredCapacityLevels];
    }
    if ([value isKindOfClass:NSPopUpButton.class]) {
        NSPopUpButton *button = value;
        return [NSString stringWithFormat:@"pop-up:%@:%@:%ld:%ld:%d:%d:%d", auto_canonical(button.cell),
            auto_canonical(button.itemTitles), (long)button.numberOfItems, (long)button.indexOfSelectedItem,
            button.pullsDown, button.autoenablesItems, button.altersStateOfSelectedItem];
    }
    if ([value isKindOfClass:NSTabView.class]) {
        NSTabView *tabView = value;
        NSMutableArray *items = [NSMutableArray array];
        for (NSTabViewItem *item in tabView.tabViewItems)
            [items addObject:[NSString stringWithFormat:@"%@:%@", auto_hex([item.identifier description] ?: @""), auto_hex(item.label ?: @"")]];
        return [NSString stringWithFormat:@"tab-view:%@:%ld:%ld:%ld:%ld:%@", auto_canonical(items),
            (long)tabView.numberOfTabViewItems, (long)tabView.tabViewType, (long)tabView.tabPosition,
            (long)tabView.tabViewBorderType, auto_hex(tabView.selectedTabViewItem.label ?: @"")];
    }
    if ([value isKindOfClass:NSTabViewItem.class]) {
        NSTabViewItem *item = value;
        return [NSString stringWithFormat:@"tab-view-item:%@:%@:%@:%ld:%@:%@", auto_hex([item.identifier description] ?: @""),
            auto_hex(item.label ?: @""), auto_canonical(item.color), (long)item.tabState,
            auto_canonical(item.image), auto_canonical(item.view)];
    }
    if ([value isKindOfClass:NSMatrix.class]) {
        NSMatrix *matrix = value;
        return [NSString stringWithFormat:@"matrix:%@:%ld:%ld:%ld:%ld:%ld:%d:%d", auto_canonical(matrix.cells),
            (long)matrix.numberOfRows, (long)matrix.numberOfColumns, (long)matrix.selectedRow, (long)matrix.selectedColumn,
            (long)matrix.mode, matrix.allowsEmptySelection, matrix.autorecalculatesCellSize];
    }
    if ([value isKindOfClass:NSGridView.class]) {
        NSGridView *grid = value;
        return [NSString stringWithFormat:@"grid:%ld:%ld:%a:%a:%ld:%ld", (long)grid.numberOfRows,
            (long)grid.numberOfColumns, grid.rowSpacing, grid.columnSpacing, (long)grid.xPlacement, (long)grid.yPlacement];
    }
    if ([value isKindOfClass:NSGridRow.class]) {
        NSGridRow *row = value;
        return [NSString stringWithFormat:@"grid-row:%ld:%a:%a:%ld:%ld:%d", (long)row.numberOfCells,
            row.topPadding, row.bottomPadding, (long)row.height, (long)row.rowAlignment, row.isHidden];
    }
    if ([value isKindOfClass:NSGridColumn.class]) {
        NSGridColumn *column = value;
        return [NSString stringWithFormat:@"grid-column:%ld:%a:%a:%a:%ld:%d", (long)column.numberOfCells,
            column.width, column.leadingPadding, column.trailingPadding, (long)column.xPlacement, column.isHidden];
    }
    if ([value isKindOfClass:NSGridCell.class]) {
        NSGridCell *cell = value;
        return [NSString stringWithFormat:@"grid-cell:%ld:%ld:%ld:%ld:%@", (long)[cell.row.gridView indexOfRow:cell.row],
            (long)[cell.column.gridView indexOfColumn:cell.column], (long)cell.xPlacement, (long)cell.yPlacement,
            auto_canonical(cell.contentView)];
    }
    if ([value isKindOfClass:NSRulerMarker.class]) {
        NSRulerMarker *marker = value;
        return [NSString stringWithFormat:@"ruler-marker:%ld:%@:%ld,%ld:%d:%d:%@", (long)auto_appkit_geometry(marker.markerLocation),
            auto_canonical(marker.image), (long)auto_appkit_geometry(marker.imageOrigin.x),
            (long)auto_appkit_geometry(marker.imageOrigin.y), marker.isMovable, marker.isRemovable,
            auto_canonical(marker.representedObject)];
    }
    if ([value isKindOfClass:NSRulerView.class]) {
        NSRulerView *ruler = value;
        return [NSString stringWithFormat:@"ruler:%ld:%@:%ld:%ld:%ld:%ld:%lu:%d", (long)ruler.orientation,
            auto_hex(ruler.measurementUnits ?: @""), (long)auto_appkit_geometry(ruler.ruleThickness),
            (long)auto_appkit_geometry(ruler.reservedThicknessForMarkers),
            (long)auto_appkit_geometry(ruler.reservedThicknessForAccessoryView),
            (long)auto_appkit_geometry(ruler.originOffset), (unsigned long)ruler.markers.count, ruler.isFlipped];
    }
    if ([value isKindOfClass:NSBox.class]) {
        NSBox *box = value;
        return [NSString stringWithFormat:@"box:%@:%ld:%ld:%a:%@:%@:%@:%ld:%d", auto_hex(box.title ?: @""),
            (long)box.boxType, (long)box.borderType, box.borderWidth, auto_canonical(box.borderColor),
            auto_canonical(box.fillColor), auto_canonical(box.contentView), (long)box.titlePosition, box.isTransparent];
    }
    if ([value isKindOfClass:NSControl.class]) {
        NSControl *control = value;
        return [NSString stringWithFormat:@"control:%@:%@:%@:%@:%d:%d:%ld:%ld", NSStringFromClass([control class]),
            auto_canonical(control.cell), auto_canonical(control.objectValue), auto_hex(control.stringValue ?: @""),
            control.isEnabled, control.isContinuous, (long)control.controlSize, (long)control.alignment];
    }
    if ([value isKindOfClass:NSView.class]) {
        NSView *view = value;
        NSRect frame = view.frame, bounds = view.bounds;
        return [NSString stringWithFormat:@"view:%ld,%ld,%ld,%ld:%ld,%ld,%ld,%ld:%d:%d:%lu",
            (long)auto_appkit_geometry(frame.origin.x), (long)auto_appkit_geometry(frame.origin.y),
            (long)auto_appkit_geometry(frame.size.width), (long)auto_appkit_geometry(frame.size.height),
            (long)auto_appkit_geometry(bounds.origin.x), (long)auto_appkit_geometry(bounds.origin.y),
            (long)auto_appkit_geometry(bounds.size.width), (long)auto_appkit_geometry(bounds.size.height),
            view.isHidden, view.isOpaque, (unsigned long)view.autoresizingMask];
    }
    if ([value isKindOfClass:NSLayoutConstraint.class]) {
        NSLayoutConstraint *constraint = value;
        return [NSString stringWithFormat:@"constraint:%ld:%ld:%ld:%ld,%ld:%ld:%ld:%@:%d", (long)constraint.firstAttribute,
            (long)constraint.relation, (long)constraint.secondAttribute,
            (long)auto_appkit_geometry(constraint.multiplier), (long)auto_appkit_geometry(constraint.constant),
            (long)auto_appkit_component(constraint.priority), (long)constraint.isActive,
            auto_hex(constraint.identifier ?: @""), constraint.firstItem != nil];
    }
    if ([value isKindOfClass:NSLayoutAnchor.class]) {
        return [NSString stringWithFormat:@"layout-anchor:%@", NSStringFromClass([value class])];
    }
    if ([value isKindOfClass:NSPasteboard.class]) {
        NSPasteboard *board = value;
        return [NSString stringWithFormat:@"pasteboard:%@:%@", auto_hex(auto_appkit_private_name(board.name)),
            auto_canonical(board.types ?: @[])];
    }
    if ([value isKindOfClass:NSPrintInfo.class]) {
        NSPrintInfo *info = value;
        NSSize size = info.paperSize;
        NSString *paperName = info.paperName ?: @"";
        if (![paperName isEqualToString:@"na-letter"] && ![paperName isEqualToString:@"iso-a4"])
            paperName = @"<custom>";
        return [NSString stringWithFormat:@"print-info:%@:%ld:%ld,%ld:%ld,%ld,%ld,%ld:%ld", auto_hex(paperName),
            (long)info.orientation, (long)auto_appkit_geometry(size.width), (long)auto_appkit_geometry(size.height),
            (long)auto_appkit_geometry(info.leftMargin), (long)auto_appkit_geometry(info.rightMargin),
            (long)auto_appkit_geometry(info.topMargin), (long)auto_appkit_geometry(info.bottomMargin),
            (long)auto_appkit_geometry(info.scalingFactor)];
    }
#endif
    if ([value isKindOfClass:NSString.class]) return [@"string:" stringByAppendingString:auto_hex(value)];
    if ([value isKindOfClass:NSNumber.class]) {
        if (CFGetTypeID((CFTypeRef)value) == CFBooleanGetTypeID())
            return [NSString stringWithFormat:@"bool:%d", [value boolValue]];
        return [@"number:" stringByAppendingString:auto_hex([value stringValue])];
    }
    if ([value isKindOfClass:NSData.class]) {
        const unsigned char *bytes = [value bytes]; NSMutableString *hex = [NSMutableString stringWithFormat:@"data:%lu:", (unsigned long)[value length]];
        for (NSUInteger i = 0; i < [value length]; i++) [hex appendFormat:@"%02x", bytes[i]];
        return hex;
    }
    if ([value isKindOfClass:NSDate.class]) return [NSString stringWithFormat:@"date:%a", [value timeIntervalSinceReferenceDate]];
    if ([value isKindOfClass:NSDateComponents.class]) {
        NSDateComponents *parts = value;
        NSString *calendar = parts.calendar.calendarIdentifier ?: @"";
        NSString *zone = parts.timeZone.name ?: @"";
        return [NSString stringWithFormat:@"date-components:%ld,%ld,%ld,%ld,%ld,%ld,%ld,%ld,%ld,%ld,%ld,%ld,%ld,%d:%@:%@",
            (long)parts.era, (long)parts.year, (long)parts.month, (long)parts.day, (long)parts.hour,
            (long)parts.minute, (long)parts.second, (long)parts.nanosecond, (long)parts.weekday,
            (long)parts.weekdayOrdinal, (long)parts.quarter, (long)parts.weekOfMonth,
            (long)parts.weekOfYear, parts.isLeapMonth, auto_hex(calendar), auto_hex(zone)];
    }
    if ([value isKindOfClass:NSURL.class]) return [@"url:" stringByAppendingString:auto_hex([value absoluteString] ?: @"")];
    if ([value isKindOfClass:NSURLComponents.class]) return [@"url-components:" stringByAppendingString:auto_hex([value string] ?: @"")];
    if ([value isKindOfClass:NSLocale.class]) return [@"locale:" stringByAppendingString:auto_hex([value localeIdentifier] ?: @"")];
    if ([value isKindOfClass:NSTimeZone.class]) return [NSString stringWithFormat:@"timezone:%@:%ld", auto_hex([value name]), (long)[value secondsFromGMTForDate:[NSDate dateWithTimeIntervalSinceReferenceDate:700000000]]];
    if ([value isKindOfClass:NSThread.class]) return [NSString stringWithFormat:@"thread:%@", auto_hex([value name] ?: @"")];
    if ([value isKindOfClass:NSPointerFunctions.class]) return [NSString stringWithFormat:@"pointer-functions:%lu", (unsigned long)[(NSPointerFunctions *)value options]];
    if ([value isKindOfClass:NSIndexSet.class]) {
        NSIndexSet *indexes = value;
        NSMutableArray *parts = [NSMutableArray array];
        NSUInteger index = indexes.firstIndex;
        while (index != NSNotFound && parts.count < 256) {
            [parts addObject:@(index)];
            index = [indexes indexGreaterThanIndex:index];
        }
        return [NSString stringWithFormat:@"index-set:%@", auto_canonical(parts)];
    }
    if ([value isKindOfClass:NSCalendar.class]) {
        NSCalendar *calendar = value; NSTimeZone *zone = calendar.timeZone;
        return [NSString stringWithFormat:@"calendar:%@:%@:%lu", auto_hex([calendar calendarIdentifier]), auto_hex([zone name]), (unsigned long)calendar.firstWeekday];
    }
    if ([value isKindOfClass:NSError.class]) return [NSString stringWithFormat:@"error:%@:%ld", auto_hex([value domain]), (long)[value code]];
    if ([value isKindOfClass:NSNotificationCenter.class]) return @"notification-center";
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *parts = [NSMutableArray array]; for (id object in value) [parts addObject:auto_canonical(object)];
        return [NSString stringWithFormat:@"array:[%@]", [parts componentsJoinedByString:@","]];
    }
    if ([value isKindOfClass:NSEnumerator.class]) {
        NSMutableArray *parts = [NSMutableArray array]; id object;
        while ((object = [value nextObject])) [parts addObject:auto_canonical(object)];
        return [NSString stringWithFormat:@"enumerator:[%@]", [parts componentsJoinedByString:@","]];
    }
    if ([value isKindOfClass:NSOrderedSet.class]) {
        NSMutableArray *parts = [NSMutableArray array]; for (id object in value) [parts addObject:auto_canonical(object)];
        return [NSString stringWithFormat:@"ordered-set:[%@]", [parts componentsJoinedByString:@","]];
    }
    if ([value isKindOfClass:NSSet.class]) {
        NSMutableArray *parts = [NSMutableArray array]; for (id object in value) [parts addObject:auto_canonical(object)];
        [parts sortUsingSelector:@selector(compare:)];
        return [NSString stringWithFormat:@"set:{%@}", [parts componentsJoinedByString:@","]];
    }
    if ([value isKindOfClass:NSHashTable.class]) {
        NSHashTable *table = (NSHashTable *)value;
        NSMutableArray *parts = [NSMutableArray array]; for (id object in table.allObjects) [parts addObject:auto_canonical(object)];
        [parts sortUsingSelector:@selector(compare:)];
        return [NSString stringWithFormat:@"hash-table:{%@}", [parts componentsJoinedByString:@","]];
    }
    if ([value isKindOfClass:NSMapTable.class]) return auto_canonical([(NSMapTable *)value dictionaryRepresentation]);
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableArray *parts = [NSMutableArray array];
        for (id key in value) [parts addObject:[NSString stringWithFormat:@"%@=%@", auto_canonical(key), auto_canonical(value[key])]];
        [parts sortUsingSelector:@selector(compare:)];
        return [NSString stringWithFormat:@"dictionary:{%@}", [parts componentsJoinedByString:@","]];
    }
    if ([value isKindOfClass:NSAttributedString.class]) {
        id attributes = [value length] ? [value attributesAtIndex:0 effectiveRange:NULL] : @{};
        return [NSString stringWithFormat:@"attributed:%@:%@", auto_canonical([value string]), auto_canonical(attributes)];
    }
    if ([value isKindOfClass:NSValue.class]) {
        const char *type = [value objCType];
        if (!strcmp(type, @encode(NSRange))) { NSRange range = [value rangeValue]; return [NSString stringWithFormat:@"range:%lu,%lu", (unsigned long)range.location, (unsigned long)range.length]; }
#ifdef FINCH_DIFFTEST_APPKIT
        if (!strcmp(type, @encode(NSPoint))) { NSPoint point = [value pointValue]; return [NSString stringWithFormat:@"point:%ld,%ld", (long)auto_appkit_geometry(point.x), (long)auto_appkit_geometry(point.y)]; }
        if (!strcmp(type, @encode(NSSize))) { NSSize size = [value sizeValue]; return [NSString stringWithFormat:@"size:%ld,%ld", (long)auto_appkit_geometry(size.width), (long)auto_appkit_geometry(size.height)]; }
        if (!strcmp(type, @encode(NSRect))) { NSRect rect = [value rectValue]; return [NSString stringWithFormat:@"rect:%ld,%ld,%ld,%ld", (long)auto_appkit_geometry(rect.origin.x), (long)auto_appkit_geometry(rect.origin.y), (long)auto_appkit_geometry(rect.size.width), (long)auto_appkit_geometry(rect.size.height)]; }
        if (!strcmp(type, @encode(NSEdgeInsets))) {
            NSEdgeInsets insets = [value edgeInsetsValue];
            return [NSString stringWithFormat:@"edge-insets:%ld,%ld,%ld,%ld",
                (long)auto_appkit_geometry(insets.top), (long)auto_appkit_geometry(insets.left),
                (long)auto_appkit_geometry(insets.bottom), (long)auto_appkit_geometry(insets.right)];
        }
        if (!strcmp(type, @encode(NSAffineTransformStruct))) {
            NSAffineTransformStruct t; [value getValue:&t];
            return [NSString stringWithFormat:@"affine-transform:%ld,%ld,%ld,%ld,%ld,%ld",
                (long)auto_appkit_geometry(t.m11), (long)auto_appkit_geometry(t.m12),
                (long)auto_appkit_geometry(t.m21), (long)auto_appkit_geometry(t.m22),
                (long)auto_appkit_geometry(t.tX), (long)auto_appkit_geometry(t.tY)];
        }
#else
        if (!strcmp(type, @encode(NSPoint))) { NSPoint point = [value pointValue]; return [NSString stringWithFormat:@"point:%a,%a", point.x, point.y]; }
        if (!strcmp(type, @encode(NSSize))) { NSSize size = [value sizeValue]; return [NSString stringWithFormat:@"size:%a,%a", size.width, size.height]; }
        if (!strcmp(type, @encode(NSRect))) { NSRect rect = [value rectValue]; return [NSString stringWithFormat:@"rect:%a,%a,%a,%a", rect.origin.x, rect.origin.y, rect.size.width, rect.size.height]; }
#endif
        return [NSString stringWithFormat:@"value:%s:%@", type, auto_hex([value description])];
    }
    if ([value isKindOfClass:NSCharacterSet.class]) {
        static const UTF32Char chars[] = {'a', 'A', 0x00e9, 0x4e2d, 0x1f642, 0x05d0};
        NSMutableString *bits = [NSMutableString stringWithString:@"charset:"];
        for (size_t i = 0; i < sizeof(chars) / sizeof(chars[0]); i++) [bits appendFormat:@"%d", [value longCharacterIsMember:chars[i]]];
        return bits;
    }
    NSString *description = [value description] ?: @"";
    description = [description stringByReplacingOccurrencesOfString:@"0x[0-9a-fA-F]+" withString:@"<ADDRESS>"
        options:NSRegularExpressionSearch range:NSMakeRange(0, description.length)];
    return [NSString stringWithFormat:@"%@:%@", NSStringFromClass([value class]), auto_hex(description)];
}

static void auto_print(NSString *value)
{
    const unsigned char *bytes = [value UTF8String];
    if (!bytes) { fputs("null", stdout); return; }
    while (*bytes) printf("%02x", *bytes++);
}

#ifdef FINCH_DIFFTEST_APPKIT
static NSBitmapImageRep *auto_bitmap(void)
{
    return [[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:2 pixelsHigh:2
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:8 bitsPerPixel:32] autorelease];
}

static NSImage *auto_image(void)
{
    NSImage *image = [[[NSImage alloc] initWithSize:NSMakeSize(2, 2)] autorelease];
    NSBitmapImageRep *rep = auto_bitmap();
    if (image && rep) [image addRepresentation:rep];
    return image;
}

static NSColor *auto_color(NSUInteger index)
{
    static const CGFloat red[] = {0, 0.25, 0.5, 0.75, 1, 0.1, 0.9, 0.35};
    static const CGFloat green[] = {0.75, 0.9, 0.1, 0.25, 0.5, 1, 0.35, 0};
    static const CGFloat blue[] = {0.5, 0.1, 0.9, 0.35, 0, 0.75, 0.25, 1};
    return [NSColor colorWithSRGBRed:red[index % 8] green:green[index % 8]
        blue:blue[index % 8] alpha:(index % 2) ? 1.0 : 0.5];
}

static NSEvent *auto_event(void)
{
    return [NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSMakePoint(4, 6)
        modifierFlags:NSEventModifierFlagShift timestamp:1.25 windowNumber:0 context:nil
        subtype:7 data1:42 data2:-13];
}

static NSPasteboard *auto_private_pasteboard(NSString *selectorName)
{
    NSString *suffix = selectorName.length ?
        [selectorName stringByReplacingOccurrencesOfString:@":" withString:@"-"] : @"default";
    NSString *name = [NSString stringWithFormat:@"org.finch.difftest.receiver.%@", suffix];
    NSPasteboard *board = [NSPasteboard pasteboardWithName:name];
    [board clearContents];
    return board;
}

static NSView *auto_layout_root(void)
{
    static NSView *view;
    if (!view) view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
    return view;
}

static NSView *auto_layout_view(void);

static NSView *auto_layout_peer_view(void)
{
    static NSView *view;
    if (!view) {
        view = [[NSView alloc] initWithFrame:NSMakeRect(20, 30, 120, 80)];
        [auto_layout_root() addSubview:view];
    }
    return view;
}

static NSView *auto_layout_view(void)
{
    static NSView *view;
    if (!view) {
        view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 120, 80)];
        [auto_layout_root() addSubview:view];
    }
    return view;
}

static NSGridView *auto_grid_view(void)
{
    static NSGridView *view;
    if (!view) view = [[NSGridView gridViewWithNumberOfColumns:2 rows:2] retain];
    return view;
}

static NSScrollView *auto_ruler_scroll_view(void)
{
    static NSScrollView *view;
    if (!view) view = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 160, 96)];
    return view;
}

static NSRulerView *auto_ruler_view(void)
{
    static NSRulerView *view;
    if (!view) view = [[NSRulerView alloc] initWithScrollView:auto_ruler_scroll_view()
        orientation:NSHorizontalRuler];
    return view;
}

static NSLayoutConstraint *auto_constraint(void)
{
    NSView *view = auto_layout_view();
    return [NSLayoutConstraint constraintWithItem:view attribute:NSLayoutAttributeWidth
        relatedBy:NSLayoutRelationEqual toItem:nil attribute:NSLayoutAttributeNotAnAttribute
        multiplier:1 constant:42];
}

static NSTextStorage *auto_text_storage(void)
{
    return [[[NSTextStorage alloc] initWithString:@"Finch café🙂" attributes:@{
        NSFontAttributeName:[NSFont systemFontOfSize:12]
    }] autorelease];
}

static NSLayoutManager *auto_text_layout_manager(void)
{
    NSTextStorage *storage = auto_text_storage();
    NSLayoutManager *manager = [[[NSLayoutManager alloc] init] autorelease];
    [storage addLayoutManager:manager];
    NSTextContainer *container = [[[NSTextContainer alloc] initWithContainerSize:NSMakeSize(160, 96)] autorelease];
    container.lineFragmentPadding = 4;
    [manager addTextContainer:container];
    return manager;
}

static NSTextContainer *auto_text_container(void)
{
    return auto_text_layout_manager().textContainers.firstObject;
}

static NSTextView *auto_text_view(void)
{
    return [[[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 160, 96)
        textContainer:auto_text_container()] autorelease];
}
#endif

static NSData *auto_data(const void *bytes, NSUInteger length)
{
    return [(NSData *)CFDataCreate(kCFAllocatorDefault, bytes, (CFIndex)length) autorelease];
}

static id auto_object(NSString *type, NSUInteger index);
static id auto_dynamic_init(NSString *className);

static NSArray *auto_generic_arguments(NSString *type)
{
    NSRange opening = [type rangeOfString:@"<"];
    if (opening.location == NSNotFound) return @[];
    NSMutableArray *arguments = [NSMutableArray array];
    NSUInteger depth = 0, start = NSMaxRange(opening);
    for (NSUInteger index = start; index < type.length; index++) {
        unichar character = [type characterAtIndex:index];
        if (character == '<') depth++;
        else if (character == '>') {
            if (!depth) {
                NSString *argument = [[type substringWithRange:NSMakeRange(start, index - start)]
                    stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if (argument.length) [arguments addObject:argument];
                break;
            }
            depth--;
        } else if (character == ',' && !depth) {
            NSString *argument = [[type substringWithRange:NSMakeRange(start, index - start)]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (argument.length) [arguments addObject:argument];
            start = index + 1;
        }
    }
    return arguments;
}

static id auto_generic_object(NSString *type, NSUInteger index)
{
    NSString *clean = [type stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (![clean containsString:@"*"] && ![clean hasPrefix:@"id<"])
        clean = [clean stringByAppendingString:@" *"];
#ifdef FINCH_DIFFTEST_QUARTZCORE
    if ([clean isEqualToString:@"id<CAAction>"]) return [CAAnimation animation];
#endif
    return auto_object(clean, index);
}

#ifdef FINCH_DIFFTEST_PDFKIT
static NSData *auto_pdfkit_data(void)
{
    CGRect page = CGRectMake(0, 0, 120, 80);
    CFMutableDataRef data = CFDataCreateMutable(kCFAllocatorDefault, 0);
    CGDataConsumerRef consumer = CGDataConsumerCreateWithCFData(data);
    CGContextRef context = consumer ? CGPDFContextCreate(consumer, &page, NULL) : NULL;
    if (context) {
        CGPDFContextBeginPage(context, NULL);
        CGContextSelectFont(context, "Helvetica", 12, kCGEncodingMacRoman);
        CGContextShowTextAtPoint(context, 8, 40, "Finch generated page", 20);
        CGPDFContextEndPage(context);
        CGContextRelease(context);
    }
    if (consumer) CGDataConsumerRelease(consumer);
    NSData *result = [[[NSData alloc] initWithData:(NSData *)data] autorelease];
    CFRelease(data);
    return result;
}
#endif

#ifdef FINCH_DIFFTEST_AVFOUNDATION
static NSURL *auto_avfoundation_url(void)
{
    static NSURL *url;
    if (url) return url;
    (void)mkdir("build/difftest/fixtures", 0755);
    NSString *path = [NSString stringWithFormat:@"build/difftest/fixtures/avmovie-%d.mov", getpid()];
    NSData *first = [NSData dataWithBytes:frame0 length:sizeof(frame0)];
    NSData *second = [NSData dataWithBytes:frame1 length:sizeof(frame1)];
    NSData *movie = build_movie_with_frames(@[first, second]);
    if (![movie writeToFile:path atomically:YES]) return nil;
    url = [[NSURL fileURLWithPath:path] retain];
    return url;
}

static AVURLAsset *auto_avfoundation_asset(void)
{
    NSURL *url = auto_avfoundation_url();
    return url ? [AVURLAsset URLAssetWithURL:url options:nil] : nil;
}

static id auto_avfoundation_composition_track(void)
{
    id composition = auto_dynamic_init(@"AVMutableComposition");
    AVAssetTrack *source = [[auto_avfoundation_asset() tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (!composition || !source) return nil;
    id (*addTrack)(id, SEL, id, int32_t) = (void *)objc_msgSend;
    id track = addTrack(composition, NSSelectorFromString(@"addMutableTrackWithMediaType:preferredTrackID:"),
        AVMediaTypeVideo, kCMPersistentTrackID_Invalid);
    if (!track) return nil;
    NSError *error = nil;
    void (*insert)(id, SEL, CMTimeRange, id, CMTime, NSError **) = (void *)objc_msgSend;
    insert(track, NSSelectorFromString(@"insertTimeRange:ofTrack:atTime:error:"),
        CMTimeRangeMake(kCMTimeZero, CMTimeMake(1, 6)), source, kCMTimeZero, &error);
    return track;
}

#endif

#ifdef FINCH_DIFFTEST_IMAGEKIT
static CFDataRef auto_png_data(void);
#endif

static id auto_dynamic_init(NSString *className)
{
    Class cls = NSClassFromString(className);
    return cls ? [[[cls alloc] init] autorelease] : nil;
}

static id auto_dynamic_class_method0(NSString *className, NSString *selectorName)
{
    Class cls = NSClassFromString(className);
    if (!cls) return nil;
    id (*send)(id, SEL) = (void *)objc_msgSend;
    return send(cls, NSSelectorFromString(selectorName));
}

static id auto_dynamic_class_method1(NSString *className, NSString *selectorName, id argument)
{
    Class cls = NSClassFromString(className);
    if (!cls) return nil;
    id (*send)(id, SEL, id) = (void *)objc_msgSend;
    return send(cls, NSSelectorFromString(selectorName), argument);
}

static id auto_dynamic_class_method2(NSString *className, NSString *selectorName, id first, id second)
{
    Class cls = NSClassFromString(className);
    if (!cls) return nil;
    id (*send)(id, SEL, id, id) = (void *)objc_msgSend;
    return send(cls, NSSelectorFromString(selectorName), first, second);
}

static id auto_object(NSString *type, NSUInteger index)
{
    NSString *clean = auto_clean_type(type);
    NSArray *genericArguments = auto_generic_arguments(clean);
    NSString *base = [[clean componentsSeparatedByString:@"<"] firstObject];
    base = [[base componentsSeparatedByString:@"*"] firstObject];
    base = [base stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([base isEqualToString:@"NSUnitLength"]) return NSUnitLength.meters;
    if ([base isEqualToString:@"NSUnitTemperature"]) return NSUnitTemperature.celsius;
    if ([base isEqualToString:@"NSUnitDuration"]) return NSUnitDuration.seconds;
    if ([base isEqualToString:@"NSUnitInformationStorage"]) return NSUnitInformationStorage.bytes;
    if ([base isEqualToString:@"NSUnit"]) return [[[NSUnit alloc] initWithSymbol:@"m"] autorelease];
    if ([base isEqualToString:@"NSMeasurement"]) {
        NSUnit *unit = NSUnitLength.meters;
        if ([clean containsString:@"NSUnitInformationStorage"]) unit = NSUnitInformationStorage.bytes;
        else if ([clean containsString:@"NSUnitTemperature"]) unit = NSUnitTemperature.celsius;
        else if ([clean containsString:@"NSUnitDuration"]) unit = NSUnitDuration.seconds;
        return [[[NSMeasurement alloc] initWithDoubleValue:42.5 unit:unit] autorelease];
    }
    if ([base isEqualToString:@"NSPersonNameComponents"]) {
        NSPersonNameComponents *components = [[[NSPersonNameComponents alloc] init] autorelease];
        components.namePrefix = @"Dr."; components.givenName = @"Ada"; components.middleName = @"Byron";
        components.familyName = @"Lovelace"; components.nameSuffix = @"Jr."; components.nickname = @"Finch";
        return components;
    }
    if ([base isEqualToString:@"NSScanner"]) {
        NSScanner *scanner = [NSScanner scannerWithString:@"42 -17 3.5 0x2a"];
        scanner.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        return scanner;
    }
    if ([base isEqualToString:@"NSFileWrapper"]) {
        NSFileWrapper *wrapper = [[[NSFileWrapper alloc] initRegularFileWithContents:auto_data("finch", 5)] autorelease];
        wrapper.filename = @"finch.txt"; wrapper.preferredFilename = @"finch.txt";
        wrapper.fileAttributes = @{NSFileType:NSFileTypeRegular, NSFilePosixPermissions:@0644};
        return wrapper;
    }
    if ([base isEqualToString:@"NSProgress"]) {
        NSProgress *progress = [NSProgress progressWithTotalUnitCount:100];
        progress.completedUnitCount = 42; progress.cancellable = YES; progress.pausable = YES;
        progress.localizedDescription = @"Finch";
        return progress;
    }
#ifdef FINCH_DIFFTEST_PDFKIT
    if ([base isEqualToString:@"PDFView"]) {
        PDFView *view = [[[PDFView alloc] initWithFrame:NSMakeRect(0, 0, 120, 80)] autorelease];
        view.document = auto_object(@"PDFDocument *", index);
        view.displaysPageBreaks = YES; view.autoScales = YES;
        return view;
    }
    if ([base isEqualToString:@"PDFThumbnailView"]) {
        PDFThumbnailView *view = [[[PDFThumbnailView alloc] initWithFrame:NSMakeRect(0, 0, 120, 80)] autorelease];
        view.PDFView = auto_object(@"PDFView *", index);
        view.thumbnailSize = CGSizeMake(32, 24);
        return view;
    }
    if ([base isEqualToString:@"PDFDocument"])
        return [[[PDFDocument alloc] initWithData:auto_pdfkit_data()] autorelease];
    if ([base isEqualToString:@"PDFPage"])
        return [auto_object(@"PDFDocument *", index) pageAtIndex:0];
    if ([base isEqualToString:@"PDFSelection"])
        return [auto_object(@"PDFDocument *", index) findString:@"Finch" withOptions:0].firstObject;
    if ([base isEqualToString:@"PDFOutline"]) return [[[PDFOutline alloc] init] autorelease];
    if ([base isEqualToString:@"PDFDestination"])
        return [[[PDFDestination alloc] initWithPage:auto_object(@"PDFPage *", index) atPoint:CGPointMake(8, 40)] autorelease];
    if ([base isEqualToString:@"PDFBorder"]) return [[[PDFBorder alloc] init] autorelease];
    if ([base isEqualToString:@"PDFAnnotation"])
        return [[[PDFAnnotation alloc] initWithBounds:CGRectMake(8, 8, 24, 16)
            forType:PDFAnnotationSubtypeText withProperties:nil] autorelease];
    if ([base isEqualToString:@"PDFAppearanceCharacteristics"]) {
        Class appearanceClass = NSClassFromString(@"PDFAppearanceCharacteristics");
        return appearanceClass ? [[[appearanceClass alloc] init] autorelease] : nil;
    }
    if ([base isEqualToString:@"PDFActionURL"])
        return [[[PDFActionURL alloc] initWithURL:[NSURL URLWithString:@"https://example.invalid/"]] autorelease];
    if ([base isEqualToString:@"PDFActionGoTo"])
        return [[[PDFActionGoTo alloc] initWithDestination:auto_object(@"PDFDestination *", index)] autorelease];
    if ([base hasPrefix:@"PDFAnnotation"] && ![base isEqualToString:@"PDFAnnotation"]) {
        Class annotationClass = NSClassFromString(base);
        if (!annotationClass) return nil;
        id (*send)(id, SEL, CGRect, id, id) = (void *)objc_msgSend;
        return send([annotationClass alloc], NSSelectorFromString(@"initWithBounds:forType:withProperties:"),
            CGRectMake(8, 8, 24, 16), PDFAnnotationSubtypeText, nil);
    }
    if ([base isEqualToString:@"PDFActionNamed"]) {
        Class actionClass = NSClassFromString(base);
        if (!actionClass) return nil;
        id (*send)(id, SEL, id) = (void *)objc_msgSend;
        return send([actionClass alloc], NSSelectorFromString(@"initWithName:"), @"GoToPage");
    }
    if ([base isEqualToString:@"PDFActionResetForm"]) return auto_dynamic_init(base);
#endif
#ifdef FINCH_DIFFTEST_IMAGEKIT
    if ([base isEqualToString:@"IKImageView"]) {
        Class imageViewClass = NSClassFromString(base);
        if (!imageViewClass) return nil;
        id (*send)(id, SEL, NSRect) = (void *)objc_msgSend;
        id view = send([imageViewClass alloc], NSSelectorFromString(@"initWithFrame:"), NSMakeRect(0, 0, 64, 48));
        if (view) [view setValue:auto_object(@"NSImage *", index) forKey:@"image"];
        return view;
    }
    if ([base isEqualToString:@"IKImageBrowserView"]) {
        Class browserClass = NSClassFromString(base);
        if (!browserClass) return nil;
        id (*send)(id, SEL, NSRect) = (void *)objc_msgSend;
        return send([browserClass alloc], NSSelectorFromString(@"initWithFrame:"), NSMakeRect(0, 0, 64, 48));
    }
    if ([base isEqualToString:@"IKImageBrowserCell"]) return auto_dynamic_init(base);
    if ([base isEqualToString:@"IKSaveOptions"]) return [[[IKSaveOptions alloc] init] autorelease];
    if ([base isEqualToString:@"NSImage"]) {
        CFDataRef data = auto_png_data();
        NSImage *image = [[[NSImage alloc] initWithData:(NSData *)data] autorelease];
        CFRelease(data);
        return image;
    }
#endif
#ifdef FINCH_DIFFTEST_AVFOUNDATION
    if ([base isEqualToString:@"AVAsset"] || [base isEqualToString:@"AVURLAsset"])
        return auto_avfoundation_asset();
    if ([base isEqualToString:@"AVAssetTrack"])
        return [[auto_avfoundation_asset() tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if ([base isEqualToString:@"AVAssetTrackSegment"])
        return [[[auto_avfoundation_asset() tracksWithMediaType:AVMediaTypeVideo] firstObject].segments firstObject];
    if ([base isEqualToString:@"AVMutableComposition"] || [base isEqualToString:@"AVComposition"])
        return auto_dynamic_init(@"AVMutableComposition");
    if ([base isEqualToString:@"AVMutableCompositionTrack"] || [base isEqualToString:@"AVCompositionTrack"])
        return auto_avfoundation_composition_track();
    if ([base isEqualToString:@"AVMutableAudioMix"] || [base isEqualToString:@"AVAudioMix"])
        return auto_dynamic_class_method0(@"AVMutableAudioMix", @"audioMix");
    if ([base isEqualToString:@"AVVideoComposition"] || [base isEqualToString:@"AVMutableVideoComposition"]) {
        id composition = auto_dynamic_class_method0(@"AVMutableVideoComposition", @"videoComposition");
        if (composition) {
            [composition setValue:[NSValue valueWithSize:CGSizeMake(64, 48)] forKey:@"renderSize"];
            CMTime frameDuration = CMTimeMake(1, 6);
            [composition setValue:[NSValue valueWithBytes:&frameDuration objCType:@encode(CMTime)]
                forKey:@"frameDuration"];
        }
        return composition;
    }
    if ([base isEqualToString:@"AVVideoCompositionInstruction"] ||
        [base isEqualToString:@"AVMutableVideoCompositionInstruction"]) {
        id instruction = auto_dynamic_class_method0(@"AVMutableVideoCompositionInstruction", @"videoCompositionInstruction");
        if (instruction) {
            CMTimeRange range = CMTimeRangeMake(kCMTimeZero, CMTimeMake(1, 6));
            [instruction setValue:[NSValue valueWithBytes:&range objCType:@encode(CMTimeRange)] forKey:@"timeRange"];
            [instruction setValue:@[] forKey:@"layerInstructions"];
        }
        return instruction;
    }
    if ([base isEqualToString:@"AVVideoCompositionLayerInstruction"] ||
        [base isEqualToString:@"AVMutableVideoCompositionLayerInstruction"])
        return auto_dynamic_class_method1(@"AVMutableVideoCompositionLayerInstruction",
            @"videoCompositionLayerInstructionWithAssetTrack:", auto_object(@"AVAssetTrack *", index));
    if ([base isEqualToString:@"AVPlayerItem"])
        return auto_dynamic_class_method1(@"AVPlayerItem", @"playerItemWithAsset:", auto_avfoundation_asset());
    if ([base isEqualToString:@"AVPlayerItemTrack"])
        return [[auto_object(@"AVPlayerItem *", index) tracks] firstObject];
    if ([base isEqualToString:@"AVAssetExportSession"])
        return auto_dynamic_class_method2(@"AVAssetExportSession", @"exportSessionWithAsset:presetName:",
            auto_avfoundation_asset(), AVAssetExportPresetPassthrough);
    if ([base isEqualToString:@"AVAssetImageGenerator"])
        return auto_dynamic_class_method1(@"AVAssetImageGenerator", @"assetImageGeneratorWithAsset:",
            auto_avfoundation_asset());
    if ([base isEqualToString:@"AVMediaSelection"])
        return auto_avfoundation_asset().preferredMediaSelection;
    if ([base isEqualToString:@"AVMutableMediaSelection"])
        return [auto_avfoundation_asset().preferredMediaSelection mutableCopy];
    if ([base isEqualToString:@"AVMediaSelectionGroup"])
        return [auto_avfoundation_asset() mediaSelectionGroupForMediaCharacteristic:AVMediaCharacteristicVisual];
    if ([base isEqualToString:@"AVMediaSelectionOption"])
        return [[auto_object(@"AVMediaSelectionGroup *", index) options] firstObject];
    if ([base isEqualToString:@"AVTimedMetadataGroup"] || [base isEqualToString:@"AVMutableTimedMetadataGroup"]) {
        Class groupClass = NSClassFromString(base);
        if (!groupClass) return nil;
        id (*send)(id, SEL, id, CMTimeRange) = (void *)objc_msgSend;
        CMTimeRange range = CMTimeRangeMake(kCMTimeZero, CMTimeMake(1, 6));
        return send([groupClass alloc], NSSelectorFromString(@"initWithItems:timeRange:"),
            @[auto_object(@"AVMetadataItem *", index)], range);
    }
    if ([base isEqualToString:@"AVDateRangeMetadataGroup"] || [base isEqualToString:@"AVMutableDateRangeMetadataGroup"]) {
        Class groupClass = NSClassFromString(base);
        if (!groupClass) return nil;
        id (*send)(id, SEL, id, id, id) = (void *)objc_msgSend;
        NSDate *start = [NSDate dateWithTimeIntervalSinceReferenceDate:700000000];
        NSDate *end = [NSDate dateWithTimeIntervalSinceReferenceDate:700000006];
        return send([groupClass alloc], NSSelectorFromString(@"initWithItems:startDate:endDate:"),
            @[auto_object(@"AVMetadataItem *", index)], start, end);
    }
    if ([base isEqualToString:@"AVCaption"] || [base isEqualToString:@"AVMutableCaption"]) {
        Class captionClass = NSClassFromString(base);
        if (!captionClass) return nil;
        id (*send)(id, SEL, id, CMTimeRange) = (void *)objc_msgSend;
        CMTimeRange range = CMTimeRangeMake(kCMTimeZero, CMTimeMake(1, 6));
        return send([captionClass alloc], NSSelectorFromString(@"initWithText:timeRange:"), @"Finch caption", range);
    }
    if ([base isEqualToString:@"AVCaptionRegion"] || [base isEqualToString:@"AVMutableCaptionRegion"] ||
        [base isEqualToString:@"AVCaptionRuby"] || [base isEqualToString:@"AVTextStyleRule"] ||
        [base isEqualToString:@"AVAssetVariantQualifier"] || [base isEqualToString:@"AVAssetVariant"] ||
        [base isEqualToString:@"AVAssetVariantVideoAttributes"] || [base isEqualToString:@"AVAssetVariantAudioAttributes"] ||
        [base isEqualToString:@"AVMediaSelectionGroup"] || [base isEqualToString:@"AVMediaSelectionOption"] ||
        [base isEqualToString:@"AVMetadataItemFilter"] || [base isEqualToString:@"AVAssetTrackGroup"])
        return auto_dynamic_init(base);
    if ([base isEqualToString:@"AVMetadataItem"] || [base isEqualToString:@"AVMutableMetadataItem"]) {
        AVMutableMetadataItem *item = [[[AVMutableMetadataItem alloc] init] autorelease];
        item.identifier = AVMetadataCommonIdentifierTitle;
        item.value = @"Finch generated movie";
        item.dataType = kCMMetadataBaseDataType_UTF8;
        return item;
    }
#endif
#ifdef FINCH_DIFFTEST_OPENDIRECTORY
    if ([base isEqualToString:@"ODAttributeMap"])
        return auto_dynamic_class_method1(base, @"attributeMapWithStaticValue:", @"$native$");
    if ([base isEqualToString:@"ODConfiguration"] || [base isEqualToString:@"ODMappings"] ||
        [base isEqualToString:@"ODRecordMap"])
        return auto_dynamic_class_method0(base, [base isEqualToString:@"ODConfiguration"] ? @"configuration" :
            ([base isEqualToString:@"ODMappings"] ? @"mappings" : @"recordMap"));
    if ([base isEqualToString:@"ODModuleEntry"])
        return auto_dynamic_class_method2(base, @"moduleEntryWithName:xpcServiceName:", @"FinchDifftest", @"org.finch.difftest");
#endif
#ifdef FINCH_DIFFTEST_STOREKIT
    if ([base isEqualToString:@"SKPayment"] || [base isEqualToString:@"SKMutablePayment"]) {
        SKMutablePayment *payment = [[[SKMutablePayment alloc] init] autorelease];
        payment.productIdentifier = @"org.finch.difftest.local";
        payment.quantity = 2;
        payment.applicationUsername = @"fixed-user-value";
        payment.requestData = [NSData dataWithBytes:"fixed" length:5];
        return payment;
    }
    if ([base isEqualToString:@"SKPaymentDiscount"])
        return [[[SKPaymentDiscount alloc] initWithIdentifier:@"fixed-offer" keyIdentifier:@"fixed-key"
            nonce:[[NSUUID alloc] initWithUUIDString:@"68753a44-4d6f-1226-9c60-0050e4c00067"]
            signature:@"fixed-signature" timestamp:@1] autorelease];
#endif
#ifdef FINCH_DIFFTEST_LINKPRESENTATION
    if ([base isEqualToString:@"LPLinkMetadata"]) {
        LPLinkMetadata *metadata = [[[LPLinkMetadata alloc] init] autorelease];
        metadata.originalURL = [NSURL URLWithString:@"https://example.invalid/original"];
        metadata.URL = [NSURL URLWithString:@"https://example.invalid/final"];
        metadata.title = @"Finch fixed link";
        return metadata;
    }
#endif
#ifdef FINCH_DIFFTEST_QUARTZCORE
    if ([base isEqualToString:@"CALayerContentsFilter"])
        return @[kCAFilterNearest, kCAFilterLinear, kCAFilterTrilinear][index % 3];
    if ([base isEqualToString:@"CALayerContentsGravity"])
        return @[kCAGravityCenter, kCAGravityTop, kCAGravityBottom, kCAGravityLeft, kCAGravityRight][index % 5];
    if ([base isEqualToString:@"CALayerCornerCurve"])
        return @[kCACornerCurveCircular, kCACornerCurveContinuous][index % 2];
    if ([base isEqualToString:@"CAMediaTimingFunctionName"])
        return @[kCAMediaTimingFunctionLinear, kCAMediaTimingFunctionEaseIn,
            kCAMediaTimingFunctionEaseOut, kCAMediaTimingFunctionEaseInEaseOut][index % 4];
    if ([base isEqualToString:@"CAEmitterLayerEmitterMode"])
        return @[kCAEmitterLayerPoints, kCAEmitterLayerOutline, kCAEmitterLayerSurface, kCAEmitterLayerVolume][index % 4];
    if ([base isEqualToString:@"CAEmitterLayerEmitterShape"])
        return @[kCAEmitterLayerPoint, kCAEmitterLayerLine, kCAEmitterLayerRectangle,
            kCAEmitterLayerCircle, kCAEmitterLayerSphere][index % 5];
    if ([base isEqualToString:@"CAShapeLayerFillRule"])
        return @[kCAFillRuleNonZero, kCAFillRuleEvenOdd][index % 2];
    if ([base isEqualToString:@"CAShapeLayerLineCap"])
        return @[kCALineCapButt, kCALineCapRound, kCALineCapSquare][index % 3];
    if ([base isEqualToString:@"CAShapeLayerLineJoin"])
        return @[kCALineJoinMiter, kCALineJoinRound, kCALineJoinBevel][index % 3];
    if ([base isEqualToString:@"CATransitionType"])
        return @[kCATransitionFade, kCATransitionMoveIn][index % 2];
    if ([base isEqualToString:@"CATransitionSubtype"])
        return @[kCATransitionFromRight, kCATransitionFromLeft,
            kCATransitionFromTop, kCATransitionFromBottom][index % 4];
    if ([base isEqualToString:@"CAValueFunctionName"])
        return @[kCAValueFunctionRotateX, kCAValueFunctionRotateY, kCAValueFunctionRotateZ,
            kCAValueFunctionScale, kCAValueFunctionTranslate][index % 5];
#endif
#ifdef FINCH_DIFFTEST_QUARTZCORE
    if ([base isEqualToString:@"CALayer"]) return [CALayer layer];
    if ([base isEqualToString:@"CAAnimation"]) return [CAAnimation animation];
    if ([base isEqualToString:@"CAPropertyAnimation"]) return [CAPropertyAnimation animationWithKeyPath:@"opacity"];
    if ([base isEqualToString:@"CABasicAnimation"]) return [CABasicAnimation animationWithKeyPath:@"opacity"];
    if ([base isEqualToString:@"CAKeyframeAnimation"]) return [CAKeyframeAnimation animationWithKeyPath:@"position"];
    if ([base isEqualToString:@"CASpringAnimation"]) return [CASpringAnimation animationWithKeyPath:@"position"];
    if ([base isEqualToString:@"CAEmitterCell"]) return [CAEmitterCell emitterCell];
    if ([base isEqualToString:@"CAMediaTimingFunction"])
        return [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    if ([base isEqualToString:@"CAValueFunction"]) return [CAValueFunction functionWithName:kCAValueFunctionRotateZ];
#endif
#ifdef FINCH_DIFFTEST_COREIMAGE
    if ([base isEqualToString:@"CIColor"]) {
        static const CGFloat components[][4] = {{0, 0, 0, 1}, {0.25, 0.5, 0.75, 1}, {1, 0.5, 0.1, 0.5}};
        const CGFloat *c = components[index % 3];
        return [CIColor colorWithRed:c[0] green:c[1] blue:c[2] alpha:c[3]];
    }
    if ([base isEqualToString:@"CIImage"]) return [CIImage imageWithColor:auto_object(@"CIColor *", index)];
    if ([base isEqualToString:@"CIContext"])
        return [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer:@YES}];
    if ([base isEqualToString:@"CIFilter"]) {
        CIFilter *filter = [CIFilter filterWithName:@"CIColorControls"];
        [filter setDefaults];
        [filter setValue:auto_object(@"CIImage *", index) forKey:kCIInputImageKey];
        return filter;
    }
    if ([base isEqualToString:@"CIFilterShape"]) return [CIFilterShape shapeWithRect:CGRectMake(0, 0, 8, 8)];
    if ([base isEqualToString:@"CIImageAccumulator"])
        return [CIImageAccumulator imageAccumulatorWithExtent:CGRectMake(0, 0, 8, 8) format:kCIFormatRGBA8];
    if ([base isEqualToString:@"CIVector"]) return [CIVector vectorWithX:1.25 Y:-2.5 Z:3.75 W:1];
    if ([base isEqualToString:@"CIKernel"])
        return [CIKernel kernelWithString:@"kernel vec4 finchDifftestKernel (sampler image) { return sample(image, samplerCoord(image)); }"];
    if ([base isEqualToString:@"CIColorKernel"])
        return [CIColorKernel kernelWithString:@"kernel vec4 finchDifftestColorKernel (vec4 color) { return color; }"];
    if ([base isEqualToString:@"CIWarpKernel"])
        return [CIWarpKernel kernelWithString:@"kernel vec2 finchDifftestWarpKernel (vec2 point) { return point; }"];
    if ([base isEqualToString:@"CIBlendKernel"]) return CIBlendKernel.sourceOver;
    NSData *barcodePayload = [NSData dataWithBytes:"finch" length:5];
    if ([base isEqualToString:@"CIQRCodeDescriptor"])
        return [CIQRCodeDescriptor descriptorWithPayload:barcodePayload symbolVersion:1 maskPattern:0
            errorCorrectionLevel:CIQRCodeErrorCorrectionLevelL];
    if ([base isEqualToString:@"CIAztecCodeDescriptor"])
        return [CIAztecCodeDescriptor descriptorWithPayload:barcodePayload isCompact:YES layerCount:1 dataCodewordCount:1];
    if ([base isEqualToString:@"CIPDF417CodeDescriptor"])
        return [CIPDF417CodeDescriptor descriptorWithPayload:barcodePayload isCompact:YES rowCount:3 columnCount:3];
    if ([base isEqualToString:@"CIDataMatrixCodeDescriptor"])
        return [CIDataMatrixCodeDescriptor descriptorWithPayload:barcodePayload rowCount:10 columnCount:10
            eccVersion:CIDataMatrixCodeECCVersion200];
#endif
#ifdef FINCH_DIFFTEST_UTI
    if ([base isEqualToString:@"UTType"])
        return [UTType typeWithIdentifier:@[@"public.plain-text", @"public.jpeg", @"com.adobe.pdf"][index % 3]];
#endif
#ifdef FINCH_DIFFTEST_CONTACTS
    if ([base isEqualToString:@"CNContact"] || [base isEqualToString:@"CNMutableContact"]) {
        CNMutableContact *contact = [[[CNMutableContact alloc] init] autorelease];
        contact.givenName = @[@"Ada", @"Sam", @"Zoë"][index % 3];
        contact.familyName = @[@"Lovelace", @"Finch", @"Ng"][index % 3];
        contact.organizationName = @"Finch Difftest";
        return contact;
    }
    if ([base isEqualToString:@"CNPhoneNumber"])
        return [CNPhoneNumber phoneNumberWithStringValue:@[@"+1 416 555 0100", @"+44 20 5555 0100"][index % 2]];
    if ([base isEqualToString:@"CNPostalAddress"] || [base isEqualToString:@"CNMutablePostalAddress"]) {
        CNMutablePostalAddress *address = [[[CNMutablePostalAddress alloc] init] autorelease];
        address.street = @"1 Test Street"; address.city = @"Toronto"; address.state = @"ON";
        address.postalCode = @"M5V 2T6"; address.country = @"Canada"; address.ISOCountryCode = @"CA";
        return address;
    }
    if ([base isEqualToString:@"CNContactFormatter"]) {
        CNContactFormatter *formatter = [[[CNContactFormatter alloc] init] autorelease];
        formatter.style = CNContactFormatterStyleFullName;
        return formatter;
    }
    if ([base isEqualToString:@"CNPostalAddressFormatter"]) return [[[CNPostalAddressFormatter alloc] init] autorelease];
    if ([base isEqualToString:@"CNSocialProfile"])
        return [[[CNSocialProfile alloc] initWithUrlString:@"https://example.invalid/profile"
            username:@"finch" userIdentifier:@"fixed-id" service:@"example"] autorelease];
#endif
#ifdef FINCH_DIFFTEST_COREDATA
    if ([base isEqualToString:@"NSFetchRequest"])
        return [[[NSFetchRequest alloc] initWithEntityName:@"FinchDifftestEntity"] autorelease];
    if ([base isEqualToString:@"NSEntityDescription"]) {
        NSEntityDescription *entity = [[[NSEntityDescription alloc] init] autorelease];
        entity.name = @"FinchDifftestEntity"; entity.managedObjectClassName = @"NSManagedObject";
        return entity;
    }
    if ([base isEqualToString:@"NSAttributeDescription"]) {
        NSAttributeDescription *attribute = [[[NSAttributeDescription alloc] init] autorelease];
        attribute.name = @"title"; attribute.attributeType = NSStringAttributeType; attribute.optional = YES;
        return attribute;
    }
    if ([base isEqualToString:@"NSRelationshipDescription"]) {
        NSRelationshipDescription *relationship = [[[NSRelationshipDescription alloc] init] autorelease];
        relationship.name = @"related"; relationship.minCount = 0; relationship.maxCount = 1; relationship.optional = YES;
        return relationship;
    }
    if ([base isEqualToString:@"NSManagedObjectModel"]) {
        NSEntityDescription *entity = auto_object(@"NSEntityDescription *", index);
        entity.properties = @[auto_object(@"NSAttributeDescription *", index)];
        return [[[NSManagedObjectModel alloc] initWithEntities:@[entity]] autorelease];
    }
    if ([base isEqualToString:@"NSFetchIndexElementDescription"])
        return [[[NSFetchIndexElementDescription alloc] initWithProperty:auto_object(@"NSAttributeDescription *", index)
            collationType:NSFetchIndexElementTypeBinary] autorelease];
    if ([base isEqualToString:@"NSFetchIndexDescription"])
        return [[[NSFetchIndexDescription alloc] initWithName:@"FinchIndex"
            elements:@[auto_object(@"NSFetchIndexElementDescription *", index)]] autorelease];
    if ([base isEqualToString:@"NSPersistentStoreDescription"])
        return [[[NSPersistentStoreDescription alloc] initWithURL:[NSURL fileURLWithPath:@"/tmp/finch-difftest.sqlite"]] autorelease];
    if ([base isEqualToString:@"NSBatchUpdateRequest"])
        return [[[NSBatchUpdateRequest alloc] initWithEntityName:@"FinchDifftestEntity"] autorelease];
    if ([base isEqualToString:@"NSBatchDeleteRequest"])
        return [[[NSBatchDeleteRequest alloc] initWithFetchRequest:auto_object(@"NSFetchRequest *", index)] autorelease];
    if ([base isEqualToString:@"NSMergePolicy"])
        return [NSMergePolicy mergeByPropertyObjectTrumpMergePolicy];
#endif
#ifdef FINCH_DIFFTEST_CORELOCATION
    if ([base isEqualToString:@"CLLocation"])
        return [[[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake(43.6532, -79.3832)
            altitude:76 horizontalAccuracy:5 verticalAccuracy:8 course:90 speed:1.5
            timestamp:[NSDate dateWithTimeIntervalSinceReferenceDate:700000000]] autorelease];
    if ([base isEqualToString:@"CLCircularRegion"])
        return [[[CLCircularRegion alloc] initWithCenter:CLLocationCoordinate2DMake(43.6532, -79.3832)
            radius:250 identifier:@"FinchDifftest"] autorelease];
#endif
#ifdef FINCH_DIFFTEST_METAL
    if ([base isEqualToString:@"MTLTextureDescriptor"])
        return [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
            width:8 height:4 mipmapped:NO];
    if ([base isEqualToString:@"MTLRenderPassDescriptor"]) return [MTLRenderPassDescriptor renderPassDescriptor];
    if ([base isEqualToString:@"MTLVertexDescriptor"]) return [MTLVertexDescriptor vertexDescriptor];
    if ([base isEqualToString:@"MTLArgumentDescriptor"]) return [MTLArgumentDescriptor argumentDescriptor];
    if ([base hasSuffix:@"Descriptor"]) {
        Class descriptorClass = NSClassFromString(base);
        if ([descriptorClass respondsToSelector:@selector(descriptor)])
            return ((id (*)(id, SEL))objc_msgSend)(descriptorClass, @selector(descriptor));
        if (descriptorClass) return [[[descriptorClass alloc] init] autorelease];
    }
    if ([base isEqualToString:@"MTLFunctionConstantValues"])
        return [[[MTLFunctionConstantValues alloc] init] autorelease];
#endif
#ifdef FINCH_DIFFTEST_CORESPOTLIGHT
    if ([base isEqualToString:@"CSSearchableItemAttributeSet"]) {
        CSSearchableItemAttributeSet *attributes = [[[CSSearchableItemAttributeSet alloc]
            initWithItemContentType:@"public.item"] autorelease];
        attributes.title = @"Finch"; attributes.displayName = @"Finch";
        attributes.contentDescription = @"A fixed Spotlight value";
        attributes.keywords = @[@"finch", @"test"];
        attributes.contentURL = [NSURL URLWithString:@"https://example.invalid/item"];
        return attributes;
    }
    if ([base isEqualToString:@"CSSearchableItem"] || [base isEqualToString:@"CSLocalizedString"] ||
        [base isEqualToString:@"CSPerson"] || [base isEqualToString:@"CSCustomAttributeKey"]) {
        if ([base isEqualToString:@"CSSearchableItem"]) {
            CSSearchableItem *item = [[[CSSearchableItem alloc] initWithUniqueIdentifier:@"finch-difftest-item"
                domainIdentifier:@"org.finch.difftest"
                attributeSet:auto_object(@"CSSearchableItemAttributeSet *", index)] autorelease];
            item.expirationDate = [NSDate dateWithTimeIntervalSinceReferenceDate:800000000];
            return item;
        }
        if ([base isEqualToString:@"CSLocalizedString"])
            return [[[CSLocalizedString alloc] initWithLocalizedStrings:@{@"en":@"Finch", @"fr":@"Finch"}] autorelease];
        if ([base isEqualToString:@"CSPerson"])
            return [[[CSPerson alloc] initWithDisplayName:@"Finch Tester" handles:@[@"+1 416 555 0100"]
                handleIdentifier:@"phone"] autorelease];
        return [[[CSCustomAttributeKey alloc] initWithKeyName:@"org_finch_difftest_value"
            searchable:YES searchableByDefault:NO unique:NO multiValued:NO] autorelease];
    }
#endif
#ifdef FINCH_DIFFTEST_AVFAUDIO
    if ([base isEqualToString:@"AVAudioFormat"])
        return [[[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100 channels:2] autorelease];
    if ([base isEqualToString:@"AVAudioChannelLayout"])
        return [[[AVAudioChannelLayout alloc] initWithLayoutTag:kAudioChannelLayoutTag_Stereo] autorelease];
    if ([base isEqualToString:@"AVAudioTime"])
        return [[[AVAudioTime alloc] initWithSampleTime:128 atRate:44100] autorelease];
    if ([base isEqualToString:@"AVAudioPCMBuffer"]) {
        AVAudioPCMBuffer *buffer = [[[AVAudioPCMBuffer alloc]
            initWithPCMFormat:auto_object(@"AVAudioFormat *", index) frameCapacity:128] autorelease];
        buffer.frameLength = 32;
        if (buffer.floatChannelData) {
            for (AVAudioFrameCount frame = 0; frame < buffer.frameLength; frame++) {
                for (AVAudioChannelCount channel = 0; channel < buffer.format.channelCount; channel++)
                    buffer.floatChannelData[channel][frame] = (float)((frame + channel) % 7) / 8.0f;
            }
        }
        return buffer;
    }
    if ([base isEqualToString:@"AVAudioCompressedBuffer"]) {
        AudioStreamBasicDescription description = {0};
        description.mSampleRate = 44100;
        description.mFormatID = kAudioFormatMPEG4AAC;
        description.mChannelsPerFrame = 2;
        description.mFramesPerPacket = 1024;
        AVAudioFormat *format = [[[AVAudioFormat alloc] initWithStreamDescription:&description] autorelease];
        return [[[AVAudioCompressedBuffer alloc] initWithFormat:format packetCapacity:4 maximumPacketSize:4096] autorelease];
    }
    if ([base isEqualToString:@"AVAudioConverter"]) {
        AVAudioFormat *format = auto_object(@"AVAudioFormat *", index);
        return [[[AVAudioConverter alloc] initFromFormat:format toFormat:format] autorelease];
    }
#endif
#ifdef FINCH_DIFFTEST_APPKIT
    if ([base isEqualToString:@"NSColor"]) return auto_color(index);
    if ([base isEqualToString:@"NSColorSpace"]) return @[[NSColorSpace sRGBColorSpace],
        [NSColorSpace genericRGBColorSpace], [NSColorSpace extendedSRGBColorSpace]][index % 3];
    if ([base isEqualToString:@"NSColorList"]) {
        NSColorList *list = [[[NSColorList alloc] initWithName:@"FinchDifftest"] autorelease];
        [list setColor:auto_color(1) forKey:@"accent"];
        [list setColor:auto_color(4) forKey:@"gray"];
        return list;
    }
    if ([base isEqualToString:@"NSCell"]) return [[[NSCell alloc] initTextCell:@"Finch"] autorelease];
    if ([base isEqualToString:@"NSMenuItem"])
        return [[[NSMenuItem alloc] initWithTitle:@"Finch" action:NULL keyEquivalent:@"f"] autorelease];
    if ([base isEqualToString:@"NSMenu"]) return [[[NSMenu alloc] initWithTitle:@"Finch"] autorelease];
    if ([base isEqualToString:@"NSTableColumn"]) return [[[NSTableColumn alloc] initWithIdentifier:@"Finch"] autorelease];
    if ([base isEqualToString:@"NSFont"]) {
        static const CGFloat sizes[] = {12, 13, 18, 24};
        return [NSFont systemFontOfSize:sizes[index % 4]];
    }
    if ([base isEqualToString:@"NSFontDescriptor"]) return [[NSFont systemFontOfSize:12] fontDescriptor];
    if ([base isEqualToString:@"NSFontManager"]) return [NSFontManager sharedFontManager];
    if ([base isEqualToString:@"NSBezierPath"]) return [NSBezierPath bezierPathWithRect:NSMakeRect(1, 2, 8, 6)];
    if ([base isEqualToString:@"NSAffineTransform"]) return [[[NSAffineTransform alloc] init] autorelease];
    if ([base isEqualToString:@"NSImage"]) return auto_image();
    if ([base isEqualToString:@"NSImageRep"] || [base isEqualToString:@"NSBitmapImageRep"]) return auto_bitmap();
    if ([base isEqualToString:@"NSParagraphStyle"]) return [NSParagraphStyle defaultParagraphStyle];
    if ([base isEqualToString:@"NSMutableParagraphStyle"]) return [[NSParagraphStyle defaultParagraphStyle] mutableCopy];
    if ([base isEqualToString:@"NSTextTab"]) return [[[NSTextTab alloc] initWithType:NSLeftTabStopType location:36] autorelease];
    if ([base isEqualToString:@"NSShadow"]) return [[[NSShadow alloc] init] autorelease];
    if ([base isEqualToString:@"NSGradient"]) return [[[NSGradient alloc] initWithStartingColor:auto_color(index)
        endingColor:auto_color(index + 1)] autorelease];
    if ([base isEqualToString:@"NSCursor"]) return [NSCursor arrowCursor];
    if ([base isEqualToString:@"NSAppearance"]) return [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    if ([base isEqualToString:@"NSEvent"]) return auto_event();
    if ([base isEqualToString:@"NSTextStorage"]) return auto_text_storage();
    if ([base isEqualToString:@"NSLayoutManager"]) return auto_text_layout_manager();
    if ([base isEqualToString:@"NSTextContainer"]) return auto_text_container();
    if ([base isEqualToString:@"NSTextView"]) return auto_text_view();
    if ([base isEqualToString:@"NSScrollView"])
        return [[[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 160, 96)] autorelease];
    if ([base isEqualToString:@"NSGridView"]) return auto_grid_view();
    if ([base isEqualToString:@"NSGridRow"]) return [auto_grid_view() rowAtIndex:0];
    if ([base isEqualToString:@"NSGridColumn"]) return [auto_grid_view() columnAtIndex:0];
    if ([base isEqualToString:@"NSGridCell"]) return [auto_grid_view() cellAtColumnIndex:0 rowIndex:0];
    if ([base isEqualToString:@"NSRulerView"]) return auto_ruler_view();
    if ([base isEqualToString:@"NSRulerMarker"])
        return [[[NSRulerMarker alloc] initWithRulerView:auto_ruler_view() markerLocation:42
            image:auto_image() imageOrigin:NSMakePoint(1, 2)] autorelease];
    if ([base isEqualToString:@"NSView"]) return auto_layout_view();
    if ([base isEqualToString:@"NSLayoutConstraint"]) return auto_constraint();
    if ([base isEqualToString:@"NSLayoutAnchor"] || [base isEqualToString:@"NSLayoutXAxisAnchor"])
        return auto_layout_view().leadingAnchor;
    if ([base isEqualToString:@"NSLayoutYAxisAnchor"]) return auto_layout_view().topAnchor;
    if ([base isEqualToString:@"NSLayoutDimension"]) return auto_layout_view().widthAnchor;
    if ([base isEqualToString:@"NSLayoutGuide"]) return [[[NSLayoutGuide alloc] init] autorelease];
    if ([base isEqualToString:@"NSPasteboard"]) return auto_private_pasteboard(nil);
    if ([base isEqualToString:@"NSPrintInfo"]) return [[[NSPrintInfo alloc] init] autorelease];
    if ([base isEqualToString:@"NSValue"]) return [NSValue valueWithPoint:NSMakePoint(3, -2)];
    if ([base isEqualToString:@"NSAttributedString"]) return [[[NSAttributedString alloc] initWithString:@"café🙂" attributes:@{
        NSFontAttributeName:[NSFont systemFontOfSize:12]}] autorelease];
    if ([base isEqualToString:@"NSMutableAttributedString"]) return [[[NSMutableAttributedString alloc] initWithString:@"café🙂" attributes:@{
        NSFontAttributeName:[NSFont systemFontOfSize:12]}] autorelease];
#endif
    if ([base isEqualToString:@"ObjectType"] || [base isEqualToString:@"KeyType"] ||
        [base isEqualToString:@"ValueType"]) return auto_object(@"id", index);
    if ([base isEqualToString:@"NSLinguisticTagScheme"])
        return @[NSLinguisticTagSchemeTokenType, NSLinguisticTagSchemeLexicalClass,
            NSLinguisticTagSchemeNameType, NSLinguisticTagSchemeLemma,
            NSLinguisticTagSchemeLanguage, NSLinguisticTagSchemeScript][index % 6];
    if ([base isEqualToString:@"NSStringTransform"])
        return @[NSStringTransformToLatin, NSStringTransformStripCombiningMarks,
            NSStringTransformLatinToKatakana, NSStringTransformHiraganaToKatakana][index % 4];
    if ([base isEqualToString:@"id"] || [base isEqualToString:@"NSObject"]) {
        NSArray *any = @[@"", @"Finch", @1, @-1, @[@"a", @2], @{ @"key": @"value" }, auto_data("\0\1\xff", 3), [NSDate dateWithTimeIntervalSinceReferenceDate:700000000]];
        return any[index % any.count];
    }
    if ([base isEqualToString:@"NSString"] || [base isEqualToString:@"NSMutableString"]) {
        NSString *value = @[@"", @"Finch", @"cafe\u0301 👩🏽‍💻 עברית", @"العربية", [@"x" stringByPaddingToLength:65536 withString:@"x" startingAtIndex:0]][index % 5];
        return [base isEqualToString:@"NSMutableString"] ? [value mutableCopy] : value;
    }
    if ([base isEqualToString:@"NSNumber"]) return @[@0, @1, @-1, @(LLONG_MAX), @(LLONG_MIN), @0.5, @(NAN), @(INFINITY)][index % 8];
    if ([base isEqualToString:@"NSDecimalNumber"]) return @[[NSDecimalNumber zero], [NSDecimalNumber one], [NSDecimalNumber decimalNumberWithString:@"-1.25" locale:@{NSLocaleIdentifier:@"en_US_POSIX"}], [NSDecimalNumber decimalNumberWithString:@"999999.125" locale:@{NSLocaleIdentifier:@"en_US_POSIX"}]][index % 4];
    if ([base isEqualToString:@"NSDate"]) return @[[NSDate dateWithTimeIntervalSinceReferenceDate:0], [NSDate dateWithTimeIntervalSinceReferenceDate:-1], [NSDate dateWithTimeIntervalSinceReferenceDate:700000000], [NSDate dateWithTimeIntervalSinceReferenceDate:800000000]][index % 4];
    if ([base isEqualToString:@"NSCalendarDate"]) return [NSCalendarDate dateWithTimeIntervalSinceReferenceDate:700000000];
    if ([base isEqualToString:@"NSData"] || [base isEqualToString:@"NSMutableData"]) {
        const char *utf8 = "café🙂";
        NSData *value = @[auto_data(NULL, 0), auto_data("\0\1\x7f\x80\xfe\xff", 6), auto_data(utf8, strlen(utf8))][index % 3];
        return [base isEqualToString:@"NSMutableData"] ? [value mutableCopy] : value;
    }
    if ([base isEqualToString:@"NSArray"] || [base isEqualToString:@"NSMutableArray"] || [base isEqualToString:@"NSOrderedSet"] || [base isEqualToString:@"NSMutableOrderedSet"]) {
        NSArray *values;
        if (genericArguments.count) {
            id first = auto_generic_object(genericArguments[0], index);
            id second = auto_generic_object(genericArguments[0], index + 1);
            if (!first || !second) return nil;
            values = @[ @[], @[first], @[first, second] ][index % 3];
        } else values = @[@[], @[@"a", @1], @[@"cafe\u0301", @"🙂", @-1]][index % 3];
        if ([base isEqualToString:@"NSOrderedSet"]) return [NSOrderedSet orderedSetWithArray:values];
        if ([base isEqualToString:@"NSMutableOrderedSet"]) return [NSMutableOrderedSet orderedSetWithArray:values];
        return [base isEqualToString:@"NSMutableArray"] ? [values mutableCopy] : values;
    }
    if ([base isEqualToString:@"NSDictionary"] || [base isEqualToString:@"NSMutableDictionary"]) {
        NSDictionary *value;
        if (genericArguments.count > 1) {
            id firstKey = auto_generic_object(genericArguments[0], index);
            id secondKey = auto_generic_object(genericArguments[0], index + 1);
            id firstValue = auto_generic_object(genericArguments[1], index);
            id secondValue = auto_generic_object(genericArguments[1], index + 1);
            if (!firstKey || !secondKey || !firstValue || !secondValue) return nil;
            value = @[ @{}, @{firstKey:firstValue}, @{firstKey:firstValue, secondKey:secondValue} ][index % 3];
        } else value = @[@{}, @{ @"a": @1, @"é": @"e\u0301" }, @{ @"z": @2, @"a": @1 }][index % 3];
        return [base isEqualToString:@"NSMutableDictionary"] ? [value mutableCopy] : value;
    }
    if ([base isEqualToString:@"NSSet"] || [base isEqualToString:@"NSMutableSet"] || [base isEqualToString:@"NSCountedSet"]) {
        NSSet *value;
        if (genericArguments.count) {
            id first = auto_generic_object(genericArguments[0], index);
            id second = auto_generic_object(genericArguments[0], index + 1);
            if (!first || !second) return nil;
            value = @[[NSSet set], [NSSet setWithObject:first], [NSSet setWithObjects:first, second, nil]][index % 3];
        } else value = @[[NSSet set], [NSSet setWithArray:@[@"a", @"a", @1]], [NSSet setWithArray:@[@"🙂", @"é", @-1]]][index % 3];
        if ([base isEqualToString:@"NSMutableSet"]) return [value mutableCopy];
        if ([base isEqualToString:@"NSCountedSet"]) return [NSCountedSet setWithArray:value.allObjects];
        return value;
    }
    if ([base isEqualToString:@"NSURL"]) return @[[NSURL URLWithString:@"https://example.invalid/a%20b?q=1#part"], [NSURL URLWithString:@"mailto:finch@example.invalid"], [NSURL URLWithString:@"relative/path"]][index % 3];
    if ([base isEqualToString:@"NSURLComponents"]) return @[[NSURLComponents componentsWithString:@"https://example.invalid/a%20b?q=1#part"], [NSURLComponents componentsWithString:@"mailto:finch@example.invalid"], [NSURLComponents componentsWithString:@"relative/path"]][index % 3];
    if ([base isEqualToString:@"NSLocale"]) return @[[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"], [[NSLocale alloc] initWithLocaleIdentifier:@"fr_CA"], [[NSLocale alloc] initWithLocaleIdentifier:@"ar_EG"]][index % 3];
    if ([base isEqualToString:@"NSTimeZone"]) return @[[NSTimeZone timeZoneWithName:@"UTC"], [NSTimeZone timeZoneWithName:@"America/Toronto"], [NSTimeZone timeZoneWithName:@"Asia/Kathmandu"]][index % 3];
    if ([base isEqualToString:@"NSCalendar"]) {
        NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:index & 1 ? NSCalendarIdentifierISO8601 : NSCalendarIdentifierGregorian];
        calendar.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        calendar.timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
        return calendar;
    }
    if ([base isEqualToString:@"NSDateComponents"]) {
        NSDateComponents *components = [[[NSDateComponents alloc] init] autorelease];
        components.year = 2001; components.month = 1; components.day = 2;
        components.hour = 3; components.minute = 4; components.second = 5;
        components.timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
        return components;
    }
    if ([base isEqualToString:@"NSCharacterSet"]) return @[[NSCharacterSet characterSetWithCharactersInString:@"aé中🙂"], [NSCharacterSet alphanumericCharacterSet], [NSCharacterSet whitespaceAndNewlineCharacterSet]][index % 3];
    if ([base isEqualToString:@"NSAttributedString"]) return [[NSAttributedString alloc] initWithString:@"cafe\u0301 🙂" attributes:@{@"FinchTest":@"value"}];
    if ([base isEqualToString:@"NSMutableAttributedString"]) return [[NSMutableAttributedString alloc] initWithString:@"cafe\u0301 🙂" attributes:@{@"FinchTest":@"value"}];
    if ([base isEqualToString:@"NSError"]) return [NSError errorWithDomain:@"org.finch.difftest" code:(NSInteger)index userInfo:nil];
    if ([base isEqualToString:@"NSUUID"]) return [[NSUUID alloc] initWithUUIDString:@"68753a44-4d6f-1226-9c60-0050e4c00067"];
    if ([base isEqualToString:@"NSNull"]) return NSNull.null;
    if ([base isEqualToString:@"NSIndexSet"] || [base isEqualToString:@"NSMutableIndexSet"]) {
        NSMutableIndexSet *indexes = [NSMutableIndexSet indexSet];
        [indexes addIndex:1]; [indexes addIndex:3]; [indexes addIndex:5];
        return [base isEqualToString:@"NSMutableIndexSet"] ? indexes : [indexes copy];
    }
    if ([base isEqualToString:@"NSRange"]) return [NSValue valueWithRange:NSMakeRange(0, 0)];
    if ([base isEqualToString:@"NSValue"]) return [NSValue valueWithRange:NSMakeRange(0, 1)];
    if ([base isEqualToString:@"NSPredicate"]) return [NSPredicate predicateWithValue:YES];
    if ([base isEqualToString:@"NSExpression"]) return [NSExpression expressionForConstantValue:@1];
    if ([base isEqualToString:@"NSInvocation"]) {
        NSMethodSignature *signature = [NSObject instanceMethodSignatureForSelector:@selector(description)];
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        invocation.target = @"Finch"; invocation.selector = @selector(description); return invocation;
    }
    if ([base isEqualToString:@"NSSortDescriptor"]) return [NSSortDescriptor sortDescriptorWithKey:nil ascending:YES];
    if ([base isEqualToString:@"NSRegularExpression"]) return [NSRegularExpression regularExpressionWithPattern:@"a+" options:0 error:NULL];
    if ([base isEqualToString:@"NSException"]) return [NSException exceptionWithName:@"FinchTest" reason:@"fixed" userInfo:nil];
    if ([base isEqualToString:@"NSNotification"]) return [NSNotification notificationWithName:@"FinchTest" object:nil];
    if ([base isEqualToString:@"NSNotificationCenter"]) return [NSNotificationCenter defaultCenter];
    if ([base isEqualToString:@"NSMapTable"]) return [[NSMapTable alloc] initWithKeyOptions:NSPointerFunctionsStrongMemory valueOptions:NSPointerFunctionsStrongMemory capacity:0];
    if ([base isEqualToString:@"NSHashTable"]) return [[NSHashTable alloc] initWithOptions:NSPointerFunctionsStrongMemory capacity:0];
    if ([base isEqualToString:@"NSCache"]) return [[NSCache alloc] init];
    if ([base isEqualToString:@"NSXMLDocument"]) return [[NSXMLDocument alloc] initWithXMLString:@"<root><item>value</item></root>" options:0 error:NULL];
    if ([base isEqualToString:@"NSXMLElement"]) return [NSXMLElement elementWithName:@"root"];
    if ([base isEqualToString:@"NSXMLNode"]) return [NSXMLNode elementWithName:@"node"];
    if ([base isEqualToString:@"NSNotificationName"] || [base hasSuffix:@"Key"] || [base hasSuffix:@"Name"])
        return @[@"", @"FinchTest", @"cafe\u0301"][index % 3];
    if ([base hasPrefix:@"AV"] &&
        ([base hasSuffix:@"Key"] || [base hasSuffix:@"Name"] || [base hasSuffix:@"Identifier"] ||
         [base hasSuffix:@"Type"] || [base hasSuffix:@"Format"] || [base hasSuffix:@"Mode"] ||
         [base hasSuffix:@"Option"])) {
#ifdef FINCH_DIFFTEST_AVFOUNDATION
        if ([base isEqualToString:@"AVMediaType"])
            return @[AVMediaTypeVideo, AVMediaTypeAudio][index % 2];
        if ([base isEqualToString:@"AVMetadataIdentifier"])
            return @[AVMetadataCommonIdentifierTitle, AVMetadataCommonIdentifierArtist][index % 2];
        if ([base isEqualToString:@"AVMetadataKeySpace"])
            return @[AVMetadataKeySpaceCommon, AVMetadataKeySpaceQuickTimeUserData][index % 2];
        if ([base isEqualToString:@"AVMetadataKey"])
            return @[AVMetadataCommonKeyTitle, AVMetadataCommonKeyArtist][index % 2];
#endif
        return @[@"FinchTest", @"org.finch.difftest"][index % 2];
    }
    if ([base hasSuffix:@"Identifier"] || [base hasSuffix:@"Domain"] || [base hasSuffix:@"Type"])
        return @[@"en_US_POSIX", @"fr_CA", @"ar_EG"][index % 3];
    if ([base hasPrefix:@"CF"] && [base hasSuffix:@"Ref"]) {
        NSString *bridge = [base stringByReplacingOccurrencesOfString:@"CF" withString:@"NS" options:0 range:NSMakeRange(0, 2)];
        bridge = [bridge stringByReplacingOccurrencesOfString:@"Ref" withString:@""];
        return auto_object([bridge stringByAppendingString:@" *"], index);
    }
    Class cls = NSClassFromString(base);
    if (cls) { @try { return [[cls alloc] init]; } @catch (__unused NSException *exception) { return nil; } }
    return nil;
}

static BOOL auto_type_is_mutable(NSString *type)
{
    return [type containsString:@"NSMutable"] || [type containsString:@"CFMutable"] ||
        [@[@"NSCountedSet", @"NSMapTable", @"NSHashTable", @"NSCache", @"NSCalendar",
           @"NSDateFormatter", @"NSNumberFormatter", @"NSBezierPath", @"NSAffineTransform", @"NSImage",
           @"NSBitmapImageRep", @"NSColorList", @"NSShadow", @"NSPasteboard", @"NSPrintInfo",
           @"NSView", @"NSCell", @"NSMenu", @"NSMenuItem", @"NSTableColumn", @"NSMutableIndexSet"] containsObject:type];
}

static NSMutableArray *auto_callback_output;
static BOOL auto_callback_was_used;

static void auto_callback_record(id value)
{
    if (auto_callback_output && auto_callback_output.count < 256)
        [auto_callback_output addObject:value ?: NSNull.null];
}

static NSArray *auto_callback_result(NSString *className)
{
    NSArray *values = auto_callback_output ?: @[];
    if (![className isEqualToString:@"NSSet"] && ![className isEqualToString:@"NSDictionary"])
        return values;
    return [values sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        return [auto_canonical(a) compare:auto_canonical(b)];
    }];
}

static id auto_method_object(NSString *type, NSString *parameterName, NSString *className,
    NSString *selectorName, NSUInteger index)
{
    NSString *clean = auto_clean_type(type);
    NSString *base = [[clean componentsSeparatedByString:@"<"] firstObject];
    base = [[base componentsSeparatedByString:@"*"] firstObject];
    base = [base stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *name = [parameterName lowercaseString] ?: @"";
    if ([type containsString:@"(^"]) {
        if (([className isEqualToString:@"NSArray"] || [className isEqualToString:@"NSOrderedSet"]) &&
            [type containsString:@"ObjectType"] && [type containsString:@"NSUInteger"] &&
            [type containsString:@"BOOL *"]) {
            auto_callback_was_used = YES;
            if ([type hasPrefix:@"BOOL"]) {
                BOOL (^callback)(id, NSUInteger, BOOL *) = ^BOOL(id object, NSUInteger index, BOOL *stop) {
                    BOOL matches = [object isEqual:@1];
                    auto_callback_record(@[auto_canonical(object) ?: @"null", @(index), @(matches)]);
                    return matches;
                };
                return [callback copy];
            }
            void (^callback)(id, NSUInteger, BOOL *) = ^(id object, NSUInteger index, BOOL *stop) {
                auto_callback_record(@[auto_canonical(object) ?: @"null", @(index)]);
                if (stop) *stop = NO;
            };
            return [callback copy];
        }
        if (([className isEqualToString:@"NSArray"] || [className isEqualToString:@"NSOrderedSet"]) &&
            [type hasPrefix:@"BOOL"] && [type containsString:@"ObjectType"] &&
            ![type containsString:@"NSUInteger"]) {
            auto_callback_was_used = YES;
            BOOL (^callback)(id, id) = ^BOOL(id first, id second) {
                BOOL matches = [first isEqual:second];
                auto_callback_record(@[auto_canonical(first) ?: @"null", auto_canonical(second) ?: @"null", @(matches)]);
                return matches;
            };
            return [callback copy];
        }
        if ([className isEqualToString:@"NSSet"] && [type containsString:@"ObjectType"] &&
            [type containsString:@"BOOL *"]) {
            auto_callback_was_used = YES;
            if ([type hasPrefix:@"BOOL"]) {
                BOOL (^callback)(id, BOOL *) = ^BOOL(id object, BOOL *stop) {
                    BOOL matches = [object isEqual:@1];
                    auto_callback_record(@[auto_canonical(object) ?: @"null", @(matches)]);
                    return matches;
                };
                return [callback copy];
            }
            void (^callback)(id, BOOL *) = ^(id object, BOOL *stop) {
                auto_callback_record(@[auto_canonical(object) ?: @"null"]);
                if (stop) *stop = NO;
            };
            return [callback copy];
        }
        if ([className isEqualToString:@"NSDictionary"] && [type containsString:@"KeyType"] &&
            [type containsString:@"ObjectType"] && [type containsString:@"BOOL *"]) {
            auto_callback_was_used = YES;
            if ([type hasPrefix:@"BOOL"]) {
                BOOL (^callback)(id, id, BOOL *) = ^BOOL(id key, id object, BOOL *stop) {
                    BOOL matches = [object isEqual:@1];
                    auto_callback_record(@[auto_canonical(key) ?: @"null", auto_canonical(object) ?: @"null", @(matches)]);
                    return matches;
                };
                return [callback copy];
            }
            void (^callback)(id, id, BOOL *) = ^(id key, id object, BOOL *stop) {
                auto_callback_record(@[auto_canonical(key) ?: @"null", auto_canonical(object) ?: @"null"]);
                if (stop) *stop = NO;
            };
            return [callback copy];
        }
        if ([className isEqualToString:@"NSIndexSet"] && [type containsString:@"BOOL *"] &&
            ([type containsString:@"NSUInteger"] || [type containsString:@"NSRange"])) {
            auto_callback_was_used = YES;
            if ([type hasPrefix:@"BOOL"]) {
                BOOL (^indexCallback)(NSUInteger, BOOL *) = ^BOOL(NSUInteger index, BOOL *stop) {
                    BOOL matches = index == 3;
                    auto_callback_record(@[@(index), @(matches)]);
                    return matches;
                };
                void (^rangeCallback)(NSRange, BOOL *) = ^(NSRange range, BOOL *stop) {
                    auto_callback_record(@[@(range.location), @(range.length)]);
                    if (stop) *stop = NO;
                };
                return [type containsString:@"NSRange"] ? [rangeCallback copy] : [indexCallback copy];
            }
            void (^indexCallback)(NSUInteger, BOOL *) = ^(NSUInteger index, BOOL *stop) {
                auto_callback_record(@[@(index)]);
                if (stop) *stop = NO;
            };
            void (^rangeCallback)(NSRange, BOOL *) = ^(NSRange range, BOOL *stop) {
                auto_callback_record(@[@(range.location), @(range.length)]);
                if (stop) *stop = NO;
            };
            return [type containsString:@"NSRange"] ? [rangeCallback copy] : [indexCallback copy];
        }
        if ([className isEqualToString:@"NSData"] && [type containsString:@"const void *"] &&
            [type containsString:@"NSRange"] && [type containsString:@"BOOL *"]) {
            auto_callback_was_used = YES;
            void (^callback)(const void *, NSRange, BOOL *) = ^(const void *bytes, NSRange range, BOOL *stop) {
                NSUInteger length = MIN(range.length, (NSUInteger)32);
                NSMutableString *hex = [NSMutableString string];
                const unsigned char *input = bytes;
                for (NSUInteger i = 0; input && i < length; i++) [hex appendFormat:@"%02x", input[i]];
                auto_callback_record(@[@(range.location), @(range.length), hex]);
                if (stop) *stop = NO;
            };
            return [callback copy];
        }
        if ([className isEqualToString:@"NSAttributedString"] && [type containsString:@"NSRange"] &&
            [type containsString:@"BOOL *"]) {
            auto_callback_was_used = YES;
            if ([type containsString:@"NSDictionary<NSAttributedStringKey,id>"]) {
                void (^callback)(NSDictionary *, NSRange, BOOL *) = ^(NSDictionary *attributes, NSRange range, BOOL *stop) {
                    auto_callback_record(@[auto_canonical(attributes ?: @{}) ?: @"null", @(range.location), @(range.length)]);
                    if (stop) *stop = NO;
                };
                return [callback copy];
            }
            void (^callback)(id, NSRange, BOOL *) = ^(id attribute, NSRange range, BOOL *stop) {
                auto_callback_record(@[auto_canonical(attribute) ?: @"null", @(range.location), @(range.length)]);
                if (stop) *stop = NO;
            };
            return [callback copy];
        }
        if ([className isEqualToString:@"NSString"] && [type containsString:@"NSRange"] &&
            [type containsString:@"BOOL *"]) {
            auto_callback_was_used = YES;
            if ([type containsString:@"NSString *"] && [[type componentsSeparatedByString:@"NSRange"] count] >= 3) {
                void (^callback)(NSString *, NSRange, NSRange, BOOL *) = ^(NSString *substring, NSRange substringRange,
                    NSRange enclosingRange, BOOL *stop) {
                    auto_callback_record(@[auto_canonical(substring) ?: @"null", @(substringRange.location),
                        @(substringRange.length), @(enclosingRange.location), @(enclosingRange.length)]);
                    if (stop) *stop = NO;
                };
                return [callback copy];
            }
            void (^callback)(NSString *, BOOL *) = ^(NSString *line, BOOL *stop) {
                auto_callback_record(@[auto_canonical(line) ?: @"null"]);
                if (stop) *stop = NO;
            };
            return [callback copy];
        }
        if ([className isEqualToString:@"NSString"] && [selectorName containsString:@"enumerateLines"] &&
            [type containsString:@"NSString *"] && [type containsString:@"BOOL *"]) {
            auto_callback_was_used = YES;
            void (^callback)(NSString *, BOOL *) = ^(NSString *line, BOOL *stop) {
                auto_callback_record(@[auto_canonical(line) ?: @"null"]);
                if (stop) *stop = NO;
            };
            return [callback copy];
        }
        if ([className isEqualToString:@"NSRegularExpression"] &&
            [type containsString:@"NSTextCheckingResult"] && [type containsString:@"NSMatchingFlags"] &&
            [type containsString:@"BOOL *"]) {
            auto_callback_was_used = YES;
            void (^callback)(NSTextCheckingResult *, NSMatchingFlags, BOOL *) = ^(NSTextCheckingResult *result,
                NSMatchingFlags flags, BOOL *stop) {
                auto_callback_record(@[auto_canonical(result) ?: @"null", @(flags)]);
                if (stop) *stop = NO;
            };
            return [callback copy];
        }
    }
    if ([className isEqualToString:@"NSDateComponentsFormatter"] && [base isEqualToString:@"NSLocale"])
        return [[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"] autorelease];
    if ([className isEqualToString:@"NSPersonNameComponentsFormatter"]) {
        if ([base isEqualToString:@"NSLocale"])
            return [[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"] autorelease];
        if ([base isEqualToString:@"NSPersonNameComponents"])
            return auto_object(@"NSPersonNameComponents *", index);
    }
    if ([className isEqualToString:@"NSMeasurement"] && [base isEqualToString:@"NSUnit"])
        return auto_object(type, index);
    if (([className isEqualToString:@"NSMeasurementFormatter"] || [className isEqualToString:@"NSByteCountFormatter"]) &&
        [base isEqualToString:@"NSMeasurement"])
        return auto_object(type, index);
    if ([className isEqualToString:@"NSMeasurementFormatter"] && [base isEqualToString:@"NSLocale"])
        return [[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"] autorelease];
    if ([className isEqualToString:@"NSEnergyFormatter"] && [base isEqualToString:@"NSNumberFormatter"]) {
        NSNumberFormatter *formatter = [[[NSNumberFormatter alloc] init] autorelease];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.numberStyle = NSNumberFormatterDecimalStyle;
        return formatter;
    }
    if ([className isEqualToString:@"NSScanner"] && [base isEqualToString:@"NSString"])
        return @"42 -17 3.5 0x2a";
    if ([className isEqualToString:@"NSFileWrapper"]) {
        if ([base isEqualToString:@"NSData"])
            return auto_data("finch", 5);
        if ([base isEqualToString:@"NSFileWrapper"])
            return auto_object(@"NSFileWrapper *", index);
        if ([base isEqualToString:@"NSString"] && [name containsString:@"filename"])
            return @"finch.txt";
        if ([base isEqualToString:@"NSString"] &&
            ([selectorName isEqualToString:@"initSymbolicLinkWithDestination:"] ||
             [selectorName isEqualToString:@"addSymbolicLinkWithDestination:preferredFilename:"]))
            return @"/System";
        if ([base isEqualToString:@"NSDictionary"] && [selectorName isEqualToString:@"initDirectoryWithFileWrappers:"]) {
            NSFileWrapper *child = auto_object(@"NSFileWrapper *", index + 1);
            child.preferredFilename = @"finch.txt";
            return @{@"finch.txt":child};
        }
        if ([base isEqualToString:@"NSDictionary"] &&
            ([name containsString:@"attribute"] || [selectorName isEqualToString:@"setFileAttributes:"]))
            return @{NSFileType:NSFileTypeRegular, NSFilePosixPermissions:@0644};
        if ([base isEqualToString:@"NSString"] && [name containsString:@"destination"])
            return @"/System";
    }
    if ([className isEqualToString:@"NSProgress"] && [base isEqualToString:@"NSProgress"])
        return auto_object(@"NSProgress *", index);
#ifdef FINCH_DIFFTEST_COREIMAGE
    if ([base isEqualToString:@"NSString"] && [selectorName containsString:@"kernelWithString"]) {
        if ([className isEqualToString:@"CIColorKernel"])
            return @"kernel vec4 finchDifftestColorKernel (vec4 color) { return color; }";
        if ([className isEqualToString:@"CIWarpKernel"])
            return @"kernel vec2 finchDifftestWarpKernel (vec2 point) { return point; }";
        if ([className isEqualToString:@"CIBlendKernel"])
            return @"kernel vec4 finchDifftestBlendKernel (__sample foreground, __sample background) { return foreground + background; }";
        return @"kernel vec4 finchDifftestKernel (sampler image) { return sample(image, samplerCoord(image)); }";
    }
    if ([base isEqualToString:@"NSData"] &&
        ([className hasSuffix:@"CodeDescriptor"] || [className isEqualToString:@"CIQRCodeDescriptor"]))
        return [NSData dataWithBytes:"finch" length:5];
#endif
#ifdef FINCH_DIFFTEST_CORESPOTLIGHT
    if ([className isEqualToString:@"CSSearchableItemAttributeSet"] && [base isEqualToString:@"UTType"])
        return [UTType typeWithIdentifier:@"public.item"];
    if ([className isEqualToString:@"CSSearchableItemAttributeSet"] && [base isEqualToString:@"NSArray"]) {
        if ([type containsString:@"CSPerson"])
            return @[auto_object(@"CSPerson *", index)];
        if ([type containsString:@"NSString"])
            return @[@"Finch", @"difftest"];
        if ([type containsString:@"NSNumber"])
            return @[@1, @2];
    }
    if ([className isEqualToString:@"CSPerson"] && [base isEqualToString:@"NSArray"])
        return @[@"+1 416 555 0100", @"+1 416 555 0101"];
    if ([className isEqualToString:@"CSLocalizedString"] && [base isEqualToString:@"NSDictionary"])
        return @{@"en":@"Finch", @"fr":@"Finch"};
    if ([className isEqualToString:@"CSCustomAttributeKey"] && [base isEqualToString:@"NSString"] &&
        [name containsString:@"key"])
        return @[@"org_finch_value", @"org_finch_name", @"org_finch_tag"][index % 3];
#endif
#ifdef FINCH_DIFFTEST_QUARTZCORE
    if ([className hasPrefix:@"CA"] && [base isEqualToString:@"NSString"] &&
        ([name containsString:@"keypath"] || [name containsString:@"key"] || [name containsString:@"property"]))
        return @[@"opacity", @"position", @"bounds"][index % 3];
#endif
#ifdef FINCH_DIFFTEST_APPKIT
    if ([base isEqualToString:@"NSArray"] && [className isEqualToString:@"NSMenu"] &&
        [selectorName isEqualToString:@"setItemArray:"])
        return @[auto_object(@"NSMenuItem *", index)];
    if ([base isEqualToString:@"NSArray"] && [className isEqualToString:@"NSMenuItem"] &&
        [selectorName isEqualToString:@"setWritingToolsItems:"])
        return @[auto_object(@"NSMenuItem *", index)];
#endif
#ifdef FINCH_DIFFTEST_COREIMAGE
    if ([className isEqualToString:@"CIFilter"] && [base isEqualToString:@"NSString"] &&
        ([name containsString:@"name"] || [selectorName containsString:@"WithName"]))
        return @"CIColorControls";
    if ([className isEqualToString:@"CIFilter"] && [base isEqualToString:@"NSString"] &&
        [name containsString:@"key"])
        return kCIInputImageKey;
#endif
#ifdef FINCH_DIFFTEST_UTI
    if ([className isEqualToString:@"UTType"] && [base isEqualToString:@"NSString"]) {
        if ([name containsString:@"tag"] || [name containsString:@"extension"])
            return @[@"txt", @"jpg", @"pdf"][index % 3];
        if ([name containsString:@"mime"])
            return @[@"text/plain", @"image/jpeg", @"application/pdf"][index % 3];
        return @[@"public.plain-text", @"public.jpeg", @"com.adobe.pdf"][index % 3];
    }
#endif
#ifdef FINCH_DIFFTEST_CONTACTS
    if ([className isEqualToString:@"CNContactFormatter"] && [base isEqualToString:@"NSLocale"])
        return [[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"] autorelease];
    if ([className isEqualToString:@"CNContactFormatter"] && [base isEqualToString:@"CNContact"])
        return auto_object(@"CNContact *", index);
    if ([className isEqualToString:@"CNPostalAddressFormatter"] && [base isEqualToString:@"CNPostalAddress"])
        return auto_object(@"CNPostalAddress *", index);
    if ([className isEqualToString:@"CNContact"] && [base isEqualToString:@"NSString"])
        return @[@"givenName", @"familyName", @"organizationName"][index % 3];
#endif
#ifdef FINCH_DIFFTEST_COREDATA
    if ([className hasPrefix:@"NS"] && [base isEqualToString:@"NSString"] &&
        ([name containsString:@"entity"] || [name containsString:@"name"]))
        return @"FinchDifftestEntity";
    if ([className hasPrefix:@"NS"] && [base isEqualToString:@"NSString"] && [name containsString:@"property"])
        return @"title";
#endif
#ifdef FINCH_DIFFTEST_CORELOCATION
    if ([className hasPrefix:@"CL"] && [base isEqualToString:@"NSString"] && [name containsString:@"identifier"])
        return @"FinchDifftest";
#endif
#ifdef FINCH_DIFFTEST_APPKIT
    if ([className isEqualToString:@"NSColor"] &&
        ([base isEqualToString:@"NSString"] || [base isEqualToString:@"NSColorName"])) {
        if ([name containsString:@"space"] || [selectorName containsString:@"colorUsingColorSpaceName"])
            return @[
                NSDeviceRGBColorSpace, NSCalibratedRGBColorSpace, NSDeviceWhiteColorSpace,
                NSCalibratedWhiteColorSpace, NSDeviceCMYKColorSpace, NSNamedColorSpace, NSPatternColorSpace
            ][index % 7];
        if ([selectorName containsString:@"Named"] || [name containsString:@"name"])
            return @[@"controlAccentColor", @"labelColor", @"textColor", @"systemRedColor"][index % 4];
    }
    if ([className isEqualToString:@"NSColor"] &&
        [base isEqualToString:@"NSColorSpaceName"])
        return @[
            NSDeviceRGBColorSpace, NSCalibratedRGBColorSpace, NSDeviceWhiteColorSpace,
            NSCalibratedWhiteColorSpace, NSDeviceCMYKColorSpace, NSNamedColorSpace, NSPatternColorSpace
        ][index % 7];
    if (([className isEqualToString:@"NSFont"] || [className isEqualToString:@"NSFontDescriptor"] ||
         [className isEqualToString:@"NSFontManager"]) && [base isEqualToString:@"NSString"] &&
        ([name containsString:@"font"] || [name containsString:@"family"] || [name containsString:@"face"] ||
         [name containsString:@"name"]))
        return @[@"Helvetica", @"Menlo", @"Noto Sans", @"FinchDifftestMissingFont"][index % 4];
    if ([className isEqualToString:@"NSFontDescriptor"] && [base isEqualToString:@"NSDictionary"])
        return @{NSFontNameAttribute:@[@"Helvetica", @"Menlo", @"Noto Sans"][index % 3], NSFontSizeAttribute:@13};
    if ([className isEqualToString:@"NSBitmapImageRep"] &&
        ([base isEqualToString:@"NSString"] || [base isEqualToString:@"NSColorSpaceName"]))
        return NSCalibratedRGBColorSpace;
    if ([className isEqualToString:@"NSColorList"] &&
        ([base isEqualToString:@"NSString"] || [base isEqualToString:@"NSColorListName"]) &&
        ([name containsString:@"name"] || [selectorName containsString:@"Named"]))
        return @"System";
    if ([className isEqualToString:@"NSAppearance"] &&
        ([base isEqualToString:@"NSString"] || [base isEqualToString:@"NSAppearanceName"]))
        return @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua][index % 2];
    if ([className isEqualToString:@"NSPasteboard"] &&
        ([base isEqualToString:@"NSString"] || [base isEqualToString:@"NSPasteboardName"]) &&
        ([name containsString:@"name"] || [selectorName containsString:@"WithName"]))
        return [NSString stringWithFormat:@"org.finch.difftest.argument.%lu", (unsigned long)(index % 8)];
    if ([className isEqualToString:@"NSPasteboard"] && [base isEqualToString:@"NSString"])
        return @"Finch Difftest café🙂";
    if ([className isEqualToString:@"NSPasteboard"] && [base isEqualToString:@"NSPasteboardType"])
        return NSPasteboardTypeString;
    if ([className isEqualToString:@"NSPasteboard"] && [base isEqualToString:@"NSData"])
        return [@"Finch Difftest café🙂" dataUsingEncoding:NSUTF8StringEncoding];
    if ([className isEqualToString:@"NSPasteboard"] && [base isEqualToString:@"id"] &&
        [selectorName isEqualToString:@"setPropertyList:forType:"])
        return @"Finch Difftest café🙂";
    if ([className isEqualToString:@"NSPasteboard"] && [base isEqualToString:@"NSArray"]) {
        if ([selectorName containsString:@"readObjectsForClasses"])
            return @[(id)NSString.class, (id)NSAttributedString.class];
        return @[NSPasteboardTypeString, @"org.finch.difftest.extra"];
    }
    if ([className isEqualToString:@"NSLayoutDimension"] && [base isEqualToString:@"NSLayoutDimension"])
        return auto_layout_peer_view().widthAnchor;
    if ([className isEqualToString:@"NSLayoutAnchor"] && [base isEqualToString:@"NSLayoutAnchor"])
        return auto_layout_peer_view().leadingAnchor;
    if ([className isEqualToString:@"NSLayoutXAxisAnchor"] && [base isEqualToString:@"NSLayoutXAxisAnchor"])
        return auto_layout_peer_view().leadingAnchor;
    if ([className isEqualToString:@"NSLayoutYAxisAnchor"] && [base isEqualToString:@"NSLayoutYAxisAnchor"])
        return auto_layout_peer_view().topAnchor;
    if (([className isEqualToString:@"NSLayoutAnchor"] || [className isEqualToString:@"NSLayoutXAxisAnchor"]) &&
        [base isEqualToString:@"NSView"])
        return auto_layout_peer_view();
    if ([className isEqualToString:@"NSLayoutYAxisAnchor"] && [base isEqualToString:@"NSView"])
        return auto_layout_peer_view();
    if ([className isEqualToString:@"NSLayoutConstraint"] && [base isEqualToString:@"NSView"] &&
        [name containsString:@"toitem"])
        return auto_layout_peer_view();
    if ([className isEqualToString:@"NSPrintInfo"] && [base isEqualToString:@"NSDictionary"])
        return @{
            NSPrintPaperName:@"na-letter", NSPrintPaperSize:[NSValue valueWithSize:NSMakeSize(612, 792)],
            NSPrintLeftMargin:@12, NSPrintRightMargin:@12, NSPrintTopMargin:@18, NSPrintBottomMargin:@24
        };
    if ([className isEqualToString:@"NSColorList"] && [base isEqualToString:@"NSString"])
        return @[@"accent", @"gray"][index % 2];
    if ([className isEqualToString:@"NSAttributedString"] || [className isEqualToString:@"NSMutableAttributedString"]) {
        if ([base isEqualToString:@"NSDictionary"])
            return @{NSFontAttributeName:[NSFont systemFontOfSize:12], NSForegroundColorAttributeName:auto_color(index)};
    }
    if ([className isEqualToString:@"NSGradient"] && [base isEqualToString:@"NSArray"])
        return @[auto_color(index), auto_color(index + 1)];
    if ([className isEqualToString:@"NSPrintInfo"] &&
        ([base isEqualToString:@"NSString"] || [base isEqualToString:@"NSPrinterPaperName"]) &&
        [name containsString:@"paper"])
        return @[@"na-letter", @"iso-a4"][index % 2];
#endif
#if defined(FINCH_DIFFTEST_COREIMAGE) || defined(FINCH_DIFFTEST_QUARTZCORE)
    if ([base isEqualToString:@"CGColorSpaceRef"] || [base isEqualToString:@"CGColorSpace"]) {
        CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        return (id)colorSpace;
    }
#endif
    if ([className isEqualToString:@"NSObject"]) {
        if ([selectorName hasPrefix:@"isGreaterThan"] || [selectorName hasPrefix:@"isLessThan"])
            return @[@1, @2, @3][index % 3];
        if ([name containsString:@"observer"]) return [[[NSObject alloc] init] autorelease];
        if ([name containsString:@"key"] || [name containsString:@"keypath"] || [name containsString:@"propertykey"]) {
            if ([selectorName containsString:@"addObserver"] || [selectorName containsString:@"takeValue"])
                return @"name";
            if ([selectorName containsString:@"mutableOrderedSetValueForKey"])
                return @"orderedItems";
            if ([selectorName containsString:@"mutableSetValueForKey"])
                return @"tags";
            NSArray *keys = [selectorName containsString:@"KeyPath"] ? @[@"name", @"name.length", @"age", @"items"]
                : @[@"name", @"age", @"items", @"name"];
            return keys[index % keys.count];
        }
        if ([name isEqualToString:@"value"] && [selectorName containsString:@"takeValue"])
            return @"Finch updated";
        if ([name isEqualToString:@"properties"] && [selectorName containsString:@"takeValuesFromDictionary"])
            return @{ @"name": @"Finch updated", @"age": @37 };
        if ([name isEqualToString:@"object"] && ([selectorName hasPrefix:@"isGreaterThan"] || [selectorName hasPrefix:@"isLessThan"]))
            return @[@1, @2, @3][index % 3];
    }
    if ([className isEqualToString:@"NSString"] && [selectorName isEqualToString:@"stringByAppendingPathExtension:"] &&
        ([name isEqualToString:@"str"] || [name containsString:@"extension"]))
        return @[@"", @"txt", @"tar.gz", @"a/b"][index % 4];
    if ([className isEqualToString:@"NSExpression"] &&
        [selectorName isEqualToString:@"expressionForFunction:arguments:"] && [name isEqualToString:@"name"])
        return @"sum:";
    if ([className isEqualToString:@"NSExpression"] &&
        [selectorName isEqualToString:@"expressionForFunction:selectorName:arguments:"] && [name isEqualToString:@"name"])
        return @"uppercaseString";
    if ([name containsString:@"base64"]) {
        if ([base isEqualToString:@"NSString"] || [base isEqualToString:@"NSMutableString"])
            return @[@"", @"YQ==", @"SGVsbG8=", @"Zm9vYmFy"][index % 4];
        if ([base isEqualToString:@"NSData"] || [base isEqualToString:@"NSMutableData"]) {
            const char *encoded[] = {"", "YQ==", "SGVsbG8=", "Zm9vYmFy"};
            return auto_data(encoded[index % 4], strlen(encoded[index % 4]));
        }
    }
    if ([className isEqualToString:@"NSDate"] && [selectorName containsString:@"NaturalLanguage"] &&
        [name containsString:@"locale"])
        return @{NSLocaleIdentifier:@"en_US_POSIX"};
    if ([className isEqualToString:@"NSDecimalNumber"] && [name containsString:@"behavior"])
        return [NSDecimalNumberHandler decimalNumberHandlerWithRoundingMode:NSRoundPlain scale:2
            raiseOnExactness:NO raiseOnOverflow:NO raiseOnUnderflow:NO raiseOnDivideByZero:NO];
    if ([className isEqualToString:@"NSExpression"] && [selectorName containsString:@"expressionForFunction"]) {
        if ([name containsString:@"target"])
            return [NSExpression expressionForConstantValue:@"Finch"];
        if ([name containsString:@"selectorname"])
            return @"uppercaseString";
    }
    if ([className isEqualToString:@"NSDateInterval"] && [base isEqualToString:@"NSDate"])
        return [NSDate dateWithTimeIntervalSinceReferenceDate:[name containsString:@"end"] ? 800000000 : 700000000];
    if ([className isEqualToString:@"NSDateComponentsFormatter"] && [base isEqualToString:@"NSDateComponents"]) {
        NSDateComponents *components = [[[NSDateComponents alloc] init] autorelease];
        components.hour = 1; components.minute = 2; components.second = 3;
        return components;
    }
    if ([className isEqualToString:@"NSMutableDictionary"] &&
        [selectorName isEqualToString:@"dictionaryWithSharedKeySet:"])
        return [NSMutableDictionary sharedKeySetForKeys:@[@"a", @"b"]];
    if ([className isEqualToString:@"NSExpression"] && [selectorName containsString:@"expressionWithFormat"] && [name containsString:@"format"])
        return @"1 + 2";
    if ([className isEqualToString:@"NSExpression"] && [selectorName containsString:@"expressionForFunction"] && [name containsString:@"function"])
        return [selectorName isEqualToString:@"expressionForFunction:arguments:"] ? @"sum:" : @"uppercaseString";
    if ([className isEqualToString:@"NSMethodSignature"] &&
        ([name containsString:@"types"] || [name containsString:@"encoding"]))
        return @"v@:";
    if ([className isEqualToString:@"NSCalendar"] && [type containsString:@"NSCalendarIdentifier"])
        return @[NSCalendarIdentifierGregorian, NSCalendarIdentifierISO8601][index % 2];
    if ([className isEqualToString:@"NSRegularExpression"] && [base isEqualToString:@"NSString"])
        return @"Finch";
    if (([className isEqualToString:@"NSAttributedString"] || [className isEqualToString:@"NSMutableAttributedString"]) &&
        ([base isEqualToString:@"NSString"] || [base isEqualToString:@"NSAttributedStringKey"]))
        return @"FinchTest";
    if ([base isEqualToString:@"NSString"] || [base isEqualToString:@"NSMutableString"]) {
        if ([className isEqualToString:@"NSLocale"]) {
            if ([selectorName containsString:@"DirectionForLanguage"])
                return @[@"en", @"ar", @"he"][index % 3];
            if ([selectorName containsString:@"canonicalLanguageIdentifier"])
                return @[@"en", @"ar-EG", @"he-IL"][index % 3];
            if ([selectorName containsString:@"Identifier"] || [name containsString:@"language"] ||
                [name containsString:@"locale"] || [name containsString:@"identifier"])
                return @[@"en_US_POSIX", @"ar_EG", @"he_IL"][index % 3];
            if ([name isEqualToString:@"key"]) return NSLocaleIdentifier;
        }
        if ([className isEqualToString:@"NSCalendar"] && [name containsString:@"identifier"])
            return @[NSCalendarIdentifierGregorian, NSCalendarIdentifierISO8601][index % 2];
        if ([className isEqualToString:@"NSTimeZone"] &&
            ([selectorName containsString:@"WithName"] || [name containsString:@"name"]))
            return @[@"UTC", @"America/Toronto", @"Asia/Kathmandu"][index % 3];
        if ([className isEqualToString:@"NSURL"] && [name containsString:@"path"])
            return @[@"/tmp/finch-difftest", @"/tmp/finch-difftest/file.txt"][index % 2];
        if ([className isEqualToString:@"NSURLComponents"] && [name containsString:@"percentencoded"]) {
            if ([name containsString:@"host"]) return @"example.test";
            if ([name containsString:@"user"]) return @"finch";
            if ([name containsString:@"password"]) return @"secret";
            if ([name containsString:@"path"]) return @"/a%20b";
            if ([name containsString:@"query"]) return @"q=1";
            if ([name containsString:@"fragment"]) return @"part";
        }
        if ([className isEqualToString:@"NSDecimalNumber"] &&
            ([selectorName containsString:@"WithString"] || [name containsString:@"string"] || [name containsString:@"numbervalue"]))
            return @[@"0", @"-1.25", @"42.5", @"999999.125"][index % 4];
        if ([className isEqualToString:@"NSCalendarDate"] && [name containsString:@"locale"])
            return @{NSLocaleIdentifier:@"en_US_POSIX"};
        if ([className isEqualToString:@"NSCalendarDate"]) {
            if ([name containsString:@"format"]) return @"%Y-%m-%d %H:%M:%S";
            if ([selectorName containsString:@"String"] &&
                ([name containsString:@"description"] || [name containsString:@"string"]))
                return @"2001-01-02 03:04:05";
        }
        if ([className isEqualToString:@"NSXMLDocument"] && [name containsString:@"string"])
            return @"<root><item>value</item></root>";
        if ([className isEqualToString:@"NSXMLDocument"] && [name containsString:@"stylesheet"])
            return @"<?xml version=\"1.0\"?><xsl:stylesheet version=\"1.0\" xmlns:xsl=\"http://www.w3.org/1999/XSL/Transform\"><xsl:template match=\"/\"><result/></xsl:template></xsl:stylesheet>";
        if ([className isEqualToString:@"NSDateFormatter"]) {
            if ([name containsString:@"format"]) return @"yyyy-MM-dd HH:mm:ss";
            if ([name containsString:@"string"]) return @"2001-01-02 03:04:05";
        }
        if ([className isEqualToString:@"NSExpression"] && [name containsString:@"function"])
            return @"sum:";
    }
    if ([base isEqualToString:@"NSArray"] && [className isEqualToString:@"NSExpression"] &&
        [selectorName containsString:@"expressionWithFormat"] && [name containsString:@"argumentarray"])
        return @[];
    if ([base isEqualToString:@"NSArray"] && [className isEqualToString:@"NSExpression"] &&
        [selectorName containsString:@"expressionForFunction"] && [selectorName containsString:@"selectorName"])
        return @[];
    if ([base isEqualToString:@"NSArray"] && [className isEqualToString:@"NSExpression"] &&
        [selectorName isEqualToString:@"expressionForFunction:arguments:"])
        return @[[NSExpression expressionForAggregate:@[[NSExpression expressionForConstantValue:@1], [NSExpression expressionForConstantValue:@2]]]];
    if ([base isEqualToString:@"NSArray"] && [className isEqualToString:@"NSExpression"] &&
        [name containsString:@"argument"])
        return @[[NSExpression expressionForConstantValue:@1], [NSExpression expressionForConstantValue:@2]];
    if ([base isEqualToString:@"NSData"] && [className isEqualToString:@"NSJSONSerialization"] &&
        [name containsString:@"data"]) {
        NSArray *json = @[@"{\"key\":1}", @"[1,2]", @"null"];
        return [json[index % json.count] dataUsingEncoding:NSUTF8StringEncoding];
    }
    if ([base isEqualToString:@"NSData"] && [className isEqualToString:@"NSXMLDocument"] &&
        [name containsString:@"data"])
        return [@"<root><item>value</item></root>" dataUsingEncoding:NSUTF8StringEncoding];
    if ([base isEqualToString:@"id"] && [className isEqualToString:@"NSDecimalNumber"] && [name containsString:@"locale"])
        return @{NSLocaleIdentifier:@"en_US_POSIX", NSLocaleDecimalSeparator:@"."};
    if ([base isEqualToString:@"id"] && [className isEqualToString:@"NSCalendarDate"] && [name containsString:@"locale"])
        return @{NSLocaleIdentifier:@"en_US_POSIX"};
    if ([base isEqualToString:@"id"] && [selectorName containsString:@"descriptionWithLocale"] && [name containsString:@"locale"])
        return nil;
    return auto_object(type, index);
}

static id auto_receiver(NSString *className, NSString *selectorName)
{
    Class cls = NSClassFromString(className);
    if (!cls) return nil;
    if ([selectorName hasPrefix:@"init"]) return [cls alloc];
    if ([className hasPrefix:@"PDF"] || [className hasPrefix:@"AV"] || [className hasPrefix:@"IK"] ||
        [className hasPrefix:@"OD"] || [className hasPrefix:@"SK"] || [className hasPrefix:@"LP"])
        return auto_object([className stringByAppendingString:@" *"], 2);
    if ([className isEqualToString:@"NSIndexSet"]) return auto_object(@"NSIndexSet *", 2);
    if ([className isEqualToString:@"NSMutableIndexSet"]) return auto_object(@"NSMutableIndexSet *", 2);
    if ([className isEqualToString:@"NSMeasurement"] || [className isEqualToString:@"NSPersonNameComponents"] ||
        [className isEqualToString:@"NSUnit"] || [className hasPrefix:@"NSUnit"] ||
        [className isEqualToString:@"NSScanner"])
        return auto_object([NSString stringWithFormat:@"%@ *", className], 2);
    if ([className isEqualToString:@"NSDateComponentsFormatter"]) {
        NSDateComponentsFormatter *formatter = [[[NSDateComponentsFormatter alloc] init] autorelease];
        formatter.calendar = [[[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian] autorelease];
        formatter.calendar.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.calendar.timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
        formatter.allowedUnits = NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond;
        formatter.unitsStyle = NSDateComponentsFormatterUnitsStyleFull;
        return formatter;
    }
    if ([className isEqualToString:@"NSPersonNameComponentsFormatter"]) {
        NSPersonNameComponentsFormatter *formatter = [[[NSPersonNameComponentsFormatter alloc] init] autorelease];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        return formatter;
    }
    if ([className isEqualToString:@"NSByteCountFormatter"]) {
        NSByteCountFormatter *formatter = [[[NSByteCountFormatter alloc] init] autorelease];
        formatter.countStyle = NSByteCountFormatterCountStyleFile;
        formatter.allowedUnits = NSByteCountFormatterUseAll;
        return formatter;
    }
    if ([className isEqualToString:@"NSEnergyFormatter"]) {
        NSEnergyFormatter *formatter = [[[NSEnergyFormatter alloc] init] autorelease];
        NSNumberFormatter *numberFormatter = [[[NSNumberFormatter alloc] init] autorelease];
        numberFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        numberFormatter.numberStyle = NSNumberFormatterDecimalStyle;
        formatter.numberFormatter = numberFormatter;
        return formatter;
    }
    if ([className isEqualToString:@"NSMeasurementFormatter"]) {
        NSMeasurementFormatter *formatter = [[[NSMeasurementFormatter alloc] init] autorelease];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.unitOptions = NSMeasurementFormatterUnitOptionsProvidedUnit;
        NSNumberFormatter *numberFormatter = [[[NSNumberFormatter alloc] init] autorelease];
        numberFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        numberFormatter.numberStyle = NSNumberFormatterDecimalStyle;
        formatter.numberFormatter = numberFormatter;
        return formatter;
    }
    if ([className isEqualToString:@"NSFileWrapper"]) {
        if ([selectorName isEqualToString:@"isSymbolicLink"] ||
            [selectorName isEqualToString:@"symbolicLinkDestination"])
            return [[[NSFileWrapper alloc] initSymbolicLinkWithDestination:@"/System"] autorelease];
        if ([selectorName isEqualToString:@"fileWrappers"] || [selectorName isEqualToString:@"addFileWrapper:"] ||
            [selectorName isEqualToString:@"addRegularFileWithContents:preferredFilename:"] ||
            [selectorName isEqualToString:@"addSymbolicLinkWithDestination:preferredFilename:"] ||
            [selectorName isEqualToString:@"removeFileWrapper"] || [selectorName isEqualToString:@"keyForFileWrapper:"] ||
            [selectorName isEqualToString:@"isDirectory"]) {
            NSFileWrapper *child = auto_object(@"NSFileWrapper *", 2);
            child.preferredFilename = @"finch.txt";
            return [[[NSFileWrapper alloc] initDirectoryWithFileWrappers:@{@"finch.txt":child}] autorelease];
        }
        return auto_object(@"NSFileWrapper *", 2);
    }
    if ([className isEqualToString:@"NSProgress"]) {
        NSProgress *progress = [NSProgress progressWithTotalUnitCount:100];
        progress.completedUnitCount = 42; progress.cancellable = YES; progress.pausable = YES;
        progress.localizedDescription = @"Finch";
        return progress;
    }
#ifdef FINCH_DIFFTEST_APPKIT
    if ([className isEqualToString:@"NSGridView"]) return auto_grid_view();
    if ([className isEqualToString:@"NSGridRow"]) return [auto_grid_view() rowAtIndex:0];
    if ([className isEqualToString:@"NSGridColumn"]) return [auto_grid_view() columnAtIndex:0];
    if ([className isEqualToString:@"NSGridCell"]) return [auto_grid_view() cellAtColumnIndex:0 rowIndex:0];
    if ([className isEqualToString:@"NSRulerView"]) return auto_ruler_view();
    if ([className isEqualToString:@"NSRulerMarker"])
        return auto_object(@"NSRulerMarker *", 2);
    if ([className isEqualToString:@"NSSlider"]) {
        NSSlider *slider = [[[NSSlider alloc] initWithFrame:NSMakeRect(0, 0, 140, 24)] autorelease];
        slider.minValue = 0; slider.maxValue = 100; slider.doubleValue = 42;
        return slider;
    }
    if ([className isEqualToString:@"NSLevelIndicator"]) {
        NSLevelIndicator *indicator = [[[NSLevelIndicator alloc] initWithFrame:NSMakeRect(0, 0, 120, 16)] autorelease];
        indicator.minValue = 0; indicator.maxValue = 100; indicator.doubleValue = 42;
        return indicator;
    }
    if ([className isEqualToString:@"NSPopUpButton"]) {
        NSPopUpButton *button = [[[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 140, 24) pullsDown:NO] autorelease];
        [button addItemsWithTitles:@[@"One", @"Two", @"Three"]];
        return button;
    }
    if ([className isEqualToString:@"NSTabView"]) {
        NSTabView *tabView = [[[NSTabView alloc] initWithFrame:NSMakeRect(0, 0, 160, 100)] autorelease];
        for (NSString *identifier in @[@"one", @"two", @"three"]) {
            NSTabViewItem *item = [[[NSTabViewItem alloc] initWithIdentifier:identifier] autorelease];
            [item setLabel:[identifier capitalizedString]];
            [tabView addTabViewItem:item];
        }
        return tabView;
    }
    if ([className isEqualToString:@"NSTabViewItem"]) {
        NSTabViewItem *item = [[[NSTabViewItem alloc] initWithIdentifier:@"one"] autorelease];
        [item setLabel:@"One"];
        return item;
    }
    if ([className isEqualToString:@"NSMatrix"]) {
        return [[[NSMatrix alloc] initWithFrame:NSMakeRect(0, 0, 120, 48) mode:NSRadioModeMatrix
            cellClass:NSButtonCell.class numberOfRows:2 numberOfColumns:2] autorelease];
    }
    if ([className isEqualToString:@"NSControl"])
        return [[[NSControl alloc] initWithFrame:NSMakeRect(0, 0, 120, 24)] autorelease];
    if ([className isEqualToString:@"NSButton"])
        return [[[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 120, 24)] autorelease];
    if ([className isEqualToString:@"NSTextField"])
        return [[[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 160, 24)] autorelease];
    if ([className isEqualToString:@"NSComboBox"]) {
        NSComboBox *combo = [[[NSComboBox alloc] initWithFrame:NSMakeRect(0, 0, 160, 24)] autorelease];
        [combo addItemsWithObjectValues:@[@"One", @"Two", @"Three"]];
        return combo;
    }
    if ([className isEqualToString:@"NSSegmentedControl"]) {
        NSSegmentedControl *control = [[[NSSegmentedControl alloc] initWithFrame:NSMakeRect(0, 0, 180, 24)] autorelease];
        control.segmentCount = 3;
        [control setLabel:@"One" forSegment:0]; [control setLabel:@"Two" forSegment:1]; [control setLabel:@"Three" forSegment:2];
        return control;
    }
    if ([className isEqualToString:@"NSProgressIndicator"])
        return [[[NSProgressIndicator alloc] initWithFrame:NSMakeRect(0, 0, 120, 16)] autorelease];
    if ([className isEqualToString:@"NSBox"])
        return [[[NSBox alloc] initWithFrame:NSMakeRect(0, 0, 140, 80)] autorelease];
    if ([className isEqualToString:@"NSColor"]) return auto_color(2);
    if ([className isEqualToString:@"NSColorSpace"]) return [NSColorSpace sRGBColorSpace];
    if ([className isEqualToString:@"NSColorList"]) {
        NSColorList *list = [[[NSColorList alloc] initWithName:@"FinchDifftest"] autorelease];
        [list setColor:auto_color(1) forKey:@"accent"];
        [list setColor:auto_color(4) forKey:@"gray"];
        return list;
    }
    if ([className isEqualToString:@"NSCell"]) {
        NSString *title = [selectorName isEqualToString:@"setFloatingPointFormat:left:right:"] ? @"42.5" : @"Finch";
        NSCell *cell = [[[NSCell alloc] initTextCell:title] autorelease];
        if ([selectorName isEqualToString:@"setFloatingPointFormat:left:right:"]) cell.doubleValue = 42.5;
        return cell;
    }
    if ([className isEqualToString:@"NSButtonCell"])
        return [[[NSButtonCell alloc] initTextCell:@"Finch"] autorelease];
    if ([className isEqualToString:@"NSSliderCell"])
        return [[[NSSliderCell alloc] init] autorelease];
    if ([className isEqualToString:@"NSSegmentedCell"]) {
        NSSegmentedCell *cell = [[[NSSegmentedCell alloc] init] autorelease];
        cell.segmentCount = 3;
        [cell setLabel:@"One" forSegment:0]; [cell setLabel:@"Two" forSegment:1]; [cell setLabel:@"Three" forSegment:2];
        return cell;
    }
    if ([className isEqualToString:@"NSPopUpButtonCell"])
        return [[[NSPopUpButtonCell alloc] initTextCell:@"Finch" pullsDown:NO] autorelease];
    if ([className isEqualToString:@"NSComboBoxCell"]) {
        NSComboBoxCell *cell = [[[NSComboBoxCell alloc] initTextCell:@"Finch"] autorelease];
        [cell addItemsWithObjectValues:@[@"One", @"Two", @"Three"]];
        return cell;
    }
    if ([className isEqualToString:@"NSLevelIndicatorCell"])
        return [[[NSLevelIndicatorCell alloc] init] autorelease];
    if ([className isEqualToString:@"NSTextFieldCell"])
        return [[[NSTextFieldCell alloc] initTextCell:@"Finch"] autorelease];
    if ([className isEqualToString:@"NSImageCell"])
        return [[[NSImageCell alloc] initImageCell:auto_image()] autorelease];
    if ([className isEqualToString:@"NSMenuItem"])
        return [[[NSMenuItem alloc] initWithTitle:@"Finch" action:NULL keyEquivalent:@"f"] autorelease];
    if ([className isEqualToString:@"NSMenu"])
        return [[[NSMenu alloc] initWithTitle:@"Finch"] autorelease];
    if ([className isEqualToString:@"NSTableColumn"])
        return [[[NSTableColumn alloc] initWithIdentifier:@"Finch"] autorelease];
    if ([className isEqualToString:@"NSFont"]) return [NSFont systemFontOfSize:13];
    if ([className isEqualToString:@"NSFontDescriptor"]) return [[NSFont systemFontOfSize:13] fontDescriptor];
    if ([className isEqualToString:@"NSFontManager"]) return [NSFontManager sharedFontManager];
    if ([className isEqualToString:@"NSBezierPath"]) return [NSBezierPath bezierPathWithRect:NSMakeRect(1, 2, 8, 6)];
    if ([className isEqualToString:@"NSAffineTransform"]) return [[[NSAffineTransform alloc] init] autorelease];
    if ([className isEqualToString:@"NSImage"]) return auto_image();
    if ([className isEqualToString:@"NSImageRep"] || [className isEqualToString:@"NSBitmapImageRep"]) return auto_bitmap();
    if ([className isEqualToString:@"NSParagraphStyle"]) return [NSParagraphStyle defaultParagraphStyle];
    if ([className isEqualToString:@"NSMutableParagraphStyle"])
        return [[NSParagraphStyle defaultParagraphStyle] mutableCopy];
    if ([className isEqualToString:@"NSTextTab"])
        return [[[NSTextTab alloc] initWithType:NSLeftTabStopType location:36] autorelease];
    if ([className isEqualToString:@"NSShadow"]) return [[[NSShadow alloc] init] autorelease];
    if ([className isEqualToString:@"NSGradient"])
        return [[[NSGradient alloc] initWithStartingColor:auto_color(1) endingColor:auto_color(3)] autorelease];
    if ([className isEqualToString:@"NSCursor"]) return [NSCursor arrowCursor];
    if ([className isEqualToString:@"NSAppearance"]) return [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    if ([className isEqualToString:@"NSEvent"]) return auto_event();
    if ([className isEqualToString:@"NSTextStorage"]) return auto_text_storage();
    if ([className isEqualToString:@"NSLayoutManager"]) return auto_text_layout_manager();
    if ([className isEqualToString:@"NSTextContainer"]) return auto_text_container();
    if ([className isEqualToString:@"NSTextView"]) return auto_text_view();
    if ([className isEqualToString:@"NSScrollView"])
        return [[[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 160, 96)] autorelease];
    if ([className isEqualToString:@"NSView"]) return auto_layout_view();
    if ([className isEqualToString:@"NSLayoutConstraint"]) return auto_constraint();
    if ([className isEqualToString:@"NSLayoutAnchor"] || [className isEqualToString:@"NSLayoutXAxisAnchor"])
        return auto_layout_view().leadingAnchor;
    if ([className isEqualToString:@"NSLayoutYAxisAnchor"]) return auto_layout_view().topAnchor;
    if ([className isEqualToString:@"NSLayoutDimension"]) return auto_layout_view().widthAnchor;
    if ([className isEqualToString:@"NSLayoutGuide"]) return [[[NSLayoutGuide alloc] init] autorelease];
    if ([className isEqualToString:@"NSPasteboard"]) return auto_private_pasteboard(selectorName);
    if ([className isEqualToString:@"NSPrintInfo"]) return [[[NSPrintInfo alloc] initWithDictionary:@{
        NSPrintPaperName:@"na-letter", NSPrintPaperSize:[NSValue valueWithSize:NSMakeSize(612, 792)],
        NSPrintLeftMargin:@12, NSPrintRightMargin:@12, NSPrintTopMargin:@18, NSPrintBottomMargin:@24
    }] autorelease];
    if ([className isEqualToString:@"NSAttributedString"])
        return [[[NSAttributedString alloc] initWithString:@"Finch café🙂" attributes:@{NSFontAttributeName:[NSFont systemFontOfSize:12]}] autorelease];
    if ([className isEqualToString:@"NSMutableAttributedString"])
        return [[[NSMutableAttributedString alloc] initWithString:@"Finch café🙂" attributes:@{NSFontAttributeName:[NSFont systemFontOfSize:12]}] autorelease];
#endif
#ifdef FINCH_DIFFTEST_CORESPOTLIGHT
    if ([className isEqualToString:@"CSSearchableItemAttributeSet"])
        return auto_object(@"CSSearchableItemAttributeSet *", 2);
    if ([className isEqualToString:@"CSSearchableItem"])
        return auto_object(@"CSSearchableItem *", 2);
    if ([className isEqualToString:@"CSLocalizedString"])
        return auto_object(@"CSLocalizedString *", 2);
    if ([className isEqualToString:@"CSPerson"])
        return auto_object(@"CSPerson *", 2);
    if ([className isEqualToString:@"CSCustomAttributeKey"])
        return auto_object(@"CSCustomAttributeKey *", 2);
#endif
#ifdef FINCH_DIFFTEST_AVFAUDIO
    if ([className isEqualToString:@"AVAudioFormat"])
        return auto_object(@"AVAudioFormat *", 2);
    if ([className isEqualToString:@"AVAudioChannelLayout"])
        return auto_object(@"AVAudioChannelLayout *", 2);
    if ([className isEqualToString:@"AVAudioTime"])
        return auto_object(@"AVAudioTime *", 2);
    if ([className isEqualToString:@"AVAudioPCMBuffer"])
        return auto_object(@"AVAudioPCMBuffer *", 2);
#endif
#ifdef FINCH_DIFFTEST_QUARTZCORE
    if ([className hasPrefix:@"CA"]) return auto_object([className stringByAppendingString:@" *"], 2);
#endif
#ifdef FINCH_DIFFTEST_COREIMAGE
    if ([className hasPrefix:@"CI"]) return auto_object([className stringByAppendingString:@" *"], 2);
#endif
#ifdef FINCH_DIFFTEST_UTI
    if ([className isEqualToString:@"UTType"]) return auto_object(@"UTType *", 2);
#endif
#ifdef FINCH_DIFFTEST_CONTACTS
    if ([className hasPrefix:@"CN"]) return auto_object([className stringByAppendingString:@" *"], 2);
#endif
#ifdef FINCH_DIFFTEST_COREDATA
    if ([className hasPrefix:@"NSFetchRequest"] || [className hasPrefix:@"NSEntityDescription"] ||
        [className hasPrefix:@"NSPropertyDescription"] || [className hasPrefix:@"NSAttributeDescription"] ||
        [className hasPrefix:@"NSRelationshipDescription"] || [className hasPrefix:@"NSFetchedPropertyDescription"] ||
        [className hasPrefix:@"NSManagedObjectModel"] || [className hasPrefix:@"NSEntityMapping"] ||
        [className hasPrefix:@"NSPropertyMapping"] || [className hasPrefix:@"NSMappingModel"])
        return auto_object([className stringByAppendingString:@" *"], 2);
    if ([className isEqualToString:@"NSFetchIndexDescription"] ||
        [className isEqualToString:@"NSFetchIndexElementDescription"] ||
        [className isEqualToString:@"NSPersistentStoreDescription"] ||
        [className isEqualToString:@"NSBatchUpdateRequest"] ||
        [className isEqualToString:@"NSBatchDeleteRequest"] || [className isEqualToString:@"NSMergePolicy"])
        return auto_object([className stringByAppendingString:@" *"], 2);
#endif
#ifdef FINCH_DIFFTEST_CORELOCATION
    if ([className hasPrefix:@"CL"]) return auto_object([className stringByAppendingString:@" *"], 2);
#endif
#ifdef FINCH_DIFFTEST_METAL
    if ([className hasPrefix:@"MTL"]) return auto_object([className stringByAppendingString:@" *"], 2);
#endif
    if ([className isEqualToString:@"NSObject"]) {
        if ([selectorName hasPrefix:@"isGreaterThan"] || [selectorName hasPrefix:@"isLessThan"])
            return @2;
        if ([selectorName containsString:@"ForKey"] || [selectorName containsString:@"forKey"] ||
            [selectorName containsString:@"KeyPath"] || [selectorName containsString:@"keyPath"] ||
            [selectorName containsString:@"takeValue"] || [selectorName containsString:@"handleQueryWithUnboundKey"] ||
            [selectorName containsString:@"handleTakeValue:forUnboundKey:"] ||
            [selectorName containsString:@"takeValuesFromDictionary"] || [selectorName containsString:@"insertValue:inPropertyWithKey:"])
            return [[FinchDifftestKVCObject alloc] init];
        return [[NSObject alloc] init];
    }
    if ([className isEqualToString:@"NSString"]) return @"Finch";
    if ([className isEqualToString:@"NSMutableString"]) return [NSMutableString stringWithString:@"Finch"];
    if ([className isEqualToString:@"NSNumber"]) return @1;
    if ([className isEqualToString:@"NSDecimalNumber"]) return [NSDecimalNumber decimalNumberWithString:@"1.25"];
    if ([className isEqualToString:@"NSDate"]) return [NSDate dateWithTimeIntervalSinceReferenceDate:700000000];
    if ([className isEqualToString:@"NSData"]) return [NSData dataWithBytes:"\0\1\xff" length:3];
    if ([className isEqualToString:@"NSMutableData"]) return [NSMutableData dataWithBytes:"\0\1\xff" length:3];
    if ([className isEqualToString:@"NSArray"]) return @[@"a", @1];
    if ([className isEqualToString:@"NSMutableArray"]) return [NSMutableArray arrayWithArray:@[@"a", @1]];
    if ([className isEqualToString:@"NSDictionary"]) return @{@"a":@1};
    if ([className isEqualToString:@"NSMutableDictionary"]) return [NSMutableDictionary dictionaryWithDictionary:@{@"a":@1}];
    if ([className isEqualToString:@"NSSet"]) return [NSSet setWithArray:@[@"a", @1]];
    if ([className isEqualToString:@"NSMutableSet"]) return [NSMutableSet setWithArray:@[@"a", @1]];
    if ([className isEqualToString:@"NSCountedSet"]) return [NSCountedSet setWithArray:@[@"a", @"a", @1]];
    if ([className isEqualToString:@"NSOrderedSet"]) return [NSOrderedSet orderedSetWithArray:@[@"a", @1]];
    if ([className isEqualToString:@"NSMutableOrderedSet"]) return [NSMutableOrderedSet orderedSetWithArray:@[@"a", @1]];
    if ([className isEqualToString:@"NSCalendar"]) {
        NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
        calendar.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        calendar.timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
        return calendar;
    }
    if ([className isEqualToString:@"NSURL"]) return [NSURL URLWithString:@"https://example.invalid/a%20b?q=1#part"];
    if ([className isEqualToString:@"NSURLComponents"]) return [NSURLComponents componentsWithString:@"https://example.invalid/a%20b?q=1#part"];
    if ([className isEqualToString:@"NSLocale"]) return [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    if ([className isEqualToString:@"NSTimeZone"]) return [NSTimeZone timeZoneWithName:@"UTC"];
    if ([className isEqualToString:@"NSCalendar"]) {
        NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
        calendar.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        calendar.timeZone = [NSTimeZone timeZoneWithName:@"UTC"]; return calendar;
    }
    if ([className isEqualToString:@"NSCalendarDate"]) {
        NSCalendarDate *date = [NSCalendarDate dateWithTimeIntervalSinceReferenceDate:700000000];
        [date setTimeZone:[NSTimeZone timeZoneWithName:@"UTC"]]; return date;
    }
    if ([className isEqualToString:@"NSDateInterval"])
        return [[[NSDateInterval alloc] initWithStartDate:[NSDate dateWithTimeIntervalSinceReferenceDate:700000000] duration:3600] autorelease];
    if ([className isEqualToString:@"NSDateFormatter"]) {
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
        formatter.calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss"; return formatter;
    }
    if ([className isEqualToString:@"NSNumberFormatter"]) {
        NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
        formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.numberStyle = NSNumberFormatterDecimalStyle; return formatter;
    }
    if ([className isEqualToString:@"NSCharacterSet"]) return [NSCharacterSet characterSetWithCharactersInString:@"aé中🙂"];
    if ([className isEqualToString:@"NSAttributedString"])
        return [[NSAttributedString alloc] initWithString:@"Finch" attributes:@{@"FinchTest":@"value"}];
    if ([className isEqualToString:@"NSMutableAttributedString"])
        return [[NSMutableAttributedString alloc] initWithString:@"Finch" attributes:@{@"FinchTest":@"value"}];
    if ([className isEqualToString:@"NSPredicate"]) return [NSPredicate predicateWithValue:YES];
    if ([className isEqualToString:@"NSNotificationCenter"]) return [NSNotificationCenter defaultCenter];
    if ([className isEqualToString:@"NSMapTable"]) return [[NSMapTable alloc] initWithKeyOptions:NSPointerFunctionsStrongMemory valueOptions:NSPointerFunctionsStrongMemory capacity:0];
    if ([className isEqualToString:@"NSHashTable"]) return [[NSHashTable alloc] initWithOptions:NSPointerFunctionsStrongMemory capacity:0];
    if ([className isEqualToString:@"NSCache"]) return [[NSCache alloc] init];
    if ([className isEqualToString:@"NSXMLDocument"]) {
        if ([selectorName isEqualToString:@"addChild:"] || [selectorName isEqualToString:@"insertChild:atIndex:"])
            return [[[NSXMLDocument alloc] init] autorelease];
        return [[NSXMLDocument alloc] initWithXMLString:@"<root><item>value</item></root>" options:0 error:NULL];
    }
    if ([className isEqualToString:@"NSXMLElement"]) return [NSXMLElement elementWithName:@"root"];
    if ([className isEqualToString:@"NSRegularExpression"]) return [NSRegularExpression regularExpressionWithPattern:@"Finch" options:0 error:NULL];
    if ([className isEqualToString:@"NSUUID"]) return [[NSUUID alloc] initWithUUIDString:@"68753a44-4d6f-1226-9c60-0050e4c00067"];
    return nil;
}

static NSArray *auto_enum_values(NSDictionary *parameter)
{
    NSArray *values = parameter[@"enum_values"];
    return [values isKindOfClass:NSArray.class] ? values : @[];
}

#ifdef FINCH_DIFFTEST_APPKIT
static BOOL auto_store_appkit_struct(void *destination, NSString *type, NSUInteger index, NSUInteger size)
{
    NSUInteger step = index % 4;
    if ([type containsString:@"NSEdgeInsets"]) {
        NSEdgeInsets value = {1 + step, 2 + step, 3 + step, 4 + step};
        memcpy(destination, &value, MIN(size, sizeof(value))); return YES;
    }
    if ([type containsString:@"NSAffineTransformStruct"]) {
        NSAffineTransformStruct value = {1.25, 0.5, -0.25, 2.0, 3.0 + step, -4.0 + step};
        memcpy(destination, &value, MIN(size, sizeof(value))); return YES;
    }
    if ([type containsString:@"CGAffineTransform"]) {
        CGAffineTransform value = CGAffineTransformMake(1.25, 0.5, -0.25, 2.0, 3.0 + step, -4.0 + step);
        memcpy(destination, &value, MIN(size, sizeof(value))); return YES;
    }
    if ([type containsString:@"NSRect"] || [type containsString:@"CGRect"]) {
        NSRect value = NSMakeRect(step, 2 + step, 5 + step, 7 + step);
        memcpy(destination, &value, MIN(size, sizeof(value))); return YES;
    }
    if ([type containsString:@"NSPoint"] || [type containsString:@"CGPoint"]) {
        NSPoint value = NSMakePoint(step + 1, step - 2);
        memcpy(destination, &value, MIN(size, sizeof(value))); return YES;
    }
    if ([type containsString:@"NSSize"] || [type containsString:@"CGSize"]) {
        NSSize value = NSMakeSize(4 + step, 6 + step);
        memcpy(destination, &value, MIN(size, sizeof(value))); return YES;
    }
    return NO;
}
#endif

static void auto_store_scalar(void *destination, const char *encoding, NSString *type, NSUInteger index,
    NSDictionary *parameter, NSString *className, NSString *selectorName, NSUInteger storageSize)
{
    NSString *clean = auto_clean_type(type);
    NSString *name = [parameter[@"name"] lowercaseString] ?: @"";
    NSArray *enumValues = auto_enum_values(parameter);
    if (([className isEqualToString:@"NSMeasurement"] || [className isEqualToString:@"NSDateComponentsFormatter"] ||
         [className isEqualToString:@"NSEnergyFormatter"]) && (encoding[0] == 'f' || encoding[0] == 'd')) {
        static const double values[] = {0.0, 0.5, 2.0, 42.5};
        double number = values[index % (sizeof(values) / sizeof(values[0]))];
        if (encoding[0] == 'f') { float v = (float)number; memcpy(destination, &v, sizeof(v)); }
        else memcpy(destination, &number, sizeof(number));
        return;
    }
#ifdef FINCH_DIFFTEST_APPKIT
    if (([className isEqualToString:@"NSControl"] || [className isEqualToString:@"NSButton"] ||
         [className isEqualToString:@"NSTextField"] || [className isEqualToString:@"NSComboBox"] ||
         [className isEqualToString:@"NSSegmentedControl"] || [className isEqualToString:@"NSProgressIndicator"] ||
         [className isEqualToString:@"NSBox"] || [className isEqualToString:@"NSSlider"] ||
         [className isEqualToString:@"NSLevelIndicator"] || [className isEqualToString:@"NSGridView"] ||
         [className isEqualToString:@"NSGridRow"] || [className isEqualToString:@"NSGridColumn"] ||
         [className isEqualToString:@"NSRulerView"] || [className isEqualToString:@"NSRulerMarker"]) &&
        (encoding[0] == 'f' || encoding[0] == 'd') &&
        ([name containsString:@"value"] || [name containsString:@"width"] || [name containsString:@"height"] ||
         [name containsString:@"margin"] || [name containsString:@"spacing"] || [name containsString:@"border"] ||
         [name containsString:@"thickness"] || [name containsString:@"increment"] || [name containsString:@"padding"] ||
         [name containsString:@"location"] || [name containsString:@"offset"])) {
        static const double values[] = {0.0, 0.5, 1.0, 4.0, 18.0, 42.5};
        double number = values[index % (sizeof(values) / sizeof(values[0]))];
        if (encoding[0] == 'f') { float v = (float)number; memcpy(destination, &v, sizeof(v)); }
        else memcpy(destination, &number, sizeof(number));
        return;
    }
    if ([className isEqualToString:@"NSView"] && [name isEqualToString:@"priority"] &&
        ([selectorName hasPrefix:@"setContentCompressionResistancePriority:"] ||
         [selectorName hasPrefix:@"setContentHuggingPriority:"])) {
        static const float priorities[] = {250.0f, 500.0f, 750.0f, 1000.0f};
        float value = priorities[index % (sizeof(priorities) / sizeof(priorities[0]))];
        if (encoding[0] == 'd') { double wide = value; memcpy(destination, &wide, sizeof(wide)); }
        else memcpy(destination, &value, sizeof(value));
        return;
    }
    if ([className isEqualToString:@"NSView"] &&
        ([selectorName isEqualToString:@"rotateByAngle:"] || [selectorName isEqualToString:@"setBoundsRotation:"] ||
         [selectorName isEqualToString:@"setFrameRotation:"] || [selectorName isEqualToString:@"setFrameCenterRotation:"])) {
        static const double angles[] = {0, 15, 45, -30};
        double value = angles[index % 4];
        if (encoding[0] == 'f') { float v = (float)value; memcpy(destination, &v, sizeof(v)); }
        else memcpy(destination, &value, sizeof(value));
        return;
    }
    NSSet *valueCells = [NSSet setWithObjects:@"NSButtonCell", @"NSSliderCell", @"NSSegmentedCell",
        @"NSPopUpButtonCell", @"NSComboBoxCell", @"NSLevelIndicatorCell", @"NSTextFieldCell", @"NSImageCell", nil];
    if ([valueCells containsObject:className] && (encoding[0] == 'f' || encoding[0] == 'd')) {
        static const double values[] = {0, 0.25, 0.5, 1, 2, 8};
        double value = values[index % (sizeof(values) / sizeof(values[0]))];
        if (encoding[0] == 'f') { float v = (float)value; memcpy(destination, &v, sizeof(v)); }
        else memcpy(destination, &value, sizeof(value));
        return;
    }
    if ([valueCells containsObject:className] &&
        ([name containsString:@"index"] || [name containsString:@"segment"] ||
         [name containsString:@"numberoftick"] || [name containsString:@"numberofvisible"])) {
        long long values[] = {0, 1, 2};
        memset(destination, 0, storageSize);
        memcpy(destination, &values[index % 3], MIN(storageSize, sizeof(values[0])));
        return;
    }
#endif
    if ([name isEqualToString:@"options"] &&
        ([selectorName containsString:@"enumerate"] || [selectorName containsString:@"passingTest"])) {
        NSUInteger value = 0;
        memcpy(destination, &value, MIN(storageSize, sizeof(value))); return;
    }
#ifdef FINCH_DIFFTEST_AVFAUDIO
    if ([className isEqualToString:@"AVAudioFormat"] && [name containsString:@"samplerate"]) {
        double value = 44100; memcpy(destination, &value, MIN(storageSize, sizeof(value))); return;
    }
    if ([className isEqualToString:@"AVAudioFormat"] && [name containsString:@"channels"]) {
        unsigned int value = 2; memcpy(destination, &value, MIN(storageSize, sizeof(value))); return;
    }
    if ([className isEqualToString:@"AVAudioFormat"] && [name isEqualToString:@"format"]) {
        AVAudioCommonFormat value = AVAudioPCMFormatFloat32;
        memcpy(destination, &value, MIN(storageSize, sizeof(value))); return;
    }
    if ([className isEqualToString:@"AVAudioChannelLayout"] && [name containsString:@"layouttag"]) {
        AudioChannelLayoutTag value = kAudioChannelLayoutTag_Stereo;
        memcpy(destination, &value, MIN(storageSize, sizeof(value))); return;
    }
    if ([className isEqualToString:@"AVAudioTime"] && [name containsString:@"rate"]) {
        double value = 44100; memcpy(destination, &value, MIN(storageSize, sizeof(value))); return;
    }
    if ([className isEqualToString:@"AVAudioTime"] && [name containsString:@"sampletime"]) {
        AVAudioFramePosition value = 128; memcpy(destination, &value, MIN(storageSize, sizeof(value))); return;
    }
    if ([className isEqualToString:@"AVAudioPCMBuffer"] && [name containsString:@"framecapacity"]) {
        AVAudioFrameCount value = 128; memcpy(destination, &value, MIN(storageSize, sizeof(value))); return;
    }
    if ([className isEqualToString:@"AVAudioPCMBuffer"] && [name containsString:@"framelength"]) {
        AVAudioFrameCount value = 32; memcpy(destination, &value, MIN(storageSize, sizeof(value))); return;
    }
#endif
#ifdef FINCH_DIFFTEST_METAL
    if ([className isEqualToString:@"MTLRenderPassDescriptor"] &&
        ([selectorName isEqualToString:@"getSamplePositions:count:"] ||
         [selectorName isEqualToString:@"setSamplePositions:count:"]) && [name isEqualToString:@"count"]) {
        NSUInteger value = index == 7 ? 0 : 4;
        if ([selectorName isEqualToString:@"getSamplePositions:count:"]) value = 0;
        memcpy(destination, &value, MIN(storageSize, sizeof(value))); return;
    }
#endif
    if ([clean containsString:@"NSRange"]) {
        NSRange range = NSMakeRange(0, index % 2);
        if ([className isEqualToString:@"NSOrderedSet"] && [selectorName isEqualToString:@"getObjects:range:"])
            range = NSMakeRange(0, 2);
        else if ([className isEqualToString:@"NSIndexSet"] &&
                 ([selectorName containsString:@"enumerate"] || [selectorName containsString:@"PassingTest"] ||
                  [selectorName containsString:@"passingTest"]))
            range = NSMakeRange(0, 6);
        else if (([className isEqualToString:@"NSString"] || [className isEqualToString:@"NSAttributedString"] ||
                  [className isEqualToString:@"NSRegularExpression"]) &&
                 [selectorName containsString:@"enumerate"])
            range = NSMakeRange(0, 5);
        memcpy(destination, &range, sizeof(range)); return;
    }
    if ([clean containsString:@"CFRange"]) {
        CFRange range = CFRangeMake(0, (CFIndex)(index % 2));
        memcpy(destination, &range, sizeof(range)); return;
    }
#ifdef FINCH_DIFFTEST_CORELOCATION
    if ([clean containsString:@"CLLocationCoordinate2D"]) {
        CLLocationCoordinate2D value = {43.6532 + (double)(index % 2), -79.3832};
        memcpy(destination, &value, MIN(storageSize, sizeof(value))); return;
    }
#endif
#ifdef FINCH_DIFFTEST_COREIMAGE
    if ([className isEqualToString:@"CIQRCodeDescriptor"] || [className isEqualToString:@"CIAztecCodeDescriptor"] ||
        [className isEqualToString:@"CIPDF417CodeDescriptor"] || [className isEqualToString:@"CIDataMatrixCodeDescriptor"]) {
        long long value = 1;
        if ([className isEqualToString:@"CIQRCodeDescriptor"]) {
            if ([name containsString:@"maskpattern"]) value = (long long)(index % 8);
            else if ([name containsString:@"errorcorrectionlevel"]) value = CIQRCodeErrorCorrectionLevelL;
            else if ([name containsString:@"symbolversion"]) value = 1 + (long long)(index % 40);
        } else if ([className isEqualToString:@"CIAztecCodeDescriptor"]) {
            if ([name containsString:@"iscompact"]) value = (long long)(index & 1);
            else if ([name containsString:@"layercount"]) value = 1 + (long long)(index % 4);
            else if ([name containsString:@"datacodewordcount"]) value = 1 + (long long)(index % 16);
        } else if ([className isEqualToString:@"CIPDF417CodeDescriptor"]) {
            if ([name containsString:@"iscompact"]) value = (long long)(index & 1);
            else if ([name containsString:@"rowcount"]) value = 3 + (long long)(index % 20);
            else if ([name containsString:@"columncount"]) value = 1 + (long long)(index % 10);
        } else {
            if ([name containsString:@"rowcount"] || [name containsString:@"columncount"]) value = 10;
            else if ([name containsString:@"eccversion"]) value = CIDataMatrixCodeECCVersion200;
        }
        memcpy(destination, &value, MIN(storageSize, sizeof(value))); return;
    }
#endif
#ifdef FINCH_DIFFTEST_QUARTZCORE
    if ([clean containsString:@"CATransform3D"]) {
        CATransform3D value = CATransform3DIdentity;
        value.m41 = (CGFloat)(index % 3); value.m42 = 2;
        memcpy(destination, &value, MIN(storageSize, sizeof(value))); return;
    }
#endif
#ifdef FINCH_DIFFTEST_METAL
    if ([clean containsString:@"MTL4BufferRange"]) {
        MTL4BufferRange value = MTL4BufferRangeMake(0, 0);
        memcpy(destination, &value, MIN(storageSize, sizeof(value))); return;
    }
    if ([clean containsString:@"MTLSize"]) {
        MTLSize value = MTLSizeMake(8, 4, 1);
        memcpy(destination, &value, MIN(storageSize, sizeof(value))); return;
    }
    if ([clean containsString:@"MTLOrigin"]) {
        MTLOrigin value = MTLOriginMake(1, 2, 0);
        memcpy(destination, &value, MIN(storageSize, sizeof(value))); return;
    }
    if ([clean containsString:@"MTLRegion"]) {
        MTLRegion value = MTLRegionMake2D(1, 2, 8, 4);
        memcpy(destination, &value, MIN(storageSize, sizeof(value))); return;
    }
    if ([clean containsString:@"MTLClearColor"]) {
        MTLClearColor value = MTLClearColorMake(0.25, 0.5, 0.75, 1.0);
        memcpy(destination, &value, MIN(storageSize, sizeof(value))); return;
    }
    if ([clean containsString:@"MTLSamplePosition"]) {
        MTLSamplePosition value = {0.25f, 0.75f};
        memcpy(destination, &value, MIN(storageSize, sizeof(value))); return;
    }
#endif
    if ([clean containsString:@"NSOperatingSystemVersion"]) {
        NSOperatingSystemVersion value = {15, 0, 1};
        memcpy(destination, &value, MIN(storageSize, sizeof(value))); return;
    }
#ifdef FINCH_DIFFTEST_APPKIT
    if ([className isEqualToString:@"NSBezierPath"] && [clean containsString:@"Point"]) {
        static const NSPoint points[] = {{0, 0}, {10, 0}, {10, 10}, {0, 10}, {4, 6}};
        NSPoint point = points[index % (sizeof(points) / sizeof(points[0]))];
        memcpy(destination, &point, MIN(storageSize, sizeof(point))); return;
    }
#endif
    if ([clean containsString:@"Point"] || [clean containsString:@"Size"] || [clean containsString:@"Rect"] || [clean containsString:@"Transform"]) {
#ifdef FINCH_DIFFTEST_APPKIT
        if (auto_store_appkit_struct(destination, clean, index, storageSize)) return;
#endif
        memset(destination, 0, storageSize); return;
    }
#ifdef FINCH_DIFFTEST_APPKIT
    if ([className isEqualToString:@"NSColor"] &&
        ([name containsString:@"red"] || [name containsString:@"green"] || [name containsString:@"blue"] || [name containsString:@"alpha"])) {
        static const double values[] = {0, 0.25, 0.5, 0.75, 1, 0.1, 0.9, 0.35};
        NSUInteger offset = [name containsString:@"red"] ? 0 : [name containsString:@"green"] ? 2 :
            [name containsString:@"blue"] ? 4 : 1;
        double value = values[(index + offset) % 8];
        if (encoding[0] == 'f') { float v = (float)value; memcpy(destination, &v, sizeof(v)); }
        else memcpy(destination, &value, sizeof(value));
        return;
    }
    if ([className isEqualToString:@"NSColor"] &&
        ([name containsString:@"level"] || [selectorName containsString:@"highlightWithLevel"] ||
         [selectorName containsString:@"shadowWithLevel"])) {
        static const double levels[] = {0, 0.25, 0.5, 0.75, 1};
        double value = levels[index % 5];
        if (encoding[0] == 'f') { float v = (float)value; memcpy(destination, &v, sizeof(v)); }
        else memcpy(destination, &value, sizeof(value));
        return;
    }
    if ([className isEqualToString:@"NSColor"] && [name containsString:@"headroom"]) {
        static const double headroom[] = {1, 1.5, 2, 4};
        double value = headroom[index % 4];
        if (encoding[0] == 'f') { float v = (float)value; memcpy(destination, &v, sizeof(v)); }
        else memcpy(destination, &value, sizeof(value));
        return;
    }
    if ([className isEqualToString:@"NSFont"] && [name containsString:@"size"]) {
        static const double sizes[] = {12, 13, 18, 24};
        double value = sizes[index % 4];
        if (encoding[0] == 'f') { float v = (float)value; memcpy(destination, &v, sizeof(v)); }
        else memcpy(destination, &value, sizeof(value));
        return;
    }
    if ([className isEqualToString:@"NSBezierPath"] &&
        ([name containsString:@"width"] || [name containsString:@"flatness"] || [name containsString:@"miter"])) {
        static const double values[] = {0, 0.5, 1, 2};
        double value = values[index % 4];
        if (encoding[0] == 'f') { float v = (float)value; memcpy(destination, &v, sizeof(v)); }
        else memcpy(destination, &value, sizeof(value));
        return;
    }
    if ([className isEqualToString:@"NSBezierPath"] && [name containsString:@"radius"]) {
        static const double radii[] = {0, 1, 4, 10};
        double value = radii[index % 4];
        if (encoding[0] == 'f') { float v = (float)value; memcpy(destination, &v, sizeof(v)); }
        else memcpy(destination, &value, sizeof(value));
        return;
    }
    if ([className isEqualToString:@"NSBezierPath"] && [name containsString:@"angle"]) {
        static const double angles[] = {0, 45, 90, 180, 270, 360};
        double value = angles[index % 6];
        if (encoding[0] == 'f') { float v = (float)value; memcpy(destination, &v, sizeof(v)); }
        else memcpy(destination, &value, sizeof(value));
        return;
    }
    if ([className isEqualToString:@"NSGradient"] && [name containsString:@"location"]) {
        static const double locations[] = {0, 0.25, 0.5, 0.75, 1};
        double value = locations[index % 5];
        if (encoding[0] == 'f') { float v = (float)value; memcpy(destination, &v, sizeof(v)); }
        else memcpy(destination, &value, sizeof(value));
        return;
    }
    if ([className isEqualToString:@"NSImage"] && [name containsString:@"scale"]) {
        static const double scales[] = {0.5, 1, 2, 4};
        double value = scales[index % 4];
        if (encoding[0] == 'f') { float v = (float)value; memcpy(destination, &v, sizeof(v)); }
        else memcpy(destination, &value, sizeof(value));
        return;
    }
    /* The SDK names these two arguments `m` and `c`; their selector labels
       carry the useful names. Without this check, `m` gets the generic 0.0. */
    BOOL layoutMultiplier = [name containsString:@"multiplier"] ||
        ([name isEqualToString:@"m"] && [selectorName containsString:@"multiplier"]);
    BOOL layoutConstant = [name containsString:@"constant"] ||
        ([name isEqualToString:@"c"] && [selectorName containsString:@"constant"]);
    if ([className hasPrefix:@"NSLayout"] &&
        (layoutMultiplier || layoutConstant || [name containsString:@"spacing"])) {
        static const double values[] = {0, 1, -1, 2, 8};
        double value = values[index % 5];
        if (layoutMultiplier) value = index % 2 ? 2 : 1;
        if (encoding[0] == 'f') { float v = (float)value; memcpy(destination, &v, sizeof(v)); }
        else memcpy(destination, &value, sizeof(value));
        return;
    }
    if ([className isEqualToString:@"NSBitmapImageRep"] &&
        ([name containsString:@"pixelswide"] || [name containsString:@"pixelshigh"])) {
        long long value = 2 + (long long)(index % 3);
        memset(destination, 0, storageSize); memcpy(destination, &value, MIN(storageSize, sizeof(value))); return;
    }
    if ([className isEqualToString:@"NSBitmapImageRep"] && [name containsString:@"bitspersample"]) {
        long long value = 8; memset(destination, 0, storageSize); memcpy(destination, &value, MIN(storageSize, sizeof(value))); return;
    }
    if ([className isEqualToString:@"NSBitmapImageRep"] && [name containsString:@"samplesperpixel"]) {
        long long value = 4; memset(destination, 0, storageSize); memcpy(destination, &value, MIN(storageSize, sizeof(value))); return;
    }
    if ([className isEqualToString:@"NSBitmapImageRep"] && [name containsString:@"bytesperrow"]) {
        long long value = 16; memset(destination, 0, storageSize); memcpy(destination, &value, MIN(storageSize, sizeof(value))); return;
    }
    if ([className isEqualToString:@"NSBitmapImageRep"] && [name containsString:@"bitsperpixel"]) {
        long long value = 32; memset(destination, 0, storageSize); memcpy(destination, &value, MIN(storageSize, sizeof(value))); return;
    }
    if ([className isEqualToString:@"NSBitmapImageRep"] && [name containsString:@"x"] && ![name containsString:@"index"]) {
        long long value = (long long)(index % 2); memset(destination, 0, storageSize); memcpy(destination, &value, MIN(storageSize, sizeof(value))); return;
    }
    if ([className isEqualToString:@"NSEvent"] && [name containsString:@"timestamp"]) {
        double value = 1.25 + (double)(index % 3); memcpy(destination, &value, MIN(storageSize, sizeof(value))); return;
    }
    if ([className isEqualToString:@"NSEvent"] && [name containsString:@"type"]) {
        unsigned long long value = [selectorName containsString:@"mouseEvent"] ? NSEventTypeLeftMouseDown : NSEventTypeApplicationDefined;
        memset(destination, 0, storageSize); memcpy(destination, &value, MIN(storageSize, sizeof(value))); return;
    }
    if ([className isEqualToString:@"NSEvent"] && [name containsString:@"windownumber"]) {
        long long value = 0; memset(destination, 0, storageSize); memcpy(destination, &value, MIN(storageSize, sizeof(value))); return;
    }
    if ([className isEqualToString:@"NSPrintInfo"] && [name containsString:@"margin"]) {
        static const double values[] = {0, 1, 12, 24};
        double value = values[index % 4];
        if (encoding[0] == 'f') { float v = (float)value; memcpy(destination, &v, sizeof(v)); }
        else memcpy(destination, &value, sizeof(value));
        return;
    }
    if ([className isEqualToString:@"NSPrintInfo"] && [name containsString:@"scalingfactor"]) {
        static const double values[] = {0, 0.5, 1, 2};
        double value = values[index % 4];
        if (encoding[0] == 'f') { float v = (float)value; memcpy(destination, &v, sizeof(v)); }
        else memcpy(destination, &value, sizeof(value));
        return;
    }
    if ([className isEqualToString:@"NSCell"] &&
        [selectorName isEqualToString:@"setFloatingPointFormat:left:right:"] &&
        ([name isEqualToString:@"leftdigits"] || [name isEqualToString:@"rightdigits"])) {
        NSUInteger value = 2; memcpy(destination, &value, MIN(storageSize, sizeof(value))); return;
    }
#endif
    if ([className isEqualToString:@"NSDateInterval"] && [name containsString:@"duration"]) {
        static const double values[] = {0.0, 1.0, 60.0, 3600.0};
        double value = values[index % 4];
        if (encoding[0] == 'f') { float v = (float)value; memcpy(destination, &v, sizeof(v)); }
        else memcpy(destination, &value, sizeof(value));
        return;
    }
    if (encoding[0] == 'f' || encoding[0] == 'd') {
        static const double values[] = {0.0, -0.0, INFINITY, -INFINITY, NAN, 0x1p-1074, 0.5};
        static const double timeValues[] = {0.0, -1.0, 700000000.0, 800000000.0, 1000000000.0, 123456789.0, 31536000.0, 86400.0};
        BOOL timeType = [clean containsString:@"AbsoluteTime"] || [clean containsString:@"TimeInterval"];
        double number = timeType ? timeValues[index % 8] : values[index % 7];
#ifdef FINCH_DIFFTEST_APPKIT
        if ([className hasPrefix:@"NSLayout"] && !isfinite(number)) number = 0;
#endif
        if (encoding[0] == 'f') { float v = (float)number; memcpy(destination, &v, sizeof(v)); }
        else memcpy(destination, &number, sizeof(number));
        return;
    }
    if ([className isEqualToString:@"NSString"] &&
        [selectorName isEqualToString:@"initWithCharactersNoCopy:length:freeWhenDone:"] &&
        [name isEqualToString:@"freebuffer"]) {
        unsigned char value = 0; memcpy(destination, &value, MIN(storageSize, sizeof(value))); return;
    }
    if (encoding[0] == 'B' || [clean isEqualToString:@"BOOL"] || [clean isEqualToString:@"Boolean"] || [clean isEqualToString:@"bool"]) {
        unsigned char v = (unsigned char)(index & 1); memcpy(destination, &v, sizeof(v)); return;
    }
    if ([className isEqualToString:@"NSCalendar"] && [name isEqualToString:@"firstweekday"]) {
        long long values[] = {1, 2, 7}; NSUInteger size = 0; NSGetSizeAndAlignment(encoding, &size, NULL);
        memset(destination, 0, size); memcpy(destination, &values[index % 3], MIN(size, sizeof(long long))); return;
    }
    if ([className isEqualToString:@"NSCalendar"] &&
        [selectorName containsString:@"dateBySettingHour"] && [name isEqualToString:@"opts"]) {
        long long value = 0; NSUInteger size = 0; NSGetSizeAndAlignment(encoding, &size, NULL);
        memset(destination, 0, size); memcpy(destination, &value, MIN(size, sizeof(value))); return;
    }
    if ([className isEqualToString:@"NSXMLDocument"] && [name containsString:@"index"] &&
        ([selectorName containsString:@"ChildAtIndex"] || [selectorName containsString:@"insertChild"])) {
        long long value = 0; NSUInteger size = 0; NSGetSizeAndAlignment(encoding, &size, NULL);
        memset(destination, 0, size); memcpy(destination, &value, MIN(size, sizeof(value))); return;
    }
    if ([selectorName containsString:@"descriptionWithLocale"] && [name isEqualToString:@"level"]) {
        long long values[] = {0, 1, 2}; NSUInteger size = 0; NSGetSizeAndAlignment(encoding, &size, NULL);
        memset(destination, 0, size); memcpy(destination, &values[index % 3], MIN(size, sizeof(long long))); return;
    }
    if ([className isEqualToString:@"NSCalendarDate"] &&
        ([name containsString:@"year"] || [name containsString:@"month"] || [name containsString:@"day"] ||
         [name containsString:@"hour"] || [name containsString:@"minute"] || [name containsString:@"second"])) {
        long long value = [name containsString:@"year"] ? 2001 : [name containsString:@"month"] ? 1 :
            [name containsString:@"day"] ? 2 : [name containsString:@"hour"] ? 3 :
            [name containsString:@"minute"] ? 4 : 5;
        NSUInteger size = 0; NSGetSizeAndAlignment(encoding, &size, NULL);
        memset(destination, 0, size); memcpy(destination, &value, MIN(size, sizeof(value))); return;
    }
    if ([className isEqualToString:@"NSCalendar"] && [name hasSuffix:@"value"]) {
        long long values[] = {1, 2001, 1, 2, 12, 34, 56, 0};
        NSUInteger position = [name containsString:@"era"] ? 0 : [name containsString:@"year"] ? 1 :
            [name containsString:@"month"] ? 2 : [name containsString:@"day"] ? 3 :
            [name containsString:@"hour"] ? 4 : [name containsString:@"minute"] ? 5 :
            [name containsString:@"second"] ? 6 : 7;
        long long value = values[position]; NSUInteger size = 0; NSGetSizeAndAlignment(encoding, &size, NULL);
        memset(destination, 0, size); memcpy(destination, &value, MIN(size, sizeof(value))); return;
    }
    if ([className isEqualToString:@"NSCalendar"] &&
        [selectorName containsString:@"dateBySettingHour"] &&
        ([name isEqualToString:@"h"] || [name isEqualToString:@"m"] || [name isEqualToString:@"s"] ||
         [name isEqualToString:@"hour"] || [name isEqualToString:@"minute"] || [name isEqualToString:@"second"])) {
        BOOL isHour = [name isEqualToString:@"h"] || [name isEqualToString:@"hour"];
        BOOL isMinute = [name isEqualToString:@"m"] || [name isEqualToString:@"minute"];
        long long values[] = {0, 1, isHour ? 12 : isMinute ? 34 : 56};
        long long value = values[index % 3]; NSUInteger size = 0; NSGetSizeAndAlignment(encoding, &size, NULL);
        memset(destination, 0, size); memcpy(destination, &value, MIN(size, sizeof(value))); return;
    }
    if ([name hasPrefix:@"idx"] || [name containsString:@"index"] || [name containsString:@"location"] ||
        [name containsString:@"offset"] || [name containsString:@"position"] || [name containsString:@"start"] ||
        [name containsString:@"end"] || [name isEqualToString:@"loc"]) {
        long long values[] = {0, 1}; NSUInteger size = 0; NSGetSizeAndAlignment(encoding, &size, NULL);
        memset(destination, 0, size); memcpy(destination, &values[index % 2], MIN(size, sizeof(long long))); return;
    }
    if ([name containsString:@"power"]) {
        long long values[] = {0, 1, 2, 3}; NSUInteger size = 0; NSGetSizeAndAlignment(encoding, &size, NULL);
        memset(destination, 0, size); memcpy(destination, &values[index % 4], MIN(size, sizeof(long long))); return;
    }
    if ([name containsString:@"length"] || [name containsString:@"count"] || [name isEqualToString:@"cnt"] || [name isEqualToString:@"len"] || [name containsString:@"capacity"] ||
        [name containsString:@"num"] ||
        [name containsString:@"size"] || [name containsString:@"limit"] || [name containsString:@"bufferlen"] ||
        [name containsString:@"indent"]) {
        long long values[] = {0, 1, 2}; NSUInteger size = 0; NSGetSizeAndAlignment(encoding, &size, NULL);
        memset(destination, 0, size); memcpy(destination, &values[index % 3], MIN(size, sizeof(long long))); return;
    }
    if ([name containsString:@"scale"]) {
        long long values[] = {-2, 0, 2}; NSUInteger size = 0; NSGetSizeAndAlignment(encoding, &size, NULL);
        memset(destination, 0, size); memcpy(destination, &values[index % 3], MIN(size, sizeof(long long))); return;
    }
    if ([name containsString:@"hour"] || [name containsString:@"minute"] || [name containsString:@"second"] ||
        [name containsString:@"month"] || [name containsString:@"day"] || [name containsString:@"year"] ||
        [name isEqualToString:@"value"]) {
        long long values[] = {0, 1, -1, 2}; NSUInteger size = 0; NSGetSizeAndAlignment(encoding, &size, NULL);
        memset(destination, 0, size); memcpy(destination, &values[index % 4], MIN(size, sizeof(long long))); return;
    }
    if ([clean containsString:@"Encoding"] || [name containsString:@"encoding"]) {
        unsigned long values[] = {NSUTF8StringEncoding, NSASCIIStringEncoding,
            NSISOLatin1StringEncoding, NSMacOSRomanStringEncoding};
        NSUInteger size = 0; NSGetSizeAndAlignment(encoding, &size, NULL); memset(destination, 0, size);
        memcpy(destination, &values[index % 4], MIN(size, sizeof(unsigned long))); return;
    }
    if ([name containsString:@"mantissa"]) {
        unsigned long long values[] = {0, 1, 125, 99999};
        NSUInteger size = 0; NSGetSizeAndAlignment(encoding, &size, NULL); memset(destination, 0, size);
        memcpy(destination, &values[index % 4], MIN(size, sizeof(unsigned long long))); return;
    }
    if ([clean isEqualToString:@"NSPointerFunctionsOptions"]) enumValues = @[@0];
    if (enumValues.count) {
        long long value = [enumValues[index % enumValues.count] longLongValue];
        NSUInteger size = 0; NSGetSizeAndAlignment(encoding, &size, NULL); memset(destination, 0, size);
        memcpy(destination, &value, MIN(size, sizeof(value))); return;
    }
    long long signedValues[] = {0, 1, -1, 2, LLONG_MAX, LLONG_MIN, -2};
    unsigned long long unsignedValues[] = {0, 1, 2, 255, 65535, UINT_MAX, ULLONG_MAX};
    NSUInteger size = 0; NSGetSizeAndAlignment(encoding, &size, NULL); memset(destination, 0, size);
    if (strchr("CISLQ", encoding[0])) {
        unsigned long long value = unsignedValues[index % 7]; memcpy(destination, &value, MIN(size, sizeof(value)));
    } else {
        long long value = signedValues[index % 7]; memcpy(destination, &value, MIN(size, sizeof(value)));
    }
}

static void auto_invoke(NSInvocation *invocation)
{
#ifdef FINCH_DIFFTEST_APPKIT
    NSAppearance *appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    if (appearance) {
        [appearance performAsCurrentDrawingAppearance:^{ [invocation invoke]; }];
        return;
    }
#endif
    [invocation invoke];
}

static void auto_test_method(NSDictionary *item)
{
    NSString *className = item[@"class"];
    NSString *selectorName = item[@"selector"];
    SEL selector = NSSelectorFromString(selectorName);
    BOOL classMethod = [item[@"class_method"] boolValue];
    Class cls = NSClassFromString(className);
    id classOrReceiver = classMethod ? (id)cls : auto_receiver(className, selectorName);
    if (!classOrReceiver) { puts("0\tnot-exercised:no-safe-receiver"); return; }
    NSMethodSignature *signature = [classOrReceiver methodSignatureForSelector:selector];
    if (!signature) { puts("0\tno-method-signature"); return; }
    NSArray *parameters = item[@"parameters"];
    NSUInteger argumentCount = signature.numberOfArguments > 2 ? signature.numberOfArguments - 2 : 0;
    NSUInteger cases = argumentCount ? 8 : 1;
    for (NSUInteger caseIndex = 0; caseIndex < cases; caseIndex++) {
        @autoreleasepool {
            auto_callback_output = [NSMutableArray array];
            auto_callback_was_used = NO;
            id receiver = classMethod ? (id)cls : auto_receiver(className, selectorName);
            if (!receiver) { printf("%lu\tnot-exercised:no-safe-receiver\n", (unsigned long)caseIndex); continue; }
            NSMethodSignature *sig = [receiver methodSignatureForSelector:selector];
            if (!sig) { printf("%lu\tno-method-signature\n", (unsigned long)caseIndex); continue; }
            NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:sig];
            invocation.target = receiver; invocation.selector = selector;
            NSMutableArray *outputPointers = [NSMutableArray array];
            NSMutableArray *argumentObjects = [NSMutableArray arrayWithCapacity:argumentCount];
            BOOL hasSafeInputs = YES;
            for (NSUInteger argIndex = 0; argIndex < argumentCount; argIndex++) {
                NSDictionary *parameter = argIndex < parameters.count ? parameters[argIndex] : @{};
                NSString *type = parameter[@"type"] ?: @"id";
                const char *encoding = [sig getArgumentTypeAtIndex:argIndex + 2];
                while (strchr("rnNoORV", encoding[0])) encoding++;
                if ([className isEqualToString:@"NSUUID"] &&
                    [selectorName isEqualToString:@"getUUIDBytes:"] &&
                    [parameter[@"name"] isEqualToString:@"uuid"]) {
                    void *storage = calloc(16, 1);
                    if (!storage) { hasSafeInputs = NO; void *value = NULL; [invocation setArgument:&value atIndex:argIndex + 2]; continue; }
                    void *value = storage; [argumentObjects addObject:NSNull.null];
                    [invocation setArgument:&value atIndex:argIndex + 2];
                    [outputPointers addObject:@{ @"type":type, @"storage":[NSValue valueWithPointer:storage], @"size":@16 }];
                    continue;
                }
                if ([className isEqualToString:@"NSUUID"] &&
                    [selectorName isEqualToString:@"initWithUUIDBytes:"] &&
                    [parameter[@"name"] isEqualToString:@"bytes"]) {
                    static const unsigned char uuidBytes[16] = {0x68, 0x75, 0x3a, 0x44, 0x4d, 0x6f, 0x12, 0x26, 0x9c, 0x60, 0x00, 0x50, 0xe4, 0xc0, 0x00, 0x67};
                    void *value = (void *)uuidBytes; [argumentObjects addObject:NSNull.null];
                    [invocation setArgument:&value atIndex:argIndex + 2]; continue;
                }
#ifdef FINCH_DIFFTEST_APPKIT
                if ([className isEqualToString:@"NSBitmapImageRep"] &&
                    [selectorName hasPrefix:@"initWithBitmapDataPlanes:"] &&
                    [[parameter[@"name"] lowercaseString] isEqualToString:@"planes"]) {
                    void *value = NULL; [argumentObjects addObject:NSNull.null];
                    [invocation setArgument:&value atIndex:argIndex + 2]; continue;
                }
                if ([className isEqualToString:@"NSBitmapImageRep"] &&
                    [selectorName isEqualToString:@"getPixel:atX:y:"] &&
                    [[parameter[@"name"] lowercaseString] isEqualToString:@"p"]) {
                    NSUInteger *storage = calloc(4, sizeof(NSUInteger));
                    if (!storage) { hasSafeInputs = NO; void *value = NULL; [invocation setArgument:&value atIndex:argIndex + 2]; continue; }
                    void *value = storage; [argumentObjects addObject:NSNull.null];
                    [invocation setArgument:&value atIndex:argIndex + 2];
                    [outputPointers addObject:@{@"type":type, @"storage":[NSValue valueWithPointer:storage],
                        @"size":@(4 * sizeof(NSUInteger)), @"kind":@"pixel-array"}];
                    continue;
                }
                if ([className isEqualToString:@"NSBitmapImageRep"] &&
                    [selectorName isEqualToString:@"setPixel:atX:y:"] &&
                    [[parameter[@"name"] lowercaseString] isEqualToString:@"p"]) {
                    static NSUInteger pixels[4] = {17, 33, 65, 255};
                    void *value = pixels; [argumentObjects addObject:NSNull.null];
                    [invocation setArgument:&value atIndex:argIndex + 2]; continue;
                }
#endif
                if (encoding[0] == '@') {
                    id value = nil;
                    if (encoding[1] == '?' || [type containsString:@"(^"]) {
                        if ([parameter[@"name"] localizedCaseInsensitiveContainsString:@"comparator"] ||
                            [selectorName localizedCaseInsensitiveContainsString:@"comparator"]) {
                            NSComparator comparator = ^NSComparisonResult(id a, id b) { return [[a description] compare:[b description]]; };
                            value = [comparator copy];
                        } else hasSafeInputs = NO;
                    } else {
                        value = auto_method_object(type, parameter[@"name"] ?: @"", className,
                            selectorName, caseIndex + argIndex);
                        if ([parameter[@"nullable"] boolValue] && caseIndex == 7) value = nil;
                        if (!value && [parameter[@"nullable"] boolValue]) value = NSNull.null;
                    }
                    if (!value && ![parameter[@"nullable"] boolValue]) hasSafeInputs = NO;
                    [argumentObjects addObject:value ?: NSNull.null];
                    if (value == NSNull.null) value = nil;
                    [invocation setArgument:&value atIndex:argIndex + 2];
                    continue;
                }
                if (encoding[0] == '#') {
                    Class value = NSClassFromString([type containsString:@"*"] ? [type componentsSeparatedByString:@"*"][0] : @"NSObject");
                    if (!value) value = NSObject.class;
                    [argumentObjects addObject:value];
                    [invocation setArgument:&value atIndex:argIndex + 2]; continue;
                }
                if (encoding[0] == ':') {
                    SEL value = [className isEqualToString:@"NSComparisonPredicate"] &&
                        [selectorName containsString:@"customSelector"] ? @selector(compare:) : @selector(description);
                    [argumentObjects addObject:NSNull.null]; [invocation setArgument:&value atIndex:argIndex + 2]; continue;
                }
                if (encoding[0] == '^' || encoding[0] == '*') {
                    NSString *parameterName = parameter[@"name"] ?: @"";
                    NSString *direction = parameter[@"direction"] ?: @"unspecified";
#ifdef FINCH_DIFFTEST_METAL
                    if ([className isEqualToString:@"MTLRenderPassDescriptor"] &&
                        [selectorName isEqualToString:@"getSamplePositions:count:"] &&
                        [parameterName isEqualToString:@"positions"]) {
                        if (caseIndex == 7) {
                            void *value = NULL; [argumentObjects addObject:NSNull.null];
                            [invocation setArgument:&value atIndex:argIndex + 2];
                        } else {
                            MTLSamplePosition *storage = calloc(1, sizeof(MTLSamplePosition));
                            if (!storage) { hasSafeInputs = NO; void *value = NULL; [invocation setArgument:&value atIndex:argIndex + 2]; continue; }
                            void *value = storage; [argumentObjects addObject:NSNull.null];
                            [invocation setArgument:&value atIndex:argIndex + 2];
                            [outputPointers addObject:@{@"type":type, @"storage":[NSValue valueWithPointer:storage], @"size":@(sizeof(MTLSamplePosition)), @"kind":@"sample-position-array", @"count":@0}];
                        }
                        continue;
                    }
                    if ([className isEqualToString:@"MTLRenderPassDescriptor"] &&
                        [selectorName isEqualToString:@"setSamplePositions:count:"] &&
                        [parameterName isEqualToString:@"positions"]) {
                        if (caseIndex == 7) {
                            void *value = NULL; [argumentObjects addObject:NSNull.null];
                            [invocation setArgument:&value atIndex:argIndex + 2];
                        } else {
                            NSMutableData *backing = [NSMutableData dataWithLength:4 * sizeof(MTLSamplePosition)];
                            MTLSamplePosition *positions = backing.mutableBytes;
                            for (NSUInteger i = 0; i < 4; i++) {
                                positions[i].x = (float)(i + 1) / 5.0f;
                                positions[i].y = (float)(4 - i) / 5.0f;
                            }
                            void *value = positions; [argumentObjects addObject:backing];
                            [invocation setArgument:&value atIndex:argIndex + 2];
                        }
                        continue;
                    }
#endif
                    BOOL outputName = [parameterName rangeOfString:@"(?:error|out|result|start|end|length|location|range|count|offset|used|remaining|destination|response|buffer|characters)" options:NSRegularExpressionSearch | NSCaseInsensitiveSearch].location != NSNotFound;
                    BOOL noCopyCharacters = [className isEqualToString:@"NSString"] &&
                        [selectorName isEqualToString:@"initWithCharactersNoCopy:length:freeWhenDone:"] &&
                        [parameterName.lowercaseString isEqualToString:@"characters"];
                    if (noCopyCharacters) outputName = NO;
                    if ([className isEqualToString:@"NSDateFormatter"] &&
                        [selectorName isEqualToString:@"getObjectValue:forString:range:error:"] &&
                        [parameterName.lowercaseString isEqualToString:@"obj"]) outputName = YES;
                    if ([className isEqualToString:@"NSOrderedSet"] &&
                        [selectorName isEqualToString:@"getObjects:range:"] &&
                        [parameterName.lowercaseString isEqualToString:@"objects"]) outputName = YES;
                    BOOL output = [direction isEqualToString:@"out"] || [direction isEqualToString:@"inout"] ||
                        (outputName && ![type containsString:@"const"]);
                    if (noCopyCharacters) output = NO;
                    BOOL uuidMethod = [className isEqualToString:@"NSUUID"];
                    if (noCopyCharacters) {
                        static const unichar characters[] = {'c', 'a', 'f', 0x00e9, 0x0301, 0xd83d, 0xde42};
                        NSMutableData *storage = [NSMutableData dataWithBytes:characters length:sizeof(characters)];
                        void *value = storage.mutableBytes; [argumentObjects addObject:storage];
                        [invocation setArgument:&value atIndex:argIndex + 2]; continue;
                    }
                    if ([className isEqualToString:@"NSOrderedSet"] &&
                        [selectorName isEqualToString:@"getObjects:range:"] &&
                        [parameterName.lowercaseString isEqualToString:@"objects"]) {
                        void *storage = calloc(2, sizeof(id));
                        if (!storage) { hasSafeInputs = NO; void *value = NULL; [invocation setArgument:&value atIndex:argIndex + 2]; continue; }
                        void *value = storage; [argumentObjects addObject:NSNull.null];
                        [invocation setArgument:&value atIndex:argIndex + 2];
                        [outputPointers addObject:@{@"type":type, @"storage":[NSValue valueWithPointer:storage], @"size":@(2 * sizeof(id)), @"kind":@"object-array"}];
                        continue;
                    }
                    if ([className isEqualToString:@"NSIndexPath"] &&
                        [selectorName isEqualToString:@"indexPathWithIndexes:length:"] &&
                        [parameterName.lowercaseString isEqualToString:@"indexes"]) {
                        NSMutableData *valueStorage = [NSMutableData dataWithLength:3 * sizeof(NSUInteger)];
                        NSUInteger *indexes = [valueStorage mutableBytes]; indexes[0] = 0; indexes[1] = 1; indexes[2] = 2;
                        void *value = indexes; [argumentObjects addObject:valueStorage];
                        [invocation setArgument:&value atIndex:argIndex + 2]; continue;
                    }
                    if ([type containsString:@"const"] &&
                        ([type containsString:@"ObjectType"] || [type containsString:@"KeyType"] ||
                         [type containsString:@"ValueType"] || [type containsString:@"id"]) &&
                        [type containsString:@"*"] && [type rangeOfString:@"char *"].location == NSNotFound) {
                        NSArray *backing = [parameterName.lowercaseString containsString:@"key"] ?
                            @[@"a", @"é", @"b"] : @[@"a", @1, @"b"];
                        NSMutableData *valueStorage = [NSMutableData dataWithLength:3 * sizeof(id)];
                        id *values = [valueStorage mutableBytes];
                        values[0] = backing[0]; values[1] = backing[1]; values[2] = backing[2];
                        void *value = values; [argumentObjects addObject:backing];
                        [argumentObjects addObject:valueStorage];
                        [invocation setArgument:&value atIndex:argIndex + 2]; continue;
                    }
                    BOOL unsignedBytePointer = [type containsString:@"unsigned char *"] || [type containsString:@"UInt8 *"] || [type containsString:@"uint8_t *"];
                    if (unsignedBytePointer && [type containsString:@"const"]) {
                        static const unsigned char bytes[16] = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15};
                        void *value = (void *)bytes; [argumentObjects addObject:NSNull.null];
                        [invocation setArgument:&value atIndex:argIndex + 2]; continue;
                    }
                    if (unsignedBytePointer && output && [parameterName rangeOfString:@"buffer|bytes|characters|uuid" options:NSRegularExpressionSearch | NSCaseInsensitiveSearch].location != NSNotFound) {
                        NSUInteger byteCount = uuidMethod ? 16 : 4096;
                        void *storage = calloc(byteCount, 1);
                        if (!storage) { hasSafeInputs = NO; void *value = NULL; [invocation setArgument:&value atIndex:argIndex + 2]; continue; }
                        void *value = storage; [argumentObjects addObject:NSNull.null];
                        [invocation setArgument:&value atIndex:argIndex + 2];
                        [outputPointers addObject:@{@"type":type, @"storage":[NSValue valueWithPointer:storage], @"size":@(byteCount)}];
                        continue;
                    }
                    if ((encoding[0] == '*' || [type containsString:@"char *"]) &&
                        !unsignedBytePointer && [type containsString:@"const"]) {
                        NSString *string = auto_method_object(@"NSString *", parameter[@"name"] ?: @"",
                            className, selectorName, caseIndex + argIndex);
                        [argumentObjects addObject:string ?: NSNull.null];
                        const char *value = [string UTF8String]; [invocation setArgument:&value atIndex:argIndex + 2]; continue;
                    }
                    if ([type containsString:@"void *"] && !output &&
                        [parameterName rangeOfString:@"bytes|buffer|data" options:NSRegularExpressionSearch | NSCaseInsensitiveSearch].location != NSNotFound) {
                        static const unsigned char inputBytes[] = {0, 1, 127, 128, 254, 255, 42, 99, 0};
                        void *value = (void *)inputBytes;
                        if ([selectorName containsString:@"NoCopy"]) {
                            value = malloc(sizeof(inputBytes));
                            if (!value) { hasSafeInputs = NO; [argumentObjects addObject:NSNull.null]; continue; }
                            memcpy(value, inputBytes, sizeof(inputBytes));
                        }
                        [argumentObjects addObject:NSNull.null];
                        [invocation setArgument:&value atIndex:argIndex + 2]; continue;
                    }
                    if (encoding[0] == '*' || [type containsString:@"char *"]) {
                        if (output && [parameterName rangeOfString:@"buffer|bytes|characters" options:NSRegularExpressionSearch | NSCaseInsensitiveSearch].location != NSNotFound) {
                            char *storage = calloc(4096, 1);
                            if (!storage) { hasSafeInputs = NO; void *value = NULL; [invocation setArgument:&value atIndex:argIndex + 2]; continue; }
                            void *value = storage; [invocation setArgument:&value atIndex:argIndex + 2];
                            [argumentObjects addObject:NSNull.null];
                            [outputPointers addObject:@{@"type":type, @"storage":[NSValue valueWithPointer:storage], @"size":@(4096)}];
                            continue;
                        }
                        if ([parameter[@"nullable"] boolValue]) {
                            void *value = NULL; [invocation setArgument:&value atIndex:argIndex + 2];
                            [argumentObjects addObject:NSNull.null]; continue;
                        }
                        hasSafeInputs = NO; void *value = NULL; [invocation setArgument:&value atIndex:argIndex + 2];
                        [argumentObjects addObject:NSNull.null]; continue;
                    }
                    if ([type containsString:@"void *"] && output && ([parameterName rangeOfString:@"bytes|buffer|data" options:NSRegularExpressionSearch | NSCaseInsensitiveSearch].location != NSNotFound)) {
                        NSData *data = auto_object(@"NSData *", caseIndex + argIndex);
                        NSUInteger size = 4096;
                        void *storage = calloc(size, 1);
                        if (!storage) { hasSafeInputs = NO; void *value = NULL; [invocation setArgument:&value atIndex:argIndex + 2]; continue; }
                        if (data.length) memcpy(storage, data.bytes, MIN(data.length, size));
                        [argumentObjects addObject:data ?: NSNull.null];
                        void *value = storage; [invocation setArgument:&value atIndex:argIndex + 2];
                        [outputPointers addObject:@{@"type":type, @"storage":[NSValue valueWithPointer:storage], @"size":@(size)}]; continue;
                    }
                    if (!output) {
                        if ([parameter[@"nullable"] boolValue]) {
                            void *value = NULL; [invocation setArgument:&value atIndex:argIndex + 2];
                            [argumentObjects addObject:NSNull.null]; continue;
                        }
                        hasSafeInputs = NO; void *value = NULL; [invocation setArgument:&value atIndex:argIndex + 2];
                        [argumentObjects addObject:NSNull.null]; continue;
                    }
                    if ([parameter[@"nullable"] boolValue] && caseIndex == 7) {
                        void *value = NULL; [invocation setArgument:&value atIndex:argIndex + 2];
                        [argumentObjects addObject:NSNull.null]; continue;
                    }
                    NSUInteger size = 0; NSGetSizeAndAlignment(encoding + 1, &size, NULL);
                    if (!size || size > 4096) size = 8;
                    void *storage = calloc(1, MAX(size, sizeof(void *)));
                    if (!storage) { hasSafeInputs = NO; void *value = NULL; [invocation setArgument:&value atIndex:argIndex + 2]; continue; }
                    if ([className isEqualToString:@"NSDateFormatter"] &&
                        [selectorName isEqualToString:@"getObjectValue:forString:range:error:"] &&
                        [parameterName.lowercaseString isEqualToString:@"rangep"]) {
                        NSRange initialRange = NSMakeRange(0, 19);
                        memcpy(storage, &initialRange, sizeof(initialRange));
                    }
                    [invocation setArgument:&storage atIndex:argIndex + 2];
                    [argumentObjects addObject:NSNull.null];
                    [outputPointers addObject:@{ @"type":type, @"storage": [NSValue valueWithPointer:storage], @"size":@(MAX(size, sizeof(void *))) }];
                    continue;
                }
                NSUInteger size = 0; NSGetSizeAndAlignment(encoding, &size, NULL);
                if (!size || size > 4096) size = sizeof(long long);
                void *storage = calloc(1, size);
                auto_store_scalar(storage, encoding, type, caseIndex + argIndex, parameter,
                    className, selectorName, size);
                [invocation setArgument:storage atIndex:argIndex + 2];
                [argumentObjects addObject:NSNull.null];
                free(storage);
            }
            if (!hasSafeInputs) {
                printf("%lu\tnot-exercised:no-safe-input\n", (unsigned long)caseIndex);
                for (NSDictionary *slot in outputPointers) free([[slot objectForKey:@"storage"] pointerValue]);
                continue;
            }
            @try {
                auto_invoke(invocation);
                printf("%lu\t", (unsigned long)caseIndex);
                const char *returnType = sig.methodReturnType;
                while (strchr("rnNoORV", returnType[0])) returnType++;
                if (returnType[0] == 'v') fputs("void", stdout);
                else if (returnType[0] == '@') {
                    __unsafe_unretained id result = nil; [invocation getReturnValue:&result];
                    auto_print(auto_canonical(result));
                    if (!classMethod && [selectorName hasPrefix:@"init"]) receiver = result;
                }
                else if (returnType[0] == '^' || returnType[0] == '*') {
                    void *result = NULL; [invocation getReturnValue:&result];
                    NSString *returnName = item[@"return_type"];
#ifdef FINCH_DIFFTEST_APPKIT
                    if ([className isEqualToString:@"NSBitmapImageRep"] && [selectorName isEqualToString:@"bitmapData"] && result) {
                        NSBitmapImageRep *rep = receiver;
                        NSUInteger count = MIN((NSUInteger)MAX(0, rep.bytesPerRow * rep.pixelsHigh), (NSUInteger)16);
                        const unsigned char *pixels = result; fputs("pixel-data:", stdout);
                        for (NSUInteger i = 0; i < count; i++) printf("%02x", pixels[i]);
                    }
                    else
#endif
                    if (returnType[0] == '*' && [returnName containsString:@"char *"] && result)
                        auto_print(auto_canonical([NSString stringWithUTF8String:(const char *)result]));
                    else if ([returnName hasPrefix:@"CF"] && ([returnName containsString:@"Ref"] || [returnName containsString:@"Identifier"] || [returnName containsString:@"Key"] || [returnName containsString:@"Name"]))
                        auto_print(auto_canonical((id)result));
                    else printf("pointer:%s", result ? "nonnull" : "null");
                }
                else if (returnType[0] == '#' || returnType[0] == ':') {
                    void *result = NULL; [invocation getReturnValue:&result];
                    NSString *name = returnType[0] == '#' ? NSStringFromClass((Class)result) : NSStringFromSelector((SEL)result);
                    auto_print(auto_hex(name ?: @""));
                }
                else if (returnType[0] == 'f') { float value = 0; [invocation getReturnValue:&value]; printf("%a", (double)value); }
                else if (returnType[0] == 'd') { double value = 0; [invocation getReturnValue:&value]; printf("%a", value); }
                else if (returnType[0] == '{') {
                    NSUInteger size = sig.methodReturnLength; void *bytes = calloc(1, size); [invocation getReturnValue:bytes];
                    if ([item[@"return_type"] containsString:@"NSRange"]) { NSRange range; memcpy(&range, bytes, MIN(size, sizeof(range))); printf("range:%lu,%lu", (unsigned long)range.location, (unsigned long)range.length); }
                    else if ([item[@"return_type"] containsString:@"CFRange"]) { CFRange range; memcpy(&range, bytes, MIN(size, sizeof(range))); printf("range:%ld,%ld", (long)range.location, (long)range.length); }
#ifdef FINCH_DIFFTEST_APPKIT
                    else if ([item[@"return_type"] containsString:@"NSEdgeInsets"]) {
                        NSEdgeInsets value; memcpy(&value, bytes, MIN(size, sizeof(value)));
                        printf("edge-insets:%.5f,%.5f,%.5f,%.5f", (double)value.top, (double)value.left,
                            (double)value.bottom, (double)value.right);
                    }
                    else if ([item[@"return_type"] containsString:@"NSAffineTransformStruct"]) {
                        NSAffineTransformStruct value; memcpy(&value, bytes, MIN(size, sizeof(value)));
                        printf("transform:%.5f,%.5f,%.5f,%.5f,%.5f,%.5f", (double)value.m11, (double)value.m12,
                            (double)value.m21, (double)value.m22, (double)value.tX, (double)value.tY);
                    }
#endif
                    else if ([item[@"return_type"] containsString:@"NSPoint"] || [item[@"return_type"] containsString:@"CGPoint"]) {
                        NSPoint value; memcpy(&value, bytes, MIN(size, sizeof(value)));
                        printf("point:%.5f,%.5f", (double)value.x, (double)value.y);
                    }
                    else if ([item[@"return_type"] containsString:@"NSSize"] || [item[@"return_type"] containsString:@"CGSize"]) {
                        NSSize value; memcpy(&value, bytes, MIN(size, sizeof(value)));
                        printf("size:%.5f,%.5f", (double)value.width, (double)value.height);
                    }
                    else if ([item[@"return_type"] containsString:@"NSRect"] || [item[@"return_type"] containsString:@"CGRect"]) {
                        NSRect value; memcpy(&value, bytes, MIN(size, sizeof(value)));
                        printf("rect:%.5f,%.5f,%.5f,%.5f", (double)value.origin.x, (double)value.origin.y,
                            (double)value.size.width, (double)value.size.height);
                    }
                    else { fputs("struct:", stdout); for (NSUInteger i = 0; i < size; i++) printf("%02x", ((unsigned char *)bytes)[i]); }
                    free(bytes);
                } else {
                    unsigned long long value = 0; [invocation getReturnValue:&value];
                    if (strchr("CISLQ", returnType[0])) printf("%llu", value);
                    else printf("%lld", (long long)value);
                }
                for (NSDictionary *slot in outputPointers) {
                    putchar('\t'); void *storage = [slot[@"storage"] pointerValue]; NSString *type = slot[@"type"];
                    if ([slot[@"kind"] isEqualToString:@"pixel-array"]) {
                        NSUInteger *pixels = storage;
                        printf("pixels:%lu,%lu,%lu,%lu", (unsigned long)pixels[0], (unsigned long)pixels[1],
                            (unsigned long)pixels[2], (unsigned long)pixels[3]);
                    } else if ([slot[@"kind"] isEqualToString:@"object-array"]) {
                        NSMutableArray *values = [NSMutableArray array]; id *objects = storage;
                        for (NSUInteger i = 0; i < 2; i++) [values addObject:auto_canonical(objects[i]) ?: @"null"];
                        auto_print(auto_canonical(values));
#ifdef FINCH_DIFFTEST_METAL
                    } else if ([slot[@"kind"] isEqualToString:@"sample-position-array"]) {
                        MTLSamplePosition *positions = storage;
                        NSMutableString *result = [NSMutableString stringWithFormat:@"sample-positions:%@", slot[@"count"]];
                        for (NSUInteger i = 0; i < [slot[@"count"] unsignedIntegerValue]; i++)
                            [result appendFormat:@"|%a,%a", (double)positions[i].x, (double)positions[i].y];
                        auto_print(auto_canonical(result));
#endif
                    } else if ([type containsString:@"NSRange"] && [type componentsSeparatedByString:@"*"].count == 2) {
                        NSRange range; memcpy(&range, storage, sizeof(range)); printf("range:%lu,%lu", (unsigned long)range.location, (unsigned long)range.length);
                    } else if ([type containsString:@"CFRange"] && [type componentsSeparatedByString:@"*"].count == 2) {
                        CFRange range; memcpy(&range, storage, sizeof(range)); printf("range:%ld,%ld", (long)range.location, (long)range.length);
                    } else {
                        NSString *cleanType = auto_clean_type(type);
                        BOOL objectPointer = [cleanType rangeOfString:@"^id\\s*(?:<[^>]+>\\s*)?\\*"
                            options:NSRegularExpressionSearch].location != NSNotFound;
                        if ([type containsString:@"NSError"] || [type containsString:@"NSString"] || objectPointer) {
                        __unsafe_unretained id value = *(__unsafe_unretained id *)storage; auto_print(auto_canonical(value));
                        } else {
                        NSUInteger size = [slot[@"size"] unsignedIntegerValue];
                        fputs("out:", stdout); for (NSUInteger i = 0; i < MIN(size, (NSUInteger)16); i++) printf("%02x", ((unsigned char *)storage)[i]);
                        }
                    }
                    free(storage);
                }
                if (!classMethod && (returnType[0] == 'v' || auto_type_is_mutable(className))) {
                    putchar('\t');
#ifdef FINCH_DIFFTEST_QUARTZCORE
                    if ([className hasPrefix:@"CA"] && [selectorName hasPrefix:@"set"] &&
                        [selectorName hasSuffix:@":"] && selectorName.length > 4) {
                        NSString *key = [selectorName substringWithRange:NSMakeRange(3, selectorName.length - 4)];
                        NSString *first = [[key substringToIndex:1] lowercaseString];
                        key = [first stringByAppendingString:[key substringFromIndex:1]];
                        auto_print(auto_canonical([receiver valueForKey:key]));
                    } else
#endif
#ifdef FINCH_DIFFTEST_METAL
                    if ([className isEqualToString:@"MTLRenderPassDescriptor"] &&
                        [selectorName isEqualToString:@"setSamplePositions:count:"]) {
                        MTLSamplePosition positions[8] = {};
                        NSUInteger requestedCount = caseIndex == 7 ? 0 : 4;
                        NSUInteger count = [(MTLRenderPassDescriptor *)receiver getSamplePositions:positions count:requestedCount];
                        NSMutableString *state = [NSMutableString stringWithFormat:@"sample-positions:%lu", (unsigned long)count];
                        for (NSUInteger i = 0; i < MIN(count, (NSUInteger)8); i++)
                            [state appendFormat:@"|%a,%a", (double)positions[i].x, (double)positions[i].y];
                        auto_print(auto_canonical(state));
                    } else
#endif
#ifdef FINCH_DIFFTEST_CORESPOTLIGHT
                    if ([className isEqualToString:@"CSSearchableItemAttributeSet"] &&
                        [selectorName isEqualToString:@"setValue:forCustomKey:"]) {
                        id key = argumentObjects.count > 1 && argumentObjects[1] != NSNull.null ? argumentObjects[1] : nil;
                        auto_print(auto_canonical(key ? [receiver valueForCustomKey:key] : nil));
                    } else if ([className isEqualToString:@"CSSearchableItemAttributeSet"] &&
                        [selectorName hasPrefix:@"set"] && [selectorName hasSuffix:@":"] && selectorName.length > 4) {
                        NSString *key = [selectorName substringWithRange:NSMakeRange(3, selectorName.length - 4)];
                        NSString *first = [[key substringToIndex:1] lowercaseString];
                        key = [first stringByAppendingString:[key substringFromIndex:1]];
                        auto_print(auto_canonical([receiver valueForKey:key]));
                    } else
#endif
                    auto_print(auto_canonical(receiver));
                }
                for (NSUInteger argIndex = 0; argIndex < argumentObjects.count; argIndex++) {
                    id value = argumentObjects[argIndex];
                    NSDictionary *parameter = argIndex < parameters.count ? parameters[argIndex] : @{};
                    if (value != NSNull.null && auto_type_is_mutable(parameter[@"type"] ?: @"")) {
                        printf("\targ%lu=", (unsigned long)argIndex); auto_print(auto_canonical(value));
                    }
                }
                if (auto_callback_was_used) {
                    putchar('\t');
                    auto_print(auto_canonical(auto_callback_result(className)));
                }
                putchar('\n');
            } @catch (NSException *exception) {
                printf("%lu\texception:", (unsigned long)caseIndex); auto_print(auto_hex(exception.name)); putchar(':'); auto_print(auto_hex(exception.reason ?: @"")); putchar('\n');
                for (NSDictionary *slot in outputPointers) free([[slot objectForKey:@"storage"] pointerValue]);
            }
        }
    }
}

static BOOL auto_run_objc_item(const char *name, const char *metadataPath)
{
    NSData *data = [NSData dataWithBytes:metadataPath length:strlen(metadataPath)];
    NSError *error = nil; NSDictionary *root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (![root isKindOfClass:NSDictionary.class] || ![root[@"name"] isEqualToString:[NSString stringWithUTF8String:name]]) return NO;
    NSString *kind = root[@"kind"];
    NSString *typeName = root[@"type_name"];
    if ([kind isEqualToString:@"objc-class"]) {
        const char *spelling = typeName.UTF8String;
        Class cls = spelling ? objc_getClass(spelling) : Nil;
        if (!cls) { auto_print(auto_hex(@"missing-class")); putchar('\n'); return YES; }
        Class superclass = class_getSuperclass(cls);
        NSString *parentName = superclass ? @(class_getName(superclass)) : @"<root>";
        NSString *record = [NSString stringWithFormat:@"class:%@:%@:%lu", @(class_getName(cls)), parentName,
            (unsigned long)class_getInstanceSize(cls)];
        auto_print(auto_hex(record)); putchar('\n');
        return YES;
    }
    if ([kind isEqualToString:@"objc-method"]) {
        NSString *className = root[@"class_name"];
        NSString *selectorName = root[@"selector"];
        Class cls = className ? objc_getClass(className.UTF8String) : Nil;
        if (!cls) { auto_print(auto_hex(@"missing-class")); putchar('\n'); return YES; }
        SEL selector = selectorName ? sel_registerName(selectorName.UTF8String) : NULL;
        Method method = [root[@"class_method"] boolValue]
            ? class_getClassMethod(cls, selector) : class_getInstanceMethod(cls, selector);
        if (!method) { auto_print(auto_hex(@"missing-method")); putchar('\n'); return YES; }
        const char *encoding = method_getTypeEncoding(method);
        NSString *record = [NSString stringWithFormat:@"method:%@:%@:%@", className, selectorName,
            encoding ? @(encoding) : @""];
        auto_print(auto_hex(record)); putchar('\n');
        return YES;
    }
    if ([kind isEqualToString:@"objc-protocol"]) {
        const char *spelling = typeName.UTF8String;
        Protocol *protocol = spelling ? objc_getProtocol(spelling) : NULL;
        if (!protocol) { auto_print(auto_hex(@"missing-protocol")); putchar('\n'); return YES; }
        NSMutableArray *methods = [NSMutableArray array];
        for (BOOL required = YES; ; required = NO) {
            for (BOOL instance = YES; ; instance = NO) {
                unsigned int count = 0;
                struct objc_method_description *descriptions = protocol_copyMethodDescriptionList(
                    protocol, required, instance, &count);
                for (unsigned int index = 0; index < count; index++) {
                    NSString *selector = NSStringFromSelector(descriptions[index].name) ?: @"";
                    NSString *encoding = descriptions[index].types ? @(descriptions[index].types) : @"";
                    [methods addObject:[NSString stringWithFormat:@"%@:%@:%@", required ? @"required" : @"optional",
                        instance ? @"instance" : @"class", [NSString stringWithFormat:@"%@:%@", selector, encoding]]];
                }
                free(descriptions);
                if (!instance) break;
            }
            if (!required) break;
        }
        [methods sortUsingSelector:@selector(compare:)];
        NSString *record = [NSString stringWithFormat:@"protocol:%@:%@", @(protocol_getName(protocol)),
            [methods componentsJoinedByString:@"|"]];
        auto_print(auto_hex(record)); putchar('\n');
        return YES;
    }
    NSDictionary *item = root;
    @try { auto_test_method(item); }
    @catch (NSException *exception) { fputs("exception\t", stdout); auto_print(auto_hex(exception.name)); putchar(':'); auto_print(auto_hex(exception.reason ?: @"")); putchar('\n'); }
    return YES;
}
'''


def _function_metadata(function: dict, enum_values: list[dict]) -> dict:
    result = dict(function)
    for parameter in result.get("parameters", []):
        parameter["enum_values"] = _enum_pool(parameter, enum_values)
    return result


def prepare(framework: str, c_items: set[str], objc_items: set[str], swift_items: set[str],
            details: dict, manual_names: set[str], finch_symbols: set[str], output_dir: Path,
            objc_type_items: list[dict] | None = None) -> dict:
    """Make a generated dispatch table and metadata for every safely buildable call."""
    function_by_name = {item["name"]: item for item in details.get("functions", [])}
    variable_by_name = {item["name"]: item for item in details.get("variables", [])}
    method_by_name = details.get("methods", {})
    enum_values = details.get("enum_values", [])
    auto_c = []
    auto_objc = {}
    skipped: dict[str, str] = {}

    for name in sorted(c_items - manual_names):
        scope_reason = _framework_scope_reason(
            framework, name, variable=name in variable_by_name and name not in function_by_name)
        if scope_reason:
            skipped[name] = scope_reason
            continue
        if framework == "AppKit" and not _appkit_c_scope(name, name in variable_by_name):
            skipped[name] = "outside the selected AppKit headless API scope"
            continue
        if name in function_by_name:
            source, reason = _make_c_function(function_by_name[name], enum_values, finch_symbols, framework)
            if source:
                auto_c.append({"name": name, "category": f"auto/c/{_category(name)}", "source": source,
                               "kind": "function", "signature": function_by_name[name]["type"]})
            else:
                skipped[name] = reason or "no safe input pool"
        elif name in variable_by_name:
            source, reason = _make_c_variable(variable_by_name[name], finch_symbols)
            if source:
                auto_c.append({"name": name, "category": f"auto/c/{_category(name)}", "source": source,
                               "kind": "variable", "signature": variable_by_name[name]["type"]})
            else:
                skipped[name] = reason or "no canonical reader"
        else:
            skipped[name] = "SDK inventory entry has no parsed C declaration signature"

    for name in sorted(objc_items - manual_names):
        method = method_by_name.get(name)
        if not method:
            skipped[name] = "SDK header inventory entry has no matching Objective-C AST signature"
            continue
        if framework == "AppKit":
            reason = _appkit_skip(method)
            if reason:
                skipped[name] = reason
                continue
        reason = _objc_framework_scope_reason(framework, method)
        if reason:
            skipped[name] = reason
            continue
        reason = _skip_reason(name, framework)
        if reason:
            skipped[name] = reason
            continue
        if (not method.get("class_method") and method.get("class") in {"NSCoder", "NSArchiver", "NSUnarchiver"}) or \
                method.get("selector") in {"initWithCoder:", "encodeWithCoder:"} or any(
                    "NSCoder" in parameter.get("type", "") or "NSArchiver" in parameter.get("type", "")
                    for parameter in method.get("parameters", [])):
            skipped[name] = "archive context is required to build a safe receiver"
            continue
        if method.get("variadic"):
            skipped[name] = "variadic Objective-C methods need API-specific format arguments"
            continue
        if _base_type(method.get("return_type", "")) == "NSDecimal" and "*" not in method.get("return_type", ""):
            skipped[name] = "NSDecimal structure return needs an ABI-specific result reader"
            continue
        unsupported = None
        for parameter in method.get("parameters", []):
            qtype = parameter.get("type", "")
            base = _base_type(qtype)
            if _is_function_pointer(qtype):
                # These callbacks run synchronously over fixed in-memory values.
                if name not in FOUNDATION_CALLBACK_METHODS and not (
                        "(^" in qtype and re.search(r"comparator", name, re.I)):
                    unsupported = f"callback parameter has no safe builder: {qtype}"
                    break
            elif _scalar_kind(qtype) or parameter.get("enum_values") or _is_cf_ref(qtype) or _is_objc_object(qtype) or _base_type(qtype) == "SEL":
                pass
            elif "char *" in qtype or base in ("void", "NSRange", "CFRange", "CGPoint", "CGSize", "CGRect", "NSPoint", "NSSize", "NSRect", "CGAffineTransform", "CATransform3D", "NSRangePointer", "NSPointArray", "NSSizeArray", "NSRectArray"):
                pass
            elif "*" in qtype and parameter.get("nullable"):
                pass
            else:
                unsupported = f"no safe input pool for type {qtype}"
                break
        if unsupported:
            skipped[name] = unsupported
            continue
        data = dict(method)
        data["name"] = name
        for parameter in data.get("parameters", []):
            parameter["enum_values"] = _enum_pool(parameter, enum_values)
        data["category"] = f"auto/objc/{_category(name)}"
        auto_objc[name] = data

    for name in sorted(swift_items - manual_names):
        skipped.setdefault(name, "Swift interface entry has no C or Objective-C selector signature")

    # SDK declarations sometimes appear in both the C and Objective-C scanners.
    duplicate = set(entry["name"] for entry in auto_c) & set(auto_objc)
    for name in duplicate:
        skipped[name] = "ambiguous C and Objective-C inventory spelling"
    auto_c = [entry for entry in auto_c if entry["name"] not in duplicate]
    for name in duplicate:
        auto_objc.pop(name, None)

    c_source = "\n\n".join(entry["source"] for entry in auto_c)
    c_entries = "\n".join(
        "    { " + json.dumps(entry["name"]) + ", " +
        ("typed_c_" if entry["kind"] == "function" else "typed_v_") +
        re.sub(r"\W+", "_", entry["name"]) + " },"
        for entry in auto_c
    )
    metadata = {
        "framework": framework,
        "pool_descriptions": POOL_DESCRIPTIONS,
        "max_cases_per_item": MAX_CASES,
        "c": [{"name": entry["name"], "category": entry["category"], "kind": entry["kind"], "signature": entry["signature"]} for entry in auto_c],
        "objc": auto_objc,
        "types": {entry["name"]: entry for entry in (objc_type_items or [])},
        "skipped": skipped,
    }
    metadata_path = output_dir / f"{framework.replace('/', '__')}.types.json"
    metadata_path.write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
    return {
        "c_source": _c_runtime() + "\n" + c_source if auto_c else _c_runtime(),
        "c_entries": c_entries,
        "objc_runtime": _objc_runtime(),
        "auto_c_items": [{"name": entry["name"], "category": entry["category"], "kind": entry["kind"], "signature": entry["signature"]} for entry in auto_c],
        "auto_objc_items": [{"name": name, "category": item["category"], "kind": "objc", "signature": item["return_type"] + " (" + ", ".join(p.get("type", "") for p in item.get("parameters", [])) + ")"} for name, item in auto_objc.items()],
        "auto_objc_type_items": [{"name": entry["name"], "category": "auto/objc/runtime-type", "kind": "objc-type",
                                  "signature": entry["kind"]} for entry in (objc_type_items or [])],
        "skipped": skipped,
        "metadata": str(metadata_path),
    }
