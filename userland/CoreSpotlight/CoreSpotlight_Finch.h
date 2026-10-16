/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#import <CoreSpotlight/CoreSpotlight.h>

NSArray<CSSearchableItem *> *FinchCSSearchAllItems(void);
NSArray<CSSearchableItem *> *FinchCSSearchItemsNamed(NSString *name);
CSSearchableItem *FinchCSSearchableItemWithFetchedAttributes(CSSearchableItem *item, NSArray<NSString *> *attributes);
NSString *FinchCSSearchIndexPath(NSString *name);
