# Security and SystemConfiguration

Finch builds both frameworks for arm64e using Apple's public SDK headers and
framework paths. Their build scripts accept `FINCH_OUTPUT_ROOT` and
`FINCH_OBJ_DIR` for separate test builds. Neither copies Apple's closed code.

## Security

`userland/Security` provides Finch's implementation. Its constants generator
reads the pinned `Security-61901.101.4` source and finds definitions for all 564
constants it emits. Key and certificate operations use OpenSSL from Finch's
existing corecrypto build. Build corecrypto first. Security hides OpenSSL's
symbols and links CoreFoundation and libSystem.

Supported operations include random bytes, DER certificates, certificate
names and serials, RSA and prime-curve EC keys, key import and export, signing
and signature checks, RSA encryption and decryption, and ECDH. Trust checks
validate the chain, date, hostname and purpose. Unknown algorithms and policies
fail. Server TLS checks use the pinned Mozilla root bundle installed at
`/etc/ssl/cert.pem`, unless the caller selects only its own roots. Client TLS,
mail and code-signing policies do not inherit these web roots. An absent bundle
never makes an unknown certificate trusted. Foundation and CFNetwork use the
same bundle for HTTPS.

The bundle comes from curl's dated Mozilla export (2026-09-25), checked by
SHA-256 during the build. The image includes its source record and MPL 2.0
licence. Updating the pin and shipping refreshed roots remain release work;
there is no automatic certificate download or revocation fetch.

The file keychain stores items across calls and processes, with file locks and
duplicate checks. Its path is walked without following links (except the system's
/tmp and /var aliases); every folder on the way must belong to the user or root and
not be writable by others (a sticky temporary folder excepted), and the file must be
the user's own regular file, mode 0600, with one link and a sane size. New files
require a password and encrypt the complete item list with PBKDF2-SHA256 and
AES-256-GCM (`SecKeychainCrypto.c`). Each save writes a private temporary file and
replaces the old file after syncing it. A stable lock file keeps concurrent saves
from overwriting each other's changes.

