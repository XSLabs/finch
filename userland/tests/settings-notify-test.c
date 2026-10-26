/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Settings changes reach apps (guest-only, persistent VM:
 * tools/vm/test-settings-notify.sh). As root it starts a watcher as nobody
 * (an ordinary process) that schedules an SCPreferences callback on the system
 * preferences and a dynamic-store notification on Setup:/, then changes the
 * computer name with scutil, as an administrator would. The watcher must be
 * told by both, and read the new name.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <SystemConfiguration/SystemConfiguration.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#define NAME "Notify Test Finch"

static int failures;
static bool committed, setupChanged;

static void check(const char *what, bool ok)
{
	printf("%s: %s\n", what, ok ? "pass" : "FAIL");
	if (!ok)
		failures++;
}

static void prefsChanged(SCPreferencesRef prefs, SCPreferencesNotification type, void *info)
{
	(void)prefs;
	(void)info;
	if (type & kSCPreferencesNotificationCommit)
		committed = true;
}

static void storeChanged(SCDynamicStoreRef store, CFArrayRef keys, void *info)
{
	(void)store;
	(void)info;
	if (CFArrayContainsValue(keys, CFRangeMake(0, CFArrayGetCount(keys)), CFSTR("Setup:/")))
		setupChanged = true;
}

static int watch(int ready)
{
	SCPreferencesRef prefs = SCPreferencesCreate(NULL, CFSTR("settings-notify-test"), NULL);
	SCPreferencesContext pc = { 0 };
	bool scheduled = prefs && SCPreferencesSetCallback(prefs, prefsChanged, &pc) &&
	    SCPreferencesScheduleWithRunLoop(prefs, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
	SCDynamicStoreContext sc = { 0 };
	SCDynamicStoreRef store = SCDynamicStoreCreate(NULL, CFSTR("settings-notify-test"), storeChanged, &sc);
	const void *k[] = { CFSTR("Setup:/") };
	CFArrayRef keys = CFArrayCreate(NULL, k, 1, &kCFTypeArrayCallBacks);
	CFRunLoopSourceRef source = store ? SCDynamicStoreCreateRunLoopSource(NULL, store, 0) : NULL;
	scheduled = scheduled && store && SCDynamicStoreSetNotificationKeys(store, keys, NULL) && source;
	if (source)
		CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopDefaultMode);
	check("an ordinary process watches the settings", scheduled);
	(void)!write(ready, "x", 1);
	close(ready);
	for (int i = 0; i < 240 && !(committed && setupChanged); i++)
		CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.5, false);
	check("it's told the preferences were saved", committed);
	check("and that Setup:/ changed", setupChanged);
	CFStringRef name = SCDynamicStoreCopyComputerName(NULL, NULL);
	check("it reads the new computer name", name && CFEqual(name, CFSTR(NAME)));
	return failures != 0;
}

int main(void)
{
	setvbuf(stdout, NULL, _IOLBF, 0);
	if (getuid() != 0) {
		printf("run as root\n");
		return 2;
	}
	int fds[2];
	if (pipe(fds) != 0)
		return 1;
	pid_t pid = fork();
	if (pid == 0) {
		close(fds[0]);
		struct passwd *pw = getpwnam("nobody");
		if (!pw || setgid(pw->pw_gid) != 0 || setuid(pw->pw_uid) != 0)
			_exit(126);
		_exit(watch(fds[1]));
	}
	close(fds[1]);
	char c;
	check("the watcher is ready", read(fds[0], &c, 1) == 1);
	close(fds[0]);
	sleep(1);
	check("root sets the computer name", system("/usr/sbin/scutil --set ComputerName '" NAME "'") == 0);
	int status = 0;
	waitpid(pid, &status, 0);
	check("the watcher's checks", WIFEXITED(status) && WEXITSTATUS(status) == 0);
	printf("settings-notify-test: %d failed\n", failures);
	return failures != 0;
}
