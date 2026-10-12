/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * IOBluetoothUI: the Bluetooth panels (device selector, object push, transfer progress)
 * and the hardware check. Finch has no Bluetooth driver yet, so, as on a Mac without
 * Bluetooth, the hardware check tells the user Bluetooth isn't available, the selector
 * finds nothing to choose, and pushes can't start. The panels' objects keep what apps
 * set on them.
 */
#import <AppKit/AppKit.h>
#import <IOBluetooth/IOBluetooth.h>
#import <IOBluetoothUI/IOBluetoothUI.h>
#import <objc/message.h>
#import "IOBluetoothTransferProgress.h"

static BOOL
have_controller(void)
{
    IOBluetoothHostController *c = [IOBluetoothHostController defaultController];
    return c && [c powerState] == kBluetoothHCIPowerStateON;
}

/* Success when there's a Bluetooth controller; otherwise an alert says there isn't (with
   the app's description and cancel button title), and the check fails. */
IOReturn
IOBluetoothValidateHardwareWithDescription(CFStringRef cancelButtonTitle, CFStringRef descriptionText)
{
    if (have_controller())
        return kIOReturnSuccess;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Bluetooth isn't available on this computer.";
    alert.informativeText = (__bridge NSString *)descriptionText ?: @"";
    [alert addButtonWithTitle:(__bridge NSString *)cancelButtonTitle ?: @"Quit"];
    [alert runModal];
    return kIOReturnNotAttached;
}

/* (a book and anchor, both optional: the app's help otherwise) */
void
IOBluetoothOpenBluetoothHelpAtPath(CFStringRef book, CFStringRef anchor)
{
    NSHelpManager *help = [NSHelpManager sharedHelpManager];
    if (anchor)
        [help openHelpAnchor:(__bridge NSString *)anchor inBook:(__bridge NSString *)book];
    else
        [NSApp showHelp:nil];
}

#pragma mark - Device selector

@implementation IOBluetoothDeviceSelectorController {
    IOBluetoothServiceBrowserControllerOptions _options;
    IOBluetoothDeviceSearchAttributes _attributes;
    BOOL _hasAttributes;
    NSMutableArray *_allowedUUIDs;
    NSString *_title;
}

+ (IOBluetoothDeviceSelectorController *)deviceSelector
{
    return [[self alloc] initWithWindow:nil];
}

- (instancetype)initWithWindow:(NSWindow *)window
{
    if ((self = [super initWithWindow:window]))
        _allowedUUIDs = [NSMutableArray array];
    return self;
}

/* (no devices can be found: the selection ends as if cancelled) */
- (int)runModal { return kIOBluetoothUIUserCanceledErr; }

- (IOReturn)beginSheetModalForWindow:(NSWindow *)sheetWindow modalDelegate:(id)modalDelegate
                      didEndSelector:(SEL)didEndSelector contextInfo:(void *)contextInfo
{
    if (modalDelegate && didEndSelector)
        dispatch_async(dispatch_get_main_queue(), ^{
            ((void (*)(id, SEL, id, IOReturn, void *))objc_msgSend)(modalDelegate, didEndSelector, self,
                                                                     kIOBluetoothUIUserCanceledErr, contextInfo);
        });
    return kIOReturnSuccess;
}

- (NSArray *)getResults { return nil; }
- (void)setOptions:(IOBluetoothServiceBrowserControllerOptions)options { _options = options; }
- (IOBluetoothServiceBrowserControllerOptions)getOptions { return _options; }

- (void)setSearchAttributes:(const IOBluetoothDeviceSearchAttributes *)searchAttributes
{
    _hasAttributes = searchAttributes != NULL;
    if (searchAttributes)
        _attributes = *searchAttributes;
}

- (const IOBluetoothDeviceSearchAttributes *)getSearchAttributes { return _hasAttributes ? &_attributes : NULL; }
- (void)addAllowedUUID:(IOBluetoothSDPUUID *)allowedUUID { if (allowedUUID) [_allowedUUIDs addObject:allowedUUID]; }
- (void)addAllowedUUIDArray:(NSArray *)allowedUUIDArray { if (allowedUUIDArray) [_allowedUUIDs addObjectsFromArray:allowedUUIDArray]; }
- (void)clearAllowedUUIDs { [_allowedUUIDs removeAllObjects]; }
- (void)setTitle:(NSString *)windowTitle { _title = [windowTitle copy]; }
- (NSString *)getTitle { return _title; }
- (void)setHeader:(NSString *)headerText {}
- (NSString *)getHeader { return nil; }
- (void)setDescriptionText:(NSString *)descriptionText {}
- (NSString *)getDescriptionText { return nil; }
- (void)setPrompt:(NSString *)prompt {}
- (NSString *)getPrompt { return nil; }
- (void)setCancel:(NSString *)prompt {}
- (NSString *)getCancel { return nil; }

@end

#pragma mark - Object push

@implementation IOBluetoothObjectPushUIController {
    IOBluetoothDevice *_device;
    NSArray *_files;
    __weak id _delegate;
    NSString *_title;
    NSImage *_icon;
}

- (IOBluetoothObjectPushUIController *)initObjectPushWithBluetoothDevice:(IOBluetoothDevice *)inDevice
                                                               withFiles:(NSArray *)inFiles
                                                                delegate:(id)inDelegate
{
    if ((self = [super initWithWindow:nil])) {
        _device = inDevice;
        _files = [inFiles copy];
        _delegate = inDelegate;
    }
    return self;
}

