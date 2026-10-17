/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Process-local IOHID elements and values. No hardware is fabricated here. */
#include <CoreFoundation/CFRuntime.h>
#include <IOKit/hid/IOHIDElement.h>
#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/hid/IOHIDValue.h>
#include <Block.h>
#include <math.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
	CFRuntimeBase base;
	CFMutableDictionaryRef properties;
	CFMutableArrayRef attached;
	struct IOHIDElementOpaque *parent;
} HIDElement;

typedef struct {
	CFRuntimeBase base;
	IOHIDElementRef element;
	uint64_t timestamp;
	CFIndex length;
	const uint8_t *bytes;
	uint8_t storage[8];
} HIDValue;

typedef struct {
	CFRuntimeBase base;
	CFMutableDictionaryRef properties;
	CFTypeRef deviceMatching;
	CFTypeRef inputMatching;
	CFMutableArrayRef schedules;
	dispatch_queue_t queue;
	dispatch_block_t cancelHandler;
	IOHIDDeviceCallback matchingCallback, removalCallback;
	void *matchingContext, *removalContext;
	IOHIDReportCallback reportCallback;
	IOHIDReportWithTimeStampCallback timestampReportCallback;
	void *reportContext, *timestampReportContext;
	IOHIDValueCallback valueCallback;
	void *valueContext;
	bool opened, active, canceled;
} HIDManager;

static void elementFinalize(CFTypeRef object)
{
	HIDElement *element = (HIDElement *)object;
	if (element->properties) CFRelease(element->properties);
	if (element->attached) CFRelease(element->attached);
}

static void valueFinalize(CFTypeRef object)
{
	HIDValue *value = (HIDValue *)object;
	if (value->element) CFRelease(value->element);
}

static void managerFinalize(CFTypeRef object)
{
	HIDManager *manager = (HIDManager *)object;
	if (manager->properties) CFRelease(manager->properties);
	if (manager->deviceMatching) CFRelease(manager->deviceMatching);
	if (manager->inputMatching) CFRelease(manager->inputMatching);
	if (manager->schedules) CFRelease(manager->schedules);
	if (manager->queue) dispatch_release(manager->queue);
	if (manager->cancelHandler) Block_release(manager->cancelHandler);
}

static const CFRuntimeClass elementClass = {
	0, "IOHIDElement", NULL, NULL, elementFinalize, NULL, NULL, NULL, NULL, NULL, NULL
};
static const CFRuntimeClass valueClass = {
	0, "IOHIDValue", NULL, NULL, valueFinalize, NULL, NULL, NULL, NULL, NULL, NULL
};
static const CFRuntimeClass managerClass = {
	0, "IOHIDManager", NULL, NULL, managerFinalize, NULL, NULL, NULL, NULL, NULL, NULL
};
static pthread_once_t elementOnce = PTHREAD_ONCE_INIT;
static pthread_once_t valueOnce = PTHREAD_ONCE_INIT;
static pthread_once_t managerOnce = PTHREAD_ONCE_INIT;
static CFTypeID elementType = _kCFRuntimeNotATypeID;
static CFTypeID valueType = _kCFRuntimeNotATypeID;
static CFTypeID managerType = _kCFRuntimeNotATypeID;

static void registerElement(void) { elementType = _CFRuntimeRegisterClass(&elementClass); }
static void registerValue(void) { valueType = _CFRuntimeRegisterClass(&valueClass); }
static void registerManager(void) { managerType = _CFRuntimeRegisterClass(&managerClass); }

CFTypeID IOHIDElementGetTypeID(void)
{
	pthread_once(&elementOnce, registerElement);
	return elementType;
}

CFTypeID IOHIDValueGetTypeID(void)
{
	pthread_once(&valueOnce, registerValue);
	return valueType;
}

CFTypeID IOHIDManagerGetTypeID(void)
{
	pthread_once(&managerOnce, registerManager);
	return managerType;
}

static void *createObject(CFAllocatorRef allocator, CFTypeID type, size_t size)
{
	if (size < sizeof(CFRuntimeBase))
		return NULL;
	void *object = _CFRuntimeCreateInstance(allocator, type, size - sizeof(CFRuntimeBase), NULL);
	if (object)
		memset((uint8_t *)object + sizeof(CFRuntimeBase), 0, size - sizeof(CFRuntimeBase));
	return object;
}

