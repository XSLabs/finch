// SPDX-License-Identifier: MIT OR Apache-2.0
// The C path-monitor entry points used by Swift clients, plus opaque TLS values
// for Network's Swift protocol-options API.
#import <Foundation/Foundation.h>
#import <Network/Network.h>
#import <Security/Security.h>
#import <dns_sd.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <stdbool.h>
#import <stdlib.h>

@interface FinchNetworkPath : NSObject {
    nw_path_status_t _status;
}
- (instancetype)initWithStatus:(nw_path_status_t)status;
- (nw_path_status_t)status;
@end

@implementation FinchNetworkPath
- (instancetype)initWithStatus:(nw_path_status_t)status {
    self = [super init];
    if (self) _status = status;
    return self;
}
- (nw_path_status_t)status { return _status; }
@end

@interface FinchNetworkPathMonitor : NSObject {
    dispatch_queue_t _queue;
    dispatch_source_t _timer;
    nw_path_monitor_update_handler_t _updateHandler;
    nw_path_t _lastPath;
    BOOL _started;
    BOOL _cancelled;
}
- (void)setQueue:(dispatch_queue_t)queue;
- (void)setUpdateHandler:(nw_path_monitor_update_handler_t)handler;
- (void)start;
- (void)cancel;
@end

static nw_path_t FinchCurrentPath(void) {
    struct ifaddrs *interfaces = NULL;
    BOOL satisfied = NO;
    if (getifaddrs(&interfaces) == 0) {
        for (struct ifaddrs *item = interfaces; item; item = item->ifa_next) {
            if (!item->ifa_addr || !(item->ifa_flags & IFF_UP) || (item->ifa_flags & IFF_LOOPBACK)) continue;
            sa_family_t family = item->ifa_addr->sa_family;
            if (family == AF_INET || family == AF_INET6) {
                satisfied = YES;
                break;
            }
        }
        freeifaddrs(interfaces);
    }
    FinchNetworkPath *path = [[FinchNetworkPath alloc] initWithStatus:
        (satisfied ? nw_path_status_satisfied : nw_path_status_unsatisfied)];
    return (nw_path_t)[path autorelease];
}

@implementation FinchNetworkPathMonitor
- (void)setQueue:(dispatch_queue_t)queue {
    if (_started || _cancelled || _queue == queue) return;
    [_queue release];
    _queue = [queue retain];
}
- (void)setUpdateHandler:(nw_path_monitor_update_handler_t)handler {
    if (_cancelled) return;
    if (_updateHandler) Block_release(_updateHandler);
    _updateHandler = handler ? Block_copy(handler) : nil;
}
- (void)start {
    if (_started || _cancelled) return;
    _started = YES;
    if (!_queue) _queue = [dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0) retain];
    _lastPath = [FinchCurrentPath() retain];
    if (_updateHandler) _updateHandler(_lastPath);

    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(_timer, ^{
        if (self->_cancelled) return;
        nw_path_t path = FinchCurrentPath();
        if (nw_path_get_status(path) == nw_path_get_status(self->_lastPath)) return;
        [self->_lastPath release];
        self->_lastPath = [path retain];
        if (self->_updateHandler) self->_updateHandler(path);
    });
    dispatch_resume(_timer);
}
- (void)cancel {
    if (_cancelled) return;
    _cancelled = YES;
    if (_timer) {
        dispatch_source_cancel(_timer);
        [_timer release];
        _timer = nil;
    }
    if (_updateHandler) {
        Block_release(_updateHandler);
        _updateHandler = nil;
    }
    [_lastPath release];
    _lastPath = nil;
}
- (void)dealloc {
    [self cancel];
    [_queue release];
    [super dealloc];
}
@end

nw_path_monitor_t nw_path_monitor_create(void) {
    return (nw_path_monitor_t)[[FinchNetworkPathMonitor alloc] init];
}

void nw_path_monitor_set_queue(nw_path_monitor_t monitor, dispatch_queue_t queue) {
    [(FinchNetworkPathMonitor *)monitor setQueue:queue];
}

void nw_path_monitor_set_update_handler(nw_path_monitor_t monitor, nw_path_monitor_update_handler_t handler) {
    [(FinchNetworkPathMonitor *)monitor setUpdateHandler:handler];
}

void nw_path_monitor_start(nw_path_monitor_t monitor) {
    [(FinchNetworkPathMonitor *)monitor start];
}

void nw_path_monitor_cancel(nw_path_monitor_t monitor) {
    [(FinchNetworkPathMonitor *)monitor cancel];
}

nw_path_status_t nw_path_get_status(nw_path_t path) {
    return path ? [(FinchNetworkPath *)path status] : nw_path_status_invalid;
}

bool nw_path_is_constrained(nw_path_t path) {
    (void)path;
    return false;
}

@interface FinchSecurityProtocolOptions : NSObject
@end
@implementation FinchSecurityProtocolOptions
@end

@interface FinchSecurityProtocolMetadata : NSObject
@end
@implementation FinchSecurityProtocolMetadata
@end

sec_protocol_options_t finch_network_sec_protocol_options_create(void) {
    return (sec_protocol_options_t)[[[FinchSecurityProtocolOptions alloc] init] autorelease];
}

sec_protocol_metadata_t finch_network_sec_protocol_metadata_create(void) {
    return (sec_protocol_metadata_t)[[[FinchSecurityProtocolMetadata alloc] init] autorelease];
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
