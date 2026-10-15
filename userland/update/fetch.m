/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-update fetch: an update and its signature downloaded with NSURLSession (Finch's
 * Foundation on Finch). A download cut short keeps its resume data beside where the file
 * goes (NAME.resume), and continues from it: at once, up to FINCH_UPDATE_ATTEMPTS times
 * (5), and on the next fetch if those run out. (The partial file itself is in the temporary
 * folder; if it's gone, the download starts again.)
 */
#import <Foundation/Foundation.h>

int finch_update_fetch(const char *url, const char *dir, char *archive, size_t archiveSize);

/* One file: URL into DIR under its own name. */
static BOOL
fetch_one(NSURL *url, NSString *dir, int attempts, NSString **outPath)
{
    NSString *name = url.lastPathComponent;
    NSString *dest = [dir stringByAppendingPathComponent:name];
    NSString *resumePath = [dest stringByAppendingString:@".resume"];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (int attempt = 1; attempt <= attempts; attempt++) {
        NSData *resume = [NSData dataWithContentsOfFile:resumePath];
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block NSError *failure = nil;
        __block NSInteger status = 0;
        __block BOOL placed = NO;
        void (^finished)(NSURL *, NSURLResponse *, NSError *) = ^(NSURL *location, NSURLResponse *response, NSError *error) {
          failure = error;
          status = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 200;
          if (location && status >= 200 && status < 300) {
              [fm removeItemAtPath:dest error:NULL];
              NSError *moveError = nil;
              placed = [fm moveItemAtURL:location toURL:[NSURL fileURLWithPath:dest] error:&moveError];
              if (!placed)
                  failure = moveError;
          }
          dispatch_semaphore_signal(done);
        };
        NSURLSession *session = [NSURLSession sharedSession];
        NSURLSessionDownloadTask *task = resume ? [session downloadTaskWithResumeData:resume completionHandler:finished]
                                                : [session downloadTaskWithURL:url completionHandler:finished];
        if (resume)
            printf("finch-update: resuming %s\n", name.UTF8String);
        [task resume];
        dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
        if (placed) {
            [fm removeItemAtPath:resumePath error:NULL];
            *outPath = dest;
            return YES;
        }
        if (!failure) {
            [fm removeItemAtPath:resumePath error:NULL];
            fprintf(stderr, "finch-update: %s: HTTP %ld\n", url.absoluteString.UTF8String, (long)status);
            return NO;
        }
        NSData *more = failure.userInfo[NSURLSessionDownloadTaskResumeData];
        if (more) {
            [more writeToFile:resumePath atomically:YES];
            fprintf(stderr, "finch-update: %s stopped after %lld bytes (%s); its resume data is in %s\n", name.UTF8String,
                    task.countOfBytesReceived, failure.localizedDescription.UTF8String, resumePath.UTF8String);
        } else {
            [fm removeItemAtPath:resumePath error:NULL];
            fprintf(stderr, "finch-update: %s: %s\n", url.absoluteString.UTF8String, failure.localizedDescription.UTF8String);
        }
        if (attempt < attempts)
            sleep(1);
    }
    return NO;
}

/* The update at URL and URL.sig, into DIR; the archive's path in archive. */
int
finch_update_fetch(const char *url, const char *dir, char *archive, size_t archiveSize)
{
    @autoreleasepool {
        NSURL *u = [NSURL URLWithString:@(url)];
        NSURL *sig = [NSURL URLWithString:[u.absoluteString stringByAppendingString:@".sig"]];
        const char *env = getenv("FINCH_UPDATE_ATTEMPTS");
        int attempts = env && atoi(env) > 0 ? atoi(env) : 5;
        NSString *d = @(dir), *path = nil, *sigPath = nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:NULL];
        if (!u.lastPathComponent.length || !fetch_one(u, d, attempts, &path) || !fetch_one(sig, d, attempts, &sigPath))
            return 1;
        snprintf(archive, archiveSize, "%s", path.fileSystemRepresentation);
        return 0;
    }
}
