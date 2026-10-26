/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * networksetup, written for Finch (macOS's is closed) over its
 * SystemConfiguration framework: the commands for network services, their
 * IPv4 and DNS settings and the computer name, with macOS's wording and exit
 * status. Settings are saved in configd's preferences and applied.
 *
 *   networksetup -listallnetworkservices | -listnetworkserviceorder
 *   networksetup -listallhardwareports
 *   networksetup -getinfo SERVICE
 *   networksetup -setmanual SERVICE IP SUBNET ROUTER
 *   networksetup -setdhcp SERVICE [CLIENTID]
 *   networksetup -getdnsservers SERVICE
 *   networksetup -setdnsservers SERVICE DNS... | Empty
 *   networksetup -getsearchdomains SERVICE
 *   networksetup -setsearchdomains SERVICE DOMAIN... | Empty
 *   networksetup -setnetworkserviceenabled SERVICE on|off
 *   networksetup -getnetworkserviceenabled SERVICE
 *   networksetup -getcomputername | -setcomputername NAME
 */
#include <CoreFoundation/CoreFoundation.h>
#include <SystemConfiguration/SystemConfiguration.h>

#include <arpa/inet.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define EXIT_BAD_PARAMETERS 4

static char *
cstring(CFStringRef s)
{
	if (s == NULL) {
		return strdup("");
	}
	CFIndex max = CFStringGetMaximumSizeForEncoding(CFStringGetLength(s), kCFStringEncodingUTF8) + 1;
	char *buf = malloc((size_t)max);
	if (buf && !CFStringGetCString(s, buf, max, kCFStringEncodingUTF8)) {
		buf[0] = 0;
	}
	return buf;
}

static CFStringRef
cfstr(const char *s)
{
	return CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8);
}

static int
bad_parameters(void)
{
	printf("** Error: The parameters were not valid.\n");
	return EXIT_BAD_PARAMETERS;
}

/* The preferences, locked for a change when write is set. */
static SCPreferencesRef
open_prefs(bool write)
{
	SCPreferencesRef prefs = SCPreferencesCreate(NULL, CFSTR("networksetup"), NULL);
	if (prefs == NULL) {
		printf("** Error: Unable to open the network settings (%s).\n", SCErrorString(SCError()));
		exit(1);
	}
	if (write && !SCPreferencesLock(prefs, TRUE)) {
		printf("** Error: You cannot set network settings: %s\n", SCErrorString(SCError()));
		exit(14);
	}
	return prefs;
}

static int
save(SCPreferencesRef prefs)
{
	bool ok = SCPreferencesCommitChanges(prefs) && SCPreferencesApplyChanges(prefs);
	if (!ok) {
		printf("** Error: Unable to commit changes to network database.\n");
	}
	SCPreferencesUnlock(prefs);
	CFRelease(prefs);
	return ok ? 0 : 1;
}

/* The current set's services, in its service order. */
static CFArrayRef
services(SCPreferencesRef prefs)
{
	SCNetworkSetRef set = SCNetworkSetCopyCurrent(prefs);
	CFArrayRef list = set ? SCNetworkSetCopyServices(set) : SCNetworkServiceCopyAll(prefs);
	CFArrayRef order = set ? SCNetworkSetGetServiceOrder(set) : NULL;
	CFMutableArrayRef sorted = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);

	if (list != NULL) {
		if (order != NULL) {
			for (CFIndex i = 0; i < CFArrayGetCount(order); i++) {
				for (CFIndex j = 0; j < CFArrayGetCount(list); j++) {
					SCNetworkServiceRef s = (SCNetworkServiceRef)CFArrayGetValueAtIndex(list, j);
					if (CFEqual(SCNetworkServiceGetServiceID(s), CFArrayGetValueAtIndex(order, i))) {
						CFArrayAppendValue(sorted, s);
					}
				}
			}
		}
		/* Without a service order, the set's services as they come; with one,
		   only those it orders (as macOS's lists them). */
		if (order == NULL) {
			CFArrayAppendArray(sorted, list, CFRangeMake(0, CFArrayGetCount(list)));
		}
		CFRelease(list);
	}
	if (set) {
		CFRelease(set);
	}
	return sorted;
}

