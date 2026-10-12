/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * ScreenCaptureKit's values: the error domain, frame info keys, stream configuration
 * defaults and presets, screenshot, recording and picker configurations. (Capturing
 * needs screen access, which Apple's asks the user for: finch-appkit-screencapture-test
 * captures on Finch's window server.) Compared with Apple's.
 */
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static void
dump(NSObject *o, NSArray *keys)
{
    for (NSString *k in keys)
        printf("  %s = %s\n", k.UTF8String, [[[o valueForKey:k] description] UTF8String]);
}

int
main(void)
{
    @autoreleasepool {
        printf("domain %s\n", SCStreamErrorDomain.UTF8String);
        printf("frame info keys: %s %s %s %s %s %s %s %s %s\n", SCStreamFrameInfoStatus.UTF8String,
            SCStreamFrameInfoDisplayTime.UTF8String, SCStreamFrameInfoScaleFactor.UTF8String,
            SCStreamFrameInfoContentScale.UTF8String, SCStreamFrameInfoContentRect.UTF8String,
            SCStreamFrameInfoDirtyRects.UTF8String, SCStreamFrameInfoScreenRect.UTF8String,
            SCStreamFrameInfoBoundingRect.UTF8String, SCStreamFrameInfoPresenterOverlayContentRect.UTF8String);

        SCStreamConfiguration *c = [SCStreamConfiguration new];
        printf("stream config:\n");
        dump(c, @[
            @"width", @"height", @"pixelFormat", @"scalesToFit", @"preservesAspectRatio", @"streamName", @"showsCursor",
            @"showMouseClicks", @"sourceRect", @"destinationRect", @"queueDepth", @"capturesAudio", @"sampleRate",
            @"channelCount", @"excludesCurrentProcessAudio", @"ignoreShadowsDisplay", @"ignoreShadowsSingleWindow",
            @"captureResolution", @"capturesShadowsOnly", @"shouldBeOpaque", @"ignoreGlobalClipDisplay",
            @"ignoreGlobalClipSingleWindow", @"presenterOverlayPrivacyAlertSetting", @"includeChildWindows",
            @"captureMicrophone", @"microphoneCaptureDeviceID", @"captureDynamicRange"
        ]);
        CMTime t = c.minimumFrameInterval;
        printf("  minimumFrameInterval %lld/%d flags %u\n", t.value, t.timescale, t.flags);
        printf("  backgroundColor %s colorMatrix %s colorSpaceName %s\n", [[(__bridge id)c.backgroundColor description] UTF8String],
            [(__bridge NSString *)c.colorMatrix UTF8String], [(__bridge NSString *)c.colorSpaceName UTF8String]);
        for (int p = 0; p < 5; p++) {
            SCStreamConfiguration *pc = [SCStreamConfiguration streamConfigurationWithPreset:p];
            printf("preset %d: pixelFormat %08x dyn %ld colorSpace %s matrix %s showsCursor %d queue %ld\n", p,
                (unsigned)pc.pixelFormat, (long)pc.captureDynamicRange, [(__bridge NSString *)pc.colorSpaceName UTF8String],
                [(__bridge NSString *)pc.colorMatrix UTF8String], pc.showsCursor, (long)pc.queueDepth);
        }

        SCScreenshotConfiguration *s = [SCScreenshotConfiguration new];
        printf("screenshot config:\n");
        dump(s, @[
            @"width", @"height", @"showsCursor", @"sourceRect", @"destinationRect", @"ignoreShadows", @"ignoreClipping",
            @"includeChildWindows", @"displayIntent", @"dynamicRange", @"contentType", @"fileURL"
        ]);
        printf("  supported %s\n",
            [[[SCScreenshotConfiguration supportedContentTypes] valueForKey:@"identifier"] componentsJoinedByString:@" "].UTF8String);
        SCScreenshotOutput *o = [SCScreenshotOutput new];
        printf("output %p %p %s\n", o.sdrImage, o.hdrImage, o.fileURL.description.UTF8String);

        SCRecordingOutputConfiguration *rc = [SCRecordingOutputConfiguration new];
        printf("recording config: url %s codec %s type %s\n  codecs %s\n  types %s\n", rc.outputURL.description.UTF8String,
            rc.videoCodecType.UTF8String, rc.outputFileType.UTF8String,
            [rc.availableVideoCodecTypes componentsJoinedByString:@" "].UTF8String,
            [rc.availableOutputFileTypes componentsJoinedByString:@" "].UTF8String);
        SCRecordingOutput *ro = [[SCRecordingOutput alloc] initWithConfiguration:rc delegate:(id)[NSNull null]];
        printf("recording output: duration %lld size %ld\n", ro.recordedDuration.value, (long)ro.recordedFileSize);

        SCContentSharingPickerConfiguration *pk = [SCContentSharingPickerConfiguration new];
        printf("picker config: modes %lu excluded windows %lu bundles %lu changing %d\n", (unsigned long)pk.allowedPickerModes,
            (unsigned long)pk.excludedWindowIDs.count, (unsigned long)pk.excludedBundleIDs.count, pk.allowsChangingSelectedContent);
        SCContentSharingPicker *sp = SCContentSharingPicker.sharedPicker;
        printf("picker: active %d max %s default modes %lu\n", sp.active, sp.maximumStreamCount.description.UTF8String,
            (unsigned long)sp.defaultConfiguration.allowedPickerModes);
    }
    return 0;
}
