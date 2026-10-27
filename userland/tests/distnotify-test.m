/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-distnotify-test: NSDistributedNotificationCenter.
 *
 *   finch-distnotify-test          within the process, compared with Apple's on the host:
 *                                  selector and block observers, delivery after the post
 *                                  (on the main run loop), objects matched by value, user
 *                                  info, the poster receiving its own, removal
 *   finch-distnotify-test --cross  (guest: tools/vm/test-distnotify.sh) between processes:
 *                                  a child observes, the parent posts with user info, and
 *                                  the child reports what it got
 */
#import <Foundation/Foundation.h>
#include <spawn.h>
#include <stdio.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

@interface Watcher : NSObject
@property (strong) NSMutableArray<NSString *> *seen;
@end
@implementation Watcher
- (instancetype)init { if ((self = [super init])) _seen = [NSMutableArray array]; return self; }
- (void)noted:(NSNotification *)n
{
    [_seen addObject:[NSString stringWithFormat:@"%@ object=%@ info=%@", n.name, n.object ?: @"-",
                                                n.userInfo[@"k"] ?: @"-"]];
}
@end

static void
spin(double seconds, BOOL (^done)(void))
{
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ((!done || !done()) && [until timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
}

static void
within(void)
{
    NSDistributedNotificationCenter *dnc = [NSDistributedNotificationCenter defaultCenter];
    NSString *name = @"org.finch.test.distnotify.within";
    Watcher *w = [Watcher new], *any = [Watcher new];
    NSString *object = [NSString stringWithFormat:@"%@", @"the-object"];
    [dnc addObserver:w selector:@selector(noted:) name:name object:object];
    [dnc addObserver:any selector:@selector(noted:) name:name object:nil];
    __block NSMutableArray *blocks = [NSMutableArray array];
    id token = [dnc addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *n) {
        [blocks addObject:[NSString stringWithFormat:@"block %@ main=%d", n.object ?: @"-", [NSThread isMainThread]]];
    }];
    spin(0.5, nil);

    /* a different string object with the same characters matches */
    NSString *same = [[NSMutableString stringWithString:@"the-"] stringByAppendingString:@"object"];
    [dnc postNotificationName:name object:same userInfo:@{ @"k" : @"v1" } deliverImmediately:YES];
    printf("delivered during the post: %s\n", w.seen.count || any.seen.count || blocks.count ? "yes" : "no");
    spin(5, ^BOOL { return w.seen.count >= 1 && any.seen.count >= 1 && blocks.count >= 1; });
    printf("matching object: %s\n", [[w.seen componentsJoinedByString:@"; "] UTF8String]);
    printf("any object: %s\n", [[any.seen componentsJoinedByString:@"; "] UTF8String]);
    printf("block: %s\n", [[blocks componentsJoinedByString:@"; "] UTF8String]);

    /* another object: only the any-object observers */
    [dnc postNotificationName:name object:@"other" userInfo:nil deliverImmediately:YES];
    spin(5, ^BOOL { return any.seen.count >= 2 && blocks.count >= 2; });
    spin(0.3, nil);
    printf("other object: matching %lu, any %lu, block %lu\n", (unsigned long)w.seen.count, (unsigned long)any.seen.count,
        (unsigned long)blocks.count);

    /* removed: no more */
    [dnc removeObserver:w];
    [dnc removeObserver:token];
    [dnc postNotificationName:name object:object userInfo:nil deliverImmediately:YES];
    spin(5, ^BOOL { return any.seen.count >= 3; });
    spin(0.3, nil);
    printf("after removal: matching %lu, any %lu, block %lu\n", (unsigned long)w.seen.count, (unsigned long)any.seen.count,
        (unsigned long)blocks.count);
    [dnc removeObserver:any];
}

static int
child(void)
{
    NSDistributedNotificationCenter *dnc = [NSDistributedNotificationCenter defaultCenter];
    __block NSString *got = nil;
    [dnc addObserverForName:@"org.finch.test.distnotify.cross" object:@"from-parent" queue:nil
                 usingBlock:^(NSNotification *n) {
                     got = [NSString stringWithFormat:@"%@ %@ %@", n.name, n.object, n.userInfo[@"k"]];
                 }];
    /* (after the observation, on the same connection: the parent hears this once it's registered) */
    [dnc postNotificationName:@"org.finch.test.distnotify.ready" object:nil userInfo:nil deliverImmediately:YES];
    spin(20, ^BOOL { return got != nil; });
    printf("child got: %s\n", got ? got.UTF8String : "(nothing)");
    return got ? 0 : 1;
}

static int
cross(const char *self)
{
    NSDistributedNotificationCenter *dnc = [NSDistributedNotificationCenter defaultCenter];
    __block BOOL ready = NO;
    [dnc addObserverForName:@"org.finch.test.distnotify.ready" object:nil queue:nil
                 usingBlock:^(NSNotification *n) { (void)n; ready = YES; }];
    spin(0.5, nil);
    pid_t pid;
    char *args[] = {(char *)self, "--child", NULL};
    if (posix_spawnp(&pid, self, NULL, NULL, args, environ) != 0) {
        printf("can't start the child\n");
        return 1;
    }
    spin(20, ^BOOL { return ready; });
    printf("child ready: %s\n", ready ? "yes" : "no");
    [dnc postNotificationName:@"org.finch.test.distnotify.cross" object:@"from-parent" userInfo:@{ @"k" : @"cross-info" }
           deliverImmediately:YES];
    int status = 0;
    waitpid(pid, &status, 0);
    printf("child: %s\n", WIFEXITED(status) && WEXITSTATUS(status) == 0 ? "received" : "failed");
    return ready && WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : 1;
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        if (argc > 1 && !strcmp(argv[1], "--child"))
            return child();
        if (argc > 1 && !strcmp(argv[1], "--cross"))
            return cross(argv[0]);
        within();
    }
    return 0;
}
