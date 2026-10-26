# Generated compatibility tests

These tests compare Finch's CoreFoundation, Foundation, CoreGraphics,
CoreText, ImageIO, AppKit, Security, CoreVideo, CoreMedia, CoreServices,
QuartzCore, CoreImage, UniformTypeIdentifiers, CFNetwork, ColorSync, Contacts,
CoreData, CoreLocation, Network, Metal, CoreSpotlight, AVFAudio, PDFKit,
Quartz, Quartz/PDFKit, Quartz/ImageKit, AVFoundation, AudioToolbox, IOKit,
SystemConfiguration, CoreMIDI, OpenDirectory, OpenDirectory/CFOpenDirectory,
StoreKit, LinkPresentation, and Accelerate frameworks with Apple's frameworks
on the same Mac. They use the current macOS SDK for the API list and C and
Objective-C method signatures.

## Run the comparisons

Build Finch's host frameworks first. The default run compares CoreFoundation
and Foundation. You can pass any supported framework name to compare one or
more frameworks:

```sh
python3 tools/difftest/run.py
python3 tools/difftest/run.py CoreFoundation
python3 tools/difftest/run.py Foundation
python3 tools/difftest/run.py CoreGraphics
python3 tools/difftest/run.py CoreText
python3 tools/difftest/run.py ImageIO
python3 tools/difftest/run.py AppKit --jobs 8
python3 tools/difftest/run.py Security CoreVideo CoreMedia CoreServices
python3 tools/difftest/run.py QuartzCore CoreImage UniformTypeIdentifiers CFNetwork ColorSync Contacts CoreData CoreLocation Network Metal CoreSpotlight AVFAudio --jobs 8
python3 tools/difftest/run.py PDFKit Quartz Quartz/PDFKit Quartz/ImageKit \
  AVFoundation AudioToolbox IOKit SystemConfiguration CoreMIDI OpenDirectory \
  OpenDirectory/CFOpenDirectory StoreKit LinkPresentation Accelerate --jobs 8
```

The runner builds one generated program for each framework and starts a fresh
process for each API item. It runs Apple first and Finch second, with Finch's
framework paths set in that child process. It does not use a wrapper that can
strip `DYLD_*` variables. For value calls, the runner compares up to eight
typed cases for each item. It also checks Objective-C class layout, protocol
method lists, and selector type signatures without calling those methods. It
uses parallel workers and reuses a generated binary when its source and SDK
have not changed.

Results go to `build/compat-results/<Framework>.json`, the same file used by
the constants comparison. The `items` map uses the IDs from
`tools/api-coverage.py`: C functions use IDs such as `c:_CFStringCreateWithBytes`,
and Objective-C selectors use IDs such as
`objc-class-method:NSString:-lowercaseString` or
`objc-class-method:NSPasteboard:+pasteboardWithName:`. Selectors that are
property accessors use the matching `objc-class-property:<Class>:<property>` ID.
Each comparison merges its item records into that map, so running one source
preserves the other source's results. A later result replaces the earlier status for the same ID
when it verifies, differs or crashes; a generated case marked not exercised
leaves another source's result for that ID in place, so the order of runs does
not matter. The API report counts records with `status: verified` as verified.
For value calls, this means the outputs matched. A record in the
`auto/objc/runtime-type` category means the public type or selector information
matched; it does not mean the method's output was tested. A difference records
the first row that did not match. Exceptions include their names and reasons.
The program normalizes object descriptions, pointer values, addresses, and
unordered collections before comparing results.

The AppKit run covers APIs that can be checked without opening windows or
starting a window server. It builds values for colors and color spaces, fonts,
paths, images and bitmap pixels, attributed text and paragraph styles, shadows,
gradients, cursor images, appearances, layout constraints, geometry, print
settings, and interface identifiers. It fixes the drawing appearance to Aqua
and uses private named pasteboards. Event inputs are values made by the test;
the runner skips calls that need a real mouse, keyboard, touch, window, drawing
context, printer, or shared pasteboard. Bitmap components may differ by one
8-bit value (1/255); geometry may differ by up to 0.01 points.

The added framework scopes use fixed, in-memory values. PDFKit and Quartz make
PDF pages and drawings in memory. Quartz also inventories its nested PDFKit and
ImageKit APIs. AVFoundation reads a small MOV file generated from Finch's own
test data and checks media values without playback or capture. AudioToolbox
uses fixed data and memory callbacks. IOKit checks registry-independent
helpers. SystemConfiguration checks fixed keys and preferences saved in a
temporary file; it skips reachability flags because those read the live network
route. CoreMIDI checks packet lists and UMP values without opening a MIDI port.
OpenDirectory and CFOpenDirectory check local values and serializers without
contacting a directory service or using credentials. StoreKit checks detached
value objects, and LinkPresentation checks detached link metadata. Accelerate
checks fixed-number vDSP, vImage, and simd values. These tests do not use a GPU,
device, account, or network service.

