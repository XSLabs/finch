// SPDX-License-Identifier: MIT OR Apache-2.0
#import <CoreBluetooth/CoreBluetooth.h>
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#include <stdio.h>

@interface CBStateDelegate : NSObject
{
    dispatch_semaphore_t _semaphore;
    CBManagerState _state;
}
- (instancetype)initWithSemaphore:(dispatch_semaphore_t)semaphore;
- (CBManagerState)state;
- (void)centralManagerDidUpdateState:(CBCentralManager *)manager;
- (void)peripheralManagerDidUpdateState:(CBPeripheralManager *)manager;
@end

@implementation CBStateDelegate
- (instancetype)initWithSemaphore:(dispatch_semaphore_t)semaphore
{
    self = [super init];
    if (self) _semaphore = semaphore;
    return self;
}
- (CBManagerState)state { return _state; }
- (void)centralManagerDidUpdateState:(CBCentralManager *)manager
{
    _state = manager.state;
    dispatch_semaphore_signal(_semaphore);
}
- (void)peripheralManagerDidUpdateState:(CBPeripheralManager *)manager
{
    _state = manager.state;
    dispatch_semaphore_signal(_semaphore);
}
@end

int main(void)
{
    @autoreleasepool {
        dispatch_queue_t queue = dispatch_queue_create("org.finch.tests.bluetooth", DISPATCH_QUEUE_SERIAL);
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        CBStateDelegate *centralDelegate = [[CBStateDelegate alloc] initWithSemaphore:semaphore];
        CBCentralManager *central = [[CBCentralManager alloc] initWithDelegate:(id)centralDelegate queue:queue];
        long centralCallback = dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
        CBStateDelegate *peripheralDelegate = [[CBStateDelegate alloc] initWithSemaphore:semaphore];
        CBPeripheralManager *peripheral = [[CBPeripheralManager alloc] initWithDelegate:(id)peripheralDelegate queue:queue];
        long peripheralCallback = dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
        printf("central state=%ld callback=%d; peripheral state=%ld callback=%d\n",
            (long)central.state, centralCallback == 0, (long)peripheral.state, peripheralCallback == 0);
    }
    return 0;
}
