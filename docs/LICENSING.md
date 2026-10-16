# Licensing & Provenance

This is not legal advice. Before Finch ships anything publicly, a real lawyer should
review this. The rules below exist to keep us out of trouble until then.

## Finch's own code

Original Finch code is dual-licensed **MIT OR Apache-2.0**, at the user's option (see
`LICENSE-MIT` and `LICENSE-APACHE`). Every source file carries
`SPDX-License-Identifier: MIT OR Apache-2.0`.

- **Why dual:** MIT keeps our code GPL-2.0-compatible, so Asahi Linux and other GPL
  projects can take our driver and hardware work. Apache-2.0 offers an explicit patent
  grant to those who want it. Rust and much of the Asahi ecosystem use the same
  arrangement.
- **Exception: changes to Apple's files.** Patches to XNU or other APSL-licensed files
  (`kernel/patches/`) stay APSL-2.0, as that license requires. New standalone files,
  such as Finch kexts, use MIT OR Apache-2.0.
- **Imported code** keeps its original license and headers.

Contributions are accepted under the same dual license (inbound = outbound).

## Sources

| Source | License | How we use it |
|---|---|---|
| XNU, most Darwin userland | APSL 2.0 | Build and modify. Modifications to APSL files stay APSL and must be published. |
| CF-Lite, libdispatch, swift-corelibs, Swift, LLVM/clang | Apache 2.0 / APSL | Build directly |
| WebKit | BSD / LGPL | Build directly |
| cron-52 | Vixie, BSD and Apple notices as supplied | Built from the pinned source, with Finch patches recorded and the full source licence installed. |
| system_cmds-1042.100.6.0.1 at/atrun | BSD and Apple notices as supplied | Builds one-time jobs without the closed background-task service; source notices travel with the programs. |
| mDNSResponder-2881.100.56.0.1 | Apache 2.0 daemon; BSD-3 client | Builds the DNS-SD client and portable POSIX daemon; keeps source notices. |
| Mozilla CA roots, curl export 2026-09-25 | MPL 2.0 | Dated bundle checked by SHA-256; source record and licence installed beside Finch’s other notices. |
| OpenSSL 3.5.9 | Apache 2.0 | Built and linked statically into Finch's libcorecrypto, Security.framework and Foundation.framework (TLS for the URL loading system) |
| swift-crypto 5.0.1, with vendored BoringSSL revision `0226f30467f540a3f62ef48d453f93927da199b6` and XKCP revision `11297f5` | Apache 2.0 for Swift Crypto and BoringSSL; XKCP files keep their public-domain notices | Built into CryptoKit.framework with BoringSSL and XKCP linked privately. The upstream `LICENSE.txt`, `NOTICE.txt`, source revisions and collected notices for the built files install under `/usr/share/finch/licenses/swift-crypto/`. |
| cmark-gfm 0.29.0.gfm.13 | BSD-2-Clause; `COPYING` also keeps MIT notices for derived files | Built statically into Foundation for Markdown parsing. The exact tag is pinned in `userland/third-party-projects.txt`; `COPYING` ships at `/usr/share/finch/licenses/cmark-gfm/`. |
| swift-foundation, swift-experimental-string-processing (`swift-6.3.1-RELEASE`), swift-collections 1.1.6 | Apache 2.0, with Swift's Runtime Library Exception where stated | Foundation's Swift value types and private collections; Swift's string and regex libraries. Source notices ship with the image. |
| Swift Darwin overlays (`swift-5.4-RELEASE`, `swift-5.2.5-RELEASE`) | Apache 2.0 with Runtime Library Exception | Historical open Foundation, CoreFoundation, IOKit, simd and Darwin sources, adapted for the current SDK. Imported files retain their notices. |
| swift-system 1.8.1 | Apache 2.0 with Runtime Library Exception | Built as `/usr/lib/swift/libswiftSystem.dylib` (Swift System: `FilePath`, `FileDescriptor`, `Errno`), with Finch's compatibility entry points (`userland/swift/overlays/System`). |
| objc4-951.7 and libdispatch-1542.100.32 Swift overlays | objc4 project APSL 2.0; Dispatch Swift sources Apache 2.0 with Runtime Library Exception | Built from their pinned source trees. The overlay build installs the project licences and the compiled files' copyright notices in `objc4-swift-overlay` and `libdispatch-swift-overlay`; the Dispatch folder also keeps Swift's licence and exception. |
| configd-1405.100.8 | APSL 2.0 | SystemConfiguration's key helpers and generated schema constants. The build collects the source notices. |
| DiskArbitration-535.100.31 | APSL 2.0 | Client framework and disk daemon from published source. Finch keeps its daemon changes as patches and installs the source licence. |
| LZFSE 1.0, LZ4 1.10.0 (lib), Brotli 1.1.0 | BSD-3 / BSD-2 / MIT | Built and linked statically into Finch's libcompression |
| XZ Utils 5.4.3 (liblzma), libxo, libsbuf | 0BSD / BSD | Build directly |
| libxml2 (Apple's libxml2-39.10) | MIT | Build directly (Foundation's NSXMLParser links it) |
| OpenCombine 0.14.0 | MIT | Adapted and built as Combine.framework (`docs/design/COMBINE.md`) |
| OpenSwiftUI (`aefa4e6`), OpenAttributeGraph, OpenObservation, OpenRenderBox, OpenCoreGraphics (revisions pinned by OpenSwiftUI's `Package.resolved`), Compute 0.6.0 (the attribute graph) | MIT | Adapted and built as SwiftUI.framework and SwiftUICore.framework (`docs/design/SWIFTUI.md`). Notices ship in the image. OpenSwiftUI's DarwinPrivateFrameworks package (headers for Apple's private frameworks) is fetched by SwiftPM but switched off: nothing from it is linked. swift-numerics and swift-syntax (Apache 2.0) are build-time dependencies only. Finch patches Compute for arm64e (`userland/SwiftUI/patches/Compute`). |
| Skia (chrome/m155) | BSD-3 | Built and linked statically into Finch's CoreGraphics |
| FreeType | FTL or GPL-2.0 | Taken under the FTL (BSD-style, with a credit clause), linked statically with Skia |
| HarfBuzz, libpng, libjpeg-turbo, libwebp, wuffs, zlib (Chromium's), skcms | MIT / libpng / BSD-3 + IJG / BSD-3 / Apache 2.0 / Zlib / BSD-3 | Built with Skia, linked statically |
| Open Runde 1.0.1, Fragment Mono 1.21, Inter 4.1, Liberation 2.1.5, Noto Sans / Serif 2.015, Noto Sans Symbols 2.003 / Symbols 2 2.008 / Arabic 2.013 / Hebrew 3.001, Noto Sans CJK 2.004, Noto Color Emoji 2.051 | OFL-1.1 | Shipped unmodified (`userland/fonts/build.sh`, pinned by SHA-256) in place of Apple's fonts, which can't be redistributed. The OFL allows bundling with any software; the fonts may not be sold on their own, and a modified font must drop its Reserved Font Name. Finch doesn't modify them. |
| XCharter 1.26 | Bitstream free font licence | Four unchanged OpenType faces, with the full font licence from the package README. |
| TeX Gyre Pagella 2.501 | GUST Font License | Four unchanged OpenType faces, with `GUST-FONT-LICENSE.txt` and `README-TeX-Gyre-Pagella.txt`. |
| DejaVu Sans Mono 2.37 | Bitstream Vera licence (DejaVu's changes public domain) | Shipped unmodified, as above. Permissive; a modified font must be renamed away from "Bitstream" and "Vera". |
| m1n1 | MIT | Import |
| Mesa 25.0.7 (softpipe, OSMesa, GLSL compiler, util) | MIT, with some files under BSD/Boost-style licences and Bison's parser-skeleton exception | Built by Finch as OpenGL.framework's libGL (`userland/OpenGL/mesa.sh`, pinned by commit); the build checks that no GPL-only file is compiled in, and the licences ship under `/usr/share/finch/licenses/mesa` |
| Mesa (incl. asahi driver), for GPU drivers later | MIT | Import |
| Asahi **documentation** (wiki, register notes) | Docs | Use as reference |
| Asahi Linux kernel code, **dual-licensed** files (e.g. `drivers/gpu/drm/asahi`: `GPL-2.0-only OR MIT`) | MIT option | Import under MIT. Keep the SPDX line and copyright. |
| Asahi Linux kernel code, **GPL-only** files | GPL-2.0 | **Reference only, under the clean-room rule** |
| GNUstep | LGPL | Case by case. Dynamic linking is fine; avoid copying it into APSL/MIT files. |
| Darling | GPL-3.0 | Ideas and research only. No code. |
| Apple proprietary binaries (kexts, frameworks, firmware) | Apple EULA | **Never committed, never redistributed.** Since 2026-10-08 only the kexts (and firmware) are loaded, from the user's own macOS install at runtime. Closed libraries and frameworks are never loaded. |

## Notices in the image

A third-party licence that requires its notice to travel with binaries (Apache,
MIT, BSD) is installed at `/usr/share/finch/licenses/<project>/`. The component
that embeds the code installs it. For example, `make -C userland/corecrypto
install` installs OpenSSL's `LICENSE.txt` and `AUTHORS.md`. For projects built with
`tools/build-oss.sh`, `userland/oss/<project>.notices` lists the source files to
install (OpenBSM's and OpenPAM's `LICENSE`, ncurses' `COPYING`). libm's build
installs CORE-MATH's and FreeBSD msun's notices. `userland/fonts/build.sh` installs each
font family's licence (`OFL.txt`, `LICENSE`) at `/usr/share/finch/licenses/<family>/`. Where every source file
carries its own notice (CORE-MATH's per-file authors, msun's mix of BSD and Sun
fdlibm notices), `tools/collect-notices.py` collects them from exactly the
files built in, listing each distinct notice once with the files it covers.
The `msdosfs` and `diskdev_cmds` recipes install both Apple's licence and the
notices from their compiled files, including the FAT tools' BSD notices.

## Clean-room rule for GPL drivers

Check each file's SPDX header first. Much of Asahi's newer Rust code is dual-licensed
`GPL-2.0-only OR MIT`, and we take that code under MIT. The rule below applies only to
GPL-only files.


APSL-2.0 and GPL-2.0 are mutually incompatible, so copying Linux driver code into an XNU
kext produces something nobody can legally distribute.

1. Hardware facts (register offsets, bit meanings, command protocols, firmware message
   formats) are not copyrightable. Write them up in `docs/hw/` in our own words.
2. Kext code is written from those writeups and m1n1/hardware traces, not by translating
   Linux source line by line.
3. When a driver is substantially informed by a specific Linux driver, record that in the
   commit message so provenance is auditable.

## Firmware

Some hardware (Wi-Fi, Bluetooth, DCP, GPU, ANS coprocessors) runs Apple firmware that is
loaded at boot. Asahi extracts it from the user's macOS install at install time, and so
will Finch. It is never committed to this repo.

## Trademarks

"Mac", "macOS", "Apple" and the like describe compatibility only. No Apple logos, icons or
artwork go into Finch's UI.
