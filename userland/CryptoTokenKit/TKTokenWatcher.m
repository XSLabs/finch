// SPDX-License-Identifier: MIT OR Apache-2.0
#import <CryptoTokenKit/CryptoTokenKit.h>
#import <dispatch/dispatch.h>
#import <Block.h>
#import <objc/runtime.h>

static char TKWatcherHandlersKey;
static char TKWatcherInsertionHandlerKey;

@implementation TKTokenWatcher

- (instancetype)init
{
    self = [super init];
    if (self) objc_setAssociatedObject(self, &TKWatcherHandlersKey,
        [NSMutableDictionary dictionary], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return self;
}

- (instancetype)initWithInsertionHandler:(void (^)(NSString *))insertionHandler
{
    self = [self init];
    if (self) [self setInsertionHandler:insertionHandler];
    return self;
}

- (NSArray<NSString *> *)tokenIDs { return [NSArray array]; }

- (void)setInsertionHandler:(void (^)(NSString *))insertionHandler
{
    objc_setAssociatedObject(self, &TKWatcherInsertionHandlerKey, insertionHandler,
        OBJC_ASSOCIATION_COPY_NONATOMIC);
}

- (NSMutableDictionary *)_removalHandlers
{
    NSMutableDictionary *handlers = objc_getAssociatedObject(self, &TKWatcherHandlersKey);
    if (!handlers) {
        handlers = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(self, &TKWatcherHandlersKey, handlers, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        handlers = objc_getAssociatedObject(self, &TKWatcherHandlersKey);
    }
    return handlers;
}

- (void)addRemovalHandler:(void (^)(NSString *))handler forTokenID:(NSString *)tokenID
{
    if (![tokenID isKindOfClass:[NSString class]] || tokenID.length == 0)
        [NSException raise:NSInvalidArgumentException format:@"A token identifier is required"];
    if (handler) {
        void (^copied)(NSString *) = Block_copy(handler);
        @synchronized(self) { [[self _removalHandlers] setObject:copied forKey:tokenID]; }
        Block_release(copied);
        handler(tokenID);
    }
}

- (TKTokenWatcherTokenInfo *)tokenInfoForTokenID:(NSString *)tokenID
{
    (void)tokenID;
    return nil;
}

@end
