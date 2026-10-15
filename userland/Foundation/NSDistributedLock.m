/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* A process-shared lock with an atomic marker and a persistent lock date. */
#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

@implementation NSDistributedLock {
    NSString *_path;
    NSString *_lockPath;
    dev_t _device;
    ino_t _inode;
    BOOL _locked;
}

+ (instancetype)lockWithPath:(NSString *)path
{
    return [[[self alloc] initWithPath:path] autorelease];
}

- (instancetype)initWithPath:(NSString *)path
{
    if (![path length]) {
        [self release];
        return nil;
    }
    if ((self = [super init])) {
        _path = [path copy];
        _lockPath = [[path stringByAppendingString:@".lock"] copy];
    }
    return self;
}

- (void)dealloc
{
    [self unlock];
    [_path release];
    [_lockPath release];
    [super dealloc];
}

- (BOOL)tryLock
{
    if (_locked)
        return NO;
    int fd = open([_lockPath fileSystemRepresentation], O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (fd < 0)
        return NO;
    struct stat marker;
    BOOL gotStat = fstat(fd, &marker) == 0;
    close(fd);
    int dateFD = open([_path fileSystemRepresentation], O_WRONLY | O_CREAT | O_CLOEXEC, 0600);
    if (!gotStat || dateFD < 0 || futimens(dateFD, NULL) != 0) {
        if (dateFD >= 0)
            close(dateFD);
        unlink([_lockPath fileSystemRepresentation]);
        return NO;
    }
    close(dateFD);
    _device = marker.st_dev;
    _inode = marker.st_ino;
    _locked = YES;
    return YES;
}

- (void)unlock
{
    if (!_locked)
        return;
    struct stat st;
    if (stat([_lockPath fileSystemRepresentation], &st) == 0 && st.st_dev == _device && st.st_ino == _inode)
        unlink([_lockPath fileSystemRepresentation]);
    _locked = NO;
}

- (void)breakLock
{
    unlink([_lockPath fileSystemRepresentation]);
    _locked = NO;
}

- (NSDate *)lockDate
{
    struct stat st;
    if (stat([_path fileSystemRepresentation], &st) != 0)
        return nil;
    return [NSDate dateWithTimeIntervalSince1970:st.st_mtimespec.tv_sec + st.st_mtimespec.tv_nsec / 1e9];
}

@end
