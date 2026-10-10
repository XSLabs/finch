/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * ServiceManagement: an app's login items, agents and daemons. On Finch an agent or a
 * login item is a launchd job of the user's: registering one writes its plist to
 * ~/Library/LaunchAgents (where finch-init loads the user's agents from at login) and
 * bootstraps it now with launchctl; unregistering boots it out and removes the plist.
 * The app itself as a login item is such a job running the app. Daemons and the
 * privileged-helper calls (SMJobBless, SMJobSubmit) need an administrator's approval,
 * which Finch can't ask for yet: they fail as when it's refused.
 */
#import <Foundation/Foundation.h>
#import <ServiceManagement/ServiceManagement.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static NSString *
agents_dir(void)
{
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/LaunchAgents"];
}

static int
launchctl(NSArray<NSString *> *args)
{
    NSMutableArray *all = [NSMutableArray arrayWithObject:@"launchctl"];
    [all addObjectsFromArray:args];
    char **argv = calloc(all.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < all.count; i++)
        argv[i] = (char *)[all[i] fileSystemRepresentation];
    pid_t pid;
    int status = -1;
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0);
    if (posix_spawn(&pid, "/bin/launchctl", &fa, NULL, argv, environ) == 0)
        waitpid(pid, &status, 0);
    posix_spawn_file_actions_destroy(&fa);
    free(argv);
    return status;
}

static NSString *
domain(void)
{
    return [NSString stringWithFormat:@"gui/%u", getuid()];
}

static NSError *
sm_error(NSInteger code)
{
    return [NSError errorWithDomain:SMAppServiceErrorDomain code:code userInfo:nil];
}

/* Writes a job's plist to the user's agents and loads it. */
static BOOL
install_agent(NSString *label, NSDictionary *job, NSError **error)
{
    NSString *dir = agents_dir();
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *path = [dir stringByAppendingPathComponent:[label stringByAppendingPathExtension:@"plist"]];
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        if (error)
            *error = sm_error(kSMErrorAlreadyRegistered);
        return NO;
    }
    if (![job writeToFile:path atomically:YES]) {
        if (error)
            *error = sm_error(kSMErrorInternalFailure);
        return NO;
    }
    launchctl(@[ @"bootstrap", domain(), path ]);
    return YES;
}

static BOOL
remove_agent(NSString *label, NSError **error)
{
    NSString *path = [agents_dir() stringByAppendingPathComponent:[label stringByAppendingPathExtension:@"plist"]];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        if (error)
            *error = sm_error(kSMErrorJobNotFound);
        return NO;
    }
    launchctl(@[ @"bootout", [NSString stringWithFormat:@"%@/%@", domain(), label] ]);
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    return YES;
}

static BOOL
agent_installed(NSString *label)
{
    NSString *path = [agents_dir() stringByAppendingPathComponent:[label stringByAppendingPathExtension:@"plist"]];
    return [[NSFileManager defaultManager] fileExistsAtPath:path];
}

typedef NS_ENUM(NSInteger, FinchServiceKind) { FinchServiceMainApp, FinchServiceLoginItem, FinchServiceAgent, FinchServiceDaemon };

@implementation SMAppService {
    FinchServiceKind _kind;
    NSString *_name; /* the login item's identifier, or the plist's name */
}

+ (instancetype)_finchService:(FinchServiceKind)kind name:(NSString *)name
{
    SMAppService *s = [[self alloc] _finchInit];
    s->_kind = kind;
    s->_name = [name copy];
    return s;
}

- (instancetype)_finchInit __attribute__((objc_method_family(init))) { return [super init]; }

+ (instancetype)loginItemServiceWithIdentifier:(NSString *)identifier
{
    return [self _finchService:FinchServiceLoginItem name:identifier];
}

+ (SMAppService *)mainAppService
{
    return [self _finchService:FinchServiceMainApp name:[NSBundle mainBundle].bundleIdentifier];
}

+ (instancetype)agentServiceWithPlistName:(NSString *)plistName { return [self _finchService:FinchServiceAgent name:plistName]; }
+ (instancetype)daemonServiceWithPlistName:(NSString *)plistName { return [self _finchService:FinchServiceDaemon name:plistName]; }

/* The job's label, and its plist as it should be loaded. */
- (NSString *)_finchLabel
{
    if (_kind == FinchServiceAgent || _kind == FinchServiceDaemon) {
        NSDictionary *plist = [self _finchBundledPlist];
        return plist[@"Label"] ?: [_name stringByDeletingPathExtension];
    }
    return _name;
}

- (NSDictionary *)_finchBundledPlist
{
    NSString *dir = _kind == FinchServiceDaemon ? @"Contents/Library/LaunchDaemons" : @"Contents/Library/LaunchAgents";
    NSString *path = [[[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:dir] stringByAppendingPathComponent:_name];
    return [NSDictionary dictionaryWithContentsOfFile:path];
}

- (NSDictionary *)_finchJob
{
    NSBundle *main = [NSBundle mainBundle];
    if (_kind == FinchServiceMainApp)
        return @{@"Label" : _name ?: @"app", @"ProgramArguments" : @[ main.executablePath ?: @"" ], @"RunAtLoad" : @YES,
                 @"LimitLoadToSessionType" : @"Aqua"};
    if (_kind == FinchServiceLoginItem) {
        NSString *items = [main.bundlePath stringByAppendingPathComponent:@"Contents/Library/LoginItems"];
        for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:items error:NULL]) {
            NSBundle *b = [NSBundle bundleWithPath:[items stringByAppendingPathComponent:name]];
            if ([b.bundleIdentifier isEqualToString:_name])
                return @{@"Label" : _name, @"ProgramArguments" : @[ b.executablePath ], @"RunAtLoad" : @YES,
                         @"LimitLoadToSessionType" : @"Aqua"};
        }
        return nil;
    }
    NSMutableDictionary *job = [[self _finchBundledPlist] mutableCopy];
    if (!job)
        return nil;
    /* BundleProgram is relative to the app */
    NSString *bp = job[@"BundleProgram"];
    if (bp) {
        NSString *exe = [main.bundlePath stringByAppendingPathComponent:bp];
        job[@"Program"] = exe;
        [job removeObjectForKey:@"BundleProgram"];
    }
    return job;
}

