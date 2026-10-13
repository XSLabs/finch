/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Finch's AppleScript: values. A value is an Objective-C object:
 *   integer  NSNumber (long long)        real     NSNumber (double)
 *   boolean  the CFBoolean NSNumbers     text     NSString
 *   list     ASList (shared by reference, as AppleScript's lists are)
 *   record   ASRecord (ordered keys)     date     NSDate
 *   missing value, constants and classes  ASConstant
 *   file and alias                       ASFile
 *   application                          ASApplication
 *   a script's handler                   ASHandler
 */
#import <Foundation/Foundation.h>

/* An AppleScript error: number, message, partial result, offending object. */
@interface ASError : NSException
@property NSInteger number;
@property (strong) id partialResult, offendingObject;
@property (strong) NSString *expectedType;
@property NSRange range; /* in the source: where it happened (hasRange) */
@property BOOL hasRange;
+ (instancetype)errorWithNumber:(NSInteger)number message:(NSString *)message;
@end

@interface ASList : NSObject <NSFastEnumeration>
@property (strong) NSMutableArray *items;
+ (instancetype)listWithArray:(NSArray *)a;
- (NSUInteger)count;
- (id)objectAtIndex:(NSUInteger)i;
@end

@interface ASRecord : NSObject
@property (strong) NSMutableArray *keys;   /* in order */
@property (strong) NSMutableDictionary *values;
- (void)setValue:(id)v forField:(NSString *)k;
- (id)valueForField:(NSString *)k;
@end

/* missing value, true/false-like keywords, classes (integer, text, ...), months, weekdays, ... */
@interface ASConstant : NSObject
@property (copy) NSString *name;
@property BOOL isClass;
+ (instancetype)constant:(NSString *)name;
+ (instancetype)classNamed:(NSString *)name;
+ (instancetype)missingValue;
@end

@interface ASFile : NSObject
@property (copy) NSString *path; /* POSIX */
@property BOOL isAlias;
@end

@interface ASApplication : NSObject
@property (copy) NSString *name;
@end

@class ASNode;
@interface ASHandler : NSObject
@property (copy) NSString *name;
@property (strong) NSArray<NSString *> *parameters;
@property (strong) ASNode *body;
@end

/* kinds */
BOOL ASIsBoolean(id v);
BOOL ASIsInteger(id v);
BOOL ASIsReal(id v);
BOOL ASIsNumber(id v);
NSString *ASClassName(id v);

/* coercions (raise ASError -1700 when they can't) */
NSString *ASText(id v);
id ASNumberValue(id v);           /* integer or real */
long long ASInteger(id v);
double ASReal(id v);
BOOL ASBool(id v);
/* true or false, as AppleScript booleans (the CFBoolean singletons) */
static inline id ASBoolean(BOOL b) { return (__bridge id)(b ? kCFBooleanTrue : kCFBooleanFalse); }
ASList *ASListValue(id v);
id ASCoerce(id v, NSString *className);

/* integers as AppleScript makes them: a real when outside its range */
id ASMakeInteger(long long n);
id ASMakeReal(double d);

/* display: AppleScript's source form ("abc", {1, 2}, 1.0E+4, date "...") */
NSString *ASDisplay(id v);
/* text form for "as text" and display dialog (no quotes) */
NSString *ASFormatReal(double d);

/* comparison and equality, AppleScript's way (text ignoring case) */
BOOL ASEqual(id a, id b);
NSComparisonResult ASCompare(id a, id b);
id ASDeepCopy(id v);

/* the text item delimiters */
extern NSArray *ASTextItemDelimiters;
extern BOOL ASConsiderCase; /* inside considering case */
NSString *ASHFSPath(NSString *posix);
