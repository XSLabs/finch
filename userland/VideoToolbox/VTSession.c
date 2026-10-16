/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "VTInternal.h"
#include <stdlib.h>
#include <string.h>

static CFTypeID typeIDs[4];
static pthread_once_t typeOnce[4] = {PTHREAD_ONCE_INIT, PTHREAD_ONCE_INIT, PTHREAD_ONCE_INIT, PTHREAD_ONCE_INIT};

static void
finalize_transfer(CFTypeRef cf)
{
    _VTSessionBaseFinalize(&((struct OpaqueVTPixelTransferSession *)cf)->session);
}

static void
finalize_rotation(CFTypeRef cf)
{
    _VTSessionBaseFinalize(&((struct OpaqueVTPixelRotationSession *)cf)->session);
}

static void
finalize_decompression(CFTypeRef cf)
{
    (void)cf;
    _VTDecompressionSessionFinalize(&((struct OpaqueVTDecompressionSession *)cf)->session);
}

static void
finalize_compression(CFTypeRef cf)
{
    (void)cf;
    _VTCompressionSessionFinalize(&((struct OpaqueVTCompressionSession *)cf)->session);
}

static const VTCFRuntimeClass classes[4] = {
    {0, "VTPixelTransferSession", NULL, NULL, finalize_transfer, NULL, NULL, NULL, NULL, NULL, NULL, 0},
    {0, "VTPixelRotationSession", NULL, NULL, finalize_rotation, NULL, NULL, NULL, NULL, NULL, NULL, 0},
    {0, "VTDecompressionSession", NULL, NULL, finalize_decompression, NULL, NULL, NULL, NULL, NULL, NULL, 0},
    {0, "VTCompressionSession", NULL, NULL, finalize_compression, NULL, NULL, NULL, NULL, NULL, NULL, 0}
};

static void
register_transfer(void) { typeIDs[VTKindPixelTransfer] = _CFRuntimeRegisterClass(&classes[VTKindPixelTransfer]); }
static void
register_rotation(void) { typeIDs[VTKindPixelRotation] = _CFRuntimeRegisterClass(&classes[VTKindPixelRotation]); }
static void
register_decompression(void) { typeIDs[VTKindDecompression] = _CFRuntimeRegisterClass(&classes[VTKindDecompression]); }
static void
register_compression(void) { typeIDs[VTKindCompression] = _CFRuntimeRegisterClass(&classes[VTKindCompression]); }

static void (*const registerFunctions[4])(void) = {
    register_transfer, register_rotation, register_decompression, register_compression
};

CFTypeID
_VTTypeID(VTKind kind)
{
    if (kind < VTKindPixelTransfer || kind > VTKindCompression)
        return 0;
    pthread_once(&typeOnce[kind], registerFunctions[kind]);
    return typeIDs[kind];
}

CFTypeRef
_VTCreateSession(CFAllocatorRef allocator, VTKind kind, size_t size)
{
    CFTypeID type = _VTTypeID(kind);
    if (!type || size < sizeof(VTSessionBase))
        return NULL;
    CFTypeRef object = _CFRuntimeCreateInstance(allocator, type, (CFIndex)(size - sizeof(VTCFRuntimeBase)), NULL);
    if (!object)
        return NULL;
    memset((char *)object + sizeof(VTCFRuntimeBase), 0, size - sizeof(VTCFRuntimeBase));
    VTSessionBase *session = (VTSessionBase *)object;
    session->kind = kind;
    if (pthread_mutex_init(&session->lock, NULL) != 0) {
        CFRelease(object);
        return NULL;
    }
    session->lockInitialized = true;
    session->properties = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    session->supportedProperties = _VTCreateSupportedProperties(kind, 0);
    if (!session->properties || !session->supportedProperties) {
        CFRelease(object);
        return NULL;
    }
    return object;
}

VTSessionBase *
_VTGetSession(CFTypeRef object)
{
    if (!object)
        return NULL;
    CFTypeID type = CFGetTypeID(object);
    for (VTKind kind = VTKindPixelTransfer; kind <= VTKindCompression; kind++)
        if (type == _VTTypeID(kind))
            return (VTSessionBase *)object;
    return NULL;
}

