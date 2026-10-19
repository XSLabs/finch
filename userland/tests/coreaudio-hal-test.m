/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Compare stable HAL error paths and host-clock conversions, never live device lists. */
#import <CoreAudio/AudioHardware.h>
#import <CoreAudio/AudioHardwareDeprecated.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/HostTime.h>
#import <Foundation/Foundation.h>

extern OSStatus AudioDeviceDuck(AudioDeviceID, Float32, const AudioTimeStamp *, Float32);

static OSStatus
io_proc(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
        const AudioTimeStamp *inputTime, AudioBufferList *output, const AudioTimeStamp *outputTime,
        void *clientData)
{
    (void)device; (void)now; (void)input; (void)inputTime;
    (void)output; (void)outputTime; (void)clientData;
    return noErr;
}

int
main(void)
{
    @autoreleasepool {
        AudioDeviceID bogus = 0x7ffffffe;
        AudioDeviceIOProcID procID = NULL;
        UInt32 size = sizeof(Float64);
        Float64 property = 0;
        Boolean writable = true;
        OSStatus create = AudioDeviceCreateIOProcID(bogus, io_proc, NULL, &procID);
        printf("device start/stop %d %d\n", (int)AudioDeviceStart(bogus, NULL), (int)AudioDeviceStop(bogus, NULL));
        printf("io proc %d %p %d\n", (int)create, (void *)procID, (int)AudioDeviceDestroyIOProcID(bogus, procID));
        OSStatus propertyInfo = AudioDeviceGetPropertyInfo(bogus, 0, false,
            kAudioDevicePropertyNominalSampleRate, &size, &writable);
        UInt32 dataSize = sizeof(property);
        OSStatus propertyGet = AudioDeviceGetProperty(bogus, 0, false,
            kAudioDevicePropertyNominalSampleRate, &dataSize, &property);
        printf("legacy property %d %d %u %d\n", (int)propertyInfo, (int)propertyGet,
               (unsigned)size, (int)writable);
        printf("duck %d\n", (int)AudioDeviceDuck(bogus, 0.5f, NULL, 0.1f));

        NSDictionary *subdevice = @{ @kAudioSubDeviceUIDKey : @"finch.no-such-device" };
        NSArray *subdevices = @[ subdevice ];
        NSDictionary *description = @{
            @kAudioAggregateDeviceNameKey : @"Finch test",
            @kAudioAggregateDeviceUIDKey : @"finch.test.aggregate",
            @kAudioAggregateDeviceSubDeviceListKey : subdevices,
        };
        AudioObjectID aggregateID = 0;
        OSStatus aggregate = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)description, &aggregateID);
        printf("aggregate %d %u destroy %d\n", (int)aggregate, (unsigned)aggregateID,
               (int)AudioHardwareDestroyAggregateDevice(bogus));

        CATapDescription *tap = [[CATapDescription alloc] initStereoMixdownOfProcesses:@[@(bogus)]];
        tap.name = @"Finch test tap";
        tap.privateTap = YES;
        tap.muteBehavior = CATapMuted;
        AudioObjectID tapID = 0;
        OSStatus tapCreate = AudioHardwareCreateProcessTap(tap, &tapID);
        printf("tap description %s %lu %d %d\n", tap.name.UTF8String,
               (unsigned long)tap.processes.count, tap.isPrivate, (int)tap.muteBehavior);
        printf("tap create/destroy %d %u %d\n", (int)tapCreate, (unsigned)tapID,
               (int)AudioHardwareDestroyProcessTap(bogus));

        UInt32 unknownSelector = 0x7ffffffe;
        UInt32 data = 0;
        printf("hardware set %d\n", (int)AudioHardwareSetProperty(unknownSelector, sizeof(data), &data));
        printf("host clock %u %.0f %llu %llu %d\n", (unsigned)AudioGetHostClockMinimumTimeDelta(),
               AudioGetHostClockFrequency(), (unsigned long long)AudioConvertHostTimeToNanos(1234567),
               (unsigned long long)AudioConvertNanosToHostTime(1234567), AudioGetCurrentHostTime() != 0);

        if (aggregate == noErr)
            AudioHardwareDestroyAggregateDevice(aggregateID);
        if (tapCreate == noErr)
            AudioHardwareDestroyProcessTap(tapID);
    }
    return 0;
}
