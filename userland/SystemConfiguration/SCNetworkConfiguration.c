/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Network configuration: interfaces (the kernel's), and the sets, services
 * and protocols of a preferences session (docs/design/SECURITY.md). Reading
 * is complete; editing (creating services, changing protocols) changes the
 * session's preferences, committed with SCPreferencesCommitChanges.
 */
#include "SCFinch.h"
#include <errno.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/if_types.h>
#include <net/if_var.h>
#include <netinet/ip.h>
#include <netinet/ip6.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/sockio.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* ---- Interfaces ---- */

typedef struct {
	CFRuntimeBase base;
	CFStringRef bsdName, type, displayName, hardwareAddress;
	CFDictionaryRef configuration;
	SCPreferencesRef prefs;
	CFStringRef serviceID;
	SCNetworkInterfaceRef child;
} Interface;

static void interfaceFree(CFTypeRef o)
{
	Interface *i = (Interface *)o;
	CFTypeRef refs[] = {i->bsdName, i->type, i->displayName, i->hardwareAddress, i->configuration,
	    i->prefs, i->serviceID, i->child};
	for (size_t k = 0; k < sizeof(refs) / sizeof(*refs); k++)
		if (refs[k])
			CFRelease(refs[k]);
}
static Boolean interfaceEqual(CFTypeRef a, CFTypeRef b)
{
	Interface *x = (Interface *)a, *y = (Interface *)b;
	return CFEqual(x->type, y->type) && (x->bsdName == y->bsdName || (x->bsdName && y->bsdName && CFEqual(x->bsdName, y->bsdName)));
}
static CFHashCode interfaceHash(CFTypeRef a)
{
	Interface *i = (Interface *)a;
	return i->bsdName ? CFHash(i->bsdName) : CFHash(i->type);
}
static CFStringRef interfaceDescription(CFTypeRef o)
{
	Interface *i = (Interface *)o;
	return CFStringCreateWithFormat(NULL, NULL, CFSTR("<SCNetworkInterface %p> { type = %@, entity_device = %@, name = %@ }"),
	    o, i->type, i->bsdName, i->displayName);
}
SC_DEFINE_TYPE(SCNetworkInterfaceGetTypeID, "SCNetworkInterface", interfaceFree, interfaceEqual, interfaceHash, interfaceDescription)

static Interface *interfaceCreate(CFStringRef bsdName, CFStringRef type, CFStringRef displayName)
{
	Interface *i = (Interface *)_SCCreateInstance(SCNetworkInterfaceGetTypeID(), sizeof(*i));
	i->bsdName = bsdName ? CFRetain(bsdName) : NULL;
	i->type = CFRetain(type);
	i->displayName = displayName ? CFRetain(displayName) : NULL;
	return i;
}

/* kSCNetworkInterfaceIPv4 (SCInterfaceIPv4.c): the virtual interface
 * IPv4-only services sit on. */
const void *_SCCreateIPv4Interface(void);
const void *_SCCreateIPv4Interface(void)
{
	return interfaceCreate(NULL, kSCNetworkInterfaceTypeIPv4, NULL);
}

/* The kernel's interfaces as SCNetworkInterfaceCopyAll reports them: real
 * network hardware, not loopback, tunnels or the kernel's private ones. */
static bool listed(const char *name, CFStringRef *type, CFStringRef *display)
{
	if (!strncmp(name, "en", 2)) {
		*type = kSCNetworkInterfaceTypeEthernet;
		*display = CFSTR("Ethernet");
		return true;
	}
	if (!strncmp(name, "bridge", 6)) {
		*type = kSCNetworkInterfaceTypeBridge;
		*display = CFSTR("Bridge");
		return true;
	}
	if (!strncmp(name, "bond", 4)) {
		*type = kSCNetworkInterfaceTypeBond;
		*display = CFSTR("Bond");
		return true;
	}
	if (!strncmp(name, "vlan", 4)) {
		*type = kSCNetworkInterfaceTypeVLAN;
		*display = CFSTR("VLAN");
		return true;
	}
	return false;
}

CFArrayRef SCNetworkInterfaceCopyAll(void)
{
	CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	struct ifaddrs *ifa = NULL;
	if (getifaddrs(&ifa) < 0)
		return out;
	for (struct ifaddrs *i = ifa; i; i = i->ifa_next) {
		if (!i->ifa_addr || i->ifa_addr->sa_family != AF_LINK || (i->ifa_flags & IFF_LOOPBACK))
			continue;
		CFStringRef type, display;
		if (!listed(i->ifa_name, &type, &display))
			continue;
		CFStringRef name = CFStringCreateWithCString(NULL, i->ifa_name, kCFStringEncodingUTF8);
		Interface *x = interfaceCreate(name, type, display);
		CFRelease(name);
		struct sockaddr_dl *sdl = (struct sockaddr_dl *)i->ifa_addr;
		if (sdl->sdl_alen == 6) {
			const unsigned char *m = (const unsigned char *)LLADDR(sdl);
			x->hardwareAddress = CFStringCreateWithFormat(NULL, NULL, CFSTR("%02x:%02x:%02x:%02x:%02x:%02x"), m[0], m[1], m[2], m[3], m[4], m[5]);
		}
		CFArrayAppendValue(out, x);
		CFRelease(x);
	}
	freeifaddrs(ifa);
	return out;
}

SCNetworkInterfaceRef _SCNetworkInterfaceCreateFromConfiguration(CFDictionaryRef config)
{
	CFStringRef device = CFDictionaryGetValue(config, kSCPropNetInterfaceDeviceName);
	CFStringRef hardware = CFDictionaryGetValue(config, kSCPropNetInterfaceHardware);
	CFStringRef type = CFDictionaryGetValue(config, kSCPropNetInterfaceType);
	CFStringRef name = CFDictionaryGetValue(config, kSCPropUserDefinedName);
	CFStringRef scType = kSCNetworkInterfaceTypeEthernet;
	if (hardware && CFEqual(hardware, kSCEntNetAirPort))
		scType = kSCNetworkInterfaceTypeIEEE80211;
	else if (type && CFEqual(type, kSCValNetInterfaceTypePPP))
		scType = kSCNetworkInterfaceTypePPP;
	else if (hardware && CFGetTypeID(hardware) == CFStringGetTypeID())
		scType = hardware;
	else if (type && CFGetTypeID(type) == CFStringGetTypeID())
		scType = type;
	Interface *i = interfaceCreate(device, scType, name);
	i->configuration = CFRetain(config);
	return (SCNetworkInterfaceRef)i;
}

static SCNetworkInterfaceRef interfaceCreateForService(CFDictionaryRef config, SCPreferencesRef prefs,
	    CFStringRef serviceID)
{
	Interface *i = (Interface *)_SCNetworkInterfaceCreateFromConfiguration(config);
	i->prefs = (SCPreferencesRef)CFRetain(prefs);
	i->serviceID = CFRetain(serviceID);
	return (SCNetworkInterfaceRef)i;
}

static Interface *validInterface(SCNetworkInterfaceRef i)
{
	if (i && CFGetTypeID(i) == SCNetworkInterfaceGetTypeID())
		return (Interface *)i;
	_SCErrorSet(kSCStatusInvalidArgument);
	return NULL;
}

static CFDictionaryRef pathValue(SCPreferencesRef prefs, CFStringRef fmt, ...) CF_FORMAT_FUNCTION(2, 3);
static CFStringRef defaultConfigurationType(Interface *interface);
static CFArrayRef interfaceConfigurationPaths(Interface *interface, CFStringRef entity);
static bool validExtendedConfigurationType(Interface *interface, CFStringRef entity);
static Boolean setInterfaceConfiguration(Interface *interface, CFStringRef entity, CFDictionaryRef config);

CFStringRef SCNetworkInterfaceGetBSDName(SCNetworkInterfaceRef interface)
{
	Interface *i = validInterface(interface);
	return i ? i->bsdName : NULL;
}

CFStringRef SCNetworkInterfaceGetInterfaceType(SCNetworkInterfaceRef interface)
{
	Interface *i = validInterface(interface);
	return i ? i->type : NULL;
}

CFStringRef SCNetworkInterfaceGetLocalizedDisplayName(SCNetworkInterfaceRef interface)
{
	Interface *i = validInterface(interface);
	return i ? i->displayName : NULL;
}

CFStringRef SCNetworkInterfaceGetHardwareAddressString(SCNetworkInterfaceRef interface)
{
	Interface *i = validInterface(interface);
	return i ? i->hardwareAddress : NULL;
}

/* Finch's interfaces don't layer (no PPP over Ethernet yet). */
SCNetworkInterfaceRef SCNetworkInterfaceGetInterface(SCNetworkInterfaceRef interface)
{
	Interface *i = validInterface(interface);
	return i ? i->child : NULL;
}

CFDictionaryRef SCNetworkInterfaceGetConfiguration(SCNetworkInterfaceRef interface)
{
	Interface *i = validInterface(interface);
	if (!i)
		return NULL;
	CFArrayRef paths = interfaceConfigurationPaths(i, defaultConfigurationType(i));
	CFDictionaryRef config = paths && CFArrayGetCount(paths)
	    ? SCPreferencesPathGetValue(i->prefs, CFArrayGetValueAtIndex(paths, 0)) : NULL;
	if (paths)
		CFRelease(paths);
	if (config && CFDictionaryGetCount(config) == 0)
		config = NULL;
	_SCErrorSet(kSCStatusOK);
	return config;
}

CFDictionaryRef SCNetworkInterfaceGetExtendedConfiguration(SCNetworkInterfaceRef interface, CFStringRef extendedType)
{
	Interface *i = validInterface(interface);
	if (!i || !extendedType || CFGetTypeID(extendedType) != CFStringGetTypeID()) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return NULL;
	}
	if (!validExtendedConfigurationType(i, extendedType)) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return NULL;
	}
	CFArrayRef paths = interfaceConfigurationPaths(i, extendedType);
	CFDictionaryRef config = paths && CFArrayGetCount(paths)
	    ? SCPreferencesPathGetValue(i->prefs, CFArrayGetValueAtIndex(paths, 0)) : NULL;
	if (paths)
		CFRelease(paths);
	if (config && CFDictionaryGetCount(config) == 0)
		config = NULL;
	_SCErrorSet(kSCStatusOK);
	return config;
}