void
_VTSessionBaseFinalize(VTSessionBase *session)
{
    if (session->properties)
        CFRelease(session->properties);
    if (session->supportedProperties)
        CFRelease(session->supportedProperties);
    if (session->lockInitialized)
        pthread_mutex_destroy(&session->lock);
}

Boolean
_VTIsCFBoolean(CFTypeRef value)
{
    return value && CFGetTypeID(value) == CFBooleanGetTypeID();
}

Boolean
_VTIsCFNumber(CFTypeRef value)
{
    return value && CFGetTypeID(value) == CFNumberGetTypeID();
}

Boolean
_VTIsCFString(CFTypeRef value)
{
    return value && CFGetTypeID(value) == CFStringGetTypeID();
}

static CFNumberRef
number(int32_t value)
{
    return CFNumberCreate(NULL, kCFNumberSInt32Type, &value);
}

static CFDictionaryRef
property_info(CFStringRef type, CFStringRef access, Boolean serializable, CFArrayRef values)
{
    const void *keys[4], *items[4];
    CFIndex count = 0;
    keys[count] = kVTPropertyTypeKey;
    items[count++] = type;
    keys[count] = kVTPropertyReadWriteStatusKey;
    items[count++] = access;
    keys[count] = kVTPropertyShouldBeSerializedKey;
    items[count++] = serializable ? kCFBooleanTrue : kCFBooleanFalse;
    if (values) {
        keys[count] = kVTPropertySupportedValueListKey;
        items[count++] = values;
    }
    return CFDictionaryCreate(NULL, keys, items, count, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}

static void
add_property(CFMutableDictionaryRef properties, CFStringRef key, CFStringRef type, CFStringRef access,
             Boolean serializable, CFArrayRef values)
{
    CFDictionaryRef info = property_info(type, access, serializable, values);
    if (info) {
        CFDictionarySetValue(properties, key, info);
        CFRelease(info);
    }
}

static CFArrayRef
string_values(const CFStringRef *values, CFIndex count)
{
    return CFArrayCreate(NULL, (const void **)values, count, &kCFTypeArrayCallBacks);
}

CFDictionaryRef
_VTCreateSupportedProperties(VTKind kind, CMVideoCodecType codecType)
{
    (void)codecType;
    CFMutableDictionaryRef properties = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (!properties)
        return NULL;
    const CFStringRef scaling[] = {kVTScalingMode_Normal, kVTScalingMode_CropSourceToCleanAperture, kVTScalingMode_Letterbox, kVTScalingMode_Trim};
    const CFStringRef rotations[] = {kVTRotation_0, kVTRotation_CW90, kVTRotation_180, kVTRotation_CCW90};
    const CFStringRef profiles[] = {kVTProfileLevel_H264_Baseline_AutoLevel, kVTProfileLevel_H264_Main_AutoLevel, kVTProfileLevel_H264_High_AutoLevel};
    CFArrayRef scalingValues = string_values(scaling, 4);
    CFArrayRef rotationValues = string_values(rotations, 4);
    CFArrayRef profileValues = string_values(profiles, 3);

    if (kind == VTKindPixelTransfer) {
        add_property(properties, kVTPixelTransferPropertyKey_ScalingMode, kVTPropertyType_Enumeration, kVTPropertyReadWriteStatus_ReadWrite, true, scalingValues);
        const CFStringRef downsampling[] = {kVTDownsamplingMode_Decimate, kVTDownsamplingMode_Average};
        CFArrayRef downsamplingValues = string_values(downsampling, 2);
        add_property(properties, kVTPixelTransferPropertyKey_DownsamplingMode, kVTPropertyType_Enumeration, kVTPropertyReadWriteStatus_ReadWrite, true, downsamplingValues);
        CFRelease(downsamplingValues);
    } else if (kind == VTKindPixelRotation) {
        add_property(properties, kVTPixelRotationPropertyKey_Rotation, kVTPropertyType_Enumeration, kVTPropertyReadWriteStatus_ReadWrite, true, rotationValues);
        add_property(properties, kVTPixelRotationPropertyKey_FlipHorizontalOrientation, kVTPropertyType_Boolean, kVTPropertyReadWriteStatus_ReadWrite, true, NULL);
        add_property(properties, kVTPixelRotationPropertyKey_FlipVerticalOrientation, kVTPropertyType_Boolean, kVTPropertyReadWriteStatus_ReadWrite, true, NULL);
    } else if (kind == VTKindCompression) {
        add_property(properties, kVTCompressionPropertyKey_AverageBitRate, kVTPropertyType_Number, kVTPropertyReadWriteStatus_ReadWrite, true, NULL);
        add_property(properties, kVTCompressionPropertyKey_ExpectedFrameRate, kVTPropertyType_Number, kVTPropertyReadWriteStatus_ReadWrite, true, NULL);
        add_property(properties, kVTCompressionPropertyKey_MaxKeyFrameInterval, kVTPropertyType_Number, kVTPropertyReadWriteStatus_ReadWrite, true, NULL);
        add_property(properties, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, kVTPropertyType_Number, kVTPropertyReadWriteStatus_ReadWrite, true, NULL);
        add_property(properties, kVTCompressionPropertyKey_RealTime, kVTPropertyType_Boolean, kVTPropertyReadWriteStatus_ReadWrite, true, NULL);
        add_property(properties, kVTCompressionPropertyKey_AllowFrameReordering, kVTPropertyType_Boolean, kVTPropertyReadWriteStatus_ReadWrite, true, NULL);
        add_property(properties, kVTCompressionPropertyKey_ProfileLevel, kVTPropertyType_Enumeration, kVTPropertyReadWriteStatus_ReadWrite, true, profileValues);
        add_property(properties, kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, kVTPropertyType_Boolean, kVTPropertyReadWriteStatus_ReadOnly, false, NULL);
    }
    if (scalingValues) CFRelease(scalingValues);
    if (rotationValues) CFRelease(rotationValues);
    if (profileValues) CFRelease(profileValues);
    return properties;
}

static OSStatus
validate_property(VTSessionBase *session, CFStringRef key, CFTypeRef value)
{
    if (!session || !key)
        return kVTParameterErr;
    CFDictionaryRef info = CFDictionaryGetValue(session->supportedProperties, key);
    if (!info)
        return kVTPropertyNotSupportedErr;
    CFStringRef access = CFDictionaryGetValue(info, kVTPropertyReadWriteStatusKey);
    if (CFEqual(access, kVTPropertyReadWriteStatus_ReadOnly))
        return kVTPropertyNotSupportedErr;
    if (!value)
        return noErr;
    CFStringRef type = CFDictionaryGetValue(info, kVTPropertyTypeKey);
    if (CFEqual(type, kVTPropertyType_Boolean))
        return _VTIsCFBoolean(value) ? noErr : kVTPropertyNotSupportedErr;
    if (CFEqual(type, kVTPropertyType_Number))
        return _VTIsCFNumber(value) ? noErr : kVTPropertyNotSupportedErr;
    if (CFEqual(type, kVTPropertyType_Enumeration)) {
        if (CFGetTypeID(value) != CFStringGetTypeID())
            return kVTPropertyNotSupportedErr;
        CFArrayRef allowed = CFDictionaryGetValue(info, kVTPropertySupportedValueListKey);
        return allowed && CFArrayContainsValue(allowed, CFRangeMake(0, CFArrayGetCount(allowed)), value) ? noErr : kVTPropertyNotSupportedErr;
    }
    return kVTPropertyNotSupportedErr;
}

OSStatus
_VTSetSessionProperty(VTSessionBase *session, CFStringRef key, CFTypeRef value)
{
    OSStatus status = validate_property(session, key, value);
    if (status != noErr)
        return status;
    if (session->kind == VTKindCompression && CFEqual(key, kVTCompressionPropertyKey_AllowFrameReordering) &&
        value && CFEqual(value, kCFBooleanTrue))
        return kVTPropertyNotSupportedErr;
    pthread_mutex_lock(&session->lock);
    if (session->invalidated) {
        pthread_mutex_unlock(&session->lock);
        return kVTInvalidSessionErr;
    }
    if (session->kind == VTKindCompression) {
        OSStatus changed = _VTCompressionPropertyChanged((struct OpaqueVTCompressionSession *)session, key, value);
        if (changed != noErr) {
            pthread_mutex_unlock(&session->lock);
            return changed;
        }
    }
    if (value)
        CFDictionarySetValue(session->properties, key, value);
    else
        CFDictionaryRemoveValue(session->properties, key);
    pthread_mutex_unlock(&session->lock);
    return noErr;
}

CFTypeRef
_VTCopySessionProperty(VTSessionBase *session, CFStringRef key)
{
    if (!session || !key || !CFDictionaryContainsKey(session->supportedProperties, key))
        return NULL;
    pthread_mutex_lock(&session->lock);
    CFTypeRef value = CFDictionaryGetValue(session->properties, key);
    if (value)
        CFRetain(value);
    pthread_mutex_unlock(&session->lock);
    if (value)
        return value;
    if (session->kind == VTKindPixelTransfer && CFEqual(key, kVTPixelTransferPropertyKey_ScalingMode))
        return CFRetain(kVTScalingMode_Normal);
    if (session->kind == VTKindPixelRotation && CFEqual(key, kVTPixelRotationPropertyKey_Rotation))
        return CFRetain(kVTRotation_0);
    if (session->kind == VTKindPixelRotation &&
        (CFEqual(key, kVTPixelRotationPropertyKey_FlipHorizontalOrientation) || CFEqual(key, kVTPixelRotationPropertyKey_FlipVerticalOrientation)))
        return CFRetain(kCFBooleanFalse);
    if (session->kind == VTKindCompression && CFEqual(key, kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder))
        return CFRetain(kCFBooleanFalse);
    if (session->kind == VTKindCompression && CFEqual(key, kVTCompressionPropertyKey_ProfileLevel))
        return CFRetain(kVTProfileLevel_H264_Baseline_AutoLevel);
    if (session->kind == VTKindCompression && CFEqual(key, kVTCompressionPropertyKey_RealTime))
        return CFRetain(kCFBooleanFalse);
    if (session->kind == VTKindCompression && CFEqual(key, kVTCompressionPropertyKey_AllowFrameReordering))
        return CFRetain(kCFBooleanFalse);
    if (session->kind == VTKindCompression && CFEqual(key, kVTCompressionPropertyKey_AverageBitRate)) {
        int32_t valueNumber = 0;
        if (session->kind == VTKindCompression) valueNumber = ((struct OpaqueVTCompressionSession *)session)->bitrate;
        return number(valueNumber);
    }
    if (session->kind == VTKindCompression && CFEqual(key, kVTCompressionPropertyKey_ExpectedFrameRate)) {
        int32_t valueNumber = ((struct OpaqueVTCompressionSession *)session)->frameRate;
        return number(valueNumber);
    }
    if (session->kind == VTKindCompression && CFEqual(key, kVTCompressionPropertyKey_MaxKeyFrameInterval)) {
        int32_t valueNumber = ((struct OpaqueVTCompressionSession *)session)->keyFrameInterval;
        return number(valueNumber);
    }
    return NULL;
}

CFTypeID
VTPixelTransferSessionGetTypeID(void)
{
    return _VTTypeID(VTKindPixelTransfer);
}

CFTypeID
VTPixelRotationSessionGetTypeID(void)
{
    return _VTTypeID(VTKindPixelRotation);
}

CFTypeID
VTDecompressionSessionGetTypeID(void)
{
    return _VTTypeID(VTKindDecompression);
}

CFTypeID
VTCompressionSessionGetTypeID(void)
{
    return _VTTypeID(VTKindCompression);
}

OSStatus
VTSessionSetProperty(VTSessionRef sessionRef, CFStringRef key, CFTypeRef value)
{
    return _VTSetSessionProperty(_VTGetSession(sessionRef), key, value);
}

OSStatus
VTSessionSetProperties(VTSessionRef sessionRef, CFDictionaryRef properties)
{
    VTSessionBase *session = _VTGetSession(sessionRef);
    if (!session || !properties)
        return kVTParameterErr;
    CFIndex count = CFDictionaryGetCount(properties);
    const void **keys = calloc((size_t)count, sizeof(*keys));
    const void **values = calloc((size_t)count, sizeof(*values));
    if (count && (!keys || !values)) {
        free(keys); free(values);
        return kVTAllocationFailedErr;
    }
    CFDictionaryGetKeysAndValues(properties, keys, values);
    OSStatus status = noErr;
    for (CFIndex i = 0; i < count; i++) {
        status = validate_property(session, keys[i], values[i]);
        if (status != noErr) break;
        if (session->kind == VTKindCompression && CFEqual(keys[i], kVTCompressionPropertyKey_AllowFrameReordering) &&
            CFEqual(values[i], kCFBooleanTrue)) {
            status = kVTPropertyNotSupportedErr;
            break;
        }
    }
    if (status == noErr)
        for (CFIndex i = 0; i < count; i++) {
            status = _VTSetSessionProperty(session, keys[i], values[i]);
            if (status != noErr) break;
        }
    free(keys); free(values);
    return status;
}

OSStatus
VTSessionCopyProperty(VTSessionRef sessionRef, CFStringRef key, CFAllocatorRef allocator, void *propertyValueOut)
{
    (void)allocator;
    VTSessionBase *session = _VTGetSession(sessionRef);
    if (!session || !key || !propertyValueOut)
        return kVTParameterErr;
    CFTypeRef value = _VTCopySessionProperty(session, key);
    if (!value)
        return kVTPropertyNotSupportedErr;
    *(CFTypeRef *)propertyValueOut = value;
    return noErr;
}

OSStatus
VTSessionCopySupportedPropertyDictionary(VTSessionRef sessionRef, CFDictionaryRef *supportedPropertyDictionaryOut)
{
    VTSessionBase *session = _VTGetSession(sessionRef);
    if (!session || !supportedPropertyDictionaryOut)
        return kVTParameterErr;
    *supportedPropertyDictionaryOut = CFRetain(session->supportedProperties);
    return noErr;
}

OSStatus
VTSessionCopySerializableProperties(VTSessionRef sessionRef, CFAllocatorRef allocator, CFDictionaryRef *dictionaryOut)
{
    (void)allocator;
    VTSessionBase *session = _VTGetSession(sessionRef);
    if (!session || !dictionaryOut)
        return kVTParameterErr;
    CFMutableDictionaryRef result = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (!result)
        return kVTAllocationFailedErr;
    CFIndex count = CFDictionaryGetCount(session->supportedProperties);
    const void **keys = calloc((size_t)count, sizeof(*keys));
    if (count && !keys) {
        CFRelease(result);
        return kVTAllocationFailedErr;
    }
    CFDictionaryGetKeysAndValues(session->supportedProperties, keys, NULL);
    for (CFIndex i = 0; i < count; i++) {
        CFDictionaryRef info = CFDictionaryGetValue(session->supportedProperties, keys[i]);
        if (CFDictionaryGetValue(info, kVTPropertyShouldBeSerializedKey) == kCFBooleanTrue) {
            CFTypeRef value = _VTCopySessionProperty(session, keys[i]);
            if (value) {
                CFDictionarySetValue(result, keys[i], value);
                CFRelease(value);
            }
        }
    }
    free(keys);
    *dictionaryOut = result;
    return noErr;
}

void
_VTSessionPropertyChanged(VTSessionBase *session, CFStringRef key, CFTypeRef value)
{
    (void)session;
    (void)key;
    (void)value;
}
