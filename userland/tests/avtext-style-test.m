/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Check text markup rules and their saved property-list form. */
#import <AVFoundation/AVTextStyleRule.h>
#import <CoreMedia/CMTextMarkup.h>
#import <Foundation/Foundation.h>

int
main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        NSDictionary *attributes = @{
            (__bridge NSString *)kCMTextMarkupAttribute_BoldStyle: @YES,
            (__bridge NSString *)kCMTextMarkupAttribute_ForegroundColorARGB: @[@1.0, @0.2, @0.4, @0.8]
        };
        AVTextStyleRule *rule = [[AVTextStyleRule alloc] initWithTextMarkupAttributes:attributes textSelector:@".title"];
        NSArray *propertyList = [AVTextStyleRule propertyListForTextStyleRules:@[rule]];
        NSArray<AVTextStyleRule *> *decoded = [AVTextStyleRule textStyleRulesFromPropertyList:propertyList];
        AVTextStyleRule *plain = [AVTextStyleRule textStyleRuleWithTextMarkupAttributes:@{
            (__bridge NSString *)kCMTextMarkupAttribute_ItalicStyle: @YES
        }];
        puts("AVTextStyleRule property-list checks");
        printf("rule %lu %s %d plist %s\n", (unsigned long)rule.textMarkupAttributes.count,
            rule.textSelector.UTF8String, rule != nil, [[propertyList description] UTF8String]);
        printf("decoded %lu %lu %s plain %lu\n", (unsigned long)decoded.count,
            (unsigned long)decoded.firstObject.textMarkupAttributes.count,
            decoded.firstObject.textSelector.UTF8String,
            (unsigned long)plain.textMarkupAttributes.count);
    }
    return 0;
}
