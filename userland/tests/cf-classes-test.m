/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-cf-classes-test: the classes CoreFoundation exports beyond its
 * bridged ones, against Apple's and Finch's (tools/host-tests.sh diffs the
 * runs; the first line names the CoreFoundation used):
 *
 *   NSConstantData, NSConstantDate   instances laid out as a linker emits them
 *   NSTaggedPointerString            from _CFStringCreateTaggedPointerString
 *   NSIndirectTaggedPointerString    as Swift makes them
 *   NSBlockInvocation                invoking a block
 *   NSSharedKeySet                   indexes, keys, archiving
 *
 * Built without ARC (the constant objects are made by hand).
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

CFStringRef _CFStringCreateTaggedPointerString(const uint8_t *bytes, CFIndex count);

@interface NSObject (CFClassesTest)
+ (id)keySetWithKeys:(NSArray *)keys;
- (NSUInteger)indexForKey:(id)key;
- (id)keyAtIndex:(NSUInteger)index;
- (BOOL)isEmpty;
- (NSUInteger)keySetCount;
- (NSArray *)allKeys;
@end

static void
line(const char *what, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    printf("%s: ", what);
    vprintf(fmt, ap);
    printf("\n");
    va_end(ap);
}

static const char *
yes(BOOL b) { return b ? "yes" : "no"; }

/* An instance as the compiler or linker lays it out: the class, then ivars at the
   class's own offsets. */
static id
constant_instance(const char *name)
{
    return class_createInstance(objc_getClass(name), 0);
}

static void
set_ivar(id obj, const char *name, const void *value, size_t size)
{
    Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
    memcpy((char *)obj + ivar_getOffset(iv), value, size);
}

static void
classes(void)
{
    const char *names[] = { "NSConstantData", "NSConstantDate", "NSTaggedPointerString",
        "NSIndirectTaggedPointerString", "NSBlockInvocation", "NSSharedKeySet" };
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        Class c = objc_getClass(names[i]);
        line(names[i], "%s, subclass of %s", c ? "exists" : "missing", c ? class_getName(class_getSuperclass(c)) : "-");
    }
    line("NSConstantData size", "%zu", class_getInstanceSize(objc_getClass("NSConstantData")));
    line("NSConstantDate size", "%zu", class_getInstanceSize(objc_getClass("NSConstantDate")));
}

static void
constant_objects(void)
{
    id data = constant_instance("NSConstantData");
    NSUInteger length = 3;
    const char *bytes = "abc";
    set_ivar(data, "_length", &length, sizeof(length));
    set_ivar(data, "_bytes", &bytes, sizeof(bytes));
    line("constant data", "length %lu, bytes %.3s", (unsigned long)[data length], (const char *)[data bytes]);
    line("constant data is immortal", "%s", yes([data retainCount] == UINTPTR_MAX && [[data retain] retainCount] == UINTPTR_MAX));
    [data release];
    line("constant data copies to itself", "%s", yes([data copy] == data));
    line("constant data equals the same bytes", "%s", yes([data isEqual:[NSData dataWithBytes:"abc" length:3]]));
    line("constant data hash", "%s", yes([data hash] == [[NSData dataWithBytes:"abc" length:3] hash]));
    line("constant data description", "%s", [[data description] UTF8String]);
    id mutable = [[data mutableCopy] autorelease];
    [mutable appendBytes:"d" length:1];
    line("its mutable copy", "%lu bytes", (unsigned long)[mutable length]);
    id alloc = [[objc_getClass("NSConstantData") alloc] initWithBytes:"xy" length:2];
    line("allocating one makes ordinary data", "%s, length %lu, %s", yes([alloc isKindOfClass:[NSData class]]),
        (unsigned long)[alloc length], yes(![alloc isKindOfClass:objc_getClass("NSConstantData")]));
    [alloc release];

    id date = constant_instance("NSConstantDate");
    double ti = 100.5;
    set_ivar(date, "_ti", &ti, sizeof(ti));
    line("constant date", "%.1f", [date timeIntervalSinceReferenceDate]);
    line("constant date is immortal", "%s", yes([date retainCount] == UINTPTR_MAX));
    line("constant date copies to itself", "%s", yes([date copy] == date));
    line("constant date equals the same time", "%s", yes([date isEqual:[NSDate dateWithTimeIntervalSinceReferenceDate:100.5]]));
    line("constant date description", "%s", [[date description] UTF8String]);
    line("constant date compares", "%ld", (long)[date compare:[NSDate dateWithTimeIntervalSinceReferenceDate:0]]);
    id dalloc = [[objc_getClass("NSConstantDate") alloc] initWithTimeIntervalSinceReferenceDate:5];
    line("allocating one makes an ordinary date", "%s, %.0f", yes(![dalloc isKindOfClass:objc_getClass("NSConstantDate")]),
        [dalloc timeIntervalSinceReferenceDate]);
    [dalloc release];
}

