# Install payload

`tools/release/mkrootfs.py` packs Finch's built programs, libraries and system
files into an archive. It does not produce a bootable image, install on a disk,
or sign a release. It does not take files from the borrowed VM base image.

Build the userland first, then run:

```sh
python3 tools/release/mkrootfs.py --compat-version 26.4.1 --compat-build 25E253
python3 tools/release/verifyrootfs.py build/release/rootfs.tar.gz
python3 tools/release/check_libraries.py build/release/rootfs.tar.gz
python3 tools/release/test_rootfs.py
```

The version arguments describe the macOS version Finch targets. The payload
still calls itself a development build. Do not use these arguments to claim a
Finch 1.0 release.

The archive records numeric owners and file permissions without changing host
files. System files belong to root. Password data is private. Only the listed
login and job tools retain permission to run as root. Cron's job directories
belong to its service account. Temporary directories have the usual shared
access rules. The installed boot script preserves existing jobs and data.
System accounts start locked; an installer must create the first user.

The release templates reserve user and group number 11 for `_notifyd`, with a
locked password and no login shell. The configured VM base has no conflicting
name or number (checked read-only on 2026-10-18). Template and archive tests pass,
but the service still runs as root. The updater now loads the new service record
before restoring saved accounts, then merges it into the staged system. It
refuses conflicting names or numbers before swapping system folders. It also
keeps accepting old signed payloads that do not define this account.

On 2026-10-18, all 128 host updater checks pass with Finch's frameworks. They
include preserving user passwords privately, rebuilding the public account
file without hashes, repeat installs, name and number conflicts, rollback, and
recovery after a forced stop following the account merge. The account helper's
78 focused checks also pass. These checks cover an offline staged root, not an
installed system booting from persistent storage. Development-image account
setup still needs a verified ownership step: its normal mount hides the stored
owners, and the helper refuses to write through such a mount.
`tools/vm/finalize-system-accounts.sh` prepares a separate image copy with file
ownership enabled and replaces the original only after checking the account
files. Its cleanup passes 15 temporary-file checks, including failed restore
and uncertain detach cases. It has not yet been run against a real image and
requires administrator access to preserve root ownership.

The embedded file list records file hashes, owners, permissions, the repository
commit, whether local changes exist, and the requested source versions. The
archive uses a fixed timestamp and sorted paths. Given the same input files and
metadata it has identical bytes. This does not yet prove that rebuilding all
source code produces identical programs. Requested source versions also do not
prove that every source checkout or compiler matched them.

The checker rejects missing or changed files, unsafe owners and permissions,
duplicate paths, writes through links, broken links, and links that leave the
installed root. It also checks that the login settings name packaged PAM modules.
The package takes these settings directly from Finch's sources, so an earlier
Apple-source build cannot replace them with settings for closed services.
A second check reads library links from the archive itself and
requires each strong link to resolve to a packaged file. It reports absent weak
links separately. It does not check symbols or libraries opened later by a
running program. On 2026-10-18 it checked 601 binaries with no missing required
links. The optional `libobjc-env.dylib` and seven Swift overlays were absent.
The latest archive check covered 9,687 paths, including the shared account
library, account tool, and updater with service-account merging. Its updater
bytes match the staged binary. The three packaged account files have root
ownership and the expected private/public modes. The VM-only test programs,
their account templates, and upstream XCTest bundles are not included in this
install payload. The package tests also check that a staged XCTest bundle is
excluded while its neighboring system library remains included.

The archive also unpacked with Finch's `gzip` and `pax` in QEMU on 2026-10-11.
The password file had owner/group 0:0 and mode 600, and cron's job directory
had 1:1 and 755. A second run checked full mode values: login retained 4555,
and the shared temporary directory retained 1777. Finch's PAM settings were
also present. Running the extracted system with
`chroot` did not pass: the borrowed Apple kernel killed its shell with
`hardened runtime not allowed in chroot`. Thus unpacking and these owners are
checked, but running the installed root and preserving data across boots are
still unverified. No hardware disk was changed.

Hashes detect a mismatch with the embedded list. They do not prove who made an
archive: someone replacing the archive could replace its list too. A signature does:

## Signed updates

`tools/release/sign-update.sh ARCHIVE` signs a payload: ECDSA P-256 over the archive's
SHA-256, written beside it as `ARCHIVE.sig`. Its key pair stays in `build/release/keys`
(made on first use, never committed); a real release's key is its maker's to keep
(`FINCH_UPDATE_SIGNING_KEY`). The public key, the curve point, goes into the system as
`/usr/share/finch/update-key.der` when the system is built after a key exists.

`finch-update` (`userland/update`, Finch's own, over Finch's Security) checks and applies
one:

```sh
finch-update verify rootfs.tar.gz                  # rootfs.tar.gz.sig beside it
finch-update install rootfs.tar.gz --root /Volumes/Finch/System
finch-update rollback --root /Volumes/Finch/System
finch-update fetch https://example.org/rootfs.tar.gz /var/db/finch-update   # then verify
```

