/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * SCNetworkConnection objects for services in SystemConfiguration preferences.
 * Finch has no PPP or VPN connection agent yet, so reads report the stored
 * service and disconnected state while start requests return the service error.
 */
#include "SCFinch.h"
#include <SystemConfiguration/SCNetworkConnection.h>
#include <errno.h>

typedef struct {
	CFRuntimeBase base;
	CFStringRef serviceID;
	CFDictionaryRef userOptions;
	CFMutableArrayRef schedules;
	SCNetworkConnectionCallBack callback;
	SCNetworkConnectionContext context;
	dispatch_queue_t queue;
	SCNetworkConnectionStatus status;
	Boolean serviceAvailable;
} Connection;

static void connectionFinalize(CFTypeRef object)
{
	Connection *connection = (Connection *)object;
	if (connection->serviceID) CFRelease(connection->serviceID);
	if (connection->userOptions) CFRelease(connection->userOptions);
	if (connection->schedules) CFRelease(connection->schedules);
	if (connection->queue) dispatch_release(connection->queue);
	if (connection->context.info && connection->context.release)
		connection->context.release(connection->context.info);
}

static CFStringRef connectionDescription(CFTypeRef object)
{
	Connection *connection = (Connection *)object;
	return CFStringCreateWithFormat(NULL, NULL, CFSTR("<SCNetworkConnection %p> { serviceID = %@, status = %d }"),
	    object, connection->serviceID, (int)connection->status);
}

SC_DEFINE_TYPE(SCNetworkConnectionGetTypeID, "SCNetworkConnection", connectionFinalize, NULL, NULL,
	connectionDescription)

static Connection *validConnection(SCNetworkConnectionRef object)
{
	if (object && CFGetTypeID(object) == SCNetworkConnectionGetTypeID())
		return (Connection *)object;
	_SCErrorSet(kSCStatusInvalidArgument);
	return NULL;
}

static Connection *createConnection(CFAllocatorRef allocator, CFStringRef serviceID, Boolean serviceAvailable,
	    SCNetworkConnectionCallBack callback, SCNetworkConnectionContext *context)
{
	if (context && context->version != 0) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return NULL;
	}
	Connection *connection = (Connection *)_CFRuntimeCreateInstance(allocator, SCNetworkConnectionGetTypeID(),
	    sizeof(*connection) - sizeof(CFRuntimeBase), NULL);
	if (!connection)
		return NULL;
	connection->serviceID = serviceID ? CFRetain(serviceID) : NULL;
	connection->serviceAvailable = serviceAvailable;
	connection->callback = callback;
	connection->status = serviceID && serviceAvailable ? kSCNetworkConnectionDisconnected : kSCNetworkConnectionInvalid;
	connection->schedules = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	if (context) {
		connection->context = *context;
		if (connection->context.info && connection->context.retain)
			connection->context.info = (void *)connection->context.retain(connection->context.info);
	}
	_SCErrorSet(kSCStatusOK);
	return connection;
}

Boolean SCNetworkConnectionCopyUserPreferences(CFDictionaryRef selectionOptions, CFStringRef *serviceID,
	CFDictionaryRef *userOptions)
{
	if (serviceID) *serviceID = NULL;
	if (userOptions) *userOptions = NULL;
	if ((selectionOptions && CFGetTypeID(selectionOptions) != CFDictionaryGetTypeID()) || !serviceID || !userOptions) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return false;
	}
	SCPreferencesRef prefs = SCPreferencesCreate(NULL, CFSTR("SCNetworkConnection preferences"), NULL);
	if (!prefs)
		return false;
	CFArrayRef services = SCNetworkServiceCopyAll(prefs);
	for (CFIndex i = 0; i < CFArrayGetCount(services); i++) {
		SCNetworkServiceRef service = CFArrayGetValueAtIndex(services, i);
		SCNetworkInterfaceRef interface = SCNetworkServiceGetInterface(service);
		if (SCNetworkServiceGetEnabled(service) && interface &&
		    CFEqual(SCNetworkInterfaceGetInterfaceType(interface), kSCNetworkInterfaceTypePPP)) {
			*serviceID = CFRetain(SCNetworkServiceGetServiceID(service));
			*userOptions = CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks,
			    &kCFTypeDictionaryValueCallBacks);
			break;
		}
	}
	CFRelease(services);
	CFRelease(prefs);
	if (!*serviceID) {
		_SCErrorSet(kSCStatusConnectionNoService);
		return false;
	}
	_SCErrorSet(kSCStatusOK);
	return true;
}

SCNetworkConnectionRef SCNetworkConnectionCreateWithServiceID(CFAllocatorRef allocator, CFStringRef serviceID,
	SCNetworkConnectionCallBack callback, SCNetworkConnectionContext *context)
{
	if (!serviceID || CFGetTypeID(serviceID) != CFStringGetTypeID()) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return NULL;
	}
	SCPreferencesRef prefs = SCPreferencesCreate(allocator, CFSTR("SCNetworkConnection"), NULL);
	SCNetworkServiceRef service = prefs ? SCNetworkServiceCopy(prefs, serviceID) : NULL;
	Boolean available = service && SCNetworkServiceGetInterface(service) != NULL;
	Connection *connection = createConnection(allocator, serviceID, available, callback, context);
	if (service) CFRelease(service);
	if (prefs) CFRelease(prefs);
	return (SCNetworkConnectionRef)connection;
}

CFStringRef SCNetworkConnectionCopyServiceID(SCNetworkConnectionRef object)
{
	Connection *connection = validConnection(object);
	if (!connection)
		return NULL;
	if (!connection->serviceID) {
		_SCErrorSet(kSCStatusConnectionNoService);
		return NULL;
	}
	_SCErrorSet(kSCStatusOK);
	return CFRetain(connection->serviceID);
}

