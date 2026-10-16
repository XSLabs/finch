# AVFoundation app import audit

2026-10-15. This snapshot uses `tools/check-imports.py` over each app executable and its bundled frameworks and plug-ins, then groups strong imports by symbol and app. Weak imports are left out. The source apps are the apps installed on this Mac when the scan ran.

## Before and after

| Finch image | Before | After |
|---|---:|---:|
| AVFoundation | 23 apps, 58 symbols, 196 app-symbol imports | 23 apps, 57 symbols, 190 app-symbol imports |
| AVFAudio | 1 app, 1 symbol, 1 app-symbol import | 0 apps, 0 symbols, 0 app-symbol imports |
| `libswiftAVFoundation.dylib` | 8 apps could not find the image; they imported 28 symbols across 61 app-symbol pairs | 2 apps, 5 symbols, 5 app-symbol imports remain |

Apps can still be blocked by other missing Finch frameworks, so the AVFoundation app count can stay the same even when six imports are fixed.

## AVFoundation

The pass-through `AVAssetExportSession` was added for existing QuickTime and MPEG-4 reader/writer paths. It supports asynchronous completion, progress, cancellation and file-type checks. It does not claim encoding presets or transcoding. The added class import is used by Freeform, Journal, Numbers Creator Studio, Photo Booth, QuickTime Player and VoiceMemos.

The table lists the 58 AVFoundation symbols that apps lacked before the change. The export-session class is now present; the other rows remain missing.

