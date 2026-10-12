/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* What QuartzFilters' files share. */
#import <AppKit/AppKit.h>
#import <QuartzFilters/QuartzFilters.h>

@interface QuartzFilter (FinchInternal)
- (instancetype)_initWithProperties:(NSDictionary *)properties;
- (void)setURL:(NSURL *)url;
@end

/* Apple's filter property keys (exported, not in its headers) */
extern NSString *const kQFilterName, *const kQFilterType, *const kQFilterDomains, *const kQFilterURL, *const kQFilterData;
