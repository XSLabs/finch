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
licence. A refreshed bundle ships as a system update (finch-update); there is
no automatic certificate download or revocation fetch.

**Revocation (2026-10-26).** A trust with a revocation policy
(`SecPolicyCreateRevocation`) checks each certificate of the built chain but
its anchor (`userland/Security/SecRevocation.c`): by OCSP, first any response
stapled with `SecTrustSetOCSPResponse`, then the responder its Authority
Information Access names, and by its CRL distribution points, in the order the
flags ask. OCSP responses must be signed by the issuer or a responder it
certified and be current; CRLs must be the issuer's, signed by it and current.
A revoked certificate fails the trust (`errSecCertificateRevoked`,
`kSecTrustResultFatalTrustFailure`); with no answer it passes unless
`kSecRevocationRequirePositiveResponse` (`errSecIncompleteCertRevocationCheck`).
Fetching is plain HTTP, through a small bounded client (Finch's OpenSSL has no
sockets), and only where `SecTrustSetNetworkFetchAllowed` and the flags allow;
as on macOS a trust may fetch by default only when it checks revocation.
`tools/test-revocation.sh` serves OCSP and a CRL for a test-only authority on
the host and passes 14 checks: good and revoked certificates by OCSP and by CRL,
positive answers required, the network refused by the trust or the policy, and
a stapled response used offline but not for another certificate.

**Trust settings (2026-10-26).** `SecTrustSettings` keeps the user's
(`~/Library/Security/Trust Settings/User.plist`, the user's own, mode 0600) and
the administrator's (`/Library/Security/Trust Settings/Admin.plist`, root's to
change; others get `errAuthorizationDenied`) in macOS's record format, with
each certificate kept in its entry; the system's are the pinned roots,
read-only. Trust evaluation uses them unless the caller chose only its own
anchors: a root trusted (for every policy, one policy, or one host name)
becomes an anchor and the result is `kSecTrustResultProceed`, a distrusted
certificate fails any chain it's in (`kSecTrustResultDeny`), and a user's
setting overrides the administrator's. Only a self-signed certificate can be a
trusted root; a corrupt file is reported and grants nothing. Finch's `security`
command has macOS's `add-trusted-cert`, `remove-trusted-cert`,
`dump-trust-settings` and `verify-cert`. `security-trust-settings-test`
(host and QEMU, 28 checks) and `tools/vm/test-trust-settings.sh` (root adding
and removing a company root on the persistent VM) pass. Sandboxed apps and
services may read both files.

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
Locking handles aliases of the same file in both paths. A keychain from before
Finch encrypted them (its item database as a bare property list) opens locked
and unchanged; the first unlock seals it under a key from that password, in
place and under the write lock, so a login keychain moves to the login
password at the next login (2026-10-26, host and QEMU checks). A password
dialog remains open. At login,
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

Authorization Services go through Finch's `authd` (see "Shared authorization"
below); there is no password dialog yet. Code checks read signatures and validate file hashes,
resources and CMS signatures. Requirement parsing and trust serialization also
exist. These checks do not establish an Apple signing identity or enforce an
app sandbox. Hardware keys and the assessment service remain unavailable.

## The sandbox (2026-10-25)

Finch has its own sandbox, end to end, in place of macOS's closed one:

