# Persistent VM storage

**Status: a development VM with persistent accounts and homes; installed-system storage is unfinished.** The normal `darwin` VM still boots from RAM. `tools/vm/mkpersistent.sh` builds a second development VM whose system image mounts a VirtIO data disk at boot, through the AppleVirtualPlatform PCIe bridge that `tools/build-kernel.sh` now links into the kernel collection (`boot/kc/extra-kexts.txt`) and the opt-in QEMU bridge. Accounts, passwords, home folders and `/private/var/db` live on that disk; `tools/vm/test-persistence.sh` checks them across shutdowns and restarts. The system image itself is still loaded as a RAM disk, and installation, updates that switch the booted system, and hardware remain open.

## What a release must do

Finch is ready for real use only when all four things work together:

1. The machine boots Finch-built XNU, not Apple's kernel.
2. User files and settings survive a full shutdown, restart, update, and recovery.
3. Updates understand the parts needed to boot Finch. They switch the kernel collection, trust cache, system image, and device tree as one working set. They keep a known-good boot and can return to it if an update fails. User data stays in place through that change.
4. Finch can be installed and recovered on supported Apple hardware. A QEMU test alone does not prove this.

The durable storage layout, the files that belong on it, and the update and recovery steps are still open work. There is no complete release path yet.

## What the current VM proves

`tools/vm/run.sh` starts QEMU's `darwin` machine with a kernel collection, device tree, trust cache, and ramdisk. It has no data-disk option. In `third_party/darwin-vm/qemu-sptm/hw/arm/darwin.c`, QEMU opens the ramdisk as read-only boot input and copies it into guest memory. A write to that guest copy disappears when QEMU exits.

The normal `darwin` machine setup creates the CPU, interrupt controller, UARTs, SEP, and other Apple registers. It creates no PCI host unless the new experimental `finch-pcie` option is enabled. The QEMU source does show a GPEX PCI host in `third_party/darwin-vm/qemu-sptm/hw/vmapple/vmapple.c`. That is the separate `vmapple` machine with a different firmware and boot path. It does not make PCI storage available to Finch's current `darwin` machine.

The M4 device tree in `third_party/darwin-vm/firmware/dtree` has Apple-specific PCI roots under `/device-tree/arm-io/apcie` and `/device-tree/arm-io/apciec0`, `apciec1`, and `apciec3`. They describe Apple's hardware roots, with Apple-specific register ranges, buses, and interrupts. They do not describe a generic QEMU PCI host or contain the `pcie,vmapple1` name needed by Apple's virtual PCIe bridge.

The installed KDK has a generic NVMe personality. It matches PCI class `0x01080200`, which is the class QEMU's standard NVMe device reports. The KDK also includes APFS and the storage framework. This makes NVMe and APFS worth testing once the guest can see a PCI bus. It does not prove that the current Finch guest can discover or use a disk.

PCI discovery is the missing link. The KDK's M4 PCI driver personalities are keyed to Apple-specific names such as `apcie,t8132` and `apciec,t8132`, and their code reads T8132 hardware registers. They are not generic GPEX host drivers. The current tree's root nodes have names like `apcie` and `apciec0`, device types `pci` and `pci-c`, and no `compatible` property. XNU's `IONameMatch` checks a device tree entry's `compatible`, `name`, and `device_type` fields (`kernel/xnu/iokit/IOKit/IOService.h`). So these personality names do not prove that the KDK drivers bind to the current tree as-is. The `IOPCIFamily` bundle's personalities match PCI-to-PCI bridge devices; that bundle alone does not claim a generic root host.

The KDK also has a possible virtual host bridge, `AppleVirtualPlatformPCIE`. Its personality matches `pcie,vmapple1` on an `AppleARMIODevice`, and its binary implements PCI configuration and bridge operations. It reads device-tree data for ECAM, `ranges`, interrupts, and MSI. But the Finch build selects the `mac16g` manifest, which does not request `AppleVirtualPlatform`, and the M4 tree has no matching node. A static check could not confirm the full built collection: `kmutil inspect` stopped with `Cannot create DASession`. On October 18, a separate `kmutil create` run successfully linked `AppleVirtualPlatform` with the current Finch-built XNU and the existing bundle set. The working kernel collection and kernel input kept their original SHA-256 hashes. The command, result, and separate output are under `build/continuation-20261018/avp-link-experiment/`. The separate collection also booted Finch and passed `notify-path-cancel-test` using the existing device tree; `boot-run.json` and `boot.log` record that check. The VM inputs stayed unchanged. This proves basic boot compatibility, not that the bridge starts: the tree still has no matching virtual PCI node. The test image also still borrows the base sandbox library.

