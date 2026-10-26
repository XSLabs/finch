/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * scutil: the system configuration's command-line tool, written for Finch
 * over its SystemConfiguration framework. The commands people use, with
 * macOS's output:
 *
 *   scutil --get ComputerName|LocalHostName|HostName
 *   scutil --set ComputerName|LocalHostName|HostName [value]   (root)
 *   scutil --dns          the resolver configuration
 *   scutil --proxy        the proxy settings
 *   scutil                read commands: list, show, get, d.init, d.show,
 *                         d.add, set, add, remove, notify, help, quit
 *
 * Names are kept where macOS keeps them: ComputerName and HostName under
 * /System/System, LocalHostName under /System/Network/HostNames in
 * /Library/Preferences/SystemConfiguration/preferences.plist (written
 * through configd).
 */
#include <CoreFoundation/CoreFoundation.h>
#include <SystemConfiguration/SystemConfiguration.h>

#include <ctype.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void
put_cf(CFTypeRef value, int indent);

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

/* ---- printing values as scutil does ---- */

static void
pad(int indent)
{
	for (int i = 0; i < indent; i++) {
		fputs("  ", stdout);
	}
}

static void
put_scalar(CFTypeRef value)
{
	CFTypeID t = CFGetTypeID(value);
	if (t == CFStringGetTypeID()) {
		char *s = cstring(value);
		fputs(s, stdout);
		free(s);
	} else if (t == CFNumberGetTypeID()) {
		if (CFNumberIsFloatType(value)) {
			double d = 0;
			CFNumberGetValue(value, kCFNumberDoubleType, &d);
			printf("%g", d);
		} else {
			long long n = 0;
			CFNumberGetValue(value, kCFNumberLongLongType, &n);
			printf("%lld", n);
		}
	} else if (t == CFBooleanGetTypeID()) {
		fputs(CFBooleanGetValue(value) ? "TRUE" : "FALSE", stdout);
	} else if (t == CFDataGetTypeID()) {
		const UInt8 *bytes = CFDataGetBytePtr(value);
		CFIndex n = CFDataGetLength(value);
		printf("<data> 0x");
		for (CFIndex i = 0; i < n; i++) {
			printf("%02x", bytes[i]);
		}
	} else if (t == CFDateGetTypeID()) {
		printf("<date> %.0f", CFDateGetAbsoluteTime(value));
	} else {
		CFStringRef d = CFCopyDescription(value);
		char *s = cstring(d);
		fputs(s, stdout);
		free(s);
		CFRelease(d);
	}
}

static int
key_compare(const void *a, const void *b)
{
	CFStringRef x = *(CFStringRef const *)a, y = *(CFStringRef const *)b;
	return (int)CFStringCompare(x, y, 0);
}

static void
put_cf(CFTypeRef value, int indent)
{
	CFTypeID t = CFGetTypeID(value);
	if (t == CFDictionaryGetTypeID()) {
		CFIndex n = CFDictionaryGetCount(value);
		const void **keys = calloc((size_t)(n ? n : 1), sizeof(*keys));
		CFDictionaryGetKeysAndValues(value, keys, NULL);
		qsort(keys, (size_t)n, sizeof(*keys), key_compare);
		printf("<dictionary> {\n");
		for (CFIndex i = 0; i < n; i++) {
			pad(indent + 1);
			put_scalar(keys[i]);
			fputs(" : ", stdout);
			put_cf(CFDictionaryGetValue(value, keys[i]), indent + 1);
			putchar('\n');
		}
		free(keys);
		pad(indent);
		putchar('}');
	} else if (t == CFArrayGetTypeID()) {
		printf("<array> {\n");
		for (CFIndex i = 0; i < CFArrayGetCount(value); i++) {
			pad(indent + 1);
			printf("%ld : ", (long)i);
			put_cf(CFArrayGetValueAtIndex(value, i), indent + 1);
			putchar('\n');
		}
		pad(indent);
		putchar('}');
	} else {
		put_scalar(value);
	}
}

/* ---- --get and --set ---- */

enum name_kind { NAME_COMPUTER, NAME_LOCAL_HOST, NAME_HOST };

static int
name_kind(const char *name, enum name_kind *kind)
{
	if (!strcmp(name, "ComputerName")) {
		*kind = NAME_COMPUTER;
	} else if (!strcmp(name, "LocalHostName")) {
		*kind = NAME_LOCAL_HOST;
	} else if (!strcmp(name, "HostName")) {
		*kind = NAME_HOST;
	} else {
		return -1;
	}
	return 0;
}

