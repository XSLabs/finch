// SPDX-License-Identifier: MIT OR Apache-2.0
#import <CoreBluetooth/CoreBluetooth.h>
#import <objc/runtime.h>

extern void CBSet(id object, const void *key, id value);
extern id CBGet(id object, const void *key);
extern void CBSetWeak(id object, const void *key, id value);
extern id CBGetWeak(id object, const void *key);
extern NSError *CBUnsupportedError(void);

@interface CBUUID (FinchInternal)
- (instancetype)_initWithData:(NSData *)data;
@end

@interface CBAttribute (FinchInternal)
- (instancetype)_initWithUUID:(CBUUID *)UUID;
@end
