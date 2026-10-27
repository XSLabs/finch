/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * What NSURLSession.m shares with the socket tasks (NSURLSessionSockets.m):
 * its connections and errors, and the task internals they finish through.
 */
#import <Foundation/Foundation.h>
#include <openssl/ssl.h>

/* An HTTP/1.1 connection: a socket, and OpenSSL over it for https. */
typedef struct {
    int fd;
    SSL *ssl;
    SSL_CTX *ctx;
    uint64_t bytesWritten;
} Connection;

__attribute__((visibility("hidden"))) NSInteger conn_open(Connection *c, NSURL *url, NSTimeInterval timeout);
__attribute__((visibility("hidden"))) ssize_t conn_read(Connection *c, void *buf, size_t n);
__attribute__((visibility("hidden"))) BOOL conn_write(Connection *c, const void *buf, size_t n);
__attribute__((visibility("hidden"))) void conn_close(Connection *c);
__attribute__((visibility("hidden"))) NSError *url_error(NSInteger code, NSURL *url, NSString *description);

/* conn_open for a task: an https connection's server trust goes to the task's
   delegate as for its other loads. 0, or the NSURLError code. */
__attribute__((visibility("hidden"))) NSInteger _FinchURLTaskConnect(NSURLSessionTask *task, Connection *c, NSURL *url,
    NSTimeInterval timeout);
/* TLS over a connection already open (a stream task's -startSecureConnection). */
__attribute__((visibility("hidden"))) NSInteger _FinchURLTaskStartTLS(NSURLSessionTask *task, Connection *c, NSString *host);

@interface NSURLSessionTask (FinchInternal)
- (instancetype)_finchInitWithSession:(NSURLSession *)session request:(NSURLRequest *)request identifier:(NSUInteger)ident
                             download:(BOOL)download
                           completion:(void (^)(id result, NSURLResponse *response, NSError *error))completion;
- (NSURLSession *)_finchSession;
- (void)_finchSetResponse:(NSURLResponse *)response;
- (BOOL)_finchStartRunning;
/* Completed: the delegate hears -URLSession:task:didCompleteWithError: unless quietly. */
- (void)_finchFinishWithResult:(id)result response:(NSURLResponse *)response error:(NSError *)error;
- (void)_finchFinishQuietly;
@end

@interface NSURLSession (FinchInternal)
- (id)_finchTask:(Class)cls request:(NSURLRequest *)request download:(BOOL)download completion:(id)completion;
@end
