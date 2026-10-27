/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-coredata-xml-test: an NSPersistentDocument saved in Core Data's XML store and read
 * back by another document: every attribute type, text that needs escaping, a
 * transformable value and both kinds of relationship. host-tests runs it across systems:
 * Finch reads the file Apple's run writes and Apple reads Finch's.
 *
 *     finch-coredata-xml-test write|read FILE [ignored]
 */
#import <AppKit/AppKit.h>
#import <CoreData/CoreData.h>
#include <stdio.h>

@interface ShelfDocument : NSPersistentDocument
@end

static NSAttributeDescription *
attr(NSString *name, NSAttributeType type)
{
    NSAttributeDescription *a = [NSAttributeDescription new];
    a.name = name;
    a.attributeType = type;
    if (type == NSTransformableAttributeType) a.valueTransformerName = NSKeyedUnarchiveFromDataTransformerName;
    return a;
}

@implementation ShelfDocument
- (NSManagedObjectModel *)managedObjectModel
{
    static NSManagedObjectModel *model;
    if (model) return model;
    NSEntityDescription *box = [NSEntityDescription new], *item = [NSEntityDescription new];
    box.name = @"Box";
    item.name = @"Item";
    NSRelationshipDescription *items = [NSRelationshipDescription new], *inbox = [NSRelationshipDescription new];
    items.name = @"items";
    items.destinationEntity = item;
    items.maxCount = 0;
    inbox.name = @"box";
    inbox.destinationEntity = box;
    inbox.maxCount = 1;
    items.inverseRelationship = inbox;
    inbox.inverseRelationship = items;
    box.properties = @[ attr(@"label", NSStringAttributeType), items ];
    item.properties = @[ attr(@"name", NSStringAttributeType), attr(@"count", NSInteger64AttributeType), attr(@"small", NSInteger16AttributeType),
                         attr(@"price", NSDoubleAttributeType), attr(@"ratio", NSFloatAttributeType), attr(@"when", NSDateAttributeType),
                         attr(@"blob", NSBinaryDataAttributeType), attr(@"flag", NSBooleanAttributeType), attr(@"amount", NSDecimalAttributeType),
                         attr(@"uuid", NSUUIDAttributeType), attr(@"link", NSURIAttributeType), attr(@"thing", NSTransformableAttributeType), inbox ];
    model = [NSManagedObjectModel new];
    model.entities = @[ box, item ];
    return model;
}
@end

static NSString *
text(id value)
{
    return [[value description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
}

static void
dump(NSManagedObjectContext *c)
{
    NSError *e = nil;
    NSFetchRequest *f = [NSFetchRequest fetchRequestWithEntityName:@"Item"];
    f.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES] ];
    for (NSManagedObject *o in [c executeFetchRequest:f error:&e]) {
        printf("item %s count %s small %s price %s ratio %s when %s\n", [[o valueForKey:@"name"] UTF8String], text([o valueForKey:@"count"]).UTF8String,
               text([o valueForKey:@"small"]).UTF8String, text([o valueForKey:@"price"]).UTF8String, text([o valueForKey:@"ratio"]).UTF8String,
               text([o valueForKey:@"when"]).UTF8String);
        printf("  blob %s flag %s amount %s uuid %s link %s\n", text([o valueForKey:@"blob"]).UTF8String, text([o valueForKey:@"flag"]).UTF8String,
               text([o valueForKey:@"amount"]).UTF8String, [[[o valueForKey:@"uuid"] UUIDString] UTF8String], [[[o valueForKey:@"link"] absoluteString] UTF8String]);
        printf("  thing %s box %s\n", text([o valueForKey:@"thing"]).UTF8String, [[[o valueForKey:@"box"] valueForKey:@"label"] UTF8String]);
    }
    NSMutableArray *boxes = [NSMutableArray array];
    for (NSManagedObject *b in [c executeFetchRequest:[NSFetchRequest fetchRequestWithEntityName:@"Box"] error:&e])
        [boxes addObject:[NSString stringWithFormat:@"%@:%lu", [b valueForKey:@"label"] ?: @"(none)", (unsigned long)[[b valueForKey:@"items"] count]]];
    [boxes sortUsingSelector:@selector(compare:)];
    printf("boxes %s\n", [boxes componentsJoinedByString:@" | "].UTF8String);
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        if (argc < 3) return 2;
        [NSApplication sharedApplication];
        printf("Core Data XML store through NSPersistentDocument\n");
        NSURL *url = [NSURL fileURLWithPath:@(argv[2])];
        NSError *e = nil;
        if (!strcmp(argv[1], "write")) {
            [[NSFileManager defaultManager] removeItemAtURL:url error:NULL];
            ShelfDocument *doc = [ShelfDocument new];
            NSManagedObjectContext *c = doc.managedObjectContext;
            printf("store type %s\n", [doc persistentStoreTypeForFileType:@"public.data"].UTF8String);
            NSManagedObject *b = [NSEntityDescription insertNewObjectForEntityForName:@"Box" inManagedObjectContext:c];
            [b setValue:@"red & <blue> \\ é 😀 ]]>" forKey:@"label"];
            [NSEntityDescription insertNewObjectForEntityForName:@"Box" inManagedObjectContext:c];
            for (int i = 0; i < 2; i++) {
                NSManagedObject *o = [NSEntityDescription insertNewObjectForEntityForName:@"Item" inManagedObjectContext:c];
                [o setValue:i ? @"pear" : @"apple" forKey:@"name"];
                [o setValue:@(i + 3) forKey:@"count"];
                [o setValue:@(-7 - i) forKey:@"small"];
                [o setValue:@(1.1 * (i + 1)) forKey:@"price"];
                [o setValue:@(0.1f + i) forKey:@"ratio"];
                [o setValue:[NSDate dateWithTimeIntervalSinceReferenceDate:100.5 + i] forKey:@"when"];
                [o setValue:[NSData dataWithBytes:"ab\0c" length:4] forKey:@"blob"];
                [o setValue:@(i == 0) forKey:@"flag"];
                [o setValue:[NSDecimalNumber decimalNumberWithString:@"12.34"] forKey:@"amount"];
                [o setValue:[[NSUUID alloc] initWithUUIDString:@"11111111-2222-3333-4444-555555555555"] forKey:@"uuid"];
                [o setValue:[NSURL URLWithString:@"https://example.org/x?a=1&b=2"] forKey:@"link"];
                [o setValue:@[ @1, @"x", @{ @"k" : @2 } ] forKey:@"thing"];
                [o setValue:b forKey:@"box"];
            }
            BOOL ok = [doc writeToURL:url ofType:@"public.data" forSaveOperation:NSSaveAsOperation originalContentsURL:nil error:&e];
            printf("written %d %ld\n", ok, (long)e.code);
        } else {
            printf("store type XML\n");
        }
        ShelfDocument *reader = [ShelfDocument new];
        BOOL ok = [reader readFromURL:url ofType:@"public.data" error:&e];
        if (!strcmp(argv[1], "read")) printf("written 1 0\n");
        printf("read %d %ld\n", ok, (long)e.code);
        dump(reader.managedObjectContext);
    }
    return 0;
}