/* (nothing can be sent without a controller: the push ends at once, telling the delegate) */
- (void)finish
{
    id d = _delegate;
    if ([d respondsToSelector:@selector(objectPushComplete:)])
        [d performSelector:@selector(objectPushComplete:) withObject:self];
}

- (void)runModal { [self finish]; }
- (void)runPanel { [self finish]; }

- (IOReturn)beginSheetModalForWindow:(NSWindow *)sheetWindow modalDelegate:(id)modalDelegate
                      didEndSelector:(SEL)didEndSelector contextInfo:(void *)contextInfo
{
    if (modalDelegate && didEndSelector)
        dispatch_async(dispatch_get_main_queue(), ^{
            ((void (*)(id, SEL, id, IOReturn, void *))objc_msgSend)(modalDelegate, didEndSelector, self,
                                                                     kIOReturnNotAttached, contextInfo);
        });
    return kIOReturnNotAttached;
}

- (void)stop {}
- (void)setTitle:(NSString *)windowTitle { _title = [windowTitle copy]; }
- (NSString *)getTitle { return _title; }
- (void)setIconImage:(NSImage *)image { _icon = image; }
- (IOBluetoothDevice *)getDevice { return _device; }
- (BOOL)isTransferInProgress { return NO; }

@end

#pragma mark - Transfer progress

/* A transfer's progress shown in the panel's fields: status, file name, bytes and time
   remaining, and its progress indicator. */
@interface IOBluetoothTransferProgressUI : IOBluetoothTransferProgress
@end

@implementation IOBluetoothTransferProgressUI {
    NSProgressIndicator *mProgressIndicator;
    NSTextField *_statusField, *_fileNameField, *_bytesField, *_timeField, *_timeLabel;
    NSString *_deviceName, *_fileName, *_statusKey, *_bytesKey, *_timeKey;
    int _transferType;
}

- (instancetype)initWithTotalBytes:(unsigned int)totalBytes progressIndicator:(NSProgressIndicator *)indicator
{
    if ((self = [super initWithTotalBytes:totalBytes]))
        mProgressIndicator = indicator;
    return self;
}

- (void)setProgressIndicator:(NSProgressIndicator *)indicator { mProgressIndicator = indicator; [self updateUI]; }
- (void)setStatusField:(NSTextField *)f { _statusField = f; }
- (void)setFileNameField:(NSTextField *)f { _fileNameField = f; }
- (void)setTransferedBytesField:(NSTextField *)f { _bytesField = f; }
- (void)setTimeRemainingField:(NSTextField *)f { _timeField = f; }
- (void)setTimeRemainingFieldLabel:(NSTextField *)f { _timeLabel = f; }
- (void)setDeviceName:(NSString *)name { _deviceName = [name copy]; }
- (void)setTransferFileName:(NSString *)name { _fileName = [name copy]; _fileNameField.stringValue = name ?: @""; }
- (void)setFileNameString:(NSString *)s { _fileNameField.stringValue = s ?: @""; }
- (void)setStatusString:(NSString *)s { _statusField.stringValue = s ?: @""; }
- (void)setStatusStringKey:(NSString *)k { _statusKey = [k copy]; [self setStatusString:[self locString:k]]; }
- (void)setBytesString:(NSString *)s { _bytesField.stringValue = s ?: @""; }
- (void)setBytesStringKey:(NSString *)k { _bytesKey = [k copy]; }
- (void)setTimeString:(NSString *)s { _timeField.stringValue = s ?: @""; }
- (void)setTimeStringKey:(NSString *)k { _timeKey = [k copy]; }
- (void)setTransferType:(int)type { _transferType = type; }
- (void)setIndeterminateState:(BOOL)indeterminate { mProgressIndicator.indeterminate = indeterminate; }
- (NSString *)locString:(NSString *)key { return [[NSBundle bundleForClass:[self class]] localizedStringForKey:key value:key table:nil]; }

- (NSString *)getByteSizeString:(unsigned int)bytes
{
    return [NSByteCountFormatter stringFromByteCount:bytes countStyle:NSByteCountFormatterCountStyleFile];
}

- (NSString *)getBytesTransferredAsString
{
    return [NSString stringWithFormat:@"%@ of %@", [self getByteSizeString:(unsigned int)[self getBytesTransferred]],
                                      [self getByteSizeString:(unsigned int)[self getBytesTotal]]];
}

- (void)setTransferState:(int)state
{
    [super setTransferState:state];
    [self updateUI];
}

- (void)updateUI
{
    mProgressIndicator.maxValue = 100;
    mProgressIndicator.doubleValue = [self getTransferPercentage];
    _bytesField.stringValue = [self getBytesTransferredAsString];
    double remaining = [self getEstimatedTimeRemaining];
    if (_timeField) {
        NSDateComponentsFormatter *f = [[NSDateComponentsFormatter alloc] init];
        f.unitsStyle = NSDateComponentsFormatterUnitsStyleFull;
        f.maximumUnitCount = 1;
        _timeField.stringValue = remaining > 0 ? [f stringFromTimeInterval:remaining] ?: @"" : @"";
    }
}

- (NSRect)getSavedWindowFrameForTextField:(NSTextField *)field { return field.window.frame; }
- (void)resizeWindowWithTextField:(NSTextField *)field {}
- (void)saveWindowFrameWithTextField:(NSTextField *)field {}

@end