static CFStringRef
name_path(enum name_kind kind, CFStringRef *key)
{
	if (kind == NAME_LOCAL_HOST) {
		*key = CFSTR("LocalHostName");
		return CFSTR("/System/Network/HostNames");
	}
	*key = kind == NAME_COMPUTER ? CFSTR("ComputerName") : CFSTR("HostName");
	return CFSTR("/System/System");
}

static void usage(void) __attribute__((noreturn));

static int
get_name(const char *name)
{
	enum name_kind kind;
	CFStringRef key;

	if (name_kind(name, &kind) != 0) {
		usage();
	}
	SCPreferencesRef prefs = SCPreferencesCreate(NULL, CFSTR("scutil --get"), NULL);
	if (prefs == NULL) {
		fprintf(stderr, "SCPreferencesCreate() failed: %s\n", SCErrorString(SCError()));
		return 1;
	}
	CFStringRef path = name_path(kind, &key);
	CFDictionaryRef entity = SCPreferencesPathGetValue(prefs, path);
	CFTypeRef value = entity ? CFDictionaryGetValue(entity, key) : NULL;
	int status = 0;
	if (value != NULL && CFGetTypeID(value) == CFStringGetTypeID()) {
		char *s = cstring(value);
		printf("%s\n", s);
		free(s);
	} else {
		printf("%s: not set\n", name);
		status = 1;
	}
	CFRelease(prefs);
	return status;
}

/* LocalHostName: letters, digits and hyphens, as macOS's own rule. */
static bool
valid_local_host_name(const char *s)
{
	if (*s == '\0' || *s == '-' || strlen(s) > 63) {
		return false;
	}
	for (; *s; s++) {
		if (!isalnum((unsigned char)*s) && *s != '-') {
			return false;
		}
	}
	return true;
}

static int
set_name(const char *name, const char *given)
{
	enum name_kind kind;
	char line[1024];
	const char *value = given;

	if (name_kind(name, &kind) != 0) {
		usage();
	}
	if (value == NULL) {
		/* As macOS's: read the new name from standard input. */
		if (fgets(line, sizeof(line), stdin) == NULL) {
			line[0] = '\0';
		}
		line[strcspn(line, "\n")] = '\0';
		value = line;
	}
	if (kind == NAME_LOCAL_HOST && *value && !valid_local_host_name(value)) {
		fprintf(stderr, "Invalid name.\n");
		return 1;
	}
	SCPreferencesRef prefs = SCPreferencesCreate(NULL, CFSTR("scutil --set"), NULL);
	if (prefs == NULL || !SCPreferencesLock(prefs, TRUE)) {
		fprintf(stderr, "SCPreferencesLock() failed: %s\n", SCErrorString(SCError()));
		if (prefs) {
			CFRelease(prefs);
		}
		return 1;
	}
	CFStringRef v = *value ? cfstr(value) : NULL;
	Boolean ok;
	if (kind == NAME_COMPUTER) {
		ok = SCPreferencesSetComputerName(prefs, v, kCFStringEncodingUTF8);
	} else if (kind == NAME_LOCAL_HOST) {
		ok = SCPreferencesSetLocalHostName(prefs, v);
	} else {
		CFStringRef key;
		CFStringRef path = name_path(kind, &key);
		CFDictionaryRef old = SCPreferencesPathGetValue(prefs, path);
		CFMutableDictionaryRef entity = old ? CFDictionaryCreateMutableCopy(NULL, 0, old) :
		    CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
		if (v) {
			CFDictionarySetValue(entity, key, v);
		} else {
			CFDictionaryRemoveValue(entity, key);
		}
		ok = SCPreferencesPathSetValue(prefs, path, entity);
		CFRelease(entity);
	}
	if (v) {
		CFRelease(v);
	}
	if (ok) {
		ok = SCPreferencesCommitChanges(prefs) && SCPreferencesApplyChanges(prefs);
	}
	if (!ok) {
		fprintf(stderr, "SCPreferences%s() failed: %s\n", "CommitChanges", SCErrorString(SCError()));
	}
	SCPreferencesUnlock(prefs);
	CFRelease(prefs);
	return ok ? 0 : 1;
}

/* ---- --dns and --proxy ---- */

