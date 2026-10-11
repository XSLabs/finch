/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Verify that DNS-SD clients can register and browse through the local daemon. */
#include <dns_sd.h>

#include <arpa/inet.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/select.h>
#include <time.h>
#include <unistd.h>

typedef struct
{
    char name[64];
    DNSServiceErrorType error;
    int registered;
    int found;
} TestState;

static void DNSSD_API register_reply(DNSServiceRef service, DNSServiceFlags flags,
    DNSServiceErrorType error, const char *name, const char *type, const char *domain,
    void *context)
{
    TestState *state = context;
    (void)service;
    (void)flags;
    (void)type;
    (void)domain;
    if (error != kDNSServiceErr_NoError)
    {
        state->error = error;
        return;
    }
    if (strcmp(name, state->name) != 0)
    {
        state->error = kDNSServiceErr_BadParam;
        return;
    }
    state->registered = 1;
}

static void DNSSD_API browse_reply(DNSServiceRef service, DNSServiceFlags flags,
    uint32_t interfaceIndex, DNSServiceErrorType error, const char *name,
    const char *type, const char *domain, void *context)
{
    TestState *state = context;
    (void)service;
    (void)interfaceIndex;
    (void)type;
    (void)domain;
    if (error != kDNSServiceErr_NoError)
    {
        state->error = error;
        return;
    }
    if ((flags & kDNSServiceFlagsAdd) && strcmp(name, state->name) == 0)
        state->found = 1;
}

static int make_timeout(const struct timespec *deadline, struct timeval *timeout)
{
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0)
        return -1;

    time_t seconds = deadline->tv_sec - now.tv_sec;
    long nanoseconds = deadline->tv_nsec - now.tv_nsec;
    if (nanoseconds < 0)
    {
        --seconds;
        nanoseconds += 1000000000L;
    }
    if (seconds < 0)
        return 0;

    timeout->tv_sec = seconds;
    timeout->tv_usec = nanoseconds / 1000;
    return 1;
}

static int wait_for_service(DNSServiceRef registration, DNSServiceRef browser, TestState *state)
{
    const int registration_fd = DNSServiceRefSockFD(registration);
    const int browser_fd = DNSServiceRefSockFD(browser);
    int max_fd = registration_fd > browser_fd ? registration_fd : browser_fd;
    if (registration_fd < 0 || browser_fd < 0)
        return -1;

    struct timespec deadline;
    if (clock_gettime(CLOCK_MONOTONIC, &deadline) != 0)
        return -1;
    deadline.tv_sec += 5;

    while (!state->error && !(state->registered && state->found))
    {
        fd_set read_fds;
        FD_ZERO(&read_fds);
        FD_SET(registration_fd, &read_fds);
        FD_SET(browser_fd, &read_fds);

        struct timeval timeout;
        int remaining = make_timeout(&deadline, &timeout);
        if (remaining <= 0)
            return remaining;

        int ready = select(max_fd + 1, &read_fds, NULL, NULL, &timeout);
        if (ready < 0)
        {
            if (errno == EINTR)
                continue;
            return -1;
        }
        if (ready == 0)
            return 0;

        if (FD_ISSET(registration_fd, &read_fds))
            state->error = DNSServiceProcessResult(registration);
        if (!state->error && FD_ISSET(browser_fd, &read_fds))
            state->error = DNSServiceProcessResult(browser);
    }
    return state->registered && state->found ? 1 : -1;
}

int main(void)
{
    TestState state = {0};
    (void)snprintf(state.name, sizeof(state.name), "Finch mDNS smoke %ld", (long)getpid());

    DNSServiceRef registration = NULL;
    DNSServiceRef browser = NULL;
    DNSServiceErrorType error = DNSServiceRegister(&registration, kDNSServiceFlagsNoAutoRename,
        kDNSServiceInterfaceIndexLocalOnly, state.name, "_finch-smoke._tcp", "local.",
        NULL, htons(9), 0, NULL, register_reply, &state);
    if (error == kDNSServiceErr_NoError)
    {
        error = DNSServiceBrowse(&browser, 0, kDNSServiceInterfaceIndexLocalOnly,
            "_finch-smoke._tcp", "local.", browse_reply, &state);
    }
    if (error == kDNSServiceErr_NoError)
    {
        const int result = wait_for_service(registration, browser, &state);
        if (result == 1)
            printf("local-only service registration and browse succeeded\n");
        else if (state.error == kDNSServiceErr_NoError)
            fprintf(stderr, "local-only service was not found within five seconds\n");
        else
            error = state.error;
    }

    if (browser)
        DNSServiceRefDeallocate(browser);
    if (registration)
        DNSServiceRefDeallocate(registration);

    if (error != kDNSServiceErr_NoError)
    {
        fprintf(stderr, "DNS-SD smoke test failed: %d\n", error);
        return 1;
    }
    return state.registered && state.found ? 0 : 1;
}
