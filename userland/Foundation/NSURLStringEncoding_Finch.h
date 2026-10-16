/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Escape characters that are not valid in a URL while preserving separators
 * and already-valid percent escapes. As Apple's (macOS 14 and later), the host
 * and port aren't escaped: a host or port with an invalid character makes the
 * whole string invalid (nil), and a non-ASCII host is converted to its ASCII
 * (IDNA/punycode) form.
 */
#ifndef FINCH_NSURL_STRING_ENCODING_H
#define FINCH_NSURL_STRING_ENCODING_H

#import <Foundation/Foundation.h>
#include <unicode/uidna.h>

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

/* A host's own characters: letters, digits and RFC 3986's unreserved, sub-delims and
   percent escapes ([...] literals are checked as they are). */
static BOOL
FinchURLHostCharacterAllowed(unichar c)
{
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))
        return YES;
    switch (c) {
    case '-': case '.': case '_': case '~': case '!': case '$': case '&': case '\'': case '(':
    case ')': case '*': case '+': case ',': case ';': case '=': case '%':
        return YES;
    default:
        return NO;
    }
}

/* A non-ASCII host in its ASCII form (UTS #46), or nil if it has none. */
static NSString *
FinchURLASCIIHost(NSString *host)
{
    UErrorCode status = U_ZERO_ERROR;
    UIDNA *idna = uidna_openUTS46(UIDNA_CHECK_BIDI | UIDNA_NONTRANSITIONAL_TO_ASCII, &status);
    if (U_FAILURE(status))
        return nil;
    NSUInteger length = [host length];
    unichar *source = malloc((length ? length : 1) * sizeof(unichar)), dest[1024];
    [host getCharacters:source range:NSMakeRange(0, length)];
    UIDNAInfo info = UIDNA_INFO_INITIALIZER;
    int32_t written = uidna_nameToASCII(idna, source, (int32_t)length, dest, 1024, &info, &status);
    free(source);
    uidna_close(idna);
    if (U_FAILURE(status) || info.errors)
        return nil;
    return [NSString stringWithCharacters:dest length:(NSUInteger)written];
}

/* The string with its authority's host and port checked, and a non-ASCII host converted;
   nil if either is invalid. Strings without an authority come back unchanged. */
static NSString *
FinchURLStringCheckingHost(NSString *string)
{
    NSRange scheme = [string rangeOfString:@"://"];
    if (scheme.location == NSNotFound || scheme.location == 0)
        return string;
    for (NSUInteger i = 0; i < scheme.location; i++) {
        unichar c = [string characterAtIndex:i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (i && ((c >= '0' && c <= '9') || c == '+' || c == '-' || c == '.'))))
            return string;
    }
    NSUInteger start = NSMaxRange(scheme), end = start, length = [string length];
    while (end < length) {
        unichar c = [string characterAtIndex:end];
        if (c == '/' || c == '?' || c == '#')
            break;
        end++;
    }
    NSString *authority = [string substringWithRange:NSMakeRange(start, end - start)];
    NSRange at = [authority rangeOfString:@"@" options:NSBackwardsSearch];
    NSUInteger hostStart = at.location == NSNotFound ? 0 : NSMaxRange(at);
    NSString *hostPort = [authority substringFromIndex:hostStart];
    NSString *host = hostPort, *port = nil;
    if ([hostPort hasPrefix:@"["]) {
        NSRange close = [hostPort rangeOfString:@"]"];
        if (close.location == NSNotFound)
            return nil;
        host = [hostPort substringToIndex:NSMaxRange(close)];
        NSString *rest = [hostPort substringFromIndex:NSMaxRange(close)];
        if ([rest length] && ![rest hasPrefix:@":"])
            return nil;
        port = [rest length] ? [rest substringFromIndex:1] : nil;
    } else {
        NSRange colon = [hostPort rangeOfString:@":" options:NSBackwardsSearch];
        if (colon.location != NSNotFound) {
            host = [hostPort substringToIndex:colon.location];
            port = [hostPort substringFromIndex:NSMaxRange(colon)];
        }
        BOOL ascii = YES;
        for (NSUInteger i = 0; i < [host length]; i++) {
            unichar c = [host characterAtIndex:i];
            if (c >= 0x80)
                ascii = NO;
            else if (!FinchURLHostCharacterAllowed(c))
                return nil;
        }
        if (!ascii) {
            host = FinchURLASCIIHost(host);
            if (!host)
                return nil;
        }
    }
    for (NSUInteger i = 0; i < [port length]; i++) {
        unichar c = [port characterAtIndex:i];
        if (c < '0' || c > '9')
            return nil;
    }
    NSString *rebuilt = [NSString stringWithFormat:@"%@%@%@%@", [authority substringToIndex:hostStart], host,
                                                   port ? @":" : @"", port ?: @""];
    return [NSString stringWithFormat:@"%@%@%@", [string substringToIndex:start], rebuilt, [string substringFromIndex:end]];
}

static NSString *
FinchURLStringByEncodingInvalidCharacters(NSString *string)
{
    if (!string)
        return nil;
    string = FinchURLStringCheckingHost(string);
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
