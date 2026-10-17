// SPDX-License-Identifier: MIT OR Apache-2.0
#import "GCGameControllerPrivate.h"
#import <GameController/GCGamepadSnapshot.h>
#import <GameController/GCExtendedGamepadSnapshot.h>
#import <GameController/GCMicroGamepadSnapshot.h>
#include <stddef.h>
#include <string.h>

static NSData *GCSnapshotData(const void *bytes, size_t byteCount,
                              uint16_t *version, uint16_t *size,
                              uint16_t currentVersion, size_t currentSize,
                              size_t minimumSize)
{
    if (!bytes || !version || !size)
        return nil;
    if (*version == 0 && *size == 0) {
        *version = currentVersion;
        *size = (uint16_t)currentSize;
    }
    if (*size < minimumSize || *size > byteCount ||
        (*version != 0x0100 && *version != currentVersion))
        return nil;
    return [NSData dataWithBytes:bytes length:*size];
}

NSData *NSDataFromGCExtendedGamepadSnapshotData(GCExtendedGamepadSnapshotData *data)
{
    if (!data)
        return nil;
    if (data->version == 0 && data->size == 0) {
        data->version = GCCurrentExtendedGamepadSnapshotDataVersion;
        data->size = sizeof(*data);
    }
    size_t minimumSize = data->version == 0x0100 ?
        offsetof(GCExtendedGamepadSnapshotData, supportsClickableThumbsticks) : sizeof(*data);
    if ((data->version != 0x0100 && data->version != GCCurrentExtendedGamepadSnapshotDataVersion) ||
        data->size < minimumSize || data->size > sizeof(*data))
        return nil;
    return GCSnapshotData(data, sizeof(*data), &data->version, &data->size,
                          GCCurrentExtendedGamepadSnapshotDataVersion, sizeof(*data),
                          minimumSize);
}

BOOL GCExtendedGamepadSnapshotDataFromNSData(GCExtendedGamepadSnapshotData *snapshot, NSData *data)
{
    if (!snapshot || !data || [data length] < offsetof(GCExtendedGamepadSnapshotData, supportsClickableThumbsticks))
        return NO;
    memset(snapshot, 0, sizeof(*snapshot));
    size_t length = MIN([data length], sizeof(*snapshot));
    [data getBytes:snapshot length:length];
    size_t minimumSize = snapshot->version == 0x0100 ?
        offsetof(GCExtendedGamepadSnapshotData, supportsClickableThumbsticks) : sizeof(*snapshot);
    if (snapshot->size > [data length] || snapshot->size < minimumSize)
        return NO;
    if (snapshot->version != 0x0100 && snapshot->version != GCCurrentExtendedGamepadSnapshotDataVersion)
        return NO;
    return YES;
}

NSData *NSDataFromGCMicroGamepadSnapshotData(GCMicroGamepadSnapshotData *data)
{
    if (!data)
        return nil;
    return GCSnapshotData(data, sizeof(*data), &data->version, &data->size,
                          GCCurrentMicroGamepadSnapshotDataVersion, sizeof(*data), sizeof(*data));
}

BOOL GCMicroGamepadSnapshotDataFromNSData(GCMicroGamepadSnapshotData *snapshot, NSData *data)
{
    if (!snapshot || !data || [data length] < sizeof(*snapshot))
        return NO;
    memset(snapshot, 0, sizeof(*snapshot));
    [data getBytes:snapshot length:sizeof(*snapshot)];
    if (snapshot->size < sizeof(*snapshot) || snapshot->size > [data length] ||
        (snapshot->version != 0x0100 && snapshot->version != GCCurrentMicroGamepadSnapshotDataVersion))
        return NO;
    return YES;
}

NSData *NSDataFromGCExtendedGamepadSnapShotDataV100(GCExtendedGamepadSnapShotDataV100 *data)
{
    if (!data)
        return nil;
    if (data->version == 0 && data->size == 0) {
        data->version = 0x0100;
        data->size = sizeof(*data);
    }
    if (data->version != 0x0100 || data->size < sizeof(*data) || data->size > sizeof(*data))
        return nil;
    return [NSData dataWithBytes:data length:data->size];
}

BOOL GCExtendedGamepadSnapShotDataV100FromNSData(GCExtendedGamepadSnapShotDataV100 *snapshot, NSData *data)
{
    if (!snapshot || !data || [data length] < sizeof(*snapshot))
        return NO;
    [data getBytes:snapshot length:sizeof(*snapshot)];
    return snapshot->version == 0x0100 && snapshot->size >= sizeof(*snapshot) && snapshot->size <= [data length];
}

NSData *NSDataFromGCMicroGamepadSnapShotDataV100(GCMicroGamepadSnapShotDataV100 *data)
{
    if (!data)
        return nil;
    if (data->version == 0 && data->size == 0) {
        data->version = 0x0100;
        data->size = sizeof(*data);
    }
    if (data->version != 0x0100 || data->size != sizeof(*data))
        return nil;
    return [NSData dataWithBytes:data length:data->size];
}

BOOL GCMicroGamepadSnapShotDataV100FromNSData(GCMicroGamepadSnapShotDataV100 *snapshot, NSData *data)
{
    if (!snapshot || !data || [data length] < sizeof(*snapshot))
        return NO;
    [data getBytes:snapshot length:sizeof(*snapshot)];
    return snapshot->version == 0x0100 && snapshot->size >= sizeof(*snapshot) && snapshot->size <= [data length];
}

