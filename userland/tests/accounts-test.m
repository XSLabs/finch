/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-accounts-test: the account store as a Mac with no Internet accounts answers,
 * run against Apple's Accounts and Finch's to compare (tools/host-tests.sh): account
 * types by identifier, access, saving and removing, accounts and credentials as values.
 */
#import <Accounts/Accounts.h>

static void
wait_for(dispatch_semaphore_t s)
{
    dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
}

int
main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        [[NSUserDefaults standardUserDefaults] setVolatileDomain:@{@"AppleLanguages" : @[ @"en" ]} forName:NSArgumentDomain];
        printf("%s\n", [[NSBundle bundleForClass:[ACAccountStore class]] executablePath].UTF8String);
        ACAccountStore *s = [ACAccountStore new];
        printf("accounts %lu, by id %s\n", (unsigned long)s.accounts.count, [[s accountWithIdentifier:@"x"] description].UTF8String);
        for (NSString *t in @[ ACAccountTypeIdentifierTwitter, ACAccountTypeIdentifierFacebook, ACAccountTypeIdentifierLinkedIn,
                               @"com.apple.account.IMAP", @"com.apple.account.AppleAccount", @"com.apple.account.Exchange",
                               @"com.apple.account.Google", @"com.apple.account.CalDAV", @"com.apple.account.iTunesStore", @"bogus" ]) {
            ACAccountType *ty = [s accountTypeWithAccountTypeIdentifier:t];
            printf("type %s: %s, name '%s', granted %d, accounts %lu\n", t.UTF8String, [ty description].UTF8String,
                   ty.accountTypeDescription.UTF8String, ty.accessGranted, (unsigned long)[s accountsWithAccountType:ty].count);
        }
        ACAccountType *tw = [s accountTypeWithAccountTypeIdentifier:ACAccountTypeIdentifierTwitter];
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [s requestAccessToAccountsWithType:tw options:nil completion:^(BOOL granted, NSError *e) {
          printf("access %d: %s %ld %s; main thread %d\n", granted, e.domain.UTF8String, (long)e.code, e.localizedDescription.UTF8String,
                 [NSThread isMainThread]);
          dispatch_semaphore_signal(sem);
        }];
        wait_for(sem);
        ACAccount *a = [[ACAccount alloc] initWithAccountType:tw];
        a.username = @"u";
        a.accountDescription = @"d";
        printf("account: id length %lu, type %s, username %s, description %s, credential %s\n", (unsigned long)a.identifier.length,
               a.accountType.identifier.UTF8String, a.username.UTF8String, a.accountDescription.UTF8String,
               [a.credential description].UTF8String);
        [s saveAccount:a withCompletionHandler:^(BOOL ok, NSError *e) {
          printf("save %d: %ld %s\n", ok, (long)e.code, e.localizedDescription.UTF8String);
          dispatch_semaphore_signal(sem);
        }];
        wait_for(sem);
        [s removeAccount:a withCompletionHandler:^(BOOL ok, NSError *e) {
          printf("remove %d: %ld %s\n", ok, (long)e.code, e.localizedDescription.UTF8String);
          dispatch_semaphore_signal(sem);
        }];
        wait_for(sem);
        ACAccountCredential *c = [[ACAccountCredential alloc] initWithOAuth2Token:@"t" refreshToken:@"r" expiryDate:[NSDate distantFuture]];
        ACAccountCredential *c1 = [[ACAccountCredential alloc] initWithOAuthToken:@"t1" tokenSecret:@"s"];
        c1.oauthToken = @"t2";
        printf("credentials: %s %s\n", c.oauthToken.UTF8String, c1.oauthToken.UTF8String);
        printf("notification %s, domain %s\n", ACAccountStoreDidChangeNotification.UTF8String, ACErrorDomain.UTF8String);
    }
    return 0;
}
