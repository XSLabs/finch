/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * SCDynamicStore with Finch's configd (docs/design/SECURITY.md).
 *
 * The store answers from the system's own state, read when asked:
 *   Setup:/System                       computer name (preferences, else the host name)
 *   Setup:/Network/HostNames            local host name (preferences, else derived)
 *   State:/Users/ConsoleUser            the owner of /dev/console (unless root)
 *   State:/Network/Interface            the kernel's interfaces (getifaddrs)
 *   State:/Network/Interface/<if>/IPv4  addresses, masks, broadcast addresses
 *   State:/Network/Interface/<if>/IPv6  addresses, prefix lengths, flags
 *   State:/Network/Interface/<if>/Link  whether the link is up
 *   State:/Network/Global/IPv4, IPv6    primary interface and router (default route)
 *   State:/Network/Global/DNS           /etc/resolv.conf
 *   State:/Network/Global/Proxies       the primary service's proxies, else Apple's defaults
 * Finch's configd shares written values and watches between processes. Local
 * network state also uses the kernel's routing socket. A store keeps its watch
 * keys so it can subscribe again after the service restarts.
 */
#include "SCFinch.h"
#include <arpa/inet.h>
#include <errno.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/route.h>
#include <netinet/in.h>
#include <netinet6/in6_var.h>
#include <pthread.h>
#include <pwd.h>
#include <regex.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <sys/sysctl.h>
#include <unistd.h>

#define CONFIGD_SERVICE "com.apple.SystemConfiguration.configd"

/* Keep the wire format simple and stable: request values are binary property
 * lists, and replies carry the same values as xpc.data. */
xpc_connection_t _SCConfigdCreateConnection(xpc_handler_t handler)
{
	xpc_connection_t connection = xpc_connection_create_mach_service(CONFIGD_SERVICE, NULL, 0);
	if (connection == NULL)
		return NULL;
	if (handler == NULL)
		handler = ^(xpc_object_t event) { (void)event; };
	xpc_connection_set_event_handler(connection, handler);
	xpc_connection_resume(connection);
	return connection;
}

xpc_object_t _SCConfigdCreateRequest(const char *operation)
{
	if (operation == NULL)
		return NULL;
	xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
	if (request)
		xpc_dictionary_set_string(request, "op", operation);
	return request;
}

xpc_object_t _SCConfigdSendRequest(xpc_connection_t connection, xpc_object_t request, int *status)
{
	if (status)
		*status = kSCStatusNoStoreServer;
	if (connection == NULL || request == NULL)
		return NULL;
	xpc_object_t reply = xpc_connection_send_message_with_reply_sync(connection, request);
	if (reply == NULL || xpc_get_type(reply) != XPC_TYPE_DICTIONARY) {
		if (reply)
			xpc_release(reply);
		return NULL;
	}
	xpc_object_t value = xpc_dictionary_get_value(reply, "status");
	if (value == NULL || xpc_get_type(value) != XPC_TYPE_INT64) {
		xpc_release(reply);
		return NULL;
	}
	if (status)
		*status = (int)xpc_dictionary_get_int64(reply, "status");
	return reply;
}

bool _SCConfigdSetPropertyList(xpc_object_t request, const char *name, CFPropertyListRef value)
{
	if (request == NULL || name == NULL || value == NULL ||
	    !CFPropertyListIsValid(value, kCFPropertyListBinaryFormat_v1_0))
		return false;
	CFErrorRef error = NULL;
	CFDataRef bytes = CFPropertyListCreateData(NULL, value,
	    kCFPropertyListBinaryFormat_v1_0, 0, &error);
	if (bytes == NULL) {
		if (error)
			CFRelease(error);
		return false;
	}
	xpc_object_t data = xpc_data_create(CFDataGetBytePtr(bytes),
	    (size_t)CFDataGetLength(bytes));
	CFRelease(bytes);
	if (error)
		CFRelease(error);
	if (data == NULL)
		return false;
	xpc_dictionary_set_value(request, name, data);
	xpc_release(data);
	return true;
}

CFPropertyListRef _SCConfigdCopyPropertyList(xpc_object_t reply, const char *name)
{
	xpc_object_t data = reply ? xpc_dictionary_get_value(reply, name) : NULL;
	if (data == NULL || xpc_get_type(data) != XPC_TYPE_DATA)
		return NULL;
	size_t length = xpc_data_get_length(data);
	if (length == 0 || length > 16 * 1024 * 1024)
		return NULL;
	CFDataRef bytes = CFDataCreate(NULL, xpc_data_get_bytes_ptr(data), (CFIndex)length);
	if (bytes == NULL)
		return NULL;
	CFPropertyListRef value = CFPropertyListCreateWithData(NULL, bytes,
	    kCFPropertyListMutableContainersAndLeaves, NULL, NULL);
	CFRelease(bytes);
	if (value && !CFPropertyListIsValid(value, kCFPropertyListBinaryFormat_v1_0)) {
		CFRelease(value);
		value = NULL;
	}
	return value;
}

static void setString(CFMutableDictionaryRef d, CFStringRef k, const char *s)
{
	CFStringRef v = CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8);
	if (v) {
		CFDictionarySetValue(d, k, v);
		CFRelease(v);
	}
}

static void setInt(CFMutableDictionaryRef d, CFStringRef k, int n)
{
	CFNumberRef v = CFNumberCreate(NULL, kCFNumberIntType, &n);
	CFDictionarySetValue(d, k, v);
	CFRelease(v);
}

static CFMutableDictionaryRef newDict(void)
{
	return CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}

static CFMutableArrayRef arrayIn(CFMutableDictionaryRef d, CFStringRef k)
{
	CFMutableArrayRef a = (CFMutableArrayRef)CFDictionaryGetValue(d, k);
	if (!a) {
		a = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
		CFDictionarySetValue(d, k, a);
		CFRelease(a);
	}
	return a;
}

static void appendString(CFMutableArrayRef a, const char *s)
{
	CFStringRef v = CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8);
	CFArrayAppendValue(a, v);
	CFRelease(v);
}

static void appendInt(CFMutableArrayRef a, int n)
{
	CFNumberRef v = CFNumberCreate(NULL, kCFNumberIntType, &n);
	CFArrayAppendValue(a, v);
	CFRelease(v);
}

/* ---- Names ---- */

static CFDictionaryRef prefsPath(CFDictionaryRef prefs, const char *const *path)
{
	CFTypeRef d = prefs;
	for (int i = 0; d && path[i]; i++) {
		if (CFGetTypeID(d) != CFDictionaryGetTypeID())
			return NULL;
		CFStringRef k = CFStringCreateWithCString(NULL, path[i], kCFStringEncodingUTF8);
		d = CFDictionaryGetValue(d, k);
		CFRelease(k);
	}
	return d && CFGetTypeID(d) == CFDictionaryGetTypeID() ? d : NULL;
}

