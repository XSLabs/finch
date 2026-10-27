/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-coredata-hash-test: version hashes of properties, attributes,
 * relationships, derived and composite attributes, entities (with inheritance
 * and uniqueness constraints) and models, and a store's version checksum
 * (diff Apple's and Finch's).
 */
#import <CoreData/CoreData.h>
#include <stdio.h>

static NSString *
hex(NSData *d)
{
    NSMutableString *s = [NSMutableString string];
    const unsigned char *b = d.bytes;
    for (NSUInteger i = 0; i < d.length; i++) [s appendFormat:@"%02x", b[i]];
    return s;
}

static NSAttributeDescription *
attr(NSString *name, NSAttributeType type)
{
    NSAttributeDescription *a = [NSAttributeDescription new];
    a.name = name;
    a.attributeType = type;
    return a;
}

#define SHOW(label, object) printf("%-22s %s\n", label, hex([object versionHash]).UTF8String)

int
main(void)
{
    @autoreleasepool {
        NSAttributeDescription *a = attr(@"a", NSStringAttributeType);
        SHOW("attribute", a);
        a.optional = NO;
        SHOW("required", a);
        a = attr(@"a", NSStringAttributeType);
        a.transient = YES;
        SHOW("transient", a);
        SHOW("int16", attr(@"a", NSInteger16AttributeType));
        SHOW("date", attr(@"when", NSDateAttributeType));
        a = attr(@"a", NSStringAttributeType);
        a.versionHashModifier = @"m";
        SHOW("modifier", a);
        a = attr(@"a", NSStringAttributeType);
        a.defaultValue = @"x";
        a.userInfo = @{ @"k" : @"v" };
        a.renamingIdentifier = @"old";
        SHOW("unhashed fields", a);
        a = attr(@"blob", NSBinaryDataAttributeType);
        a.allowsExternalBinaryDataStorage = YES;
        SHOW("external", a);
        a = attr(@"a", NSStringAttributeType);
        a.preservesValueInHistoryOnDeletion = YES;
        SHOW("history", a);
        SHOW("empty attribute", [NSAttributeDescription new]);

        NSEntityDescription *A = [NSEntityDescription new], *B = [NSEntityDescription new];
        A.name = @"A";
        B.name = @"B";
        NSRelationshipDescription *r = [NSRelationshipDescription new];
        r.name = @"r";
        SHOW("relationship", r);
        r.destinationEntity = B;
        r.minCount = 2;
        r.maxCount = 5;
        SHOW("counts", r);
        r.ordered = YES;
        r.deleteRule = NSCascadeDeleteRule;
        SHOW("ordered", r);
        NSRelationshipDescription *back = [NSRelationshipDescription new];
        back.name = @"back";
        back.destinationEntity = A;
        back.maxCount = 1;
        r.inverseRelationship = back;
        back.inverseRelationship = r;
        A.properties = @[ r, attr(@"title", NSStringAttributeType), attr(@"count", NSInteger64AttributeType) ];
        B.properties = @[ back ];
        SHOW("inverse", r);
        SHOW("back", back);
        SHOW("entity A", A);
        SHOW("entity B", B);

        NSEntityDescription *C = [NSEntityDescription new];
        C.name = @"C";
        C.abstract = YES;
        C.versionHashModifier = @"v2";
        SHOW("abstract modifier", C);
        NSEntityDescription *P = [NSEntityDescription new], *S = [NSEntityDescription new];
        P.name = @"P";
        S.name = @"S";
        P.properties = @[ attr(@"shared", NSStringAttributeType) ];
        S.properties = @[ attr(@"own", NSDoubleAttributeType) ];
        P.subentities = @[ S ];
        SHOW("parent", P);
        SHOW("subentity", S);
        NSEntityDescription *U = [NSEntityDescription new];
        U.name = @"U";
        U.properties = @[ attr(@"x", NSStringAttributeType), attr(@"y", NSStringAttributeType) ];
        U.uniquenessConstraints = @[ @[ @"x", @"y" ], @[ @"x" ] ];
        SHOW("unique", U);
        NSEntityDescription *T = [NSEntityDescription new];
        T.name = @"T";
        NSAttributeDescription *gone = attr(@"scratch", NSStringAttributeType);
        gone.transient = YES;
        T.properties = @[ attr(@"kept", NSStringAttributeType), gone ];
        SHOW("transient skipped", T);

        NSDerivedAttributeDescription *d = [NSDerivedAttributeDescription new];
        d.name = @"lower";
        d.attributeType = NSStringAttributeType;
        d.derivationExpression = [NSExpression expressionWithFormat:@"lowercase:(title)"];
        SHOW("derived", d);
        NSCompositeAttributeDescription *comp = [NSCompositeAttributeDescription new];
        comp.name = @"where";
        comp.elements = @[ attr(@"lon", NSDoubleAttributeType), attr(@"lat", NSDoubleAttributeType) ];
        SHOW("composite", comp);

        NSManagedObjectModel *m = [NSManagedObjectModel new];
        m.entities = @[ B, A, C, P, S, U ];
        NSPersistentStoreCoordinator *psc = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:m];
        printf("%-22s %s\n", "model checksum", m.versionChecksum.UTF8String);
        NSMutableArray *names = [NSMutableArray array];
        for (NSString *name in [m.entityVersionHashesByName.allKeys sortedArrayUsingSelector:@selector(compare:)])
            [names addObject:[NSString stringWithFormat:@"%@=%@", name, [hex(m.entityVersionHashesByName[name]) substringToIndex:8]]];
        printf("%-22s %s\n", "entity hashes", [names componentsJoinedByString:@" "].UTF8String);
        NSError *error = nil;
        NSPersistentStore *store = [psc addPersistentStoreWithType:NSInMemoryStoreType configuration:nil URL:nil options:nil error:&error];
        printf("%-22s %s\n", "store checksum", [store.metadata[@"NSStoreModelVersionChecksumKey"] UTF8String]);
        printf("%-22s %d\n", "store compatible", [m isConfiguration:nil compatibleWithStoreMetadata:store.metadata]);
    }
    return 0;
}