Boolean SCNetworkInterfaceSetConfiguration(SCNetworkInterfaceRef interface, CFDictionaryRef config)
{
	Interface *i = validInterface(interface);
	if (!i || (config && CFGetTypeID(config) != CFDictionaryGetTypeID())) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return false;
	}
	return setInterfaceConfiguration(i, defaultConfigurationType(i), config);
}

Boolean SCNetworkInterfaceSetExtendedConfiguration(SCNetworkInterfaceRef interface, CFStringRef extendedType,
	    CFDictionaryRef config)
{
	Interface *i = validInterface(interface);
	if (!i || !extendedType || CFGetTypeID(extendedType) != CFStringGetTypeID() ||
	    (config && CFGetTypeID(config) != CFDictionaryGetTypeID())) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return false;
	}
	if (!validExtendedConfigurationType(i, extendedType)) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return false;
	}
	return setInterfaceConfiguration(i, extendedType, config);
}

Boolean SCNetworkInterfaceCopyMTU(SCNetworkInterfaceRef interface, int *current, int *minimum, int *maximum)
{
	Interface *i = validInterface(interface);
	if (!i || !i->bsdName) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return false;
	}
	struct ifreq request = {0};
	if (!CFStringGetCString(i->bsdName, request.ifr_name, sizeof(request.ifr_name), kCFStringEncodingASCII)) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return false;
	}
	int fd = socket(AF_INET, SOCK_DGRAM, 0);
	if (fd < 0) {
		_SCErrorSet(errno);
		return false;
	}
	if (ioctl(fd, SIOCGIFMTU, &request) < 0) {
		int error = errno;
		close(fd);
		_SCErrorSet(error);
		return false;
	}
	int mtu = request.ifr_mtu;
	if (current) *current = mtu;
	if (minimum) *minimum = mtu;
	if (maximum) *maximum = mtu;
	if ((minimum || maximum) && ioctl(fd, SIOCGIFDEVMTU, &request) == 0) {
		if (minimum) *minimum = request.ifr_devmtu.ifdm_min > IF_MINMTU ? request.ifr_devmtu.ifdm_min : IF_MINMTU;
		if (maximum) *maximum = request.ifr_devmtu.ifdm_max;
		if (minimum && *minimum < IP_MSS) *minimum = IP_MSS;
		if (minimum && *minimum < IPV6_MMTU) *minimum = IPV6_MMTU;
		if (minimum && *minimum > mtu) *minimum = mtu;
		if (minimum && maximum && *minimum > *maximum) *minimum = *maximum;
	}
	close(fd);
	_SCErrorSet(kSCStatusOK);
	return true;
}

Boolean SCNetworkInterfaceSetMTU(SCNetworkInterfaceRef interface, int mtu)
{
	Interface *i = validInterface(interface);
	if (!i)
		return false;
	int minimum, maximum;
	if (!SCNetworkInterfaceCopyMTU(interface, NULL, &minimum, &maximum))
		return false;
	if (mtu != 0 && (mtu < minimum || mtu > maximum)) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return false;
	}
	CFDictionaryRef old = SCNetworkInterfaceGetConfiguration(interface);
	CFMutableDictionaryRef changed = old ? CFDictionaryCreateMutableCopy(NULL, 0, old)
	    : CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFDictionaryRemoveValue(changed, kSCResvInactive);
	if (mtu == 0) {
		CFDictionaryRemoveValue(changed, kSCPropNetEthernetMTU);
	} else {
		CFNumberRef number = CFNumberCreate(NULL, kCFNumberIntType, &mtu);
		CFDictionarySetValue(changed, kSCPropNetEthernetMTU, number);
		CFRelease(number);
	}
	Boolean ok = SCNetworkInterfaceSetConfiguration(interface,
	    CFDictionaryGetCount(changed) ? changed : NULL);
	CFRelease(changed);
	return ok;
}

CFArrayRef SCNetworkInterfaceGetSupportedInterfaceTypes(SCNetworkInterfaceRef interface)
{
	return NULL;
}

