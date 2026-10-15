# Userland inventory (macOS 26.4.1 / 25E253 ramdisk)

This is what the VM's userland is made of today, and where each piece comes from.
"Published" is checked against Apple's
[macOS 26.4 source release](https://github.com/apple-oss-distributions/distribution-macOS/blob/macos-264/release.json).
The image has a **dyld shared cache built by Finch** (`docs/design/DYLD_CACHE.md`) from
its own dylibs, Apple's and Finch's. Pieces are still replaced one at a time: rebuilding
the image rebuilds the cache.

| Status | Meaning |
|---|---|
| OPEN | Apple publishes current source; build it |
| LLVM | Comes from upstream LLVM |
| STALE | Apple's source exists but hasn't been published in years; use an alternative |
| CLOSED | No source; Finch must provide an implementation |
| ? | Not yet verified |

## PID 1

| Binary | Source | Status | Finch |
|---|---|---|---|
| `/sbin/launchd` | launchd (Swift since macOS 26; last published as launchd-842, 2014) | CLOSED | **Replaced by `finch-init`** (`userland/finch-init`) |

## Daemons (run by finch-init; job plists in `userland/LaunchDaemons`)

| Daemon | Apple project | Status |
|---|---|---|
| `notifyd` (com.apple.notifyd) | Libnotify-348.100.7 | **Built by Finch**, started on demand. Without LaunchEvents, its event publisher has no subscribers. |
| `syslogd` (com.apple.syslogd) | syslog-406 | **Built by Finch**, kept alive. As on macOS, syslog(3) and asl(3) go to os_log (finch-logd), so its ASL store stays mostly empty. |
| `aslmanager` (com.apple.aslmanager) | syslog-406 | **Built by Finch**, started on demand by syslogd's trigger (`VPROC_GSK_IS_MANAGED` tells it it's a job) |
| `newsyslog` (com.apple.newsyslog) | syslog-406 | **Built by Finch**, every hour at :30; Apple's `/etc/newsyslog.conf` |
| `dynamic_pager` (com.apple.dynamic_pager) | system_cmds-1042.100.6.0.1 | **Built by Finch**, runs once at boot |
| `logd` (com.apple.logd) | closed | **Replaced by `finch-logd`** (`userland/logd`, on libdispatch's open firehose server; `docs/design/LOGD.md`), with Finch's `log(1)` |
| CoreFoundation.framework | swift-corelibs-foundation (Apache 2.0) | **Built by Finch** (`userland/CoreFoundation`; `docs/design/COREFOUNDATION.md`) |
| libicucore | ICU-76142.4.7 | **Built by Finch** |
| libz, libbz2, libedit, libresolv | zlib-100, bzip2-47, libedit-65, libresolv-96 | **Built by Finch**, Apple's exports exactly (patches in `userland/patches/{zlib,libedit}`) |
| libxml2 | libxml2-39.10 (MIT) | **Built by Finch** (`userland/oss/libxml2.build.sh`), Apple's version and exports exactly; Foundation's NSXMLParser uses it |
| liblzma, libxo, libsbuf | XZ Utils 5.4.3, libxo 1.6.0, FreeBSD 14.5 sbuf (upstream; Apple doesn't publish its copies for 26.4) | **Built by Finch** (`userland/{xz,libxo,libsbuf}`), Apple's versions, install names and exports exactly |
| IOKit.framework | IOKitUser-100231.100.18.0.1 | **Built by Finch** (`userland/IOKit`): IOKitLib, pwr_mgt, ps, platform; 500 of Apple's 2,372 exports, every one Finch's binaries import. HID, graphics, display, USB and kext parts come as something needs them. |
| libswiftCore | swift (Apache 2.0) | **Built by Finch** (`userland/swift`) |
| `cron` | cron-52 | **Built by Finch**, with closed analytics and background-task hooks removed. Launch job and temporary VM spool installed. Root and non-root reboot jobs pass in QEMU (2026-10-11). |
| `mdnsd` (com.apple.mDNSResponder) | mDNSResponder-2881.100.56.0.1 | **Built by Finch** from the portable `mDNSPosix` daemon. Launch job installed; local-only registration and discovery pass in QEMU (2026-10-11). |
| `configd` | Finch service over libxpc | **Built by Finch**. Shared store access, user permissions, cross-process callbacks, temporary-key cleanup and watches across service restart pass in QEMU (2026-10-11). Preference file commits and readback pass in a private VM test root. Reboot persistence and network apply remain unverified. |
| `diskarbitrationd` | DiskArbitration-535.100.31 | **Built by Finch** against Finch frameworks, without private FSKit/CoreStorage helpers. A client opens and closes a session in QEMU (2026-10-11). Real disk mounting remains unverified. |

## libSystem (`/usr/lib/libSystem.B.dylib` + `/usr/lib/system/*`)

| Dylib | Apple project | Status |
|---|---|---|
| libSystem.B | Libsystem-1356 | OPEN |
| libsystem_kernel | xnu-12377.101.15 (libsyscall) | **Built by Finch** (plus Finch `work_interval_instance_*`; Apple ships unpublished additions) |
| libsystem_platform | libplatform-375.100.10 | **Built by Finch** (Apple ships no Xcode project; Finch adds 9 unpublished exports) |
| libsystem_pthread | libpthread-539.100.4 | **Built by Finch** (+2 unpublished exports; Finch JIT/SPRR header) |
| libsystem_malloc | libmalloc-812.100.31 | **Built by Finch** (no longer links libcorecrypto) |
| libsystem_c | Libc-1752.100.10 | **Built by Finch** (no longer links libcorecrypto) |
| libsystem_darwin | Libc-1752.100.10 (libdarwin) | **Built by Finch** (APFS dir-stats fast path compiled out; it was already unused) |
| libsystem_info | Libinfo-600 | **Built by Finch** (without the closed Darwin Directory module, which is feature-flagged off on macOS) |
| libsystem_notify | Libnotify-348.100.7 | **Built by Finch** |
| libsystem_blocks | libclosure-96 | **Built by Finch** |
| libdispatch | libdispatch-1542.100.32 | **Built by Finch** (build config reconstructed) |
| libdyld | dyld-1376.6 | **Built by Finch** |
| libcopyfile | copyfile-240 | **Built by Finch** |
| libremovefile | removefile-85.100.6 | **Built by Finch** |
| libkeymgr | keymgr-31 | **Built by Finch** |
| libcommonCrypto | CommonCrypto-600035 | **Built by Finch** (unmodified source, on Finch libcorecrypto) |
| libsystem_configuration | configd-1405.100.8 | **Built by Finch** |
| libsystem_dnssd | mDNSResponder-2881.100.56.0.1 | **Built by Finch** |
| libsystem_asl | syslog-406 | **Built by Finch** |
| libcompiler_rt | compiler-rt | **Built by Finch** (LLVM 22.1.8) |
| libunwind | libunwind | **Built by Finch** (LLVM 22.1.8) |
| libmacho | cctools-1035.1.102 | **Built by Finch** |
| libsystem_m | Libm (stale) | **Finch's**: CORE-MATH + FreeBSD msun (`userland/libm`) |
| libcorecrypto | corecrypto (source-viewable, non-OSS license) | CLOSED: **Finch's** on OpenSSL 3.5.9 (`userland/corecrypto`, 1,092/1,092) |
| libsystem_trace | os_log / os_activity | CLOSED: **Finch's** (`userland/libsystem/trace`, 197/197) |
| libxpc, liblaunch | XPC / launchd | CLOSED: **replaced by Finch libxpc** (`userland/libxpc`, ABI-compatible; bootstrap served by finch-init) |
| libquarantine | Quarantine | CLOSED: **Finch's** (`userland/libsystem`) |
| libsystem_sandbox, libsystem_secinit | Sandbox | CLOSED: **Finch's** (`userland/libsystem`) |
| libsystem_containermanager | Containers | CLOSED: **Finch's** |
| libsystem_coreservices | CoreServices | CLOSED: **Finch's** |
| libsystem_featureflags | Feature flags | CLOSED: **Finch's** |
| libsystem_networkextension | NetworkExtension | CLOSED: **Finch's** |
| libsystem_symptoms | Symptoms | CLOSED: **Finch's** |
| libsystem_trial | Trial | CLOSED: **Finch's** |
| libsystem_eligibility | Eligibility | CLOSED: **Finch's** |
| libsystem_darwindirectory | Darwin directory services | CLOSED: **Finch's** |
| libsystem_collections | Libc-1752.100.10 | **Built by Finch** |
| libsystem_sanitizers | | CLOSED: **Finch's** |
| libcache | | CLOSED: **Finch's** |
| libunc | | ? |

## Other

| Item | Source | Status |
|---|---|---|
| `/usr/lib/dyld` | dyld-1376.6 | **Built by Finch** |
| `/bin/launchctl` | launchd (closed) | **Replaced by Finch's** (`userland/launchctl`, talks to finch-init) |
| `bash`, `zsh` + modules | bash-144, zsh-118 | **Built by Finch** (zsh is the console shell) |
| `bc`, `dc` | bc-35 | **Built by Finch** |
| `at`, `atq`, `atrun` | system_cmds-1042.100.6.0.1 | **Built by Finch**; the runner no longer needs the closed background-task service. Root and non-root one-time jobs pass in QEMU (2026-10-11); see the development-image ownership limits in `docs/design/SERVICES.md`. |
| `sh` | dash project (closed launcher) | **Finch's** (`userland/sh`): the variant launcher |
| `mount_tmpfs` | tmpfs.fs (closed) | **Finch's** (`userland/mount_tmpfs`) |
| `mount`, `fsck` | diskdev_cmds-757 | **Built by Finch**. Basic filesystem helper dispatch; closed APFS/FSKit paths are left out. |
| `msdos.util`, `mount_msdos`, `newfs_msdos`, `fsck_msdos` | msdosfs-788.100.31 | **Built by Finch**, with the native `msdos.fs` bundle. Real formatting and mounting remain unverified: the current QEMU machine has no secondary block-device bus. |
| libsysmon | sysmon (closed; sysmond client) | **Finch's** (`userland/libsysmon`, 36/36): process tables from libproc, no sysmond; `pgrep`/`pkill` run on it |
| libmd, libutil, libbsm, libncurses | libmd-7 (51/51; its SHA-2 headers in Finch's SDK), libutil-73, OpenBSM-21 (+ `userland/oss/OpenBSM/finch_compat.c`), ncurses-79 | **Built by Finch** |
| `libiconv.2`, `libcharset.1`, `/usr/lib/i18n/*` (25 modules), `/usr/share/i18n` (700 tables) | libiconv-115.100.1 | **Built by Finch** (exports match Apple's: 95/95, 2/2) |
| file_cmds, shell_cmds, text_cmds, adv_cmds, system_cmds | Apple OSS (`userland/projects.txt`) | **Built by Finch** (`tools/build-system.sh`; `ps` too, via `userland/patches/adv_cmds`) |
| Other `mount_*`, `fsck_*`, `newfs_*` (from the restore ramdisk) | hfs and other filesystem projects; APFS tools are closed | Mixed; these are not supplied by the FAT helpers above |

## Deferred commands (don't build yet)

`userland/oss/<project>.deferred` lists these per project; `tools/build-system.sh` allows
exactly them to fail.

| Tool | Project | Blocker |
|---|---|---|
| chpass | system_cmds | Private OpenDirectory record-editing APIs; Finch provides lookup, verification and password changes only |
| bintrans tests (not the command) | text_cmds | Apple-internal `darwintest.h`; `bintrans` itself is built and staged |
| zprint, zlog | system_cmds | CoreSymbolication (closed) |

su and login build and use Finch's PAM: libpam from Apple's OpenPAM, the pam_modules
that don't need closed frameworks (rootok, uwtmp, self, env, group, nologin, sacl),
Finch's copy of OpenPAM's pam_unix in place of pam_opendirectory, and Finch's `/etc/pam.d` stacks
(`userland/pam`). passwd builds with an empty stand-in for `OpenDirectoryPriv.h`: run by root
it changes a password through Finch's OpenDirectory; run by a user, through PAM
(`/etc/pam.d/passwd`), setuid root as installed, and pam_keychain re-keys the user's login
keychain. (Apple's warning that it doesn't update the keychain is printed regardless.) login weak-links libEndpointSecuritySystem, which the image doesn't have.
PAM and OpenDirectory share `libfinchaccount` for Finch PBKDF2 password hashes
and old DES hash checks. `accountctl` writes an explicitly named account folder;
it does not install users' home folders or grant admin rights. See
[the security notes](../docs/design/SECURITY.md) for the checks and remaining work.
gcore works on processes it may read (in the VM, `finch-debuggee`); it relies on
libdyld's introspection, which needed two dyld patches (`userland/patches/dyld`):
falling back from the absent Dyld.framework, and the AA01 compact-info archive that
Apple's published dyld leaves out.

## Static libraries Finch provides

| Library | Apple | Finch |
|---|---|---|
| libCrashReporterClient.a | Apple-internal | `userland/CrashReporterClient`: per-image `__crash_info` record (version 5), linked by Libc and notifyd |
