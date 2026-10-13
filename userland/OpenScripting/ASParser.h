/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Finch's AppleScript: the parse tree and the parser. */
#import <Foundation/Foundation.h>

@interface ASNode : NSObject
@property (copy) NSString *kind;          /* "set", "if", "binop", "elem", ... */
@property (copy) NSString *name;          /* variable, handler, operator, element class, property */
@property (strong) id value;              /* a literal */
@property (strong) NSMutableArray<ASNode *> *children;
@property (strong) NSMutableDictionary<NSString *, id> *args; /* named parts */
@property NSRange range;                  /* in the source */
+ (instancetype)kind:(NSString *)kind;
@end

/* Parses a script; raises ASError -2741 (syntax) with the offending range. */
ASNode *ASParse(NSString *source);

/* The source, pretty-printed in AppleScript's style (compiled form). */
NSString *ASFormatSource(NSString *source);

/* AppleScript's source styles (kASSourceStyle... in AppleScript.h) */
enum {
    kASStyleUncompiled = 0, kASStyleNormal = 1, kASStyleLanguageKeyword = 2, kASStyleApplicationKeyword = 3, kASStyleComment = 4,
    kASStyleLiteral = 5, kASStyleUserSymbol = 6, kASStyleString = 7, kASStyleEventName = 8, kASStyleParameterName = 9,
    kASStyleClass = 10, kASStyleProperty = 11, kASStyleEnumValue = 12, kASStyleCount = 18
};
/* Style runs for compiled source: {location, length, style}. */
NSArray<NSArray<NSNumber *> *> *ASSourceStyleRuns(NSString *source);
