/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include <IOKit/IOKitLib.h>
#include <IOKit/network/IONetworkLib.h>
#include <IOKit/hid/IOHIDElement.h>
#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/hid/IOHIDValue.h>
#include <stdio.h>

int main(void)
{
    io_connect_t connection = MACH_PORT_NULL;
    UInt8 byte = 0;
    UInt32 size = sizeof(byte);
    UInt32 capacity = 0;
    UInt32 filters = 0;
    IONDHandle handle = 0;

    puts("IOKit network calls");
    printf("open=%d\n", IONetworkOpen(IO_OBJECT_NULL, &connection));
    printf("close=%d\n", IONetworkClose(MACH_PORT_NULL));
    printf("write=%d\n", IONetworkWriteData(MACH_PORT_NULL, 1, &byte, 1));
    IOReturn result = IONetworkReadData(MACH_PORT_NULL, 1, &byte, &size);
    printf("read=%d size=%u\n", result, size);
    printf("reset=%d\n", IONetworkResetData(MACH_PORT_NULL, 1));
    result = IONetworkGetDataCapacity(MACH_PORT_NULL, 1, &capacity);
    printf("capacity=%d value=%u\n", result, capacity);
    result = IONetworkGetDataHandle(MACH_PORT_NULL, "missing", &handle);
    printf("handle=%d value=%u\n", result, handle);
    result = IONetworkGetPacketFiltersMask(MACH_PORT_NULL, "missing", &filters, 0);
    printf("get-filters=%d value=%u\n", result, filters);
    printf("set-filters=%d\n", IONetworkSetPacketFiltersMask(MACH_PORT_NULL, "missing", 1, 0));

    puts("HID data objects");
    int32_t values[] = {17, kIOHIDElementTypeInput_Axis, 1, 0x30, -127, 127, -100, 100, 8, 1, 1, 0, 0};
    CFStringRef keys[] = {CFSTR(kIOHIDElementCookieKey), CFSTR(kIOHIDElementTypeKey), CFSTR(kIOHIDElementUsagePageKey),
        CFSTR(kIOHIDElementUsageKey), CFSTR(kIOHIDElementMinKey), CFSTR(kIOHIDElementMaxKey),
        CFSTR(kIOHIDElementScaledMinKey), CFSTR(kIOHIDElementScaledMaxKey), CFSTR(kIOHIDElementReportSizeKey),
        CFSTR(kIOHIDElementReportCountKey), CFSTR(kIOHIDElementReportIDKey), CFSTR(kIOHIDElementUnitKey),
        CFSTR(kIOHIDElementUnitExponentKey)};
    CFMutableDictionaryRef description = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    for (size_t i = 0; i < sizeof(values) / sizeof(values[0]); i++) {
        CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt32Type, &values[i]);
        CFDictionarySetValue(description, keys[i], number);
        CFRelease(number);
    }
    CFDictionarySetValue(description, CFSTR(kIOHIDElementIsRelativeKey), kCFBooleanTrue);
    CFDictionarySetValue(description, CFSTR(kIOHIDElementIsArrayKey), kCFBooleanFalse);
    CFDictionarySetValue(description, CFSTR(kIOHIDElementIsWrappingKey), kCFBooleanFalse);
    CFDictionarySetValue(description, CFSTR(kIOHIDElementIsNonLinearKey), kCFBooleanFalse);
    CFDictionarySetValue(description, CFSTR(kIOHIDElementHasPreferredStateKey), kCFBooleanTrue);
    CFDictionarySetValue(description, CFSTR(kIOHIDElementHasNullStateKey), kCFBooleanFalse);
    CFDictionarySetValue(description, CFSTR(kIOHIDElementNameKey), CFSTR("Horizontal"));
    IOHIDElementRef element = IOHIDElementCreateWithDictionary(NULL, description);
    printf("element %d", element != NULL);
    if (element) {
        CFStringRef name = IOHIDElementGetName(element);
        char nameBuffer[64] = "-";
        if (name) CFStringGetCString(name, nameBuffer, sizeof(nameBuffer), kCFStringEncodingUTF8);
        printf(" type %u collection %u cookie %u usage %u/%u flags %u/%u report %u/%u/%u unit %u/%u range %ld..%ld physical %ld..%ld name %s",
            (unsigned)IOHIDElementGetType(element), (unsigned)IOHIDElementGetCollectionType(element),
            (unsigned)IOHIDElementGetCookie(element), (unsigned)IOHIDElementGetUsagePage(element),
            (unsigned)IOHIDElementGetUsage(element), (unsigned)IOHIDElementIsRelative(element),
            (unsigned)IOHIDElementIsArray(element), (unsigned)IOHIDElementGetReportSize(element),
            (unsigned)IOHIDElementGetReportCount(element), (unsigned)IOHIDElementGetReportID(element),
            (unsigned)IOHIDElementGetUnit(element), (unsigned)IOHIDElementGetUnitExponent(element),
            (long)IOHIDElementGetLogicalMin(element), (long)IOHIDElementGetLogicalMax(element),
            (long)IOHIDElementGetPhysicalMin(element), (long)IOHIDElementGetPhysicalMax(element), nameBuffer);
        Boolean setStatus = IOHIDElementSetProperty(element, CFSTR("TestProperty"), CFSTR("kept"));
        printf(" property %u %d", (unsigned)setStatus,
            CFEqual(IOHIDElementGetProperty(element, CFSTR("TestProperty")), CFSTR("kept")));
        IOHIDElementRef other = IOHIDElementCreateWithDictionary(NULL, description);
        if (other) {
            IOHIDElementAttach(element, other);
            CFArrayRef attached = IOHIDElementCopyAttached(element);
            printf(" attached %ld", (long)(attached ? CFArrayGetCount(attached) : -1));
            if (attached) CFRelease(attached);
            IOHIDElementDetach(element, other);
            CFRelease(other);
        }
        IOHIDValueRef integerValue = IOHIDValueCreateWithIntegerValue(NULL, element, 123, -17);
        printf(" integer-value %d %ld %llu %ld %.3f %.3f", integerValue != NULL,
            integerValue ? (long)IOHIDValueGetIntegerValue(integerValue) : 0,
            (unsigned long long)(integerValue ? IOHIDValueGetTimeStamp(integerValue) : 0),
            (long)(integerValue ? IOHIDValueGetLength(integerValue) : 0),
            integerValue ? IOHIDValueGetScaledValue(integerValue, kIOHIDValueScaleTypePhysical) : 0,
            integerValue ? IOHIDValueGetScaledValue(integerValue, kIOHIDValueScaleTypeCalibrated) : 0);
        const uint8_t raw[] = {0x12, 0x34};
        IOHIDValueRef bytesValue = IOHIDValueCreateWithBytes(NULL, element, 456, raw, sizeof(raw));
        printf(" bytes-value %d %ld %ld %llu %u %u\n", bytesValue != NULL,
            (long)(bytesValue ? IOHIDValueGetIntegerValue(bytesValue) : 0),
            (long)(bytesValue ? IOHIDValueGetLength(bytesValue) : 0),
            (unsigned long long)(bytesValue ? IOHIDValueGetTimeStamp(bytesValue) : 0),
            bytesValue && IOHIDValueGetLength(bytesValue) > 0 ? IOHIDValueGetBytePtr(bytesValue)[0] : 0,
            bytesValue && IOHIDValueGetLength(bytesValue) > 1 ? IOHIDValueGetBytePtr(bytesValue)[1] : 0);
        if (bytesValue) CFRelease(bytesValue);
        if (integerValue) CFRelease(integerValue);
        CFRelease(element);
    } else {
        puts("");
    }
    CFRelease(description);
    puts("HID manager");
    IOHIDManagerRef manager = IOHIDManagerCreate(NULL, kIOHIDManagerOptionNone);
    printf("create %d type %d", manager != NULL,
        manager && CFGetTypeID(manager) == IOHIDManagerGetTypeID());
    if (manager) {
        int32_t vendor = 0x7ffffffe;
        CFNumberRef vendorNumber = CFNumberCreate(NULL, kCFNumberSInt32Type, &vendor);
        CFMutableDictionaryRef matching = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks);
        CFDictionarySetValue(matching, CFSTR(kIOHIDVendorIDKey), vendorNumber);
        IOHIDManagerSetDeviceMatching(manager, matching);
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        IOReturn openStatus = IOHIDManagerOpen(manager, kIOHIDOptionsTypeNone);
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false);
        CFSetRef devices = IOHIDManagerCopyDevices(manager);
        Boolean setStatus = IOHIDManagerSetProperty(manager, CFSTR("TestManagerProperty"), CFSTR("kept"));
        printf(" property %u %d devices %ld open %d close %d\n", (unsigned)setStatus,
            CFEqual(IOHIDManagerGetProperty(manager, CFSTR("TestManagerProperty")), CFSTR("kept")),
            (long)(devices ? CFSetGetCount(devices) : -1), (int)openStatus,
            (int)IOHIDManagerClose(manager, kIOHIDOptionsTypeNone));
        if (devices) CFRelease(devices);
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        CFRelease(matching);
        CFRelease(vendorNumber);
        CFRelease(manager);
    } else {
        puts("");
    }
    return 0;
}
