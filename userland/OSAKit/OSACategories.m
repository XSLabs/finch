/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * OSAKit: what it adds to Foundation and AppKit classes, which Script Editor calls: text
 * views' contents set and appended, line endings standardized, HFS paths, outline
 * selections and reveals, split view divider positions, dates compared.
 */
#import "OSAKit_Finch.h"

@implementation NSAttributedString (OSAKit)
+ (NSAttributedString *)_osa_attributedReturnString { return [[NSAttributedString alloc] initWithString:@"\n"]; }
+ (NSAttributedString *)_osa_attributedTabString { return [[NSAttributedString alloc] initWithString:@"\t"]; }
@end

@implementation NSDate (OSAKit)
- (BOOL)_osa_isEarlierDate:(NSDate *)d { return [self compare:d] == NSOrderedAscending; }
- (BOOL)_osa_isLaterDate:(NSDate *)d { return [self compare:d] == NSOrderedDescending; }
@end

@implementation NSImage (OSAKit)
+ (NSImage *)_osa_imageNamed:(NSString *)name inBundleWithIdentifier:(NSString *)identifier
{
    NSBundle *b = [NSBundle bundleWithIdentifier:identifier];
    return [b imageForResource:name] ?: [NSImage imageNamed:name];
}
@end

static void
standardize(NSMutableString *s, NSString *eol)
{
    NSString *t = [[s stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    t = [[t stringByReplacingOccurrencesOfString:@" " withString:@"\n"] stringByReplacingOccurrencesOfString:@" " withString:@"\n"];
    if (![eol isEqualToString:@"\n"])
        t = [t stringByReplacingOccurrencesOfString:@"\n" withString:eol];
    [s setString:t];
}

@implementation NSMutableString (OSAKit)
- (void)_osa_standardizeEndOfLineToCR { standardize(self, @"\r"); }
- (void)_osa_standardizeEndOfLineToCRLF { standardize(self, @"\r\n"); }
- (void)_osa_standardizeEndOfLineToLF { standardize(self, @"\n"); }
- (void)_osa_standardizeEndOfLineToLineSeparator { standardize(self, @" "); }
- (void)_osa_standardizeEndOfLineToParagraphSeparator { standardize(self, @" "); }
@end

@implementation NSOutlineView (OSAKit)
- (void)_osa_revealItem:(id)item
{
    NSMutableArray *chain = [NSMutableArray array];
    for (id p = [self parentForItem:item]; p; p = [self parentForItem:p])
        [chain insertObject:p atIndex:0];
    for (id p in chain)
        [self expandItem:p];
    NSInteger row = [self rowForItem:item];
    if (row >= 0)
        [self scrollRowToVisible:row];
}

- (NSArray *)_osa_selectedItems
{
    NSMutableArray *a = [NSMutableArray array];
    [self.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
        id item = [self itemAtRow:(NSInteger)i];
        if (item)
            [a addObject:item];
    }];
    return a;
}
@end

@implementation NSSplitView (OSAKit)
- (CGFloat)_osa_positionOfDivider:(NSInteger)index
{
    NSArray *views = self.arrangedSubviews.count ? self.arrangedSubviews : self.subviews;
    if (index < 0 || (NSUInteger)index >= views.count)
        return 0;
    NSRect f = [views[(NSUInteger)index] frame];
    return self.isVertical ? NSMaxX(f) : NSMaxY(f);
}

- (void)_osa_setPosition:(CGFloat)position ofDivider:(NSInteger)index { [self setPosition:position ofDividerAtIndex:index]; }
@end

/* "Macintosh HD:Users:...": the volume's name, then the path with colons */
static NSString *
hfs_path(NSString *posix)
{
    if (!posix.length)
        return nil;
    NSString *volume = @"Macintosh HD";
    NSArray *parts = posix.pathComponents;
    NSMutableArray *out = [NSMutableArray arrayWithObject:volume];
    NSUInteger i = 1;
    if (parts.count > 2 && [parts[1] isEqualToString:@"Volumes"]) {
        out[0] = parts[2];
        i = 3;
    }
    for (; i < parts.count; i++)
        [out addObject:[parts[i] stringByReplacingOccurrencesOfString:@":" withString:@"/"]];
    NSString *s = [out componentsJoinedByString:@":"];
    BOOL dir = NO;
    if (out.count == 1 || ([[NSFileManager defaultManager] fileExistsAtPath:posix isDirectory:&dir] && dir))
        s = [s stringByAppendingString:@":"];
    return s;
}

@implementation NSString (OSAKit)
- (NSString *)_osa_hfsPath { return hfs_path(self); }

/* "script bundle" -> "ScriptBundle" (a class) or "scriptBundle" */
- (NSString *)camelCaseForClass:(BOOL)forClass
{
    NSMutableString *out = [NSMutableString string];
    BOOL up = forClass;
    for (NSString *w in [self componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]) {
        if (!w.length)
            continue;
        [out appendString:up ? [[w substringToIndex:1].uppercaseString stringByAppendingString:[w substringFromIndex:1]] : w];
        up = YES;
    }
    return out;
}

- (NSString *)stringByReplacingCharactersInSet:(NSCharacterSet *)set withString:(NSString *)replacement
{
    return [[self componentsSeparatedByCharactersInSet:set] componentsJoinedByString:replacement ?: @""];
}
@end

@implementation NSURL (OSAKit)
- (NSString *)_osa_hfsPath { return self.isFileURL ? hfs_path(self.path) : nil; }
@end

@implementation NSTextView (OSAKit)
- (void)_osa_setContentsToAttributedString:(NSAttributedString *)s
{
    [self.textStorage setAttributedString:s ?: [NSAttributedString new]];
    [self setSelectedRange:NSMakeRange(self.textStorage.length, 0)];
}

- (void)_osa_setContentsToString:(NSString *)s
{
    NSDictionary *attrs = self.typingAttributes ?: @{};
    [self _osa_setContentsToAttributedString:[[NSAttributedString alloc] initWithString:s ?: @"" attributes:attrs]];
}

- (void)_osa_appendAttributedStringToContents:(NSAttributedString *)s
{
    if (!s.length)
        return;
    [self.textStorage appendAttributedString:s];
    [self scrollRangeToVisible:NSMakeRange(self.textStorage.length, 0)];
}

- (void)_osa_appendStringToContents:(NSString *)s
{
    [self _osa_appendAttributedStringToContents:[[NSAttributedString alloc] initWithString:s ?: @"" attributes:self.typingAttributes ?: @{}]];
}
@end
