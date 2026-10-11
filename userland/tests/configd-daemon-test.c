/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Network settings must be checked before configd changes host state. */
#include <fcntl.h>
#include <arpa/inet.h>
#include <errno.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <net/route.h>
#include <netinet/in.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/sockio.h>
#include <sys/socket.h>
#include <unistd.h>

static int test_getifaddrs(struct ifaddrs **all);
static void test_freeifaddrs(struct ifaddrs *all);
static int test_socket(int domain, int type, int protocol);
static int test_ioctl(int fd, unsigned long request, ...);
static int test_close(int fd);
static int test_sethostname(const char *hostname, size_t length);

static unsigned int
test_if_nametoindex(const char *name)
{
    return strcmp(name, "lo0") == 0 ? 1 : 0;
}

static int forbidden_open(const char *path, int flags, ...)
{
    (void)flags;
    fprintf(stderr, "unexpected file access: %s\n", path);
    abort();
}

static int forbidden_openat(int directory, const char *path, int flags, ...)
{
    (void)directory;
    (void)flags;
    fprintf(stderr, "unexpected relative file access: %s\n", path);
    abort();
}

#define if_nametoindex test_if_nametoindex
#define getifaddrs test_getifaddrs
#define freeifaddrs test_freeifaddrs
#define socket test_socket
#define ioctl test_ioctl
#define close test_close
#define sethostname test_sethostname
#define open forbidden_open
#define openat forbidden_openat
#define main configd_daemon_entry
#include "../oss/configd.daemon.c"
#undef main
#undef openat
#undef open
#undef sethostname
#undef close
#undef ioctl
#undef socket
#undef freeifaddrs
#undef getifaddrs
#undef if_nametoindex

#define MAX_FAKE_ALIASES 8
#define MAX_FAKE_IOCTL_CALLS 32

typedef struct {
	struct ifaddrs entry;
	char name[IF_NAMESIZE + 1];
	struct sockaddr_in address;
	struct sockaddr_in netmask;
	struct sockaddr_in broadcast;
	bool used;
} FakeIPv4Alias;

typedef struct {
	unsigned long request;
	struct in_addr address;
} FakeIoctlCall;

static FakeIPv4Alias fakeAliases[MAX_FAKE_ALIASES];
static FakeIoctlCall fakeIoctlCalls[MAX_FAKE_IOCTL_CALLS];
static size_t fakeIoctlCallCount;
static unsigned int fakeAddCount;
static unsigned int fakeFailAddAt;
static bool fakeFailLookup;
static bool fakeFailDelete;
static bool fakeFailHostname;

static void
fakeReset(void)
{
	memset(fakeAliases, 0, sizeof(fakeAliases));
	memset(fakeIoctlCalls, 0, sizeof(fakeIoctlCalls));
	fakeIoctlCallCount = 0;
	fakeAddCount = 0;
	fakeFailAddAt = 0;
	fakeFailLookup = false;
	fakeFailDelete = false;
	fakeFailHostname = false;
}

static bool
fakeAddress(const char *text, struct in_addr *address)
{
	return inet_pton(AF_INET, text, address) == 1;
}

static FakeIPv4Alias *
fakeAddAlias(const char *addressText, const char *maskText)
{
	FakeIPv4Alias *alias = NULL;
	for (size_t i = 0; i < MAX_FAKE_ALIASES; i++) {
		if (!fakeAliases[i].used) {
			alias = &fakeAliases[i];
			break;
		}
	}
	if (alias == NULL || !fakeAddress(addressText, &alias->address.sin_addr) ||
	    !fakeAddress(maskText, &alias->netmask.sin_addr))
		return NULL;
	memset(&alias->entry, 0, sizeof(alias->entry));
	strlcpy(alias->name, "lo0", sizeof(alias->name));
	alias->address.sin_family = AF_INET;
	alias->netmask.sin_family = AF_INET;
	alias->broadcast.sin_family = AF_INET;
	alias->broadcast.sin_addr.s_addr = alias->address.sin_addr.s_addr |
	    ~alias->netmask.sin_addr.s_addr;
	alias->entry.ifa_name = alias->name;
	alias->entry.ifa_addr = (struct sockaddr *)&alias->address;
	alias->entry.ifa_netmask = (struct sockaddr *)&alias->netmask;
	alias->entry.ifa_broadaddr = (struct sockaddr *)&alias->broadcast;
	alias->entry.ifa_flags = IFF_BROADCAST;
	alias->used = true;
	return alias;
}