CFArrayRef SCNetworkInterfaceGetSupportedProtocolTypes(SCNetworkInterfaceRef interface)
{
	Interface *i = validInterface(interface);
	if (!i)
		return NULL;
	static CFArrayRef types;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		const void *t[] = {kSCNetworkProtocolTypeDNS, kSCNetworkProtocolTypeIPv4, kSCNetworkProtocolTypeIPv6,
		    kSCNetworkProtocolTypeProxies, kSCNetworkProtocolTypeSMB};
		types = CFArrayCreate(NULL, t, 5, &kCFTypeArrayCallBacks);
	});
	return types;
}

CFArrayRef SCNetworkInterfaceCopyMediaSubTypes(CFArrayRef available)
{
	if (!available || CFGetTypeID(available) != CFArrayGetTypeID()) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return NULL;
	}
	CFMutableArrayRef subtypes = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	for (CFIndex i = 0; i < CFArrayGetCount(available); i++) {
		CFTypeRef item = CFArrayGetValueAtIndex(available, i);
		if (CFGetTypeID(item) != CFDictionaryGetTypeID())
			continue;
		CFTypeRef subtype = CFDictionaryGetValue(item, kSCPropNetEthernetMediaSubType);
		if (subtype && CFGetTypeID(subtype) == CFStringGetTypeID() &&
		    !CFArrayContainsValue(subtypes, CFRangeMake(0, CFArrayGetCount(subtypes)), subtype))
			CFArrayAppendValue(subtypes, subtype);
	}
	if (CFArrayGetCount(subtypes) == 0) {
		CFRelease(subtypes);
		_SCErrorSet(kSCStatusOK);
		return NULL;
	}
	_SCErrorSet(kSCStatusOK);
	return subtypes;
}

CFArrayRef SCNetworkInterfaceCopyMediaSubTypeOptions(CFArrayRef available, CFStringRef subtype)
{
	if (!available || CFGetTypeID(available) != CFArrayGetTypeID() || !subtype ||
	    CFGetTypeID(subtype) != CFStringGetTypeID()) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return NULL;
	}
	CFMutableArrayRef options = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	for (CFIndex i = 0; i < CFArrayGetCount(available); i++) {
		CFTypeRef item = CFArrayGetValueAtIndex(available, i);
		if (CFGetTypeID(item) != CFDictionaryGetTypeID())
			continue;
		CFTypeRef itemSubtype = CFDictionaryGetValue(item, kSCPropNetEthernetMediaSubType);
		CFTypeRef itemOptions = CFDictionaryGetValue(item, kSCPropNetEthernetMediaOptions);
		if (!itemSubtype || CFGetTypeID(itemSubtype) != CFStringGetTypeID() || !CFEqual(itemSubtype, subtype) ||
		    !itemOptions || CFGetTypeID(itemOptions) != CFArrayGetTypeID())
			continue;
		if (!CFArrayContainsValue(options, CFRangeMake(0, CFArrayGetCount(options)), itemOptions))
			CFArrayAppendValue(options, itemOptions);
	}
	if (CFArrayGetCount(options) == 0) {
		CFRelease(options);
		_SCErrorSet(kSCStatusOK);
		return NULL;
	}
	_SCErrorSet(kSCStatusOK);
	return options;
}

/* ---- Sets, services and protocols over a preferences session ---- */

typedef struct {
	CFRuntimeBase base;
	SCPreferencesRef prefs;
	CFStringRef id;
	CFStringRef protocolType;   /* protocols: the entity; services: NULL */
	CFStringRef serviceID;      /* protocols: their service */
	SCNetworkInterfaceRef interface;
} NetObject;

static void netFree(CFTypeRef o)
{
	NetObject *n = (NetObject *)o;
	CFTypeRef refs[] = {n->prefs, n->id, n->protocolType, n->serviceID, n->interface};
	for (size_t k = 0; k < sizeof(refs) / sizeof(*refs); k++)
		if (refs[k])
			CFRelease(refs[k]);
}
static Boolean netEqual(CFTypeRef a, CFTypeRef b)
{
	NetObject *x = (NetObject *)a, *y = (NetObject *)b;
	return CFEqual(x->id, y->id) && x->prefs == y->prefs;
}
static CFHashCode netHash(CFTypeRef a)
{
	return CFHash(((NetObject *)a)->id);
}
SC_DEFINE_TYPE(SCNetworkSetGetTypeID, "SCNetworkSet", netFree, netEqual, netHash, NULL)
SC_DEFINE_TYPE(SCNetworkServiceGetTypeID, "SCNetworkService", netFree, netEqual, netHash, NULL)
SC_DEFINE_TYPE(SCNetworkProtocolGetTypeID, "SCNetworkProtocol", netFree, netEqual, netHash, NULL)

static NetObject *netCreate(CFTypeID type, SCPreferencesRef prefs, CFStringRef id)
{
	NetObject *n = (NetObject *)_SCCreateInstance(type, sizeof(*n));
	n->prefs = (SCPreferencesRef)CFRetain(prefs);
	n->id = CFRetain(id);
	return n;
}

static NetObject *validNet(CFTypeRef o, CFTypeID type)
{
	if (o && CFGetTypeID(o) == type)
		return (NetObject *)o;
	_SCErrorSet(kSCStatusInvalidArgument);
	return NULL;
}

static CFDictionaryRef pathValue(SCPreferencesRef prefs, CFStringRef fmt, ...) CF_FORMAT_FUNCTION(2, 3);
static CFDictionaryRef pathValue(SCPreferencesRef prefs, CFStringRef fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	CFStringRef path = CFStringCreateWithFormatAndArguments(NULL, NULL, fmt, ap);
	va_end(ap);
	CFDictionaryRef d = SCPreferencesPathGetValue(prefs, path);
	CFRelease(path);
	return d;
}

static CFStringRef createChildID(SCPreferencesRef prefs, CFStringRef parent)
{
	CFStringRef path = SCPreferencesPathCreateUniqueChild(prefs, parent);
	if (!path)
		return NULL;
	CFArrayRef parts = CFStringCreateArrayBySeparatingStrings(NULL, path, CFSTR("/"));
	CFRelease(path);
	CFIndex count = CFArrayGetCount(parts);
	CFStringRef id = count ? CFRetain(CFArrayGetValueAtIndex(parts, count - 1)) : NULL;
	CFRelease(parts);
	return id;
}

static CFStringRef defaultConfigurationType(Interface *interface)
{
	if (CFEqual(interface->type, kSCNetworkInterfaceTypeIEEE80211))
		return kSCEntNetAirPort;
	if (CFEqual(interface->type, kSCNetworkInterfaceTypePPP))
		return kSCEntNetPPP;
	if (CFEqual(interface->type, kSCNetworkInterfaceTypeEthernet) ||
	    CFEqual(interface->type, kSCNetworkInterfaceTypeBond) ||
	    CFEqual(interface->type, kSCNetworkInterfaceTypeBridge) ||
	    CFEqual(interface->type, kSCNetworkInterfaceTypeVLAN))
		return kSCEntNetEthernet;
	if (CFEqual(interface->type, kSCNetworkInterfaceTypeFireWire))
		return kSCEntNetFireWire;
	return interface->type;
}