CFStringRef _SCCopyComputerName(CFStringEncoding *encoding)
{
	CFDictionaryRef prefs = _SCCopySystemPreferences();
	static const char *const path[] = {"System", "System", NULL};
	CFDictionaryRef sys = prefs ? prefsPath(prefs, path) : NULL;
	CFStringRef name = sys ? CFDictionaryGetValue(sys, kSCPropSystemComputerName) : NULL;
	CFStringEncoding enc = kCFStringEncodingMacRoman;
	if (name && CFGetTypeID(name) == CFStringGetTypeID()) {
		CFNumberRef n = CFDictionaryGetValue(sys, kSCPropSystemComputerNameEncoding);
		if (n && CFGetTypeID(n) == CFNumberGetTypeID())
			CFNumberGetValue(n, kCFNumberSInt32Type, &enc);
		CFRetain(name);
	} else {
		char host[256] = "";
		gethostname(host, sizeof(host));
		char *dot = strchr(host, '.');
		if (dot)
			*dot = 0;
		name = CFStringCreateWithCString(NULL, host[0] ? host : "localhost", kCFStringEncodingUTF8);
	}
	if (prefs)
		CFRelease(prefs);
	if (encoding)
		*encoding = enc;
	return name;
}

/* A computer name as a host name label: letters, digits and hyphens. */
static CFStringRef hostLabel(CFStringRef name)
{
	CFMutableStringRef s = CFStringCreateMutable(NULL, 0);
	bool hyphen = false;
	for (CFIndex i = 0; i < CFStringGetLength(name) && CFStringGetLength(s) < 63; i++) {
		UniChar c = CFStringGetCharacterAtIndex(name, i);
		if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) {
			CFStringAppendCharacters(s, &c, 1);
			hyphen = false;
		} else if ((c == ' ' || c == '-' || c == '_' || c == '.') && !hyphen && CFStringGetLength(s)) {
			CFStringAppendCString(s, "-", kCFStringEncodingASCII);
			hyphen = true;
		}
	}
	if (hyphen)
		CFStringDelete(s, CFRangeMake(CFStringGetLength(s) - 1, 1));
	if (!CFStringGetLength(s))
		CFStringAppendCString(s, "localhost", kCFStringEncodingASCII);
	return s;
}

CFStringRef _SCCopyLocalHostName(void)
{
	CFDictionaryRef prefs = _SCCopySystemPreferences();
	static const char *const path[] = {"System", "Network", "HostNames", NULL};
	CFDictionaryRef hn = prefs ? prefsPath(prefs, path) : NULL;
	CFStringRef name = hn ? CFDictionaryGetValue(hn, kSCPropNetLocalHostName) : NULL;
	if (name && CFGetTypeID(name) == CFStringGetTypeID())
		CFRetain(name);
	else {
		CFStringRef computer = _SCCopyComputerName(NULL);
		name = hostLabel(computer);
		CFRelease(computer);
	}
	if (prefs)
		CFRelease(prefs);
	return name;
}

/* ---- The network state ---- */

static CFMutableDictionaryRef entity(CFMutableDictionaryRef state, const char *ifname, CFStringRef ent)
{
	CFStringRef key = CFStringCreateWithFormat(NULL, NULL, CFSTR("State:/Network/Interface/%s/%@"), ifname, ent);
	CFMutableDictionaryRef d = (CFMutableDictionaryRef)CFDictionaryGetValue(state, key);
	if (!d) {
		d = newDict();
		CFDictionarySetValue(state, key, d);
		CFRelease(d);
	}
	CFRelease(key);
	return d;
}

static int prefixLength(const struct in6_addr *mask)
{
	int n = 0;
	for (int i = 0; i < 16; i++)
		for (int b = 7; b >= 0; b--) {
			if (!(mask->s6_addr[i] & (1 << b)))
				return n;
			n++;
		}
	return n;
}

static void addInterfaces(CFMutableDictionaryRef state)
{
	struct ifaddrs *ifa = NULL;
	if (getifaddrs(&ifa) < 0)
		return;
	CFMutableDictionaryRef list = newDict();
	CFMutableArrayRef names = arrayIn(list, CFSTR("Interfaces"));
	int s6 = socket(AF_INET6, SOCK_DGRAM, 0);
	for (struct ifaddrs *i = ifa; i; i = i->ifa_next) {
		CFStringRef n = CFStringCreateWithCString(NULL, i->ifa_name, kCFStringEncodingUTF8);
		if (!CFArrayContainsValue(names, CFRangeMake(0, CFArrayGetCount(names)), n))
			CFArrayAppendValue(names, n);
		CFRelease(n);
		if (!i->ifa_addr)
			continue;
		char buf[INET6_ADDRSTRLEN];
		if (i->ifa_addr->sa_family == AF_INET) {
			CFMutableDictionaryRef d = entity(state, i->ifa_name, kSCEntNetIPv4);
			inet_ntop(AF_INET, &((struct sockaddr_in *)i->ifa_addr)->sin_addr, buf, sizeof(buf));
			appendString(arrayIn(d, kSCPropNetIPv4Addresses), buf);
			if (i->ifa_netmask) {
				inet_ntop(AF_INET, &((struct sockaddr_in *)i->ifa_netmask)->sin_addr, buf, sizeof(buf));
				appendString(arrayIn(d, kSCPropNetIPv4SubnetMasks), buf);
			}
			if ((i->ifa_flags & IFF_BROADCAST) && i->ifa_dstaddr) {
				inet_ntop(AF_INET, &((struct sockaddr_in *)i->ifa_dstaddr)->sin_addr, buf, sizeof(buf));
				appendString(arrayIn(d, kSCPropNetIPv4BroadcastAddresses), buf);
			}
		} else if (i->ifa_addr->sa_family == AF_INET6) {
			CFMutableDictionaryRef d = entity(state, i->ifa_name, kSCEntNetIPv6);
			struct sockaddr_in6 sin6 = *(struct sockaddr_in6 *)i->ifa_addr;
			if (IN6_IS_ADDR_LINKLOCAL(&sin6.sin6_addr)) {
				/* The kernel embeds the scope in the address. */
				sin6.sin6_addr.s6_addr[2] = sin6.sin6_addr.s6_addr[3] = 0;
			}
			inet_ntop(AF_INET6, &sin6.sin6_addr, buf, sizeof(buf));
			appendString(arrayIn(d, kSCPropNetIPv6Addresses), buf);
			appendInt(arrayIn(d, kSCPropNetIPv6PrefixLength),
			    i->ifa_netmask ? prefixLength(&((struct sockaddr_in6 *)i->ifa_netmask)->sin6_addr) : 128);
			int flags = 0;
			struct in6_ifreq ifr;
			memset(&ifr, 0, sizeof(ifr));
			strlcpy(ifr.ifr_name, i->ifa_name, sizeof(ifr.ifr_name));
			ifr.ifr_addr = *(struct sockaddr_in6 *)i->ifa_addr;
			if (s6 >= 0 && ioctl(s6, SIOCGIFAFLAG_IN6, &ifr) == 0)
				flags = ifr.ifr_ifru.ifru_flags6;
			appendInt(arrayIn(d, kSCPropNetIPv6Flags), flags);
		} else if (i->ifa_addr->sa_family == AF_LINK && !(i->ifa_flags & IFF_LOOPBACK)) {
			CFMutableDictionaryRef d = entity(state, i->ifa_name, kSCEntNetLink);
			CFDictionarySetValue(d, kSCPropNetLinkActive, (i->ifa_flags & IFF_RUNNING) ? kCFBooleanTrue : kCFBooleanFalse);
		}
	}
	if (s6 >= 0)
		close(s6);
	freeifaddrs(ifa);
	CFDictionarySetValue(state, CFSTR("State:/Network/Interface"), list);
	CFRelease(list);
}