static void
put_string_array(const char *label, CFArrayRef a)
{
	if (a == NULL || CFGetTypeID(a) != CFArrayGetTypeID()) {
		return;
	}
	for (CFIndex i = 0; i < CFArrayGetCount(a); i++) {
		CFTypeRef v = CFArrayGetValueAtIndex(a, i);
		if (CFGetTypeID(v) == CFStringGetTypeID()) {
			char *s = cstring(v);
			printf("  %s[%ld] : %s\n", label, (long)i, s);
			free(s);
		}
	}
}

static int
show_dns(void)
{
	SCDynamicStoreRef store = SCDynamicStoreCreate(NULL, CFSTR("scutil --dns"), NULL, NULL);
	CFDictionaryRef dns = store ? SCDynamicStoreCopyValue(store, CFSTR("State:/Network/Global/DNS")) : NULL;
	int resolver = 1;

	printf("DNS configuration\n\n");
	if (dns != NULL && CFGetTypeID(dns) == CFDictionaryGetTypeID()) {
		printf("resolver #%d\n", resolver++);
		CFStringRef domain = CFDictionaryGetValue(dns, CFSTR("DomainName"));
		if (domain != NULL && CFGetTypeID(domain) == CFStringGetTypeID()) {
			char *s = cstring(domain);
			printf("  domain   : %s\n", s);
			free(s);
		}
		put_string_array("search domain", CFDictionaryGetValue(dns, CFSTR("SearchDomains")));
		put_string_array("nameserver", CFDictionaryGetValue(dns, CFSTR("ServerAddresses")));
		printf("  flags    : Request A records, Request AAAA records\n\n");
	} else {
		/* No service has DNS: show the resolver file's servers, as libresolv reads it. */
		FILE *f = fopen("/private/var/run/resolv.conf", "r");
		char line[512];
		int n = 0;
		if (f != NULL) {
			printf("resolver #%d\n", resolver++);
			while (fgets(line, sizeof(line), f)) {
				char word[64], arg[448];
				if (sscanf(line, "%63s %447s", word, arg) == 2) {
					if (!strcmp(word, "nameserver")) {
						printf("  nameserver[%d] : %s\n", n++, arg);
					} else if (!strcmp(word, "search") || !strcmp(word, "domain")) {
						printf("  search domain[0] : %s\n", arg);
					}
				}
			}
			fclose(f);
			printf("\n");
		}
	}
	if (resolver == 1) {
		printf("No DNS configuration available\n");
	}
	printf("DNS configuration (for scoped queries)\n\n");
	if (dns) {
		CFRelease(dns);
	}
	if (store) {
		CFRelease(store);
	}
	return 0;
}

static int
show_proxy(void)
{
	CFDictionaryRef proxies = SCDynamicStoreCopyProxies(NULL);
	if (proxies == NULL) {
		proxies = CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks,
		    &kCFTypeDictionaryValueCallBacks);
	}
	/* As macOS's: the per-interface proxies aren't shown. */
	CFMutableDictionaryRef shown = CFDictionaryCreateMutableCopy(NULL, 0, proxies);
	CFDictionaryRemoveValue(shown, CFSTR("__SCOPED__"));
	put_cf(shown, 0);
	putchar('\n');
	CFRelease(shown);
	CFRelease(proxies);
	return 0;
}

/* ---- the interactive commands (the store) ---- */

struct session {
	SCDynamicStoreRef store;
	CFMutableDictionaryRef dict;	/* d.init's working dictionary */
};

static bool
ensure_open(struct session *s)
{
	if (s->store == NULL) {
		s->store = SCDynamicStoreCreate(NULL, CFSTR("scutil"), NULL, NULL);
	}
	if (s->store == NULL) {
		printf("  store not open: %s\n", SCErrorString(SCError()));
		return false;
	}
	return true;
}

static void
cmd_list(struct session *s, const char *pattern)
{
	if (!ensure_open(s)) {
		return;
	}
	CFStringRef p = cfstr(pattern ? pattern : ".*");
	CFArrayRef keys = SCDynamicStoreCopyKeyList(s->store, p);
	CFRelease(p);
	if (keys == NULL || CFArrayGetCount(keys) == 0) {
		printf("  no keys.\n");
	} else {
		CFIndex n = CFArrayGetCount(keys);
		CFStringRef *sorted = calloc((size_t)n, sizeof(*sorted));
		CFArrayGetValues(keys, CFRangeMake(0, n), (const void **)sorted);
		qsort(sorted, (size_t)n, sizeof(*sorted), key_compare);
		for (CFIndex i = 0; i < n; i++) {
			char *k = cstring(sorted[i]);
			printf("  subKey [%ld] = %s\n", (long)i, k);
			free(k);
		}
		free(sorted);
	}
	if (keys) {
		CFRelease(keys);
	}
}