These facts come from the current `tools/build-kernel.sh` target and the KDK for build `25E253`. The build uses the manifest's required bundle list. A KDK bundle on disk is not the same as a bundle present and working in Finch's guest.

## Storage paths under consideration

The virtual PCI bridge and VirtIO disk passed the marker test below. The normal system does not yet place accounts, settings, or user files on this disk.

### Try the Apple virtual PCIe bridge in a development build

This is the first path to test because the KDK already has a bridge that can publish PCI devices to IOKit.

1. Link `AppleVirtualPlatform` and its needed bundles into a separate Finch development kernel collection. **Passed** for the October 18 experiment described above.
2. Add a synthetic `pcie,vmapple1` device-tree node for one GPEX host. **Implemented as an experiment:** `tools/vm/dtree-virtual-pcie.py` creates a separate tree, and the QEMU `darwin` machine accepts `finch-pcie=on` (off by default). It uses ECAM at `0x40000000`, memory at `0x50000000`, and AIC interrupt lines `0x20` through `0x2f`. Existing M4 hardware roots stay intact. MSI is not modeled.
3. Boot Finch XNU with the empty bridge first. **Passed:** the guest matched one `AppleVirtualPlatformPCIE` service, with an `AppleARMIODevice` parent and the QEMU `pci1b36,8` host bridge as an `IOPCIDevice` child. The probe found no bridge before the change. The two logs and their input hashes are saved as `bridge-absent*` and `bridge-enabled*` under the experiment directory. This proves attachment and PCI configuration reads, not disk I/O or interrupt delivery.
4. Add a disk backed by a new, disposable image. **Disk discovery passed with VirtIO:** the guest attached `AppleVirtIOPCITransport`, `AppleVirtIOBlockStorageDevice`, and `IOBlockStorageDriver`, then published a 1 GiB `IOMedia` as `disk0`. The NVMe attempt failed earlier because `IONVMeFamily` and `AppleVirtIOStorage` both define `AppleNVMeEAN`; the latter is a required dependency of `AppleVirtualPlatform`. The VirtIO route uses the platform's existing block driver and avoids loading the conflicting NVMe driver. Logs are `nvme-detection.log` and `virtio-detection*` in the experiment directory. The APFS mount and marker checks described next also passed.
5. Write one marker file, stop QEMU, start a new QEMU process with the same disk image, and read the marker back. **Passed on October 18:** the first guest mounted `FinchData`, created a new mode-0600 marker, called `fsync` and `F_FULLFSYNC`, and unmounted the volume. QEMU then exited. A fresh QEMU process mounted the same volume and checked the exact contents, root ownership, and mode. The disk image changed; all five boot inputs stayed unchanged. `data-write.log`, `data-read-reboot.log`, and `persistence-result.json` record this under the experiment directory.

This test proves the marker survives a full QEMU restart under Finch XNU after a full flush and an orderly volume unmount. A listed device, a successful mount in one run, or an Apple-kernel boot is not enough. It proves only the basic QEMU disk path. It does not prove normal shutdown behavior, user-data placement, update safety, or hardware installation. It also uses the base image's closed APFS mount helper and sandbox library; it does not close the release's open-userland requirements.

### Full-disk mount stall (AIC level lines)

Mounting a populated system image (`build/vm-persistent/system-gpt.cdr`) stalled
in APFS waiting for a read that QEMU's trace showed as completed. Turning off
VirtIO `event_idx` did not help. The cause was QEMU's AIC model: it latched only
the rising edge of an interrupt line, while `AppleInterruptControllerV3` masks a
claimed vector and expects it to fire again on re-enable if the device still
holds the line high. A completion signalled in that window was lost.
`third_party/patches/qemu-sptm/0003` tracks the line level; with it, two runs
mounted the full image, read all of it (`du`, `find`), and unmounted cleanly
(`filled-disk-aic-level*.log`). The bridge itself is patch 0002. Both are
Finch-local QEMU patches (`docs/DEV_VM.md`).