static SCNetworkServiceRef
find_service(SCPreferencesRef prefs, const char *name)
{
	CFArrayRef list = services(prefs);
	CFStringRef wanted = cfstr(name);
	SCNetworkServiceRef found = NULL;

	for (CFIndex i = 0; i < CFArrayGetCount(list) && !found; i++) {
		SCNetworkServiceRef s = (SCNetworkServiceRef)CFArrayGetValueAtIndex(list, i);
		CFStringRef n = SCNetworkServiceGetName(s);
		if (n && CFStringCompare(n, wanted, 0) == kCFCompareEqualTo) {
			found = (SCNetworkServiceRef)CFRetain(s);
		}
	}
	CFRelease(wanted);
	CFRelease(list);
	if (found == NULL) {
		printf("%s is not a recognized network service.\n", name);
	}
	return found;
}

static int
list_services(bool order)
{
	SCPreferencesRef prefs = open_prefs(false);
	CFArrayRef list = services(prefs);

	if (order) {
		printf("An asterisk (*) denotes that a network service is disabled.\n");
	} else {
		printf("An asterisk (*) denotes that a network service is disabled.\n");
	}
	for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
		SCNetworkServiceRef s = (SCNetworkServiceRef)CFArrayGetValueAtIndex(list, i);
		char *name = cstring(SCNetworkServiceGetName(s));
		const char *mark = SCNetworkServiceGetEnabled(s) ? "" : "*";
		if (order) {
			/* The hardware under any layers (PPP over a modem, ...). */
			SCNetworkInterfaceRef ifc = SCNetworkServiceGetInterface(s);
			while (ifc && SCNetworkInterfaceGetInterface(ifc)) {
				ifc = SCNetworkInterfaceGetInterface(ifc);
			}
			char *port = cstring(ifc ? SCNetworkInterfaceGetLocalizedDisplayName(ifc) : NULL);
			char *dev = cstring(ifc ? SCNetworkInterfaceGetBSDName(ifc) : NULL);
			printf("(%s%ld) %s\n(Hardware Port: %s, Device: %s)\n\n", mark, (long)i + 1, name, port, dev);
			free(port);
			free(dev);
		} else {
			printf("%s%s\n", mark, name);
		}
		free(name);
	}
	CFRelease(list);
	CFRelease(prefs);
	return 0;
}

static int
list_hardware_ports(void)
{
	CFArrayRef all = SCNetworkInterfaceCopyAll();
	for (CFIndex i = 0; all && i < CFArrayGetCount(all); i++) {
		SCNetworkInterfaceRef ifc = (SCNetworkInterfaceRef)CFArrayGetValueAtIndex(all, i);
		char *port = cstring(SCNetworkInterfaceGetLocalizedDisplayName(ifc));
		char *dev = cstring(SCNetworkInterfaceGetBSDName(ifc));
		char *mac = cstring(SCNetworkInterfaceGetHardwareAddressString(ifc));
		printf("\nHardware Port: %s\nDevice: %s\nEthernet Address: %s\n", port, dev, *mac ? mac : "N/A");
		free(port);
		free(dev);
		free(mac);
	}
	printf("\nVLAN Configurations\n===================\n");
	if (all) {
		CFRelease(all);
	}
	return 0;
}

/* The service's configuration for a protocol; *out holds the protocol to release. */
static CFDictionaryRef
protocol_config(SCNetworkServiceRef s, CFStringRef type, SCNetworkProtocolRef *out)
{
	*out = SCNetworkServiceCopyProtocol(s, type);
	return *out ? SCNetworkProtocolGetConfiguration(*out) : NULL;
}

