// SPDX-License-Identifier: MIT OR Apache-2.0
// The C globals Network's header macros name (the C API itself is CAPI*.swift), opaque
// TLS values for the protocol-options API, and DNS-SD glue for the Swift browsers.
#import <Foundation/Foundation.h>
#import <Network/Network.h>
#import <Security/Security.h>
#import <dns_sd.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <stdbool.h>
#import <stdlib.h>

@interface FinchSecurityProtocolOptions : NSObject
@end
@implementation FinchSecurityProtocolOptions
@end

extern sec_protocol_metadata_t _FinchSecProtocolMetadataCreate(void);

/* (+1: Swift declares these with @_silgen_name, so takes their results as owned) */
sec_protocol_options_t finch_network_sec_protocol_options_create(void) {
    return (sec_protocol_options_t)[[FinchSecurityProtocolOptions alloc] init];
}

sec_protocol_metadata_t finch_network_sec_protocol_metadata_create(void) {
	return _FinchSecProtocolMetadataCreate();
}

typedef void (*FinchDNSBrowseCallback)(void *, uint32_t, uint32_t, int32_t,
                                       const char *, const char *, const char *);
typedef void (*FinchDNSRegisterCallback)(void *, uint32_t, int32_t, const char *, const char *, const char *);
typedef void (*FinchDNSResolveCallback)(void *, uint32_t, uint32_t, int32_t, const char *, const char *, uint16_t,
                                        uint16_t, const unsigned char *);

typedef struct {
    void *client;
    union {
        FinchDNSBrowseCallback browse;
        FinchDNSRegisterCallback registration;
        FinchDNSResolveCallback resolve;
    } callback;
} FinchDNSContext;

typedef struct {
    DNSServiceRef service;
    FinchDNSContext *context;
} FinchDNSHandle;

static FinchDNSHandle *FinchDNSMakeHandle(DNSServiceRef service, FinchDNSContext *context) {
    FinchDNSHandle *handle = malloc(sizeof(*handle));
    if (!handle) {
        DNSServiceRefDeallocate(service);
        free(context);
        return NULL;
    }
    handle->service = service;
    handle->context = context;
    return handle;
}

static void FinchDNSBrowseReply(DNSServiceRef ref, DNSServiceFlags flags, uint32_t interfaceIndex,
                                DNSServiceErrorType error, const char *name, const char *type,
                                const char *domain, void *context) {
    (void)ref;
    FinchDNSContext *state = context;
    state->callback.browse(state->client, flags, interfaceIndex, error, name, type, domain);
}

void *finch_network_dns_browse(const char *type, const char *domain, FinchDNSBrowseCallback callback,
                               void *client, int32_t *error) {
    FinchDNSContext *context = calloc(1, sizeof(*context));
    if (!context) { if (error) *error = kDNSServiceErr_NoMemory; return NULL; }
    context->callback.browse = callback;
    context->client = client;
    DNSServiceRef service = NULL;
    DNSServiceErrorType result = DNSServiceBrowse(&service, 0, kDNSServiceInterfaceIndexAny,
        type, domain, FinchDNSBrowseReply, context);
    if (result != kDNSServiceErr_NoError) {
        free(context);
        if (error) *error = result;
        return NULL;
    }
    FinchDNSHandle *handle = FinchDNSMakeHandle(service, context);
    if (error) *error = handle ? kDNSServiceErr_NoError : kDNSServiceErr_NoMemory;
    return handle;
}

int finch_network_dns_fd(void *service) {
    FinchDNSHandle *handle = service;
    return handle ? DNSServiceRefSockFD(handle->service) : -1;
}

int32_t finch_network_dns_process(void *service) {
    FinchDNSHandle *handle = service;
    return handle ? DNSServiceProcessResult(handle->service) : kDNSServiceErr_BadParam;
}

void finch_network_dns_cancel(void *service) {
    if (!service) return;
    FinchDNSHandle *handle = service;
    DNSServiceRefDeallocate(handle->service);
    free(handle->context);
    free(handle);
}

static void FinchDNSRegisterReply(DNSServiceRef ref, DNSServiceFlags flags, DNSServiceErrorType error,
                                  const char *name, const char *type, const char *domain, void *context) {
    (void)ref;
    FinchDNSContext *state = context;
    state->callback.registration(state->client, flags, error, name, type, domain);
}

void *finch_network_dns_register(const char *name, const char *type, const char *domain,
                                 bool noAutoRename, uint16_t port, const void *txt, uint16_t txtLength,
                                 FinchDNSRegisterCallback callback, void *client, int32_t *error) {
    FinchDNSContext *context = calloc(1, sizeof(*context));
    if (!context) { if (error) *error = kDNSServiceErr_NoMemory; return NULL; }
    context->callback.registration = callback;
    context->client = client;
    DNSServiceRef service = NULL;
    DNSServiceFlags flags = noAutoRename ? kDNSServiceFlagsNoAutoRename : 0;
    DNSServiceErrorType result = DNSServiceRegister(&service, flags, kDNSServiceInterfaceIndexAny,
        name, type, domain, NULL, htons(port), txtLength, txt, FinchDNSRegisterReply, context);
    if (result != kDNSServiceErr_NoError) {
        free(context);
        if (error) *error = result;
        return NULL;
    }
    FinchDNSHandle *handle = FinchDNSMakeHandle(service, context);
    if (error) *error = handle ? kDNSServiceErr_NoError : kDNSServiceErr_NoMemory;
    return handle;
}

static void FinchDNSResolveReply(DNSServiceRef ref, DNSServiceFlags flags, uint32_t interfaceIndex,
                                 DNSServiceErrorType error, const char *fullName, const char *host,
                                 uint16_t port, uint16_t txtLength, const unsigned char *txt, void *context) {
    (void)ref;
    FinchDNSContext *state = context;
    state->callback.resolve(state->client, flags, interfaceIndex, error, fullName, host, port, txtLength, txt);
}

void *finch_network_dns_resolve(const char *name, const char *type, const char *domain, uint32_t interfaceIndex,
                                FinchDNSResolveCallback callback, void *client, int32_t *error) {
    FinchDNSContext *context = calloc(1, sizeof(*context));
    if (!context) { if (error) *error = kDNSServiceErr_NoMemory; return NULL; }
    context->callback.resolve = callback;
    context->client = client;
    DNSServiceRef service = NULL;
    DNSServiceErrorType result = DNSServiceResolve(&service, 0, interfaceIndex, name, type, domain,
        FinchDNSResolveReply, context);
    if (result != kDNSServiceErr_NoError) {
        free(context);
        if (error) *error = result;
        return NULL;
    }
    FinchDNSHandle *handle = FinchDNSMakeHandle(service, context);
    if (error) *error = handle ? kDNSServiceErr_NoError : kDNSServiceErr_NoMemory;
    return handle;
}