/* The default route for a family: its interface and gateway. */
static bool defaultRoute(int family, char *ifname, size_t ifsize, char *router, size_t rsize)
{
	int mib[6] = {CTL_NET, PF_ROUTE, 0, family, NET_RT_FLAGS, RTF_GATEWAY};
	size_t len = 0;
	if (sysctl(mib, 6, NULL, &len, NULL, 0) < 0 || len == 0)
		return false;
	char *buf = malloc(len);
	bool found = false;
	if (sysctl(mib, 6, buf, &len, NULL, 0) == 0) {
		for (char *p = buf; !found && p < buf + len;) {
			struct rt_msghdr *rtm = (struct rt_msghdr *)p;
			if (rtm->rtm_msglen == 0)
				break;
			struct sockaddr *sa = (struct sockaddr *)(rtm + 1);
			struct sockaddr *addrs[RTAX_MAX] = {0};
			for (int i = 0; i < RTAX_MAX; i++) {
				if (!(rtm->rtm_addrs & (1 << i)))
					continue;
				addrs[i] = sa;
				size_t l = sa->sa_len ? ((sa->sa_len + 3) & ~3u) : 4;
				sa = (struct sockaddr *)((char *)sa + l);
			}
			struct sockaddr *dst = addrs[RTAX_DST], *gw = addrs[RTAX_GATEWAY], *mask = addrs[RTAX_NETMASK];
			bool isDefault = dst && dst->sa_family == family &&
			    (family == AF_INET ? ((struct sockaddr_in *)dst)->sin_addr.s_addr == 0
			                       : IN6_IS_ADDR_UNSPECIFIED(&((struct sockaddr_in6 *)dst)->sin6_addr)) &&
			    (!mask || mask->sa_len <= 2 ||
			        (family == AF_INET ? ((struct sockaddr_in *)mask)->sin_addr.s_addr == 0
			                           : IN6_IS_ADDR_UNSPECIFIED(&((struct sockaddr_in6 *)mask)->sin6_addr)));
			if (isDefault && (rtm->rtm_flags & RTF_UP) && !(rtm->rtm_flags & RTF_IFSCOPE)) {
				if (!if_indextoname(rtm->rtm_index, ifname))
					ifname[0] = 0;
				router[0] = 0;
				if (gw && gw->sa_family == AF_INET)
					inet_ntop(AF_INET, &((struct sockaddr_in *)gw)->sin_addr, router, rsize);
				else if (gw && gw->sa_family == AF_INET6) {
					struct sockaddr_in6 g = *(struct sockaddr_in6 *)gw;
					if (IN6_IS_ADDR_LINKLOCAL(&g.sin6_addr))
						g.sin6_addr.s6_addr[2] = g.sin6_addr.s6_addr[3] = 0;
					inet_ntop(AF_INET6, &g.sin6_addr, router, rsize);
				}
				found = ifname[0] != 0;
			}
			p += rtm->rtm_msglen;
		}
	}
	free(buf);
	(void)ifsize;
	return found;
}

static void addGlobal(CFMutableDictionaryRef state)
{
	char ifname[IF_NAMESIZE + 1], router[INET6_ADDRSTRLEN];
	int families[] = {AF_INET, AF_INET6};
	CFStringRef keys[] = {CFSTR("State:/Network/Global/IPv4"), CFSTR("State:/Network/Global/IPv6")};
	for (int i = 0; i < 2; i++)
		if (defaultRoute(families[i], ifname, sizeof(ifname), router, sizeof(router))) {
			CFMutableDictionaryRef d = newDict();
			setString(d, CFSTR("PrimaryInterface"), ifname);
			if (router[0])
				setString(d, kSCPropNetIPv4Router, router);
			CFDictionarySetValue(state, keys[i], d);
			CFRelease(d);
		}
}

static void addDNS(CFMutableDictionaryRef state)
{
	FILE *f = fopen("/etc/resolv.conf", "r");
	if (!f)
		return;
	CFMutableDictionaryRef d = newDict();
	char line[512];
	while (fgets(line, sizeof(line), f)) {
		char *save = NULL, *word = strtok_r(line, " \t\r\n", &save);
		if (!word || word[0] == '#' || word[0] == ';')
			continue;
		if (!strcmp(word, "nameserver")) {
			char *a = strtok_r(NULL, " \t\r\n", &save);
			if (a)
				appendString(arrayIn(d, kSCPropNetDNSServerAddresses), a);
		} else if (!strcmp(word, "search")) {
			for (char *w; (w = strtok_r(NULL, " \t\r\n", &save));)
				appendString(arrayIn(d, kSCPropNetDNSSearchDomains), w);
		} else if (!strcmp(word, "domain")) {
			char *w = strtok_r(NULL, " \t\r\n", &save);
			if (w)
				setString(d, kSCPropNetDNSDomainName, w);
		}
	}
	fclose(f);
	if (CFDictionaryGetCount(d))
		CFDictionarySetValue(state, CFSTR("State:/Network/Global/DNS"), d);
	CFRelease(d);
}

/* The proxies of the first active service in the current set, else the
 * defaults macOS reports when none are configured. */
static void addProxies(CFMutableDictionaryRef state)
{
	CFDictionaryRef proxies = NULL;
	CFDictionaryRef prefs = _SCCopySystemPreferences();
	CFStringRef current = prefs ? CFDictionaryGetValue(prefs, kSCPrefCurrentSet) : NULL;
	if (current && CFGetTypeID(current) == CFStringGetTypeID() && CFStringHasPrefix(current, CFSTR("/Sets/"))) {
		CFStringRef setID = CFStringCreateWithSubstring(NULL, current, CFRangeMake(6, CFStringGetLength(current) - 6));
		CFDictionaryRef sets = CFDictionaryGetValue(prefs, kSCPrefSets);
		CFDictionaryRef set = sets && CFGetTypeID(sets) == CFDictionaryGetTypeID() ? CFDictionaryGetValue(sets, setID) : NULL;
		static const char *const orderPath[] = {"Network", "Global", "IPv4", NULL};
		CFDictionaryRef global = set ? prefsPath(set, orderPath) : NULL;
		CFArrayRef order = global ? CFDictionaryGetValue(global, CFSTR("ServiceOrder")) : NULL;
		CFDictionaryRef services = CFDictionaryGetValue(prefs, kSCPrefNetworkServices);
		for (CFIndex i = 0; !proxies && order && CFGetTypeID(order) == CFArrayGetTypeID() && i < CFArrayGetCount(order); i++) {
			CFDictionaryRef svc = services ? CFDictionaryGetValue(services, CFArrayGetValueAtIndex(order, i)) : NULL;
			if (!svc || CFGetTypeID(svc) != CFDictionaryGetTypeID() || CFDictionaryGetValue(svc, kSCResvInactive))
				continue;
			CFDictionaryRef p = CFDictionaryGetValue(svc, kSCEntNetProxies);
			if (p && CFGetTypeID(p) == CFDictionaryGetTypeID())
				proxies = CFRetain(p);
		}
		CFRelease(setID);
	}
	if (prefs)
		CFRelease(prefs);
	if (!proxies) {
		CFMutableDictionaryRef d = newDict();
		CFMutableArrayRef ex = arrayIn(d, kSCPropNetProxiesExceptionsList);
		appendString(ex, "*.local");
		appendString(ex, "169.254/16");
		setInt(d, kSCPropNetProxiesFTPPassive, 1);
		proxies = d;
	}
	CFDictionarySetValue(state, CFSTR("State:/Network/Global/Proxies"), proxies);
	CFRelease(proxies);
}