static size_t
fakeAliasCount(void)
{
	size_t count = 0;
	for (size_t i = 0; i < MAX_FAKE_ALIASES; i++)
		count += fakeAliases[i].used ? 1 : 0;
	return count;
}

static int
test_getifaddrs(struct ifaddrs **all)
{
	if (fakeFailLookup) {
		errno = EIO;
		return -1;
	}
	struct ifaddrs *first = NULL;
	struct ifaddrs *last = NULL;
	for (size_t i = 0; i < MAX_FAKE_ALIASES; i++) {
		FakeIPv4Alias *alias = &fakeAliases[i];
		if (!alias->used)
			continue;
		alias->entry.ifa_next = NULL;
		if (last != NULL)
			last->ifa_next = &alias->entry;
		else
			first = &alias->entry;
		last = &alias->entry;
	}
	*all = first;
	return 0;
}

static void
test_freeifaddrs(struct ifaddrs *all)
{
	(void)all;
}

static int
test_socket(int domain, int type, int protocol)
{
	(void)domain;
	(void)type;
	(void)protocol;
	return 42;
}

static int
test_close(int fd)
{
	(void)fd;
	return 0;
}

static int
test_sethostname(const char *hostname, size_t length)
{
	(void)hostname;
	(void)length;
	if (fakeFailHostname) {
		errno = EIO;
		return -1;
	}
	return 0;
}

static void
recordFakeIoctl(unsigned long request, struct in_addr address)
{
	if (fakeIoctlCallCount < MAX_FAKE_IOCTL_CALLS) {
		fakeIoctlCalls[fakeIoctlCallCount].request = request;
		fakeIoctlCalls[fakeIoctlCallCount].address = address;
	}
	fakeIoctlCallCount++;
}

static int
test_ioctl(int fd, unsigned long request, ...)
{
	(void)fd;
	va_list args;
	va_start(args, request);
	if (request == SIOCAIFADDR) {
		struct ifaliasreq *aliasRequest = va_arg(args, struct ifaliasreq *);
		va_end(args);
		struct in_addr address = ((struct sockaddr_in *)&aliasRequest->ifra_addr)->sin_addr;
		recordFakeIoctl(request, address);
		fakeAddCount++;
		if (fakeFailAddAt != 0 && fakeAddCount == fakeFailAddAt) {
			errno = EIO;
			return -1;
		}
		char addressText[INET_ADDRSTRLEN];
		char maskText[INET_ADDRSTRLEN];
		if (inet_ntop(AF_INET, &address, addressText, sizeof(addressText)) == NULL ||
		    inet_ntop(AF_INET, &((struct sockaddr_in *)&aliasRequest->ifra_mask)->sin_addr,
		        maskText, sizeof(maskText)) == NULL) {
			errno = EINVAL;
			return -1;
		}
		FakeIPv4Alias *alias = fakeAddAlias(addressText, maskText);
		if (alias == NULL) {
			errno = ENOSPC;
			return -1;
		}
		alias->broadcast.sin_addr = ((struct sockaddr_in *)&aliasRequest->ifra_broadaddr)->sin_addr;
		return 0;
	}
	if (request == SIOCDIFADDR) {
		struct ifreq *deleteRequest = va_arg(args, struct ifreq *);
		va_end(args);
		struct in_addr address = ((struct sockaddr_in *)&deleteRequest->ifr_addr)->sin_addr;
		recordFakeIoctl(request, address);
		if (fakeFailDelete) {
			errno = EIO;
			return -1;
		}
		for (size_t i = 0; i < MAX_FAKE_ALIASES; i++) {
			if (fakeAliases[i].used &&
			    fakeAliases[i].address.sin_addr.s_addr == address.s_addr) {
				fakeAliases[i].used = false;
				return 0;
			}
		}
		errno = EADDRNOTAVAIL;
		return -1;
	}
	va_end(args);
	errno = EINVAL;
	return -1;
}

static CFMutableDictionaryRef
fixtureDictionary(void)
{
    return CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
}

