/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CoreAudio's object and property API (AudioHardware.h). Finch has no audio
 * hardware driver yet, so the system object (kAudioObjectSystemObject) is
 * the only object: it has no devices, its default devices are
 * kAudioObjectUnknown, and other objects are bad objects, as Apple's
 * CoreAudio answers on a Mac with no audio devices. Listeners are kept (and
 * never called: nothing changes).
 */
#include <CoreAudio/AudioHardware.h>
#include <CoreAudio/AudioHardwareDeprecated.h>
#include <CoreAudio/AudioHardwareTapping.h>
#include <CoreAudio/HostTime.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <math.h>
#include <string.h>

/* The system object's properties, and their sizes (0: a variable list, empty). */
static UInt32
system_property_size(AudioObjectPropertySelector s, Boolean *known)
{
    *known = true;
    switch (s) {
    case kAudioHardwarePropertyDevices:
    case kAudioObjectPropertyOwnedObjects:
    case kAudioHardwarePropertyPlugInList:
    case kAudioHardwarePropertyBoxList:
    case kAudioHardwarePropertyClockDeviceList:
        return 0;
    case kAudioHardwarePropertyDefaultInputDevice:
    case kAudioHardwarePropertyDefaultOutputDevice:
    case kAudioHardwarePropertyDefaultSystemOutputDevice:
        return sizeof(AudioObjectID);
    case kAudioHardwarePropertyMixStereoToMono:
    case kAudioHardwarePropertyIsInitingOrExiting:
    case kAudioHardwarePropertySleepingIsAllowed:
    case kAudioHardwarePropertyUnloadingIsAllowed:
    case kAudioHardwarePropertyHogModeIsAllowed:
    case kAudioHardwarePropertyUserSessionIsActiveOrHeadless:
    case kAudioHardwarePropertyServiceRestarted:
    case kAudioHardwarePropertyPowerHint:
    case kAudioHardwarePropertyProcessIsMain:
        return sizeof(UInt32);
    case kAudioObjectPropertyClass:
    case kAudioObjectPropertyBaseClass:
        return sizeof(AudioClassID);
    case kAudioObjectPropertyName:
    case kAudioObjectPropertyManufacturer:
        return sizeof(CFStringRef);
    default:
        *known = false;
        return 0;
    }
}

Boolean
AudioObjectHasProperty(AudioObjectID inObjectID, const AudioObjectPropertyAddress *inAddress)
{
    Boolean known = false;
    if (inObjectID == kAudioObjectSystemObject && inAddress)
        system_property_size(inAddress->mSelector, &known);
    return known;
}

OSStatus
AudioObjectIsPropertySettable(AudioObjectID inObjectID, const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable)
{
    if (inObjectID != kAudioObjectSystemObject)
        return kAudioHardwareBadObjectError;
    if (!AudioObjectHasProperty(inObjectID, inAddress))
        return kAudioHardwareUnknownPropertyError;
    if (outIsSettable)
        *outIsSettable = false;
    return kAudioHardwareNoError;
}

OSStatus
AudioObjectGetPropertyDataSize(AudioObjectID inObjectID, const AudioObjectPropertyAddress *inAddress,
                               UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize)
{
    Boolean known;
    if (inObjectID != kAudioObjectSystemObject)
        return kAudioHardwareBadObjectError;
    if (!inAddress || !outDataSize)
        return kAudioHardwareIllegalOperationError;
    UInt32 size = system_property_size(inAddress->mSelector, &known);
    if (!known)
        return kAudioHardwareUnknownPropertyError;
    *outDataSize = size;
    return kAudioHardwareNoError;
}

