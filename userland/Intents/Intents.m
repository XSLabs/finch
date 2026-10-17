/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Intents value objects and the local interaction store. Objects that need Siri
 * or another Apple service return the same unavailable error family that the
 * Intents API uses when that service cannot be reached.
 */
#import <Foundation/Foundation.h>
#import <Intents/Intents.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

NSString * const INIntentErrorDomain = @"INIntentErrorDomain";
NSString * const INAnswerCallIntentIdentifier = @"INAnswerCallIntentIdentifier";
NSString * const INHangUpCallIntentIdentifier = @"INHangUpCallIntentIdentifier";
NSString * const INPersonHandleLabelHome = @"com.apple.intents.PersonHandleLabel.Home";
NSString * const INPersonHandleLabelWork = @"com.apple.intents.PersonHandleLabel.Work";
NSString * const INPersonHandleLabeliPhone = @"com.apple.intents.PersonHandleLabel.iPhone";
NSString * const INPersonHandleLabelMobile = @"com.apple.intents.PersonHandleLabel.Mobile";
NSString * const INPersonHandleLabelMain = @"com.apple.intents.PersonHandleLabel.Main";
NSString * const INPersonHandleLabelHomeFax = @"com.apple.intents.PersonHandleLabel.HomeFax";
NSString * const INPersonHandleLabelWorkFax = @"com.apple.intents.PersonHandleLabel.WorkFax";
NSString * const INPersonHandleLabelPager = @"com.apple.intents.PersonHandleLabel.Pager";
NSString * const INPersonHandleLabelOther = @"com.apple.intents.PersonHandleLabel.Other";
NSString * const INPersonHandleLabelSchool = @"com.apple.intents.PersonHandleLabel.School";
NSString * const INPersonRelationshipSon = @"com.apple.intents.PersonRelationship.Son";
NSString * const INPersonRelationshipDaughter = @"com.apple.intents.PersonRelationship.Daughter";
double IntentsVersionNumber = 1.0;
const unsigned char IntentsVersionString[] = "1.0";

typedef struct FinchIntentProperty {
    char *owner;
    char *name;
    char *getter;
    char *setter;
    unsigned kind;
    unsigned copied;
    unsigned classProperty;
    char *scalarEncoding;
    struct FinchIntentProperty *next;
} FinchIntentProperty;

static FinchIntentProperty *sProperties;
static NSMutableArray *sIntentClassNames;
static char sValuesAssociationKey;
static char sParameterImagesAssociationKey;

static NSString *
FinchKey(const char *value)
{
    return value ? [NSString stringWithUTF8String:value] : nil;
}

static FinchIntentProperty *
FinchFindProperty(Class cls, SEL selector, BOOL classMethod)
{
    const char *selName = sel_getName(selector);
    for (Class current = cls; current; current = class_getSuperclass(current)) {
        const char *owner = class_getName(current);
        for (FinchIntentProperty *property = sProperties; property; property = property->next) {
            if (property->classProperty != (unsigned)classMethod || strcmp(property->owner, owner))
                continue;
            if (!strcmp(property->getter, selName) ||
                (property->setter && !strcmp(property->setter, selName)))
                return property;
        }
    }
    return NULL;
}