IOHIDElementRef IOHIDElementCreateWithDictionary(CFAllocatorRef allocator, CFDictionaryRef dictionary)
{
	if (!dictionary || CFGetTypeID(dictionary) != CFDictionaryGetTypeID())
		return NULL;
	return (IOHIDElementRef)createObject(allocator, IOHIDElementGetTypeID(), sizeof(HIDElement));
}

IOHIDDeviceRef IOHIDElementGetDevice(IOHIDElementRef element)
{
	return NULL;
}

IOHIDElementRef IOHIDElementGetParent(IOHIDElementRef element)
{
	return element ? (IOHIDElementRef)((HIDElement *)element)->parent : NULL;
}

CFArrayRef IOHIDElementGetChildren(IOHIDElementRef element)
{
	return NULL;
}

static void addAttached(HIDElement *element, IOHIDElementRef other)
{
	if (!element->attached)
		element->attached = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	CFRange all = CFRangeMake(0, CFArrayGetCount(element->attached));
	if (!CFArrayContainsValue(element->attached, all, other))
		CFArrayAppendValue(element->attached, other);
}

void IOHIDElementAttach(IOHIDElementRef elementRef, IOHIDElementRef otherRef)
{
	if (!elementRef || !otherRef || elementRef == otherRef)
		return;
	addAttached((HIDElement *)elementRef, otherRef);
	addAttached((HIDElement *)otherRef, elementRef);
}

static void removeAttached(HIDElement *element, IOHIDElementRef other)
{
	if (!element->attached)
		return;
	for (CFIndex i = CFArrayGetCount(element->attached) - 1; i >= 0; i--) {
		if (CFArrayGetValueAtIndex(element->attached, i) == other)
			CFArrayRemoveValueAtIndex(element->attached, i);
	}
	if (CFArrayGetCount(element->attached) == 0) {
		CFRelease(element->attached);
		element->attached = NULL;
	}
}

void IOHIDElementDetach(IOHIDElementRef elementRef, IOHIDElementRef otherRef)
{
	if (!elementRef || !otherRef)
		return;
	removeAttached((HIDElement *)elementRef, otherRef);
	removeAttached((HIDElement *)otherRef, elementRef);
}

CFArrayRef IOHIDElementCopyAttached(IOHIDElementRef element)
{
	HIDElement *e = (HIDElement *)element;
	return e && e->attached ? CFArrayCreateCopy(NULL, e->attached) : NULL;
}

IOHIDElementCookie IOHIDElementGetCookie(IOHIDElementRef element) { return 0; }
IOHIDElementType IOHIDElementGetType(IOHIDElementRef element) { return 0; }
IOHIDElementCollectionType IOHIDElementGetCollectionType(IOHIDElementRef element) { return 0; }
uint32_t IOHIDElementGetUsagePage(IOHIDElementRef element) { return 0; }
uint32_t IOHIDElementGetUsage(IOHIDElementRef element) { return 0; }
Boolean IOHIDElementIsVirtual(IOHIDElementRef element) { return false; }
Boolean IOHIDElementIsRelative(IOHIDElementRef element) { return false; }
Boolean IOHIDElementIsWrapping(IOHIDElementRef element) { return false; }
Boolean IOHIDElementIsArray(IOHIDElementRef element) { return true; }
Boolean IOHIDElementIsNonLinear(IOHIDElementRef element) { return false; }
Boolean IOHIDElementHasPreferredState(IOHIDElementRef element) { return true; }
Boolean IOHIDElementHasNullState(IOHIDElementRef element) { return false; }

CFStringRef IOHIDElementGetName(IOHIDElementRef element)
{
	return IOHIDElementGetProperty(element, CFSTR(kIOHIDElementNameKey));
}

uint32_t IOHIDElementGetReportID(IOHIDElementRef element) { return 0; }
uint32_t IOHIDElementGetReportSize(IOHIDElementRef element) { return 0; }
uint32_t IOHIDElementGetReportCount(IOHIDElementRef element) { return 0; }
uint32_t IOHIDElementGetUnit(IOHIDElementRef element) { return 0; }
uint32_t IOHIDElementGetUnitExponent(IOHIDElementRef element) { return 0; }
CFIndex IOHIDElementGetLogicalMin(IOHIDElementRef element) { return 0; }
CFIndex IOHIDElementGetLogicalMax(IOHIDElementRef element) { return 0; }
CFIndex IOHIDElementGetPhysicalMin(IOHIDElementRef element) { return 0; }
CFIndex IOHIDElementGetPhysicalMax(IOHIDElementRef element) { return 0; }