/* The live IPv4 state configd published for the service. */
static CFDictionaryRef
service_state(SCNetworkServiceRef s, CFStringRef entity)
{
	SCDynamicStoreRef store = SCDynamicStoreCreate(NULL, CFSTR("networksetup"), NULL, NULL);
	if (store == NULL) {
		return NULL;
	}
	CFStringRef key = SCDynamicStoreKeyCreateNetworkServiceEntity(NULL, kSCDynamicStoreDomainState,
	    SCNetworkServiceGetServiceID(s), entity);
	CFDictionaryRef v = SCDynamicStoreCopyValue(store, key);
	CFRelease(key);
	CFRelease(store);
	return v;
}

static char *
first_string(CFDictionaryRef d, CFStringRef key)
{
	CFTypeRef v = d ? CFDictionaryGetValue(d, key) : NULL;
	if (v && CFGetTypeID(v) == CFArrayGetTypeID() && CFArrayGetCount(v) > 0) {
		v = CFArrayGetValueAtIndex(v, 0);
	}
	return v && CFGetTypeID(v) == CFStringGetTypeID() ? cstring(v) : NULL;
}

static int
get_info(const char *name)
{
	SCPreferencesRef prefs = open_prefs(false);
	SCNetworkServiceRef s = find_service(prefs, name);
	if (s == NULL) {
		CFRelease(prefs);
		return bad_parameters();
	}
	SCNetworkProtocolRef p = NULL;
	CFDictionaryRef config = protocol_config(s, kSCNetworkProtocolTypeIPv4, &p);
	CFStringRef method = config ? CFDictionaryGetValue(config, kSCPropNetIPv4ConfigMethod) : NULL;
	CFDictionaryRef state = service_state(s, kSCEntNetIPv4);
	bool manual = method && CFEqual(method, kSCValNetIPv4ConfigMethodManual);
	char *ip = first_string(state, kSCPropNetIPv4Addresses);
	char *mask = first_string(state, kSCPropNetIPv4SubnetMasks);
	char *router = first_string(state, kSCPropNetIPv4Router);
	if (manual) {
		/* A manual setting shows what was set, even before configd applies it. */
		free(ip);
		free(mask);
		free(router);
		ip = first_string(config, kSCPropNetIPv4Addresses);
		mask = first_string(config, kSCPropNetIPv4SubnetMasks);
		router = first_string(config, kSCPropNetIPv4Router);
	}
	if (method == NULL || p == NULL || (p && !SCNetworkProtocolGetEnabled(p))) {
		printf("IP address: none\n");
	} else {
		printf("%s\n", manual ? "Manual Configuration" : "DHCP Configuration");
		printf("IP address: %s\n", ip ? ip : "none");
		printf("Subnet mask: %s\n", mask ? mask : "none");
		printf("Router: %s\n", router ? router : "none");
		if (!manual) {
			char *client = first_string(config, kSCPropNetIPv4DHCPClientID);
			printf("Client ID: %s\n", client ? client : "");
			free(client);
		}
	}
	SCNetworkProtocolRef p6 = NULL;
	CFDictionaryRef c6 = protocol_config(s, kSCNetworkProtocolTypeIPv6, &p6);
	CFStringRef m6 = c6 ? CFDictionaryGetValue(c6, kSCPropNetIPv6ConfigMethod) : NULL;
	printf("IPv6: %s\n", m6 && CFEqual(m6, kSCValNetIPv6ConfigMethodAutomatic) ? "Automatic" :
	    m6 && CFEqual(m6, kSCValNetIPv6ConfigMethodManual) ? "Manual" : "Off");
	printf("IPv6 IP address: none\nIPv6 Router: none\n");
	SCNetworkInterfaceRef ifc = SCNetworkServiceGetInterface(s);
	char *mac = cstring(ifc ? SCNetworkInterfaceGetHardwareAddressString(ifc) : NULL);
	if (*mac) {
		CFStringRef type = SCNetworkInterfaceGetInterfaceType(ifc);
		printf("%s: %s\n", type && CFEqual(type, kSCNetworkInterfaceTypeIEEE80211) ? "Wi-Fi ID" :
		    "Ethernet Address", mac);
	}
	free(mac);
	free(ip);
	free(mask);
	free(router);
	if (state) {
		CFRelease(state);
	}
	if (p) {
		CFRelease(p);
	}
	if (p6) {
		CFRelease(p6);
	}
	CFRelease(s);
	CFRelease(prefs);
	return 0;
}

