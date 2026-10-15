/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Compare NSURLSession's HTTPS server-trust challenges with Apple's. */
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <limits.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

static int server_port;
static pid_t server_pid = -1;
static char server_dir[PATH_MAX];

typedef NS_ENUM(NSInteger, TrustAnswer) {
    TrustAnswerDefault,
    TrustAnswerAccept,
    TrustAnswerCancel,
    TrustAnswerReject
};

static void
write_file(const char *name, const char *contents)
{
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/%s", server_dir, name);
    FILE *file = fopen(path, "wb");
    if (!file) {
        perror(path);
        exit(2);
    }
    int failed = fwrite(contents, 1, strlen(contents), file) != strlen(contents);
    if (fclose(file) != 0)
        failed = 1;
    if (failed) {
        perror(path);
        exit(2);
    }
}

static void
run_openssl(char *const argv[])
{
    pid_t child = fork();
    if (child < 0) {
        perror("fork");
        exit(2);
    }
    if (!child) {
        int null = open("/dev/null", O_RDWR);
        if (null >= 0) {
            dup2(null, STDOUT_FILENO);
            dup2(null, STDERR_FILENO);
            close(null);
        }
        execv("/usr/bin/openssl", argv);
        _exit(127);
    }
    int status;
    if (waitpid(child, &status, 0) != child || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        fprintf(stderr, "openssl command failed\n");
        exit(2);
    }
}

static int
unused_port(void)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in address = {.sin_len = sizeof address, .sin_family = AF_INET,
                                  .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    socklen_t length = sizeof address;
    if (fd < 0 || bind(fd, (struct sockaddr *)&address, sizeof address) != 0 ||
        getsockname(fd, (struct sockaddr *)&address, &length) != 0) {
        perror("find port");
        exit(2);
    }
    int port = ntohs(address.sin_port);
    close(fd);
    return port;
}

static int
server_ready(void)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in address = {.sin_len = sizeof address, .sin_family = AF_INET,
                                  .sin_port = htons(server_port),
                                  .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    int ready = fd >= 0 && connect(fd, (struct sockaddr *)&address, sizeof address) == 0;
    if (fd >= 0)
        close(fd);
    return ready;
}

static void
start_server(void)
{
    char cwd[PATH_MAX];
    if (!getcwd(cwd, sizeof cwd)) {
        perror("getcwd");
        exit(2);
    }
    snprintf(server_dir, sizeof server_dir, "%s/build/urlsession-trust.XXXXXX", cwd);
    if (!mkdtemp(server_dir)) {
        perror("mkdtemp");
        exit(2);
    }
    write_file("body.txt", "server trust accepted\n");
    write_file("openssl.cnf",
               "[req]\n"
               "distinguished_name=subject\n"
               "x509_extensions=server\n"
               "prompt=no\n"
               "[subject]\n"
               "CN=Finch Trust Test\n"
               "[server]\n"
               "basicConstraints=critical,CA:FALSE\n"
               "keyUsage=critical,digitalSignature,keyEncipherment\n"
               "extendedKeyUsage=serverAuth\n"
               "subjectAltName=IP:127.0.0.1\n");

    char config[PATH_MAX], certificate[PATH_MAX], key[PATH_MAX];
    snprintf(config, sizeof config, "%s/openssl.cnf", server_dir);
    snprintf(certificate, sizeof certificate, "%s/cert.pem", server_dir);
    snprintf(key, sizeof key, "%s/key.pem", server_dir);
    char *const create[] = {"openssl", "req", "-new", "-x509", "-nodes", "-newkey", "rsa:2048", "-days", "1",
                            "-config", config, "-keyout", key, "-out", certificate, NULL};
    run_openssl(create);

    server_port = unused_port();
    char port[16];
    snprintf(port, sizeof port, "%d", server_port);
    server_pid = fork();
    if (server_pid < 0) {
        perror("fork server");
        exit(2);
    }
    if (!server_pid) {
        if (chdir(server_dir) != 0)
            _exit(126);
        int null = open("/dev/null", O_RDWR);
        if (null >= 0) {
            dup2(null, STDOUT_FILENO);
            dup2(null, STDERR_FILENO);
            close(null);
        }
        execl("/usr/bin/openssl", "openssl", "s_server", "-quiet", "-WWW", "-accept", port,
              "-cert", certificate, "-key", key, (char *)NULL);
        _exit(127);
    }
    for (int i = 0; i < 100 && !server_ready(); i++)
        usleep(20000);
    if (!server_ready()) {
        fprintf(stderr, "openssl TLS server did not start\n");
        exit(2);
    }
}