static bool hasPerInterfaceConfiguration(Interface *interface)
{
	return CFEqual(interface->type, kSCNetworkInterfaceTypeEthernet) ||
	    CFEqual(interface->type, kSCNetworkInterfaceTypeIEEE80211) ||
	    CFEqual(interface->type, kSCNetworkInterfaceTypeBond) ||
	    CFEqual(interface->type, kSCNetworkInterfaceTypeBridge) ||
	    CFEqual(interface->type, kSCNetworkInterfaceTypeVLAN) ||
	    CFEqual(interface->type, kSCNetworkInterfaceTypeFireWire);
}

static bool knownConfigurationEntity(CFStringRef entity)
{
	return CFEqual(entity, kSCEntNet6to4) || CFEqual(entity, kSCEntNetAirPort) ||
	    CFEqual(entity, kSCEntNetEthernet) || CFEqual(entity, kSCEntNetFireWire) ||
	    CFEqual(entity, kSCEntNetIPSec) || CFEqual(entity, kSCEntNetL2TP) ||
	    CFEqual(entity, kSCEntNetModem) || CFEqual(entity, kSCEntNetPPP) || CFEqual(entity, CFSTR("VPN"));
}

static bool validExtendedConfigurationType(Interface *interface, CFStringRef entity)
{
	if (!entity || CFGetTypeID(entity) != CFStringGetTypeID() || !interface->prefs || !interface->serviceID ||
	    !hasPerInterfaceConfiguration(interface) || CFEqual(entity, defaultConfigurationType(interface)) ||
	    knownConfigurationEntity(entity))
		return false;
	return true;
}

static CFArrayRef interfaceConfigurationPaths(Interface *interface, CFStringRef entity)
{
	if (!interface || !interface->prefs || !interface->serviceID || !entity ||
	    CFGetTypeID(entity) != CFStringGetTypeID()) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return NULL;
	}
	CFMutableArrayRef paths = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	if (!hasPerInterfaceConfiguration(interface)) {
		CFStringRef path = CFStringCreateWithFormat(NULL, NULL, CFSTR("/NetworkServices/%@/%@"),
		    interface->serviceID, entity);
		CFArrayAppendValue(paths, path);
		CFRelease(path);
		return paths;
	}
	if (!interface->bsdName) {
		CFRelease(paths);
		_SCErrorSet(kSCStatusNoKey);
		return NULL;
	}
	CFArrayRef sets = SCNetworkSetCopyAll(interface->prefs);
	CFStringRef target = CFStringCreateWithFormat(NULL, NULL, CFSTR("/NetworkServices/%@"), interface->serviceID);
	for (CFIndex i = 0; i < CFArrayGetCount(sets); i++) {
		NetObject *set = (NetObject *)CFArrayGetValueAtIndex(sets, i);
		CFStringRef membership = CFStringCreateWithFormat(NULL, NULL,
		    CFSTR("/Sets/%@/Network/Service/%@"), set->id, interface->serviceID);
		CFStringRef link = SCPreferencesPathGetLink(interface->prefs, membership);
		CFRelease(membership);
		if (link && CFEqual(link, target)) {
			CFStringRef path = CFStringCreateWithFormat(NULL, NULL,
			    CFSTR("/Sets/%@/Network/Interface/%@/%@"), set->id, interface->bsdName, entity);
			CFArrayAppendValue(paths, path);
			CFRelease(path);
		}
	}
	CFRelease(target);
	CFRelease(sets);
	if (CFArrayGetCount(paths) == 0) {
		CFRelease(paths);
		_SCErrorSet(kSCStatusNoKey);
		return NULL;
	}
	return paths;
}

static Boolean setInterfaceConfiguration(Interface *interface, CFStringRef entity, CFDictionaryRef config)
{
	if (!interface->prefs || !interface->serviceID || !entity ||
	    (config && CFGetTypeID(config) != CFDictionaryGetTypeID())) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return false;
	}
	CFArrayRef paths = interfaceConfigurationPaths(interface, entity);
	if (!paths)
		return false;
	Boolean ok = true;
	for (CFIndex i = 0; i < CFArrayGetCount(paths); i++) {
		CFStringRef path = CFArrayGetValueAtIndex(paths, i);
		if (config && CFDictionaryGetCount(config) > 0) {
			ok = SCPreferencesPathSetValue(interface->prefs, path, config);
		} else if (SCPreferencesPathGetValue(interface->prefs, path)) {
			ok = SCPreferencesPathRemoveValue(interface->prefs, path);
		} else {
			_SCErrorSet(kSCStatusOK);
			ok = true;
		}
		if (!ok)
			break;
	}
	CFRelease(paths);
	if (ok)
		_SCErrorSet(kSCStatusOK);
	return ok;
}

static bool validPrefs(SCPreferencesRef prefs)
{
	if (prefs && CFGetTypeID(prefs) == SCPreferencesGetTypeID())
		return true;
	_SCErrorSet(kSCStatusInvalidArgument);
	return false;
}

static CFDictionaryRef serviceDict(NetObject *n);

static CFComparisonResult compareStrings(const void *a, const void *b, void *context)
{
	return CFStringCompare(a, b, 0);
}

static CFArrayRef sortedKeys(CFDictionaryRef d)
{
	CFIndex n = d ? CFDictionaryGetCount(d) : 0;
	const void **keys = malloc(sizeof(void *) * (n ? n : 1));
	if (d)
		CFDictionaryGetKeysAndValues(d, keys, NULL);
	CFMutableArrayRef a = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	for (CFIndex i = 0; i < n; i++)
		if (CFGetTypeID(keys[i]) == CFStringGetTypeID())
			CFArrayAppendValue(a, keys[i]);
	free(keys);
	CFArraySortValues(a, CFRangeMake(0, CFArrayGetCount(a)), compareStrings, NULL);
	return a;
}

SCNetworkSetRef SCNetworkSetCopyCurrent(SCPreferencesRef prefs)
{
	CFStringRef current = SCPreferencesGetValue(prefs, kSCPrefCurrentSet);
	if (!current || CFGetTypeID(current) != CFStringGetTypeID() || !CFStringHasPrefix(current, CFSTR("/Sets/"))) {
		_SCErrorSet(kSCStatusNoKey);
		return NULL;
	}
	CFStringRef id = CFStringCreateWithSubstring(NULL, current, CFRangeMake(6, CFStringGetLength(current) - 6));
	NetObject *set = pathValue(prefs, CFSTR("/Sets/%@"), id) ? netCreate(SCNetworkSetGetTypeID(), prefs, id) : NULL;
	CFRelease(id);
	_SCErrorSet(set ? kSCStatusOK : kSCStatusNoKey);
	return (SCNetworkSetRef)set;
}

SCNetworkSetRef SCNetworkSetCopy(SCPreferencesRef prefs, CFStringRef setID)
{
	if (!setID || !pathValue(prefs, CFSTR("/Sets/%@"), setID)) {
		_SCErrorSet(kSCStatusNoKey);
		return NULL;
	}
	return (SCNetworkSetRef)netCreate(SCNetworkSetGetTypeID(), prefs, setID);
}