CFTypeRef IOHIDElementGetProperty(IOHIDElementRef element, CFStringRef key)
{
	HIDElement *e = (HIDElement *)element;
	return e && e->properties && key ? CFDictionaryGetValue(e->properties, key) : NULL;
}

Boolean IOHIDElementSetProperty(IOHIDElementRef element, CFStringRef key, CFTypeRef property)
{
	HIDElement *e = (HIDElement *)element;
	if (!e || !key || !property)
		return false;
	if (!e->properties)
		e->properties = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
		    &kCFTypeDictionaryValueCallBacks);
	if (!e->properties)
		return false;
	CFDictionarySetValue(e->properties, key, property);
	return true;
}

static IOHIDValueRef createValue(CFAllocatorRef allocator, IOHIDElementRef element, uint64_t timestamp)
{
	if (!element)
		return NULL;
	HIDValue *value = createObject(allocator, IOHIDValueGetTypeID(), sizeof(*value));
	if (!value)
		return NULL;
	value->element = CFRetain(element);
	value->timestamp = timestamp;
	return (IOHIDValueRef)value;
}

IOHIDValueRef IOHIDValueCreateWithIntegerValue(CFAllocatorRef allocator, IOHIDElementRef element,
    uint64_t timestamp, CFIndex integer)
{
	HIDValue *value = (HIDValue *)createValue(allocator, element, timestamp);
	if (value)
		value->bytes = value->storage;
	return (IOHIDValueRef)value;
}

IOHIDValueRef IOHIDValueCreateWithBytes(CFAllocatorRef allocator, IOHIDElementRef element, uint64_t timestamp,
    const uint8_t *bytes, CFIndex length)
{
	if (!bytes || length <= 0)
		return NULL;
	HIDValue *value = (HIDValue *)createValue(allocator, element, timestamp);
	if (value)
		value->bytes = value->storage;
	return (IOHIDValueRef)value;
}

IOHIDValueRef IOHIDValueCreateWithBytesNoCopy(CFAllocatorRef allocator, IOHIDElementRef element,
    uint64_t timestamp, const uint8_t *bytes, CFIndex length)
{
	if (!bytes || length <= 0)
		return NULL;
	HIDValue *value = (HIDValue *)createValue(allocator, element, timestamp);
	if (value)
		value->bytes = bytes;
	return (IOHIDValueRef)value;
}

IOHIDElementRef IOHIDValueGetElement(IOHIDValueRef value) { return value ? ((HIDValue *)value)->element : NULL; }
uint64_t IOHIDValueGetTimeStamp(IOHIDValueRef value) { return value ? ((HIDValue *)value)->timestamp : 0; }
CFIndex IOHIDValueGetLength(IOHIDValueRef value) { return value ? ((HIDValue *)value)->length : 0; }
const uint8_t *IOHIDValueGetBytePtr(IOHIDValueRef value) { return value ? ((HIDValue *)value)->bytes : NULL; }

CFIndex IOHIDValueGetIntegerValue(IOHIDValueRef value)
{
	if (!value)
		return 0;
	HIDValue *v = (HIDValue *)value;
	uint64_t integer = 0;
	CFIndex count = v->length < (CFIndex)sizeof(integer) ? v->length : (CFIndex)sizeof(integer);
	for (CFIndex i = 0; i < count; i++)
		integer |= (uint64_t)v->bytes[i] << (8 * i);
	if (count && (IOHIDElementGetLogicalMin(v->element) < 0 || IOHIDElementGetLogicalMax(v->element) < 0) &&
	    count < (CFIndex)sizeof(integer) && (v->bytes[count - 1] & 0x80))
		integer |= UINT64_MAX << (8 * count);
	return (CFIndex)integer;
}