SCNetworkConnectionStatus SCNetworkConnectionGetStatus(SCNetworkConnectionRef object)
{
	Connection *connection = validConnection(object);
	return connection ? connection->status : kSCNetworkConnectionInvalid;
}

CFDictionaryRef SCNetworkConnectionCopyExtendedStatus(SCNetworkConnectionRef object)
{
	if (!validConnection(object))
		return NULL;
	_SCErrorSet(kSCStatusConnectionNoService);
	return NULL;
}

CFDictionaryRef SCNetworkConnectionCopyStatistics(SCNetworkConnectionRef object)
{
	if (!validConnection(object))
		return NULL;
	_SCErrorSet(kSCStatusConnectionNoService);
	return NULL;
}

Boolean SCNetworkConnectionStart(SCNetworkConnectionRef object, CFDictionaryRef userOptions, Boolean linger)
{
	Connection *connection = validConnection(object);
	(void)linger;
	if (!connection || (userOptions && CFGetTypeID(userOptions) != CFDictionaryGetTypeID())) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return false;
	}
	if (!connection->serviceID || !connection->serviceAvailable) {
		_SCErrorSet(kSCStatusConnectionNoService);
		return false;
	}
	if (connection->userOptions) CFRelease(connection->userOptions);
	connection->userOptions = userOptions ? CFDictionaryCreateCopy(NULL, userOptions) : NULL;
	_SCErrorSet(kSCStatusConnectionNoService);
	return false;
}

Boolean SCNetworkConnectionStop(SCNetworkConnectionRef object, Boolean forceDisconnect)
{
	Connection *connection = validConnection(object);
	(void)forceDisconnect;
	if (!connection)
		return false;
	if (connection->status == kSCNetworkConnectionDisconnected) {
		_SCErrorSet(kSCStatusOK);
		return true;
	}
	_SCErrorSet(kSCStatusConnectionNoService);
	return false;
}

CFDictionaryRef SCNetworkConnectionCopyUserOptions(SCNetworkConnectionRef object)
{
	Connection *connection = validConnection(object);
	if (!connection)
		return NULL;
	_SCErrorSet(kSCStatusOK);
	return connection->userOptions ? CFDictionaryCreateCopy(NULL, connection->userOptions) :
	    CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}

static CFDictionaryRef scheduleEntry(CFRunLoopRef runLoop, CFStringRef mode)
{
	const void *keys[] = { CFSTR("runLoop"), CFSTR("mode") };
	const void *values[] = { runLoop, mode };
	return CFDictionaryCreate(NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}

Boolean SCNetworkConnectionScheduleWithRunLoop(SCNetworkConnectionRef object, CFRunLoopRef runLoop, CFStringRef mode)
{
	Connection *connection = validConnection(object);
	if (!connection || !runLoop || !mode || CFGetTypeID(mode) != CFStringGetTypeID()) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return false;
	}
	for (CFIndex i = 0; i < CFArrayGetCount(connection->schedules); i++) {
		CFDictionaryRef entry = CFArrayGetValueAtIndex(connection->schedules, i);
		if (CFEqual(CFDictionaryGetValue(entry, CFSTR("runLoop")), runLoop) &&
		    CFEqual(CFDictionaryGetValue(entry, CFSTR("mode")), mode)) {
			_SCErrorSet(kSCStatusOK);
			return true;
		}
	}
	CFRunLoopSourceContext context = {0};
	CFRunLoopSourceRef source = CFRunLoopSourceCreate(NULL, 0, &context);
	if (!source)
		return false;
	CFRunLoopAddSource(runLoop, source, mode);
	CFDictionaryRef entry = scheduleEntry(runLoop, mode);
	CFArrayAppendValue(connection->schedules, entry);
	CFArrayAppendValue(connection->schedules, source);
	CFRelease(entry);
	CFRelease(source);
	_SCErrorSet(kSCStatusOK);
	return true;
}

Boolean SCNetworkConnectionUnscheduleFromRunLoop(SCNetworkConnectionRef object, CFRunLoopRef runLoop, CFStringRef mode)
{
	Connection *connection = validConnection(object);
	if (!connection || !runLoop || !mode || CFGetTypeID(mode) != CFStringGetTypeID()) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return false;
	}
	for (CFIndex i = 0; i + 1 < CFArrayGetCount(connection->schedules); i += 2) {
		CFDictionaryRef entry = CFArrayGetValueAtIndex(connection->schedules, i);
		CFRunLoopSourceRef source = (CFRunLoopSourceRef)CFArrayGetValueAtIndex(connection->schedules, i + 1);
		if (CFEqual(CFDictionaryGetValue(entry, CFSTR("runLoop")), runLoop) &&
		    CFEqual(CFDictionaryGetValue(entry, CFSTR("mode")), mode)) {
			CFRunLoopRemoveSource(runLoop, source, mode);
			CFArrayRemoveValueAtIndex(connection->schedules, i + 1);
			CFArrayRemoveValueAtIndex(connection->schedules, i);
			_SCErrorSet(kSCStatusOK);
			return true;
		}
	}
	_SCErrorSet(kSCStatusNoKey);
	return false;
}

Boolean SCNetworkConnectionSetDispatchQueue(SCNetworkConnectionRef object, dispatch_queue_t queue)
{
	Connection *connection = validConnection(object);
	if (!connection)
		return false;
	if (queue)
		dispatch_retain(queue);
	if (connection->queue)
		dispatch_release(connection->queue);
	connection->queue = queue;
	_SCErrorSet(kSCStatusOK);
	return true;
}
