/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include <SystemConfiguration/SystemConfiguration.h>
#include <CoreFoundation/CoreFoundation.h>
#include <assert.h>
#include <stdio.h>
#include <arpa/inet.h>
/* Run as root in the VM, with configd running: preferences edited in memory, and the dynamic
   store taking root's values (Apple's refuse those to other users). Commits are checked by
   finch-configd-service-test (tools/vm/test-settings.sh), with a configd of its own. */
int main(void)
{
	SCPreferencesRef p = SCPreferencesCreate(
	    NULL, CFSTR("Finch test"), CFSTR("/tmp/finch-nonexistent-preferences-test.plist"));
	assert(p);
	CFDictionaryRef empty = CFDictionaryCreate(
	    NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	assert(SCPreferencesSetValue(p, CFSTR("Nested"), empty));
	assert(SCPreferencesPathGetValue(p, CFSTR("/Nested")));
	CFArrayRef keys = SCPreferencesCopyKeyList(p);
	assert(keys &&
	    CFArrayContainsValue(keys, CFRangeMake(0, CFArrayGetCount(keys)), CFSTR("Nested")));
	CFRelease(keys);
	CFRelease(empty);
	CFRelease(p);
	SCDynamicStoreRef store = SCDynamicStoreCreate(NULL, CFSTR("Finch test"), NULL, NULL);
	assert(store);
	CFStringRef host = SCDynamicStoreCopyComputerName(store, NULL);
	assert(host && CFStringGetLength(host));
	CFRelease(host);
	CFDictionaryRef interfaces =
	    SCDynamicStoreCopyValue(store, CFSTR("State:/Network/Interface"));
	assert(interfaces);
	CFRelease(interfaces);
	keys = SCDynamicStoreCopyKeyList(store, CFSTR("State:/Network/Interface/.*/IPv[46]"));
	assert(keys && CFArrayGetCount(keys) > 0);
	CFDictionaryRef values = SCDynamicStoreCopyMultiple(store, keys, NULL);
	assert(values && CFDictionaryGetCount(values) == CFArrayGetCount(keys));
	CFRelease(values);
	CFRelease(keys);
	CFStringRef key = CFSTR("State:/Finch/sysconfig-core-test");
	assert(SCDynamicStoreSetValue(store, key, CFSTR("value")));
	CFPropertyListRef got = SCDynamicStoreCopyValue(store, key);
	assert(got && CFEqual(got, CFSTR("value")));
	CFRelease(got);
	assert(SCDynamicStoreRemoveValue(store, key));
	assert(!SCDynamicStoreCopyValue(store, key));
	CFRelease(store);
	struct sockaddr_in address = {.sin_len = sizeof(address), .sin_family = AF_INET};
	inet_pton(AF_INET, "127.0.0.1", &address.sin_addr);
	SCNetworkReachabilityRef r =
	    SCNetworkReachabilityCreateWithAddress(NULL, (struct sockaddr *)&address);
	assert(r);
	SCNetworkReachabilityFlags flags = 0;
	assert(SCNetworkReachabilityGetFlags(r, &flags));
	assert(flags & kSCNetworkReachabilityFlagsReachable);
	CFRelease(r);
	CFArrayRef all = SCNetworkInterfaceCopyAll();
	assert(all);
	for (CFIndex i = 0; i < CFArrayGetCount(all); i++) {
		SCNetworkInterfaceRef interface = CFArrayGetValueAtIndex(all, i);
		assert(SCNetworkInterfaceGetBSDName(interface));
		assert(SCNetworkInterfaceGetInterfaceType(interface));
	}
	CFRelease(all);
	puts(
	    "sysconfig-core: PASS (preferences in memory, live interfaces, address reads, route, store writes)");
	return 0;
}
