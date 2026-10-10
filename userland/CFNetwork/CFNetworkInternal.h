/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* What CFNetwork's parts share. */
#ifndef CFNETWORK_INTERNAL_H
#define CFNETWORK_INTERNAL_H

#include <CFNetwork/CFNetwork.h>
#include <dispatch/dispatch.h>
#include <pthread.h>
#include <sys/types.h>
#include <stdbool.h>
#include <stdint.h>

/* CoreFoundation's runtime (swift-corelibs' CFRuntime.h): CF types of our own. */
typedef struct {
    uintptr_t isa;
    _Atomic(uint64_t) info;
} CFRuntimeBase;

typedef struct {
    CFIndex version;
    const char *className;
    void (*init)(CFTypeRef);
    CFTypeRef (*copy)(CFAllocatorRef, CFTypeRef);
    void (*finalize)(CFTypeRef);
    Boolean (*equal)(CFTypeRef, CFTypeRef);
    CFHashCode (*hash)(CFTypeRef);
    CFStringRef (*copyFormattingDesc)(CFTypeRef, CFDictionaryRef);
    CFStringRef (*copyDebugDesc)(CFTypeRef);
    void (*reclaim)(CFTypeRef);
    uint32_t (*refcount)(intptr_t, CFTypeRef);
    uintptr_t requiredAlignment;
} CFRuntimeClass;

extern CFTypeID _CFRuntimeRegisterClass(const CFRuntimeClass *cls);
extern CFTypeRef _CFRuntimeCreateInstance(CFAllocatorRef allocator, CFTypeID typeID, CFIndex extraBytes,
                                          unsigned char *category);

#define CFN_REGISTER(var, cls)                                                                                    \
    static dispatch_once_t once;                                                                                  \
    dispatch_once(&once, ^{ var = _CFRuntimeRegisterClass(&cls); });                                              \
    return var

static inline void *
cfn_create(CFTypeID type, size_t size)
{
    return (void *)_CFRuntimeCreateInstance(NULL, type, (CFIndex)(size - sizeof(CFRuntimeBase)), NULL);
}

/* Exported by Apple's CFNetwork, though no header declares it. */
extern const SInt32 kCFStreamErrorHTTPConnectionLost;

/* CFHTTPMessage internals the stream and authentication use. */
CFHTTPMessageRef cfn_message_parse_response_head(const uint8_t *bytes, CFIndex length, CFIndex *consumed);
CFStringRef cfn_message_header(CFHTTPMessageRef message, const char *name);
/* "Basic <base64 of user:password>" */
CFStringRef cfn_basic_credentials(CFStringRef username, CFStringRef password);
void _CFHTTPMessageSetResponseURL(CFHTTPMessageRef response, CFURLRef url);
CFArrayRef cfn_message_copy_header_names(CFHTTPMessageRef message); /* in order */
void cfn_message_set_bodyless(CFHTTPMessageRef message);

/* A TCP connection, with TLS (OpenSSL) over it once started. */
typedef struct cfn_conn {
    int fd;
    void *ssl, *ctx; /* SSL *, SSL_CTX * */
    pthread_mutex_t lock; /* OpenSSL's state, between a reader and a writer */
} cfn_conn;
void cfn_conn_init(cfn_conn *c);
/* Resolves and connects; err is NetDB (getaddrinfo's code) or POSIX. */
bool cfn_conn_connect(cfn_conn *c, const char *host, int port, double timeout, CFStreamError *err);
/* TLS client handshake; peer is the name to verify (NULL: none), verify false skips the chain. */
bool cfn_conn_start_tls(cfn_conn *c, const char *peer, bool verify, CFStreamError *err);
ssize_t cfn_conn_read(cfn_conn *c, void *buf, size_t n);
bool cfn_conn_write(cfn_conn *c, const void *buf, size_t n);
bool cfn_conn_readable(cfn_conn *c);
void cfn_conn_close(cfn_conn *c, bool close_fd);

/* CFStreamError <-> CFError, as Apple's (_CFErrorCreateWithStreamError). */
CFErrorRef _CFErrorCreateWithStreamError(CFAllocatorRef alloc, CFStreamError *streamError);
CFStreamError _CFStreamErrorFromCFError(CFErrorRef error);
CFErrorRef cfn_error(long domain, int code);

/* "Name/version CFNetwork/x Darwin/y", as Apple's default User-Agent. */
CFStringRef _CFNetworkCopyDefaultUserAgentString(void);

/* A C string of a CFString (malloc'd), or NULL. */
char *cfn_cstring(CFStringRef s);

#endif
