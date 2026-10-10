/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Accounts.framework: the user's Internet accounts. Finch has none yet (no account
 * setup, no sign-in to Apple's services), so the store answers as a Mac with no
 * accounts: every account type Apple's knows is there, with its name, and holds no
 * accounts; asking for access is refused because there are none; saving and removing
 * aren't permitted. Accounts and credentials can still be made and read, as values.
 */
#import <Accounts/Accounts.h>

#define FINCH_INIT __attribute__((objc_method_family(init)))

/* The account types: identifier and name (Apple's names, taken as data). */
static const char *const types[][2] = {
    {"com.apple.account.126", "126"},
    {"com.apple.account.163", "163"},
    {"com.apple.account.aol", "Aol"},
    {"com.apple.account.AppleAccount", "iCloud"},
    {"com.apple.account.AppleID", "AppleID"},
    {"com.apple.account.AppleIDAuthentication", "Apple ID"},
    {"com.apple.account.BookmarkDAV", "BookmarkDAV"},
    {"com.apple.account.CalDAV", "CalDAV"},
    {"com.apple.account.CalDAVLegacy", "CalDAV Legacy"},
    {"com.apple.account.CardDAV", "CardDAV"},
    {"com.apple.account.CardDAVLegacy", "CardDAV Legacy"},
    {"com.apple.account.CloudKit", "CloudKit"},
    {"com.apple.account.DCA", "Detached Child Account"},
    {"com.apple.account.DeviceLocator", "Device Locator"},
    {"com.apple.account.Exchange", "Exchange"},
    {"com.apple.account.facebookLegacy", "Facebook Legacy"},
    {"com.apple.account.FaceTime", "FaceTime"},
    {"com.apple.account.FindMyFriends", "Find My Friends"},
    {"com.apple.account.GameCenter", "Game Center"},
    {"com.apple.account.Google", "Gmail"},
    {"com.apple.account.HolidayCalendar", "Holiday Calendar"},
    {"com.apple.account.Hotmail", "Hotmail"},
    {"com.apple.account.IdentityServices", "Messages"},
    {"com.apple.account.idms", "IDMS"},
    {"com.apple.account.IMAP", "IMAP"},
    {"com.apple.account.IMAPMail", "IMAPMail"},
    {"com.apple.account.IMAPNotes", "IMAPNotes"},
    {"com.apple.account.iTunesStore.sandbox", "iTunes Store (Sandbox)"},
    {"com.apple.account.iTunesStore", "iTunes Store"},
    {"com.apple.account.jabber", "Jabber"},
    {"com.apple.account.LDAP", "LDAP"},
    {"com.apple.account.linkedInLegacy", "LinkedIn Legacy"},
    {"com.apple.account.Madrid", "Messages"},
    {"com.apple.account.mso", "MSO"},
    {"com.apple.account.OnMyDevice", "On My Device"},
    {"com.apple.account.osxserver", "macOS Server"},
    {"com.apple.account.POP", "POP"},
    {"com.apple.account.PublishedCalendar", "Published Calendar"},
    {"com.apple.account.qq", "QQ"},
    {"com.apple.account.RemoteManagement", "Remote Management"},
    {"com.apple.account.SingleSignOn", "Single Sign-on"},
    {"com.apple.account.SMTP", "SMTP"},
    {"com.apple.account.SubscribedCalendar", "SubscribedCalendar"},
    {"com.apple.account.tencentweibo", "Tencent Weibo"},
    {"com.apple.account.Yahoo", "Yahoo"},
    {"com.apple.account.yahooim", "Yahoo IM"},
    {"com.apple.account.yelp", "Yelp"},
    {"com.apple.facebook", "Facebook"},
    {"com.apple.flickr", "Flickr"},
    {"com.apple.linkedin", "LinkedIn"},
    {"com.apple.sinaweibo", "Sina Weibo"},
    {"com.apple.tudou", "Tudou"},
    {"com.apple.twitter", "Twitter"},
    {"com.apple.vimeo", "Vimeo"},
    {"com.apple.youku", "Youku"},
};

static NSError *
denied(NSString *message)
{
    return [NSError errorWithDomain:ACErrorDomain code:ACErrorPermissionDenied userInfo:@{NSLocalizedDescriptionKey : message}];
}

