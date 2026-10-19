/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Compare capture classes and value state without reading the host's real devices. */
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>

int
main(void)
{
    @autoreleasepool {
        printf("classes %d %d %d %d %d\n", [AVCaptureDevice class] != Nil,
               [AVCaptureSession class] != Nil, [AVCapturePhotoSettings class] != Nil,
               [AVCaptureVideoDataOutput class] != Nil, [AVCaptureVideoPreviewLayer class] != Nil);
        printf("input port class %d audio record selector %d\n", [AVCaptureInputPort class] != Nil,
               [AVCaptureAudioFileOutput instancesRespondToSelector:@selector(startRecordingToOutputFileURL:outputFileType:recordingDelegate:)]);

        AVCaptureDeviceDiscoverySession *discovery =
            [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[]
                                                                    mediaType:nil
                                                                     position:AVCaptureDevicePositionUnspecified];
        printf("empty discovery %lu\n", (unsigned long)discovery.devices.count);

        printf("bogus unique ID %d\n", [AVCaptureDevice deviceWithUniqueID:@"finch.no-such-device"] == nil);

        AVCapturePhotoSettings *settings = [AVCapturePhotoSettings photoSettingsWithFormat:@{ AVVideoCodecKey : AVVideoCodecTypeJPEG }];
        settings.flashMode = AVCaptureFlashModeOn;
        settings.photoQualityPrioritization = AVCapturePhotoQualityPrioritizationQuality;
        settings.maxPhotoDimensions = (CMVideoDimensions){640, 480};
        AVCapturePhotoSettings *copy = [settings copy];
        printf("photo settings %s %ld %ld %d %d\n", [[settings.format objectForKey:AVVideoCodecKey] description].UTF8String,
               (long)settings.flashMode, (long)settings.photoQualityPrioritization,
               settings.maxPhotoDimensions.width, copy.maxPhotoDimensions.height);

        AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
        output.alwaysDiscardsLateVideoFrames = NO;
        printf("video output discards late frames %d\n", output.alwaysDiscardsLateVideoFrames);

        AVCapturePhotoOutput *photoOutput = [[AVCapturePhotoOutput alloc] init];
        NSArray *photoPixels = ((id (*)(id, SEL, id))objc_msgSend)(photoOutput,
            @selector(supportedPhotoPixelFormatTypesForFileType:), AVFileTypeJPEG);
        NSArray *photoCodecs = ((id (*)(id, SEL, id))objc_msgSend)(photoOutput,
            @selector(supportedPhotoCodecTypesForFileType:), AVFileTypeJPEG);
        AVCaptureMovieFileOutput *movieOutput = [[AVCaptureMovieFileOutput alloc] init];
        NSDictionary *movieSettings = ((id (*)(id, SEL, id))objc_msgSend)(movieOutput,
            @selector(outputSettingsForConnection:), nil);
        ((void (*)(id, SEL, id, id))objc_msgSend)(movieOutput,
            @selector(setOutputSettings:forConnection:), @{}, nil);
        printf("device-free output formats %lu %lu movie settings nil %d\n",
               (unsigned long)photoPixels.count, (unsigned long)photoCodecs.count, movieSettings == nil);

        AVCaptureSession *session = [[AVCaptureSession alloc] init];
        printf("session preset %s\n", session.sessionPreset.UTF8String);
        BOOL canAdd = [session canAddOutput:output];
        if (canAdd)
            [session addOutput:output];
        printf("session output %d %lu\n", canAdd, (unsigned long)session.outputs.count);
        [session startRunning];
        BOOL running = session.isRunning;
        [session stopRunning];
        printf("session transitions %d %d\n", running, session.isRunning);

        AVCaptureVideoPreviewLayer *layer = [AVCaptureVideoPreviewLayer layerWithSession:session];
        printf("preview %d %d %s\n", layer.session == session, layer.connection != nil,
               layer.videoGravity.UTF8String);
        [layer setSessionWithNoConnection:session];
        printf("no-connection preview %d %d\n", layer.session == session, layer.connection == nil);
    }
    return 0;
}