static bool
valid_ipv4(const char *s)
{
	struct in_addr a;
	return inet_pton(AF_INET, s, &a) == 1;
}

/* Change the service's IPv4 (or DNS) protocol configuration. */
static int
edit_protocol(const char *name, CFStringRef type, void (*edit)(CFMutableDictionaryRef, void *), void *arg)
{
	SCPreferencesRef prefs = open_prefs(true);
	SCNetworkServiceRef s = find_service(prefs, name);
	if (s == NULL) {
		SCPreferencesUnlock(prefs);
		CFRelease(prefs);
		return bad_parameters();
	}
	SCNetworkProtocolRef p = SCNetworkServiceCopyProtocol(s, type);
	if (p == NULL && SCNetworkServiceAddProtocolType(s, type)) {
		p = SCNetworkServiceCopyProtocol(s, type);
	}
	if (p == NULL) {
		printf("** Error: The service has no %s settings.\n", CFStringGetCStringPtr(type, kCFStringEncodingUTF8));
		SCPreferencesUnlock(prefs);
		CFRelease(s);
		CFRelease(prefs);
		return 1;
	}
	CFDictionaryRef old = SCNetworkProtocolGetConfiguration(p);
	CFMutableDictionaryRef config = old ? CFDictionaryCreateMutableCopy(NULL, 0, old) :
	    CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	edit(config, arg);
	bool ok = SCNetworkProtocolSetConfiguration(p, CFDictionaryGetCount(config) ? config : NULL) &&
	    SCNetworkProtocolSetEnabled(p, TRUE);
	CFRelease(config);
	CFRelease(p);
	CFRelease(s);
	if (!ok) {
		printf("** Error: Unable to change the settings (%s).\n", SCErrorString(SCError()));
		SCPreferencesUnlock(prefs);
		CFRelease(prefs);
		return 1;
	}
	return save(prefs);
}

static CFArrayRef
string_array(char **values, int count)
{
	CFMutableArrayRef a = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	for (int i = 0; i < count; i++) {
		CFStringRef v = cfstr(values[i]);
		CFArrayAppendValue(a, v);
		CFRelease(v);
	}
	return a;
}

struct manual {
	char **v;
};

static void
set_manual(CFMutableDictionaryRef c, void *arg)
{
	struct manual *m = arg;
	CFDictionaryRemoveAllValues(c);
	CFDictionarySetValue(c, kSCPropNetIPv4ConfigMethod, kSCValNetIPv4ConfigMethodManual);
	CFArrayRef a = string_array(&m->v[0], 1), s = string_array(&m->v[1], 1);
	CFDictionarySetValue(c, kSCPropNetIPv4Addresses, a);
	CFDictionarySetValue(c, kSCPropNetIPv4SubnetMasks, s);
	CFRelease(a);
	CFRelease(s);
	CFStringRef r = cfstr(m->v[2]);
	CFDictionarySetValue(c, kSCPropNetIPv4Router, r);
	CFRelease(r);
}

static void
set_dhcp(CFMutableDictionaryRef c, void *arg)
{
	const char *client = arg;
	CFDictionaryRemoveAllValues(c);
	CFDictionarySetValue(c, kSCPropNetIPv4ConfigMethod, kSCValNetIPv4ConfigMethodDHCP);
	if (client && *client) {
		CFStringRef v = cfstr(client);
		CFDictionarySetValue(c, kSCPropNetIPv4DHCPClientID, v);
		CFRelease(v);
	}
}

