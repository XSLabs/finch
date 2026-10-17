// SPDX-License-Identifier: MIT OR Apache-2.0
#import <CryptoTokenKit/CryptoTokenKit.h>
#import <Foundation/Foundation.h>
#include <stdio.h>

int main(void)
{
    @autoreleasepool {
        TKTokenWatcher *watcher = [[TKTokenWatcher alloc] initWithInsertionHandler:^(NSString *tokenID) {
            (void)tokenID;
        }];
        __block NSUInteger removalCalls = 0;
        [watcher addRemovalHandler:^(NSString *tokenID) { (void)tokenID; removalCalls++; }
            forTokenID:@"finch-test-token-that-is-not-present"];
        TKSmartCardSlotManager *manager = [TKSmartCardSlotManager defaultManager];
        printf("tokens=%lu unknownToken=%d removalCalls=%lu slotManager=%d slots=%lu unknownSlot=%d\n",
            (unsigned long)watcher.tokenIDs.count,
            [watcher tokenInfoForTokenID:@"finch-test-token-that-is-not-present"] == nil,
            (unsigned long)removalCalls, manager != nil, (unsigned long)manager.slotNames.count,
            [manager slotNamed:@"finch-test-slot"] == nil);
    }
    return 0;
}