In a Finch guest, a per-user `securityd` owns the unlocked keys and handles keychain
requests. It checks the caller's user ID from the kernel before reading the request.
Two apps in the same user session share an unlock, and locking from either app
blocks reads from both. The QEMU service check also covers item references,
wrong passwords and malformed requests (2026-10-13). Host-only checks retain a
local file backend: a fresh process starts locked and a fork clears inherited keys.
Locking handles aliases of the same file in both paths. Older plaintext files are
refused and left unchanged; migration and a password dialog remain open. At login,
`pam_keychain` (in `/etc/pam.d/login`'s session) makes the user's login keychain with the
login password, or unlocks it with that password, and leaves a keychain with another
password locked. tools/vm/test-login.sh checks this through Finch's real console login
in QEMU, over three logins, with `finch-security-keychain-login-test` run as the user
(2026-10-15). A user's own `passwd` changes the login keychain's password too
(`pam_keychain` in `/etc/pam.d/passwd`, through `SecKeychainChangePassword`), and the next
login unlocks it with the new one; a reset by root, with no old password, leaves the
keychain on its old password, as on macOS. Focused host and QEMU checks pass for password rejection,
locked reads and writes, changed-file rejection, alias locking, concurrent saves,
file permissions and unsafe paths (2026-10-13). Filename-case checks pass on both
systems. These checks use dummy secrets in private temporary folders.

Authorization rules run inside the calling process; there is no shared authorization service
or password dialog. Code checks read signatures and validate file hashes,
resources and CMS signatures. Requirement parsing and trust serialization also
exist. These checks do not establish an Apple signing identity or enforce an
app sandbox. Hardware keys and the assessment service remain unavailable.

`finch-security-core-test` covers keys, signatures and caller-root trust.
`finch-security-roots-test` checks a real public HTTPS chain at a fixed date,
wrong hostnames, explicit roots, root-store selection and an absent store. It
also checks that web roots do not grant trust to client TLS or basic-only
policies. The tests run against Finch's shared frameworks; the root-store test also passes
in QEMU (2026-10-11). Passing these tests
does not establish secure key storage or a complete authorization system.

On 2026-10-15, the Security comparison test also checks macOS-style trust
property arrays and sealed bundle resource checks. `SecCodeValidateFileResource`
checks the supplied bytes against the signed resource hash and requires the
resource to be a plain file in the bundle. XPC-message code lookup remains out
because Finch has no trustworthy way to read the sender's audit token from an
XPC message. Apple-format trust exceptions and the old CSSM, search, and
transform APIs remain unsupported; hardware keys and Apple assessment services
also remain unavailable.

## SecurityInterface and AuthenticationServices

Finch's `SecurityInterface.framework` draws certificate, trust, identity,
keychain and authorization UI with Finch's AppKit. Certificate panels read
real `SecCertificate` and `SecTrust` objects, let the user move through a
certificate chain, and show the certificate summary, expiry date and trust
result. Accepting the trust panel writes the selected certificate's user trust
setting through `SecTrustSettingsSetTrustSettings`; an error closes the panel
as cancelled. The identity panel selects a real `SecIdentity` from the supplied
list. It stores a requested domain on the panel, but cannot save a preferred
identity for that domain because Finch Security does not provide Apple's
`SecIdentitySetPreferred` call.

The keychain save panel creates an encrypted file keychain through
`SecKeychainCreate` and takes its password in a secure text field. The settings
panel reads and writes the lock settings through Finch Security. Those settings
are currently kept only in the calling process and do not lock keychains
automatically. `SFAuthorizationView` checks and obtains its configured rights
through `SFAuthorization` and sends state changes to its delegate. Authorization
still runs inside the app; Finch has no shared authorization service or system
password dialog. The plugin view can collect local input and report a missing
system UI service, but cannot act as Apple's authorization plug-in host.

Finch's `AuthenticationServices.framework` provides the request and credential
objects apps use for web sign-in, Apple ID, passwords and passkeys. The
authorization controller completes requests with Apple's public
`ASAuthorizationErrorNotHandled` error because Finch has no Apple account or
passkey broker. Password credential objects hold the values supplied by the
app; they do not retrieve a saved password. The web session can hand a request
to an app-registered browser handler, checks its callback URL or scheme, and
reports cancellation or a missing handler through the completion block. Finch
does not launch Apple's browser service, sign into Apple ID, or create and use
passkeys. The browser-facing passkey manager reports that passkeys are not
configured and returns no stored credentials.

The framework versions and their app-facing request values are checked against
Apple's SDK with `auth-frameworks-test`. `tools/api-audit.sh` also reports public
classes Finch has not implemented, including account-provider and credential
store UI. Passing the comparison test means the exercised request values match;
it does not mean those missing system services are available.

## Console access

Normal `finch-init` boots now start `/usr/bin/login`. A missing or failed login
program does not open a root shell. The development VM opts in to its root
console with the exact boot argument `finch_dev_console=1`; duplicate or malformed
values do not enable it. Set `FINCH_DEV_CONSOLE=0` when testing normal login with
`tools/vm/run.sh`.

The parser checks and both QEMU boot paths passed on 2026-10-11. The login check
proved that an unknown account returns to the login prompt. On 2026-10-13,
`tools/vm/account-console-smoke.exp` also passed a real password login. It copies
the account files and PAM modules onto temporary guest filesystems, sets and
checks their release ownership and modes, and starts `/usr/bin/login` under
the development setup shell. A wrong password is refused. The right password
opens UID 6000, GID 20 in its own writable home, starts its per-user service
domain, and runs its shell profile. Logout exits login successfully and returns
to the setup shell. No host account or disk image account is changed.

The image builder now rejects stale PAM policies before replacing the VM image.
The test also checks the guest's exact Finch login rules before setup. Locked
system accounts are in the install payload. First-user setup and normal boot
returning to a fresh login prompt after logout remain unfinished.

`accountctl` can now create a local account or change its password in an
explicitly named account folder. It has no default destination and prompts for
passwords on a terminal. The shared `libfinchaccount` also supplies password
checks to PAM and OpenDirectory. New hashes use PBKDF2-HMAC-SHA256 with 600,000
rounds and a random 16-byte salt. Old DES hashes can be checked, but new ones
are never created. Locked system accounts stay locked.

Host and QEMU tests using Finch's CommonCrypto cover account creation, password changes,
refused writes, public password redaction, file permissions, shared legacy-hash
checks. A separate host fixture also proves recovery after a failed account-file
write. They use the exact
release account templates. These checks use private temporary folders. The
tool does not create home folders, grant admin rights, install an OS, or prove
a full console login. Correct-password, wrong-password and locked-account checks
now pass through the real PAM and OpenDirectory code in QEMU (2026-10-11).
The helper copies the release account files and PAM modules into a private,
root-owned folder, creates a test account with the shared account library, then
checks passwords from inside that folder. It keeps the normal PAM file-permission
checks and removes the folder afterward. `tools/vm/test-accounts.sh` repeats these
checks in a disposable guest.
The separate `login-init-smoke.exp` check now boots with the development root
console disabled. It rejects a wrong password, verifies the logged-in user's
identity and home, and proves that logout starts a fresh login prompt
(QEMU, 2026-10-13). Its account exists only in guest memory; first-user setup
and accounts that survive reboot remain open.
The ordinary user password-change path still needs a
privileged service; `accountctl` itself does not run with extra permissions.

## SystemConfiguration

`userland/SystemConfiguration` combines Finch's `SCState.c` with `SCDKeys.c`
and schema constants generated from the pinned `configd-1405.100.8` source.
Its build collects the source notices under
`/usr/share/finch/licenses/SystemConfiguration`. It links CoreFoundation and
libSystem. Shared changes also use Finch's libxpc and settings service.

It reads preference files, local preference values, network sets and services,
hostnames, configured proxies, and the kernel's interfaces and addresses.
Dynamic-store reads can match keys and patterns. Synchronous reachability uses
DNS and a UDP route check; the route check connects a socket without sending a
packet.

Finch now builds its own `configd` service. Shared store writes, subscriptions,
change callbacks and cleanup of temporary keys pass in QEMU (2026-10-11).
Each request uses the sender identity supplied by the kernel. Ordinary users
can change their own user keys, but cannot change global keys or read another
user's private keys; the VM test checks those limits with a separate process.

An existing store watch resumes after the service restarts in QEMU. Preference
locking, file commits, fresh-client readback after service restart, cleanup and refused non-root writes
also pass (2026-10-11). For those file checks, a VM-only helper enters a private
test root before starting the real service. It supplies root-owned preference
folders without weakening the production checks. The service refuses arbitrary
file paths. The development image's read-only root still lacks normal writable
preference storage; persistence across a reboot remains unproved.
After building the VM image, `tools/vm/test-settings.sh` repeats these checks,
checks saved-file ownership and permissions, and verifies errors while the
service is stopped. It changes only the disposable guest.
Manual IPv4 and DNS apply pass in QEMU (2026-10-11). The test adds a private
loopback address, reads it back from the kernel, applies the same settings again,
checks the resolver file in the private test root, and removes its changes. The guest's outer resolver file and
hostname stay unchanged. Host tests cover malformed settings and DNS priority.
The service checks the whole request before making changes and refuses DHCP,
routers, active IPv6 and multiple IPv4 addresses. A later system error can still
leave part of a valid request applied. The service now tries to remove only
addresses it added if a later step fails. It checks each address again before
removing it and leaves changed addresses alone. Existing matching addresses are
kept; changing the mask of an existing address is refused. Host tests with fake
network calls cover cleanup after DNS, hostname and later-address failures, plus
failed cleanup and concurrent changes. This is not full rollback: DNS can remain
changed, and another privileged process can race the address checks.
DHCP, Wi-Fi management,
reachability subscriptions and two-address reachability remain unfinished.
Interface classification and store keys are also partial. Missing services
return errors instead of treating a local cache as a successful shared write.

`finch-sysconfig-core-test` passes against the shared Finch frameworks on the
host. It checks local preferences, refused writes, hostname, real interfaces
and addresses, pattern queries and the loopback route. The host route check
needs access outside the network sandbox. All 64 names in the captured
bundled-app import list are exported. These results were checked on 2026-10-09.

Host API work (2026-10-15) adds editable services, protocols, sets, interface
settings, computer names and local hostnames through `SCPreferences`. MTU reads
use the kernel; setting or clearing an MTU changes only the saved preference.
Media subtype helpers filter and de-duplicate caller-supplied lists. Apple's
host comparison passes for all 193 lines in `sysconfig-test`; the API audit now
finds 426 of 467 public C functions. The remaining 41 include bond and VLAN
controls, link-media controls, PPP layering, daemon-backed connections, and
legacy refresh calls that need hardware or services Finch does not provide.