static void
setValue(CFMutableDictionaryRef dictionary, const char *key, CFTypeRef value)
{
    CFStringRef keyString = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    if (keyString == NULL || value == NULL) {
        fprintf(stderr, "could not build fixture value for %s\n", key);
        exit(1);
    }
    CFDictionarySetValue(dictionary, keyString, value);
    CFRelease(keyString);
}

static void
setText(CFMutableDictionaryRef dictionary, const char *key, const char *value)
{
    CFStringRef text = CFStringCreateWithCString(NULL, value, kCFStringEncodingUTF8);
    if (text == NULL) {
        fprintf(stderr, "could not build fixture text for %s\n", key);
        exit(1);
    }
    setValue(dictionary, key, text);
    CFRelease(text);
}

static CFArrayRef
stringArray(const char **values, size_t count)
{
    CFMutableArrayRef array = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    if (array == NULL)
        exit(1);
    for (size_t i = 0; i < count; i++) {
        CFStringRef value = CFStringCreateWithCString(NULL, values[i],
            kCFStringEncodingUTF8);
        if (value == NULL)
            exit(1);
        CFArrayAppendValue(array, value);
        CFRelease(value);
    }
    return array;
}

static CFMutableDictionaryRef
newIPv4(const char *method, const char **addresses, size_t addressCount,
    const char **masks, size_t maskCount, bool router)
{
    CFMutableDictionaryRef ipv4 = fixtureDictionary();
    setText(ipv4, "ConfigMethod", method);
    if (addresses != NULL || addressCount > 0) {
        CFArrayRef list = stringArray(addresses, addressCount);
        setValue(ipv4, "Addresses", list);
        CFRelease(list);
    }
    if (masks != NULL || maskCount > 0) {
        CFArrayRef list = stringArray(masks, maskCount);
        setValue(ipv4, "SubnetMasks", list);
        CFRelease(list);
    }
    if (router)
        setText(ipv4, "Router", "192.0.2.1");
    return ipv4;
}

static CFMutableDictionaryRef
newDNS(const char **addresses, size_t addressCount, const char **domains,
    size_t domainCount)
{
    CFMutableDictionaryRef dns = fixtureDictionary();
    if (addresses != NULL || addressCount > 0) {
        CFArrayRef list = stringArray(addresses, addressCount);
        setValue(dns, "ServerAddresses", list);
        CFRelease(list);
    }
    if (domains != NULL || domainCount > 0) {
        CFArrayRef list = stringArray(domains, domainCount);
        setValue(dns, "SearchDomains", list);
        CFRelease(list);
    }
    return dns;
}

static CFMutableDictionaryRef
newService(CFDictionaryRef ipv4, CFDictionaryRef ipv6, CFDictionaryRef dns)
{
    CFMutableDictionaryRef service = fixtureDictionary();
    CFMutableDictionaryRef interface = fixtureDictionary();
    setText(interface, "DeviceName", "lo0");
    setValue(service, "Interface", interface);
    CFRelease(interface);
    if (ipv4 != NULL)
        setValue(service, "IPv4", ipv4);
    if (ipv6 != NULL)
        setValue(service, "IPv6", ipv6);
    if (dns != NULL)
        setValue(service, "DNS", dns);
    return service;
}

static CFMutableDictionaryRef
newPreferences(CFArrayRef order, CFDictionaryRef services)
{
    CFMutableDictionaryRef prefs = fixtureDictionary();
    CFMutableDictionaryRef set = fixtureDictionary();
    CFMutableDictionaryRef network = fixtureDictionary();
    CFMutableDictionaryRef global = fixtureDictionary();
    CFMutableDictionaryRef globalIPv4 = fixtureDictionary();
    CFMutableDictionaryRef sets = fixtureDictionary();

    setText(prefs, "CurrentSet", "/Sets/SET1");
    setValue(prefs, "Sets", sets);
    CFDictionarySetValue(sets, CFSTR("SET1"), set);
    setValue(set, "Network", network);
    setValue(network, "Global", global);
    setValue(global, "IPv4", globalIPv4);
    if (order != NULL)
        setValue(globalIPv4, "ServiceOrder", order);
    if (services != NULL)
        setValue(prefs, "NetworkServices", services);

    CFRelease(sets);
    CFRelease(globalIPv4);
    CFRelease(global);
    CFRelease(network);
    CFRelease(set);
    return prefs;
}

