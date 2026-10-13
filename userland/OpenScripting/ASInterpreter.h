/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Finch's AppleScript: a compiled script and running it. */
#import "ASParser.h"
#import "ASValues.h"

@interface ASScript : NSObject
@property (copy) NSString *source;
@property (strong) ASNode *tree;
@property (strong) NSMutableDictionary<NSString *, id> *properties; /* and globals: persist between runs */
@property (strong) NSMutableDictionary<NSString *, ASHandler *> *handlers;
@property (copy) NSString *name;                                /* a script object's name */
/* Compiles; raises ASError (-2741 and the like) on a syntax error. */
+ (instancetype)compile:(NSString *)source;
/* A script object (script Name ... end script): its handlers from a parsed body. */
+ (instancetype)scriptWithTree:(ASNode *)tree name:(NSString *)name;
@end

@interface ASInterpreter : NSObject
@property (copy) void (^logHandler)(NSString *line); /* "log" statements, in display form */
/* Runs the script's top level (its run handler), returning its result. Raises ASError. */
- (id)run:(ASScript *)script;
- (id)run:(ASScript *)script handler:(NSString *)name arguments:(NSArray *)args;
@end
