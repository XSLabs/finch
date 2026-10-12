/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSString, NSAttributedString and NSURL on pasteboards (NSPasteboardWriting and
 * NSPasteboardReading, which AppKit gives them, as Apple's does), with Apple's types:
 * strings as UTF-8 plain text; attributed strings as RTF and plain text (flat RTFD
 * first when they hold attachments), read from RTFD, RTF, HTML, plain text and the
 * font and ruler styles; URLs as their URL or file-URL type.
 */
#import "AppKit_Finch.h"

static NSString *
string_from(id plist)
{
    if ([plist isKindOfClass:[NSString class]])
        return plist;
    if ([plist isKindOfClass:[NSData class]])
        return [[[NSString alloc] initWithData:plist encoding:NSUTF8StringEncoding] autorelease]
                   ?: [[[NSString alloc] initWithData:plist encoding:NSUTF16StringEncoding] autorelease];
    return nil;
}

@interface NSString (FinchPasteboard) <NSPasteboardWriting, NSPasteboardReading>
@end

@implementation NSString (FinchPasteboard)

- (NSArray<NSPasteboardType> *)writableTypesForPasteboard:(NSPasteboard *)pasteboard { return @[ NSPasteboardTypeString ]; }
- (id)pasteboardPropertyListForType:(NSPasteboardType)type { return [type isEqualToString:NSPasteboardTypeString] ? self : nil; }

+ (NSArray<NSPasteboardType> *)readableTypesForPasteboard:(NSPasteboard *)pasteboard
{
    return @[ NSPasteboardTypeString, @"public.utf16-external-plain-text" ];
}

- (id)initWithPasteboardPropertyList:(id)propertyList ofType:(NSPasteboardType)type
{
    NSString *s = string_from(propertyList);
    if (!s) {
        [self release];
        return nil;
    }
    return [self initWithString:s];
}

@end

@interface NSAttributedString (FinchPasteboard) <NSPasteboardWriting, NSPasteboardReading>
@end

@implementation NSAttributedString (FinchPasteboard)

- (BOOL)_finchHasAttachments
{
    __block BOOL found = NO;
    [self enumerateAttribute:NSAttachmentAttributeName inRange:NSMakeRange(0, [self length]) options:0
                  usingBlock:^(id value, NSRange range, BOOL *stop) {
                      if (value) {
                          found = YES;
                          *stop = YES;
                      }
                  }];
    return found;
}

- (NSArray<NSPasteboardType> *)writableTypesForPasteboard:(NSPasteboard *)pasteboard
{
    return [self _finchHasAttachments] ? @[ NSPasteboardTypeRTFD, NSPasteboardTypeRTF, NSPasteboardTypeString ]
                                       : @[ NSPasteboardTypeRTF, NSPasteboardTypeString ];
}

- (id)pasteboardPropertyListForType:(NSPasteboardType)type
{
    NSRange all = NSMakeRange(0, [self length]);
    if ([type isEqualToString:NSPasteboardTypeRTFD])
        return [self RTFDFromRange:all documentAttributes:@{}];
    if ([type isEqualToString:NSPasteboardTypeRTF])
        return [self RTFFromRange:all documentAttributes:@{}];
    if ([type isEqualToString:NSPasteboardTypeString])
        return [[[self string] copy] autorelease];
    return nil;
}

+ (NSArray<NSPasteboardType> *)readableTypesForPasteboard:(NSPasteboard *)pasteboard
{
    return @[ NSPasteboardTypeRTFD, NSPasteboardTypeRTF, NSPasteboardTypeHTML, NSPasteboardTypeString, NSPasteboardTypeFont,
              NSPasteboardTypeRuler ];
}

+ (NSPasteboardReadingOptions)readingOptionsForType:(NSPasteboardType)type pasteboard:(NSPasteboard *)pasteboard
{
    return [type isEqualToString:NSPasteboardTypeString] ? NSPasteboardReadingAsString : NSPasteboardReadingAsData;
}

- (id)initWithPasteboardPropertyList:(id)propertyList ofType:(NSPasteboardType)type
{
    NSData *data = [propertyList isKindOfClass:[NSData class]] ? propertyList : nil;
    if ([type isEqualToString:NSPasteboardTypeString]) {
        NSString *s = string_from(propertyList);
        return s ? [self initWithString:s] : ([self release], nil);
    }
    if (!data) {
        [self release];
        return nil;
    }
    if ([type isEqualToString:NSPasteboardTypeRTFD])
        return [self initWithRTFD:data documentAttributes:NULL];
    if ([type isEqualToString:NSPasteboardTypeHTML])
        return [self initWithHTML:data documentAttributes:NULL];
    /* (RTF, and the font and ruler styles, which are RTF of a character) */
    return [self initWithRTF:data documentAttributes:NULL];
}

@end

@interface NSURL (FinchPasteboard) <NSPasteboardWriting, NSPasteboardReading>
@end

@implementation NSURL (FinchPasteboard)

- (NSArray<NSPasteboardType> *)writableTypesForPasteboard:(NSPasteboard *)pasteboard
{
    return @[ [self isFileURL] ? NSPasteboardTypeFileURL : NSPasteboardTypeURL ];
}

- (id)pasteboardPropertyListForType:(NSPasteboardType)type { return [self absoluteString]; }

+ (NSArray<NSPasteboardType> *)readableTypesForPasteboard:(NSPasteboard *)pasteboard { return @[ NSPasteboardTypeFileURL, NSPasteboardTypeURL ]; }

+ (NSPasteboardReadingOptions)readingOptionsForType:(NSPasteboardType)type pasteboard:(NSPasteboard *)pasteboard
{
    return NSPasteboardReadingAsString;
}

- (id)initWithPasteboardPropertyList:(id)propertyList ofType:(NSPasteboardType)type
{
    NSString *s = string_from(propertyList);
    return s ? [self initWithString:s] : ([self release], nil);
}

@end