static CFMutableDictionaryRef
serviceMap(CFDictionaryRef first, CFDictionaryRef second)
{
    CFMutableDictionaryRef services = fixtureDictionary();
    if (first != NULL)
        setValue(services, "SVC1", first);
    if (second != NULL)
        setValue(services, "SVC2", second);
    return services;
}

static CFTypeRef
activeGlobalIPv4(CFMutableDictionaryRef prefs)
{
    CFTypeRef sets = CFDictionaryGetValue(prefs, CFSTR("Sets"));
    CFTypeRef set = CFDictionaryGetValue((CFDictionaryRef)sets, CFSTR("SET1"));
    CFTypeRef network = CFDictionaryGetValue((CFDictionaryRef)set, CFSTR("Network"));
    CFTypeRef global = CFDictionaryGetValue((CFDictionaryRef)network, CFSTR("Global"));
    return CFDictionaryGetValue((CFDictionaryRef)global, CFSTR("IPv4"));
}

static void
expectPlanStatus(CFDictionaryRef prefs, int expected, const char *name)
{
    NetworkApplyPlan plan;
    int status = buildNetworkApplyPlan(prefs, &plan);
    freeNetworkApplyPlan(&plan);
    if (status != expected) {
        fprintf(stderr, "%s returned %d instead of %d\n", name, status, expected);
        exit(1);
    }
}

static CFMutableDictionaryRef
basicService(const char *method, const char **addresses, size_t addressCount,
    const char **masks, size_t maskCount, bool router,
    const char **servers, size_t serverCount, const char **domains, size_t domainCount)
{
    CFMutableDictionaryRef ipv4 = newIPv4(method, addresses, addressCount,
        masks, maskCount, router);
    CFMutableDictionaryRef dns = newDNS(servers, serverCount, domains, domainCount);
    CFMutableDictionaryRef service = newService(ipv4, NULL, dns);
    CFRelease(dns);
    CFRelease(ipv4);
    return service;
}

static void
testMasksAndDomains(void)
{
    struct in_addr mask;
    if (!ipv4Mask(CFSTR("255.255.255.0"), &mask) ||
        ipv4Mask(CFSTR("255.0.255.0"), &mask)) {
        fprintf(stderr, "IPv4 mask validation failed\n");
        exit(1);
    }

    char domain[256];
    if (!validSearchDomain(CFSTR("finch-configd-test.invalid"), domain) ||
        validSearchDomain(CFSTR(""), domain) ||
        validSearchDomain(CFSTR("bad..example"), domain) ||
        validSearchDomain(CFSTR("-bad.example"), domain) ||
        validSearchDomain(CFSTR("bad_.example"), domain)) {
        fprintf(stderr, "search domain validation failed\n");
        exit(1);
    }
}

static void
testPriority(void)
{
    const char *orderItems[] = { "SVC1", "SVC2" };
    const char *firstServers[] = { "192.0.2.53" };
    const char *firstDomains[] = { "first.invalid" };
    const char *secondServers[] = { "192.0.2.54" };
    const char *secondDomains[] = { "second.invalid" };
    CFMutableDictionaryRef first = basicService("None", NULL, 0, NULL, 0, false,
        firstServers, 1, firstDomains, 1);
    CFMutableDictionaryRef second = basicService("None", NULL, 0, NULL, 0, false,
        secondServers, 1, secondDomains, 1);
    CFMutableDictionaryRef services = serviceMap(first, second);
    CFArrayRef order = stringArray(orderItems, 2);
    CFMutableDictionaryRef prefs = newPreferences(order, services);
    NetworkApplyPlan plan;
    int status = buildNetworkApplyPlan(prefs, &plan);
    if (status == SC_OK)
        status = formatResolverContents(&plan);
    const char *expected = "nameserver 192.0.2.53\nnameserver 192.0.2.54\n"
        "search first.invalid second.invalid\n";
    if (status != SC_OK || plan.resolverLength != strlen(expected) ||
        memcmp(plan.resolverContents, expected, strlen(expected)) != 0) {
        fprintf(stderr, "service priority was not kept in resolver output\n");
        exit(1);
    }
    freeNetworkApplyPlan(&plan);
    CFRelease(prefs);
    CFRelease(order);
    CFRelease(services);
    CFRelease(second);
    CFRelease(first);
}