OSStatus
AudioObjectGetPropertyData(AudioObjectID inObjectID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize,
                           const void *inQualifierData, UInt32 *ioDataSize, void *outData)
{
    Boolean known;
    if (inObjectID != kAudioObjectSystemObject)
        return kAudioHardwareBadObjectError;
    if (!inAddress || !ioDataSize)
        return kAudioHardwareIllegalOperationError;
    UInt32 size = system_property_size(inAddress->mSelector, &known);
    if (!known)
        return kAudioHardwareUnknownPropertyError;
    if (*ioDataSize < size || (size && !outData))
        return kAudioHardwareBadPropertySizeError;
    switch (inAddress->mSelector) {
    case kAudioHardwarePropertyDefaultInputDevice:
    case kAudioHardwarePropertyDefaultOutputDevice:
    case kAudioHardwarePropertyDefaultSystemOutputDevice:
        *(AudioObjectID *)outData = kAudioObjectUnknown;
        break;
    case kAudioObjectPropertyClass:
        *(AudioClassID *)outData = kAudioSystemObjectClassID;
        break;
    case kAudioObjectPropertyBaseClass:
        *(AudioClassID *)outData = kAudioObjectClassID;
        break;
    case kAudioObjectPropertyName:
        *(CFStringRef *)outData = CFSTR("The Audio System");
        break;
    case kAudioObjectPropertyManufacturer:
        *(CFStringRef *)outData = CFSTR("Finch");
        break;
    case kAudioHardwarePropertySleepingIsAllowed:
    case kAudioHardwarePropertyUnloadingIsAllowed:
    case kAudioHardwarePropertyHogModeIsAllowed:
    case kAudioHardwarePropertyUserSessionIsActiveOrHeadless:
    case kAudioHardwarePropertyProcessIsMain:
        *(UInt32 *)outData = 1;
        break;
    default:
        if (size)
            memset(outData, 0, size);
        break;
    }
    *ioDataSize = size;
    return kAudioHardwareNoError;
}

OSStatus
AudioObjectSetPropertyData(AudioObjectID inObjectID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize,
                           const void *inQualifierData, UInt32 inDataSize, const void *inData)
{
    if (inObjectID != kAudioObjectSystemObject)
        return kAudioHardwareBadObjectError;
    if (!AudioObjectHasProperty(inObjectID, inAddress))
        return kAudioHardwareUnknownPropertyError;
    return kAudioHardwareIllegalOperationError;
}