| Symbol imported | Apps | Status |
|---|---|---|
| `_OBJC_CLASS_$_AVCaptureDevice` | Antigravity, ChatGPT, Claude, Developer, Dialpad, Dialpad Meetings, Discord, FaceTime, Freeform, Gemini, Google Chrome, Journal, Maps, Meta Quest Remote Desktop, Numbers Creator Studio, Photo Booth, QuickTime Player, Visual Studio Code, cmux | Still missing |
| `_OBJC_CLASS_$_AVCaptureSession` | Antigravity, ChatGPT, Claude, Developer, Dialpad, Dialpad Meetings, Discord, Gemini, Google Chrome, Meta Quest Remote Desktop, Numbers Creator Studio, Photo Booth, QuickTime Player, Visual Studio Code, cmux | Still missing |
| `_OBJC_CLASS_$_AVCaptureDeviceInput` | Antigravity, ChatGPT, Claude, Developer, Dialpad, Dialpad Meetings, Discord, Gemini, Google Chrome, Numbers Creator Studio, Photo Booth, QuickTime Player, Visual Studio Code, cmux | Still missing |
| `_OBJC_CLASS_$_AVCaptureDeviceDiscoverySession` | Antigravity, ChatGPT, Claude, Developer, Dialpad, Dialpad Meetings, Discord, Google Chrome, QuickTime Player, Visual Studio Code, cmux | Still missing |
| `_OBJC_CLASS_$_AVCaptureVideoDataOutput` | Antigravity, ChatGPT, Claude, Dialpad, Dialpad Meetings, Discord, Gemini, Google Chrome, Photo Booth, Visual Studio Code, cmux | Still missing |
| `_OBJC_CLASS_$_AVCapturePhotoOutput` | Antigravity, ChatGPT, Claude, Developer, Dialpad, Dialpad Meetings, Discord, Gemini, Google Chrome, Visual Studio Code | Still missing |
| `_OBJC_CLASS_$_AVCapturePhotoSettings` | Antigravity, ChatGPT, Claude, Developer, Dialpad, Dialpad Meetings, Discord, Gemini, Google Chrome, Visual Studio Code | Still missing |
| `_OBJC_CLASS_$_AVSampleBufferDisplayLayer` | Antigravity, ChatGPT, Claude, Dialpad, Dialpad Meetings, Discord, Google Chrome, Visual Studio Code | Still missing |
| `_OBJC_CLASS_$_AVSampleBufferAudioRenderer` | Antigravity, ChatGPT, Claude, Dialpad, Discord, Google Chrome, Visual Studio Code | Still missing |
| `_OBJC_CLASS_$_AVSampleBufferRenderSynchronizer` | Antigravity, ChatGPT, Claude, Dialpad, Discord, Google Chrome, Visual Studio Code | Still missing |
| `_OBJC_CLASS_$_AVAssetExportSession` | Freeform, Journal, Numbers Creator Studio, Photo Booth, QuickTime Player, VoiceMemos | Implemented |
| `_OBJC_CLASS_$_AVMutableAudioMix` | Books, Freeform, Numbers Creator Studio, QuickTime Player, VoiceMemos | Still missing |
| `_OBJC_CLASS_$_AVMutableAudioMixInputParameters` | Books, Freeform, Numbers Creator Studio, QuickTime Player, VoiceMemos | Still missing |
| `_OBJC_CLASS_$_AVMutableComposition` | Freeform, Numbers Creator Studio, Photos, QuickTime Player, VoiceMemos | Still missing |
| `_OBJC_CLASS_$_AVComposition` | Freeform, Numbers Creator Studio, QuickTime Player, VoiceMemos | Still missing |
| `_OBJC_CLASS_$_AVTimeFormatter` | Photos, Podcasts, QuickTime Player, VoiceMemos | Still missing |
| `_OBJC_CLASS_$_AVMutableMovie` | Freeform, Journal, Numbers Creator Studio | Still missing |
| `_OBJC_CLASS_$_AVMutableVideoComposition` | Freeform, Numbers Creator Studio, QuickTime Player | Still missing |
| `_OBJC_CLASS_$_AVAssetDownloadConfiguration` | Developer, Podcasts | Still missing |
| `_OBJC_CLASS_$_AVAssetDownloadTask` | Developer, Podcasts | Still missing |
| `_OBJC_CLASS_$_AVAssetDownloadURLSession` | Developer, Podcasts | Still missing |
| `_OBJC_CLASS_$_AVAssetReaderAudioMixOutput` | QuickTime Player, VoiceMemos | Still missing |
| `_OBJC_CLASS_$_AVAssetVariantQualifier` | Developer, Podcasts | Still missing |
| `_OBJC_CLASS_$_AVCaptureAudioDataOutput` | Numbers Creator Studio, Photo Booth | Still missing |
| `_OBJC_CLASS_$_AVCaptureConnection` | Developer, QuickTime Player | Still missing |
| `_OBJC_CLASS_$_AVCaptureVideoPreviewLayer` | Developer, Gemini | Still missing |
| `_OBJC_CLASS_$_AVMovie` | Freeform, Numbers Creator Studio | Still missing |
| `_OBJC_CLASS_$_AVAggregateAssetDownloadTask` | Podcasts | Still missing |
| `_OBJC_CLASS_$_AVAssetCollection` | QuickTime Player | Still missing |
| `_OBJC_CLASS_$_AVAssetDownloadContentConfiguration` | Podcasts | Still missing |
| `_OBJC_CLASS_$_AVAssetReaderSampleReferenceOutput` | Numbers Creator Studio | Still missing |
| `_OBJC_CLASS_$_AVAssetVariant` | Podcasts | Still missing |
| `_OBJC_CLASS_$_AVAssetWriterInputGroup` | VoiceMemos | Still missing |
| `_OBJC_CLASS_$_AVAssetWriterInputMetadataAdaptor` | VoiceMemos | Still missing |
| `_OBJC_CLASS_$_AVAudioMixInputParameters` | VoiceMemos | Still missing |
| `_OBJC_CLASS_$_AVCaptureAudioFileOutput` | QuickTime Player | Still missing |
| `_OBJC_CLASS_$_AVCaptureAudioPreviewOutput` | QuickTime Player | Still missing |
| `_OBJC_CLASS_$_AVCaptureInput` | Developer | Still missing |
| `_OBJC_CLASS_$_AVCaptureInputPort` | Developer | Still missing |
| `_OBJC_CLASS_$_AVCaptureMovieFileOutput` | QuickTime Player | Still missing |
| `_OBJC_CLASS_$_AVCaptureOutput` | Developer | Still missing |
| `_OBJC_CLASS_$_AVCompositionTrack` | VoiceMemos | Still missing |
| `_OBJC_CLASS_$_AVCompositionTrackSegment` | VoiceMemos | Still missing |
| `_OBJC_CLASS_$_AVContentKeyResponse` | Books | Still missing |
| `_OBJC_CLASS_$_AVContentKeySession` | Books | Still missing |
| `_OBJC_CLASS_$_AVMediaDataStorage` | Numbers Creator Studio | Still missing |
| `_OBJC_CLASS_$_AVMediaSelection` | Developer | Still missing |
| `_OBJC_CLASS_$_AVMediaSelectionGroup` | Books | Still missing |
| `_OBJC_CLASS_$_AVMediaSelectionOption` | Developer | Still missing |
| `_OBJC_CLASS_$_AVMutableMediaSelection` | Developer | Still missing |
| `_OBJC_CLASS_$_AVMutableMovieTrack` | Journal | Still missing |
| `_OBJC_CLASS_$_AVMutableVideoCompositionInstruction` | QuickTime Player | Still missing |
| `_OBJC_CLASS_$_AVMutableVideoCompositionLayerInstruction` | QuickTime Player | Still missing |
| `_OBJC_CLASS_$_AVPlayerItemAccessLogEvent` | Developer | Still missing |
| `_OBJC_CLASS_$_AVRouteDetector` | Books | Still missing |
| `_OBJC_CLASS_$_AVTimedMetadataGroup` | VoiceMemos | Still missing |
| `_OBJC_METACLASS_$_AVCaptureAudioPreviewOutput` | QuickTime Player | Still missing |
| `_OBJC_METACLASS_$_AVCaptureSession` | Photo Booth | Still missing |