static void
testInvalidPreferences(void)
{
    const char *orderItems[] = { "SVC1" };
    const char *address[] = { "192.0.2.20" };
    const char *mask[] = { "255.255.255.0" };
    const char *badMask[] = { "255.0.255.0" };
    const char *server[] = { "192.0.2.53" };
    const char *emptyDomain[] = { "" };
    const char *badDomain[] = { "bad..example" };
    CFArrayRef order = stringArray(orderItems, 1);

    CFMutableDictionaryRef service = basicService("Manual", address, 1, badMask, 1,
        false, server, 1, NULL, 0);
    CFMutableDictionaryRef services = serviceMap(service, NULL);
    CFMutableDictionaryRef prefs = newPreferences(order, services);
    expectPlanStatus(prefs, SC_INVALID_ARGUMENT, "non-contiguous mask");
    CFRelease(prefs);
    CFRelease(services);
    CFRelease(service);

    service = basicService("Manual", address, 1, mask, 1, false,
        server, 1, emptyDomain, 1);
    services = serviceMap(service, NULL);
    prefs = newPreferences(order, services);
    expectPlanStatus(prefs, SC_INVALID_ARGUMENT, "empty search domain");
    CFRelease(prefs);
    CFRelease(services);
    CFRelease(service);

    service = basicService("Manual", address, 1, mask, 1, false,
        server, 1, badDomain, 1);
    services = serviceMap(service, NULL);
    prefs = newPreferences(order, services);
    expectPlanStatus(prefs, SC_INVALID_ARGUMENT, "invalid search domain");
    CFRelease(prefs);
    CFRelease(services);
    CFRelease(service);

    service = basicService("Manual", address, 1, mask, 1, true,
        server, 1, NULL, 0);
    services = serviceMap(service, NULL);
    prefs = newPreferences(order, services);
    expectPlanStatus(prefs, SC_FAILED, "unsupported router");
    CFRelease(prefs);
    CFRelease(services);
    CFRelease(service);

    const char *twoAddresses[] = { "192.0.2.20", "192.0.2.21" };
    service = basicService("Manual", twoAddresses, 2, mask, 1, false,
        server, 1, NULL, 0);
    services = serviceMap(service, NULL);
    prefs = newPreferences(order, services);
    expectPlanStatus(prefs, SC_FAILED, "multiple IPv4 addresses");
    CFRelease(prefs);
    CFRelease(services);
    CFRelease(service);

    const char *twoMasks[] = { "255.255.255.0", "255.255.0.0" };
    service = basicService("Manual", address, 1, twoMasks, 2, false,
        server, 1, NULL, 0);
    services = serviceMap(service, NULL);
    prefs = newPreferences(order, services);
    expectPlanStatus(prefs, SC_FAILED, "multiple IPv4 masks");
    CFRelease(prefs);
    CFRelease(services);
    CFRelease(service);

    service = basicService("DHCP", NULL, 0, NULL, 0, false,
        server, 1, NULL, 0);
    services = serviceMap(service, NULL);
    prefs = newPreferences(order, services);
    expectPlanStatus(prefs, SC_FAILED, "unsupported DHCP");
    CFRelease(prefs);
    CFRelease(services);
    CFRelease(service);

    CFMutableDictionaryRef ipv6 = fixtureDictionary();
    setText(ipv6, "ConfigMethod", "Automatic");
    service = newService(NULL, ipv6, NULL);
    services = serviceMap(service, NULL);
    prefs = newPreferences(order, services);
    expectPlanStatus(prefs, SC_FAILED, "unsupported IPv6");
    CFRelease(prefs);
    CFRelease(services);
    CFRelease(service);
    CFRelease(ipv6);

    service = basicService("None", NULL, 0, NULL, 0, false,
        server, 1, NULL, 0);
    services = serviceMap(service, NULL);
    prefs = newPreferences(order, services);
    CFMutableArrayRef duplicateOrder = CFArrayCreateMutable(NULL, 0,
        &kCFTypeArrayCallBacks);
    CFArrayAppendValue(duplicateOrder, CFSTR("SVC1"));
    CFArrayAppendValue(duplicateOrder, CFSTR("SVC1"));
    CFDictionarySetValue((CFMutableDictionaryRef)activeGlobalIPv4(prefs),
        CFSTR("ServiceOrder"), duplicateOrder);
    expectPlanStatus(prefs, SC_INVALID_ARGUMENT, "duplicate service order entry");
    CFRelease(duplicateOrder);
    CFRelease(prefs);

    prefs = newPreferences(order, services);
    CFDictionarySetValue(prefs, CFSTR("CurrentSet"), CFSTR("/Sets/MISSING"));
    expectPlanStatus(prefs, SC_INVALID_ARGUMENT, "missing active set");
    CFRelease(prefs);

    prefs = newPreferences(order, services);
    CFDictionarySetValue((CFMutableDictionaryRef)activeGlobalIPv4(prefs),
        CFSTR("ServiceOrder"), kCFBooleanTrue);
    expectPlanStatus(prefs, SC_INVALID_ARGUMENT, "service order type");
    CFRelease(prefs);

    prefs = newPreferences(order, services);
    CFDictionaryRemoveValue((CFMutableDictionaryRef)activeGlobalIPv4(prefs),
        CFSTR("ServiceOrder"));
    expectPlanStatus(prefs, SC_INVALID_ARGUMENT, "missing service order");
    CFRelease(prefs);

    CFRelease(services);
    CFRelease(service);

    CFRelease(order);
}