static void addSystem(CFMutableDictionaryRef state)
{
	CFDictionaryRef prefs = _SCCopySystemPreferences();
	CFStringRef current = prefs ? CFDictionaryGetValue(prefs, kSCPrefCurrentSet) : NULL;
	if (current && CFGetTypeID(current) == CFStringGetTypeID()) {
		CFMutableDictionaryRef setup = newDict();
		CFDictionarySetValue(setup, kSCDynamicStorePropSetupCurrentSet, current);
		CFDictionarySetValue(state, CFSTR("Setup:"), setup);
		CFRelease(setup);
	}
	if (prefs)
		CFRelease(prefs);

	CFStringEncoding enc;
	CFStringRef name = _SCCopyComputerName(&enc);
	CFMutableDictionaryRef d = newDict();
	CFDictionarySetValue(d, kSCPropSystemComputerName, name);
	setInt(d, kSCPropSystemComputerNameEncoding, (int)enc);
	CFDictionarySetValue(state, CFSTR("Setup:/System"), d);
	CFRelease(d);
	CFRelease(name);
	CFStringRef local = _SCCopyLocalHostName();
	d = newDict();
	CFDictionarySetValue(d, kSCPropNetLocalHostName, local);
	CFDictionarySetValue(state, CFSTR("Setup:/Network/HostNames"), d);
	CFRelease(d);
	CFRelease(local);

	struct stat st;
	if (stat("/dev/console", &st) == 0 && st.st_uid != 0) {
		struct passwd *pw = getpwuid(st.st_uid);
		if (pw) {
			d = newDict();
			setString(d, CFSTR("Name"), pw->pw_name);
			setInt(d, CFSTR("UID"), (int)pw->pw_uid);
			setInt(d, CFSTR("GID"), (int)pw->pw_gid);
			CFDictionarySetValue(state, CFSTR("State:/Users/ConsoleUser"), d);
			CFRelease(d);
		}
	}
}

CFDictionaryRef _SCCopyLocalState(void)
{
	CFMutableDictionaryRef state = newDict();
	addSystem(state);
	addInterfaces(state);
	addGlobal(state);
	addDNS(state);
	addProxies(state);
	return state;
}

/* ---- Sessions ---- */

typedef struct Store {
	CFRuntimeBase base;
	CFStringRef name;
	xpc_connection_t connection;
	SCDynamicStoreCallBack callout;
	SCDynamicStoreContext context;
	CFArrayRef watchedKeys, watchedPatterns;
	CFMutableArrayRef changed;
	CFDictionaryRef snapshot;     /* the watched values, to diff against */
	dispatch_queue_t queue;
	CFRunLoopSourceRef source;
	CFMutableArrayRef runLoops;
	pthread_mutex_t subscriptionLock;
	bool subscriptionLockInitialized;
	bool needsResubscribe;
	uint64_t subscriptionEpoch;
	bool watching;
	struct Store *nextWatcher;
	struct Store *nextStore;
} Store;

static pthread_mutex_t storeLock = PTHREAD_MUTEX_INITIALIZER;
static Store *watchers;
static Store *allStores;

static void recordChanges(Store *s, CFArrayRef keys);
static bool resendStoreSubscription(Store *store);

static bool resendStoreSubscription(Store *store)
{
	if (store == NULL || !store->subscriptionLockInitialized)
		return false;
	pthread_mutex_lock(&store->subscriptionLock);
	pthread_mutex_lock(&storeLock);
	bool needed = store->needsResubscribe;
	uint64_t epoch = store->subscriptionEpoch;
	CFArrayRef keys = needed && store->watchedKeys ? CFRetain(store->watchedKeys) : NULL;
	CFArrayRef patterns = needed && store->watchedPatterns ? CFRetain(store->watchedPatterns) : NULL;
	pthread_mutex_unlock(&storeLock);
	if (!needed) {
		pthread_mutex_unlock(&store->subscriptionLock);
		return true;
	}

	bool restored = false;
	if (keys && patterns && store->connection) {
		xpc_object_t request = _SCConfigdCreateRequest("store.subscribe");
		bool encoded = request &&
		    _SCConfigdSetPropertyList(request, "keys", keys) &&
		    _SCConfigdSetPropertyList(request, "patterns", patterns);
		int status = encoded ? kSCStatusNoStoreServer : kSCStatusFailed;
		xpc_object_t reply = encoded ?
		    _SCConfigdSendRequest(store->connection, request, &status) : NULL;
		restored = status == kSCStatusOK;
		if (reply)
			xpc_release(reply);
		if (request)
			xpc_release(request);
	}
	if (keys)
		CFRelease(keys);
	if (patterns)
		CFRelease(patterns);
	if (restored) {
		pthread_mutex_lock(&storeLock);
		if (store->subscriptionEpoch == epoch)
			store->needsResubscribe = false;
		pthread_mutex_unlock(&storeLock);
	}
	pthread_mutex_unlock(&store->subscriptionLock);
	return restored;
}

/* Restore a pending watch before and after each explicit request. The second
 * attempt covers a service that restarted between the first attempt and the
 * request. The user's request is sent only once, including writes. */
static xpc_object_t storeSendRequest(Store *store, xpc_object_t request, int *status)
{
	(void)resendStoreSubscription(store);
	xpc_object_t reply = _SCConfigdSendRequest(store ? store->connection : NULL,
	    request, status);
	if (reply)
		(void)resendStoreSubscription(store);
	return reply;
}

/* The service forgets each client's watch when it exits. Keep the client's
 * last watch and restore it on a worker queue after reconnecting. The XPC
 * event queue cannot make a synchronous request to its own connection. */
static void markStoreSubscriptionStale(Store *store)
{
	bool schedule = false;
	pthread_mutex_lock(&storeLock);
	if (store->watchedKeys && store->watchedPatterns) {
		store->needsResubscribe = true;
		store->subscriptionEpoch++;
		CFRetain(store);
		schedule = true;
	}
	pthread_mutex_unlock(&storeLock);
	if (schedule) {
		dispatch_async(dispatch_get_global_queue(0, 0), ^{
			(void)resendStoreSubscription(store);
			CFRelease(store);
		});
	}
}