## AVFAudio

The missing class was `_OBJC_CLASS_$_AVAudioCompressedBuffer`, imported by Gemini. Finch now owns and sizes its compressed packet storage and packet descriptions; the comparison test matches Apple for the supported cases.

| Symbol imported | Apps | Status |
|---|---|---|
| `_OBJC_CLASS_$_AVAudioCompressedBuffer` | Gemini | Implemented |

## `libswiftAVFoundation.dylib`

Finch now builds a Swift overlay from Finch-written code. It exports the async property classes and the calls apps use for loading asset values, exporting assets and generating one image. The Swift comparison test passes on a QuickTime movie built by the test.

This table shows every overlay symbol imported by apps before Finch had the image. Swift entries are kept in their exact mangled form because that is what the app import table records. Five still need support: URL asset bitrate variants, media selection and camera flash modes. Finch does not yet provide the AVAssetVariant/HLS or media-selection models, and it has no physical camera for flash modes.

| Symbol imported | Apps | Status |
|---|---|---|
| `_$s12AVFoundation15AVAsyncPropertyCMn` | CotEditor, Developer, Gemini, Journal, Numbers Creator Studio, Podcasts, VoiceMemos, cmux | Implemented |
| `_$s12AVFoundation22AVPartialAsyncPropertyCAASo7AVAssetCRbzlE8durationAA07AVAsyncD0CyxSo6CMTimeaGvgZ` | CotEditor, Gemini, Journal, Podcasts, VoiceMemos, cmux | Implemented |
| `_$sSo29AVAsynchronousKeyValueLoadingP12AVFoundationE4load_9isolationqd__AC15AVAsyncPropertyCyxqd__G_ScA_pSgYitYaKlF` | Developer, Journal, Podcasts, VoiceMemos | Implemented |
| `_$sSo29AVAsynchronousKeyValueLoadingP12AVFoundationE4load_9isolationqd__AC15AVAsyncPropertyCyxqd__G_ScA_pSgYitYaKlFTu` | Developer, Journal, Podcasts, VoiceMemos | Implemented |
| `_$sSo29AVAsynchronousKeyValueLoadingP12AVFoundationE6status2ofAC15AVAsyncPropertyC6StatusOyxqd___GAGyxqd__G_tlF` | CotEditor, Gemini, Numbers Creator Studio, cmux | Implemented |
| `_$s12AVFoundation15AVAsyncPropertyC6StatusO11descriptionSSvg` | CotEditor, Gemini, cmux | Implemented |
| `_$s12AVFoundation15AVAsyncPropertyC6StatusOMn` | CotEditor, Gemini, cmux | Implemented |
| `_$s12AVFoundation18AVAnyAsyncPropertyC11descriptionSSvgTj` | CotEditor, Gemini, cmux | Implemented |
| `_$s12AVFoundation22AVPartialAsyncPropertyCAASo12AVAssetTrackCRbzlE11naturalSizeAA07AVAsyncD0CyxSo6CGSizeVGvgZ` | CotEditor, Gemini | Implemented |
| `_$s12AVFoundation22AVPartialAsyncPropertyCAASo7AVAssetCRbzlE8metadataAA07AVAsyncD0CyxSaySo14AVMetadataItemCGGvgZ` | Journal, VoiceMemos | Implemented |
| `_$sSo20AVAssetExportSessionC12AVFoundationE6export2to2as9isolationy10Foundation3URLV_So10AVFileTypeaScA_pSgYitYaKF` | Journal, VoiceMemos | Implemented |
| `_$sSo20AVAssetExportSessionC12AVFoundationE6export2to2as9isolationy10Foundation3URLV_So10AVFileTypeaScA_pSgYitYaKFTu` | Journal, VoiceMemos | Implemented |
| `_$sSo21AVAssetImageGeneratorC12AVFoundationE5image2atSo10CGImageRefaAD_So6CMTimea10actualTimetAI_tYaKF` | Gemini, Journal | Implemented |
| `_$sSo21AVAssetImageGeneratorC12AVFoundationE5image2atSo10CGImageRefaAD_So6CMTimea10actualTimetAI_tYaKFTu` | Gemini, Journal | Implemented |
| `_$s12AVFoundation22AVPartialAsyncPropertyCAASo10AVURLAssetCRbzlE8variantsAA07AVAsyncD0CyxSaySo14AVAssetVariantCGGvgZ` | Podcasts | Still missing |
| `_$s12AVFoundation22AVPartialAsyncPropertyCAASo12AVAssetTrackCRbzlE18formatDescriptionsAA07AVAsyncD0CyxSaySo22CMFormatDescriptionRefaGGvgZ` | VoiceMemos | Implemented |
| `_$s12AVFoundation22AVPartialAsyncPropertyCAASo12AVAssetTrackCRbzlE18preferredTransformAA07AVAsyncD0CyxSo08CGAffineH0VGvgZ` | CotEditor | Implemented |
| `_$s12AVFoundation22AVPartialAsyncPropertyCAASo12AVAssetTrackCRbzlE9timeRangeAA07AVAsyncD0CyxSo06CMTimeH0aGvgZ` | VoiceMemos | Implemented |
| `_$s12AVFoundation22AVPartialAsyncPropertyCAASo14AVMetadataItemCRbzlE11stringValueAA07AVAsyncD0CyxSSSgGvgZ` | Journal | Implemented |
| `_$s12AVFoundation22AVPartialAsyncPropertyCAASo14AVMetadataItemCRbzlE9dateValueAA07AVAsyncD0Cyx10Foundation4DateVSgGvgZ` | Journal | Implemented |
| `_$s12AVFoundation22AVPartialAsyncPropertyCAASo7AVAssetCRbzlE033availableMediaCharacteristicsWithG16SelectionOptionsAA07AVAsyncD0CyxSaySo21AVMediaCharacteristicaGGvgZ` | cmux | Implemented |
| `_$s12AVFoundation22AVPartialAsyncPropertyCAASo7AVAssetCRbzlE23preferredMediaSelectionAA07AVAsyncD0CyxSo07AVMediaH0CGvgZ` | Developer | Still missing |
| `_$s12AVFoundation22AVPartialAsyncPropertyCAASo7AVAssetCRbzlE6tracksAA07AVAsyncD0CyxSaySo0E5TrackCGGvgZ` | Numbers Creator Studio | Implemented |
| `_$sSo14AVAssetVariantC12AVFoundationE11peakBitRateSdSgvg` | Podcasts | Still missing |
| `_$sSo14AVAssetVariantC12AVFoundationE14averageBitRateSdSgvg` | Podcasts | Still missing |
| `_$sSo20AVCapturePhotoOutputC12AVFoundationE19supportedFlashModesSaySo0aF4ModeVGvg` | Developer | Still missing |
| `_$sSo29AVAsynchronousKeyValueLoadingP12AVFoundationE4load___9isolationqd___qd_0_qd_1_qd_1_QptAC15AVAsyncPropertyCyxqd__G_AGyxqd_0_GAGyxqd_1_Gqd_1_QpScA_pSgYitYaKRvd_1_r1_lF` | Podcasts | Implemented |
| `_$sSo29AVAsynchronousKeyValueLoadingP12AVFoundationE4load___9isolationqd___qd_0_qd_1_qd_1_QptAC15AVAsyncPropertyCyxqd__G_AGyxqd_0_GAGyxqd_1_Gqd_1_QpScA_pSgYitYaKRvd_1_r1_lFTu` | Podcasts | Implemented |

## Why the remaining imports are open

Most remaining AVFoundation imports are camera capture classes and photo settings, which need a camera device Finch does not have. Other groups need movie composition/editing, sample-buffer presentation and audio rendering, download services, content-key/DRM services, route detection or media-selection models that are not implemented. Their exact symbol-to-app map is in the AVFoundation table above; Finch leaves these exports absent until it can provide real behavior.
