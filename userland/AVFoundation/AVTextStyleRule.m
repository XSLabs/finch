/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Text style rules are immutable markup values that can be saved as property lists. */
#import <AVFoundation/AVTextStyleRule.h>
#import <CoreMedia/CMTextMarkup.h>

@implementation AVTextStyleRule {
    NSDictionary *_finchAttributes;
    NSString *_finchSelector;
}

+ (instancetype)textStyleRuleWithTextMarkupAttributes:(NSDictionary<NSString *,id> *)attributes
{
    return [self textStyleRuleWithTextMarkupAttributes:attributes textSelector:nil];
}

+ (instancetype)textStyleRuleWithTextMarkupAttributes:(NSDictionary<NSString *,id> *)attributes
                                             textSelector:(NSString *)selector
{
    return [[self alloc] initWithTextMarkupAttributes:attributes textSelector:selector];
}

- (instancetype)initWithTextMarkupAttributes:(NSDictionary<NSString *,id> *)attributes
{
    return [self initWithTextMarkupAttributes:attributes textSelector:nil];
}

- (instancetype)initWithTextMarkupAttributes:(NSDictionary<NSString *,id> *)attributes
                                  textSelector:(NSString *)selector
{
    if (!attributes || ![NSPropertyListSerialization propertyList:attributes
        isValidForFormat:NSPropertyListXMLFormat_v1_0]) {
        return nil;
    }
    if ((self = [super init])) {
        _finchAttributes = [attributes copy];
        _finchSelector = [selector copy];
    }
    return self;
}

- (NSDictionary<NSString *,id> *)textMarkupAttributes { return _finchAttributes; }
- (NSString *)textSelector { return _finchSelector; }
- (id)copyWithZone:(NSZone *)zone { return self; }

+ (id)propertyListForTextStyleRules:(NSArray<AVTextStyleRule *> *)rules
{
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:rules.count];
    for (AVTextStyleRule *rule in rules) {
        NSMutableDictionary *entry = [rule.textMarkupAttributes mutableCopy];
        if (rule.textSelector)
            entry[@"CMTextSelector"] = rule.textSelector;
        [result addObject:entry];
    }
    return result;
}

+ (NSArray<AVTextStyleRule *> *)textStyleRulesFromPropertyList:(id)propertyList
{
    if (![propertyList isKindOfClass:[NSArray class]])
        return nil;
    NSMutableArray *rules = [NSMutableArray arrayWithCapacity:[propertyList count]];
    for (id value in propertyList) {
        if (![value isKindOfClass:[NSDictionary class]])
            return nil;
        NSDictionary *entry = value;
        NSMutableDictionary *attributes = [entry mutableCopy];
        id selector = attributes[@"CMTextSelector"];
        [attributes removeObjectForKey:@"CMTextSelector"];
        if (selector != nil && ![selector isKindOfClass:[NSString class]])
            return nil;
        AVTextStyleRule *rule = [[self alloc] initWithTextMarkupAttributes:attributes
            textSelector:selector];
        if (!rule)
            return nil;
        [rules addObject:rule];
    }
    return rules;
}

@end