### Forced VM stop

A second October 18 check created a different marker and fully flushed it,
then killed that exact QEMU process with `SIGKILL` while APFS was mounted.
A new QEMU process mounted the same disk and verified both markers' exact
contents, root ownership, and mode. Both reads passed. All five boot inputs
kept the same hashes across the two runs. `data-crash-write-2.log`,
`data-crash-read-2.log`, and `crash-recovery-result.json` hold the evidence.
The first attempt's host script failed before sending the signal; its log is
kept separately and does not count as a passing crash test.

This proves recovery from a VM process stop after a full file flush. It does
not prove recovery from host power loss, interrupted unflushed writes, or a
normal Finch shutdown with accounts and homes on disk.

### Build a Finch-owned storage bridge or device

If the Apple bridge cannot link with Finch XNU or depends on Apple-only behavior, Finch needs its own IOKit path. One choice is a Finch PCI host bridge that publishes GPEX devices so the existing NVMe driver can attach. Another is a simpler Finch virtual block device that avoids PCI altogether. Both need a QEMU device, a Finch driver, and an APFS mount test. Neither exists today.

Use the same disposable-image marker test for either choice: start Finch XNU, write a marker, fully stop the VM, start it again with the same image, and verify the marker. Keep this test separate from system boot and user data until it passes.

## Next boot-time integration

The next bounded change is an explicit development VM data-image option.
Leaving it unset must keep today's RAM-backed boot. Enabling it must require
an existing, identified data volume; startup must never format a disk or
quietly substitute RAM when that volume is missing or unreadable.

The existing `/private/var/rw` mount is the first integration point. `/Users`
and `/private/var/db` already point into it. Temporary files, process state,
logs, and caches can stay in RAM. Root's home currently has its own RAM mount
and needs a separate decision before this can count as complete persistence.

Account files need more than this mount. Normal login reads `/private/etc`,
while the account tool writes to its selected directory. All readers and
writers must reach the same durable account files. Copying files into RAM on
each boot would lose later password changes. Account setup must be explicit,
and OS updates need a safe way to add required system accounts without
replacing saved user accounts.

Finch now stops ordinary startup when its required boot script is missing or
fails. It skips service jobs and login. The explicit development-console
setting permits a recovery shell; normal login mode remains stopped and prints
recovery directions. This prevents a future required data-mount failure from
quietly starting an incomplete system. Separate VM images checked all three paths: exit 42
opened development recovery with no service jobs; the same failure in normal
login mode stayed blocked without a shell; a successful script started
`notifyd`, `configd`, and `syslogd`. The logs and `result.json` are under
`build/continuation-20261018/startup-recovery/`. The normal VM image has not
yet been rebuilt with this init change.

### Boot with the data volume (October 18)

Data mounting is now wired into startup. When `/private/etc/finch/data-volume`
names a volume (or the account files are links into it), `rc` runs
`finch-data-volume` before anything else and keeps `/private/var/root` and
`/private/var/rw` off tmpfs. The test system image (`system-gpt.cdr`) got the
new `rc`, helper, and account code, had its owners set to root from inside the
guest (`finch-finalize-image`, 11,829 entries), and its APFS partition was
booted as the RAM disk with `data.cdr` attached:

1. First boot: `/dev/disk1s1` mounted on `/private/var/rw` (`nodev`, `nosuid`);
   `/private/etc/master.passwd` resolved to the data volume; `id root` and
   `id finchtest` worked; `notifyd`, `configd`, and `syslogd` started. A
   mode-0600 marker was written to `/private/var/rw/db` (`data-boot-1.log`).
2. Fresh QEMU process: the marker read back with its contents, `0:0`, and mode
   `0600` (`data-boot-2.log`).
3. Same system, no data disk: the helper gave up after 30 seconds, `rc` exited
   1, and `finch-init` started no services; only the explicitly enabled
   development recovery shell opened, with nothing mounted on
   `/private/var/rw` (`data-boot-missing.log`).

That image dropped the setuid bit on `/usr/bin/passwd` and was prepared by
manual scripts. Both are fixed by the persistent development image below.

### Persistent development image (October 24)

`tools/vm/mkpersistent.sh` builds `build/vm-persistent` from the normal VM image,
without sudo:

- `system.dmg` is the VM image's files copied into a new APFS volume (a new
  volume UUID, so it can't be confused with the setup boot's root). The account
  files become links into `/private/var/rw/accounts`, and the image keeps the
  originals in `/usr/share/finch/accounts` as the seed for a new data volume.
  `/private/var/root` links to the data volume too. `tools/vm/image-owners.py`
  writes the owner and mode of every file, by the release archive's rules
  (`tools/release/mkrootfs.py`), to `/usr/share/finch/image-owners.txt`.
- One setup boot attaches both disks and runs `finch-volume-setup` as root:
  `system UUID` applies the manifest (11,844 entries, setuid bits included), and
  for a new data disk `data UUID SYSTEM-UUID` lays out the accounts, `Users`,
  `db` and `root` folders that `finch-data-volume` requires. It refuses a data
  volume that already has accounts. Both find volumes by UUID on a VirtIO disk,
  through the same registry code as `finch-data-volume`.
- `data.img` is made once and kept, so rebuilding the system image keeps users'
  data. `data-empty.img` is a clone of the fresh layout for tests.

`FINCH_PERSISTENT=1 tools/vm/run.sh` boots it.

A new account's home now starts with macOS's standard folders (Desktop,
Documents, Downloads, Library, Movies, Music, Pictures, Public and its Drop
Box), made after the account is saved, so a failed save still removes only the
empty home. The first stored-data run stopped because the new home had no
`Documents`.

**Stored-data check** (`tools/vm/test-persistence.sh`, on a fresh copy of the
empty data disk): passed on 2026-10-25. Boot 1 found a fresh data volume mounted with
`nodev`, `nosuid`, the account files on it as root's (mode 0600 for
`master.passwd`), system files root's with `passwd` setuid, and notifyd, configd
and syslogd running. It created user `persist` with `accountctl`, logged in
through `login` and PAM, saved a mode-0600 file in `Documents` and a preference
file, checked that the user could not list another user's `Documents`, write
into their home, or write the account files or `/usr/bin/passwd`, and changed
the password with `passwd`. Each boot ends with `halt` (finch-init's shutdown,
which syncs and unmounts). Boots 2 and 3 checked that the old password is
refused and the new one logs in, read the files back with the same contents,
owner and modes, and appended to a file whose line count proves each earlier
boot's write survived. The run's log is
`build/continuation-20261025/persistence-pass.log`.

Fixed on the way: new homes had no standard folders; the image's homes
(rc's and the setup tool's) had `Documents` and the rest at mode 0755, readable
by every user, where macOS has 0700; and `mkpersistent.sh` exited 1 after
success. The check passes again on an image with Finch's own sandbox compiler
and nothing borrowed (2026-10-25, after the sandbox work in
docs/design/SECURITY.md).

Timing: login and `passwd` run several 600,000-round PBKDF2 derivations (the
account hash and the login keychain) on the VM's single emulated CPU. The same
`passwd` step took between 20 seconds and 51 minutes across runs on this Mac,
while later logins took seconds; the guest showed `passwd` alone running
(CPU-bound, decayed priority), so the spread looks like host scheduling of
QEMU's one TCG thread. The test allows 900 seconds a step. One earlier boot
also logged Apple System Policy (the borrowed ASP kext) denying `/dev/tty`
reads to `bash` and `accountctl`; it didn't recur in four later boots of the
same image, and its cause is unknown.

This covers the release table's stored-data row for accounts, passwords and home
files in the development VM. Network settings aren't saved yet, and the system
image still boots as a RAM disk with the data volume as its only writable disk;
an installed system's own boot volume and updates that switch it remain open.
Separate missing, wrong, unformatted and corrupt disk checks are also still
needed (only the missing-disk case is tested above).

## Work still needed after the disk test

A disk that survives a restart is only the first step. Finch still needs a stable layout for user files and settings, clear ownership rules, and a way to keep account data consistent with those files. The updater must know which system pieces boot together, preserve the data volume, and return to a working system if an update fails. The install and recovery process must then be proven on supported Apple hardware.

Until those steps are implemented and tested, persistent user data, settings, boot-aware updates, hardware installation, and recovery are all **unimplemented**. The current RAM disk must not be described as durable storage.