CFArrayRef SCNetworkSetCopyAll(SCPreferencesRef prefs)
{
	CFDictionaryRef sets = SCPreferencesGetValue(prefs, kSCPrefSets);
	CFArrayRef ids = sortedKeys(sets && CFGetTypeID(sets) == CFDictionaryGetTypeID() ? sets : NULL);
	CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	for (CFIndex i = 0; i < CFArrayGetCount(ids); i++) {
		NetObject *s = netCreate(SCNetworkSetGetTypeID(), prefs, CFArrayGetValueAtIndex(ids, i));
		CFArrayAppendValue(out, s);
		CFRelease(s);
	}
	CFRelease(ids);
	_SCErrorSet(kSCStatusOK);
	return out;
}

CFStringRef SCNetworkSetGetSetID(SCNetworkSetRef set)
{
	NetObject *n = validNet(set, SCNetworkSetGetTypeID());
	return n ? n->id : NULL;
}

CFStringRef SCNetworkSetGetName(SCNetworkSetRef set)
{
	NetObject *n = validNet(set, SCNetworkSetGetTypeID());
	CFDictionaryRef d = n ? pathValue(n->prefs, CFSTR("/Sets/%@"), n->id) : NULL;
	return d ? CFDictionaryGetValue(d, kSCPropUserDefinedName) : NULL;
}

CFArrayRef SCNetworkSetGetServiceOrder(SCNetworkSetRef set)
{
	NetObject *n = validNet(set, SCNetworkSetGetTypeID());
	CFDictionaryRef d = n ? pathValue(n->prefs, CFSTR("/Sets/%@/Network/Global/IPv4"), n->id) : NULL;
	CFArrayRef order = d ? CFDictionaryGetValue(d, kSCPropNetServiceOrder) : NULL;
	return order && CFGetTypeID(order) == CFArrayGetTypeID() ? order : NULL;
}

SCNetworkSetRef SCNetworkSetCreate(SCPreferencesRef prefs)
{
	if (!validPrefs(prefs))
		return NULL;
	CFStringRef setID = createChildID(prefs, CFSTR("/Sets"));
	if (!setID)
		return NULL;
	CFDictionaryRef empty = CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks,
	    &kCFTypeDictionaryValueCallBacks);
	CFStringRef path = CFStringCreateWithFormat(NULL, NULL, CFSTR("/Sets/%@"), setID);
	Boolean ok = SCPreferencesPathSetValue(prefs, path, empty);
	CFRelease(path);
	CFRelease(empty);
	if (!ok) {
		CFRelease(setID);
		return NULL;
	}
	NetObject *set = netCreate(SCNetworkSetGetTypeID(), prefs, setID);
	CFRelease(setID);
	return (SCNetworkSetRef)set;
}

Boolean SCNetworkSetSetName(SCNetworkSetRef set, CFStringRef name)
{
	NetObject *n = validNet(set, SCNetworkSetGetTypeID());
	if (!n || (name && CFGetTypeID(name) != CFStringGetTypeID())) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return false;
	}
	CFStringRef path = CFStringCreateWithFormat(NULL, NULL, CFSTR("/Sets/%@"), n->id);
	CFDictionaryRef old = SCPreferencesPathGetValue(n->prefs, path);
	if (!old) {
		CFRelease(path);
		_SCErrorSet(kSCStatusInvalidArgument);
		return false;
	}
	if (name) {
		CFArrayRef sets = SCNetworkSetCopyAll(n->prefs);
		for (CFIndex i = 0; i < CFArrayGetCount(sets); i++) {
			SCNetworkSetRef other = CFArrayGetValueAtIndex(sets, i);
			if (CFEqual(SCNetworkSetGetSetID(other), n->id))
				continue;
			CFStringRef otherName = SCNetworkSetGetName(other);
			if (otherName && CFEqual(otherName, name)) {
				CFRelease(sets);
				CFRelease(path);
				_SCErrorSet(kSCStatusKeyExists);
				return false;
			}
		}
		CFRelease(sets);
	}
	CFMutableDictionaryRef changed = CFDictionaryCreateMutableCopy(NULL, 0, old);
	if (name)
		CFDictionarySetValue(changed, kSCPropUserDefinedName, name);
	else
		CFDictionaryRemoveValue(changed, kSCPropUserDefinedName);
	Boolean ok = SCPreferencesPathSetValue(n->prefs, path, changed);
	CFRelease(changed);
	CFRelease(path);
	return ok;
}

Boolean SCNetworkSetSetCurrent(SCNetworkSetRef set)
{
	NetObject *n = validNet(set, SCNetworkSetGetTypeID());
	if (!n || !pathValue(n->prefs, CFSTR("/Sets/%@"), n->id)) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return false;
	}
	CFStringRef path = CFStringCreateWithFormat(NULL, NULL, CFSTR("/Sets/%@"), n->id);
	Boolean ok = SCPreferencesSetValue(n->prefs, kSCPrefCurrentSet, path);
	CFRelease(path);
	return ok;
}

Boolean SCNetworkSetSetServiceOrder(SCNetworkSetRef set, CFArrayRef newOrder)
{
	NetObject *n = validNet(set, SCNetworkSetGetTypeID());
	if (!n || !newOrder || CFGetTypeID(newOrder) != CFArrayGetTypeID()) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return false;
	}
	if (!pathValue(n->prefs, CFSTR("/Sets/%@"), n->id)) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return false;
	}
	CFMutableArrayRef clean = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	for (CFIndex i = 0; i < CFArrayGetCount(newOrder); i++) {
		CFTypeRef value = CFArrayGetValueAtIndex(newOrder, i);
		if (CFGetTypeID(value) != CFStringGetTypeID()) {
			CFRelease(clean);
			_SCErrorSet(kSCStatusInvalidArgument);
			return false;
		}
		if (!CFArrayContainsValue(clean, CFRangeMake(0, CFArrayGetCount(clean)), value))
			CFArrayAppendValue(clean, value);
	}
	CFStringRef path = CFStringCreateWithFormat(NULL, NULL, CFSTR("/Sets/%@/Network/Global/IPv4"), n->id);
	CFDictionaryRef old = SCPreferencesPathGetValue(n->prefs, path);
	CFMutableDictionaryRef changed = old ? CFDictionaryCreateMutableCopy(NULL, 0, old)
	    : CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	if (CFArrayGetCount(clean))
		CFDictionarySetValue(changed, kSCPropNetServiceOrder, clean);
	else
		CFDictionaryRemoveValue(changed, kSCPropNetServiceOrder);
	Boolean ok;
	if (CFDictionaryGetCount(changed))
		ok = SCPreferencesPathSetValue(n->prefs, path, changed);
	else if (old)
		ok = SCPreferencesPathRemoveValue(n->prefs, path);
	else {
		_SCErrorSet(kSCStatusOK);
		ok = true;
	}
	CFRelease(changed);
	CFRelease(clean);
	CFRelease(path);
	return ok;
}