static void
cmd_show(struct session *s, const char *key, bool into_dict)
{
	if (key == NULL) {
		printf("  show key\n");
		return;
	}
	if (!ensure_open(s)) {
		return;
	}
	CFStringRef k = cfstr(key);
	CFPropertyListRef v = SCDynamicStoreCopyValue(s->store, k);
	CFRelease(k);
	if (v == NULL) {
		printf("  No such key\n");
		return;
	}
	if (into_dict) {
		if (s->dict) {
			CFRelease(s->dict);
		}
		s->dict = CFGetTypeID(v) == CFDictionaryGetTypeID() ?
		    CFDictionaryCreateMutableCopy(NULL, 0, v) :
		    CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	} else {
		put_cf(v, 0);
		putchar('\n');
	}
	CFRelease(v);
}

/* d.add key [*#?] value...: * array, # number, ? boolean */
static void
cmd_dadd(struct session *s, char **argv, int argc)
{
	if (argc < 2) {
		printf("  d.add key [*#?] value...\n");
		return;
	}
	if (s->dict == NULL) {
		s->dict = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
		    &kCFTypeDictionaryValueCallBacks);
	}
	CFStringRef key = cfstr(argv[0]);
	int first = 1;
	char kind = 0;
	if (argc > 2 && strlen(argv[1]) == 1 && strchr("*#?", argv[1][0])) {
		kind = argv[1][0];
		first = 2;
	}
	CFTypeRef value;
	if (kind == '*') {
		CFMutableArrayRef a = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
		for (int i = first; i < argc; i++) {
			CFStringRef v = cfstr(argv[i]);
			CFArrayAppendValue(a, v);
			CFRelease(v);
		}
		value = a;
	} else if (kind == '#') {
		long long n = strtoll(argv[first], NULL, 0);
		value = CFNumberCreate(NULL, kCFNumberLongLongType, &n);
	} else if (kind == '?') {
		bool b = !strcasecmp(argv[first], "true") || !strcmp(argv[first], "1") || !strcasecmp(argv[first], "yes");
		value = CFRetain(b ? kCFBooleanTrue : kCFBooleanFalse);
	} else {
		value = cfstr(argv[first]);
	}
	CFDictionarySetValue(s->dict, key, value);
	CFRelease(value);
	CFRelease(key);
}

static void
cmd_store(struct session *s, const char *how, const char *key)
{
	if (key == NULL) {
		printf("  %s key\n", how);
		return;
	}
	if (!ensure_open(s)) {
		return;
	}
	CFStringRef k = cfstr(key);
	Boolean ok;
	if (!strcmp(how, "remove")) {
		ok = SCDynamicStoreRemoveValue(s->store, k);
	} else if (!strcmp(how, "notify")) {
		ok = SCDynamicStoreNotifyValue(s->store, k);
	} else {
		CFDictionaryRef v = s->dict ? CFRetain(s->dict) :
		    CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
		ok = !strcmp(how, "add") ? SCDynamicStoreAddValue(s->store, k, v) : SCDynamicStoreSetValue(s->store, k, v);
		CFRelease(v);
	}
	CFRelease(k);
	if (!ok) {
		printf("  %s\n", SCErrorString(SCError()));
	}
}

static void
help(void)
{
	printf("\nAvailable commands:\n\n"
	    " help                          : list available commands\n"
	    " f.read file                   : read (process) commands from file\n"
	    " quit                          : quit\n"
	    " q                             : quit\n\n"
	    " d.init                        : initialize (empty) dictionary\n"
	    " d.show                        : show dictionary contents\n"
	    " d.add key [*#?] val [v2 ...]  : add information to dictionary\n"
	    "       (*=array, #=number, ?=boolean)\n"
	    " d.remove key                  : remove key from dictionary\n\n"
	    " open                          : open a session with \"configd\"\n"
	    " close                         : close current \"configd\" session\n\n"
	    " list [pattern]                : list keys in data store\n"
	    " add key                       : add key in data store w/current dict\n"
	    " get key                       : get dict from data store w/key\n"
	    " set key                       : set key in data store w/current dict\n"
	    " show key                      : show values in data store w/key\n"
	    " remove key                    : remove key from data store\n"
	    " notify key                    : notify key in data store\n\n");
}

static int run_commands(struct session *s, FILE *in, bool prompt);