static void
string_checks(const char *what, NSString *s, NSString *same)
{
    line(what, "class %s, length %lu, \"%s\"", object_getClassName(s), (unsigned long)[s length], [s UTF8String]);
    line(what, "equal %s, hash matches %s, compare %ld", yes([s isEqual:same] && [same isEqual:s] && [s isEqualToString:same]),
        yes([s hash] == [same hash]), (long)[s compare:same]);
    line(what, "CF length %ld, CF equal %s, type is CFString %s", (long)CFStringGetLength((CFStringRef)s),
        yes(CFEqual((CFStringRef)s, (CFStringRef)same)), yes(CFGetTypeID((CFTypeRef)s) == CFStringGetTypeID()));
    line(what, "copy is itself %s, retain is itself %s", yes([[s copy] autorelease] == s), yes([s retain] == s));
    [s release];
    line(what, "uppercase \"%s\", substring \"%s\", prefix %s", [[s uppercaseString] UTF8String],
        [[s substringFromIndex:1] UTF8String], yes([s hasPrefix:[same substringToIndex:1]]));
    NSDictionary *d = @{ same : @"found" };
    line(what, "as a dictionary key: %s", [[d objectForKey:s] UTF8String]);
    @try {
        [s characterAtIndex:[s length]];
        line(what, "past the end: no exception");
    } @catch (NSException *e) {
        line(what, "past the end: %s", [[e name] UTF8String]);
    }
}

static void
tagged_strings(void)
{
    NSString *direct = (NSString *)_CFStringCreateTaggedPointerString((const uint8_t *)"abc", 3);
    line("tagged string made", "%s", yes(direct != nil));
    if (direct)
        string_checks("tagged", direct, [NSString stringWithFormat:@"%s", "abc"]);
    line("non-ASCII isn't tagged", "%s", yes(_CFStringCreateTaggedPointerString((const uint8_t *)"\xc3\xa9", 2) == NULL));

    static const char constant[] = "an immortal Swift string literal";
    Class indirectClass = objc_getClass("NSIndirectTaggedPointerString");
    SEL make = sel_registerName("newIndirectTaggedNSStringWithConstantNullTerminatedASCIIBytes_:length_:");
    NSString *indirect = ((id (*)(id, SEL, const char *, CFIndex))objc_msgSend)(indirectClass, make, constant,
        (CFIndex)strlen(constant));
    line("indirect tagged string made", "%s", yes(indirect != nil));
    if (indirect) {
        string_checks("indirect", indirect, [NSString stringWithFormat:@"%s", constant]);
        line("indirect", "UTF8String is the constant itself %s", yes([indirect UTF8String] == constant));
    }
}