static void storeConnectionEvent(xpc_connection_t connection, xpc_object_t event)
{
	if (xpc_get_type(event) == XPC_TYPE_ERROR) {
		if (event == XPC_ERROR_CONNECTION_INTERRUPTED) {
			pthread_mutex_lock(&storeLock);
			Store *store = allStores;
			while (store && store->connection != connection)
				store = store->nextStore;
			if (store)
				CFRetain(store);
			pthread_mutex_unlock(&storeLock);
			if (store) {
				markStoreSubscriptionStale(store);
				CFRelease(store);
			}
		}
		return;
	}
	if (xpc_get_type(event) != XPC_TYPE_DICTIONARY ||
	    strcmp(xpc_dictionary_get_string(event, "event") ?: "", "store.changed") != 0)
		return;
	pthread_mutex_lock(&storeLock);
	Store *store = allStores;
	while (store && store->connection != connection)
		store = store->nextStore;
	if (store)
		CFRetain(store);
	pthread_mutex_unlock(&storeLock);
	if (store == NULL)
		return;

	xpc_object_t values = xpc_dictionary_get_value(event, "keys");
	CFMutableArrayRef keys = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	if (values && xpc_get_type(values) == XPC_TYPE_ARRAY) {
		size_t count = xpc_array_get_count(values);
		for (size_t i = 0; i < count; i++) {
			const char *text = xpc_array_get_string(values, i);
			if (text == NULL)
				continue;
			CFStringRef key = CFStringCreateWithCString(NULL, text, kCFStringEncodingUTF8);
			if (key) {
				CFArrayAppendValue(keys, key);
				CFRelease(key);
			}
		}
	}
	if (CFArrayGetCount(keys) > 0)
		recordChanges(store, keys);
	CFRelease(keys);
	CFRelease(store);
}

static void storeFree(CFTypeRef o)
{
	Store *s = (Store *)o;
	pthread_mutex_lock(&storeLock);
	for (Store **p = &watchers; *p; p = &(*p)->nextWatcher)
		if (*p == s) {
			*p = s->nextWatcher;
			break;
		}
	for (Store **p = &allStores; *p; p = &(*p)->nextStore)
		if (*p == s) {
			*p = s->nextStore;
			break;
		}
	pthread_mutex_unlock(&storeLock);
	if (s->connection) {
		xpc_connection_cancel(s->connection);
		xpc_release(s->connection);
	}
	if (s->subscriptionLockInitialized)
		pthread_mutex_destroy(&s->subscriptionLock);
	if (s->context.release && s->context.info)
		s->context.release(s->context.info);
	CFTypeRef refs[] = {s->name, s->watchedKeys, s->watchedPatterns, s->changed, s->snapshot, s->source, s->runLoops};
	for (size_t i = 0; i < sizeof(refs) / sizeof(*refs); i++)
		if (refs[i])
			CFRelease(refs[i]);
	if (s->queue)
		dispatch_release(s->queue);
}

static CFStringRef storeDescription(CFTypeRef o)
{
	return CFStringCreateWithFormat(NULL, NULL, CFSTR("<SCDynamicStore %p> { name = %@ }"), o, ((Store *)o)->name);
}

SC_DEFINE_TYPE(SCDynamicStoreGetTypeID, "SCDynamicStore", storeFree, NULL, NULL, storeDescription)

static CFDictionaryRef copyAll(SCDynamicStoreRef ref)
{
	CFDictionaryRef state = _SCCopyLocalState();
	CFMutableDictionaryRef all = CFDictionaryCreateMutableCopy(NULL, 0, state);
	CFRelease(state);
	Store *store = ref ? (Store *)ref : NULL;
	xpc_connection_t temporaryConnection = NULL;
	xpc_connection_t connection = store ? store->connection : NULL;
	if (connection == NULL) {
		temporaryConnection = _SCConfigdCreateConnection(NULL);
		connection = temporaryConnection;
	}
	xpc_object_t request = _SCConfigdCreateRequest("store.copy");
	int status = kSCStatusNoStoreServer;
	xpc_object_t reply = store ? storeSendRequest(store, request, &status) :
	    _SCConfigdSendRequest(connection, request, &status);
	CFPropertyListRef dynamicValues = status == kSCStatusOK ?
	    _SCConfigdCopyPropertyList(reply, "plist") : NULL;
	if (dynamicValues && CFGetTypeID(dynamicValues) == CFDictionaryGetTypeID()) {
		CFIndex n = CFDictionaryGetCount(dynamicValues);
		const void **keys = malloc(sizeof(void *) * (size_t)(n ? n : 1));
		const void **values = malloc(sizeof(void *) * (size_t)(n ? n : 1));
		if (keys && values) {
			CFDictionaryGetKeysAndValues(dynamicValues, keys, values);
			for (CFIndex i = 0; i < n; i++)
				CFDictionarySetValue(all, keys[i], values[i]);
		}
		free(keys);
		free(values);
	}
	if (dynamicValues)
		CFRelease(dynamicValues);
	if (reply)
		xpc_release(reply);
	if (request)
		xpc_release(request);
	if (temporaryConnection) {
		xpc_connection_cancel(temporaryConnection);
		xpc_release(temporaryConnection);
	}
	return all;
}

SCDynamicStoreRef SCDynamicStoreCreateWithOptions(CFAllocatorRef allocator, CFStringRef name, CFDictionaryRef storeOptions,
    SCDynamicStoreCallBack callout, SCDynamicStoreContext *context)
{
	if (!name || CFGetTypeID(name) != CFStringGetTypeID()) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return NULL;
	}
	Store *s = (Store *)_SCCreateInstance(SCDynamicStoreGetTypeID(), sizeof(*s));
	if (s == NULL) {
		_SCErrorSet(kSCStatusFailed);
		return NULL;
	}
	if (pthread_mutex_init(&s->subscriptionLock, NULL) != 0) {
		CFRelease(s);
		_SCErrorSet(kSCStatusFailed);
		return NULL;
	}
	s->subscriptionLockInitialized = true;
	s->name = CFStringCreateCopy(NULL, name);
	s->callout = callout;
	if (context) {
		s->context = *context;
		if (context->retain && context->info)
			s->context.info = (void *)context->retain(context->info);
	}
	s->changed = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	s->connection = xpc_connection_create_mach_service(CONFIGD_SERVICE, NULL, 0);
	if (s->connection) {
		xpc_connection_t connection = s->connection;
		xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
			storeConnectionEvent(connection, event);
		});
		pthread_mutex_lock(&storeLock);
		s->nextStore = allStores;
		allStores = s;
		pthread_mutex_unlock(&storeLock);
		xpc_connection_resume(connection);
	}
	_SCErrorSet(kSCStatusOK);
	return (SCDynamicStoreRef)s;
}

SCDynamicStoreRef SCDynamicStoreCreate(CFAllocatorRef allocator, CFStringRef name, SCDynamicStoreCallBack callout,
    SCDynamicStoreContext *context)
{
	return SCDynamicStoreCreateWithOptions(allocator, name, NULL, callout, context);
}

static bool validStore(SCDynamicStoreRef s)
{
	if (s && CFGetTypeID(s) == SCDynamicStoreGetTypeID())
		return true;
	_SCErrorSet(kSCStatusNoStoreSession);
	return false;
}