Boolean SCNetworkSetAddService(SCNetworkSetRef set, SCNetworkServiceRef service)
{
	NetObject *s = validNet(set, SCNetworkSetGetTypeID());
	NetObject *v = validNet(service, SCNetworkServiceGetTypeID());
	if (!s || !v || s->prefs != v->prefs ||
	    !pathValue(s->prefs, CFSTR("/Sets/%@"), s->id) || !serviceDict(v)) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return false;
	}
	CFStringRef entry = CFStringCreateWithFormat(NULL, NULL, CFSTR("/Sets/%@/Network/Service/%@"), s->id, v->id);
	CFStringRef link = CFStringCreateWithFormat(NULL, NULL, CFSTR("/NetworkServices/%@"), v->id);
	CFStringRef old = SCPreferencesPathGetLink(s->prefs, entry);
	if (old && CFEqual(old, link)) {
		CFRelease(link);
		CFRelease(entry);
		_SCErrorSet(kSCStatusOK);
		return true;
	}
	Boolean ok = SCPreferencesPathSetLink(s->prefs, entry, link);
	CFRelease(link);
	CFRelease(entry);
	if (!ok)
		return false;
	CFArrayRef order = SCNetworkSetGetServiceOrder(set);
	CFMutableArrayRef changed = order ? CFArrayCreateMutableCopy(NULL, 0, order)
	    : CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	if (!CFArrayContainsValue(changed, CFRangeMake(0, CFArrayGetCount(changed)), v->id))
		CFArrayAppendValue(changed, v->id);
	ok = SCNetworkSetSetServiceOrder(set, changed);
	CFRelease(changed);
	return ok;
}

Boolean SCNetworkSetContainsInterface(SCNetworkSetRef set, SCNetworkInterfaceRef interface)
{
	NetObject *n = validNet(set, SCNetworkSetGetTypeID());
	if (!n || !validInterface(interface))
		return false;
	CFArrayRef services = SCNetworkSetCopyServices(set);
	if (!services)
		return false;
	Boolean found = false;
	for (CFIndex i = 0; i < CFArrayGetCount(services); i++) {
		SCNetworkInterfaceRef candidate = SCNetworkServiceGetInterface(CFArrayGetValueAtIndex(services, i));
		if (candidate && CFEqual(candidate, interface)) {
			found = true;
			break;
		}
	}
	CFRelease(services);
	_SCErrorSet(kSCStatusOK);
	return found;
}

Boolean SCNetworkSetRemoveService(SCNetworkSetRef set, SCNetworkServiceRef service)
{
	NetObject *s = validNet(set, SCNetworkSetGetTypeID());
	NetObject *v = validNet(service, SCNetworkServiceGetTypeID());
	if (!s || !v || s->prefs != v->prefs || !serviceDict(v) ||
	    !pathValue(s->prefs, CFSTR("/Sets/%@"), s->id)) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return false;
	}
	CFStringRef entry = CFStringCreateWithFormat(NULL, NULL, CFSTR("/Sets/%@/Network/Service/%@"), s->id, v->id);
	CFStringRef oldLink = SCPreferencesPathGetLink(s->prefs, entry);
	Boolean ok = true;
	if (oldLink)
		ok = SCPreferencesPathRemoveValue(s->prefs, entry);
	CFRelease(entry);
	if (!ok)
		return false;
	CFArrayRef order = SCNetworkSetGetServiceOrder(set);
	if (order) {
		CFMutableArrayRef changed = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
		for (CFIndex i = 0; i < CFArrayGetCount(order); i++) {
			CFTypeRef item = CFArrayGetValueAtIndex(order, i);
			if (!CFEqual(item, v->id))
				CFArrayAppendValue(changed, item);
		}
		ok = SCNetworkSetSetServiceOrder(set, changed);
		CFRelease(changed);
	}
	if (ok)
		_SCErrorSet(kSCStatusOK);
	return ok;
}

Boolean SCNetworkSetRemove(SCNetworkSetRef set)
{
	NetObject *n = validNet(set, SCNetworkSetGetTypeID());
	if (!n) return false;
	CFStringRef path = CFStringCreateWithFormat(NULL, NULL, CFSTR("/Sets/%@"), n->id);
	if (!SCPreferencesPathGetValue(n->prefs, path)) {
		CFRelease(path);
		_SCErrorSet(kSCStatusInvalidArgument);
		return false;
	}
	CFTypeRef current = SCPreferencesGetValue(n->prefs, kSCPrefCurrentSet);
	if (current && CFGetTypeID(current) == CFStringGetTypeID() && CFEqual(current, path))
		SCPreferencesRemoveValue(n->prefs, kSCPrefCurrentSet);
	Boolean ok = SCPreferencesPathRemoveValue(n->prefs, path);
	CFRelease(path);
	return ok;
}

CFArrayRef SCNetworkSetCopyServices(SCNetworkSetRef set)
{
	NetObject *n = validNet(set, SCNetworkSetGetTypeID());
	if (!n)
		return NULL;
	CFStringRef base = CFStringCreateWithFormat(NULL, NULL, CFSTR("/Sets/%@/Network/Service"), n->id);
	CFDictionaryRef services = SCPreferencesPathGetValue(n->prefs, base);
	CFArrayRef ids = sortedKeys(services);
	CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	for (CFIndex i = 0; i < CFArrayGetCount(ids); i++) {
		CFStringRef path = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@/%@"), base, CFArrayGetValueAtIndex(ids, i));
		CFStringRef link = SCPreferencesPathGetLink(n->prefs, path);
		CFRelease(path);
		CFStringRef sid = link && CFStringHasPrefix(link, CFSTR("/NetworkServices/"))
		    ? CFStringCreateWithSubstring(NULL, link, CFRangeMake(17, CFStringGetLength(link) - 17))
		    : CFRetain(CFArrayGetValueAtIndex(ids, i));
		NetObject *s = netCreate(SCNetworkServiceGetTypeID(), n->prefs, sid);
		CFArrayAppendValue(out, s);
		CFRelease(s);
		CFRelease(sid);
	}
	CFRelease(ids);
	CFRelease(base);
	_SCErrorSet(kSCStatusOK);
	return out;
}

SCNetworkServiceRef SCNetworkServiceCreate(SCPreferencesRef prefs, SCNetworkInterfaceRef interface)
{
	if (!validPrefs(prefs) || !validInterface(interface))
		return NULL;

	CFDictionaryRef config = ((Interface *)interface)->configuration;
	CFMutableDictionaryRef newConfig = config ? CFDictionaryCreateMutableCopy(NULL, 0, config)
	    : CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	Interface *i = (Interface *)interface;
	if (i->bsdName)
		CFDictionarySetValue(newConfig, kSCPropNetInterfaceDeviceName, i->bsdName);
	if (i->type) {
		CFDictionarySetValue(newConfig, kSCPropNetInterfaceType, i->type);
		if (CFEqual(i->type, kSCNetworkInterfaceTypeIEEE80211))
			CFDictionarySetValue(newConfig, kSCPropNetInterfaceHardware, kSCEntNetAirPort);
		else
			CFDictionarySetValue(newConfig, kSCPropNetInterfaceHardware, i->type);
	}
	if (i->displayName)
		CFDictionarySetValue(newConfig, kSCPropUserDefinedName, i->displayName);

	CFStringRef serviceID = createChildID(prefs, CFSTR("/NetworkServices"));
	if (!serviceID) {
		CFRelease(newConfig);
		return NULL;
	}
	CFMutableDictionaryRef record = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
	    &kCFTypeDictionaryValueCallBacks);
	CFDictionarySetValue(record, kSCEntNetInterface, newConfig);
	if (i->displayName)
		CFDictionarySetValue(record, kSCPropUserDefinedName, i->displayName);
	CFStringRef path = CFStringCreateWithFormat(NULL, NULL, CFSTR("/NetworkServices/%@"), serviceID);
	Boolean ok = SCPreferencesPathSetValue(prefs, path, record);
	CFRelease(path);
	CFRelease(record);
	if (!ok) {
		CFRelease(newConfig);
		CFRelease(serviceID);
		return NULL;
	}
	NetObject *service = netCreate(SCNetworkServiceGetTypeID(), prefs, serviceID);
	service->interface = interfaceCreateForService(newConfig, prefs, serviceID);
	CFRelease(newConfig);
	CFRelease(serviceID);
	return (SCNetworkServiceRef)service;
}