QuartzCore compares layer and animation values without depending on display
time. CoreImage checks filter and kernel values but skips rendering, GPU work,
installed-filter lists, and the expensive lazy Gaussian blur call.
UniformTypeIdentifiers checks fixed type identifiers and conformance.
CFNetwork checks in-memory HTTP messages and
stable constants. ColorSync checks fixed profile and color-space values.
Contacts checks detached contact and formatter values. CoreData checks model,
fetch, merge, and store descriptions without opening a persistent store.
Metal uses device-free descriptors and constants; it does not ask for a GPU or
submit commands. CoreSpotlight checks detached attribute and item values without
using the shared index. AVFAudio checks detached formats, layouts, times, and
buffers without starting an engine or using audio hardware.

CoreLocation's 204 APIs are inventoried but left unexercised. Finch CoreLocation
defines private classes that Apple's `_LocationEssentials` framework also
defines. Loading both sides in one process aborts, so the runner avoids starting
either comparison process. Network checks use fixed values only; calls that
need callbacks or live network state are skipped.

## How inputs are chosen

`tools/c-api-audit.py` parses Clang's JSON AST for the framework umbrella
headers. The generator uses each declaration's parameter and return types,
nullability, output direction, and declared enum values to choose inputs.
Pools cover common integers and boundaries, finite date values, strings,
numbers, data, collections, URLs, locales, time zones, calendars, character
sets, CoreGraphics geometry and transforms, colors and paths, and CoreText
fonts by name. Strings include ASCII, accents, combining marks, emoji,
right-to-left text, and a long value. A fixed seed keeps the generated cases
repeatable.

The generator uses a small hand-written set of safe builders where a type alone
does not provide enough context, such as a numeric buffer for `CFNumberCreate`
or a valid array for a collection call. Graphics builders make bitmap contexts,
images, PDF documents, and ImageIO sources and destinations in memory. Bitmap
pixels may differ by at most one value per color channel to allow harmless
rounding at edges. CoreText checks names that are installed on both sides and
marks a case unexercised if its requested font is missing on either side.
ImageIO codec lists can vary with the host's installed codecs, so those
differences are reported rather than hidden. The generator leaves an API
unexercised when it has no safe typed input, receiver, or callable signature.
It skips declarations that the active SDK marks unavailable or already
obsoleted, since Clang will not compile calls to them. It does not guess at
invalid ranges or pass `NULL` where the declaration does not allow it.

Security uses fixed EC and RSA key data, fixed certificates and trust anchors,
and a fixed trust date. It checks key attributes, signatures, verification,
encryption round trips, key exchange, certificate values, policies, and trust.
Random calls check only their status and requested length. The generator does
not use the user's keychain. CoreVideo checks pixel buffers, planes, pools,
attachments, and format descriptions. CoreMedia checks time and range math,
sample and block buffers, format descriptions, and timebases with fixed clocks.
CoreServices checks UTType creation and conformance, safe URL and file-reference
conversions in a temporary folder, and LaunchServices calls with stable answers.
It skips lookups whose answers depend on installed apps or default handlers.

The runner skips calls that can change state outside their process. This
includes file operations, network access, user defaults, notifications,
process creation, blocking waits, streams, autorelease-pool management,
diagnostic output, and APIs that need an archive context. It also reports
Swift-only entries with no Objective-C selector, missing Finch exports, SDK
inline functions, callbacks and variadic calls, missing signatures, and cases
with no safe typed input as separate skip categories.

## Read a result

Each item has one of four statuses:

- `verified`: both runs completed and their output matched.
- `differs`: both runs completed, but their output did not match.
- `crashes`: a run failed or timed out.
- `not-exercised`: the API could not be called safely with the available
  signature and input builders.

`verified_percent` is the share of exercised items that matched. `coverage_percent`
is the share of all inventoried SDK items that were exercised. A high verified
percentage does not mean that most of the SDK has been exercised.

## Results (2026-10-25)

The full run covered all 36 supported frameworks on macOS SDK 26.4. The table
shows each run's inventory and results. A `verified` runtime-type check means
that a class layout, protocol method list, or selector signature matched; it
does not test that method's output.

