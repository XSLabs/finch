/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSAppleScript. Finch has no AppleScript language yet (Apple's is the closed
 * AppleScript component of the Open Scripting Architecture), so a script keeps its
 * source and compiling or running it fails with an error dictionary in Apple's form.
 */
#import <Foundation/Foundation.h>

@implementation NSAppleScript

- (instancetype)initWithSource:(NSString *)source
{
    if ((self = [super init]))
        _source = [source copy];
    return self;
}

- (instancetype)initWithContentsOfURL:(NSURL *)url error:(NSDictionary<NSString *, id> **)errorInfo
{
    NSString *s = [NSString stringWithContentsOfURL:url usedEncoding:NULL error:NULL];
    if (!s) {
        if (errorInfo)
            *errorInfo = @{NSAppleScriptErrorNumber : @(-43), NSAppleScriptErrorMessage : @"The file couldn’t be opened.",
                           NSAppleScriptErrorBriefMessage : @"The file couldn’t be opened."};
        [self release];
        return nil;
    }
    return [self initWithSource:s];
}

- (void)dealloc
{
    [_source release];
    [super dealloc];
}

- (NSString *)source { return _source; }
- (BOOL)isCompiled { return NO; }

static NSDictionary *
unavailable(NSString *source)
{
    NSString *m = @"AppleScript isn’t available.";
    return @{NSAppleScriptErrorNumber : @(-1761) /* errOSAComponentMismatch */, NSAppleScriptErrorMessage : m, NSAppleScriptErrorBriefMessage : m,
             NSAppleScriptErrorRange : [NSValue valueWithRange:NSMakeRange(0, source.length)]};
}

- (BOOL)compileAndReturnError:(NSDictionary<NSString *, id> **)errorInfo
{
    if (errorInfo)
        *errorInfo = unavailable(_source);
    return NO;
}

- (NSAppleEventDescriptor *)executeAndReturnError:(NSDictionary<NSString *, id> **)errorInfo
{
    if (errorInfo)
        *errorInfo = unavailable(_source);
    return nil;
}

- (NSAppleEventDescriptor *)executeAppleEvent:(NSAppleEventDescriptor *)event error:(NSDictionary<NSString *, id> **)errorInfo
{
    if (errorInfo)
        *errorInfo = unavailable(_source);
    return nil;
}

- (id)copyWithZone:(NSZone *)zone { return [[NSAppleScript alloc] initWithSource:_source]; }

@end
