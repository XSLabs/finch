/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-foundation-edges-test: Foundation behaviour checked against Apple's on the host,
 * section by section: text-checking result classes and descriptions, presentation
 * intents' indentation, progress and collection-difference descriptions, orthographies,
 * scripting and legacy key-value coding, index-set insertion checks, XML child removal
 * and node classes, NSValue type encodings, compound NOT predicates, date-components
 * formatting, calendar differences, time zones made with data, and the descriptions of
 * scripting's object specifiers, whose tests and insertion points.
 */
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#pragma clang diagnostic ignored "-Wnonnull"

/* Every line with its addresses ("0x1234...", or "@1234..." in the reasons shown) taken out. */
static int
edges_printf(const char *format, ...)
{
    va_list ap;
    va_start(ap, format);
    char *line = NULL;
    vasprintf(&line, format, ap);
    va_end(ap);
    @autoreleasepool {
        NSMutableString *s = [NSMutableString stringWithUTF8String:line ?: ""];
        NSRegularExpression *address = [NSRegularExpression regularExpressionWithPattern:@"(0x|@)[0-9a-f]{6,}" options:0 error:NULL];
        [address replaceMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@"ADDR"];
        fputs(s.UTF8String, stdout);
    }
    free(line);
    return 0;
}
#define printf edges_printf