| Framework | SDK items | Exercised | Verified | Different | Crashes | Not exercised |
|---|---:|---:|---:|---:|---:|---:|
| CoreFoundation | 1,227 | 772 | 769 | 3 | 0 | 455 |
| Foundation | 8,444 | 4,158 | 3,568 | 590 | 0 | 4,286 |
| CoreGraphics | 841 | 396 | 384 | 12 | 0 | 445 |
| CoreText | 328 | 228 | 193 | 35 | 0 | 100 |
| ImageIO | 808 | 778 | 773 | 5 | 0 | 30 |
| AppKit | 10,418 | 8,445 | 7,457 | 988 | 0 | 1,973 |
| Security | 1,804 | 140 | 140 | 0 | 0 | 1,664 |
| CoreVideo | 302 | 196 | 196 | 0 | 0 | 106 |
| CoreMedia | 752 | 134 | 132 | 2 | 0 | 618 |
| CoreServices | 1,146 | 157 | 157 | 0 | 0 | 989 |
| QuartzCore | 672 | 631 | 511 | 120 | 0 | 41 |
| CoreImage | 1,272 | 1,023 | 752 | 271 | 0 | 249 |
| UniformTypeIdentifiers | 180 | 38 | 36 | 2 | 0 | 142 |
| CFNetwork | 231 | 33 | 29 | 4 | 0 | 198 |
| ColorSync | 205 | 150 | 150 | 0 | 0 | 55 |
| Contacts | 605 | 589 | 531 | 58 | 0 | 16 |
| CoreData | 748 | 742 | 505 | 237 | 0 | 6 |
| CoreLocation | 204 | 0 | 0 | 0 | 0 | 204 |
| Network | 442 | 6 | 4 | 2 | 0 | 436 |
| Metal | 1,444 | 1,378 | 950 | 428 | 0 | 66 |
| CoreSpotlight | 483 | 479 | 461 | 18 | 0 | 4 |
| AVFAudio | 813 | 777 | 649 | 128 | 0 | 36 |
| PDFKit | 651 | 381 | 197 | 184 | 0 | 270 |
| Quartz | 3,624 | 2,902 | 1,933 | 969 | 0 | 722 |
| Quartz/PDFKit | 651 | 381 | 197 | 184 | 0 | 270 |
| Quartz/ImageKit | 376 | 259 | 200 | 59 | 0 | 117 |
| AVFoundation | 4,206 | 4,117 | 2,673 | 1,444 | 0 | 89 |
| AudioToolbox | 541 | 176 | 4 | 172 | 0 | 365 |
| IOKit | 399 | 11 | 11 | 0 | 0 | 388 |
| SystemConfiguration | 467 | 314 | 313 | 1 | 0 | 153 |
| CoreMIDI | 382 | 239 | 72 | 167 | 0 | 143 |
| OpenDirectory | 199 | 107 | 46 | 61 | 0 | 92 |
| OpenDirectory/CFOpenDirectory | 465 | 387 | 387 | 0 | 0 | 78 |
| StoreKit | 204 | 193 | 163 | 30 | 0 | 11 |
| LinkPresentation | 31 | 31 | 28 | 3 | 0 | 0 |
| Accelerate | 3,462 | 4 | 4 | 0 | 0 | 3,458 |

The API coverage report counts 26,258 behavior-verified items after this run,
up from 10,689 before it. (The earlier count is the stricter one from the
report's provenance rules: a record counts only when its run matches the saved
SDK, test code and Finch image.) That increase includes both matching value
calls and Objective-C interface checks; the two kinds of checks are identified
separately in each result file. The root and nested Quartz rows can cover some
of the same APIs, so per-framework numbers do not add up to the report total.

`tools/host-tests.sh constants-test` passed: 10,645 values matched and none
differed. `python3 tools/test-api-coverage.py` passed all 24 tests. The full
36-framework difftest run had no crashes.

## Differences and limits

Many remaining differences come from missing Finch classes or selectors. The
`auto/objc/runtime-type` category marks these separately from value calls. For
example, Apple may report a method signature while Finch reports `missing-class`.
Those are API gaps, not mismatched method outputs.

- AVFoundation had 1,444 differences. Most were classes or selectors that Finch
does not expose. The remaining differences came from values on the generated
local media file. The tests did not play, capture, or export media.
- Quartz had 969 differences, mostly missing classes or selectors, plus
`CAEDRMetadata`, emitter-cell, and PDF action values. Quartz/PDFKit had 184
similar differences; Quartz/ImageKit had 59. QuartzCore had 120 differences,
including layer and animation values. The root Quartz inventory includes nested
framework APIs, so these rows overlap.
- PDFKit had 184 differences, including action values, class or selector gaps,
and C helpers. It had no crashes.
- AudioToolbox had 172 differences, mainly missing audio-unit classes or
selectors. Its in-memory audio file cases also found differences. No audio
hardware or playback was used.
- CoreMIDI had 167 differences, mostly missing device and service classes or
selectors. Its packet-list and UMP checks used local data only.
- OpenDirectory had 61 differences in class or selector checks. The nested
CFOpenDirectory run verified 387 items with no differences. Neither run
contacted a directory service or used credentials.
- StoreKit had 30 differences, mainly store-service classes or selectors. No
account, product request, or purchase flow was used. LinkPresentation had three
class or selector differences.
- CoreGraphics and CoreText differences include font, glyph, and layout values.
ImageIO had five differences in image-copy, type-list, and metadata calls.
CFNetwork had four differences in in-memory HTTP message calls.
- Contacts had 58 differences in class or selector checks and contact values.
CoreData had 237 differences in model and store-description values. Metal had
428 descriptor values or selector differences; the test did not use a GPU.
- CoreMedia had two time-range rounding differences. UniformTypeIdentifiers
had two tag or type values that did not match. SystemConfiguration had one type
identifier difference. Network had two interface differences.
- Security, CoreVideo, CoreServices, ColorSync, IOKit, and nested
CFOpenDirectory had no differences in the calls they exercised.
- CoreLocation's 204 APIs remain unexercised because loading Finch CoreLocation
beside Apple's private `_LocationEssentials` classes aborts the process.
Accelerate had four verified numeric checks; its remaining APIs need more Finch
exports or safe type-specific input builders.