static void
block_invocation(void)
{
    int (^block)(int, int) = ^int(int x, int y) { return x * 10 + y; };
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:"i@?ii"];
    NSInvocation *inv = [objc_getClass("NSBlockInvocation") invocationWithMethodSignature:sig];
    line("block invocation", "class %s, %lu arguments", object_getClassName(inv), (unsigned long)[sig numberOfArguments]);
    [inv setTarget:block];
    int x = 4, y = 2, r = 0;
    [inv setArgument:&x atIndex:1];
    [inv setArgument:&y atIndex:2];
    [inv invoke];
    [inv getReturnValue:&r];
    line("block invocation", "returns %d, target is the block %s", r, yes([inv target] == (id)block));
    const char *sels[] = { "selector", "invokeSuper" };
    for (size_t i = 0; i < 2; i++) {
        @try {
            ((void (*)(id, SEL))objc_msgSend)(inv, sel_registerName(sels[i]));
            line("block invocation", "%s answers", sels[i]);
        } @catch (NSException *e) {
            line("block invocation", "%s: %s", sels[i], [[e name] UTF8String]);
        }
    }
    [inv retainArguments];
    [inv setTarget:nil];
    r = 7;
    [inv setReturnValue:&r];
    [inv invoke];
    [inv getReturnValue:&r];
    line("block invocation without a block", "leaves the result: %d", r);
    void (^noArgs)(void) = ^{ printf("block invocation: the block ran\n"); };
    NSInvocation *plain = [objc_getClass("NSBlockInvocation") invocationWithMethodSignature:[NSMethodSignature signatureWithObjCTypes:"v@?"]];
    [plain setTarget:noArgs];
    [plain invoke];
}

static void
shared_key_sets(void)
{
    NSArray *keys = @[ @"a", @"b", @"c" ];
    id ks = [NSDictionary sharedKeySetForKeys:keys];
    line("shared key set", "class %s, count %lu, empty %s, key sets %lu", object_getClassName(ks), (unsigned long)[ks count],
        yes([ks isEmpty]), (unsigned long)[ks keySetCount]);
    BOOL roundTrip = YES;
    for (NSString *k in keys)
        roundTrip = roundTrip && [ks indexForKey:k] < 3 && [[ks keyAtIndex:[ks indexForKey:k]] isEqual:k];
    line("shared key set", "each key's index finds it %s, missing key %s", yes(roundTrip),
        [ks indexForKey:@"z"] == NSNotFound ? "NSNotFound" : "found");
    line("shared key set", "all keys %s", yes([[NSSet setWithArray:[ks allKeys]] isEqual:[NSSet setWithArray:keys]]));
    NSUInteger n = 0;
    for (id k in ks) { (void)k; n++; }
    line("shared key set", "enumerates %lu keys", (unsigned long)n);
    NSError *error = nil;
    NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:ks requiringSecureCoding:YES error:&error];
    id back = archive ? [NSKeyedUnarchiver unarchivedObjectOfClass:[ks class] fromData:archive error:&error] : nil;
    line("shared key set", "archives %s, comes back equal %s", yes(archive != nil), yes([back isEqual:ks]));
    NSDictionary *plist = archive ? [NSPropertyListSerialization propertyListWithData:archive options:0 format:NULL error:NULL] : nil;
    NSDictionary *object = plist ? [plist[@"$objects"] objectAtIndex:1] : nil;
    line("shared key set", "archive has NS.keys %s, NS.numKey %ld", yes(object[@"NS.keys"] != nil), (long)[object[@"NS.numKey"] integerValue]);
    NSMutableDictionary *m = [NSMutableDictionary dictionaryWithSharedKeySet:ks];
    m[@"a"] = @1;
    m[@"z"] = @2;
    line("dictionary with it", "%lu entries, a=%s z=%s", (unsigned long)[m count], [[m[@"a"] description] UTF8String],
        [[m[@"z"] description] UTF8String]);
    id empty = [NSDictionary sharedKeySetForKeys:@[]];
    line("empty shared key set", "count %lu, empty %s", (unsigned long)[empty count], yes([empty isEmpty]));
}

int
main(void)
{
    @autoreleasepool {
        Dl_info info;
        dladdr((const void *)CFArrayGetCount, &info);
        printf("CoreFoundation: %s\n", info.dli_fname);
        classes();
        constant_objects();
        tagged_strings();
        block_invocation();
        shared_key_sets();
    }
    return 0;
}
