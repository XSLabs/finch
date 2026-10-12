/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* NSItemProvider's UTType methods (NSItemProvider+UTType.h), over Foundation's
   identifier-based ones. */
#import <Foundation/Foundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

/* (the initializer below goes through Foundation's own, which the compiler can't see) */
#pragma clang diagnostic ignored "-Wobjc-designated-initializers"

@interface NSItemProvider (FinchUTTypeInit)
- (instancetype)_finchInitWithContentsOfURL:(NSURL *)fileURL type:(NSString *)type openInPlace:(BOOL)openInPlace
                                 coordinated:(BOOL)coordinated visibility:(NSItemProviderRepresentationVisibility)visibility;
@end

static NSArray<UTType *> *
content_types(NSArray<NSString *> *identifiers)
{
    NSMutableArray *types = [NSMutableArray array];
    for (NSString *identifier in identifiers) {
        UTType *t = [UTType typeWithIdentifier:identifier];
        if (t)
            [types addObject:t];
    }
    return types;
}

@implementation NSItemProvider (UTType)

/* (the file's name becomes the suggested name, as Apple's does) */
- (instancetype)initWithContentsOfURL:(NSURL *)fileURL contentType:(UTType *)contentType openInPlace:(BOOL)openInPlace
                          coordinated:(BOOL)coordinated visibility:(NSItemProviderRepresentationVisibility)visibility
{
    if ((self = [self _finchInitWithContentsOfURL:fileURL type:contentType.identifier openInPlace:openInPlace
                                       coordinated:coordinated || openInPlace visibility:visibility]))
        self.suggestedName = fileURL.lastPathComponent.stringByDeletingPathExtension;
    return self;
}

- (void)registerDataRepresentationForContentType:(UTType *)contentType visibility:(NSItemProviderRepresentationVisibility)visibility
                                     loadHandler:(NSProgress *_Nullable (^)(void (^)(NSData *, NSError *)))loadHandler
{
    [self registerDataRepresentationForTypeIdentifier:contentType.identifier visibility:visibility loadHandler:loadHandler];
}

- (void)registerFileRepresentationForContentType:(UTType *)contentType visibility:(NSItemProviderRepresentationVisibility)visibility
                                     openInPlace:(BOOL)openInPlace
                                     loadHandler:(NSProgress *_Nullable (^)(void (^)(NSURL *, BOOL, NSError *)))loadHandler
{
    [self registerFileRepresentationForTypeIdentifier:contentType.identifier
                                          fileOptions:openInPlace ? NSItemProviderFileOptionOpenInPlace : 0
                                           visibility:visibility
                                          loadHandler:loadHandler];
}

- (NSArray<UTType *> *)registeredContentTypes
{
    return content_types(self.registeredTypeIdentifiers);
}

- (NSArray<UTType *> *)registeredContentTypesForOpenInPlace
{
    return content_types([self registeredTypeIdentifiersWithFileOptions:NSItemProviderFileOptionOpenInPlace]);
}

- (NSArray<UTType *> *)registeredContentTypesConformingToContentType:(UTType *)contentType
{
    NSMutableArray *types = [NSMutableArray array];
    for (UTType *t in self.registeredContentTypes)
        if ([t conformsToType:contentType])
            [types addObject:t];
    return types;
}

- (NSProgress *)loadDataRepresentationForContentType:(UTType *)contentType
                                   completionHandler:(void (^)(NSData *, NSError *))completionHandler
{
    return [self loadDataRepresentationForTypeIdentifier:contentType.identifier completionHandler:completionHandler];
}

- (NSProgress *)loadFileRepresentationForContentType:(UTType *)contentType openInPlace:(BOOL)openInPlace
                                   completionHandler:(void (^)(NSURL *, BOOL, NSError *))completionHandler
{
    if (openInPlace)
        return [self loadInPlaceFileRepresentationForTypeIdentifier:contentType.identifier completionHandler:completionHandler];
    void (^completion)(NSURL *, BOOL, NSError *) = [[completionHandler copy] autorelease];
    return [self loadFileRepresentationForTypeIdentifier:contentType.identifier
                                       completionHandler:^(NSURL *url, NSError *error) {
                                         completion(url, NO, error);
                                       }];
}

@end