@interface ACAccountType ()
- (instancetype)_finchInitWithIdentifier:(NSString *)identifier name:(NSString *)name FINCH_INIT;
@end

@implementation ACAccountType {
    NSString *_identifier, *_name;
}
- (instancetype)_finchInitWithIdentifier:(NSString *)identifier name:(NSString *)name
{
    if ((self = [super init])) {
        _identifier = [identifier copy];
        _name = [name copy];
    }
    return self;
}
- (NSString *)identifier { return _identifier; }
- (NSString *)accountTypeDescription { return _name; }
- (BOOL)accessGranted { return NO; }
- (BOOL)isEqual:(id)o { return o == self || ([o isKindOfClass:[ACAccountType class]] && [_identifier isEqual:[o identifier]]); }
- (NSUInteger)hash { return _identifier.hash; }
- (NSString *)description { return [NSString stringWithFormat:@"%@ (%@)", _name, _identifier]; }
@end

@implementation ACAccountCredential {
    NSString *_oauthToken, *_tokenSecret, *_refreshToken, *_password, *_type;
    NSDate *_expiryDate;
}
- (instancetype)initWithOAuthToken:(NSString *)token tokenSecret:(NSString *)secret
{
    if ((self = [super init])) {
        _oauthToken = [token copy];
        _tokenSecret = [secret copy];
        _type = @"oauth";
    }
    return self;
}
- (instancetype)initWithOAuth2Token:(NSString *)token refreshToken:(NSString *)refreshToken expiryDate:(NSDate *)expiryDate
{
    if ((self = [super init])) {
        _oauthToken = [token copy];
        _refreshToken = [refreshToken copy];
        _expiryDate = [expiryDate copy];
        _type = @"oauth2";
    }
    return self;
}
/* (private, as Apple's) a password credential */
- (instancetype)initWithPassword:(NSString *)password
{
    if ((self = [super init])) {
        _password = [password copy];
        _type = @"password";
    }
    return self;
}
- (NSString *)oauthToken { return _oauthToken; }
- (void)setOauthToken:(NSString *)t { _oauthToken = [t copy]; }
- (NSString *)credentialType { return _type; }
- (NSString *)password { return _password; }
- (void)setPassword:(NSString *)p { _password = [p copy]; }
- (NSString *)oauthRefreshToken { return _refreshToken; }
- (NSString *)oauthTokenSecret { return _tokenSecret; }
- (NSDate *)expiryDate { return _expiryDate; }
- (NSString *)description { return [NSString stringWithFormat:@"<ACAccountCredential:'%@'>", _type ?: @""]; }
@end

@implementation ACAccount {
    NSString *_identifier;
    ACAccountType *_accountType;
    NSString *_accountDescription, *_username;
    ACAccountCredential *_credential;
    NSMutableDictionary *_properties;
}
- (instancetype)initWithAccountType:(ACAccountType *)type
{
    if ((self = [super init])) {
        _identifier = [NSUUID UUID].UUIDString;
        _accountType = type;
        _properties = [NSMutableDictionary dictionary];
    }
    return self;
}
- (instancetype)init { return [self initWithAccountType:(ACAccountType *_Nonnull)(void *)0]; }
- (NSString *)identifier { return _identifier; }
- (ACAccountType *)accountType { return _accountType; }
- (void)setAccountType:(ACAccountType *)t { _accountType = t; }
- (NSString *)accountDescription { return _accountDescription; }
- (void)setAccountDescription:(NSString *)d { _accountDescription = [d copy]; }
- (NSString *)username { return _username; }
- (void)setUsername:(NSString *)u { _username = [u copy]; }
- (NSString *)userFullName { return nil; }
- (ACAccountCredential *)credential { return _credential; }
- (void)setCredential:(ACAccountCredential *)c { _credential = c; }
/* (private, as Apple's: the account's other settings, the mail server's and such) */
- (id)accountPropertyForKey:(NSString *)key { return _properties[key]; }
- (void)setAccountProperty:(id)value forKey:(NSString *)key
{
    if (value)
        _properties[key] = value;
    else
        [_properties removeObjectForKey:key];
}
- (NSDictionary *)accountProperties { return [_properties copy]; }
- (BOOL)isEnabledForDataclass:(NSString *)dataclass { return NO; }
- (NSSet *)enabledDataclasses { return [NSSet set]; }
- (NSSet *)provisionedDataclasses { return [NSSet set]; }
- (BOOL)isActive { return NO; }
- (BOOL)isAuthenticated { return NO; }
- (ACAccount *)parentAccount { return nil; }
- (NSArray *)childAccounts { return @[]; }
- (NSString *)description { return [NSString stringWithFormat:@"%@ (%@)", _accountType.accountTypeDescription ?: @"", _identifier]; }
@end