static int
command(struct session *s, char *line)
{
	char *argv[64];
	int argc = 0;
	for (char *p = strtok(line, " \t\n"); p && argc < 64; p = strtok(NULL, " \t\n")) {
		argv[argc++] = p;
	}
	if (argc == 0) {
		return 0;
	}
	const char *c = argv[0];
	if (!strcmp(c, "quit") || !strcmp(c, "q") || !strcmp(c, "exit")) {
		return 1;
	} else if (!strcmp(c, "help") || !strcmp(c, "?")) {
		help();
	} else if (!strcmp(c, "open")) {
		ensure_open(s);
	} else if (!strcmp(c, "close")) {
		if (s->store) {
			CFRelease(s->store);
			s->store = NULL;
		}
	} else if (!strcmp(c, "list")) {
		cmd_list(s, argc > 1 ? argv[1] : NULL);
	} else if (!strcmp(c, "show")) {
		cmd_show(s, argc > 1 ? argv[1] : NULL, false);
	} else if (!strcmp(c, "get")) {
		cmd_show(s, argc > 1 ? argv[1] : NULL, true);
	} else if (!strcmp(c, "d.init")) {
		if (s->dict) {
			CFRelease(s->dict);
		}
		s->dict = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	} else if (!strcmp(c, "d.show")) {
		if (s->dict) {
			put_cf(s->dict, 0);
			putchar('\n');
		} else {
			printf("d.show: dictionary must be initialized.\n");
		}
	} else if (!strcmp(c, "d.add")) {
		cmd_dadd(s, argv + 1, argc - 1);
	} else if (!strcmp(c, "d.remove")) {
		if (s->dict && argc > 1) {
			CFStringRef k = cfstr(argv[1]);
			CFDictionaryRemoveValue(s->dict, k);
			CFRelease(k);
		}
	} else if (!strcmp(c, "add") || !strcmp(c, "set") || !strcmp(c, "remove") || !strcmp(c, "notify")) {
		cmd_store(s, c, argc > 1 ? argv[1] : NULL);
	} else if (!strcmp(c, "f.read")) {
		FILE *f = argc > 1 ? fopen(argv[1], "r") : NULL;
		if (f == NULL) {
			printf("f.read: could not open file.\n");
		} else {
			int r = run_commands(s, f, false);
			fclose(f);
			return r;
		}
	} else {
		printf("%s: unknown, type \"help\" for command info\n", c);
	}
	return 0;
}

static int
run_commands(struct session *s, FILE *in, bool prompt)
{
	char line[4096];
	for (;;) {
		if (prompt) {
			fputs("> ", stdout);
			fflush(stdout);
		}
		if (fgets(line, sizeof(line), in) == NULL) {
			return 0;
		}
		if (command(s, line)) {
			return 1;
		}
	}
}

static void
usage(void)
{
	fprintf(stderr,
	    "usage: scutil\n"
	    "\tinteractive access to the dynamic store.\n\n"
	    "   or: scutil --get pref\n"
	    "   or: scutil --set pref [newval]\n"
	    "\tpref\tdisplay (or set) the specified preference.  Valid preferences\n"
	    "\t\tinclude:\n"
	    "\t\t\tComputerName, LocalHostName, HostName\n"
	    "\tnewval\tNew preference value to be set.  If not specified,\n"
	    "\t\tthe new value will be read from standard input.\n\n"
	    "   or: scutil --dns\n"
	    "\tshow DNS configuration.\n\n"
	    "   or: scutil --proxy\n"
	    "\tshow \"proxy\" configuration.\n");
	exit(1);
}

int
main(int argc, char **argv)
{
	if (argc >= 2 && !strcmp(argv[1], "--get")) {
		if (argc != 3) {
			usage();
		}
		return get_name(argv[2]);
	}
	if (argc >= 2 && !strcmp(argv[1], "--set")) {
		if (argc < 3 || argc > 4) {
			usage();
		}
		return set_name(argv[2], argc == 4 ? argv[3] : NULL);
	}
	if (argc == 2 && !strcmp(argv[1], "--dns")) {
		return show_dns();
	}
	if (argc == 2 && !strcmp(argv[1], "--proxy")) {
		return show_proxy();
	}
	if (argc != 1) {
		usage();
	}
	struct session s = { 0 };
	run_commands(&s, stdin, isatty(STDIN_FILENO));
	if (s.store) {
		CFRelease(s.store);
	}
	if (s.dict) {
		CFRelease(s.dict);
	}
	return 0;
}