static NSMutableDictionary *
FinchMutableValues(id object, BOOL create)
{
    NSMutableDictionary *values = objc_getAssociatedObject(object, &sValuesAssociationKey);
    if (!values && create) {
        values = [[NSMutableDictionary alloc] init];
        objc_setAssociatedObject(object, &sValuesAssociationKey, values, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [values release];
        values = objc_getAssociatedObject(object, &sValuesAssociationKey);
    }
    return values;
}

static id
FinchValue(id object, NSString *name)
{
    return [FinchMutableValues(object, NO) objectForKey:name];
}

static void
FinchStoreValue(id object, NSString *name, id value, BOOL copyValue)
{
    if (!object || !name)
        return;
    NSMutableDictionary *values = FinchMutableValues(object, YES);
    if (value) {
        id stored = copyValue && [value conformsToProtocol:@protocol(NSCopying)] ? [value copy] : [value retain];
        [values setObject:stored forKey:name];
        [stored release];
    } else {
        [values removeObjectForKey:name];
    }
}

static void
FinchStorePropertyValue(id object, const char *propertyName, id value)
{
    NSString *name = nil;
    FinchIntentProperty *property = NULL;
    for (Class cls = object_getClass(object); cls && !property; cls = class_getSuperclass(cls)) {
        for (FinchIntentProperty *candidate = sProperties; candidate; candidate = candidate->next)
            if (!candidate->classProperty && !strcmp(candidate->owner, class_getName(cls)) &&
                !strcmp(candidate->name, propertyName)) {
                property = candidate;
                break;
            }
    }
    if (property)
        name = FinchKey(property->name);
    if (!name && propertyName && propertyName[0] == 'i' && propertyName[1] == 's' &&
        propertyName[2] >= 'A' && propertyName[2] <= 'Z') {
        char lowered[256];
        size_t size = strlen(propertyName + 2);
        if (size < sizeof(lowered)) {
            lowered[0] = (char)(propertyName[2] + ('a' - 'A'));
            memcpy(lowered + 1, propertyName + 3, size - 1);
            lowered[size] = 0;
            name = FinchKey(lowered);
        }
    }
    if (!name)
        name = FinchKey(propertyName);
    BOOL copied = property ? property->copied : YES;
    FinchStoreValue(object, name, value, copied);
}

static id
FinchGetObject(id object, SEL selector)
{
    BOOL classMethod = class_isMetaClass(object_getClass(object));
    Class cls = classMethod ? (Class)object : object_getClass(object);
    FinchIntentProperty *property = FinchFindProperty(cls, selector, classMethod);
    return property ? FinchValue(object, FinchKey(property->name)) : nil;
}

static void
FinchSetObject(id object, SEL selector, id value)
{
    BOOL classMethod = class_isMetaClass(object_getClass(object));
    Class cls = classMethod ? (Class)object : object_getClass(object);
    FinchIntentProperty *property = FinchFindProperty(cls, selector, classMethod);
    if (property)
        FinchStoreValue(object, FinchKey(property->name), value, property->copied);
}

static BOOL
FinchGetBool(id object, SEL selector)
{
    id value = FinchGetObject(object, selector);
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO;
}

static void
FinchSetBool(id object, SEL selector, int value)
{
    BOOL classMethod = class_isMetaClass(object_getClass(object));
    Class cls = classMethod ? (Class)object : object_getClass(object);
    FinchIntentProperty *property = FinchFindProperty(cls, selector, classMethod);
    if (property)
        FinchStoreValue(object, FinchKey(property->name), [NSNumber numberWithBool:value], NO);
}

static long long
FinchGetSigned(id object, SEL selector)
{
    id value = FinchGetObject(object, selector);
    return [value respondsToSelector:@selector(longLongValue)] ? [value longLongValue] : 0;
}

static void
FinchSetSigned(id object, SEL selector, long long value)
{
    BOOL classMethod = class_isMetaClass(object_getClass(object));
    Class cls = classMethod ? (Class)object : object_getClass(object);
    FinchIntentProperty *property = FinchFindProperty(cls, selector, classMethod);
    if (property)
        FinchStoreValue(object, FinchKey(property->name), [NSNumber numberWithLongLong:value], NO);
}

static unsigned long long
FinchGetUnsigned(id object, SEL selector)
{
    id value = FinchGetObject(object, selector);
    return [value respondsToSelector:@selector(unsignedLongLongValue)] ? [value unsignedLongLongValue] : 0;
}

static void
FinchSetUnsigned(id object, SEL selector, unsigned long long value)
{
    BOOL classMethod = class_isMetaClass(object_getClass(object));
    Class cls = classMethod ? (Class)object : object_getClass(object);
    FinchIntentProperty *property = FinchFindProperty(cls, selector, classMethod);
    if (property)
        FinchStoreValue(object, FinchKey(property->name), [NSNumber numberWithUnsignedLongLong:value], NO);
}

static double
FinchGetDouble(id object, SEL selector)
{
    id value = FinchGetObject(object, selector);
    return [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 0.0;
}

static void
FinchSetDouble(id object, SEL selector, double value)
{
    BOOL classMethod = class_isMetaClass(object_getClass(object));
    Class cls = classMethod ? (Class)object : object_getClass(object);
    FinchIntentProperty *property = FinchFindProperty(cls, selector, classMethod);
    if (property)
        FinchStoreValue(object, FinchKey(property->name), [NSNumber numberWithDouble:value], NO);
}

static float
FinchGetFloat(id object, SEL selector)
{
    id value = FinchGetObject(object, selector);
    return [value respondsToSelector:@selector(floatValue)] ? [value floatValue] : 0.0f;
}

static void
FinchSetFloat(id object, SEL selector, float value)
{
    BOOL classMethod = class_isMetaClass(object_getClass(object));
    Class cls = classMethod ? (Class)object : object_getClass(object);
    FinchIntentProperty *property = FinchFindProperty(cls, selector, classMethod);
    if (property)
        FinchStoreValue(object, FinchKey(property->name), [NSNumber numberWithFloat:value], NO);
}

static id
FinchCopyObject(id object, SEL selector, NSZone *zone)
{
    (void)selector;
    id copy = [[[object class] allocWithZone:zone] init];
    NSDictionary *values = FinchMutableValues(object, NO);
    if (values)
        objc_setAssociatedObject(copy, &sValuesAssociationKey, [[values mutableCopy] autorelease], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    id images = objc_getAssociatedObject(object, &sParameterImagesAssociationKey);
    if (images)
        objc_setAssociatedObject(copy, &sParameterImagesAssociationKey, [[images copy] autorelease], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return copy;
}

static BOOL
FinchObjectsEqual(id object, SEL selector, id other)
{
    (void)selector;
    if (object == other)
        return YES;
    if (!other || object_getClass(object) != object_getClass(other))
        return NO;
    NSDictionary *left = FinchMutableValues(object, NO) ?: @{};
    NSDictionary *right = FinchMutableValues(other, NO) ?: @{};
    NSDictionary *leftImages = objc_getAssociatedObject(object, &sParameterImagesAssociationKey) ?: @{};
    NSDictionary *rightImages = objc_getAssociatedObject(other, &sParameterImagesAssociationKey) ?: @{};
    return [left isEqualToDictionary:right] && [leftImages isEqualToDictionary:rightImages];
}

static NSUInteger
FinchObjectHash(id object, SEL selector)
{
    (void)selector;
    NSDictionary *values = FinchMutableValues(object, NO);
    NSDictionary *images = objc_getAssociatedObject(object, &sParameterImagesAssociationKey);
    return (values.hash * 33u) ^ images.hash ^ (NSUInteger)(uintptr_t)object_getClass(object);
}

static NSString *
FinchDisplayValue(id value)
{
    return value ? [value description] : @"<null>";
}

static NSString *
FinchObjectHeader(id object)
{
    return [NSString stringWithFormat:@"<%@: %p>", NSStringFromClass([object class]), object];
}

static NSString *
FinchIndented(NSString *description, NSString *indent)
{
    return [description stringByReplacingOccurrencesOfString:@"\n" withString:[@"\n" stringByAppendingString:indent]];
}

static NSString *
FinchNameComponentsDescription(NSPersonNameComponents *components)
{
    if (!components)
        return @"<null>";
    id phonetic = components.phoneticRepresentation;
    return [NSString stringWithFormat:
        @"%@ {givenName = %@, familyName = %@, middleName = %@, namePrefix = %@, nameSuffix = %@, nickname = %@ phoneticRepresentation = %@ }",
        FinchObjectHeader(components), components.givenName ?: @"(null)", components.familyName ?: @"(null)",
        components.middleName ?: @"(null)", components.namePrefix ?: @"(null)", components.nameSuffix ?: @"(null)",
        components.nickname ?: @"(null)", phonetic ? [phonetic description] : @"(null)"];
}

static NSString *
FinchPersonHandleTypeName(NSInteger value)
{
    switch (value) {
        case 1: return @"EmailAddress";
        case 2: return @"PhoneNumber";
        default: return @"Unknown";
    }
}

static NSString *
FinchEnumDescription(NSString *type, NSInteger value)
{
    if ([type isEqualToString:@"INCallAudioRoute"]) {
        switch (value) {
            case 1: return @"Speakerphone";
            case 2: return @"Bluetooth";
            default: return @"unknown";
        }
    }
    if ([type isEqualToString:@"INAnswerCallIntentResponseCode"] && value == 1)
        return @"INAnswerCallIntentResponseCodeReady";
    if ([type isEqualToString:@"INInteractionDirection"])
        return value == 1 ? @"Outgoing" : @"Incoming";
    if ([type isEqualToString:@"INIntentHandlingStatus"])
        return value == INIntentHandlingStatusReady ? @"Ready" : @"Unspecified";
    return [NSString stringWithFormat:@"%ld", (long)value];
}

static BOOL
FinchSupportsSecureCoding(id cls, SEL selector)
{
    return YES;
}

static void
FinchEncodeObject(id object, SEL selector, NSCoder *coder)
{
    NSDictionary *values = FinchMutableValues(object, NO) ?: @{};
    NSDictionary *images = objc_getAssociatedObject(object, &sParameterImagesAssociationKey) ?: @{};
    NSMutableDictionary *encodedValues = [values mutableCopy];
    id activity = [encodedValues objectForKey:@"userActivity"];
    if (activity && [activity isKindOfClass:[NSUserActivity class]]) {
        NSUserActivity *userActivity = activity;
        NSMutableDictionary *activityValues = [NSMutableDictionary dictionaryWithObject:@YES forKey:@"__FinchNSUserActivity"];
        NSDictionary *fields = @{
            @"activityType": [userActivity activityType] ?: @"",
            @"title": [userActivity title] ?: @"",
            @"persistentIdentifier": [userActivity persistentIdentifier] ?: @"",
            @"targetContentIdentifier": [userActivity targetContentIdentifier] ?: @"",
            @"userInfo": [userActivity userInfo] ?: @{},
            @"requiredUserInfoKeys": [userActivity requiredUserInfoKeys] ?: [NSSet set],
            @"keywords": [userActivity keywords] ?: [NSSet set]
        };
        for (NSString *key in fields)
            [activityValues setObject:[fields objectForKey:key] forKey:key];
        NSURL *webpageURL = [userActivity webpageURL];
        NSURL *referrerURL = [userActivity referrerURL];
        NSDate *expirationDate = [userActivity expirationDate];
        if (webpageURL) [activityValues setObject:webpageURL forKey:@"webpageURL"];
        if (referrerURL) [activityValues setObject:referrerURL forKey:@"referrerURL"];
        if (expirationDate) [activityValues setObject:expirationDate forKey:@"expirationDate"];
        [encodedValues setObject:activityValues forKey:@"userActivity"];
    }
    [coder encodeObject:encodedValues forKey:@"finch.values"];
    [coder encodeObject:images forKey:@"finch.images"];
    [encodedValues release];
}

static NSSet *
FinchAllowedCodingClasses(void)
{
    static NSSet *classes;
    @synchronized([NSObject class]) {
        if (!classes) {
            NSMutableSet *set = [NSMutableSet setWithObjects:
                [NSDictionary class], [NSMutableDictionary class], [NSArray class], [NSMutableArray class],
                [NSSet class], [NSMutableSet class], [NSString class], [NSMutableString class],
                [NSNumber class], [NSData class], [NSMutableData class], [NSDate class], [NSDateInterval class],
                [NSURL class], [NSUUID class], [NSNull class], [NSValue class], [NSDateComponents class],
                [NSPersonNameComponents class], [NSError class], [NSUserActivity class], nil];
            for (NSString *name in sIntentClassNames) {
                Class cls = NSClassFromString(name);
                if (cls)
                    [set addObject:cls];
            }
            classes = [set copy];
        }
    }
    return classes;
}

static id
FinchInitWithCoder(id object, SEL selector, NSCoder *coder)
{
    object = [object init];
    if (!object)
        return nil;
    NSDictionary *values = nil;
    NSDictionary *images = nil;
    if ([coder respondsToSelector:@selector(decodeObjectOfClasses:forKey:)]) {
        values = [coder decodeObjectOfClasses:FinchAllowedCodingClasses() forKey:@"finch.values"];
        images = [coder decodeObjectOfClasses:FinchAllowedCodingClasses() forKey:@"finch.images"];
    } else {
        values = [coder decodeObjectForKey:@"finch.values"];
        images = [coder decodeObjectForKey:@"finch.images"];
    }
    if (values) {
        NSMutableDictionary *copy = [values mutableCopy];
        id activityValues = [copy objectForKey:@"userActivity"];
        if ([activityValues isKindOfClass:[NSDictionary class]] &&
            [[activityValues objectForKey:@"__FinchNSUserActivity"] boolValue]) {
            NSUserActivity *activity = [[NSUserActivity alloc] initWithActivityType:
                [activityValues objectForKey:@"activityType"] ?: @""];
            activity.title = [activityValues objectForKey:@"title"];
            activity.persistentIdentifier = [activityValues objectForKey:@"persistentIdentifier"];
            activity.targetContentIdentifier = [activityValues objectForKey:@"targetContentIdentifier"];
            activity.userInfo = [activityValues objectForKey:@"userInfo"];
            activity.requiredUserInfoKeys = [activityValues objectForKey:@"requiredUserInfoKeys"];
            activity.keywords = [activityValues objectForKey:@"keywords"];
            activity.webpageURL = [activityValues objectForKey:@"webpageURL"];
            activity.referrerURL = [activityValues objectForKey:@"referrerURL"];
            activity.expirationDate = [activityValues objectForKey:@"expirationDate"];
            [copy setObject:activity forKey:@"userActivity"];
            [activity release];
        }
        objc_setAssociatedObject(object, &sValuesAssociationKey, copy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [copy release];
    }
    if (images)
        objc_setAssociatedObject(object, &sParameterImagesAssociationKey, images, OBJC_ASSOCIATION_COPY_NONATOMIC);
    return object;
}

static BOOL FinchClassOwnsMethod(Class cls, SEL selector, BOOL classMethod);

static void
FinchAddInstanceMethod(Class cls, SEL selector, IMP implementation, const char *types)
{
    if (!FinchClassOwnsMethod(cls, selector, NO))
        class_addMethod(cls, selector, implementation, types);
}

static void
FinchAddClassMethod(Class cls, SEL selector, IMP implementation, const char *types)
{
    if (!FinchClassOwnsMethod(cls, selector, YES))
        class_addMethod(object_getClass(cls), selector, implementation, types);
}

void
FinchIntentsRegisterClass(const char *className, unsigned flags)
{
    Class cls = objc_getClass(className);
    if (!cls)
        return;
    if (!sIntentClassNames)
        sIntentClassNames = [[NSMutableArray alloc] init];
    [sIntentClassNames addObject:FinchKey(className)];
    BOOL identityEquality = [NSStringFromClass(cls) isEqualToString:@"INShortcut"] ||
        [NSStringFromClass(cls) isEqualToString:@"INRelevantShortcut"] ||
        [NSStringFromClass(cls) isEqualToString:@"INInteraction"] ||
        [NSStringFromClass(cls) hasSuffix:@"IntentResponse"];
    if (flags & 1) {
        FinchAddInstanceMethod(cls, @selector(copyWithZone:), (IMP)FinchCopyObject, "@@:^v");
        if (!identityEquality) {
            FinchAddInstanceMethod(cls, @selector(isEqual:), (IMP)FinchObjectsEqual, "B@:@");
            FinchAddInstanceMethod(cls, @selector(hash), (IMP)FinchObjectHash, "Q@:");
        }
    } else if ([NSStringFromClass(cls) isEqualToString:@"INFile"]) {
        FinchAddInstanceMethod(cls, @selector(isEqual:), (IMP)FinchObjectsEqual, "B@:@");
        FinchAddInstanceMethod(cls, @selector(hash), (IMP)FinchObjectHash, "Q@:");
    }
    if (flags & 2) {
        FinchAddClassMethod(cls, @selector(supportsSecureCoding), (IMP)FinchSupportsSecureCoding, "B@:");
        FinchAddInstanceMethod(cls, @selector(encodeWithCoder:), (IMP)FinchEncodeObject, "v@:@");
        FinchAddInstanceMethod(cls, @selector(initWithCoder:), (IMP)FinchInitWithCoder, "@@:@");
    }
}

void
FinchIntentsRegisterProperty(const char *owner, const char *name, const char *getter, const char *setter,
                             unsigned kind, unsigned copied, unsigned classProperty, const char *encoding)
{
    Class cls = objc_getClass(owner);
    if (!cls)
        return;
    FinchIntentProperty *property = calloc(1, sizeof(*property));
    property->owner = strdup(owner);
    property->name = strdup(name);
    property->getter = strdup(getter);
    property->setter = setter ? strdup(setter) : NULL;
    property->kind = kind;
    property->copied = copied;
    property->classProperty = classProperty;
    property->scalarEncoding = strdup(encoding ?: "@");
    property->next = sProperties;
    sProperties = property;

    SEL getSelector = sel_registerName(getter);
    IMP getImplementation = kind == 0 ? (IMP)FinchGetObject :
        kind == 1 ? (IMP)FinchGetBool : kind == 2 ? (IMP)FinchGetDouble :
        kind == 4 ? (IMP)FinchGetUnsigned : kind == 5 ? (IMP)FinchGetFloat : (IMP)FinchGetSigned;
    char getTypes[32];
    snprintf(getTypes, sizeof(getTypes), "%s@:", encoding ?: "@");
    if (classProperty)
        FinchAddClassMethod(cls, getSelector, getImplementation, getTypes);
    else
        FinchAddInstanceMethod(cls, getSelector, getImplementation, getTypes);

    if (setter) {
        SEL setSelector = sel_registerName(setter);
        IMP setImplementation = kind == 0 ? (IMP)FinchSetObject :
            kind == 1 ? (IMP)FinchSetBool : kind == 2 ? (IMP)FinchSetDouble :
            kind == 4 ? (IMP)FinchSetUnsigned : kind == 5 ? (IMP)FinchSetFloat : (IMP)FinchSetSigned;
        char setTypes[32];
        snprintf(setTypes, sizeof(setTypes), "v@:%s", encoding ?: "@");
        if (classProperty)
            FinchAddClassMethod(cls, setSelector, setImplementation, setTypes);
        else
            FinchAddInstanceMethod(cls, setSelector, setImplementation, setTypes);
    }
}

id
FinchIntentsCreateObject(id receiver, unsigned classMethod)
{
    return classMethod ? [[(Class)receiver alloc] init] : [receiver init];
}

void
FinchIntentsSetArgumentValue(id object, const char *propertyName, id value)
{
    FinchStorePropertyValue(object, propertyName, value);
}

void
FinchIntentsSetResolutionStatus(id object, const char *selectorName)
{
    NSString *name = FinchKey(selectorName);
    NSString *status = [name rangeOfString:@"success" options:NSCaseInsensitiveSearch].location != NSNotFound ? @"Success" :
        [name rangeOfString:@"unsupported" options:NSCaseInsensitiveSearch].location != NSNotFound ? @"Unsupported" :
        [name rangeOfString:@"needsValue" options:NSCaseInsensitiveSearch].location != NSNotFound ? @"NeedsValue" :
        [name rangeOfString:@"notRequired" options:NSCaseInsensitiveSearch].location != NSNotFound ? @"NotRequired" :
        [name rangeOfString:@"confirmationRequired" options:NSCaseInsensitiveSearch].location != NSNotFound ? @"ConfirmationRequired" :
        [name rangeOfString:@"disambiguation" options:NSCaseInsensitiveSearch].location != NSNotFound ? @"Disambiguation" : @"Unspecified";
    FinchStoreValue(object, @"resolutionResultCode", status, YES);
}

static BOOL
FinchClassOwnsMethod(Class cls, SEL selector, BOOL classMethod)
{
    Class target = classMethod ? object_getClass(cls) : cls;
    unsigned count = 0;
    Method *methods = class_copyMethodList(target, &count);
    BOOL found = NO;
    for (unsigned i = 0; i < count; i++)
        if (method_getName(methods[i]) == selector) {
            found = YES;
            break;
        }
    free(methods);
    return found;
}

void
FinchIntentsRegisterMethod(const char *owner, const char *selectorName, unsigned classMethod, unsigned factory,
                           const char *types, IMP implementation)
{
    (void)factory;
    Class cls = objc_getClass(owner);
    if (!cls)
        return;
    SEL selector = sel_registerName(selectorName);
    BOOL owns = FinchClassOwnsMethod(cls, selector, classMethod);
    if (!owns) {
        Class target = classMethod ? object_getClass(cls) : cls;
        class_addMethod(target, selector, implementation, types);
    }
}

extern void FinchIntentsInstallGenerated(void);

__attribute__((constructor)) static void
FinchInstallIntentsRuntime(void)
{
    FinchIntentsInstallGenerated();
}

static NSError *
FinchIntentError(INIntentErrorCode code, NSString *description)
{
    return [NSError errorWithDomain:INIntentErrorDomain code:code
                           userInfo:@{ NSLocalizedDescriptionKey : description ?: @"The Intents service is unavailable." }];
}

static NSString *
FinchInteractionStorePath(void)
{
    NSString *home = NSHomeDirectory();
    return [[home stringByAppendingPathComponent:@"Library/Finch/Intents"] stringByAppendingPathComponent:@"interactions.archive"];
}

static NSSet *
FinchInteractionArchiveClasses(void)
{
    NSMutableSet *classes = [NSMutableSet setWithSet:FinchAllowedCodingClasses()];
    [classes addObject:[INInteraction class]];
    return classes;
}

static NSArray *
FinchReadInteractions(NSError **error)
{
    NSData *data = [NSData dataWithContentsOfFile:FinchInteractionStorePath()];
    if (!data)
        return @[];
    NSError *decodeError = nil;
    NSArray *interactions = [NSKeyedUnarchiver unarchivedObjectOfClasses:FinchInteractionArchiveClasses()
                                                               fromData:data error:&decodeError];
    if (!interactions && error)
        *error = decodeError;
    return interactions ?: @[];
}

static BOOL
FinchWriteInteractions(NSArray *interactions, NSError **error)
{
    NSString *path = FinchInteractionStorePath();
    NSString *directory = [path stringByDeletingLastPathComponent];
    if (![[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES
                                                   attributes:nil error:error])
        return NO;
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:interactions requiringSecureCoding:YES error:error];
    return data && [data writeToFile:path options:NSDataWritingAtomic error:error];
}

@implementation INPerson (FinchValues)
- (NSString *)displayName
{
    NSString *displayName = FinchValue(self, @"displayName");
    if (displayName.length)
        return displayName;
    NSPersonNameComponents *components = FinchValue(self, @"nameComponents");
    if (components) {
        NSString *formatted = [NSPersonNameComponentsFormatter localizedStringFromPersonNameComponents:components
                                                                                                 style:NSPersonNameComponentsFormatterStyleDefault
                                                                                               options:0];
        if (formatted.length)
            return formatted;
    }
    INPersonHandle *handle = FinchValue(self, @"personHandle");
    return handle.value ?: @"";
}

- (BOOL)isContactSuggestion
{
    return [FinchValue(self, @"contactSuggestion") boolValue];
}
@end

@implementation INPersonHandle (FinchDescription)
- (NSString *)description
{
    return [NSString stringWithFormat:@"%@ {\n    value = %@;\n    type = %@;\n    label = %@;\n}",
            FinchObjectHeader(self), FinchDisplayValue(self.value), FinchPersonHandleTypeName(self.type),
            FinchDisplayValue(self.label)];
}
@end

@implementation INPerson (FinchDescription)
- (NSString *)description
{
    INImage *image = FinchValue(self, @"image");
    NSString *imageDescription = image ? [NSString stringWithFormat:@"<_INDataImage: %p>", image] : @"<null>";
    INPersonHandle *handle = self.personHandle;
    NSString *handleDescription = handle ? FinchIndented([handle description], @"    ") : @"<null>";
    return [NSString stringWithFormat:@"%@ {\n    displayName = %@;\n    contactIdentifier = %@;\n    nameComponents = %@;\n    image = %@;\n    customIdentifier = %@;\n    relationship = %@;\n    siriMatches = <null>;\n    personHandle = %@;\n}",
            FinchObjectHeader(self), FinchDisplayValue(FinchValue(self, @"displayName")),
            FinchDisplayValue(self.contactIdentifier), FinchNameComponentsDescription(self.nameComponents), imageDescription,
            FinchDisplayValue(self.customIdentifier), FinchDisplayValue(FinchValue(self, @"relationship")),
            handleDescription];
}
@end

@implementation INObject (FinchDescription)
- (NSString *)description
{
    return [NSString stringWithFormat:@"%@ {\n    pronunciationHint = %@;\n    displayString = %@;\n    subtitleString = %@;\n    identifier = %@;\n    alternativeSpeakableMatches = <null>;\n}",
            FinchObjectHeader(self), FinchDisplayValue(self.pronunciationHint), FinchDisplayValue(self.displayString),
            FinchDisplayValue(self.subtitleString), FinchDisplayValue(self.identifier)];
}
@end

@implementation INAirline (FinchDescription)
- (NSString *)description
{
    return [NSString stringWithFormat:@"%@ {\n    name = %@;\n    iataCode = %@;\n    icaoCode = %@;\n}",
            FinchObjectHeader(self), FinchDisplayValue(self.name), FinchDisplayValue(self.iataCode),
            FinchDisplayValue(self.icaoCode)];
}
@end

@implementation INSpeakableString (FinchDescription)
- (NSString *)description
{
    return self.spokenPhrase ?: @"";
}
@end

@implementation INAnswerCallIntent (FinchDescription)
- (NSString *)description
{
    return [NSString stringWithFormat:@"%@ {\n    audioRoute = %@;\n    callIdentifier = %@;\n}",
            FinchObjectHeader(self), FinchEnumDescription(@"INCallAudioRoute", self.audioRoute),
            FinchDisplayValue(self.callIdentifier)];
}
@end

@implementation INAnswerCallIntentResponse (FinchDescription)
- (NSString *)description
{
    return [NSString stringWithFormat:@"%@ {\n    callRecords = %@;\n    code = %@;\n}",
            FinchObjectHeader(self), FinchDisplayValue(self.callRecords),
            FinchEnumDescription(@"INAnswerCallIntentResponseCode", self.code)];
}
@end

@implementation INFocusStatus (FinchDescription)
- (NSString *)description
{
    return [NSString stringWithFormat:@"%@ {\n    isFocused = %@;\n}", FinchObjectHeader(self),
            FinchDisplayValue(self.isFocused)];
}
@end

@implementation INIntentResolutionResult (FinchDescription)
- (NSString *)description
{
    id status = FinchValue(self, @"resolutionResultCode");
    NSString *statusName = [status isKindOfClass:[NSString class]] ? status : @"Unspecified";
    id resolved = FinchValue(self, @"resolvedValue");
    return [NSString stringWithFormat:@"%@ {\n    resolutionResultCode = %@;\n    resolvedValue = %@;\n    disambiguationItems = <null>;\n    itemToConfirm = <null>;\n    unsupportedReason = 0;\n}", FinchObjectHeader(self), statusName,
            FinchDisplayValue(resolved)];
}
@end

@implementation INShortcut (FinchDescription)
- (id)copyWithZone:(NSZone *)zone
{
    return [self retain];
}

- (NSString *)description
{
    id activity = FinchValue(self, @"userActivity");
    return [NSString stringWithFormat:@"<%@: %p userActivity: %@>", NSStringFromClass([self class]), self,
            activity ? [activity description] : @"<null>"];
}
@end

@implementation INInteraction (FinchDescription)
- (NSString *)description
{
    NSDateInterval *interval = self.dateInterval;
    NSDateFormatter *formatter = [[[NSDateFormatter alloc] init] autorelease];
    formatter.locale = [[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"] autorelease];
    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    NSString *start = interval ? [formatter stringFromDate:interval.startDate] : @"(null)";
    NSString *end = interval ? [formatter stringFromDate:interval.endDate] : @"(null)";
    NSString *intentDescription = self.intent ? FinchIndented([self.intent description], @"    ") : @"<null>";
    NSString *responseDescription = self.intentResponse ? FinchIndented([self.intentResponse description], @"    ") : @"<null>";
    NSString *dateDescription = interval ? [NSString stringWithFormat:
        @"<_NSConcreteDateInterval: %p> (Start Date) %@ +0000 + (Duration) %.6f seconds = (End Date) %@ +0000",
        interval, start, interval.duration, end] : @"<null>";
    return [NSString stringWithFormat:@"%@ {\n    intent = %@;\n    dateInterval = %@;\n    intentResponse = %@;\n    groupIdentifier = %@;\n    intentHandlingStatus = %@;\n    identifier = %@;\n    direction = %@;\n}", FinchObjectHeader(self), intentDescription,
            dateDescription, responseDescription, FinchDisplayValue(self.groupIdentifier),
            FinchEnumDescription(@"INIntentHandlingStatus", self.intentHandlingStatus),
            FinchDisplayValue(self.identifier), FinchEnumDescription(@"INInteractionDirection", self.direction)];
}
@end

@implementation INObject (FinchSpeakable)
- (NSString *)spokenPhrase
{
    return self.displayString;
}

- (NSString *)vocabularyIdentifier
{
    return self.identifier;
}
@end

@implementation INImage (FinchValues)
+ (instancetype)imageNamed:(NSString *)name
{
    if (!name.length)
        return nil;
    INImage *image = [[self alloc] init];
    FinchStoreValue(image, @"name", name, YES);
    return [image autorelease];
}

+ (instancetype)imageWithImageData:(NSData *)imageData
{
    if (!imageData)
        return nil;
    INImage *image = [[self alloc] init];
    FinchStoreValue(image, @"imageData", imageData, YES);
    return [image autorelease];
}

+ (instancetype)imageWithURL:(NSURL *)URL
{
    if (!URL || !URL.scheme.length)
        return nil;
    INImage *image = [[self alloc] init];
    FinchStoreValue(image, @"URL", URL, YES);
    return [image autorelease];
}

+ (instancetype)imageWithURL:(NSURL *)URL width:(double)width height:(double)height
{
    INImage *image = [self imageWithURL:URL];
    if (image) {
        FinchStoreValue(image, @"width", [NSNumber numberWithDouble:width], NO);
        FinchStoreValue(image, @"height", [NSNumber numberWithDouble:height], NO);
    }
    return image;
}
@end

@implementation INFile (FinchValues)
+ (INFile *)fileWithData:(NSData *)data filename:(NSString *)filename typeIdentifier:(NSString *)typeIdentifier
{
    if (!data || !filename.length)
        return nil;
    INFile *file = [[self alloc] init];
    FinchStoreValue(file, @"data", data, YES);
    FinchStoreValue(file, @"filename", filename, YES);
    FinchStoreValue(file, @"typeIdentifier", typeIdentifier, YES);
    return [file autorelease];
}

+ (INFile *)fileWithFileURL:(NSURL *)fileURL filename:(NSString *)filename typeIdentifier:(NSString *)typeIdentifier
{
    if (!fileURL.isFileURL)
        return nil;
    INFile *file = [[self alloc] init];
    FinchStoreValue(file, @"fileURL", fileURL, NO);
    FinchStoreValue(file, @"filename", filename.length ? filename : fileURL.lastPathComponent, YES);
    FinchStoreValue(file, @"typeIdentifier", typeIdentifier, YES);
    return [file autorelease];
}

- (NSData *)data
{
    NSData *data = FinchValue(self, @"data");
    if (data)
        return data;
    NSURL *URL = FinchValue(self, @"fileURL");
    return URL ? [NSData dataWithContentsOfURL:URL] : nil;
}
@end

@implementation INPaymentMethod (FinchValues)
+ (instancetype)applePayPaymentMethod
{
    INPaymentMethod *method = [[self alloc] init];
    FinchStorePropertyValue(method, "type", [NSNumber numberWithInteger:INPaymentMethodTypeApplePay]);
    return [method autorelease];
}
@end

@implementation INFocusStatusCenter (FinchServices)
+ (INFocusStatusCenter *)defaultCenter
{
    static INFocusStatusCenter *center;
    @synchronized(self) {
        if (!center)
            center = [[self alloc] init];
    }
    return center;
}

- (INFocusStatus *)focusStatus
{
    return [[[INFocusStatus alloc] initWithIsFocused:[NSNumber numberWithBool:NO]] autorelease];
}

- (INFocusStatusAuthorizationStatus)authorizationStatus
{
    return INFocusStatusAuthorizationStatusNotDetermined;
}

- (void)requestAuthorizationWithCompletionHandler:(void (^)(INFocusStatusAuthorizationStatus))completionHandler
{
    if (completionHandler)
        completionHandler(INFocusStatusAuthorizationStatusNotDetermined);
}
@end

@implementation NSString (FinchDeferredIntentsStrings)
static NSString *
FinchDeferredLocalizedString(NSString *format, NSString *table, va_list arguments)
{
    NSString *localized = [[NSBundle mainBundle] localizedStringForKey:format value:format table:table];
    NSMutableString *result = [NSMutableString string];
    va_list values;
    va_copy(values, arguments);
    for (NSUInteger index = 0; index < localized.length;) {
        unichar character = [localized characterAtIndex:index];
        if (character == '%' && index + 1 < localized.length) {
            unichar next = [localized characterAtIndex:index + 1];
            if (next == '%') {
                [result appendString:@"%"];
                index += 2;
                continue;
            }
            if (next == '@') {
                id value = va_arg(values, id);
                [result appendString:value ? [value description] : @"(null)"];
                index += 2;
                continue;
            }
        }
        [result appendFormat:@"%C", character];
        index++;
    }
    va_end(values);
    return result;
}

+ (NSString *)deferredLocalizedIntentsStringWithFormat:(NSString *)format, ...
{
    va_list arguments;
    va_start(arguments, format);
    NSString *result = FinchDeferredLocalizedString(format, nil, arguments);
    va_end(arguments);
    return result;
}

+ (NSString *)deferredLocalizedIntentsStringWithFormat:(NSString *)format fromTable:(NSString *)table, ...
{
    va_list arguments;
    va_start(arguments, table);
    NSString *result = FinchDeferredLocalizedString(format, table, arguments);
    va_end(arguments);
    return result;
}

+ (NSString *)deferredLocalizedIntentsStringWithFormat:(NSString *)format fromTable:(NSString *)table arguments:(va_list)arguments
{
    return FinchDeferredLocalizedString(format, table, arguments);
}
@end

@implementation INIntent (FinchValues)
- (void)setImage:(INImage *)image forParameterNamed:(NSString *)parameterName
{
    if (!parameterName.length)
        return;
    NSMutableDictionary *images = [objc_getAssociatedObject(self, &sParameterImagesAssociationKey) mutableCopy];
    if (!images)
        images = [[NSMutableDictionary alloc] init];
    if (image)
        [images setObject:image forKey:parameterName];
    else
        [images removeObjectForKey:parameterName];
    FinchStoreValue(self, @"parameterImages", images, YES);
    objc_setAssociatedObject(self, &sParameterImagesAssociationKey, images, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [images release];
}

- (INImage *)imageForParameterNamed:(NSString *)parameterName
{
    return [objc_getAssociatedObject(self, &sParameterImagesAssociationKey) objectForKey:parameterName];
}

- (INImage *)keyImage
{
    return [[objc_getAssociatedObject(self, &sParameterImagesAssociationKey) allValues] firstObject];
}
@end

@implementation INInteraction (FinchValues)
- (instancetype)initWithIntent:(INIntent *)intent response:(INIntentResponse *)response
{
    if ((self = [super init])) {
        FinchStoreValue(self, @"intent", intent, YES);
        FinchStoreValue(self, @"intentResponse", response, YES);
        FinchStoreValue(self, @"identifier", [[NSUUID UUID] UUIDString], YES);
        NSDate *now = [NSDate date];
        FinchStoreValue(self, @"dateInterval", [[[NSDateInterval alloc] initWithStartDate:now duration:0] autorelease], YES);
        FinchStoreValue(self, @"intentHandlingStatus", [NSNumber numberWithInteger:INIntentHandlingStatusReady], NO);
    }
    return self;
}

- (void)donateInteractionWithCompletion:(void (^)(NSError *))completion
{
    NSError *error = nil;
    @synchronized([INInteraction class]) {
        NSMutableArray *items = [[FinchReadInteractions(&error) mutableCopy] autorelease];
        if (!items)
            items = [NSMutableArray array];
        NSString *identifier = self.identifier;
        NSIndexSet *old = [items indexesOfObjectsPassingTest:^BOOL(INInteraction *item, NSUInteger index, BOOL *stop) {
            return [item.identifier isEqualToString:identifier];
        }];
        [items removeObjectsAtIndexes:old];
        [items addObject:self];
        if (!FinchWriteInteractions(items, &error) && !error)
            error = FinchIntentError(INIntentErrorDonatingInteraction, @"The local interaction store could not be written.");
    }
    if (completion)
        completion(error);
}

+ (void)deleteAllInteractionsWithCompletion:(void (^)(NSError *))completion
{
    NSError *error = nil;
    @synchronized(self) {
        if (!FinchWriteInteractions(@[], &error) && !error)
            error = FinchIntentError(INIntentErrorDeletingAllInteractions, @"The local interaction store could not be cleared.");
    }
    if (completion)
        completion(error);
}

+ (void)deleteInteractionsWithIdentifiers:(NSArray<NSString *> *)identifiers completion:(void (^)(NSError *))completion
{
    NSError *error = nil;
    @synchronized(self) {
        NSMutableArray *items = [[FinchReadInteractions(&error) mutableCopy] autorelease];
        [items filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(INInteraction *item, NSDictionary *bindings) {
            return ![identifiers containsObject:item.identifier];
        }]];
        if (!FinchWriteInteractions(items ?: @[], &error) && !error)
            error = FinchIntentError(INIntentErrorDeletingInteractionWithIdentifiers, @"The local interaction store could not be updated.");
    }
    if (completion)
        completion(error);
}

+ (void)deleteInteractionsWithGroupIdentifier:(NSString *)groupIdentifier completion:(void (^)(NSError *))completion
{
    NSError *error = nil;
    @synchronized(self) {
        NSMutableArray *items = [[FinchReadInteractions(&error) mutableCopy] autorelease];
        [items filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(INInteraction *item, NSDictionary *bindings) {
            return ![item.groupIdentifier isEqualToString:groupIdentifier];
        }]];
        if (!FinchWriteInteractions(items ?: @[], &error) && !error)
            error = FinchIntentError(INIntentErrorDeletingInteractionWithGroupIdentifier, @"The local interaction store could not be updated.");
    }
    if (completion)
        completion(error);
}
@end

@implementation INPreferences (FinchServices)
+ (INSiriAuthorizationStatus)siriAuthorizationStatus
{
    return INSiriAuthorizationStatusNotDetermined;
}

+ (void)requestSiriAuthorization:(void (^)(INSiriAuthorizationStatus))handler
{
    if (handler)
        handler(INSiriAuthorizationStatusNotDetermined);
}

+ (NSString *)siriLanguageCode
{
    return @"";
}
@end

@implementation INVoiceShortcutCenter (FinchServices)
+ (INVoiceShortcutCenter *)sharedCenter
{
    static INVoiceShortcutCenter *center;
    @synchronized(self) {
        if (!center)
            center = [[self alloc] init];
    }
    return center;
}

- (void)getAllVoiceShortcutsWithCompletion:(void (^)(NSArray<INVoiceShortcut *> *, NSError *))completionHandler
{
    if (completionHandler)
        completionHandler(nil, nil);
}

- (void)getVoiceShortcutWithIdentifier:(NSUUID *)identifier completion:(void (^)(INVoiceShortcut *, NSError *))completionHandler
{
    if (completionHandler)
        completionHandler(nil, nil);
}

- (void)setShortcutSuggestions:(NSArray<INShortcut *> *)suggestions
{
    (void)suggestions;
}
@end

@implementation INRelevantShortcutStore (FinchServices)
+ (INRelevantShortcutStore *)defaultStore
{
    static INRelevantShortcutStore *store;
    @synchronized(self) {
        if (!store)
            store = [[self alloc] init];
    }
    return store;
}

- (void)setRelevantShortcuts:(NSArray<INRelevantShortcut *> *)shortcuts completionHandler:(void (^)(NSError *))completionHandler
{
    (void)shortcuts;
    if (completionHandler)
        completionHandler(FinchIntentError(INIntentErrorInteractionOperationNotSupported,
                                           @"The Siri relevance service is not available."));
}
@end