CFPropertyListRef SCDynamicStoreCopyValue(SCDynamicStoreRef store, CFStringRef key)
{
	if (store && !validStore(store))
		return NULL;
	if (!key || CFGetTypeID(key) != CFStringGetTypeID()) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return NULL;
	}
	CFDictionaryRef all = copyAll(store);
	CFPropertyListRef v = CFDictionaryGetValue(all, key);
	if (v)
		CFRetain(v);
	CFRelease(all);
	_SCErrorSet(v ? kSCStatusOK : kSCStatusNoKey);
	return v;
}

/* configd's patterns are POSIX extended regular expressions, matched against
 * the whole key. */
static bool compilePattern(CFStringRef pattern, regex_t *re)
{
	char buf[1024], anchored[1100];
	if (!CFStringGetCString(pattern, buf, sizeof(buf), kCFStringEncodingUTF8))
		return false;
	snprintf(anchored, sizeof(anchored), "^(%s)$", buf);
	return regcomp(re, anchored, REG_EXTENDED | REG_NOSUB) == 0;
}

static bool keyMatches(regex_t *re, CFStringRef key)
{
	char buf[1024];
	return CFStringGetCString(key, buf, sizeof(buf), kCFStringEncodingUTF8) && regexec(re, buf, 0, NULL, 0) == 0;
}

CFArrayRef SCDynamicStoreCopyKeyList(SCDynamicStoreRef store, CFStringRef pattern)
{
	if (store && !validStore(store))
		return NULL;
	regex_t re;
	if (!pattern || CFGetTypeID(pattern) != CFStringGetTypeID() || !compilePattern(pattern, &re)) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return NULL;
	}
	CFDictionaryRef all = copyAll(store);
	CFIndex n = CFDictionaryGetCount(all);
	const void **keys = malloc(sizeof(void *) * n);
	CFDictionaryGetKeysAndValues(all, keys, NULL);
	CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	for (CFIndex i = 0; i < n; i++)
		if (keyMatches(&re, keys[i]))
			CFArrayAppendValue(out, keys[i]);
	free(keys);
	regfree(&re);
	CFRelease(all);
	_SCErrorSet(kSCStatusOK);
	return out;
}

static CFDictionaryRef copyMatching(CFDictionaryRef all, CFArrayRef keys, CFArrayRef patterns)
{
	CFMutableDictionaryRef out = newDict();
	for (CFIndex i = 0; keys && i < CFArrayGetCount(keys); i++) {
		CFTypeRef v = CFDictionaryGetValue(all, CFArrayGetValueAtIndex(keys, i));
		if (v)
			CFDictionarySetValue(out, CFArrayGetValueAtIndex(keys, i), v);
	}
	if (patterns && CFArrayGetCount(patterns)) {
		CFIndex n = CFDictionaryGetCount(all);
		const void **k = malloc(sizeof(void *) * n), **v = malloc(sizeof(void *) * n);
		CFDictionaryGetKeysAndValues(all, k, v);
		for (CFIndex p = 0; p < CFArrayGetCount(patterns); p++) {
			regex_t re;
			if (!compilePattern(CFArrayGetValueAtIndex(patterns, p), &re))
				continue;
			for (CFIndex i = 0; i < n; i++)
				if (keyMatches(&re, k[i]))
					CFDictionarySetValue(out, k[i], v[i]);
			regfree(&re);
		}
		free(k);
		free(v);
	}
	return out;
}

CFDictionaryRef SCDynamicStoreCopyMultiple(SCDynamicStoreRef store, CFArrayRef keys, CFArrayRef patterns)
{
	if (store && !validStore(store))
		return NULL;
	CFDictionaryRef all = copyAll(store);
	CFDictionaryRef out = copyMatching(all, keys, patterns);
	CFRelease(all);
	_SCErrorSet(kSCStatusOK);
	return out;
}

static Boolean setRemote(SCDynamicStoreRef ref, CFStringRef key,
    CFPropertyListRef value, const char *operation)
{
	if (!validStore(ref))
		return false;
	if (!key || CFGetTypeID(key) != CFStringGetTypeID() || value == NULL ||
	    !CFPropertyListIsValid(value, kCFPropertyListBinaryFormat_v1_0)) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return false;
	}
	Store *store = (Store *)ref;
	xpc_object_t request = _SCConfigdCreateRequest(operation);
	if (request == NULL) {
		_SCErrorSet(kSCStatusFailed);
		return false;
	}
	bool encoded = _SCConfigdSetPropertyList(request, "key", key) &&
	    _SCConfigdSetPropertyList(request, "value", value);
	int status = encoded ? kSCStatusNoStoreServer : kSCStatusInvalidArgument;
	xpc_object_t reply = encoded ? storeSendRequest(store, request, &status) : NULL;
	if (reply)
		xpc_release(reply);
	xpc_release(request);
	_SCErrorSet(status);
	return status == kSCStatusOK;
}

Boolean SCDynamicStoreSetValue(SCDynamicStoreRef store, CFStringRef key, CFPropertyListRef value)
{
	if (!value) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return false;
	}
	return setRemote(store, key, value, "store.set");
}

Boolean SCDynamicStoreAddValue(SCDynamicStoreRef store, CFStringRef key, CFPropertyListRef value)
{
	return setRemote(store, key, value, "store.add");
}

Boolean SCDynamicStoreAddTemporaryValue(SCDynamicStoreRef store, CFStringRef key, CFPropertyListRef value)
{
	return setRemote(store, key, value, "store.temporary");
}

Boolean SCDynamicStoreSetMultiple(SCDynamicStoreRef store, CFDictionaryRef keysToSet, CFArrayRef keysToRemove,
    CFArrayRef keysToNotify)
{
	if (!validStore(store))
		return false;
	CFMutableDictionaryRef emptyDictionary = NULL;
	CFMutableArrayRef emptyRemoves = NULL, emptyNotifies = NULL;
	if (keysToSet == NULL) {
		emptyDictionary = newDict();
		keysToSet = emptyDictionary;
	}
	if (keysToRemove == NULL) {
		emptyRemoves = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
		keysToRemove = emptyRemoves;
	}
	if (keysToNotify == NULL) {
		emptyNotifies = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
		keysToNotify = emptyNotifies;
	}
	xpc_object_t request = _SCConfigdCreateRequest("store.set-multiple");
	bool encoded = request &&
	    _SCConfigdSetPropertyList(request, "sets", keysToSet) &&
	    _SCConfigdSetPropertyList(request, "removes", keysToRemove) &&
	    _SCConfigdSetPropertyList(request, "notifies", keysToNotify);
	int status = encoded ? kSCStatusNoStoreServer :
	    (request ? kSCStatusInvalidArgument : kSCStatusFailed);
	xpc_object_t reply = encoded ?
	    storeSendRequest((Store *)store, request, &status) : NULL;
	if (reply)
		xpc_release(reply);
	if (request)
		xpc_release(request);
	if (emptyDictionary)
		CFRelease(emptyDictionary);
	if (emptyRemoves)
		CFRelease(emptyRemoves);
	if (emptyNotifies)
		CFRelease(emptyNotifies);
	_SCErrorSet(status);
	return status == kSCStatusOK;
}