double_t IOHIDValueGetScaledValue(IOHIDValueRef value, IOHIDValueScaleType type)
{
	if (!value)
		return 0;
	HIDValue *v = (HIDValue *)value;
	CFIndex logical = IOHIDValueGetIntegerValue(value);
	CFIndex min = IOHIDElementGetLogicalMin(v->element), max = IOHIDElementGetLogicalMax(v->element);
	CFIndex scaledMin = IOHIDElementGetPhysicalMin(v->element), scaledMax = IOHIDElementGetPhysicalMax(v->element);
	if (type == kIOHIDValueScaleTypeCalibrated) {
		scaledMin = -1;
		scaledMax = 1;
	}
	double_t exponent = 1;
	if (type == kIOHIDValueScaleTypeExponent) {
		uint8_t unitExp = IOHIDElementGetUnitExponent(v->element) & 0x0f;
		exponent = unitExp < 8 ? pow(10, unitExp) : 1.0 / pow(10, 0x10 - unitExp);
	}
	double_t result = ((double_t)(logical - min) * (double_t)(scaledMax - scaledMin) /
	    (double_t)(max - min)) + scaledMin;
	return result * exponent;
}

IOHIDManagerRef IOHIDManagerCreate(CFAllocatorRef allocator, IOOptionBits options)
{
	(void)options;
	return (IOHIDManagerRef)createObject(allocator, IOHIDManagerGetTypeID(), sizeof(HIDManager));
}

IOReturn IOHIDManagerOpen(IOHIDManagerRef reference, IOOptionBits options)
{
	(void)options;
	if (!reference) return kIOReturnBadArgument;
	((HIDManager *)reference)->opened = true;
	return kIOReturnSuccess;
}

IOReturn IOHIDManagerClose(IOHIDManagerRef reference, IOOptionBits options)
{
	(void)options;
	if (!reference) return kIOReturnBadArgument;
	((HIDManager *)reference)->opened = false;
	return kIOReturnSuccess;
}

CFTypeRef IOHIDManagerGetProperty(IOHIDManagerRef reference, CFStringRef key)
{
	HIDManager *manager = (HIDManager *)reference;
	return manager && manager->properties && key ? CFDictionaryGetValue(manager->properties, key) : NULL;
}

Boolean IOHIDManagerSetProperty(IOHIDManagerRef reference, CFStringRef key, CFTypeRef value)
{
	HIDManager *manager = (HIDManager *)reference;
	if (!manager || !key || !value) return false;
	if (!manager->properties)
		manager->properties = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
		    &kCFTypeDictionaryValueCallBacks);
	if (!manager->properties) return false;
	CFDictionarySetValue(manager->properties, key, value);
	return true;
}

static bool sameSchedule(CFTypeRef pair, CFRunLoopRef runLoop, CFStringRef mode)
{
	return CFGetTypeID(pair) == CFArrayGetTypeID() && CFArrayGetCount(pair) == 2 &&
	    CFArrayGetValueAtIndex(pair, 0) == runLoop && CFEqual(CFArrayGetValueAtIndex(pair, 1), mode);
}

void IOHIDManagerScheduleWithRunLoop(IOHIDManagerRef reference, CFRunLoopRef runLoop, CFStringRef mode)
{
	HIDManager *manager = (HIDManager *)reference;
	if (!manager || !runLoop || !mode) return;
	if (!manager->schedules)
		manager->schedules = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	for (CFIndex i = 0; manager->schedules && i < CFArrayGetCount(manager->schedules); i++)
		if (sameSchedule(CFArrayGetValueAtIndex(manager->schedules, i), runLoop, mode)) return;
	CFArrayRef pair = CFArrayCreate(NULL, (const void *[]){runLoop, mode}, 2, &kCFTypeArrayCallBacks);
	if (pair) {
		CFArrayAppendValue(manager->schedules, pair);
		CFRelease(pair);
	}
}

void IOHIDManagerUnscheduleFromRunLoop(IOHIDManagerRef reference, CFRunLoopRef runLoop, CFStringRef mode)
{
	HIDManager *manager = (HIDManager *)reference;
	if (!manager || !manager->schedules || !mode) return;
	for (CFIndex i = CFArrayGetCount(manager->schedules) - 1; i >= 0; i--)
		if (sameSchedule(CFArrayGetValueAtIndex(manager->schedules, i), runLoop, mode))
			CFArrayRemoveValueAtIndex(manager->schedules, i);
}