OSStatus
AudioObjectAddPropertyListener(AudioObjectID inObjectID, const AudioObjectPropertyAddress *inAddress,
                               AudioObjectPropertyListenerProc inListener, void *inClientData)
{
    return inObjectID == kAudioObjectSystemObject ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

OSStatus
AudioObjectRemovePropertyListener(AudioObjectID inObjectID, const AudioObjectPropertyAddress *inAddress,
                                  AudioObjectPropertyListenerProc inListener, void *inClientData)
{
    return inObjectID == kAudioObjectSystemObject ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

OSStatus
AudioObjectAddPropertyListenerBlock(AudioObjectID inObjectID, const AudioObjectPropertyAddress *inAddress,
                                    dispatch_queue_t inDispatchQueue, AudioObjectPropertyListenerBlock inListener)
{
    return inObjectID == kAudioObjectSystemObject ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

OSStatus
AudioObjectRemovePropertyListenerBlock(AudioObjectID inObjectID, const AudioObjectPropertyAddress *inAddress,
                                       dispatch_queue_t inDispatchQueue, AudioObjectPropertyListenerBlock inListener)
{
    return inObjectID == kAudioObjectSystemObject ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

void AudioObjectShow(AudioObjectID inObjectID) {}
OSStatus AudioHardwareUnload(void) { return kAudioHardwareNoError; }

/* Finch has no audio device driver yet. Every device ID is therefore invalid. */
OSStatus
AudioDeviceCreateIOProcID(AudioObjectID device, AudioDeviceIOProc proc, void *clientData,
                          AudioDeviceIOProcID *outProcID)
{
    (void)proc;
    (void)clientData;
    if (outProcID)
        *outProcID = NULL;
    return kAudioHardwareBadDeviceError;
}

OSStatus
AudioDeviceCreateIOProcIDWithBlock(AudioDeviceIOProcID *outProcID, AudioObjectID device,
                                   dispatch_queue_t queue, AudioDeviceIOBlock block)
{
    (void)queue;
    (void)block;
    if (outProcID)
        *outProcID = NULL;
    return kAudioHardwareBadDeviceError;
}

OSStatus
AudioDeviceDestroyIOProcID(AudioObjectID device, AudioDeviceIOProcID procID)
{
    (void)procID;
    return kAudioHardwareBadDeviceError;
}

OSStatus AudioDeviceStart(AudioObjectID device, AudioDeviceIOProcID procID)
{
    (void)procID;
    return kAudioHardwareBadDeviceError;
}

OSStatus AudioDeviceStop(AudioObjectID device, AudioDeviceIOProcID procID)
{
    (void)procID;
    return kAudioHardwareBadDeviceError;
}

OSStatus
AudioHardwareCreateAggregateDevice(CFDictionaryRef description, AudioObjectID *outDeviceID)
{
    (void)description;
    if (outDeviceID)
        *outDeviceID = kAudioObjectUnknown;
    return kAudioHardwareIllegalOperationError;
}

OSStatus AudioHardwareDestroyAggregateDevice(AudioObjectID device)
{
    (void)device;
    return kAudioHardwareNoError;
}

OSStatus AudioHardwareCreateProcessTap(void *description, AudioObjectID *outTapID)
{
    (void)description;
    if (outTapID)
        *outTapID = kAudioObjectUnknown;
    return kAudioHardwareBadObjectError;
}

OSStatus AudioHardwareDestroyProcessTap(AudioObjectID tapID)
{
    (void)tapID;
    return kAudioHardwareNoError;
}

OSStatus
AudioDeviceGetPropertyInfo(AudioDeviceID device, UInt32 channel, Boolean isInput,
                           AudioDevicePropertyID propertyID, UInt32 *outSize,
                           Boolean *outWritable)
{
    (void)channel;
    (void)isInput;
    (void)propertyID;
    if (outSize)
        *outSize = 0;
    if (outWritable)
        *outWritable = false;
    return kAudioHardwareBadDeviceError;
}

OSStatus
AudioDeviceGetProperty(AudioDeviceID device, UInt32 channel, Boolean isInput,
                       AudioDevicePropertyID propertyID, UInt32 *ioSize, void *outData)
{
    (void)channel;
    (void)isInput;
    (void)propertyID;
    if (ioSize)
        *ioSize = 0;
    (void)outData;
    return kAudioHardwareBadDeviceError;
}

OSStatus
AudioHardwareSetProperty(AudioHardwarePropertyID propertyID, UInt32 dataSize,
                          const void *data)
{
    AudioObjectPropertyAddress address = {
        .mSelector = propertyID,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain,
    };
    return AudioObjectSetPropertyData(kAudioObjectSystemObject, &address, 0, NULL,
                                      dataSize, data);
}

/* Older applications still use this four-argument CoreAudio SPI. */
OSStatus
AudioDeviceDuck(AudioDeviceID device, Float32 duckedLevel,
                const AudioTimeStamp *startTime, Float32 rampDuration)
{
    (void)duckedLevel;
    (void)startTime;
    (void)rampDuration;
    return kAudioHardwareBadDeviceError;
}

UInt64 AudioGetCurrentHostTime(void) { return mach_absolute_time(); }

static mach_timebase_info_data_t
host_timebase(void)
{
    mach_timebase_info_data_t info = {1, 1};
    mach_timebase_info(&info);
    return info;
}

Float64 AudioGetHostClockFrequency(void)
{
    mach_timebase_info_data_t info = host_timebase();
    return 1000000000.0 * (Float64)info.denom / (Float64)info.numer;
}

UInt32 AudioGetHostClockMinimumTimeDelta(void) { return 1; }

UInt64 AudioConvertHostTimeToNanos(UInt64 hostTime)
{
    mach_timebase_info_data_t info = host_timebase();
    __uint128_t value = (__uint128_t)hostTime * info.numer / info.denom;
    return value > UINT64_MAX ? UINT64_MAX : (UInt64)value;
}

UInt64 AudioConvertNanosToHostTime(UInt64 nanos)
{
    mach_timebase_info_data_t info = host_timebase();
    __uint128_t value = (__uint128_t)nanos * info.denom / info.numer;
    return value > UINT64_MAX ? UINT64_MAX : (UInt64)value;
}