/* MARK: - misc */
static void P_misc(const char*l, id o){ printf("%s => %s | %s\n", l, class_getName([o class]), [[[o description] stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"] UTF8String]); }
static void
section_misc(void)
{
    printf("== misc\n");
    @autoreleasepool {
 NSRange r=NSMakeRange(1,2);
 P_misc("repl",[NSTextCheckingResult replacementCheckingResultWithRange:r replacementString:@"x"]);
 P_misc("corr",[NSTextCheckingResult correctionCheckingResultWithRange:r replacementString:@"x"]);
 P_misc("corr2",[NSTextCheckingResult correctionCheckingResultWithRange:r replacementString:@"x" alternativeStrings:@[@"y"]]);
 P_misc("dash",[NSTextCheckingResult dashCheckingResultWithRange:r replacementString:@"x"]);
 P_misc("quote",[NSTextCheckingResult quoteCheckingResultWithRange:r replacementString:@"x"]);
 P_misc("date",[NSTextCheckingResult dateCheckingResultWithRange:r date:[NSDate dateWithTimeIntervalSince1970:0] timeZone:[NSTimeZone timeZoneWithName:@"UTC"] duration:5]);
 P_misc("addr",[NSTextCheckingResult addressCheckingResultWithRange:r components:@{NSTextCheckingCityKey:@"A"}]);
 P_misc("transit",[NSTextCheckingResult transitInformationCheckingResultWithRange:r components:@{NSTextCheckingFlightKey:@"1"}]);
 P_misc("orth",[NSTextCheckingResult orthographyCheckingResultWithRange:r orthography:[NSOrthography defaultOrthographyForLanguage:@"en"]]);
 NSRange rs[2]={{0,3},{1,1}};
 P_misc("regex",[NSTextCheckingResult regularExpressionCheckingResultWithRanges:rs count:2 regularExpression:[NSRegularExpression regularExpressionWithPattern:@"a(b)" options:0 error:nil]]);
 P_misc("spell",[NSTextCheckingResult spellCheckingResultWithRange:r]);
 P_misc("gram",[NSTextCheckingResult grammarCheckingResultWithRange:r details:@[]]);
 P_misc("link",[NSTextCheckingResult linkCheckingResultWithRange:r URL:[NSURL URLWithString:@"http://a"]]);
 P_misc("phone",[NSTextCheckingResult phoneNumberCheckingResultWithRange:r phoneNumber:@"555"]);
 NSPresentationIntent *p=[NSPresentationIntent paragraphIntentWithIdentity:1 nestedInsideIntent:nil];
 NSPresentationIntent *q=[NSPresentationIntent blockQuoteIntentWithIdentity:2 nestedInsideIntent:p];
 NSPresentationIntent *c=[NSPresentationIntent listItemIntentWithIdentity:3 ordinal:4 nestedInsideIntent:q];
 P_misc("p",p); P_misc("q",q); P_misc("c",c);
 P_misc("code",[NSPresentationIntent codeBlockIntentWithIdentity:5 languageHint:@"swift" nestedInsideIntent:c]);
 P_misc("table",[NSPresentationIntent tableIntentWithIdentity:6 columnCount:2 alignments:@[@0,@1] nestedInsideIntent:nil]);
 for (id t in @[@0,@1,@-1,@5]) { NSProgress *g=[NSProgress progressWithTotalUnitCount:[t longLongValue]]; printf("progress %s: '%s' '%s' ind %d\n", [[t description] UTF8String], g.localizedDescription.UTF8String, g.localizedAdditionalDescription.UTF8String, g.indeterminate); g.completedUnitCount=1; printf("  after 1: '%s' '%s'\n", g.localizedDescription.UTF8String, g.localizedAdditionalDescription.UTF8String);}
 NSProgress *dp=[NSProgress discreteProgressWithTotalUnitCount:0]; printf("discrete0 '%s'\n", dp.localizedDescription.UTF8String);
 for (NSArray *pair in @[@[@[],@[@1,@2]], @[@[@1],@[@2,@3]], @[@[@1,@2],@[]], @[@[@1,@2],@[@1,@2]]]) P_misc("diff", [pair[1] differenceFromArray:pair[0]]);

    }
}

/* MARK: - tc */

static void
section_tc(void)
{
    printf("== tc\n");
    @autoreleasepool {
 for (NSString *n in @[@"NSReplacementCheckingResult",@"NSCorrectionCheckingResult",@"NSDashCheckingResult",@"NSQuoteCheckingResult",@"NSSubstitutionCheckingResult",@"NSDateCheckingResult",@"NSSimpleRegularExpressionCheckingResult",@"NSExtendedRegularExpressionCheckingResult",@"NSComplexRegularExpressionCheckingResult",@"NSAddressCheckingResult",@"NSSimpleOrthography",@"NSComplexOrthography"]) { Class c=NSClassFromString(n); printf("%s super %s\n", n.UTF8String, c?class_getName(class_getSuperclass(c)):"-"); }
 NSRange r=NSMakeRange(1,2);
 printf("%s\n", [[NSTextCheckingResult dateCheckingResultWithRange:r date:[NSDate dateWithTimeIntervalSince1970:0]] description].UTF8String);
 printf("%s\n", [[NSTextCheckingResult dateCheckingResultWithRange:r date:[NSDate dateWithTimeIntervalSince1970:0] timeZone:[NSTimeZone timeZoneWithName:@"UTC"] duration:0] description].UTF8String);
 NSTextCheckingResult *d=[NSTextCheckingResult dateCheckingResultWithRange:r date:nil timeZone:nil duration:3]; printf("%s\n", d.description.UTF8String);
 for (NSString *l in @[@"en",@"fr",@"ja",@"zh-Hans",@"ru"]) { NSOrthography*o=[NSOrthography defaultOrthographyForLanguage:l]; printf("%s %s | %s\n", class_getName([o class]), o.description.UTF8String, [[NSOrthography orthographyWithDominantScript:@"Latn" languageMap:@{@"Latn":@[@"en",@"fr"]}] description].UTF8String); }
 NSRange rs[3]={{0,3},{1,1},{NSNotFound,0}};
 NSRegularExpression *re=[NSRegularExpression regularExpressionWithPattern:@"a(b)(c)?" options:0 error:nil];
 for (int n=1;n<=3;n++) { id x=[NSTextCheckingResult regularExpressionCheckingResultWithRanges:rs count:n regularExpression:re]; printf("%d %s %s\n", n, class_getName([x class]), [x description].UTF8String); }
 id m=[re firstMatchInString:@"xab" options:0 range:NSMakeRange(0,3)]; printf("match %s %s\n", class_getName([m class]), [m description].UTF8String);
 NSRegularExpression *re2=[NSRegularExpression regularExpressionWithPattern:@"a" options:0 error:nil];
 m=[re2 firstMatchInString:@"xab" options:0 range:NSMakeRange(0,3)]; printf("match %s %s\n", class_getName([m class]), [m description].UTF8String);

    }
}

/* MARK: - or */
static void P_or(NSOrthography*o){ printf("%s | dom %s lang %s all %s | %s\n", o.description.UTF8String, o.dominantScript.UTF8String, o.dominantLanguage.UTF8String, [[o.allLanguages componentsJoinedByString:@","] UTF8String], [[[o.languageMap description] stringByReplacingOccurrencesOfString:@"\n" withString:@""] UTF8String]); }
static void
section_or(void)
{
    printf("== or\n");
    @autoreleasepool {
 P_or([NSOrthography orthographyWithDominantScript:@"Latn" languageMap:@{@"Latn":@[@"en"]}]);
 P_or([NSOrthography orthographyWithDominantScript:@"Latn" languageMap:@{@"Latn":@[@"en",@"fr",@"de"]}]);
 P_or([NSOrthography orthographyWithDominantScript:@"Latn" languageMap:@{@"Latn":@[@"en"],@"Cyrl":@[@"ru"]}]);
 P_or([NSOrthography orthographyWithDominantScript:@"Latn" languageMap:@{@"Latn":@[@"en",@"fr"],@"Cyrl":@[@"ru",@"uk"],@"Grek":@[@"el"]}]);
 P_or([NSOrthography orthographyWithDominantScript:@"Cyrl" languageMap:@{@"Latn":@[@"en"]}]);
 P_or([NSOrthography orthographyWithDominantScript:@"Latn" languageMap:@{}]);
 P_or([NSOrthography orthographyWithDominantScript:@"Latn" languageMap:@{@"Latn":@[]}]);
 P_or([[NSOrthography alloc] initWithDominantScript:@"Latn" languageMap:@{@"Latn":@[@"en"]}]);
 printf("%s\n", class_getName(object_getClass([NSOrthography alloc])));
 for (NSString *l in @[@"zh-Hant",@"zh",@"ko",@"ar",@"he",@"el",@"hi",@"th",@"sr",@"xx",@"und"]) P_or([NSOrthography defaultOrthographyForLanguage:l]);
 NSOrthography *a=[NSOrthography orthographyWithDominantScript:@"Latn" languageMap:@{@"Latn":@[@"en"]}];
 printf("eq %d copy %d\n", [a isEqual:[NSOrthography defaultOrthographyForLanguage:@"en"]], [a copy]==a);

    }
}

/* MARK: - ind */

static void
section_ind(void)
{
    printf("== ind\n");
    @autoreleasepool {
 NSArray *names=@[@"para",@"header",@"ol",@"ul",@"li",@"code",@"bq",@"hr",@"table"];
 NSPresentationIntent *(^make)(int, NSPresentationIntent*) = ^NSPresentationIntent*(int k, NSPresentationIntent *p){
  switch(k){case 0: return [NSPresentationIntent paragraphIntentWithIdentity:k nestedInsideIntent:p];
  case 1: return [NSPresentationIntent headerIntentWithIdentity:k level:1 nestedInsideIntent:p];
  case 2: return [NSPresentationIntent orderedListIntentWithIdentity:k nestedInsideIntent:p];
  case 3: return [NSPresentationIntent unorderedListIntentWithIdentity:k nestedInsideIntent:p];
  case 4: return [NSPresentationIntent listItemIntentWithIdentity:k ordinal:1 nestedInsideIntent:p];
  case 5: return [NSPresentationIntent codeBlockIntentWithIdentity:k languageHint:nil nestedInsideIntent:p];
  case 6: return [NSPresentationIntent blockQuoteIntentWithIdentity:k nestedInsideIntent:p];
  case 7: return [NSPresentationIntent thematicBreakIntentWithIdentity:k nestedInsideIntent:p];
  default: return [NSPresentationIntent tableIntentWithIdentity:k columnCount:1 alignments:@[@0] nestedInsideIntent:p];}};
 for (int a=0;a<9;a++) { printf("%s:%ld ", [names[a] UTF8String], (long)make(a,nil).indentationLevel); } printf("\n");
 for (int a=0;a<9;a++) { printf("%-6s", [names[a] UTF8String]); for (int b=0;b<9;b++) printf(" %ld", (long)make(b, make(a,nil)).indentationLevel); printf("\n"); }
 for (int base=0; base<9; base++) { printf("x<%s<li<para:", [names[base] UTF8String]); for (int a=0;a<9;a++) printf(" %s=%ld", [names[a] UTF8String], (long)make(a, make(base, make(4, make(0,nil)))).indentationLevel); printf("\n"); }
 for (int a=0;a<9;a++) printf("x<li<para %s=%ld\n", [names[a] UTF8String], (long)make(a, make(4, make(0,nil))).indentationLevel);
 NSPresentationIntent *x = make(4, make(3, make(4, make(2, nil))));
 printf("li<ul<li<ol: %ld\n", (long)x.indentationLevel);
 x = make(0, make(6, make(6, nil))); printf("p<bq<bq: %ld\n", (long)x.indentationLevel);

    }
}

/* MARK: - ind2 */

static void
section_ind2(void)
{
    printf("== ind2\n");
    @autoreleasepool {
 NSPresentationIntent *li=[NSPresentationIntent listItemIntentWithIdentity:1 ordinal:1 nestedInsideIntent:[NSPresentationIntent paragraphIntentWithIdentity:0 nestedInsideIntent:nil]];
 printf("hdrrow %ld row %ld cell %ld\n", (long)[NSPresentationIntent tableHeaderRowIntentWithIdentity:2 nestedInsideIntent:li].indentationLevel, (long)[NSPresentationIntent tableRowIntentWithIdentity:2 row:1 nestedInsideIntent:li].indentationLevel, (long)[NSPresentationIntent tableCellIntentWithIdentity:2 column:0 nestedInsideIntent:li].indentationLevel);
 NSPresentationIntent *bq=[NSPresentationIntent blockQuoteIntentWithIdentity:1 nestedInsideIntent:li];
 printf("li-level parent then cell: %ld\n", (long)[NSPresentationIntent listItemIntentWithIdentity:3 ordinal:1 nestedInsideIntent:[NSPresentationIntent tableCellIntentWithIdentity:2 column:0 nestedInsideIntent:bq]].indentationLevel);

    }
}

/* MARK: - skvc */
@interface Item : NSObject @property (copy) NSString *name; @property (copy) id uniqueID; @end
@implementation Item - (NSString*)description{return self.name;} @end
@interface Box : NSObject @property (strong) NSMutableArray *items; @property NSInteger age; @property (strong) NSMutableArray *things; @end
@implementation Box
- (id)valueInThingsWithName:(NSString*)n { return [@"custom-" stringByAppendingString:n]; }
- (void)insertInThings:(id)v { [_things addObject:[@"ins-" stringByAppendingString:v]]; }
- (id)valueInThingsWithUniqueID:(id)u { return @"uid-custom"; }
@end
#define T_skvc(...) @try{ id r=(__VA_ARGS__); printf("%s => %s\n", #__VA_ARGS__, [[r description] UTF8String]); }@catch(NSException*e){printf("%s: %s: %s\n", #__VA_ARGS__, e.name.UTF8String, [[e.reason stringByReplacingOccurrencesOfString:@"\n" withString:@" / "] stringByReplacingOccurrencesOfString:@"0x" withString:@"@"].UTF8String);}
static void
section_skvc(void)
{
    printf("== skvc\n");
    @autoreleasepool {
 Box *b=[Box new]; Item *a=[Item new]; a.name=@"A"; a.uniqueID=@7; Item *c=[Item new]; c.name=@"C"; c.uniqueID=@"x";
 b.items=[@[a,c] mutableCopy]; b.things=[NSMutableArray array];
 T_skvc([b valueWithName:@"C" inPropertyWithKey:@"items"]);
 T_skvc([b valueWithName:@"Z" inPropertyWithKey:@"items"]);
 T_skvc([b valueWithName:@"Q" inPropertyWithKey:@"things"]);
 T_skvc([b valueWithName:@"Q" inPropertyWithKey:@"nothing"]);
 T_skvc([b valueWithName:@"Q" inPropertyWithKey:@"age"]);
 T_skvc([b valueWithUniqueID:@7 inPropertyWithKey:@"items"]);
 T_skvc([b valueWithUniqueID:@9 inPropertyWithKey:@"items"]);
 T_skvc([b valueWithUniqueID:@9 inPropertyWithKey:@"things"]);
 T_skvc([b valueWithUniqueID:@9 inPropertyWithKey:@"nothing"]);
 T_skvc(([b insertValue:@"v" inPropertyWithKey:@"things"], b.things));
 T_skvc(([b insertValue:@"v" inPropertyWithKey:@"items"], b.items));
 T_skvc(([b insertValue:@"v" atIndex:0 inPropertyWithKey:@"items"], b.items));
 T_skvc(([b insertValue:@"w" atIndex:0 inPropertyWithKey:@"nothing"], b.items));
 T_skvc([b valueAtIndex:0 inPropertyWithKey:@"items"]);
 T_skvc([b valueAtIndex:0 inPropertyWithKey:@"nothing"]);
 T_skvc(([b removeValueAtIndex:0 fromPropertyWithKey:@"items"], b.items));
 T_skvc(([b replaceValueAtIndex:0 inPropertyWithKey:@"items" withValue:@"r"], b.items));
 T_skvc([b handleQueryWithUnboundKey:@"zip"]);
 T_skvc(([b handleTakeValue:@1 forUnboundKey:@"zip"], @"ok"));
 T_skvc(([b unableToSetNilForKey:@"age"], @"ok"));
 T_skvc(([b setValue:nil forKey:@"age"], @"ok"));
 T_skvc([b coerceValue:@"3" forKey:@"age"]);
 T_skvc([b coerceValue:@"3" forKey:@"items"]);

    }
}

/* MARK: - ins */
#define T_ins(...) @try{ __VA_ARGS__; printf("ok %s\n", [[m description] stringByReplacingOccurrencesOfString:@"\n" withString:@""].UTF8String);}@catch(NSException*e){printf("%s: %s\n", e.name.UTF8String, e.reason.UTF8String);}
static void
section_ins(void)
{
    printf("== ins\n");
    @autoreleasepool {
 NSMutableArray *m;
 NSMutableIndexSet *is=[NSMutableIndexSet indexSet]; [is addIndex:0]; [is addIndex:2]; [is addIndex:5];
 for (int base=0; base<3; base++) for (int objs=0; objs<5; objs++) {
   NSMutableArray *b=[NSMutableArray array]; for(int i=0;i<base;i++)[b addObject:@(i)];
   NSMutableArray *o=[NSMutableArray array]; for(int i=0;i<objs;i++)[o addObject:@(10+i)];
   printf("base %d objs %d: ", base, objs); m=[b mutableCopy]; T_ins([m insertObjects:o atIndexes:is]);
   printf("   replace: "); m=[b mutableCopy]; T_ins([m replaceObjectsAtIndexes:is withObjects:o]);
 }
 m=[@[@1,@2,@3,@4,@5,@6] mutableCopy]; printf("6 replace 2: "); T_ins([m replaceObjectsAtIndexes:is withObjects:@[@7,@8]]);
 m=[@[@1] mutableCopy]; printf("nil objs: "); T_ins([m insertObjects:nil atIndexes:is]);
 m=[@[@1] mutableCopy]; printf("nil set: "); T_ins([m insertObjects:@[@1] atIndexes:nil]);

    }
}

/* MARK: - xr */
#define T_xr(...) @try{ __VA_ARGS__; printf("ok %s\n", [e XMLString].UTF8String);}@catch(NSException*x){printf("%s: %s\n", x.name.UTF8String, x.reason.UTF8String);}
static void
section_xr(void)
{
    printf("== xr\n");
    @autoreleasepool {
 NSXMLElement *e=[NSXMLElement elementWithName:@"r"]; [e addChild:[NSXMLElement elementWithName:@"a"]];
 T_xr([e removeChildAtIndex:3]); T_xr([e replaceChildAtIndex:3 withNode:[NSXMLElement elementWithName:@"b"]]); T_xr([e replaceChildAtIndex:1 withNode:[NSXMLElement elementWithName:@"c"]]);
 T_xr([e removeChildAtIndex:0]); T_xr([e removeChildAtIndex:0]);
 NSXMLDocument *d=[[NSXMLDocument alloc] initWithRootElement:nil]; T_xr([d removeChildAtIndex:2]); T_xr([d replaceChildAtIndex:2 withNode:[NSXMLElement elementWithName:@"b"]]);
 for (id n in @[[NSXMLNode attributeWithName:@"a" stringValue:@"v"], [NSXMLNode namespaceWithName:@"p" stringValue:@"u"], [NSXMLNode processingInstructionWithName:@"pi" stringValue:@"x"], [NSXMLNode commentWithStringValue:@"c"], [NSXMLNode textWithStringValue:@"t"], [[NSXMLNode alloc] initWithKind:NSXMLAttributeKind], [[NSXMLNode alloc] initWithKind:NSXMLNamespaceKind], [[NSXMLNode alloc] initWithKind:NSXMLProcessingInstructionKind], [[NSXMLNode alloc] initWithKind:NSXMLTextKind], [NSXMLNode attributeWithName:@"a:b" URI:@"u" stringValue:@"v"], [NSXMLNode DTDNodeWithXMLString:@"<!ELEMENT a (b)>"]]) printf("%s super %s\n", class_getName([n class]), class_getName(class_getSuperclass([n class])));
 printf("pf %s\n", class_getName([[NSPointerFunctions pointerFunctionsWithOptions:0] class]));
 printf("pf alloc %s\n", class_getName(object_getClass([NSPointerFunctions alloc])));
 for (NSString *t in @[@"Finch",@"i",@"{x=i}",@"^v",@"[3i]",@"@",@"ii",@"",@"q",@"{",@"Z",@"*",@"#",@":",@"?",@"b3",@"(u=ic)",@"r*",@"Ai",@"jf",@"I",@"!"]) { int x=0; NSValue*v=[[NSValue alloc] initWithBytes:&x objCType:t.UTF8String]; printf("type '%s' -> %s\n", t.UTF8String, v ? v.objCType : "nil"); }

    }
}

/* MARK: - vt */

static void
section_vt(void)
{
    printf("== vt\n");
    @autoreleasepool {
 for (NSString *t in @[@"@?",@"^?",@"{x}",@"{x=}",@"{?=i}",@"[i]",@"[3]",@"D",@"@\"NSString\"",@"^{x=i}",@"{x=^{x}}",@"Vv",@"ni",@"{x=i",@"(u=i",@"[3i",@"^",@"i!",@"iZ",@"{x=\"a\"i}",@"t",@"T_vt",@"%",@"[0i]",@"{x=b3}",@"^b3",@"rr*",@"{x=?}",@"^Z"]) { int x[16]={0}; NSValue*v=[[NSValue alloc] initWithBytes:x objCType:t.UTF8String]; NSValue*w=[NSValue valueWithBytes:x objCType:t.UTF8String]; printf("'%s' -> %s / %s\n", t.UTF8String, v ? v.objCType : "nil", w? w.objCType:"nil"); }

    }
}

/* MARK: - g3 */
#define T_g3(...) @try{ id r=(__VA_ARGS__); printf("%s => %s\n", #__VA_ARGS__, [[[r description] stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"] UTF8String]); }@catch(NSException*e){printf("%s: %s: %s\n", #__VA_ARGS__, e.name.UTF8String, [[e.reason stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"] UTF8String]);}
static void
section_g3(void)
{
    printf("== g3\n");
    @autoreleasepool {
 NSPredicate *t=[NSPredicate predicateWithValue:YES], *f=[NSPredicate predicateWithFormat:@"a == 1"];
 T_g3([[NSCompoundPredicate alloc] initWithType:NSNotPredicateType subpredicates:@[]]);
 T_g3([[NSCompoundPredicate alloc] initWithType:NSNotPredicateType subpredicates:@[t]]);
 T_g3([[NSCompoundPredicate alloc] initWithType:NSNotPredicateType subpredicates:@[t,f]]);
 T_g3([[NSCompoundPredicate alloc] initWithType:NSNotPredicateType subpredicates:@[f,t,f]]);
 T_g3(@([[[NSCompoundPredicate alloc] initWithType:NSNotPredicateType subpredicates:@[t,f]] evaluateWithObject:@{@"a":@1}]));
 T_g3([[NSCompoundPredicate alloc] initWithType:NSAndPredicateType subpredicates:@[]]);
 T_g3([[NSCompoundPredicate alloc] initWithType:NSOrPredicateType subpredicates:@[]]);
 T_g3([[NSCompoundPredicate alloc] initWithType:NSAndPredicateType subpredicates:@[t]]);
 T_g3([[NSCompoundPredicate alloc] initWithType:NSOrPredicateType subpredicates:@[t,f,f]]);
 T_g3([NSCompoundPredicate notPredicateWithSubpredicate:f]);
 T_g3([[NSCompoundPredicate alloc] initWithType:(NSCompoundPredicateType)7 subpredicates:@[t]]);
 T_g3([NSPredicate predicateWithFormat:@"café ===" argumentArray:@[]]);
 NSDateComponentsFormatter *df=[NSDateComponentsFormatter new]; df.unitsStyle=NSDateComponentsFormatterUnitsStyleFull;
 for (NSNumber *n in @[@0.4,@0.5,@0.9,@1,@1.5,@42.5,@42.9,@59.6,@89.5,@3599.9,@-0.5,@-1.5]) printf("%g -> %s\n", n.doubleValue, [df stringFromTimeInterval:n.doubleValue].UTF8String);
 df.allowedUnits=NSCalendarUnitMinute|NSCalendarUnitSecond; for (NSNumber *n in @[@59.6,@89.5,@119.9]) printf("ms %g -> %s\n", n.doubleValue, [df stringFromTimeInterval:n.doubleValue].UTF8String);
 NSCalendar *c=[NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian]; c.timeZone=[NSTimeZone timeZoneWithName:@"GMT"];
 NSDate *a=[NSDate dateWithTimeIntervalSince1970:0], *b=[NSDate dateWithTimeIntervalSince1970:100000.25];
 for (NSNumber *u in @[@(NSCalendarUnitEra),@(NSCalendarUnitYear),@(NSCalendarUnitMonth),@(NSCalendarUnitDay),@(NSCalendarUnitHour),@(NSCalendarUnitMinute),@(NSCalendarUnitSecond),@(NSCalendarUnitWeekday),@(NSCalendarUnitWeekdayOrdinal),@(NSCalendarUnitQuarter),@(NSCalendarUnitWeekOfMonth),@(NSCalendarUnitWeekOfYear),@(NSCalendarUnitYearForWeekOfYear),@(NSCalendarUnitCalendar),@(NSCalendarUnitTimeZone),@(NSCalendarUnitDayOfYear)]) {
   NSDateComponents *dc=[c components:u.unsignedIntegerValue fromDate:a toDate:b options:0];
   printf("unit %lu: era %ld y %ld m %ld d %ld h %ld min %ld s %ld wd %ld wdo %ld q %ld wom %ld woy %ld yfw %ld ns %ld\n", u.unsignedLongValue, dc.era, dc.year, dc.month, dc.day, dc.hour, dc.minute, dc.second, dc.weekday, dc.weekdayOrdinal, dc.quarter, dc.weekOfMonth, dc.weekOfYear, dc.yearForWeekOfYear, dc.nanosecond);
 }
 T_g3([NSTimeZone timeZoneWithName:@"GMT" data:[@"junk" dataUsingEncoding:4]]);
 T_g3([NSTimeZone timeZoneWithName:@"America/Toronto" data:[NSData data]]);
 T_g3([NSTimeZone timeZoneWithName:@"Nowhere/X" data:[@"junk" dataUsingEncoding:4]]);
 T_g3([NSTimeZone timeZoneWithName:@"Custom" data:[NSData dataWithContentsOfFile:@"/usr/share/zoneinfo/Asia/Tokyo"]]);

    }
}

/* MARK: - specd */
#define D_specd(...) printf("%s\n", [[(__VA_ARGS__) description] UTF8String])
static void
section_specd(void)
{
    printf("== specd\n");
    @autoreleasepool {
 NSScriptClassDescription *cd=nil;
 NSPropertySpecifier *p=[[NSPropertySpecifier alloc] initWithContainerClassDescription:cd containerSpecifier:nil key:@"name"]; D_specd(p);
 NSIndexSpecifier *i=[[NSIndexSpecifier alloc] initWithContainerClassDescription:cd containerSpecifier:nil key:@"items" index:0]; D_specd(i);
 D_specd([[NSIndexSpecifier alloc] initWithContainerClassDescription:cd containerSpecifier:nil key:@"items" index:-1]);
 D_specd([[NSIndexSpecifier alloc] initWithContainerClassDescription:cd containerSpecifier:nil key:@"items" index:-3]);
 D_specd([[NSMiddleSpecifier alloc] initWithContainerClassDescription:cd containerSpecifier:nil key:@"items"]);
 D_specd([[NSRandomSpecifier alloc] initWithContainerClassDescription:cd containerSpecifier:nil key:@"items"]);
 D_specd([[NSNameSpecifier alloc] initWithContainerClassDescription:cd containerSpecifier:nil key:@"items" name:@"Bob"]);
 D_specd([[NSUniqueIDSpecifier alloc] initWithContainerClassDescription:cd containerSpecifier:nil key:@"items" uniqueID:@42]);
 D_specd([[NSUniqueIDSpecifier alloc] initWithContainerClassDescription:cd containerSpecifier:nil key:@"items" uniqueID:@"abc"]);
 NSScriptObjectSpecifier *wh=[[NSScriptObjectSpecifier alloc] initWithContainerClassDescription:cd containerSpecifier:nil key:@"items"]; D_specd(wh);
 NSIndexSpecifier *a=[[NSIndexSpecifier alloc] initWithContainerClassDescription:cd containerSpecifier:nil key:@"items" index:1];
 NSIndexSpecifier *b=[[NSIndexSpecifier alloc] initWithContainerClassDescription:cd containerSpecifier:nil key:@"items" index:4];
 D_specd([[NSRangeSpecifier alloc] initWithContainerClassDescription:cd containerSpecifier:nil key:@"items" startSpecifier:a endSpecifier:b]);
 D_specd([[NSRangeSpecifier alloc] initWithContainerClassDescription:cd containerSpecifier:nil key:@"items" startSpecifier:nil endSpecifier:b]);
 D_specd([[NSRelativeSpecifier alloc] initWithContainerClassDescription:cd containerSpecifier:nil key:@"items" relativePosition:NSRelativeAfter baseSpecifier:a]);
 D_specd([[NSRelativeSpecifier alloc] initWithContainerClassDescription:cd containerSpecifier:nil key:@"items" relativePosition:NSRelativeBefore baseSpecifier:nil]);
 NSIndexSpecifier *doc=[[NSIndexSpecifier alloc] initWithContainerClassDescription:cd containerSpecifier:nil key:@"orderedDocuments" index:0];
 NSPropertySpecifier *pp=[[NSPropertySpecifier alloc] initWithContainerClassDescription:cd containerSpecifier:doc key:@"name"]; D_specd(pp);
 NSNameSpecifier *nn=[[NSNameSpecifier alloc] initWithContainerClassDescription:cd containerSpecifier:pp key:@"words" name:@"x"]; D_specd(nn);
 NSPropertySpecifier *tested=[[NSPropertySpecifier alloc] initWithContainerClassDescription:cd containerSpecifier:nil key:@"size"]; tested.containerIsObjectBeingTested=YES; D_specd(tested);
 NSPropertySpecifier *rc=[[NSPropertySpecifier alloc] initWithContainerClassDescription:cd containerSpecifier:nil key:@"size"]; rc.containerIsRangeContainerObject=YES; D_specd(rc);
 NSPositionalSpecifier *ps=[[NSPositionalSpecifier alloc] initWithPosition:NSPositionAfter objectSpecifier:nil]; D_specd(ps);
 D_specd([[NSPositionalSpecifier alloc] initWithPosition:9 objectSpecifier:i]);
 NSSpecifierTest *t=[[NSSpecifierTest alloc] initWithObjectSpecifier:p comparisonOperator:NSEqualToComparison testObject:nil]; D_specd(t);
 D_specd([[NSSpecifierTest alloc] initWithObjectSpecifier:p comparisonOperator:NSEqualToComparison testObject:@[@1,@2]]);
 NSWhoseSpecifier *w=[[NSWhoseSpecifier alloc] initWithContainerClassDescription:cd containerSpecifier:doc key:@"items" test:t]; D_specd(w);
 D_specd([[NSWhoseSpecifier alloc] initWithContainerClassDescription:cd containerSpecifier:nil key:@"items" test:nil]);
 D_specd([[NSLogicalTest alloc] initAndTestWithTests:@[]]); D_specd([[NSLogicalTest alloc] initOrTestWithTests:@[t]]); D_specd([[NSLogicalTest alloc] initNotTestWithTest:nil]);

    }
}

/* MARK: - whose */
static void
section_whose(void)
{
    printf("== whose\n");
    @autoreleasepool {
        NSPropertySpecifier *size = [[NSPropertySpecifier alloc] initWithContainerClassDescription:nil containerSpecifier:nil key:@"size"];
        size.containerIsObjectBeingTested = YES;
        for (int op = 0; op < 10; op++)
            printf("%s\n", [[[NSSpecifierTest alloc] initWithObjectSpecifier:size comparisonOperator:op testObject:@3] description].UTF8String);
        NSSpecifierTest *big = [[NSSpecifierTest alloc] initWithObjectSpecifier:size comparisonOperator:NSGreaterThanComparison testObject:@2];
        NSSpecifierTest *same = [[NSSpecifierTest alloc] initWithObjectSpecifier:nil comparisonOperator:NSEqualToComparison testObject:nil];
        printf("nil = nil: %d, base test: %d\n", [same isTrue], [[NSScriptWhoseTest new] isTrue]);
        NSLogicalTest *and = [[NSLogicalTest alloc] initAndTestWithTests:@[ big, same ]];
        NSLogicalTest *or = [[NSLogicalTest alloc] initOrTestWithTests:@[ big, same ]];
        printf("%s\n%s\n%s\n", and.description.UTF8String, or.description.UTF8String,
            [[NSLogicalTest alloc] initNotTestWithTest:and].description.UTF8String);
        printf("empty and %d, empty or %d\n", [[[NSLogicalTest alloc] initAndTestWithTests:@[]] isTrue],
            [[[NSLogicalTest alloc] initOrTestWithTests:@[]] isTrue]);
        NSWhoseSpecifier *w = [[NSWhoseSpecifier alloc] initWithContainerClassDescription:nil containerSpecifier:nil key:@"items" test:big];
        printf("defaults: start %ld end %ld, %ld %ld\n", (long)w.startSubelementIdentifier, (long)w.endSubelementIdentifier,
            (long)w.startSubelementIndex, (long)w.endSubelementIndex);
        for (int st = 0; st < 4; st++)
            for (int en = 0; en < 5; en++)
                for (int si = -1; si <= 2; si += 3) {
                    w.startSubelementIdentifier = st;
                    w.endSubelementIdentifier = en;
                    w.startSubelementIndex = si;
                    w.endSubelementIndex = -si;
                    printf("%s\n", w.description.UTF8String);
                }
        NSScriptClassDescription *box = [[NSScriptClassDescription alloc] initWithSuiteName:@"Test" className:@"Box"
            dictionary:@{ @"AppleEventCode" : @"boxx", @"Superclass" : @"NSCoreSuite.AbstractObject",
                          @"ToManyRelationships" : @{ @"items" : @{ @"Type" : @"Item", @"AppleEventCode" : @"itms" } } }];
        NSIndexSpecifier *third = [[NSIndexSpecifier alloc] initWithContainerClassDescription:box containerSpecifier:nil key:@"items" index:2];
        for (int pos = 0; pos < 6; pos++) {
            NSPositionalSpecifier *p = [[NSPositionalSpecifier alloc] initWithPosition:pos objectSpecifier:third];
            /* (the insertion point itself needs the app's scripting suites to evaluate) */
            printf("%s position %ld same specifier %d\n", p.description.UTF8String, (long)p.position, p.objectSpecifier == third);
        }
        printf("context shared %d\n", [NSScriptExecutionContext sharedScriptExecutionContext] == [NSScriptExecutionContext sharedScriptExecutionContext]);
    }
}

/* MARK: - so */
@interface Model_so : NSObject @property NSInteger value; @property (copy) NSString *name; @end
@implementation Model_so @end
@interface Sub_so : Model_so @end
@implementation Sub_so @end
@interface Watcher_so : NSObject @property (strong) NSMutableArray *log; @end
@implementation Watcher_so - (instancetype)init{ if((self=[super init])) _log=[NSMutableArray array]; return self;}
- (void)observeValueForKeyPath:(NSString *)k ofObject:(id)o change:(NSDictionary *)c context:(void *)ctx { [_log addObject:[NSString stringWithFormat:@"%@ old=%@ new=%@ ctx=%ld kind=%@", k, c[NSKeyValueChangeOldKey]?:@"-", c[NSKeyValueChangeNewKey]?:@"-", (long)ctx, c[NSKeyValueChangeKindKey]]]; }
@end
#define T_so(...) @try{ id r=(__VA_ARGS__); printf("%s => %s\n", #__VA_ARGS__, [[[r description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "] UTF8String]); }@catch(NSException*e){printf("%s: %s: %s\n", #__VA_ARGS__, e.name.UTF8String, e.reason.UTF8String);}
static void
section_so(void)
{
    printf("== so\n");
    @autoreleasepool { 
 Watcher_so *w=[Watcher_so new], *w2=[Watcher_so new];
 NSKeyValueSharedObservers *so=[[NSKeyValueSharedObservers alloc] initWithObservableClass:[Model_so class]];
 [so addSharedObserver:w forKey:@"value" options:NSKeyValueObservingOptionNew|NSKeyValueObservingOptionOld context:(void*)7];
 [so addSharedObserver:w2 forKey:@"name" options:NSKeyValueObservingOptionInitial|NSKeyValueObservingOptionNew context:(void*)8];
 NSKeyValueSharedObserversSnapshot *snap=[so snapshot]; T_so(NSStringFromClass([snap class])); T_so(@(snap!=nil));
 Model_so *m=[Model_so new]; m.name=@"a";
 [m setSharedObservers:snap];
 m.value=3; m.name=@"b";
 T_so(w.log); T_so(w2.log);
 [so addSharedObserver:w2 forKey:@"value" options:NSKeyValueObservingOptionNew context:(void*)9];
 m.value=4; T_so(w2.log);
 NSKeyValueSharedObserversSnapshot *snap2=[so snapshot]; T_so(@(snap2==snap));
 Model_so *m2=[Model_so new]; [m2 setSharedObservers:snap2]; m2.value=5; T_so(w2.log);
 [m setSharedObservers:nil]; m.value=6; T_so(w.log);
 Sub_so *s=[Sub_so new]; T_so(([s setSharedObservers:snap], @"sub ok"));
 T_so(([[NSObject new] setSharedObservers:snap], @"wrong class ok"));
 T_so(([m2 setSharedObservers:snap], @"replace ok")); m2.value=7; T_so(w.log); T_so(w2.log);
 [m2 setSharedObservers:nil]; [s setSharedObservers:nil];
 T_so([[NSKeyValueSharedObservers alloc] initWithObservableClass:[NSString class]]);
 T_so(so);

    }
}

/* MARK: - uh */
#define T_uh(...) @try{ id r=(__VA_ARGS__); printf("%s => %s\n", #__VA_ARGS__, [[[r description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "] UTF8String]); }@catch(NSException*e){printf("%s: %s: %s\n", #__VA_ARGS__, e.name.UTF8String, e.reason.UTF8String);}
static void
section_uh(void)
{
    printf("== uh\n");
    @autoreleasepool { 
 NSURL *u=[NSURL fileURLWithPath:@"/etc/hosts"];
 T_uh(NSStringFromClass([NSURLHandle URLHandleClassForURL:u])); T_uh(@([NSURLHandle canInitWithURL:u])); T_uh([NSURLHandle cachedHandleForURL:u]);
 NSURLHandle *h=[[NSURLHandle alloc] initWithURL:u cached:NO]; T_uh(h); T_uh(@([h status])); T_uh([h failureReason]); T_uh(@([h expectedResourceDataSize]));
 T_uh(@([h availableResourceData].length)); T_uh(@([h resourceData].length)); T_uh(@([h status])); T_uh([h failureReason]); T_uh([h propertyForKey:@"x"]); T_uh(@([h writeData:[NSData data]]));
 T_uh(@([[h loadInForeground] length]));
 NSSpellServer *ss=[NSSpellServer new]; T_uh(@([ss registerLanguage:@"en" byVendor:@"Finch"])); T_uh(@([ss registerLanguage:nil byVendor:nil])); T_uh(@([ss isWordInUserDictionaries:@"qwertyzz" caseSensitive:NO])); T_uh(ss.delegate);

    }
}

/* MARK: - constant strings */
/* An NSConstantString over bytes, its ivars set by the runtime's offsets (a struct with a
   raw isa would need a signed one on arm64e). */
static NSString *
edges_constant_string(const char *bytes)
{
    Class cls = objc_getClass("NSConstantString");
    id s = class_createInstance(cls, 0);
    char *base = (char *)(__bridge void *)s;
    *(const char **)(base + ivar_getOffset(class_getInstanceVariable(cls, "bytes"))) = bytes;
    *(int *)(base + ivar_getOffset(class_getInstanceVariable(cls, "numBytes"))) = (int)strlen(bytes);
    return s;
}

static void
section_cs(void)
{
    printf("== constant strings\n");
    @autoreleasepool {
        NSString *s = edges_constant_string("hello"), *t = edges_constant_string("caf\xc3\xa9"), *z = edges_constant_string("");
        printf("%s %lu %u equal %d %d hash %d\n", s.description.UTF8String, (unsigned long)s.length, [s characterAtIndex:1],
            [s isEqual:@"hello"], [@"hello" isEqual:s], s.hash == @"hello".hash);
        printf("%s %s class %s super %s copy %s\n", s.uppercaseString.UTF8String, [s stringByAppendingString:@"!"].UTF8String,
            NSStringFromClass([s class]).UTF8String, NSStringFromClass([s superclass]).UTF8String, NSStringFromClass([[s copy] class]).UTF8String);
        printf("cafe: %lu %u %u %s raw %s\n", (unsigned long)t.length, [t characterAtIndex:3], [t characterAtIndex:4],
            t.uppercaseString.UTF8String, t.UTF8String);
        printf("empty %lu encodings %lu %lu cString %lu\n", (unsigned long)z.length, (unsigned long)s.fastestEncoding,
            (unsigned long)s.smallestEncoding, (unsigned long)[(id)s cStringLength]);
        @try {
            [s characterAtIndex:9];
        } @catch (NSException *e) {
            printf("%s: %s\n", e.name.UTF8String, e.reason.UTF8String);
        }
        printf("NSSimpleCString super %s\n", class_getName(class_getSuperclass(objc_getClass("NSSimpleCString"))));
    }
}

/* MARK: - downloads */
@interface EdgesDownload : NSObject <NSURLDownloadDelegate>
@property (strong) NSMutableArray *log;
@property (copy) NSString *dest;
@property BOOL done, overwrite;
@end
@implementation EdgesDownload
- (void)downloadDidBegin:(NSURLDownload *)d { [_log addObject:@"begin"]; }
- (NSURLRequest *)download:(NSURLDownload *)d willSendRequest:(NSURLRequest *)r redirectResponse:(NSURLResponse *)rr
{
    [_log addObject:[NSString stringWithFormat:@"willSend %@ redirect %@", r.URL.lastPathComponent, rr ? @"yes" : @"nil"]];
    return r;
}
- (void)download:(NSURLDownload *)d didReceiveResponse:(NSURLResponse *)r
{
    [_log addObject:[NSString stringWithFormat:@"response %@ %lld %@", r.MIMEType, r.expectedContentLength, r.suggestedFilename]];
}
- (void)download:(NSURLDownload *)d didReceiveDataOfLength:(NSUInteger)n { [_log addObject:[NSString stringWithFormat:@"data %lu", (unsigned long)n]]; }
- (void)download:(NSURLDownload *)d decideDestinationWithSuggestedFilename:(NSString *)f
{
    [_log addObject:[@"decide " stringByAppendingString:f]];
    if (_dest) [d setDestination:[_dest stringByAppendingPathComponent:f] allowOverwrite:_overwrite];
}
- (void)download:(NSURLDownload *)d didCreateDestination:(NSString *)p { [_log addObject:[@"created " stringByAppendingString:p.lastPathComponent]]; }
- (void)downloadDidFinish:(NSURLDownload *)d
{
    [_log addObject:@"finish"];
    _done = YES;
}
- (void)download:(NSURLDownload *)d didFailWithError:(NSError *)e
{
    [_log addObject:[NSString stringWithFormat:@"fail %@ %ld", e.domain, (long)e.code]];
    _done = YES;
}
@end

static void
edges_download(NSURL *url, NSString *dest, BOOL overwrite)
{
    EdgesDownload *d = [EdgesDownload new];
    d.log = [NSMutableArray array];
    d.dest = dest;
    d.overwrite = overwrite;
    NSURLDownload *dl = [[NSURLDownload alloc] initWithRequest:[NSURLRequest requestWithURL:url] delegate:d];
    printf("request %s deletes %d resume %s\n", dl.request.URL.lastPathComponent.UTF8String, dl.deletesFileUponFailure, dl.resumeData ? "yes" : "nil");
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:10];
    while (!d.done && [until timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    for (NSString *l in d.log) printf("  %s\n", l.UTF8String);
}

static void
section_downloads(void)
{
    printf("== downloads\n");
    @autoreleasepool {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"finch-edges-downloads"];
        [fm removeItemAtPath:dir error:NULL];
        [fm createDirectoryAtPath:[dir stringByAppendingPathComponent:@"out"] withIntermediateDirectories:YES attributes:nil error:NULL];
        NSString *source = [dir stringByAppendingPathComponent:@"notes.txt"];
        [@"twenty-one bytes here" writeToFile:source atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        NSString *out = [dir stringByAppendingPathComponent:@"out"];
        edges_download([NSURL fileURLWithPath:source], out, NO);
        edges_download([NSURL fileURLWithPath:source], out, NO);
        edges_download([NSURL fileURLWithPath:source], out, YES);
        edges_download([NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"missing.txt"]], out, NO);
        printf("files: %s\n", [[[fm contentsOfDirectoryAtPath:out error:NULL] sortedArrayUsingSelector:@selector(compare:)]
                                   componentsJoinedByString:@","].UTF8String);
        printf("can resume %d\n", [NSURLDownload canResumeDownloadDecodedWithEncodingMIMEType:@"application/gzip"]);
        [fm removeItemAtPath:dir error:NULL];
    }
}

/* MARK: - fractions, taggers, comparisons */
static void
section_more(void)
{
    printf("== more\n");
    @autoreleasepool {
        long cases[][3] = { { 10, 3, 7 }, { 3, 1, 1 }, { 7, 2, 13 }, { 100, 33, 50 }, { 9, 4, 58 }, { 1, 1, 1 }, { 6, 5, 3 } };
        for (int i = 0; i < 7; i++) {
            NSProgress *p = [NSProgress progressWithTotalUnitCount:100];
            p.completedUnitCount = 42;
            NSProgress *c = [NSProgress progressWithTotalUnitCount:cases[i][0]];
            c.completedUnitCount = cases[i][1];
            [p addChild:c withPendingUnitCount:cases[i][2]];
            printf("fraction %ld %ld %ld %a\n", cases[i][0], cases[i][1], cases[i][2], p.fractionCompleted);
        }
        @try {
            (void)[[NSProgress alloc] initWithParent:[NSProgress progressWithTotalUnitCount:1] userInfo:nil];
        } @catch (NSException *e) {
            printf("%s\n", e.reason.UTF8String);
        }
        NSLinguisticTagger *t = [[NSLinguisticTagger alloc] initWithTagSchemes:@[ NSLinguisticTagSchemeTokenType ] options:0];
        t.string = @"Hello world.";
        printf("%s", t.description.UTF8String);
        NSPresentationIntent *plain = ((id(*)(id, SEL))objc_msgSend)([NSPresentationIntent alloc], @selector(init));
        printf("%s\n", [NSPresentationIntent paragraphIntentWithIdentity:3 nestedInsideIntent:plain].description.UTF8String);
        /* (every comparison of these strings, ranges and options, as one checksum) */
        NSArray *strings = @[ @"Finch", @"", @"café", @"FINCH", @"Finch2", @"a" ];
        NSUInteger options[] = { 0, 1, 2, 8, 64, 128, 256, 512, 1024 };
        uint64_t sum = 1469598103934665603ULL;
        int count = 0;
        for (NSString *r in strings)
            for (NSString *o in strings)
                for (int k = 0; k < 9; k++)
                    for (NSUInteger loc = 0; loc <= r.length; loc++)
                        for (NSUInteger len = 0; loc + len <= r.length; len += 2) {
                            NSComparisonResult c = [r compare:o options:options[k] range:NSMakeRange(loc, len)];
                            sum = (sum ^ (uint64_t)(c + 2)) * 1099511628211ULL;
                            count++;
                        }
        printf("comparisons %d checksum %llx\n", count, (unsigned long long)sum);
    }
}

int
main(void)
{
    setvbuf(stdout, NULL, _IOLBF, 0);
        section_misc();
        section_tc();
        section_or();
        section_ind();
        section_ind2();
        section_skvc();
        section_ins();
        section_xr();
        section_vt();
        section_g3();
        section_specd();
        section_whose();
        section_so();
        section_uh();
        section_cs();
        section_downloads();
        section_more();
    return 0;
}