struct list_edit {
	CFStringRef key;
	char **values;
	int count;
};

static void
set_list(CFMutableDictionaryRef c, void *arg)
{
	struct list_edit *e = arg;
	if (e->count == 1 && !strcmp(e->values[0], "Empty")) {
		CFDictionaryRemoveValue(c, e->key);
		return;
	}
	CFArrayRef a = string_array(e->values, e->count);
	CFDictionarySetValue(c, e->key, a);
	CFRelease(a);
}

static int
get_list(const char *name, CFStringRef key, const char *what)
{
	SCPreferencesRef prefs = open_prefs(false);
	SCNetworkServiceRef s = find_service(prefs, name);
	if (s == NULL) {
		CFRelease(prefs);
		return bad_parameters();
	}
	SCNetworkProtocolRef p = NULL;
	CFDictionaryRef config = protocol_config(s, kSCNetworkProtocolTypeDNS, &p);
	CFArrayRef a = config ? CFDictionaryGetValue(config, key) : NULL;
	if (a == NULL || CFGetTypeID(a) != CFArrayGetTypeID() || CFArrayGetCount(a) == 0) {
		printf("There aren't any %s set on %s.\n", what, name);
	} else {
		for (CFIndex i = 0; i < CFArrayGetCount(a); i++) {
			char *v = cstring(CFArrayGetValueAtIndex(a, i));
			printf("%s\n", v);
			free(v);
		}
	}
	if (p) {
		CFRelease(p);
	}
	CFRelease(s);
	CFRelease(prefs);
	return 0;
}

static int
set_enabled(const char *name, const char *how)
{
	bool on = !strcasecmp(how, "on");
	if (!on && strcasecmp(how, "off")) {
		return bad_parameters();
	}
	SCPreferencesRef prefs = open_prefs(true);
	SCNetworkServiceRef s = find_service(prefs, name);
	if (s == NULL) {
		SCPreferencesUnlock(prefs);
		CFRelease(prefs);
		return bad_parameters();
	}
	bool ok = SCNetworkServiceSetEnabled(s, on);
	CFRelease(s);
	if (!ok) {
		SCPreferencesUnlock(prefs);
		CFRelease(prefs);
		return 1;
	}
	return save(prefs);
}

static int
get_enabled(const char *name)
{
	SCPreferencesRef prefs = open_prefs(false);
	SCNetworkServiceRef s = find_service(prefs, name);
	if (s == NULL) {
		CFRelease(prefs);
		return bad_parameters();
	}
	printf("%s\n", SCNetworkServiceGetEnabled(s) ? "Enabled" : "Disabled");
	CFRelease(s);
	CFRelease(prefs);
	return 0;
}

static int
get_computer_name(void)
{
	CFStringRef name = SCDynamicStoreCopyComputerName(NULL, NULL);
	if (name == NULL) {
		SCPreferencesRef prefs = open_prefs(false);
		CFDictionaryRef sys = SCPreferencesPathGetValue(prefs, CFSTR("/System/System"));
		CFStringRef v = sys ? CFDictionaryGetValue(sys, kSCPropSystemComputerName) : NULL;
		name = v ? CFRetain(v) : NULL;
		CFRelease(prefs);
	}
	char *s = cstring(name);
	printf("%s\n", s);
	free(s);
	if (name) {
		CFRelease(name);
	}
	return 0;
}

static int
set_computer_name(const char *value)
{
	SCPreferencesRef prefs = open_prefs(true);
	CFStringRef v = cfstr(value);
	bool ok = SCPreferencesSetComputerName(prefs, v, kCFStringEncodingUTF8);
	CFRelease(v);
	if (!ok) {
		SCPreferencesUnlock(prefs);
		CFRelease(prefs);
		return 1;
	}
	return save(prefs);
}

