# Dev VM: emulated M4 (Tier 1)

[darwin-vm](https://github.com/jprx/darwin-vm) runs Apple Silicon Darwin in QEMU
(`qemu-sptm` fork). It's pinned as a submodule at `third_party/darwin-vm`. Its
`firmware/` directory holds Apple binaries extracted from an IPSW. They live only in the
submodule's working tree and are never committed.

## Sandbox compiler needed for startup

The fresh 2026-10-17 image cannot start notifyd with Finch's current
`libsandbox.1.dylib`: the library does not compile or apply named sandbox
profiles. The older VM had inherited the compiler from its base image. To
retain that compiler explicitly while testing other parts of Finch, build with:

```sh
FINCH_VM_BASE_SANDBOX=1 tools/vm/with-vm-lock.sh tools/vm/mkramdisk.sh
```

This option borrows the base image's library, reports its hash in the build
log, and records the choice in
`/usr/share/finch/development-borrowed-components.txt` inside the image. It does
not change `build/root` or the install archive. It is a development aid, not a
release fix. Finch still needs its own compiler and tests showing that the
kernel enforces the resulting restrictions. Without the option, the builder
uses Finch's library and the startup blocker remains visible.

The VM test runner reads that marker from the running guest. It reports the
borrowed library and marks `libsandbox-test` as unverified even if the program
exits successfully. A known-failure entry cannot turn that result into a pass.

## Target
| | |
|---|---|
| Emulated device | `Mac16,10` (M4 Mac mini, j773gap) |
| SoC / kernel ext | `t8132` / `mac16g` |
| macOS | 26.4.1 (25E253): same build as the host |
| Stock kernel | `xnu-12377.101.15~1/RELEASE_ARM64_T8132` |

## Setup (one time)

```sh
brew install jq ipsw ninja pkgconf glib pixman python@3.13
git submodule update --init --recursive third_party/darwin-vm
git -C third_party/darwin-vm/qemu-sptm apply ../../patches/qemu-sptm/*.patch

# Build QEMU. Notes:
# - The host has MacPorts in /opt/local, which shadows Homebrew; put Homebrew first.
# - The build runs scripts via `#!/usr/bin/env python3`, which must be ≥3.12
#   (the system's 3.9 fails on nested-quote f-strings in dumpregs.py).
cd third_party/darwin-vm/qemu-sptm && mkdir build && cd build
export PATH=/opt/homebrew/opt/python@3.13/libexec/bin:/opt/homebrew/bin:$PATH
export PKG_CONFIG_PATH=/opt/homebrew/lib/pkgconfig
../configure --python=python3 --target-list=aarch64-softmmu --disable-pvg
make -j10
cd ../..

# Fetch firmware: partial remote extraction, not a full IPSW download.
DEVNAME="Mac16,10" \
URL="https://updates.cdn-apple.com/2026WinterFCS/fullrestores/122-28781/DCB2FF13-06CB-44C2-BCA2-DFCAF3521D46/UniversalMac_26.4.1_25E253_Restore.ipsw" \
./get_files.sh

# Needs sudo. Run in a real terminal.
echo y | ./fix_perms.sh firmware/ramdisk.dmg
```

## Run
- Interactive: `cd third_party/darwin-vm && ./run.sh`. Quit with `Ctrl-A x`.
- Automated smoke test: `expect tools/vm/smoke.exp`. It boots to the root shell, runs
  `uname -a` and `sysctl`, and quits.

## The desktop, live

`tools/vm/desktop.sh [--size WxH] [APP ...]` boots the VM with Finch's window server on the
guest's tunnel UART (`QEMUPORT`, 2100 by default) and shows its display in `finch-viewer` on the
host, which sends mouse and keys back. The apps named start in the VM, e.g.
`tools/vm/desktop.sh /Applications/SwiftUIGallery.app/Contents/MacOS/SwiftUIGallery`. The
console stays yours (Ctrl-A x quits). With `DESKTOP_SECONDS` it stops by itself, and
`VIEWER_ARGS="--dump PATH --frames N"` saves the display. The line carries about 350 KB/s, so
the display is at 1x (`DESKTOP_SCALE=2` for 2x) and a full screen takes a few seconds.

## Finch userland in the VM

```sh
make -C userland/finch-init       # -> build/userland/finch-init
tools/vm/mkramdisk.sh             # base ramdisk + tools/vm/overlay.txt -> build/vm/ (no sudo)
tools/vm/run.sh                   # boot with finch-init as PID 1 (launchdsuffix=finch)
expect tools/vm/smoke.exp
```

The base device tree runs the CPU's timer at 1 MHz; `tools/vm/run.sh` boots a copy
(`build/vm/dtree`, made by `tools/vm/dtree-timebase.py`) with Apple silicon's 24 MHz timebase,
which code built for the M4 assumes (Swift's `Task.sleep` turns deadlines into ticks at 24 MHz, and
at 1 MHz never woke).

The emulated M4 has no real-time clock. `tools/vm/run.sh` passes the host's time as the
boot-arg `finch_time=SECONDS`, and finch-init sets the clock from it when the clock is behind.

`tools/vm/run.sh` uses `build/vm/ramdisk.dmg` when it exists. Otherwise it uses darwin-vm's
base ramdisk.

The image adds a test user, `finchtest` (uid 501, no password, so it's reachable only
by `su` from root), for per-user domain tests. Home directories are under `/Users`, a
link into the `/private/var/rw` tmpfs, as `/var/db` is.

`mkramdisk.sh` runs without sudo, so files it adds belong to `_unknown` (uid 99) in the VM,
not root. Everything runs as root there, so this rarely matters. The exception is setuid
tools used by another user, e.g. `su` run from `nobody` reports "not running setuid".

### Finalize account-file owners in the dev image

`mkramdisk.sh` does not set the owner bits that a mounted disk image would need to show
root-owned account files. The normal build stays unprivileged. If a test needs those owners,
first build the small account helper as your usual user, then run the optional finalizer in a
real terminal:

```sh
make -C userland/system-accounts
sudo tools/vm/finalize-system-accounts.sh
```

The finalizer only accepts `build/vm/ramdisk.dmg`. It refuses a running or attached copy,
uses the VM lock without waiting, and changes a private copy of the image first. It enables
ownership on that temporary mount, fixes only `master.passwd`, `passwd`, and `group`, adds
the locked `_notifyd` entry from `userland/release/etc`, and checks the result before replacing
the original file. If a check fails, the original image stays in place. If the copy cannot be
detached, the tool keeps the temporary files so they can be inspected.

The finalizer prints the old and new SHA-256 hashes. Account changes alter the ramdisk hash;
they do not change `ramdisk.tc`. Any saved VM test run record that names the old ramdisk hash
no longer describes the image on disk. This is a local development repair, not a release
install step. The recovery logic can be checked without an image by running
`tools/vm/tests/finalize-system-accounts-cleanup-test.sh`.

## The VM test suite

`tools/vm/vm-tests.py` runs every test program in the image (`tools/vm/overlay.txt`) in one
boot and checks each: the host suite's comparison tests against Apple's output on the host
(all but the first line, by checksum), its window-server and Finch-only tests against their
`.expected` files, and explicitly listed self-checking tests by exit status. A new test
must declare how its result is checked. Every check also needs exit status 0. Each test
has 240 seconds; one that hangs is killed and the rest still run. The guest runs Finch with
the host suite's settings (`FINCH_THEME=Classic`), and window tests take a step a second
(`FINCH_TEST_TICK=1`), since QEMU is about fifty times slower than the M4.

```sh
tools/vm/mkramdisk.sh
tools/vm/vm-tests.py              # every test in the image
tools/vm/vm-tests.py cf-test      # some of them
tools/vm/vm-tests.py --scripts    # and the test scripts that set up a guest of their own
tools/vm/vm-tests.py --list       # how each is checked
tools/vm/vm-tests.py --coverage   # tests the Makefile builds that no suite runs
```

Set `KC` to use Finch's rebuilt kernel; without it, the VM uses the base firmware's
kernel. `FINCH_BOOTKC` is not supported and is rejected by the launcher. For example:

```sh
KC="$PWD/build/kc/finch-0.0.1.t8132.development" tools/vm/vm-tests.py sandbox-enforcement-proof-test
```

Each run saves `build/vm-tests/run.json` with the kernel, disk image and trust-cache
paths and hashes, the selected boot options, and display state around Apple
reference collection. The runner rejects missing inputs and fails if the input
files change during the run. The keychain script records its separate images
just before boot, then the runner checks their hashes again afterward. These
records identify the host files used; they do not prove guest enforcement or
turn a development image into a release. Keep the run record with its log before
starting another run, which replaces it.

An offline or changed host display can change Apple's layout and image results.
The runner records a warning and leaves the actual comparisons visible; it does
not treat those differences as passes. Video comparisons use the same bounded
lossy-color check as the host suite, while retaining exact checks for the other
reported fields.

A failed test's output and what it should have been are left in `build/vm-tests/`
(`diff NAME.want NAME.vm`). Fields that depend on the machine (home and temporary folders,
the model, this Mac's units) are masked in both outputs (`tools/test-masks.txt`, shared with
the host suite). Known failures, each with its reason, are in `tools/vm/vm-test-exceptions.txt`;
one that passes again fails the run until it's removed.

Apps from this Mac's install are checked by scripts of their own, with the app in the image:
`FINCH_HOST_APPS=TextEdit tools/vm/mkramdisk.sh && tools/vm/test-textedit.sh` opens a text file,
saves it twice, restores the earlier version with File > Revert To > Browse All Versions,
exports it as a PDF, and checks the files after each step.
`FINCH_HOST_APPS=Calculator tools/vm/mkramdisk.sh && tools/vm/test-calculator.sh` types
expressions into Calculator, copies each result (⌘C) and checks it with `pbpaste`.

## Apple open-source commands

```sh
tools/fetch-src.sh                       # clone projects pinned in userland/projects.txt
tools/mksdk.sh                           # private-header overlay -> build/sdk
tools/build-oss.sh file_cmds executables # xcodebuild -> build/root (signed)
tools/build-oss.sh shell_cmds All_OSX
tools/build-oss.sh text_cmds executables
tools/build-oss.sh adv_cmds Desktop
tools/build-oss.sh system_cmds All_MacOSX
tools/vm/mkramdisk.sh                    # overlays build/root, trusts every Mach-O, checks dylib deps
expect tools/vm/smoke.exp "ls -la /bin" "df -h /"
```

## libSystem pieces

```sh
tools/build-oss.sh libsyscall          # -> libsystem_kernel.dylib (needs tools/build-kernel.sh first)
tools/build-oss.sh libplatform         # -> libsystem_platform.dylib
tools/check-exports.sh /usr/lib/system/libsystem_platform.dylib
tools/build-llvm-runtimes.sh           # -> libc++, libc++abi, libunwind, libcompiler_rt (upstream LLVM)
tools/build-oss.sh objc4 objc-env objc  # -> libobjc.A.dylib
```

`check-exports.sh` compares our dylib with Apple's original and fails if any binary in the
image imports a missing symbol, whether directly or through the libSystem umbrella.
Run it before booting a swapped library: a missing symbol in PID 1's closure panics the
boot.

## QEMU patches

Finch carries patches against `qemu-sptm` in `third_party/patches/qemu-sptm/`. Apply them
before building QEMU:
`git -C third_party/darwin-vm/qemu-sptm apply ../../patches/qemu-sptm/*.patch`

- 0001: clear FEAT_LVA (`ID_AA64MMFR2_EL1.VARange`). Apple Silicon doesn't have it, and
  DEVELOPMENT kernels assert on it (`vm_sanitize.c`). This bug panicked the first
  `ps` run under finch-init. Reported upstream: https://github.com/jprx/darwin-vm/issues/14
- 0002: opt-in `finch-pcie=on` machine property. Adds one GPEX host (ECAM `0x40000000`,
  MMIO `0x50000000`, AIC lines `0x20`-`0x2f`) so `tools/vm/run.sh` can attach a VirtIO data
  disk (`FINCH_DATA_IMAGE`, `docs/design/PERSISTENT_VM_STORAGE.md`). Off by default.
- 0003: AIC v3 keeps level-triggered lines pending. The model only latched a rising edge, so a
  PCI device still holding its line high when the guest re-enabled the vector was lost, and
  mounting a full APFS disk stalled waiting for a completed read. Claiming a V3 vector now
  masks it, and re-enabling a vector whose line is still high makes it pending again
  (matching `AppleInterruptControllerV3::handleInterrupt`).

0002 and 0003 are Finch-local and stay out of upstream (the QEMU code-provenance policy).

## Booting the Finch kernel

```sh
tools/build-kernel.sh --install   # build XNU + patches, link KC, make it darwin-vm's bootkc
expect tools/vm/smoke.exp
```

The original kernelcache from Apple's restore image is kept at `firmware/kcs/stock.release`. To go back to it:
`ln -sfn kcs/stock.release third_party/darwin-vm/firmware/bootkc`.

## Debugging an early panic

If nothing prints, the kernel probably panicked before the console came up. Run QEMU with
`-s -S`, then attach lldb to the kernel collection. darwin-vm loads it slid by 0x20000000:

```
target create build/kc/finch-0.0.1.t8132.development
target modules load --file finch-0.0.1.t8132.development --slide 0x20000000
gdb-remote 127.0.0.1:1234
br set -n panic_with_thread_kernel_state
c
```

## Known intermittent boot failures

Smoke runs failed now and then in two ways, both seen in every session's logs
since Phase 1 (2026-10-06 onward: roughly 1 in 12 runs over several hundred).

- **New processes stall after the jobs load.** Fixed 2026-10-10. `tools/vm/catch-stall.exp`
  boots until one stalls, then dumps the kernel's view through QEMU's GDB stub and XNU's lldb
  macros (`build/vm/stall-*.txt`). Every new process registers with the log service
  (firehose `register`, msgid 11600) as it starts; finch-init holds that port until
  finch-logd checks in, and its queue held 5 messages. When five processes beat finch-logd to
  it, the queue was full, every later sender blocked, and so did finch-logd itself, which
  registered with its own service from a log message before `main` and so never checked in.
  finch-logd now runs with `OS_ACTIVITY_MODE=disable` (it doesn't log through itself), and
  the service ports finch-init holds take 1024 messages. 22 boots after the fix: no stall.
  `smoke.exp` and `catch-stall.exp` also ask the shell for a fresh prompt before calling a
  boot stalled, as a kernel message printed after the prompt hides it from the pattern.
- **QEMU exits during the boot banner.** `smoke.exp` reports `send: spawn id
  ... not open`. The console stops mid-banner, right after
  `load_init_program`, and the emulator process is gone. Not yet
  investigated. As with any qemu-sptm bug, it would be reported upstream
  as an issue.

## Crashes in the VM

There is no crash reporter in the VM yet. `finch-app-test` reports a crash of the app it
runs: the exception, the registers and a frame-pointer backtrace as `crash:` lines on the
console (`userland/tests/crashwatch.c`). It takes the app's exceptions on an exception
port of the identity-protected kind; Finch's programs are platform binaries in the VM, and
the kernel kills one that sets any other kind. It reads the app's memory for the backtrace
as a declared debugger (`com.apple.security.cs.debugger`) of an app that allows debugging
(`com.apple.security.get-task-allow`, which the test apps are signed with). Without that,
it reports pc and lr only.

Symbolize the report on the host:

```sh
tools/vm/symbolize-crash.py LOG
```

It finds each frame's image through `tools/vm/overlay.txt` or `build/root`; shared cache
addresses go through `build/vm/dyld_shared_cache_arm64e.map` and the cache's slide, which
the report prints.

A crash that happens only in the VM may depend on what memory holds: try the host with
`MallocPreScribble=1 MallocScribble=1`, which fills new and freed memory, before a
long VM hunt.

### A stalled app

An app that hangs or spins shows nothing to `finch-app-test`. With `FINCH_SAMPLE_MAIN` set
to the app's process name (or `*`), Finch's CoreFoundation samples its main thread from
inside the process, which needs no debugger rights (Apple's apps grant none, and the VM
ignores `DYLD_*` variables): after `FINCH_SAMPLE_DELAY` seconds (10), `FINCH_SAMPLE_COUNT`
times (3), `FINCH_SAMPLE_INTERVAL` seconds apart (2), it prints the stack as `sample:` lines.

```sh
tools/vm/with-vm-lock.sh expect tools/vm/smoke.exp \
  "FINCH_SAMPLE_MAIN=Terminal FINCH_SAMPLE_DELAY=30 finch-app-test /usr/libexec/finch-windowserver /Applications/Terminal.app/Contents/MacOS/Terminal wait:40000 output"
```

An uncaught exception prints its first throw call stack, as on macOS.

Other switches for an AppKit app (they work on the host too):

- `FINCH_TRACE_KEYS=1`: each key-down, the responder it went to, and whether a key
  equivalent in the window took it when it came back to the window.

- `FINCH_PROFILE_MAIN=SECONDS[,COUNT]`: after that long, samples the main thread COUNT
  times (100) 20 ms apart and prints the functions seen, most frequent first (inclusive,
  then leaf), and how long five blocks sent to the main queue waited. For an app that is
  busy rather than blocked.
- `FINCH_DUMP_THREADS=SECONDS`: every thread's stack, once (timed from when AppKit loads).
- `FINCH_TRACE_EXIT=1`: the stack of whatever calls exit().
- `FINCH_DUMP_VIEWS=SECONDS`: each window's view tree, with buttons' titles, images and
  actions.
- `FINCH_SWIFTUI_WARNINGS=1`: SwiftUI's runtime warnings on stderr.
- `FINCH_LOG_PRIVATE=1`: the process's log messages keep their private values (in
  `log show` and on stderr), for errors an app logs privately.
- `FINCH_LOG_BACKTRACE=TEXT`: the stack of every log message whose format contains TEXT.
- `FINCH_LOG_MIRROR=TEXT`: every message (debug level and signposts included) whose
  subsystem, category or format contains TEXT, on stderr: `concurrency` shows Swift's
  task events, without `OS_ACTIVITY_DT_MODE`'s flood.
- `FINCH_SWIFTUI_OBJECTS=1`: each environment or observed object a SwiftUI view updates
  with, and its fields (`@Published` ones by their current value).
- `FINCH_COMBINE_TRACE=1` (or `bt`, with stacks): each `@Published` change, subject send
  and `objectWillChange`.
- `FINCH_TRACE_HIT=1`: the view each mouse-down goes to, and its superviews, and whether
  a SwiftUI button's mouse-up ran its action or was released outside.
- `FINCH_TRACE_DISPLAY=1`: each window invalidation (with its thread), each display
  pass, each layer that redraws, and layer changes outside any view's tree.
- `FINCH_DUMP_VIEWS=1` (SwiftUI windows): the sizes a window scene measures its content
  at (ideal, least, most) and opens at.
- `FINCH_TRACE_LAYOUT=1` (SwiftUI): every layout's size for each proposal, nested, with
  the answers custom layouts get from their subviews: where a size comes from.
- `FINCH_TRACE_AUTOLAYOUT=1`: each sync of a window's Auto Layout engine (constraints
  active, added, and whether it was rebuilt); `=2` also what marked it out of date.
- `FINCH_TRACE_PRINT=1`: what a print operation prints (the view, its pages) and how many
  layout fragments a TextKit 2 text view draws on each.
- `FINCH_MENU_DEBUG=1` (SwiftUI): what each picker is made of (its content's type, titles
  and tags; in menus and as pop-up or segmented controls) and the value a menu one sets.
- `FINCH_CALCULATE_DEBUG=1`: each key Calculate applies or refuses and the expression
  after it, and each time CalculateUI's display redraws.
- `OpenSWIFTUI_EVENT_DEBUG=ebph` (events, bindings, phases, hit testing) with
  `FINCH_LOG_MIRROR=vents`: SwiftUI's event debugging.

To try one of Finch's test apps in the VM, give `FINCH_HOST_APPS` its path:
`FINCH_HOST_APPS="$PWD/build/userland/apps/SwiftUIMore.app," tools/vm/mkramdisk.sh`.

## Console output
To check real password login with a disposable guest account, run
`tools/vm/with-vm-lock.sh expect tools/vm/account-console-smoke.exp`.
It checks the image's Finch login rules, stages root-owned account and PAM files
in guest memory, rejects a wrong password, verifies the logged-in user's identity
and home, and checks logout. This passed on 2026-10-13. It starts login under the
development setup shell. It does not change host accounts or save the test account
in the image.

For normal startup, first run `tools/vm/prepare-login-test-image.sh` under the VM
lock, then run `tools/vm/with-vm-lock.sh expect tools/vm/login-init-smoke.exp`.
The separate image uses Finch's release account files in guest memory. It checks
wrong-password refusal, user identity and home, and a fresh login prompt after
logout. This passed in QEMU on 2026-10-13. Optional command arguments run inside
that user session and fail the check on a nonzero exit. The shared keychain service
check also passed there; `tools/vm/test-keychain.sh` prepares the copy and runs the
keychain checks in that session.

The serial console drops bytes 0x80–0x9F, so 4-byte UTF-8 characters (emoji)
look garbled in `smoke.exp` logs, though the program wrote the right bytes.
Pipe output through `od -An -tx1` to check what a program actually wrote.

## Status
- 2026-10-06: the stock 25E253 kernel boots to a root shell. It reports
  `hw.model: Mac16,10` with 10 CPUs and 8 GB.
- 2026-10-06: **the Finch kernel boots** to a root shell:
  `Darwin Kernel Version 25.4.0 … finch:finch-0.0.1/xnu-12377.101.15/DEVELOPMENT_ARM64_T8132`.
  The first attempt panicked before the console came up. The public Xcode's
  `libclang_rt.cc_kext.a` `__chkstk_darwin` has no `bti c` landing pad, so a BTI fault
  recursed until the stack overflowed. Fixed by `kernel/patches/0001`.