static void
testHostnameOnly(void)
{
    CFMutableDictionaryRef prefs = fixtureDictionary();
    char hostname[256];
    bool hasHostname = false;
    if (validateHostname(CFSTR("finch-test"), hostname, &hasHostname) != SC_OK ||
        !hasHostname || strcmp(hostname, "finch-test") != 0) {
        fprintf(stderr, "hostname-only value was rejected\n");
        exit(1);
    }
    NetworkApplyPlan plan;
    int status = buildNetworkApplyPlan(prefs, &plan);
    if (status != SC_OK || plan.serviceCount != 0 || plan.hasDNS) {
        fprintf(stderr, "hostname-only preferences were rejected\n");
        exit(1);
    }
    freeNetworkApplyPlan(&plan);
	CFRelease(prefs);
}

static int
buildTestNetworkPlan(size_t serviceCount, bool includeDNS, NetworkApplyPlan *plan)
{
	const char *orderItems[] = { "SVC1", "SVC2" };
	const char *firstAddress[] = { "192.0.2.20" };
	const char *secondAddress[] = { "192.0.2.21" };
	const char *mask[] = { "255.255.255.0" };
	const char *server[] = { "192.0.2.53" };
	if (serviceCount == 0 || serviceCount > 2)
		return SC_INVALID_ARGUMENT;
	CFMutableDictionaryRef first = basicService("Manual", firstAddress, 1, mask, 1,
	    false, NULL, 0, NULL, 0);
	CFDictionaryRemoveValue(first, CFSTR("DNS"));
	CFMutableDictionaryRef second = serviceCount == 2 ? basicService("Manual",
	    secondAddress, 1, mask, 1, false, includeDNS ? server : NULL,
	    includeDNS ? 1 : 0, NULL, 0) : NULL;
	if (second != NULL && !includeDNS)
		CFDictionaryRemoveValue(second, CFSTR("DNS"));
	CFMutableDictionaryRef services = serviceMap(first, second);
	CFArrayRef order = stringArray(orderItems, serviceCount);
	CFMutableDictionaryRef prefs = newPreferences(order, services);
	int status = buildNetworkApplyPlan(prefs, plan);
	if (status == SC_OK && includeDNS)
		status = formatResolverContents(plan);
	CFRelease(prefs);
	CFRelease(order);
	CFRelease(services);
	if (second != NULL)
		CFRelease(second);
	CFRelease(first);
	return status;
}

static bool
callIs(size_t index, unsigned long request, const char *addressText)
{
	struct in_addr expected;
	return index < fakeIoctlCallCount && index < MAX_FAKE_IOCTL_CALLS &&
	    fakeAddress(addressText, &expected) && fakeIoctlCalls[index].request == request &&
	    fakeIoctlCalls[index].address.s_addr == expected.s_addr;
}