static void
usage(void)
{
	printf("Usage: networksetup -listallnetworkservices\n"
	    "       networksetup -listnetworkserviceorder\n"
	    "       networksetup -listallhardwareports\n"
	    "       networksetup -getinfo <networkservice>\n"
	    "       networksetup -setmanual <networkservice> <ip> <subnet> <router>\n"
	    "       networksetup -setdhcp <networkservice> [clientid]\n"
	    "       networksetup -getdnsservers <networkservice>\n"
	    "       networksetup -setdnsservers <networkservice> <dns1> [dns2] [...] | Empty\n"
	    "       networksetup -getsearchdomains <networkservice>\n"
	    "       networksetup -setsearchdomains <networkservice> <domain1> [domain2] [...] | Empty\n"
	    "       networksetup -getnetworkserviceenabled <networkservice>\n"
	    "       networksetup -setnetworkserviceenabled <networkservice> <on off>\n"
	    "       networksetup -getcomputername\n"
	    "       networksetup -setcomputername <name>\n");
}

int
main(int argc, char **argv)
{
	if (argc < 2) {
		usage();
		return 0;
	}
	const char *c = argv[1];
	int n = argc - 2;
	char **a = argv + 2;

	if (!strcasecmp(c, "-listallnetworkservices") && n == 0) {
		return list_services(false);
	} else if (!strcasecmp(c, "-listnetworkserviceorder") && n == 0) {
		return list_services(true);
	} else if (!strcasecmp(c, "-listallhardwareports") && n == 0) {
		return list_hardware_ports();
	} else if (!strcasecmp(c, "-getinfo") && n == 1) {
		return get_info(a[0]);
	} else if (!strcasecmp(c, "-setmanual") && n == 4) {
		if (!valid_ipv4(a[1]) || !valid_ipv4(a[2]) || !valid_ipv4(a[3])) {
			return bad_parameters();
		}
		struct manual m = { a + 1 };
		return edit_protocol(a[0], kSCNetworkProtocolTypeIPv4, set_manual, &m);
	} else if (!strcasecmp(c, "-setdhcp") && (n == 1 || n == 2)) {
		return edit_protocol(a[0], kSCNetworkProtocolTypeIPv4, set_dhcp, n == 2 ? a[1] : NULL);
	} else if (!strcasecmp(c, "-getdnsservers") && n == 1) {
		return get_list(a[0], kSCPropNetDNSServerAddresses, "DNS Servers");
	} else if (!strcasecmp(c, "-setdnsservers") && n >= 2) {
		for (int i = 1; i < n; i++) {
			struct in6_addr a6;
			if (!(n == 2 && !strcmp(a[1], "Empty")) && !valid_ipv4(a[i]) &&
			    inet_pton(AF_INET6, a[i], &a6) != 1) {
				return bad_parameters();
			}
		}
		struct list_edit e = { kSCPropNetDNSServerAddresses, a + 1, n - 1 };
		return edit_protocol(a[0], kSCNetworkProtocolTypeDNS, set_list, &e);
	} else if (!strcasecmp(c, "-getsearchdomains") && n == 1) {
		return get_list(a[0], kSCPropNetDNSSearchDomains, "Search Domains");
	} else if (!strcasecmp(c, "-setsearchdomains") && n >= 2) {
		struct list_edit e = { kSCPropNetDNSSearchDomains, a + 1, n - 1 };
		return edit_protocol(a[0], kSCNetworkProtocolTypeDNS, set_list, &e);
	} else if (!strcasecmp(c, "-getnetworkserviceenabled") && n == 1) {
		return get_enabled(a[0]);
	} else if (!strcasecmp(c, "-setnetworkserviceenabled") && n == 2) {
		return set_enabled(a[0], a[1]);
	} else if (!strcasecmp(c, "-getcomputername") && n == 0) {
		return get_computer_name();
	} else if (!strcasecmp(c, "-setcomputername") && n == 1) {
		return set_computer_name(a[0]);
	}
	usage();
	return bad_parameters();
}
