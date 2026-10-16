/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Escape characters that are not valid in a URL while preserving separators
 * and already-valid percent escapes.
 */
#ifndef FINCH_NSURL_STRING_ENCODING_H
#define FINCH_NSURL_STRING_ENCODING_H

#import <Foundation/Foundation.h>

static BOOL
FinchURLHexDigit(unichar c)
{
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

static BOOL
FinchURLCharacterAllowed(unichar c)
{
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))
        return YES;
    switch (c) {
    case '-': case '.': case '_': case '~': case ':': case '/': case '?': case '#':
    case '[': case ']': case '@': case '!': case '$': case '&': case '\'': case '(': case ')':
    case '*': case '+': case ',': case ';': case '=':
        return YES;
    default:
        return NO;
    }
}

static NSString *
FinchURLStringByEncodingInvalidCharacters(NSString *string)
{
    if (!string)
        return nil;
    NSMutableString *result = [NSMutableString stringWithCapacity:[string length]];
    NSUInteger length = [string length];
    for (NSUInteger i = 0; i < length;) {
        unichar c = [string characterAtIndex:i];
        if (c == '%' && i + 2 < length && FinchURLHexDigit([string characterAtIndex:i + 1]) &&
            FinchURLHexDigit([string characterAtIndex:i + 2])) {
            [result appendString:[string substringWithRange:NSMakeRange(i, 3)]];
            i += 3;
            continue;
        }
        if (c < 0x80 && c != '%' && FinchURLCharacterAllowed(c)) {
            [result appendString:[string substringWithRange:NSMakeRange(i, 1)]];
            i++;
            continue;
        }

        NSUInteger count = 1;
        if (c >= 0xd800 && c <= 0xdbff && i + 1 < length) {
            unichar next = [string characterAtIndex:i + 1];
            if (next >= 0xdc00 && next <= 0xdfff)
                count = 2;
        }
        NSData *bytes = [[string substringWithRange:NSMakeRange(i, count)] dataUsingEncoding:NSUTF8StringEncoding
            allowLossyConversion:NO];
        if (!bytes)
            return nil;
        const UInt8 *p = [bytes bytes];
        for (NSUInteger j = 0; j < [bytes length]; j++)
            [result appendFormat:@"%%%02X", (unsigned int)p[j]];
        i += count;
    }
    return result;
}

#endif
