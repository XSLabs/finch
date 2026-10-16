/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Compare Finch's ContactsUI, CoreSpotlight and LinkPresentation with the Mac frameworks. */
#import <AppKit/AppKit.h>
#import <Contacts/Contacts.h>
#import <ContactsUI/ContactsUI.h>
#import <CoreSpotlight/CoreSpotlight.h>
#import <LinkPresentation/LinkPresentation.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <pthread.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

FOUNDATION_EXPORT NSString *const MDItemContentType;
FOUNDATION_EXPORT NSString *const MDItemKind;
FOUNDATION_EXPORT NSString *const MDItemUniqueIdentifier;
FOUNDATION_EXPORT NSString *const CSItemSummaryTypeAttachment;
FOUNDATION_EXPORT NSString *const CSItemSummaryTypeContact;
FOUNDATION_EXPORT NSString *const CSItemSummaryTypeDate;
FOUNDATION_EXPORT NSString *const CSItemSummaryTypeText;

static void
contact_ui(void)
{
    CNContactPicker *picker = [[CNContactPicker alloc] init];
    picker.displayedKeys = @[ CNContactEmailAddressesKey ];
    printf("contact picker keys: %lu\n", (unsigned long)picker.displayedKeys.count);

    CNContactViewController *viewController = [[CNContactViewController alloc] init];
    printf("contact card API: class %d set-contact %d\n", viewController != nil,
           [viewController respondsToSelector:@selector(setContact:)]);
}

static BOOL
wait_for(dispatch_semaphore_t semaphore)
{
    return dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC)) == 0;
}

static void
core_spotlight(void)
{
    CSSearchableIndex *index = [[CSSearchableIndex alloc] initWithName:@"org.finch.framework-comparison-test"];
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSError *indexError = nil;
    [index deleteAllSearchableItemsWithCompletionHandler:^(NSError *error) {
        indexError = error;
        dispatch_semaphore_signal(semaphore);
    }];
    BOOL cleared = wait_for(semaphore) && indexError == nil;

    CSSearchableItemAttributeSet *attributes = [[CSSearchableItemAttributeSet alloc] initWithItemContentType:@"public.text"];
    attributes.title = @"Finch Search Item";
    attributes.displayName = @"Finch Search Item";
    attributes.textContent = @"local metadata search";
    CSCustomAttributeKey *customKey = [[CSCustomAttributeKey alloc] initWithKeyName:@"org_finch_test_marker"];
    [attributes setValue:@"kept" forCustomKey:customKey];
    CSSearchableItem *item = [[CSSearchableItem alloc] initWithUniqueIdentifier:@"finch-search-item" domainIdentifier:@"finch-test" attributeSet:attributes];

    semaphore = dispatch_semaphore_create(0);
    __block NSError *writeError = nil;
    [index indexSearchableItems:@[ item ] completionHandler:^(NSError *error) {
        writeError = error;
        dispatch_semaphore_signal(semaphore);
    }];
    BOOL indexed = wait_for(semaphore) && writeError == nil;

    CSSearchQueryContext *queryContext = [[CSSearchQueryContext alloc] init];
    queryContext.fetchAttributes = @[ @"title" ];
    CSSearchQuery *query = [[CSSearchQuery alloc] initWithQueryString:@"title == \"Finch Search Item\"" queryContext:queryContext];
    __block NSUInteger resultCount = 0;
    __block NSString *resultTitle = nil;
    __block NSError *queryError = nil;
    if (indexed) {
        query.foundItemsHandler = ^(NSArray<CSSearchableItem *> *items) {
            resultCount += items.count;
            resultTitle = items.firstObject.attributeSet.title;
        };
        query.completionHandler = ^(NSError *error) {
            queryError = error;
            dispatch_semaphore_signal(semaphore);
        };
        [query start];
    }
    BOOL queried = indexed && wait_for(semaphore) && queryError == nil;

    CSSearchQuery *cancelQuery = [[CSSearchQuery alloc] initWithQueryString:@"title == \"Finch Search Item\"" queryContext:queryContext];
    semaphore = dispatch_semaphore_create(0);
    __block NSError *cancelError = nil;
    __weak CSSearchQuery *weakCancelQuery = cancelQuery;
    cancelQuery.foundItemsHandler = ^(NSArray<CSSearchableItem *> *items) {
        [weakCancelQuery cancel];
    };
    cancelQuery.completionHandler = ^(NSError *error) {
        cancelError = error;
        dispatch_semaphore_signal(semaphore);
    };
    [cancelQuery start];
    BOOL cancelled = wait_for(semaphore) && [cancelError.domain isEqualToString:CSSearchQueryErrorDomain] &&
        cancelError.code == CSSearchQueryErrorCodeCancelled;
    printf("spotlight: available %d cleared %d indexed %d title '%s' custom '%s' query %d results %lu '%s' error %ld\n",
           [CSSearchableIndex isIndexingAvailable], cleared, indexed, attributes.title.UTF8String ?: "",
           [(id)[attributes valueForCustomKey:customKey] description].UTF8String ?: "", queried,
           (unsigned long)resultCount, resultTitle.UTF8String ?: "", (long)(queryError ? queryError.code : 0));
    printf("spotlight cancellation: %d error %ld\n", cancelled, (long)(cancelError ? cancelError.code : 0));
    printf("metadata names: %s %s %s %s %s %s %s\n", MDItemContentType.UTF8String, MDItemKind.UTF8String,
           MDItemUniqueIdentifier.UTF8String, CSItemSummaryTypeAttachment.UTF8String, CSItemSummaryTypeContact.UTF8String,
           CSItemSummaryTypeDate.UTF8String, CSItemSummaryTypeText.UTF8String);

    semaphore = dispatch_semaphore_create(0);
    [index deleteSearchableItemsWithDomainIdentifiers:@[ @"finch-test" ] completionHandler:^(NSError *error) {
        dispatch_semaphore_signal(semaphore);
    }];
    (void)wait_for(semaphore);
}