- (BOOL)registerAndReturnError:(NSError **)error
{
    if (_kind == FinchServiceDaemon) {
        if (error)
            *error = sm_error(kSMErrorLaunchDeniedByUser);
        return NO;
    }
    NSDictionary *job = [self _finchJob];
    if (!job) {
        if (error)
            *error = sm_error(kSMErrorJobNotFound);
        return NO;
    }
    return install_agent([self _finchLabel], job, error);
}

- (BOOL)unregisterAndReturnError:(NSError **)error
{
    if (_kind == FinchServiceDaemon) {
        if (error)
            *error = sm_error(kSMErrorJobNotFound);
        return NO;
    }
    return remove_agent([self _finchLabel], error);
}

- (void)unregisterWithCompletionHandler:(void (^)(NSError *))handler
{
    NSError *e = nil;
    [self unregisterAndReturnError:&e];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ handler(e); });
}

- (SMAppServiceStatus)status
{
    if (_kind == FinchServiceDaemon)
        return [self _finchBundledPlist] ? SMAppServiceStatusNotRegistered : SMAppServiceStatusNotFound;
    if (_kind != FinchServiceMainApp && ![self _finchJob])
        return SMAppServiceStatusNotFound;
    return agent_installed([self _finchLabel]) ? SMAppServiceStatusEnabled : SMAppServiceStatusNotRegistered;
}

+ (SMAppServiceStatus)statusForLegacyURL:(NSURL *)url
{
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfURL:url];
    if (!plist)
        return SMAppServiceStatusNotFound;
    return agent_installed(plist[@"Label"] ?: @"") ? SMAppServiceStatusEnabled : SMAppServiceStatusNotRegistered;
}

+ (void)openSystemSettingsLoginItems {}

@end

/* --- the older C interface --- */

Boolean
SMLoginItemSetEnabled(CFStringRef identifier, Boolean enabled)
{
    SMAppService *s = [SMAppService loginItemServiceWithIdentifier:(__bridge NSString *)identifier];
    if (enabled)
        return [s registerAndReturnError:NULL] || s.status == SMAppServiceStatusEnabled;
    return [s unregisterAndReturnError:NULL] || s.status == SMAppServiceStatusNotRegistered;
}

static void
set_error(CFErrorRef *error, CFStringRef domain, CFIndex code)
{
    if (error)
        *error = CFErrorCreate(NULL, domain, code, NULL);
}

/* An administrator's approval can't be asked for yet: as when it's refused. */
Boolean
SMJobBless(CFStringRef domain, CFStringRef executableLabel, AuthorizationRef auth, CFErrorRef *outError)
{
    set_error(outError, kSMErrorDomainFramework, kSMErrorAuthorizationFailure);
    return false;
}

Boolean
SMJobSubmit(CFStringRef domain, CFDictionaryRef job, AuthorizationRef auth, CFErrorRef *outError)
{
    if (domain && CFEqual(domain, kSMDomainUserLaunchd)) {
        NSString *label = ((__bridge NSDictionary *)job)[@"Label"];
        NSError *e = nil;
        if (label && install_agent(label, (__bridge NSDictionary *)job, &e))
            return true;
        set_error(outError, kSMErrorDomainLaunchd, e ? e.code : kSMErrorInternalFailure);
        return false;
    }
    set_error(outError, kSMErrorDomainFramework, kSMErrorAuthorizationFailure);
    return false;
}

Boolean
SMJobRemove(CFStringRef domain, CFStringRef jobLabel, AuthorizationRef auth, Boolean wait, CFErrorRef *outError)
{
    if (domain && CFEqual(domain, kSMDomainUserLaunchd)) {
        NSError *e = nil;
        if (remove_agent((__bridge NSString *)jobLabel, &e))
            return true;
        set_error(outError, kSMErrorDomainLaunchd, kSMErrorJobNotFound);
        return false;
    }
    set_error(outError, kSMErrorDomainFramework, kSMErrorAuthorizationFailure);
    return false;
}

/* The user's agents installed with ServiceManagement (what it knows of; the jobs
   finch-init runs are launchctl's to list). */
CFArrayRef
SMCopyAllJobDictionaries(CFStringRef domain)
{
    NSMutableArray *jobs = [NSMutableArray array];
    if (domain && CFEqual(domain, kSMDomainUserLaunchd))
        for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:agents_dir() error:NULL]) {
            NSDictionary *job = [NSDictionary dictionaryWithContentsOfFile:[agents_dir() stringByAppendingPathComponent:name]];
            if (job[@"Label"])
                [jobs addObject:job];
        }
    return (CFArrayRef)CFBridgingRetain(jobs);
}

CFDictionaryRef
SMJobCopyDictionary(CFStringRef domain, CFStringRef jobLabel)
{
    if (!domain || !CFEqual(domain, kSMDomainUserLaunchd))
        return NULL;
    NSString *path = [agents_dir() stringByAppendingPathComponent:[(__bridge NSString *)jobLabel stringByAppendingPathExtension:@"plist"]];
    NSDictionary *job = [NSDictionary dictionaryWithContentsOfFile:path];
    return job ? (CFDictionaryRef)CFBridgingRetain(job) : NULL;
}