Boolean SCDynamicStoreRemoveValue(SCDynamicStoreRef store, CFStringRef key)
{
	if (!validStore(store))
		return false;
	if (!key || CFGetTypeID(key) != CFStringGetTypeID()) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return false;
	}
	xpc_object_t request = _SCConfigdCreateRequest("store.remove");
	bool encoded = request && _SCConfigdSetPropertyList(request, "key", key);
	int status = encoded ? kSCStatusNoStoreServer :
	    (request ? kSCStatusInvalidArgument : kSCStatusFailed);
	xpc_object_t reply = encoded ?
	    storeSendRequest((Store *)store, request, &status) : NULL;
	if (reply)
		xpc_release(reply);
	if (request)
		xpc_release(request);
	_SCErrorSet(status);
	return status == kSCStatusOK;
}

Boolean SCDynamicStoreNotifyValue(SCDynamicStoreRef store, CFStringRef key)
{
	if (!validStore(store))
		return false;
	if (!key || CFGetTypeID(key) != CFStringGetTypeID()) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return false;
	}
	xpc_object_t request = _SCConfigdCreateRequest("store.notify");
	bool encoded = request && _SCConfigdSetPropertyList(request, "key", key);
	int status = encoded ? kSCStatusNoStoreServer :
	    (request ? kSCStatusInvalidArgument : kSCStatusFailed);
	xpc_object_t reply = encoded ?
	    storeSendRequest((Store *)store, request, &status) : NULL;
	if (reply)
		xpc_release(reply);
	if (request)
		xpc_release(request);
	_SCErrorSet(status);
	return status == kSCStatusOK;
}

/* ---- Notifications ---- */

static void deliver(Store *s)
{
	CFArrayRef keys = NULL;
	pthread_mutex_lock(&storeLock);
	if (CFArrayGetCount(s->changed)) {
		keys = CFArrayCreateCopy(NULL, s->changed);
		CFArrayRemoveAllValues(s->changed);
	}
	pthread_mutex_unlock(&storeLock);
	if (keys && s->callout)
		s->callout((SCDynamicStoreRef)s, keys, s->context.info);
	if (keys)
		CFRelease(keys);
}

static void signalStore(Store *s)
{
	if (s->queue) {
		CFRetain(s);
		dispatch_async(s->queue, ^{
			deliver(s);
			CFRelease(s);
		});
	}
	if (s->source) {
		CFRunLoopSourceSignal(s->source);
		for (CFIndex i = 0; s->runLoops && i < CFArrayGetCount(s->runLoops); i++)
			CFRunLoopWakeUp((CFRunLoopRef)CFArrayGetValueAtIndex(s->runLoops, i));
	}
}

static void recordChanges(Store *s, CFArrayRef keys)
{
	bool any = false;
	pthread_mutex_lock(&storeLock);
	for (CFIndex i = 0; i < CFArrayGetCount(keys); i++) {
		CFStringRef k = CFArrayGetValueAtIndex(keys, i);
		if (!CFArrayContainsValue(s->changed, CFRangeMake(0, CFArrayGetCount(s->changed)), k)) {
			CFArrayAppendValue(s->changed, k);
			any = true;
		}
	}
	pthread_mutex_unlock(&storeLock);
	if (any)
		signalStore(s);
}

/* Network changes: re-read the watched keys and report the ones that differ. */
static void networkChanged(void)
{
	pthread_mutex_lock(&storeLock);
	Store *list[64];
	int n = 0;
	for (Store *s = watchers; s && n < 64; s = s->nextWatcher)
		list[n++] = (Store *)CFRetain(s);
	pthread_mutex_unlock(&storeLock);
	if (!n)
		return;
	CFDictionaryRef all = copyAll((SCDynamicStoreRef)list[0]);
	for (int i = 0; i < n; i++) {
		Store *s = list[i];
		CFDictionaryRef now = copyMatching(all, s->watchedKeys, s->watchedPatterns);
		CFMutableArrayRef changed = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
		CFDictionaryRef before = s->snapshot;
		CFDictionaryRef sides[] = {now, before};
		for (int side = 0; side < 2; side++) {
			CFDictionaryRef d = sides[side];
			CFIndex c = d ? CFDictionaryGetCount(d) : 0;
			const void **k = malloc(sizeof(void *) * (c ? c : 1));
			if (d)
				CFDictionaryGetKeysAndValues(d, k, NULL);
			for (CFIndex j = 0; j < c; j++) {
				CFTypeRef a = now ? CFDictionaryGetValue(now, k[j]) : NULL;
				CFTypeRef b = before ? CFDictionaryGetValue(before, k[j]) : NULL;
				if ((!a || !b || !CFEqual(a, b)) &&
				    !CFArrayContainsValue(changed, CFRangeMake(0, CFArrayGetCount(changed)), k[j]))
					CFArrayAppendValue(changed, k[j]);
			}
			free(k);
		}
		pthread_mutex_lock(&storeLock);
		if (s->snapshot)
			CFRelease(s->snapshot);
		s->snapshot = now;
		pthread_mutex_unlock(&storeLock);
		if (CFArrayGetCount(changed))
			recordChanges(s, changed);
		CFRelease(changed);
		CFRelease(s);
	}
	CFRelease(all);
}

static void startWatching(Store *s)
{
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		_SCWatchNetworkChanges(^{
			networkChanged();
		});
	});
	CFDictionaryRef all = copyAll((SCDynamicStoreRef)s);
	CFDictionaryRef now = copyMatching(all, s->watchedKeys, s->watchedPatterns);
	CFRelease(all);
	pthread_mutex_lock(&storeLock);
	if (s->snapshot)
		CFRelease(s->snapshot);
	s->snapshot = now;
	if (!s->watching) {
		s->nextWatcher = watchers;
		watchers = s;
		s->watching = true;
	}
	pthread_mutex_unlock(&storeLock);
}