@implementation ACAccountStore

+ (id)defaultStore { return [[self alloc] init]; }

- (NSArray *)accounts { return @[]; }
- (ACAccount *)accountWithIdentifier:(NSString *)identifier { return nil; }

- (ACAccountType *)accountTypeWithAccountTypeIdentifier:(NSString *)typeIdentifier
{
    for (size_t i = 0; i < sizeof types / sizeof types[0]; i++)
        if ([typeIdentifier isEqualToString:@(types[i][0])])
            return [[ACAccountType alloc] _finchInitWithIdentifier:typeIdentifier name:@(types[i][1])];
    return nil;
}

- (NSArray *)accountsWithAccountType:(ACAccountType *)accountType { return @[]; }
- (NSArray *)allAccountTypes
{
    NSMutableArray *a = [NSMutableArray array];
    for (size_t i = 0; i < sizeof types / sizeof types[0]; i++)
        [a addObject:[[ACAccountType alloc] _finchInitWithIdentifier:@(types[i][0]) name:@(types[i][1])]];
    return a;
}
- (NSArray *)accountsWithAccountTypeIdentifiers:(NSArray *)identifiers error:(NSError **)error { return @[]; }
- (ACAccount *)aa_primaryAppleAccount { return nil; }

static void
later(void (^block)(void))
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), block);
}

- (void)requestAccessToAccountsWithType:(ACAccountType *)accountType options:(NSDictionary *)options
                             completion:(ACAccountStoreRequestAccessCompletionHandler)completion
{
    if (!completion)
        return;
    NSString *message = [NSString stringWithFormat:@"No accounts found for account type %@", accountType.identifier ?: @""];
    later(^{
      completion(NO, denied(message));
    });
}

- (void)requestAccessToAccountsWithType:(ACAccountType *)accountType withCompletionHandler:(ACAccountStoreRequestAccessCompletionHandler)handler
{
    [self requestAccessToAccountsWithType:accountType options:nil completion:handler];
}

- (void)saveAccount:(ACAccount *)account withCompletionHandler:(ACAccountStoreSaveCompletionHandler)completionHandler
{
    if (!completionHandler)
        return;
    NSString *message = [NSString stringWithFormat:@"The application is not permitted to access %@ accounts",
                                                   account.accountType.accountTypeDescription ?: @""];
    later(^{
      completionHandler(NO, denied(message));
    });
}

- (void)removeAccount:(ACAccount *)account withCompletionHandler:(ACAccountStoreRemoveCompletionHandler)completionHandler
{
    if (!completionHandler)
        return;
    NSString *message = [NSString stringWithFormat:@"The application is not permitted to delete %@ accounts",
                                                   account.accountType.accountTypeDescription ?: @""];
    later(^{
      completionHandler(NO, denied(message));
    });
}

- (void)renewCredentialsForAccount:(ACAccount *)account completion:(ACAccountStoreCredentialRenewalHandler)completionHandler
{
    if (!completionHandler)
        return;
    later(^{
      completionHandler(ACAccountCredentialRenewResultFailed,
                        [NSError errorWithDomain:ACErrorDomain code:ACErrorAccountNotFound userInfo:nil]);
    });
}

@end

/* (private, as Apple's) a store that tells its delegate as accounts of some types come and
   go: with none, it never does. */
@interface ACMonitoredAccountStore : ACAccountStore
@end

@implementation ACMonitoredAccountStore
- (instancetype)initWithAccountTypes:(NSArray *)types delegate:(id)delegate { return [super init]; }
- (instancetype)initWithAccountTypes:(NSArray *)types propertiesToPrefetch:(NSArray *)properties delegate:(id)delegate
{
    return [super init];
}
- (NSArray *)registerWithCompletion:(void (^)(NSArray *))completion
{
    if (completion)
        completion(@[]);
    return @[];
}
- (NSArray *)monitoredAccounts { return @[]; }
@end