CFArrayRef SCNetworkServiceCopyAll(SCPreferencesRef prefs)
{
	CFDictionaryRef services = SCPreferencesGetValue(prefs, kSCPrefNetworkServices);
	CFArrayRef ids = sortedKeys(services && CFGetTypeID(services) == CFDictionaryGetTypeID() ? services : NULL);
	CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	for (CFIndex i = 0; i < CFArrayGetCount(ids); i++) {
		NetObject *s = netCreate(SCNetworkServiceGetTypeID(), prefs, CFArrayGetValueAtIndex(ids, i));
		CFArrayAppendValue(out, s);
		CFRelease(s);
	}
	CFRelease(ids);
	_SCErrorSet(kSCStatusOK);
	return out;
}

SCNetworkServiceRef SCNetworkServiceCopy(SCPreferencesRef prefs, CFStringRef serviceID)
{
	if (!serviceID || !pathValue(prefs, CFSTR("/NetworkServices/%@"), serviceID)) {
		_SCErrorSet(kSCStatusNoKey);
		return NULL;
	}
	return (SCNetworkServiceRef)netCreate(SCNetworkServiceGetTypeID(), prefs, serviceID);
}

static CFDictionaryRef serviceDict(NetObject *n)
{
	return n ? pathValue(n->prefs, CFSTR("/NetworkServices/%@"), n->id) : NULL;
}

CFStringRef SCNetworkServiceGetServiceID(SCNetworkServiceRef service)
{
	NetObject *n = validNet(service, SCNetworkServiceGetTypeID());
	return n ? n->id : NULL;
}

CFStringRef SCNetworkServiceGetName(SCNetworkServiceRef service)
{
	CFDictionaryRef d = serviceDict(validNet(service, SCNetworkServiceGetTypeID()));
	return d ? CFDictionaryGetValue(d, kSCPropUserDefinedName) : NULL;
}

Boolean SCNetworkServiceGetEnabled(SCNetworkServiceRef service)
{
	CFDictionaryRef d = serviceDict(validNet(service, SCNetworkServiceGetTypeID()));
	return d && !CFDictionaryContainsKey(d, kSCResvInactive);
}

SCNetworkInterfaceRef SCNetworkServiceGetInterface(SCNetworkServiceRef service)
{
	NetObject *n = validNet(service, SCNetworkServiceGetTypeID());
	CFDictionaryRef d = serviceDict(n);
	CFDictionaryRef config = d ? CFDictionaryGetValue(d, kSCEntNetInterface) : NULL;
	if (!config || CFGetTypeID(config) != CFDictionaryGetTypeID())
		return NULL;
	if (!n->interface)
		n->interface = interfaceCreateForService(config, n->prefs, n->id);
	return n->interface;
}

static bool isProtocolEntity(CFStringRef k)
{
	return CFEqual(k, kSCNetworkProtocolTypeDNS) || CFEqual(k, kSCNetworkProtocolTypeIPv4) ||
	    CFEqual(k, kSCNetworkProtocolTypeIPv6) || CFEqual(k, kSCNetworkProtocolTypeProxies) ||
	    CFEqual(k, kSCNetworkProtocolTypeSMB);
}

static SCNetworkProtocolRef protocolCreate(NetObject *service, CFStringRef type)
{
	CFStringRef id = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@/%@"), service->id, type);
	NetObject *p = netCreate(SCNetworkProtocolGetTypeID(), service->prefs, id);
	CFRelease(id);
	p->protocolType = CFRetain(type);
	p->serviceID = CFRetain(service->id);
	return (SCNetworkProtocolRef)p;
}

CFArrayRef SCNetworkServiceCopyProtocols(SCNetworkServiceRef service)
{
	NetObject *n = validNet(service, SCNetworkServiceGetTypeID());
	CFDictionaryRef d = serviceDict(n);
	if (!d)
		return NULL;
	CFArrayRef keys = sortedKeys(d);
	CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	for (CFIndex i = 0; i < CFArrayGetCount(keys); i++)
		if (isProtocolEntity(CFArrayGetValueAtIndex(keys, i))) {
			SCNetworkProtocolRef p = protocolCreate(n, CFArrayGetValueAtIndex(keys, i));
			CFArrayAppendValue(out, p);
			CFRelease(p);
		}
	CFRelease(keys);
	return out;
}

SCNetworkProtocolRef SCNetworkServiceCopyProtocol(SCNetworkServiceRef service, CFStringRef protocolType)
{
	NetObject *n = validNet(service, SCNetworkServiceGetTypeID());
	CFDictionaryRef d = serviceDict(n);
	if (!d || !protocolType || !CFDictionaryGetValue(d, protocolType)) {
		_SCErrorSet(kSCStatusNoKey);
		return NULL;
	}
	return protocolCreate(n, protocolType);
}

static CFDictionaryRef protocolDict(NetObject *p)
{
	return p ? pathValue(p->prefs, CFSTR("/NetworkServices/%@/%@"), p->serviceID, p->protocolType) : NULL;
}

static bool validProtocolType(CFStringRef type)
{
	return type && CFGetTypeID(type) == CFStringGetTypeID() && isProtocolEntity(type);
}

static CFDictionaryRef defaultProtocolConfiguration(CFStringRef type)
{
	CFMutableDictionaryRef config = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
	    &kCFTypeDictionaryValueCallBacks);
	if (CFEqual(type, kSCNetworkProtocolTypeIPv4))
		CFDictionarySetValue(config, kSCPropNetIPv4ConfigMethod, kSCValNetIPv4ConfigMethodDHCP);
	else if (CFEqual(type, kSCNetworkProtocolTypeIPv6))
		CFDictionarySetValue(config, kSCPropNetIPv6ConfigMethod, kSCValNetIPv6ConfigMethodAutomatic);
	return config;
}

