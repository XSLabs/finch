/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Keep the public delegate contracts visible in Finch's Objective-C runtime. */
#import <AVFoundation/AVFoundation.h>

__attribute__((constructor)) static void
FinchRetainAVFoundationProtocolMetadata(void)
{
    volatile Protocol *protocol;
    protocol = @protocol(AVFragmentMinding);
    protocol = @protocol(AVAssetDownloadDelegate);
    protocol = @protocol(AVAssetReaderCaptionValidationHandling);
    protocol = @protocol(AVAssetResourceLoaderDelegate);
    protocol = @protocol(AVAssetWriterDelegate);
    protocol = @protocol(AVCaptureAudioDataOutputSampleBufferDelegate);
    protocol = @protocol(AVCaptureFileOutputRecordingDelegate);
    protocol = @protocol(AVCaptureFileOutputDelegate);
    protocol = @protocol(AVCaptureMetadataOutputObjectsDelegate);
    protocol = @protocol(AVCapturePhotoOutputReadinessCoordinatorDelegate);
    protocol = @protocol(AVCapturePhotoCaptureDelegate);
    protocol = @protocol(AVCaptureSessionControlsDelegate);
    protocol = @protocol(AVCaptureSessionDeferredStartDelegate);
    protocol = @protocol(AVCaptureTimecodeGeneratorDelegate);
    protocol = @protocol(AVCaptureVideoDataOutputSampleBufferDelegate);
    protocol = @protocol(AVContentKeySessionDelegate);
    protocol = @protocol(AVContentKeyRecipient);
    protocol = @protocol(AVExternalSyncDeviceDelegate);
    protocol = @protocol(AVMetricEventStreamPublisher);
    protocol = @protocol(AVMetricEventStreamSubscriber);
    protocol = @protocol(AVPlayerPlaybackCoordinatorDelegate);
    protocol = @protocol(AVPlaybackCoordinatorPlaybackControlDelegate);
    protocol = @protocol(AVPlayerItemIntegratedTimelineObserver);
    protocol = @protocol(AVPlayerItemMetadataCollectorPushDelegate);
    protocol = @protocol(AVPlayerItemOutputPullDelegate);
    protocol = @protocol(AVPlayerItemLegibleOutputPushDelegate);
    protocol = @protocol(AVPlayerItemOutputPushDelegate);
    protocol = @protocol(AVPlayerItemMetadataOutputPushDelegate);
    protocol = @protocol(AVPlayerItemRenderedLegibleOutputPushDelegate);
    protocol = @protocol(AVVideoCompositing);
    protocol = @protocol(AVVideoCompositionValidationHandling);
    (void)protocol;
}
