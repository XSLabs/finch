/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * App extensions' request objects (docs/design/FOUNDATION.md), against the
 * SDK's <Foundation/NSExtensionItem.h> and <Foundation/NSExtensionContext.h>.
 * As Apple's, an item keeps everything in its user info: the attributed title
 * and content text as RTF data (written by the RTF support UIFoundation adds
 * to NSAttributedString, loaded when needed as Apple's Foundation does; the
 * strings themselves if it can't be), the attachments as an array. Finch doesn't host extensions yet, so a context
 * has no input items and its requests complete at once.
 */
#import <Foundation/Foundation.h>
#include <dlfcn.h>

#include "Foundation_Finch.h"

/* NSRTFTextDocumentType, NSDocumentTypeDocumentAttribute (AppKit's). */
static NSString *const RTFType = @"NSRTF";
static NSString *const DocumentType = @"DocumentType";

/* MARK: - NSExtensionItem */

@interface NSExtensionItem () {
    NSMutableDictionary *_info;
}
@end

@implementation NSExtensionItem

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)init
{
    if ((self = [super init])) _info = [[NSMutableDictionary alloc] init];
    return self;
}

- (void)dealloc
{
    [_info release];
    [super dealloc];
}

- (NSDictionary *)userInfo { return [[_info copy] autorelease]; }

- (void)setUserInfo:(NSDictionary *)userInfo
{
    [_info release];
    _info = userInfo ? [userInfo mutableCopy] : [[NSMutableDictionary alloc] init];
}

/* NSAttributedString's document reading and writing, from UIFoundation. */
static void
load_documents(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (![NSAttributedString instancesRespondToSelector:@selector(dataFromRange:documentAttributes:error:)])
            dlopen("/System/Library/PrivateFrameworks/UIFoundation.framework/UIFoundation", RTLD_LAZY | RTLD_LOCAL);
    });
}

static void
set_text(NSMutableDictionary *info, NSString *key, NSAttributedString *text)
{
    if (!text) {
        [info removeObjectForKey:key];
        return;
    }
    id value = nil;
    load_documents();
    if ([text respondsToSelector:@selector(dataFromRange:documentAttributes:error:)])
        value = [(id)text dataFromRange:NSMakeRange(0, [text length]) documentAttributes:@{ DocumentType : RTFType } error:NULL];
    [info setObject:value ?: [[text copy] autorelease] forKey:key];
}

static NSAttributedString *
text(NSDictionary *info, NSString *key)
{
    id value = [info objectForKey:key];
    if ([value isKindOfClass:[NSAttributedString class]] || !value) return value;
    if (![value isKindOfClass:[NSData class]]) return nil;
    load_documents();
    NSAttributedString *s = [NSAttributedString alloc];
    if (![s respondsToSelector:@selector(initWithData:options:documentAttributes:error:)]) return nil;
    return [[(id)s initWithData:value options:@{ DocumentType : RTFType } documentAttributes:NULL error:NULL] autorelease];
}

- (NSAttributedString *)attributedTitle { return text(_info, NSExtensionItemAttributedTitleKey); }
- (void)setAttributedTitle:(NSAttributedString *)title { set_text(_info, NSExtensionItemAttributedTitleKey, title); }
- (NSAttributedString *)attributedContentText { return text(_info, NSExtensionItemAttributedContentTextKey); }
- (void)setAttributedContentText:(NSAttributedString *)content { set_text(_info, NSExtensionItemAttributedContentTextKey, content); }

- (NSArray *)attachments { return [_info objectForKey:NSExtensionItemAttachmentsKey]; }

- (void)setAttachments:(NSArray *)attachments
{
    if (attachments) [_info setObject:[[attachments copy] autorelease] forKey:NSExtensionItemAttachmentsKey];
    else [_info removeObjectForKey:NSExtensionItemAttachmentsKey];
}

- (id)copyWithZone:(NSZone *)zone
{
    NSExtensionItem *copy = [[[self class] allocWithZone:zone] init];
    [copy setUserInfo:_info];
    return copy;
}

- (NSString *)description { return [NSString stringWithFormat:@"<%s: %p> - userInfo: %@", object_getClassName(self), self, _info]; }

- (void)encodeWithCoder:(NSCoder *)coder { [coder encodeObject:_info forKey:@"NSExtensionItemUserInfoKey"]; }

- (instancetype)initWithCoder:(NSCoder *)coder
{
    /* (as Apple's: with the classes the caller allows, not a list of its own) */
    if ((self = [self init])) {
        NSDictionary *info = [coder decodeObjectForKey:@"NSExtensionItemUserInfoKey"];
        if ([info isKindOfClass:[NSDictionary class]]) [self setUserInfo:info];
    }
    return self;
}

@end

/* MARK: - NSExtensionContext */

@implementation NSExtensionContext

- (NSArray *)inputItems { return @[]; }

- (void)completeRequestReturningItems:(NSArray *)items completionHandler:(void (^)(BOOL))completionHandler
{
    if (completionHandler) {
        completionHandler = [[completionHandler copy] autorelease];
        dispatch_async(dispatch_get_main_queue(), ^{ completionHandler(NO); });
    }
}

- (void)cancelRequestWithError:(NSError *)error
{
    if (!error) [NSException raise:NSInvalidArgumentException format:@"*** %s: error must not be nil", sel_getName(_cmd)];
}

- (void)openURL:(NSURL *)URL completionHandler:(void (^)(BOOL))completionHandler
{
    if (completionHandler) {
        completionHandler = [[completionHandler copy] autorelease];
        dispatch_async(dispatch_get_main_queue(), ^{ completionHandler(NO); });
    }
}

@end