static void
stop_server(void)
{
    if (server_pid > 0) {
        kill(server_pid, SIGTERM);
        waitpid(server_pid, NULL, 0);
        server_pid = -1;
    }
    if (server_dir[0]) {
        char path[PATH_MAX];
        const char *files[] = {"body.txt", "openssl.cnf", "cert.pem", "key.pem"};
        for (size_t i = 0; i < sizeof files / sizeof files[0]; i++) {
            snprintf(path, sizeof path, "%s/%s", server_dir, files[i]);
            unlink(path);
        }
        rmdir(server_dir);
        server_dir[0] = 0;
    }
}

@interface TrustDelegateBase : NSObject {
  @public
    TrustAnswer answer;
}
- (instancetype)initWithAnswer:(TrustAnswer)choice;
- (void)handleChallenge:(NSURLAuthenticationChallenge *)challenge
      completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler
                  route:(const char *)route;
@end

@implementation TrustDelegateBase
- (instancetype)initWithAnswer:(TrustAnswer)choice
{
    if ((self = [super init])) {
        answer = choice;
    }
    return self;
}
- (void)handleChallenge:(NSURLAuthenticationChallenge *)challenge
      completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler
                  route:(const char *)route
{
    NSURLProtectionSpace *space = challenge.protectionSpace;
    SecTrustRef trust = space.serverTrust;
    CFArrayRef chain = trust ? SecTrustCopyCertificateChain(trust) : NULL;
    CFStringRef summary = chain && CFArrayGetCount(chain)
                              ? SecCertificateCopySubjectSummary((SecCertificateRef)CFArrayGetValueAtIndex(chain, 0))
                              : NULL;
    char port_text[24];
    if (space.port == server_port)
        snprintf(port_text, sizeof port_text, "ours");
    else
        snprintf(port_text, sizeof port_text, "%ld", (long)space.port);
    printf("  challenge route %s method %s host %s port %s protocol %s serverTrust %d\n", route,
           space.authenticationMethod.UTF8String ?: "(nil)", space.host.UTF8String ?: "(nil)",
           port_text, space.protocol.UTF8String ?: "(nil)", trust != NULL);
    if (summary) {
        CFIndex length = CFStringGetLength(summary);
        CFIndex max = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1;
        char *text = malloc((size_t)max);
        if (text && CFStringGetCString(summary, text, max, kCFStringEncodingUTF8))
            printf("  leaf subject %s\n", text);
        else
            printf("  leaf subject (nil)\n");
        free(text);
    } else {
        printf("  leaf subject (nil)\n");
    }
    if (summary)
        CFRelease(summary);
    if (chain)
        CFRelease(chain);

    switch (answer) {
    case TrustAnswerAccept:
        completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:trust]);
        break;
    case TrustAnswerCancel:
        completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
        break;
    case TrustAnswerReject:
        completionHandler(NSURLSessionAuthChallengeRejectProtectionSpace, nil);
        break;
    default:
        completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
        break;
    }
}
@end

@interface SessionTrustDelegate : TrustDelegateBase <NSURLSessionDelegate>
@end
@implementation SessionTrustDelegate
- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
    completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler
{
    [self handleChallenge:challenge completionHandler:completionHandler route:"session"];
}
@end

@interface TaskTrustDelegate : TrustDelegateBase <NSURLSessionTaskDelegate>
@end
@implementation TaskTrustDelegate
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
    completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler
{
    [self handleChallenge:challenge completionHandler:completionHandler route:"task"];
}
@end

static void
run_case(const char *name, TrustDelegateBase *delegate)
{
    printf("%s:\n", name);
    NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]
                                                          delegate:(id)delegate
                                                     delegateQueue:nil];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSData *data = nil;
    __block NSError *failure = nil;
    NSString *address = [NSString stringWithFormat:@"https://127.0.0.1:%d/body.txt", server_port];
    [[session dataTaskWithURL:[NSURL URLWithString:address]
            completionHandler:^(NSData *result, NSURLResponse *response, NSError *error) {
              data = result;
              failure = error;
              dispatch_semaphore_signal(done);
            }] resume];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    if (failure)
        printf("  error %ld\n", (long)failure.code);
    else
        printf("  body %s", [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] UTF8String] ?: "(nil)\n");
    [session finishTasksAndInvalidate];
}

int
main(void)
{
    @autoreleasepool {
        Dl_info info;
        dladdr((__bridge const void *)[NSURLSession class], &info);
        atexit(stop_server);
        printf("NSURLSession from %s\n", info.dli_fname);
        start_server();
        run_case("default", nil);
        run_case("accept session", [[SessionTrustDelegate alloc] initWithAnswer:TrustAnswerAccept]);
        run_case("cancel task", [[TaskTrustDelegate alloc] initWithAnswer:TrustAnswerCancel]);
        run_case("default session", [[SessionTrustDelegate alloc] initWithAnswer:TrustAnswerDefault]);
        run_case("reject session", [[SessionTrustDelegate alloc] initWithAnswer:TrustAnswerReject]);
        stop_server();
    }
    return 0;
}