`install` refuses an archive the key didn't sign, unpacks into `DIR.finch-new` beside the
root, and copies the user's files and settings into it from the inactive target root:
`Users`, `Applications`, `Library/{Preferences,Keychains,
Application Support}`, `private/var/root`, `private/var/db/dslocal`, `private/var/at` and
the account files in `private/etc`. Those replace the payload's defaults; everything else,
`Library/LaunchDaemons` and timezone data among it, is the update's. Then it swaps the new
root in by renaming, keeping the previous root as `DIR.finch-old` for `rollback`.
Rollback copies the current user files into the previous system before switching back.
Copy failures leave the active folder and its user files in place.

One lock per target prevents two updaters from changing its folders at once. On the
next install or rollback, the updater checks for an interrupted switch and restores
or finishes it before proceeding. A process killed between renames can leave the root
path absent until that recovery runs. Unexpected files or links in the recovery slots
are refused. Some errors after the final rename mean the new folder is already in
place; the error message reports that state. This is not a boot recovery service.

`tools/release/test-update.sh` uses throwaway keys and folders on the host, against
Finch's Security. It checks signed and changed archives, the wrong key, failed unpacking,
preserved files and permissions, rollback, competing installs, and real process kills
during copying and folder switches. The full test passed on 2026-10-17. These process
kill tests do not prove safety after power loss or while apps change the source files.

`fetch` downloads `URL` and `URL.sig` into a folder with Finch's NSURLSession and verifies
them. A download cut short leaves resume data beside it (`NAME.resume`, from the error's
`NSURLSessionDownloadTaskResumeData`), and continues with a Range request: at once, up to
`FINCH_UPDATE_ATTEMPTS` times (5), then on the next fetch. Finch's download tasks stream
their bodies to a file, report a body cut short as `NSURLErrorNetworkConnectionLost` with
resume data when the response had a validator, and `cancelByProducingResumeData:` and
`downloadTaskWithResumeData:` work as Apple's (`finch-urlsession-test`, diffed against
Apple's Foundation). test-update.sh serves an update from `tools/release/test-server.py`,
which cuts off each archive's first download halfway, and checks the resume in a later run
and in the same one (2026-10-15). The partial file is in the temporary folder, so a
download resumed after a restart that cleared it starts again.

What remains: switching the booted system (a running system's root can't be renamed; that
is the installer's, with the boot path), first-user setup and hardware boot. See [the roadmap](../ROADMAP.md).
Sandbox profile compilation is also a startup blocker: notifyd requires it, and
Finch's current library cannot supply it. Passing the archive's file and link
checks does not establish that its services can start.

## Installed-system design required for 1.0

The folder-root updater is a development tool. Copying user files into each new
system is not enough for updates while people use the computer: a file can change
after its copy finishes. A successful folder swap also does not prove that the
next system can boot.

The installed system needs these separate parts:

| Part | Required behavior |
|---|---|
| System versions | Keep the working version while preparing and checking a new one. Apps must not be able to rewrite either version. |
| User data | Keep accounts, homes, settings, keychains, jobs and app data on writable storage outside the replaced system version. Switching versions must not copy or discard live user data. |
| Boot choice | Record a pending version only after its files and signature pass checks. Make it the working version only after boot and essential services pass their health checks. |
| Recovery | Keep a way to select the previous working version when startup fails or power is lost. Recovery must not depend on the failed version's services. |

This is a release requirement, not an implemented disk layout. The exact volume
and boot-choice format must follow the supported Apple Silicon boot path. The
installer must also refuse unrelated disks and preserve the existing recovery
system. Data-format changes need their own backwards-compatible migration or
recovery plan; switching old system files back cannot undo an incompatible data
change safely.

Before marking this complete, use a disposable disk to prove first-user setup,
account and settings persistence across two boots, an update and rollback with
user edits, refusal of a changed or wrongly signed update, and recovery after
interruption at each boot-choice and install step. Then repeat the supported
install and recovery flow on the dedicated Finch hardware target. Tier 1's
RAM-only disk and a folder-root test cannot substitute for those checks.

The normal QEMU Darwin boot still supplies only a RAM disk. On October 18,
a separate experiment added an opt-in PCI bridge and attached a VirtIO disk
under Finch XNU. An APFS marker survived a full QEMU process restart with its
contents, owner, and permissions intact. This proves the basic disk path;
accounts and homes still use RAM in the normal boot. See
[PERSISTENT_VM_STORAGE.md](PERSISTENT_VM_STORAGE.md) for the evidence and limits.
Homes use `/private/var/rw/Users`, while account records use `/private/etc`;
both must be backed by persistent storage, with all account writers using the
same authoritative files. Copying account records into RAM at boot is not enough.

The VZ harness can use a disposable APFS image with Apple's guest kernel. That
could test Finch account files and home permissions across reboots, but would
not prove Finch's kernel, disk drivers, mount tools or standalone login path.
The FAT check only formats and checks a filesystem; FAT cannot preserve the
per-file Unix ownership and permissions required for private homes.