static void
expectRollbackOrder(const char *name)
{
	if (fakeIoctlCallCount != 4 || !callIs(0, SIOCAIFADDR, "192.0.2.20") ||
	    !callIs(1, SIOCAIFADDR, "192.0.2.21") ||
	    !callIs(2, SIOCDIFADDR, "192.0.2.21") ||
	    !callIs(3, SIOCDIFADDR, "192.0.2.20") || fakeAliasCount() != 0) {
		fprintf(stderr, "%s did not add then roll back addresses in reverse order\n", name);
		exit(1);
	}
}

static void
testRollbackAfterLaterFailure(void)
{
	NetworkApplyPlan plan;
	fakeReset();
	if (buildTestNetworkPlan(2, true, &plan) != SC_OK ||
	    snapshotIPv4Aliases(&plan) != SC_OK ||
	    applyPreparedNetworkPlan(&plan, false, NULL) != SC_FAILED) {
		fprintf(stderr, "resolver failure did not fail the apply\n");
		exit(1);
	}
	expectRollbackOrder("resolver failure");
	freeNetworkApplyPlan(&plan);
}

static void
testExistingAndConflictingTuples(void)
{
	NetworkApplyPlan plan;
	/* The tuple appears after whole-plan preflight but before this service applies. */
	fakeReset();
	if (buildTestNetworkPlan(1, false, &plan) != SC_OK ||
	    snapshotIPv4Aliases(&plan) != SC_OK ||
	    fakeAddAlias("192.0.2.20", "255.255.255.0") == NULL ||
	    applyPreparedNetworkPlan(&plan, false, NULL) != SC_OK ||
	    fakeIoctlCallCount != 0 || plan.services[0].ipv4Added || fakeAliasCount() != 1) {
		fprintf(stderr, "an exact tuple added after preflight was changed or claimed\n");
		exit(1);
	}
	freeNetworkApplyPlan(&plan);

	fakeReset();
	if (buildTestNetworkPlan(1, false, &plan) != SC_OK ||
	    fakeAddAlias("192.0.2.20", "255.255.255.0") == NULL ||
	    snapshotIPv4Aliases(&plan) != SC_OK || plan.services[0].ipv4NeedsAdd ||
	    applyPreparedNetworkPlan(&plan, false, NULL) != SC_OK ||
	    fakeIoctlCallCount != 0 || fakeAliasCount() != 1) {
		fprintf(stderr, "an exact existing IPv4 tuple was not left alone\n");
		exit(1);
	}
	freeNetworkApplyPlan(&plan);

	fakeReset();
	if (buildTestNetworkPlan(1, false, &plan) != SC_OK ||
	    fakeAddAlias("192.0.2.20", "255.255.0.0") == NULL ||
	    snapshotIPv4Aliases(&plan) != SC_FAILED || fakeIoctlCallCount != 0 ||
	    fakeAliasCount() != 1) {
		fprintf(stderr, "a conflicting same-address tuple was not refused\n");
		exit(1);
	}
	freeNetworkApplyPlan(&plan);
}

static void
testAddFailureRollback(void)
{
	NetworkApplyPlan plan;
	fakeReset();
	fakeFailAddAt = 2;
	if (buildTestNetworkPlan(2, false, &plan) != SC_OK ||
	    snapshotIPv4Aliases(&plan) != SC_OK ||
	    applyPreparedNetworkPlan(&plan, false, NULL) != SC_FAILED ||
	    fakeIoctlCallCount != 3 || !callIs(0, SIOCAIFADDR, "192.0.2.20") ||
	    !callIs(1, SIOCAIFADDR, "192.0.2.21") ||
	    !callIs(2, SIOCDIFADDR, "192.0.2.20") || fakeAliasCount() != 0) {
		fprintf(stderr, "a failed later address add did not roll back earlier additions\n");
		exit(1);
	}
	freeNetworkApplyPlan(&plan);
}