void IOHIDManagerSetDispatchQueue(IOHIDManagerRef reference, dispatch_queue_t queue)
{
	HIDManager *manager = (HIDManager *)reference;
	if (!manager) return;
	if (manager->queue) dispatch_release(manager->queue);
	manager->queue = queue;
	if (queue) dispatch_retain(queue);
}

void IOHIDManagerSetCancelHandler(IOHIDManagerRef reference, dispatch_block_t handler)
{
	HIDManager *manager = (HIDManager *)reference;
	if (!manager) return;
	if (manager->cancelHandler) Block_release(manager->cancelHandler);
	manager->cancelHandler = handler ? Block_copy(handler) : NULL;
}

void IOHIDManagerActivate(IOHIDManagerRef reference)
{
	HIDManager *manager = (HIDManager *)reference;
	if (manager) {
		manager->active = true;
		manager->canceled = false;
	}
}

void IOHIDManagerCancel(IOHIDManagerRef reference)
{
	HIDManager *manager = (HIDManager *)reference;
	if (!manager || manager->canceled) return;
	manager->active = false;
	manager->canceled = true;
	if (manager->cancelHandler) {
		if (manager->queue)
			dispatch_async(manager->queue, manager->cancelHandler);
		else
			manager->cancelHandler();
	}
}

void IOHIDManagerSetDeviceMatching(IOHIDManagerRef reference, CFDictionaryRef matching)
{
	HIDManager *manager = (HIDManager *)reference;
	if (!manager) return;
	if (manager->deviceMatching) CFRelease(manager->deviceMatching);
	manager->deviceMatching = matching ? CFRetain(matching) : NULL;
}

void IOHIDManagerSetDeviceMatchingMultiple(IOHIDManagerRef reference, CFArrayRef matching)
{
	HIDManager *manager = (HIDManager *)reference;
	if (!manager) return;
	if (manager->deviceMatching) CFRelease(manager->deviceMatching);
	manager->deviceMatching = matching ? CFArrayCreateCopy(NULL, matching) : NULL;
}

CFSetRef IOHIDManagerCopyDevices(IOHIDManagerRef reference)
{
	(void)reference;
	return NULL;
}

void IOHIDManagerRegisterDeviceMatchingCallback(IOHIDManagerRef r, IOHIDDeviceCallback callback, void *context)
{
	HIDManager *m = (HIDManager *)r; if (m) m->matchingCallback = callback, m->matchingContext = context;
}

void IOHIDManagerRegisterDeviceRemovalCallback(IOHIDManagerRef r, IOHIDDeviceCallback callback, void *context)
{
	HIDManager *m = (HIDManager *)r; if (m) m->removalCallback = callback, m->removalContext = context;
}

void IOHIDManagerRegisterInputReportCallback(IOHIDManagerRef r, IOHIDReportCallback callback, void *context)
{
	HIDManager *m = (HIDManager *)r; if (m) m->reportCallback = callback, m->reportContext = context;
}

void IOHIDManagerRegisterInputReportWithTimeStampCallback(IOHIDManagerRef r,
    IOHIDReportWithTimeStampCallback callback, void *context)
{
	HIDManager *m = (HIDManager *)r; if (m) m->timestampReportCallback = callback, m->timestampReportContext = context;
}

void IOHIDManagerRegisterInputValueCallback(IOHIDManagerRef r, IOHIDValueCallback callback, void *context)
{
	HIDManager *m = (HIDManager *)r; if (m) m->valueCallback = callback, m->valueContext = context;
}

void IOHIDManagerSetInputValueMatching(IOHIDManagerRef reference, CFDictionaryRef matching)
{
	HIDManager *manager = (HIDManager *)reference;
	if (!manager) return;
	if (manager->inputMatching) CFRelease(manager->inputMatching);
	manager->inputMatching = matching ? CFRetain(matching) : NULL;
}

void IOHIDManagerSetInputValueMatchingMultiple(IOHIDManagerRef reference, CFArrayRef matching)
{
	HIDManager *manager = (HIDManager *)reference;
	if (!manager) return;
	if (manager->inputMatching) CFRelease(manager->inputMatching);
	manager->inputMatching = matching ? CFArrayCreateCopy(NULL, matching) : NULL;
}