Boolean SCDynamicStoreSetNotificationKeys(SCDynamicStoreRef store, CFArrayRef keys, CFArrayRef patterns)
{
	if (!validStore(store))
		return false;
	Store *s = (Store *)store;
	CFMutableArrayRef emptyKeys = NULL, emptyPatterns = NULL;
	if (keys == NULL) {
		emptyKeys = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
		keys = emptyKeys;
	}
	if (patterns == NULL) {
		emptyPatterns = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
		patterns = emptyPatterns;
	}
	CFArrayRef savedKeys = keys ? CFArrayCreateCopy(NULL, keys) : NULL;
	CFArrayRef savedPatterns = patterns ? CFArrayCreateCopy(NULL, patterns) : NULL;
	if (savedKeys == NULL || savedPatterns == NULL) {
		if (savedKeys) CFRelease(savedKeys);
		if (savedPatterns) CFRelease(savedPatterns);
		if (emptyKeys) CFRelease(emptyKeys);
		if (emptyPatterns) CFRelease(emptyPatterns);
		_SCErrorSet(kSCStatusFailed);
		return false;
	}
	xpc_object_t request = _SCConfigdCreateRequest("store.subscribe");
	bool encoded = request &&
	    _SCConfigdSetPropertyList(request, "keys", keys) &&
	    _SCConfigdSetPropertyList(request, "patterns", patterns);
	int status = encoded ? kSCStatusNoStoreServer :
	    (request ? kSCStatusInvalidArgument : kSCStatusFailed);
	CFArrayRef oldKeys = NULL, oldPatterns = NULL;
	bool oldPending = false, staged = false;
	uint64_t requestEpoch = 0;
	pthread_mutex_lock(&s->subscriptionLock);
	if (encoded) {
		pthread_mutex_lock(&storeLock);
		oldKeys = s->watchedKeys;
		oldPatterns = s->watchedPatterns;
		oldPending = s->needsResubscribe;
		s->watchedKeys = savedKeys;
		s->watchedPatterns = savedPatterns;
		savedKeys = NULL;
		savedPatterns = NULL;
		s->needsResubscribe = true;
		requestEpoch = ++s->subscriptionEpoch;
		staged = true;
		pthread_mutex_unlock(&storeLock);
	}
	xpc_object_t reply = encoded ? _SCConfigdSendRequest(s->connection, request, &status) : NULL;
	if (reply)
		xpc_release(reply);
	if (request)
		xpc_release(request);
	if (staged) {
		pthread_mutex_lock(&storeLock);
		if (status == kSCStatusOK) {
			if (s->subscriptionEpoch == requestEpoch)
				s->needsResubscribe = false;
		} else {
			if (s->watchedKeys)
				CFRelease(s->watchedKeys);
			if (s->watchedPatterns)
				CFRelease(s->watchedPatterns);
			s->watchedKeys = oldKeys;
			s->watchedPatterns = oldPatterns;
			oldKeys = NULL;
			oldPatterns = NULL;
			s->needsResubscribe = oldPending ||
			    (s->subscriptionEpoch != requestEpoch && s->watchedKeys && s->watchedPatterns);
			s->subscriptionEpoch++;
		}
		pthread_mutex_unlock(&storeLock);
	}
	pthread_mutex_unlock(&s->subscriptionLock);
	if (oldKeys) CFRelease(oldKeys);
	if (oldPatterns) CFRelease(oldPatterns);
	if (savedKeys) CFRelease(savedKeys);
	if (savedPatterns) CFRelease(savedPatterns);
	if (emptyKeys)
		CFRelease(emptyKeys);
	if (emptyPatterns)
		CFRelease(emptyPatterns);
	if (status != kSCStatusOK) {
		_SCErrorSet(status);
		return false;
	}
	startWatching(s);
	_SCErrorSet(kSCStatusOK);
	return true;
}

CFArrayRef SCDynamicStoreCopyNotifiedKeys(SCDynamicStoreRef store)
{
	if (!validStore(store))
		return NULL;
	Store *s = (Store *)store;
	pthread_mutex_lock(&storeLock);
	CFArrayRef keys = CFArrayCreateCopy(NULL, s->changed);
	CFArrayRemoveAllValues(s->changed);
	pthread_mutex_unlock(&storeLock);
	_SCErrorSet(kSCStatusOK);
	return keys;
}

static void sourcePerform(void *info)
{
	deliver((Store *)info);
}

static void sourceSchedule(void *info, CFRunLoopRef rl, CFStringRef mode)
{
	Store *s = info;
	pthread_mutex_lock(&storeLock);
	if (!s->runLoops)
		s->runLoops = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	CFArrayAppendValue(s->runLoops, rl);
	pthread_mutex_unlock(&storeLock);
}

static void sourceCancel(void *info, CFRunLoopRef rl, CFStringRef mode)
{
	Store *s = info;
	pthread_mutex_lock(&storeLock);
	CFIndex i = s->runLoops ? CFArrayGetFirstIndexOfValue(s->runLoops, CFRangeMake(0, CFArrayGetCount(s->runLoops)), rl) : kCFNotFound;
	if (i != kCFNotFound)
		CFArrayRemoveValueAtIndex(s->runLoops, i);
	pthread_mutex_unlock(&storeLock);
}

CFRunLoopSourceRef SCDynamicStoreCreateRunLoopSource(CFAllocatorRef allocator, SCDynamicStoreRef store, CFIndex order)
{
	if (!validStore(store))
		return NULL;
	Store *s = (Store *)store;
	if (s->queue) {
		_SCErrorSet(kSCStatusNotifierActive);
		return NULL;
	}
	if (!s->source) {
		CFRunLoopSourceContext ctx = {0, s, NULL, NULL, NULL, NULL, NULL, sourceSchedule, sourceCancel, sourcePerform};
		s->source = CFRunLoopSourceCreate(allocator, order, &ctx);
	}
	_SCErrorSet(kSCStatusOK);
	return (CFRunLoopSourceRef)CFRetain(s->source);
}

Boolean SCDynamicStoreSetDispatchQueue(SCDynamicStoreRef store, dispatch_queue_t queue)
{
	if (!validStore(store))
		return false;
	Store *s = (Store *)store;
	if (queue && (s->queue || s->source)) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return false;
	}
	if (s->queue)
		dispatch_release(s->queue);
	s->queue = queue;
	if (queue)
		dispatch_retain(queue);
	_SCErrorSet(kSCStatusOK);
	return true;
}

/* ---- Specific values ---- */

CFStringRef SCDynamicStoreCopyComputerName(SCDynamicStoreRef store, CFStringEncoding *nameEncoding)
{
	_SCErrorSet(kSCStatusOK);
	return _SCCopyComputerName(nameEncoding);
}

CFStringRef SCDynamicStoreCopyLocalHostName(SCDynamicStoreRef store)
{
	_SCErrorSet(kSCStatusOK);
	return _SCCopyLocalHostName();
}

/* SCDynamicStoreCopyConsoleUser and SCDynamicStoreCopyLocation are configd's
 * (SCDConsoleUser.c, SCLocation.c), over this store. */

CFDictionaryRef SCDynamicStoreCopyProxies(SCDynamicStoreRef store)
{
	CFDictionaryRef d = SCDynamicStoreCopyValue(store, CFSTR("State:/Network/Global/Proxies"));
	_SCErrorSet(kSCStatusOK);
	return d;
}

/* Key creators configd defines in files that need its daemon (SCDHostName.c,
 * SCProxies.c); the rest are configd's own (SCDKeys.c, SCDConsoleUser.c, SCLocation.c). */
CFStringRef SCDynamicStoreKeyCreateComputerName(CFAllocatorRef allocator)
{
	return CFStringCreateWithFormat(allocator, NULL, CFSTR("%@/%@"), kSCDynamicStoreDomainSetup, kSCCompSystem);
}

CFStringRef SCDynamicStoreKeyCreateHostNames(CFAllocatorRef allocator)
{
	return CFStringCreateWithFormat(allocator, NULL, CFSTR("%@/%@/%@"), kSCDynamicStoreDomainSetup, kSCCompNetwork,
	    kSCCompHostNames);
}

CFStringRef SCDynamicStoreKeyCreateProxies(CFAllocatorRef allocator)
{
	return SCDynamicStoreKeyCreateNetworkGlobalEntity(allocator, kSCDynamicStoreDomainState, kSCEntNetProxies);
}