static void
testChangedTupleAndLookupFailures(void)
{
	NetworkApplyPlan plan;
	fakeReset();
	if (buildTestNetworkPlan(1, false, &plan) != SC_OK ||
	    snapshotIPv4Aliases(&plan) != SC_OK ||
	    applyIPv4(&plan.services[0]) != SC_OK || fakeAliasCount() != 1) {
		fprintf(stderr, "could not prepare a new IPv4 tuple for rollback checks\n");
		exit(1);
	}
	if (!fakeAddress("255.255.0.0", &fakeAliases[0].netmask.sin_addr) ||
	    rollbackAddedIPv4(&plan) != SC_FAILED || fakeIoctlCallCount != 1 ||
	    fakeAliasCount() != 1) {
		fprintf(stderr, "rollback removed an address whose tuple had changed\n");
		exit(1);
	}
	freeNetworkApplyPlan(&plan);

	fakeReset();
	if (buildTestNetworkPlan(1, false, &plan) != SC_OK) {
		fprintf(stderr, "could not build lookup-failure plan\n");
		exit(1);
	}
	fakeFailLookup = true;
	if (snapshotIPv4Aliases(&plan) != SC_FAILED || fakeIoctlCallCount != 0) {
		fprintf(stderr, "a failed IPv4 lookup did not stop preflight\n");
		exit(1);
	}
	fakeFailLookup = false;
	if (snapshotIPv4Aliases(&plan) != SC_OK || applyIPv4(&plan.services[0]) != SC_OK) {
		fprintf(stderr, "could not prepare the lookup-failure rollback check\n");
		exit(1);
	}
	fakeFailLookup = true;
	if (rollbackAddedIPv4(&plan) != SC_FAILED || fakeIoctlCallCount != 1 ||
	    fakeAliasCount() != 1) {
		fprintf(stderr, "rollback deleted an address when its state could not be checked\n");
		exit(1);
	}
	fakeFailLookup = false;
	freeNetworkApplyPlan(&plan);
}

static void
testHostnameAndDeleteFailures(void)
{
	NetworkApplyPlan plan;
	fakeReset();
	if (buildTestNetworkPlan(1, false, &plan) != SC_OK ||
	    snapshotIPv4Aliases(&plan) != SC_OK) {
		fprintf(stderr, "could not prepare hostname failure check\n");
		exit(1);
	}
	fakeFailHostname = true;
	if (applyPreparedNetworkPlan(&plan, true, "finch-test") != SC_FAILED ||
	    fakeIoctlCallCount != 2 || !callIs(0, SIOCAIFADDR, "192.0.2.20") ||
	    !callIs(1, SIOCDIFADDR, "192.0.2.20") || fakeAliasCount() != 0) {
		fprintf(stderr, "hostname failure did not roll back the new IPv4 tuple\n");
		exit(1);
	}
	freeNetworkApplyPlan(&plan);

	fakeReset();
	if (buildTestNetworkPlan(1, false, &plan) != SC_OK ||
	    snapshotIPv4Aliases(&plan) != SC_OK ||
	    applyIPv4(&plan.services[0]) != SC_OK) {
		fprintf(stderr, "could not prepare delete failure check\n");
		exit(1);
	}
	fakeFailDelete = true;
	if (rollbackAddedIPv4(&plan) != SC_FAILED || fakeIoctlCallCount != 2 ||
	    fakeAliasCount() != 1) {
		fprintf(stderr, "failed address deletion was not reported safely\n");
		exit(1);
	}
	freeNetworkApplyPlan(&plan);
}

int
main(void)
{
    const UniChar embeddedNul[] = {'l', 'o', '0', 0, 'x'};
    CFStringRef badString = CFStringCreateWithCharacters(NULL, embeddedNul, 5);
    char text[32];
    if (!badString || stringFromCF(badString, text, sizeof(text)) ||
        !stringFromCF(CFSTR("caf\u00e9"), text, sizeof(text)) || strcmp(text, "caf\u00e9") != 0) {
        fprintf(stderr, "string conversion accepted a hidden suffix or rejected UTF-8\n");
        exit(1);
    }
    CFRelease(badString);
    testMasksAndDomains();
    testPriority();
    testInvalidPreferences();
    testHostnameOnly();
    testRollbackAfterLaterFailure();
    testExistingAndConflictingTuples();
    testAddFailureRollback();
    testChangedTupleAndLookupFailures();
    testHostnameAndDeleteFailures();
    puts("configd network apply validation: PASS (preflight, DNS priority, safe IPv4 rollback)");
    return 0;
}