## Earlier host comparison commands

The commands below are retained from earlier compatibility passes. This update
reran the constants test listed above.

```sh
tools/host-tests.sh security-test security-core-test security-roots-test coremedia-test corevideo-test coreservices-test uti-test cfurl-test cryptokit-test
```

The earlier CoreFoundation, Foundation, graphics, and AppKit host comparisons
passed: 15 passed, 0 failed,
0 known failures, and 0 not built. The script does not register `ctfonts-test`
or `font-replacements-test`, so those Finch-only checks were run directly. The
CoreText font output matched `ctfonts-expected.txt`; the replacement-font test
passed 308 checks with no failures.

Run the host comparisons with:

```sh
tools/host-tests.sh cf-test foundation-test foundation-more-test foundation-gaps-test archive-test xml-test cg-test cg-draw-test cgpdf-test ct-test imageio-test tiff-test appkit-draw-test appkit-core-test uifoundation-test
```

Run the two Finch-only font checks with:

```sh
DYLD_FRAMEWORK_PATH=build/root/System/Library/Frameworks:build/root/System/Library/PrivateFrameworks:build/root/System/Library/Frameworks/Quartz.framework/Frameworks:build/root/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks:build/root/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks:build/root/System/Library/Frameworks/Carbon.framework/Versions/A/Frameworks \
DYLD_LIBRARY_PATH=build/root/usr/lib/swift \
FINCH_FONT_DIRS=build/root/System/Library/Fonts \
    build/userland/finch-ctfonts-test | diff -u userland/tests/ctfonts-expected.txt -

DYLD_FRAMEWORK_PATH=build/root/System/Library/Frameworks:build/root/System/Library/PrivateFrameworks \
FINCH_FONT_DIRS=build/root/System/Library/Fonts \
    build/userland/finch-font-replacements-test
```

For the broader AppKit host suite, run all `appkit-*` comparisons plus the
related window, text, pasteboard, image, and UIFoundation checks. The AppKit
extension's full comparison set is:

```sh
tools/host-tests.sh appkit-small3-test appkit-swift2-test appkit-typedstream-test appkit-compat-test appkit-values-test appkit-core-test appkit-gaps-test appkit-draw-test appkit-containers-test appkit-controls-test appkit-menu-test appkit-text-test appkit-document-test appkit-layout-test appkit-bindings-test appkit-panels-test appkit-tables-test appkit-containers2-test appkit-controls2-test nib-test textkit2-test pasteboard-test imagekit-test uifoundation-test
```

## Machine-dependent output

`tools/difftest/masks.json` holds narrow regular-expression rules for results
that change with the clock, loaded process frameworks, locale data, time-zone
data, random UUIDs, pointer addresses, or optional direct string storage. Each
rule names its API and gives a reason. The runner applies masks before comparing
the two output lines. Do not mask a stable behavior difference.

## Add test coverage

The typed generator in `tools/difftest/typed.py` handles signatures that fit
the shared type pools. Add a focused builder there when an API needs a
particular related input, and add a specific test in `tools/difftest/generate.py`
when it needs more than the shared builder can express. Keep the input within
the API's documented range. Add side-effect rules only for calls that really
reach outside the test process. Add a mask only when the result varies with
the host or its installed data.

After changing Finch behavior, run the focused comparison and the relevant
host tests. The focused host comparison set used for these results is:

```sh
tools/host-tests.sh cf-test foundation-test foundation-more-test foundation-gaps-test archive-test xml-test cg-test cg-draw-test cgpdf-test ct-test imageio-test tiff-test appkit-draw-test appkit-core-test uifoundation-test
```

For the two Finch-only font checks, use the commands in the Results section.
For broader AppKit coverage, run the full AppKit set shown there.
