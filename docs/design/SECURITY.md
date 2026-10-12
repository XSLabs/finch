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
the user's own regular file, mode 0600, with one link and a sane size. It is **not
encrypted** yet: the authenticated-encryption format (`SecKeychainCrypto.c`,
PBKDF2-SHA256 and AES-GCM) is written and tested on its own but not used by the file
keychain. Lock and unlock calls currently do not protect stored items. Authorization
rules run inside the calling process; there is no shared authorization service
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

## Console access

Normal `finch-init` boots now start `/usr/bin/login`. A missing or failed login
program does not open a root shell. The development VM opts in to its root
console with the exact boot argument `finch_dev_console=1`; duplicate or malformed
values do not enable it. Set `FINCH_DEV_CONSOLE=0` when testing normal login with
`tools/vm/run.sh`.

The parser checks and both QEMU boot paths passed on 2026-10-11. The login check
proved that an unknown account returns to the login prompt. It did not prove a
successful account login. The development image's file ownership still prevents
its PAM stack from being used as a release test. Locked system accounts are in
the install payload; a first-user setup flow and a full console login remain
unfinished.

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
