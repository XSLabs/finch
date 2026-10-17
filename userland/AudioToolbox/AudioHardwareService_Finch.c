/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* The old Audio Hardware Service calls share CoreAudio's object properties. */
#include <AudioToolbox/AudioHardwareService.h>

Boolean AudioHardwareServiceHasProperty(AudioObjectID object,
    const AudioObjectPropertyAddress *address)
{
	return AudioObjectHasProperty(object, address);
}

OSStatus AudioHardwareServiceIsPropertySettable(AudioObjectID object,
    const AudioObjectPropertyAddress *address, Boolean *settable)
{
	return AudioObjectIsPropertySettable(object, address, settable);
}

OSStatus AudioHardwareServiceGetPropertyDataSize(AudioObjectID object,
    const AudioObjectPropertyAddress *address, UInt32 qualifierSize,
    const void *qualifier, UInt32 *dataSize)
{
	return AudioObjectGetPropertyDataSize(object, address, qualifierSize, qualifier, dataSize);
}

OSStatus AudioHardwareServiceGetPropertyData(AudioObjectID object,
    const AudioObjectPropertyAddress *address, UInt32 qualifierSize,
    const void *qualifier, UInt32 *dataSize, void *data)
{
	return AudioObjectGetPropertyData(object, address, qualifierSize, qualifier, dataSize, data);
}

OSStatus AudioHardwareServiceSetPropertyData(AudioObjectID object,
    const AudioObjectPropertyAddress *address, UInt32 qualifierSize,
    const void *qualifier, UInt32 dataSize, const void *data)
{
	return AudioObjectSetPropertyData(object, address, qualifierSize, qualifier, dataSize, data);
}

OSStatus AudioHardwareServiceAddPropertyListener(AudioObjectID object,
    const AudioObjectPropertyAddress *address, AudioObjectPropertyListenerProc listener,
    void *clientData)
{
	return AudioObjectAddPropertyListener(object, address, listener, clientData);
}

OSStatus AudioHardwareServiceRemovePropertyListener(AudioObjectID object,
    const AudioObjectPropertyAddress *address, AudioObjectPropertyListenerProc listener,
    void *clientData)
{
	return AudioObjectRemovePropertyListener(object, address, listener, clientData);
}