typedef struct {
    int listener;
} LocalServer;

static void *
serve_page(void *argument)
{
    LocalServer *server = argument;
    struct pollfd waitForConnection = { .fd = server->listener, .events = POLLIN };
    if (poll(&waitForConnection, 1, 7000) <= 0)
        return NULL;
    int client = accept(server->listener, NULL, NULL);
    if (client < 0)
        return NULL;
    char request[2048];
    (void)read(client, request, sizeof(request));
    const char *body = "<html><head><meta property=\"og:title\" content=\"Finch Link Card\"><title>Fallback</title></head><body>Page</body></html>";
    char response[1024];
    int size = snprintf(response, sizeof(response), "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n%s",
                        (unsigned long)strlen(body), body);
    (void)write(client, response, (size_t)size);
    close(client);
    return NULL;
}

static void
link_card(void)
{
    NSURL *url = [NSURL URLWithString:@"https://example.test/article"];
    LPLinkMetadata *metadata = [[LPLinkMetadata alloc] init];
    metadata.originalURL = url;
    metadata.URL = url;
    metadata.title = @"Finch Link Card";
    LPLinkView *view = [[LPLinkView alloc] initWithMetadata:metadata];
    printf("link card: title '%s' host '%s' view '%s'\n", metadata.title.UTF8String ?: "",
           metadata.URL.host.UTF8String ?: "", view.metadata.title.UTF8String ?: "");
}

static void
link_fetch_local(void)
{
    struct sockaddr_in address = { .sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK), .sin_port = 0 };
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    if (listener < 0 || bind(listener, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(listener, 1) != 0) {
        printf("link fetch: local server unavailable\n");
        if (listener >= 0)
            close(listener);
        return;
    }
    socklen_t addressSize = sizeof(address);
    getsockname(listener, (struct sockaddr *)&address, &addressSize);
    LocalServer server = { listener };
    pthread_t thread;
    pthread_create(&thread, NULL, serve_page, &server);

    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%u/page", ntohs(address.sin_port)]];
    LPMetadataProvider *provider = [[LPMetadataProvider alloc] init];
    provider.shouldFetchSubresources = NO;
    provider.timeout = 5.0;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block LPLinkMetadata *metadata = nil;
    __block NSError *fetchError = nil;
    [provider startFetchingMetadataForURL:url completionHandler:^(LPLinkMetadata *result, NSError *error) {
        metadata = result;
        fetchError = error;
        dispatch_semaphore_signal(semaphore);
    }];
    BOOL completed = wait_for(semaphore);
    [provider cancel];
    pthread_join(thread, NULL);
    close(listener);

    if (completed && metadata) {
        LPLinkView *view = [[LPLinkView alloc] initWithMetadata:metadata];
        printf("link fetch: title '%s' host '%s' view '%s'\n", metadata.title.UTF8String ?: "",
               metadata.URL.host.UTF8String ?: "", view.metadata.title.UTF8String ?: "");
    } else {
        printf("link fetch: error %ld\n", (long)(fetchError ? fetchError.code : -1));
    }
}

int
main(int argc, char **argv)
{
    if (argc == 2 && strcmp(argv[1], "--fetch-local") == 0) {
        link_fetch_local();
        return 0;
    }
    Dl_info info = {0};
    dladdr((__bridge const void *)[CSSearchableIndex class], &info);
    printf("%s\n", info.dli_fname ?: "?");
    contact_ui();
    core_spotlight();
    link_card();
    return 0;
}
