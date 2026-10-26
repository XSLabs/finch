/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * pam_console: the console's user, as macOS's loginwindow records it. A
 * session opened on the console (PAM_TTY "console" or /dev/console) makes its
 * user the console user in the SystemConfiguration dynamic store
 * (State:/Users/ConsoleUser, SCDynamicStoreSetConsoleInformation); closing it
 * clears that again. Services that wait for someone at the console, such as
 * Disk Arbitration mounting removable disks, see the login. Sessions on other
 * terminals are left alone, and the store's errors never stop a login.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <SystemConfiguration/SystemConfiguration.h>
#include <bsm/audit.h>
#include <pwd.h>
#include <string.h>
#include <unistd.h>

#define PAM_SM_SESSION
#include <security/pam_appl.h>
#include <security/pam_modules.h>
#include <security/openpam.h>

/* (SCDynamicStoreCopySpecific.h; SPI, as loginwindow uses it) */
extern const CFStringRef kSCConsoleSessionUserName;
extern const CFStringRef kSCConsoleSessionUID;
extern const CFStringRef kSCConsoleSessionConsoleSet;
extern const CFStringRef kSCConsoleSessionOnConsole;
extern const CFStringRef kSCConsoleSessionLoginDone;
extern const CFStringRef kSCConsoleSessionID;
Boolean SCDynamicStoreSetConsoleInformation(SCDynamicStoreRef store, const char *user, uid_t uid, gid_t gid,
    CFArrayRef sessions);

static bool on_console(pam_handle_t *pamh)
{
	const void *tty = NULL;
	if (pam_get_item(pamh, PAM_TTY, &tty) != PAM_SUCCESS || tty == NULL)
		return false;
	const char *name = tty;
	if (strncmp(name, "/dev/", 5) == 0)
		name += 5;
	return strcmp(name, "console") == 0;
}

static void set_console(const struct passwd *pw)
{
	SCDynamicStoreRef store = SCDynamicStoreCreate(NULL, CFSTR("pam_console"), NULL, NULL);
	if (store == NULL)
		return;
	if (pw == NULL) {
		SCDynamicStoreSetConsoleInformation(store, NULL, 0, 0, NULL);
		CFRelease(store);
		return;
	}
	CFMutableDictionaryRef session = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
	    &kCFTypeDictionaryValueCallBacks);
	CFStringRef name = CFStringCreateWithCString(NULL, pw->pw_name, kCFStringEncodingUTF8);
	int uid = (int)pw->pw_uid, zero = 0;
	CFNumberRef uidNumber = CFNumberCreate(NULL, kCFNumberIntType, &uid);
	CFNumberRef consoleSet = CFNumberCreate(NULL, kCFNumberIntType, &zero);
	auditinfo_addr_t audit;
	int asid = getaudit_addr(&audit, sizeof(audit)) == 0 ? (int)audit.ai_asid : 0;
	CFNumberRef sessionID = CFNumberCreate(NULL, kCFNumberIntType, &asid);
	CFDictionarySetValue(session, kSCConsoleSessionUserName, name);
	CFDictionarySetValue(session, kSCConsoleSessionUID, uidNumber);
	CFDictionarySetValue(session, kSCConsoleSessionConsoleSet, consoleSet);
	CFDictionarySetValue(session, kSCConsoleSessionOnConsole, kCFBooleanTrue);
	CFDictionarySetValue(session, kSCConsoleSessionLoginDone, kCFBooleanTrue);
	CFDictionarySetValue(session, kSCConsoleSessionID, sessionID);
	CFArrayRef sessions = CFArrayCreate(NULL, (const void **)&session, 1, &kCFTypeArrayCallBacks);
	SCDynamicStoreSetConsoleInformation(store, pw->pw_name, pw->pw_uid, pw->pw_gid, sessions);
	CFRelease(sessions);
	CFRelease(session);
	CFRelease(name);
	CFRelease(uidNumber);
	CFRelease(consoleSet);
	CFRelease(sessionID);
	CFRelease(store);
}

PAM_EXTERN int
pam_sm_open_session(pam_handle_t *pamh, int flags, int argc, const char *argv[])
{
	const char *user = NULL;
	(void)flags;
	(void)argc;
	(void)argv;
	if (!on_console(pamh) || pam_get_user(pamh, &user, NULL) != PAM_SUCCESS || user == NULL)
		return PAM_SUCCESS;
	struct passwd *pw = getpwnam(user);
	if (pw != NULL)
		set_console(pw);
	return PAM_SUCCESS;
}

PAM_EXTERN int
pam_sm_close_session(pam_handle_t *pamh, int flags, int argc, const char *argv[])
{
	(void)flags;
	(void)argc;
	(void)argv;
	if (on_console(pamh))
		set_console(NULL);
	return PAM_SUCCESS;
}

PAM_MODULE_ENTRY("pam_console");
