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
running program. On 2026-10-11 it checked 513 binaries with no missing required
links. The optional `libobjc-env.dylib` was absent.
The latest archive check covered 8,879 paths, including the shared account
library, account tool, and FAT filesystem helpers. The VM-only test programs
and their account templates are not included in this install payload.

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
archive: someone replacing the archive could replace its list too. Signed
releases, update verification, safe disk installation, first-user setup,
rollback and hardware boot remain unfinished. See [the roadmap](../ROADMAP.md).