Boolean SCNetworkServiceAddProtocolType(SCNetworkServiceRef service, CFStringRef protocolType)
{
	NetObject *n = validNet(service, SCNetworkServiceGetTypeID());
	if (!n || !validProtocolType(protocolType)) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return false;
	}
	if (!serviceDict(n)) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return false;
	}
	CFStringRef path = CFStringCreateWithFormat(NULL, NULL, CFSTR("/NetworkServices/%@/%@"), n->id,
	    protocolType);
	if (SCPreferencesPathGetValue(n->prefs, path)) {
		CFRelease(path);
		_SCErrorSet(kSCStatusKeyExists);
		return false;
	}
	CFDictionaryRef config = defaultProtocolConfiguration(protocolType);
	Boolean ok = SCPreferencesPathSetValue(n->prefs, path, config);
	CFRelease(config);
	CFRelease(path);
	return ok;
}

Boolean SCNetworkServiceRemoveProtocolType(SCNetworkServiceRef service, CFStringRef protocolType)
{
	NetObject *n = validNet(service, SCNetworkServiceGetTypeID());
	if (!n || !validProtocolType(protocolType)) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return false;
	}
	if (!serviceDict(n)) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return false;
	}
	CFStringRef path = CFStringCreateWithFormat(NULL, NULL, CFSTR("/NetworkServices/%@/%@"), n->id,
	    protocolType);
	if (!SCPreferencesPathGetValue(n->prefs, path)) {
		CFRelease(path);
		_SCErrorSet(kSCStatusNoKey);
		return false;
	}
	Boolean ok = SCPreferencesPathRemoveValue(n->prefs, path);
	CFRelease(path);
	return ok;
}

Boolean SCNetworkServiceEstablishDefaultConfiguration(SCNetworkServiceRef service)
{
	NetObject *n = validNet(service, SCNetworkServiceGetTypeID());
	if (!n || !serviceDict(n)) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return false;
	}
	SCNetworkInterfaceRef interface = SCNetworkServiceGetInterface(service);
	CFArrayRef types = interface ? SCNetworkInterfaceGetSupportedProtocolTypes(interface) : NULL;
	if (!types) {
		_SCErrorSet(kSCStatusFailed);
		return false;
	}
	for (CFIndex i = 0; i < CFArrayGetCount(types); i++) {
		CFStringRef type = CFArrayGetValueAtIndex(types, i);
		if (!pathValue(n->prefs, CFSTR("/NetworkServices/%@/%@"), n->id, type)) {
			if (!SCNetworkServiceAddProtocolType(service, type)) {
				return false;
			}
		}
	}
	_SCErrorSet(kSCStatusOK);
	return true;
}

CFStringRef SCNetworkProtocolGetProtocolType(SCNetworkProtocolRef protocol)
{
	NetObject *p = validNet(protocol, SCNetworkProtocolGetTypeID());
	return p ? p->protocolType : NULL;
}

CFDictionaryRef SCNetworkProtocolGetConfiguration(SCNetworkProtocolRef protocol)
{
	CFDictionaryRef d = protocolDict(validNet(protocol, SCNetworkProtocolGetTypeID()));
	if (!d || !CFDictionaryContainsKey(d, kSCResvInactive))
		return d;
	/* The configuration without the inactive marker. */
	static CFMutableDictionaryRef cache;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		cache = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	});
	CFMutableDictionaryRef copy = CFDictionaryCreateMutableCopy(NULL, 0, d);
	CFDictionaryRemoveValue(copy, kSCResvInactive);
	CFDictionarySetValue(cache, protocol, copy);
	CFRelease(copy);
	return copy;
}

Boolean SCNetworkProtocolGetEnabled(SCNetworkProtocolRef protocol)
{
	CFDictionaryRef d = protocolDict(validNet(protocol, SCNetworkProtocolGetTypeID()));
	return d && !CFDictionaryContainsKey(d, kSCResvInactive);
}

Boolean SCNetworkProtocolSetConfiguration(SCNetworkProtocolRef protocol, CFDictionaryRef config)
{
	NetObject *p = validNet(protocol, SCNetworkProtocolGetTypeID());
	if (!p)
		return false;
	CFStringRef path = CFStringCreateWithFormat(NULL, NULL, CFSTR("/NetworkServices/%@/%@"), p->serviceID, p->protocolType);
	Boolean ok = config ? SCPreferencesPathSetValue(p->prefs, path, config) : SCPreferencesPathRemoveValue(p->prefs, path);
	CFRelease(path);
	return ok;
}

static Boolean setInactive(SCPreferencesRef prefs, CFStringRef path, Boolean enabled)
{
	CFDictionaryRef d = SCPreferencesPathGetValue(prefs, path);
	if (!d)
		return false;
	CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(NULL, 0, d);
	if (enabled)
		CFDictionaryRemoveValue(m, kSCResvInactive);
	else
		CFDictionarySetValue(m, kSCResvInactive, kCFBooleanTrue);
	Boolean ok = SCPreferencesPathSetValue(prefs, path, m);
	CFRelease(m);
	return ok;
}

Boolean SCNetworkProtocolSetEnabled(SCNetworkProtocolRef protocol, Boolean enabled)
{
	NetObject *p = validNet(protocol, SCNetworkProtocolGetTypeID());
	if (!p)
		return false;
	CFStringRef path = CFStringCreateWithFormat(NULL, NULL, CFSTR("/NetworkServices/%@/%@"), p->serviceID, p->protocolType);
	Boolean ok = setInactive(p->prefs, path, enabled);
	CFRelease(path);
	return ok;
}

Boolean SCNetworkServiceSetEnabled(SCNetworkServiceRef service, Boolean enabled)
{
	NetObject *n = validNet(service, SCNetworkServiceGetTypeID());
	if (!n)
		return false;
	CFStringRef path = CFStringCreateWithFormat(NULL, NULL, CFSTR("/NetworkServices/%@"), n->id);
	Boolean ok = setInactive(n->prefs, path, enabled);
	CFRelease(path);
	return ok;
}

Boolean SCNetworkServiceSetName(SCNetworkServiceRef service, CFStringRef name)
{
	NetObject *n = validNet(service, SCNetworkServiceGetTypeID());
	CFDictionaryRef d = serviceDict(n);
	if (!d)
		return false;
	CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(NULL, 0, d);
	if (name)
		CFDictionarySetValue(m, kSCPropUserDefinedName, name);
	else
		CFDictionaryRemoveValue(m, kSCPropUserDefinedName);
	CFStringRef path = CFStringCreateWithFormat(NULL, NULL, CFSTR("/NetworkServices/%@"), n->id);
	Boolean ok = SCPreferencesPathSetValue(n->prefs, path, m);
	CFRelease(path);
	CFRelease(m);
	return ok;
}

Boolean SCNetworkServiceRemove(SCNetworkServiceRef service)
{
	NetObject *n = validNet(service, SCNetworkServiceGetTypeID());
	if (!n || !serviceDict(n)) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return false;
	}
	CFArrayRef sets = SCNetworkSetCopyAll(n->prefs);
	for (CFIndex i = 0; i < CFArrayGetCount(sets); i++) {
		if (!SCNetworkSetRemoveService(CFArrayGetValueAtIndex(sets, i), service)) {
			CFRelease(sets);
			return false;
		}
	}
	CFRelease(sets);
	CFStringRef path = CFStringCreateWithFormat(NULL, NULL, CFSTR("/NetworkServices/%@"), n->id);
	Boolean ok = SCPreferencesPathRemoveValue(n->prefs, path);
	CFRelease(path);
	return ok;
}