NSData *NSDataFromGCGamepadSnapShotDataV100(GCGamepadSnapShotDataV100 *data)
{
    if (!data)
        return nil;
    if (data->version == 0 && data->size == 0) {
        data->version = 0x0100;
        data->size = sizeof(*data);
    }
    if (data->version != 0x0100 || data->size != sizeof(*data))
        return nil;
    return [NSData dataWithBytes:data length:data->size];
}

BOOL GCGamepadSnapShotDataV100FromNSData(GCGamepadSnapShotDataV100 *snapshot, NSData *data)
{
    if (!snapshot || !data || [data length] < sizeof(*snapshot))
        return NO;
    [data getBytes:snapshot length:sizeof(*snapshot)];
    return snapshot->version == 0x0100 && snapshot->size >= sizeof(*snapshot) && snapshot->size <= [data length];
}

static GCController *GCCreateSnapshotController(NSUInteger kind)
{
    return [[[GCController alloc] _initSnapshotWithProfileKind:kind] autorelease];
}

@implementation GCExtendedGamepadSnapshot {
    NSData *_snapshotData;
}

- (instancetype)initWithSnapshotData:(NSData *)data
{
    return [self initWithController:GCCreateSnapshotController(3) snapshotData:data];
}

- (instancetype)initWithController:(GCController *)controller snapshotData:(NSData *)data
{
    GCExtendedGamepadSnapshotData state;
    if (!GCExtendedGamepadSnapshotDataFromNSData(&state, data))
        return nil;
    self = [super _initWithController:controller];
    if (self)
        self.snapshotData = data;
    return self;
}

- (NSData *)snapshotData { @synchronized(self) { return _snapshotData; } }
- (void)setSnapshotData:(NSData *)data
{
    GCExtendedGamepadSnapshotData state;
    if (!GCExtendedGamepadSnapshotDataFromNSData(&state, data))
        return;
    @synchronized(self) {
        [_snapshotData release];
        _snapshotData = [data copy];
    }
    [self.dpad setValueForXAxis:state.dpadX yAxis:state.dpadY];
    [self.buttonA setValue:state.buttonA]; [self.buttonB setValue:state.buttonB];
    [self.buttonX setValue:state.buttonX]; [self.buttonY setValue:state.buttonY];
    [self.leftShoulder setValue:state.leftShoulder]; [self.rightShoulder setValue:state.rightShoulder];
    [self.leftThumbstick setValueForXAxis:state.leftThumbstickX yAxis:state.leftThumbstickY];
    [self.rightThumbstick setValueForXAxis:state.rightThumbstickX yAxis:state.rightThumbstickY];
    [self.leftTrigger setValue:state.leftTrigger]; [self.rightTrigger setValue:state.rightTrigger];
    if (state.size >= sizeof(state)) {
        [self.leftThumbstickButton setValue:state.leftThumbstickButton ? 1.0f : 0.0f];
        [self.rightThumbstickButton setValue:state.rightThumbstickButton ? 1.0f : 0.0f];
    }
}

- (void)dealloc { [_snapshotData release]; [super dealloc]; }
@end

@implementation GCMicroGamepadSnapshot {
    NSData *_snapshotData;
}
- (instancetype)initWithSnapshotData:(NSData *)data
{
    return [self initWithController:GCCreateSnapshotController(2) snapshotData:data];
}
- (instancetype)initWithController:(GCController *)controller snapshotData:(NSData *)data
{
    GCMicroGamepadSnapshotData state;
    if (!GCMicroGamepadSnapshotDataFromNSData(&state, data))
        return nil;
    self = [super _initWithController:controller];
    if (self)
        self.snapshotData = data;
    return self;
}
- (NSData *)snapshotData { @synchronized(self) { return _snapshotData; } }
- (void)setSnapshotData:(NSData *)data
{
    GCMicroGamepadSnapshotData state;
    if (!GCMicroGamepadSnapshotDataFromNSData(&state, data))
        return;
    @synchronized(self) { [_snapshotData release]; _snapshotData = [data copy]; }
    [self.dpad setValueForXAxis:state.dpadX yAxis:state.dpadY];
    [self.buttonA setValue:state.buttonA]; [self.buttonX setValue:state.buttonX];
}
- (void)dealloc { [_snapshotData release]; [super dealloc]; }
@end

@implementation GCGamepadSnapshot {
    NSData *_snapshotData;
}
- (instancetype)initWithSnapshotData:(NSData *)data
{
    return [self initWithController:GCCreateSnapshotController(1) snapshotData:data];
}
- (instancetype)initWithController:(GCController *)controller snapshotData:(NSData *)data
{
    GCGamepadSnapShotDataV100 state;
    if (!GCGamepadSnapShotDataV100FromNSData(&state, data))
        return nil;
    self = [super _initWithController:controller];
    if (self)
        self.snapshotData = data;
    return self;
}
- (NSData *)snapshotData { @synchronized(self) { return _snapshotData; } }
- (void)setSnapshotData:(NSData *)data
{
    GCGamepadSnapShotDataV100 state;
    if (!GCGamepadSnapShotDataV100FromNSData(&state, data))
        return;
    @synchronized(self) { [_snapshotData release]; _snapshotData = [data copy]; }
    [self.dpad setValueForXAxis:state.dpadX yAxis:state.dpadY];
    [self.buttonA setValue:state.buttonA]; [self.buttonB setValue:state.buttonB];
    [self.buttonX setValue:state.buttonX]; [self.buttonY setValue:state.buttonY];
    [self.leftShoulder setValue:state.leftShoulder]; [self.rightShoulder setValue:state.rightShoulder];
}
- (void)dealloc { [_snapshotData release]; [super dealloc]; }
@end
