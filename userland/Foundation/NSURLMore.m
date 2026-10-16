/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSURL construction entry points that CoreFoundation's URL class does not
 * supply. URL objects remain CFURL objects so they keep Finch's toll-free
 * bridge and class-cluster behavior.
 */
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

#include "NSURLStringEncoding_Finch.h"

static CFURLRef
create_url_from_data(NSData *data, NSURL *baseURL, BOOL absolute)
{
    if (!data)
        return NULL;
    CFURLRef url = CFURLCreateWithBytes(kCFAllocatorDefault, [data bytes], (CFIndex)[data length], kCFStringEncodingUTF8,
                                        (CFURLRef)baseURL);
    if (!url || !absolute)
        return url;
    CFURLRef result = CFURLCopyAbsoluteURL(url);
    CFRelease(url);
    return result;
}

static CFURLRef
create_url_from_string(NSString *string, NSURL *baseURL, BOOL encodeInvalidCharacters)
{
    if (!string)
        return NULL;
    NSString *value = string;
    if (encodeInvalidCharacters)
        value = FinchURLStringByEncodingInvalidCharacters(string);
    if (!value)
        return NULL;
    return CFURLCreateWithString(kCFAllocatorDefault, (CFStringRef)value, (CFURLRef)baseURL);
}

@implementation NSURL (FinchConstruction)

+ (instancetype)URLWithString:(NSString *)string
{
    return [(id)create_url_from_string(string, nil, YES) autorelease];
}

+ (instancetype)URLWithString:(NSString *)string relativeToURL:(NSURL *)baseURL
{
    return [(id)create_url_from_string(string, baseURL, YES) autorelease];
}

- (instancetype)initWithString:(NSString *)string
{
    return [self initWithString:string relativeToURL:nil];
}

- (instancetype)initWithString:(NSString *)string relativeToURL:(NSURL *)baseURL
{
    CFURLRef url = create_url_from_string(string, baseURL, YES);
    [self release];
    return (id)url;
}

- (instancetype)initWithString:(NSString *)string encodingInvalidCharacters:(BOOL)encode
{
    CFURLRef url = create_url_from_string(string, nil, encode);
    [self release];
    return (id)url;
}

- (instancetype)initWithDataRepresentation:(NSData *)data relativeToURL:(NSURL *)baseURL
{
    CFURLRef url = create_url_from_data(data, baseURL, NO);
    [self release];
    return (id)url;
}

- (instancetype)initAbsoluteURLWithDataRepresentation:(NSData *)data relativeToURL:(NSURL *)baseURL
{
    CFURLRef url = create_url_from_data(data, baseURL, YES);
    [self release];
    return (id)url;
}

+ (NSURL *)absoluteURLWithDataRepresentation:(NSData *)data relativeToURL:(NSURL *)baseURL
{
    return [(id)create_url_from_data(data, baseURL, YES) autorelease];
}

- (instancetype)initWithScheme:(NSString *)scheme host:(NSString *)host path:(NSString *)path
{
    NSURLComponents *components = [[NSURLComponents alloc] init];
    components.scheme = scheme;
    components.host = host;
    components.path = path;
    NSURL *url = [[NSURL alloc] initWithString:[components string]];
    [components release];
    [self release];
    return url;
}

+ (NSURL *)URLWithString:(NSString *)string encodingInvalidCharacters:(BOOL)encode
{
    return [[[self alloc] initWithString:string encodingInvalidCharacters:encode] autorelease];
}

@end
