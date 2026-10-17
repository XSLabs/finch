// SPDX-License-Identifier: MIT OR Apache-2.0
#import <CoreBluetooth/CoreBluetooth.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>

static void printImage(void)
{
    Dl_info info = {0};
    if (dladdr((__bridge const void *)[CBUUID class], &info) && info.dli_fname)
        puts(info.dli_fname);
    else puts("(CoreBluetooth image unavailable)");
}

static void printData(NSData *data)
{
    const unsigned char *bytes = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) printf("%02X", bytes[i]);
}

int main(void)
{
    @autoreleasepool {
        printImage();
        CBUUID *shortUUID = [CBUUID UUIDWithString:@"180d"];
        CBUUID *baseUUID = [CBUUID UUIDWithString:@"0000180D-0000-1000-8000-00805F9B34FB"];
        CBUUID *wideUUID = [CBUUID UUIDWithString:@"12345678"];
        CBUUID *customUUID = [CBUUID UUIDWithString:@"00112233-4455-6677-8899-AABBCCDDEEFF"];
        printf("UUIDs: short=%s data=", shortUUID.UUIDString.UTF8String);
        printData(shortUUID.data);
        printf(" equalBase=%d wide=%s custom=%s\n", [shortUUID isEqual:baseUUID],
            wideUUID.UUIDString.UTF8String, customUUID.UUIDString.UTF8String);

        CBUUID *serviceUUID = [CBUUID UUIDWithString:@"180d"];
        CBMutableService *service = [[CBMutableService alloc] initWithType:serviceUUID primary:YES];
        NSData *value = [NSData dataWithBytes:"\x01\x02" length:2];
        CBMutableCharacteristic *characteristic = [[CBMutableCharacteristic alloc]
            initWithType:[CBUUID UUIDWithString:@"2a37"] properties:CBCharacteristicPropertyRead
            | CBCharacteristicPropertyNotify value:value permissions:CBAttributePermissionsReadable];
        CBMutableDescriptor *descriptor = [[CBMutableDescriptor alloc]
            initWithType:[CBUUID UUIDWithString:@"2901"] value:@"Heart rate"];
        characteristic.descriptors = @[descriptor];
        service.characteristics = @[characteristic];
        printf("values: service=%s primary=%d characteristics=%lu characteristic=%s props=%lu value=%lu descriptor=%s\n",
            service.UUID.UUIDString.UTF8String, service.isPrimary, (unsigned long)service.characteristics.count,
            characteristic.UUID.UUIDString.UTF8String, (unsigned long)characteristic.properties,
            (unsigned long)characteristic.value.length, [descriptor.value UTF8String]);
        printf("keys: att=%s adv=%s,%s,%s,%s,%s,%s,%s,%s central=%s,%s peripheral=%s,%s\n",
            CBATTErrorDomain.UTF8String, CBAdvertisementDataIsConnectable.UTF8String,
            CBAdvertisementDataLocalNameKey.UTF8String, CBAdvertisementDataManufacturerDataKey.UTF8String,
            CBAdvertisementDataOverflowServiceUUIDsKey.UTF8String, CBAdvertisementDataServiceDataKey.UTF8String,
            CBAdvertisementDataServiceUUIDsKey.UTF8String, CBAdvertisementDataSolicitedServiceUUIDsKey.UTF8String,
            CBAdvertisementDataTxPowerLevelKey.UTF8String, CBCentralManagerOptionRestoreIdentifierKey.UTF8String,
            CBCentralManagerOptionShowPowerAlertKey.UTF8String, CBPeripheralManagerOptionRestoreIdentifierKey.UTF8String,
            CBPeripheralManagerOptionShowPowerAlertKey.UTF8String);
        printf("option keys: %s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n",
            CBCentralManagerRestoredStatePeripheralsKey.UTF8String, CBCentralManagerRestoredStateScanOptionsKey.UTF8String,
            CBCentralManagerRestoredStateScanServicesKey.UTF8String, CBCentralManagerScanOptionAllowDuplicatesKey.UTF8String,
            CBCentralManagerScanOptionSolicitedServiceUUIDsKey.UTF8String, CBConnectPeripheralOptionEnableAutoReconnect.UTF8String,
            CBConnectPeripheralOptionNotifyOnConnectionKey.UTF8String, CBConnectPeripheralOptionNotifyOnDisconnectionKey.UTF8String,
            CBConnectPeripheralOptionNotifyOnNotificationKey.UTF8String, CBConnectPeripheralOptionStartDelayKey.UTF8String,
            CBPeripheralManagerRestoredStateAdvertisementDataKey.UTF8String, CBPeripheralManagerRestoredStateServicesKey.UTF8String);
        printf("authorization: manager=%ld legacy=%ld\n", (long)CBManager.authorization,
            (long)[CBPeripheralManager authorizationStatus]);
    }
    return 0;
}