- **The profile language.** `userland/libsandbox/sbpl.c` compiles SBPL, the
  Scheme dialect macOS's profiles are written in (`define`, `lambda`, `let*`,
  `letrec`, quasiquote, TinyScheme `macro`, imports, parameters), to Finch's
  FSB1 format (`kernel/sandbox/fsb_format.h`). Rule semantics follow macOS's,
  checked on the host: within one operation the last matching rule decides; an
  operation's own rules come before its group's (`file-read-data`, then
  `file-read*`, then `file*`, then `default`); with no match the answer is
  deny. Paths are compared resolved; `subpath` respects path components,
  `prefix` does not; regexes (POSIX extended, compiled for a Pike-VM matcher
  with no backtracking) search the whole path. `(version 2)` and later profiles
  also filter Unix system calls by number. The operation names are macOS 26.4's
  (`tools/sandbox/ops.txt`, from the KDK's Sandbox.kext table) plus the older
  names its compiler still takes; constants such as `SYS_open` or `AF_UNIX`
  come from the SDK and XNU (`tools/sandbox/gen-consts.py`).
- **The kernel policy.** `kernel/sandbox/finch_sandbox.c` (FinchSandbox, built
  into XNU from Finch's tree) takes a compiled profile once per process,
  validates it (every offset, index and regex program; filters can't loop), and
  keeps it on the credential through fork and exec. It decides at the MAC hooks
  for file open, read of directories, create, unlink, rename, link, stat,
  attribute, mode, owner, time, flag and extended-attribute changes, ioctl,
  chroot, exec and executable mappings; fork, signals and process information;
  sysctls; POSIX shared memory and semaphores; socket creation, connect, bind
  and listen; IOKit user clients and services; privileges, reboot, setting the
  time and JIT memory; and (version 2) Unix system calls, through XNU's
  per-process system-call bitmap. Denials are EPERM and logged as macOS logs
  them (`Sandbox: cat(135) deny(1) file-read-data /private/tmp/...`), at most 32
  a second. The first proof's fixed deny-read and deny-write restrictions
  (calls 1, 2 and 0x100) still work beside it.
- **Userland.** `libsandbox.1`'s `sandbox_compile_string`, `_file` and
  `_named` (with Finch-written built-in profiles for `no-internet`,
  `no-network`, `no-write`, `no-write-except-temporary` and
  `pure-computation`) and `sandbox_apply`; `libsystem_sandbox`'s
  `sandbox_init` family drives them as macOS's does. `sandbox_check` and its
  relatives ask FinchSandbox (call 0x103), and fall back to Apple's policy
  only where FinchSandbox isn't registered, which keeps the host comparison
  tests meaningful. finch-init's bootstrap server refuses a lookup the caller's
  profile denies (`mach-lookup`, BOOTSTRAP_NOT_PRIVILEGED).
- **Profiles.** Finch ships its own `system.sb` (`userland/sandbox-profiles`),
  which notifyd's open-source profile imports. notifyd now starts under its
  profile with no borrowed component: the VM image no longer needs the base
  image's `libsandbox.1.dylib`.

**Checks.**

- Host: the regex engine agrees with POSIX `regexec` on all 1,364
  pattern/subject pairs (`make -C userland/libsandbox test`). Across the 569
  profiles on the build Mac, Finch's compiler accepts and refuses the same
  ones as macOS's, except two font profiles where macOS refuses a construct it
  accepts elsewhere. Of 62,082 decisions (each profile applied by macOS's
  sandbox in a child, and asked of Finch's evaluator: file reads, stats,
  writes, creates, sysctls, Mach lookups, shared memory), none has Finch allow
  what macOS denies beyond three paths macOS names differently from `realpath`
  and its platform rule for raw disks; 242 have Finch deny what macOS allows,
  all from approximated filters (`make -C userland/libsandbox compare`).
- Guest: `sandbox-profile-test` (34 checks: literal, regex and subpath file
  rules, create, unlink and rename, inheritance through fork and exec,
  `sandbox_check`, sysctls, signals to other processes, shared memory, a
  bootstrap lookup refused with 1100, deny-default, version-2 system-call
  filtering and version 1 leaving it off, a second `sandbox_init` refused), and
  the notifyd, request and enforcement tests, pass on the new kernel with
  Finch's compiler (2026-10-25).

**Not enforced yet, and how each is compiled.** A filter Finch can't evaluate
is compiled so it never widens access: it matches in a deny rule and fails in
an allow rule (`sbplc -w` lists each). That covers sandbox extensions
(`extension`, issued and consumed through the kernel on macOS; Finch's are
now FinchSandbox's own, see the App Sandbox below), app containers in a profile (the App Sandbox passes its
container as a parameter instead), `require-entitlement` at run time,
mount-relative paths, `syscall-group-*` sets, private ioctl/fsctl and MIG
constants, `iokit-connection` and IOKit message filters. Mach-trap and kernel
MIG filtering (`syscall-mach`, `syscall-mig`) is unenforced: XNU takes one
set of callbacks for them, which the borrowed Sandbox.kext registers. Network
filters on remote and local addresses are compiled as unknown for now; the
kernel already passes `host:port` for IP sockets. Operations with no hook
here (notably `file-read-xattr` listing on some paths, `nvram*`, `system-fsctl`,
Mach task operations, Apple events, preferences, which the services
themselves must ask about) are decided only where a service asks
`sandbox_check`. Apple's Sandbox.kext is still linked into the kernel
collection; nothing Finch runs applies a profile to it.

### The App Sandbox (2026-10-26)

A process whose signature has `com.apple.security.app-sandbox` is sandboxed
before `main`, as on macOS. libSystem's initializer calls Finch's
`libsystem_secinit` (`userland/libsystem/secinit`), which:

- reads the process's entitlements (libxpc, from its code signature) and its
  code-signing identifier, and leaves alone a process already sandboxed (a
  sandboxed app's child keeps its parent's sandbox; one with
  `com.apple.security.inherit` and no parent sandbox stops);
- makes its container, `~/Library/Containers/IDENTIFIER/Data`, laid out as
  macOS's: its own `Documents`, `Library` (Application Support, Caches,
  Preferences, Saved Application State, ...), `SystemData` and `tmp`, and
  links to the user's Desktop, Downloads, Movies, Music and Pictures and
  Library folders such as Fonts and Keychains, which stay closed unless
  entitled;
- points `HOME`, `CFFIXED_USER_HOME` and `TMPDIR` into it;
- compiles Finch's `application.sb` (`userland/sandbox-profiles`, written for
  Finch) with the home, container and bundle as parameters and the
  entitlements as `ENTITLEMENT:` parameters, which libsandbox hands the
  compiler as entitlements, and applies it. If that fails the process stops: a
  sandboxed app never runs unsandboxed.

`application.sb` denies by default and imports `system.sb`. It allows looking
up any path but reading only system files, the app's bundle, its container,
the user's fonts, input methods, global preferences and the like, and Finch's
services (the window server's socket, pasteboard, Launch Services, keychain
and authorization). Entitlements add network clients and servers, Downloads,
Pictures, Music and Movies (read-only or read-write), and temporary exceptions
by absolute or home-relative path and by service name (absolute paths are
resolved first, since the kernel matches resolved paths). With
`files.user-selected.*`, files the user chose come as sandbox extensions.

`tools/vm/test-app-sandbox.sh` (persistent VM, a user it makes) passes: an app
with only the sandbox entitlement gets its container as `HOME` and `TMPDIR`,
with Documents and the Desktop link, writes and reads it, and is refused the
user's Documents, Downloads and home listing, `/tmp`, other files and network
connections, while system files stay readable and `/bin/cat` run from it is
sandboxed too (18 checks); an app with network.client,
downloads.read-write and a read-only exception may connect, use Downloads and
read, but not write, the excepted file (19 checks); without a sandbox the same
user reads all those files and connects. `system.sb` now also allows
`sysctl.name2oid` (behind `sysctlbyname`) and ioctls on `/dev/null`, `/dev/zero`
and `/dev/dtracehelper`. Each sandboxed child still logs one
`dynamic-code-generation` denial at start (a `MAP_JIT` probe in a borrowed
library), which is harmless.

**Sandbox extensions (2026-10-26).** FinchSandbox issues, consumes and
releases extensions itself (calls 0x104 to 0x106; `sandbox_extension_issue_*`,
`_consume` and `_release` use them, falling back to Apple's only where
FinchSandbox isn't registered). A token is the extension's type, flags,
optional target process, class and resolved path or service name, with an
HMAC-SHA256 under a key made at boot: only this boot's kernel can make one, a
changed one is refused, and one issued to a process is that process's alone. A
sandboxed issuer can pass on only what its own profile allows. Consuming gives
the process a new label that shares its profile and adds the extension;
children inherit it, and releasing takes it away again. `(extension "class")`
is now compiled and evaluated: it matches when the caller holds an extension of
that class covering the path (the path or anything below it) or the service.

The same test then hands the networked app tokens, as an open panel would, for
the user's secret file (read) and another Documents file (read-write), and
passes 16 more checks: each opens just its file for what its class allows, a
tool the app runs inherits it, releasing closes it again, a changed token, a
token issued to another process and issuing for a file the app can't read are
refused (35 checks in that app in all).

**Open and save panels (2026-10-26).** A sandboxed app's NSOpenPanel and
NSSavePanel run in `finch-openandsavepanel` (userland/openandsavepanel), a
per-user agent (Mach service `org.finch.openandsavepanel`), as macOS's run in
AppKit's panel service. The app sends the panel's settings; the agent,
unsandboxed as the user, shows Finch's panel (starting in the folder asked
for, unless that's in the app's container, else ~/Documents) and issues an
extension for each chosen file to the asking process only: read-write with
`files.user-selected.read-write`, read-only with `.read-only`, nothing (and no
panel) without either. AppKit consumes them before handing the URLs over;
`runModal`, `beginWithCompletionHandler:` and sheets all go this way.
`application.sb` now also lets apps make local sockets (the window server's)
and `system.sb` reach syslog's socket.

`tools/vm/test-openpanel.sh` (persistent VM) runs a sandboxed app as a user in
that user's domain on a headless window server and answers its panels from
the keyboard: the app shows its own window, can't read the user's file, gets
the Open panel from the agent, reads the file chosen and only it, gets the
Save panel, writes the file named, and the user finds it in Documents (18
checks).

Open: app groups, and containers for app extensions and XPC services.

### Notification service work still required

Notifyd now runs as root under its own profile, compiled by Finch. Running it
confined as macOS does needs more:

- Start the service as a dedicated non-root user. Check shared memory,
  bootstrap check-in, logging, and client access under that identity.
- Keep signal delivery working for other users. The older signal path calls
  `kill` from notifyd, which a dedicated account cannot use on arbitrary client
  processes. The newer dispatch path sends the signal from the client itself;
  passing that path alone does not prove the older path still works.
  Starting dispatch threads for every older client would also change when it
  can safely fork. Keep that behavior, or provide a separate, narrowly limited
  way for the service to deliver a signal the receiving client requested.
  `proc_signal_with_audittoken` checks that the receiving process has not been
  replaced, but still checks the sender's user permissions. It does not give
  the dedicated account permission to signal another user's process. Any
  separate delivery service must accept a right created by the receiving
  client for one fixed signal, rather than an arbitrary process and signal
  chosen by notifyd. That delivery path has not been implemented or tested.
- Give it only the fixed log files it needs. Identify allowed files by kernel
  object labels set through trusted setup. A pathname prefix alone is unsafe
  because links and renames can change what a name refers to. Cover creation,
  open, writes, truncate, links, renames, removal, and metadata changes.
- Restrict POSIX shared memory to the notification center's exact name and
  check access after opening it. Restrict executable mappings, process and
  privilege changes, device access, and system setting reads and writes.
- Close socket paths that skip a fresh access check after connection, including
  ordinary file-descriptor reads and writes and bulk send/receive calls. Keep
  the borrowed policy's existing call contract intact when adding Finch checks.
- Have the bootstrap server enforce the service's allowed lookups and
  registrations using the sender identity supplied by the kernel. Existing
  Mach send rights allow messages that do not pass through that server; this
  remaining boundary needs its own design and tests.

The file-watch code now refuses checks when it cannot switch to the client's
identity. It restores the original groups and cache setting, and stops the
service if it cannot restore its identity after a check. Missing paths remain
watchable for later creation; other failed checks revoke access. The timezone
exception now checks a full folder name, so a sibling with the same prefix does
not qualify. `userland/tests/pathwatch-credential-fault-test.py` exercises the
patched functions with failed setup and cleanup calls, saved error values, and
timezone folder boundaries. These checks pass on 2026-10-18. The guest's
`notify-path-access-test` also observes creation of a new file in an allowed
folder while receiving no events from a changed root-only file. Neither check
proves that the full file-watch service works under a dedicated non-root account.

The old file-watch parser also rejects paths that exceed its fixed buffer limit
before allocating a watch. Its scratch buffer now uses heap storage when the
requested size will not fit on the stack. The boundary tests run the patched
source with memory-error checks enabled; they cover the limit, oversized input,
and the scratch-buffer choice. These tests pass on 2026-10-18.

Shared-memory startup now checks ownership, permissions and size before touching
an existing object. It checks mapping and allocation failures before clearing
old data, and exits explicitly when setup fails. New-object cleanup failures
are logged. An owned, empty object left by an interrupted first start can be
initialized on retry; a nonempty object with the wrong size is left untouched
and requires cleanup. The page count option rejects malformed or overflowing
values. The source-based fault test passes 243 checks. In the development guest,
`notify-restart-test` stops the verified service and confirms that its replacement
keeps the original check and callback registrations and their stored state.
It also checks that a waiting notification survives the restart, can be consumed
once, and leaves an unrelated quiet registration unchanged (2026-10-18).

The old file-watch code notifies unrelated listeners with the same name when a
watched file changes. A client-owned replacement is now under test. Its first
guest run exposed a crash caused by adding one common-port client to the same
tracking list twice. After fixing that, CoreFoundation notifications, cross-user
access, path access and restart checks pass with no logged service exits.
Cancellation now waits for source cleanup before returning to an ordinary
caller, rejects canceled tokens, and keeps them out of restart recovery.
The corrected lifecycle test, direct-delivery test, and queued-callback
cancellation test all pass alongside the four checks above, with no logged
service exits (2026-10-18). This covers seven guest tests, not every file-watch
case. A new `notify-path-permission-test` found a real failure: a watch created
without directory access stayed silent after access returned, including later
file writes. A one-second retry now reopens blocked paths under the caller's
credentials. Its timer stays idle while access is allowed and joins the same
cleanup group as file watches. The new test confirms recovery after initial
denial and later loss of access, quiet hidden writes, and cancellation while
access is blocked. Cancel closes the parent folder before returning and leaves
no late callbacks or reopened folder. All eight checks passed together with no
logged service exits on October 18. The before/after records are saved under
`build/continuation-20261018/permission-baseline*` and `permission-retry-*`.
Cancellation from a file-watch queue avoids waiting on that queue and may
defer cleanup; the API does not promise safe use inside a signal handler.
The replacement is not ready to support moving the service to a non-root account.
These runs still use the base image's sandbox library and do not prove
release-image confinement.

The cross-user notification test is separate from these sandbox requirements.
It checks notifyd's own `user.uid.*` access rules and an allowed post as a
positive control. It passes in the development guest on 2026-10-18, alongside
the sandbox request, sandbox enforcement and CoreFoundation notification tests.
The child starts a fresh executable before changing user, since libnotify
disables inherited state after fork. This does not establish service confinement
or replace the required release-image checks.

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

## Shared authorization (2026-10-26)

`authd` (`userland/authd`, Mach service `com.apple.authd`, started on demand by
finch-init) is Finch's own authorization service. Security.framework's
Authorization calls send it XPC requests; every message carries a Finch
protocol marker, so on a macOS host (whose own `authd` has the same name)
Security falls back to evaluating rules in the process.

- The rules database is `/private/var/db/auth.plist`, seeded from Security's
  `authorization.plist` on first use. Rights match exactly or by the longest
  wildcard prefix; rules follow macOS's classes (`allow`, `deny`, `user`,
  `rule` with `k-of-n`, `evaluate-mechanisms`) and keys (`group`, `shared`,
  `timeout`, `allow-root`, `authenticate-user`, `session-owner`).
- Passwords given in the environment are checked through PAM's
  `authorization` service. A credential lasts for the authorization's life;
  a `shared` rule's credential is also kept for the caller's audit session,
  for the rule's timeout (0: not reused).
- Authorizations are 32-byte random tokens, so an external form passes one to
  another process. Only its own session may free it.
- `AuthorizationRightSet` and `AuthorizationRightRemove` need
  `config.add.`/`config.modify.`/`config.remove.` for the right;
  `AuthorizationExecuteWithPrivileges` runs a tool as root for an
  authorization that holds `system.privilege.admin`, its output on a pipe.
- The service is signed `org.finch.authd`: AMFI refuses the identifier
  `com.apple.authd` without Apple's version-restriction entitlement.

`tools/vm/test-authorization.sh` (persistent VM, fresh data disk) makes an
administrator and an ordinary account and, as the ordinary account, passes 31
checks: no password, a wrong password and a non-administrator's password are
refused; an administrator's password grants `system.privilege.admin`, the
context names them, and a privileged tool runs as UID 0; an authorization
without the right can't run one; allow and deny rules; a shared credential
reaches a second authorization in the session while a non-shared right still
asks; an external form opens in another process and a made-up one is refused;
and adding, changing and removing a right, with changes refused without an
administrator. `is-root` grants only root (an earlier build granted any caller
a rule with `authenticate-user` false and no group).

**The password dialog (2026-10-26).** When a right needs a password, none came
in the environment and the caller allows interaction, authd asks
`finch-securityagent` (userland/securityagent; macOS's SecurityAgent), a
per-user agent in the domain of the caller's login user (`org.finch.securityagent`,
reached with `bootstrap_look_up_per_user`). It shows the dialog ("PROGRAM wants
to make changes. Enter an administrator’s name and password to allow this.")
and returns the name and password to authd only, which takes the answer only
from `/usr/libexec/finch-securityagent` running as that user and checks it with
PAM; a wrong one asks again, up to three times, and cancelling is
`errAuthorizationCanceled`. `tools/vm/test-authorization-dialog.sh` (persistent
VM, headless window server) passes: an ordinary user's tool asks for
system.privilege.admin, a wrong administrator password brings the dialog back,
the right one grants the right, and a second request cancelled with Escape is
refused (9 checks).

Plug-in mechanisms remain open: `evaluate-mechanisms` rules accept root or a
password.

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
goes through Finch's `authd`; Finch has no system password dialog yet. The plugin view can collect local input and report a missing
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

Normal `finch-init` boots require `/etc/finch/rc` to exist and finish successfully
before services and login start. A missing or failed startup script skips both.
Init opens the recovery root shell only when
the exact development boot argument `finch_dev_console=1` was already set;
duplicate or malformed values do not enable it. Without that opt-in, init stays
stopped without an interactive login and reports that repair needs a development
boot. A missing or failed login program still does not open a root shell. Set
`FINCH_DEV_CONSOLE=0` when testing normal login with `tools/vm/run.sh`.

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
system accounts are in the install payload.

### First-user setup (2026-10-26)

On a normal boot `finch-init` starts `/usr/libexec/finch-setup` on the console
instead of `login`. When the system already has a person's account (UID 501 or
above with a login shell) it becomes `login` at once. Otherwise it asks for a full
name, an account name (suggested from the full name), a password of at least 12
characters typed twice, and a computer name. It makes the account with the next
free UID from 501, group staff, `/bin/zsh` and a home folder with macOS's standard
folders, adds it to `admin`, sets ComputerName and LocalHostName through `scutil`,
then hands the console to `login`.

`tools/vm/test-first-user.sh` boots the persistent VM with a data disk laid out as
a new system's (no test account) and passes: a short password is refused, the
account logs in, is an administrator in staff, has a private home with its
folders, has its full name and the computer's names, and after logout the console
returns to `login`, not setup.

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
tool does not grant admin rights or install an OS. Correct-password,
wrong-password and locked-account checks
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

Home creation is now an explicit option: `accountctl -d ACCOUNT_FOLDER -R
TARGET_ROOT create NAME UID GID GECOS HOME SHELL`. The account folder and target
root are separate, required choices. Without `-R`, account creation still only
changes account files. With it, the tool creates `HOME` under the chosen root,
with the new user's owner and group and mode 0700. Parent folders must already
exist and be protected from other users. The tool refuses links, `..`, and an
existing home with the wrong owner or permissions. An existing home must also
be empty, so a reused user number cannot hand an old user's files to a new
account. The check reads the already-open folder; focused host and VM tests confirm
that rejected homes keep their contents and no account is added (2026-10-18).
An empty home left by an interrupted attempt can still be reused.
If saving the account fails,
it removes only the empty home it just created, after checking that it is still
the same folder and that the account was not saved. Host fixture tests pass
(2026-10-17). The rebuilt VM also passes account creation, empty-home reuse,
non-empty-home refusal, PAM and OpenDirectory checks (2026-10-18). These checks
do not finish first-user setup or reboot persistence.

### Changing account details (2026-10-26)

`chpass`, `chsh` and `chfn` (Apple's system_cmds, built unchanged) edit an
account through OpenDirectory. Finch's OpenDirectory now reads a user record's
details and collects changes with `ODRecordSetValue`; `ODRecordSynchronize`
writes them with `libfinchaccount`'s `at_store_update_user`, which keeps uids
unique, groups real and system accounts (below 500) untouched, and rewrites the
public `passwd` from `master.passwd`. GECOS carries the full name, office,
office phone and home phone, comma-separated as in BSD's passwd(5).

Root's changes are written in the process. Anyone else's go through
`/usr/libexec/finch-account-update`, installed setuid root, which does the
local node's checks that macOS's opendirectoryd does, using the caller's real
uid and the credentials chpass was given (sent on its input, never in its
arguments):

- an administrator's password (group admin): any field chpass shows;
- the account's own password, by its own user: the GECOS fields, and the shell
  when both the old and the new one are in `/etc/shells`;
- anything else, including a wrong password (after a second's delay), is
  refused.

Non-root password checks (`ODRecordVerifyPassword`, `ODRecordSetNodeCredentials`)
use the helper's `--verify` mode, since only root reads password hashes. The VM
image now has `/etc/shells`, as the release does.

`tools/vm/test-chpass.sh` (persistent VM, fresh data disk) passes 16 checks: a
user changes their own shell and finger information; a shell outside
`/etc/shells` and a wrong password change nothing; another user's account, a
user's own uid or home, a wrong or another user's password and no credentials
are refused by the helper; an administrator's password changes another account;
root changes a uid and home without a password, and `/etc/passwd` shows the new
uid without the hash.

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

## 2026-10-16: Security and SystemConfiguration C API work

Security now exports 1,555 of the 1,804 public C entries in the 26.4 SDK audit.
The CMS encoder and decoder handle signed and enveloped messages through Finch's
OpenSSL library; `security-test` checks a signed-message round trip against Apple.
New covered paths include symmetric-key import and derivation, certificate data
and names, legacy policy and access objects, trust options and exceptions,
asynchronous trust evaluation, basic `SecTransform` actions, and the public TLS
protocol-options object. Network's TLS client now applies its supported options
to Finch's Secure Transport path: version limits, server name, ALPN, cipher list,
session tickets, fallback and renegotiation flags, peer checks, client identity,
and verify and challenge callbacks. It reports negotiated version, cipher, ALPN,
server name, and peer certificates. The loopback comparison checks certificate
rejection and acceptance, a version mismatch, ALPN, metadata, and an echo. The
Security host comparison passes in 369 lines.

The TLS handshake uses Finch's Secure Transport and OpenSSL, not Apple's private
TLS implementation. This work does not add a timestamp service or the old CSSM
service. A missing CMS timestamp returns Apple's item-not-found error.
Custom transform registration and setup are tested, but action execution is not
in the Apple comparison: the Apple test process crashes when that legacy callback
path runs. The transform comparison covers digest and Base64 actions. The audit
still reports 249 missing entries, including most CSSM calls, import/export
helpers, old keychain handles, hardware services, remaining protocol-metadata
calls, unsupported advanced TLS options, and shared-credential services.

SystemConfiguration now exports all 467 public C entries found by the same SDK
audit, including its bond/VLAN configuration and legacy connection interfaces.
The 203-line `sysconfig-test` comparison passes against Apple. This count covers
exports; it does not make Finch's configuration daemon provide Wi-Fi, DHCP,
hardware link changes, or every network service.
