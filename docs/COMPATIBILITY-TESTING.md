# Generated compatibility tests

These tests compare Finch's CoreFoundation, Foundation, CoreGraphics,
CoreText, ImageIO, and AppKit frameworks with Apple's frameworks on the same
Mac. They use the current macOS SDK as the API list and the source of C and
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
```

The runner builds one generated program for each framework and starts a fresh
process for each API item. It runs Apple first and Finch second, with Finch's
framework paths set in that child process. It does not use a wrapper that can
strip `DYLD_*` variables. The runner compares up to eight typed cases for each
item, uses parallel workers, and reuses a generated binary when its source and
SDK have not changed.

Results go to `build/compat-results/<Framework>.json`. Each result has an
`items` map keyed by the SDK name for the API. A difference records the first
output row that does not match. Exceptions include their names and reasons.
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
It does not guess at invalid ranges or pass `NULL` where the declaration does
not allow it.

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

## Results

On macOS SDK 26.4, the merged generator reported these results. The SDK item
counts come from parsed declarations; the exercised count is the sum of
verified, different, and crashed calls.

| Framework | SDK items | Exercised | Verified | Different | Crashes | Not exercised |
|---|---:|---:|---:|---:|---:|---:|
| CoreFoundation | 1,227 | 792 | 790 | 2 | 0 | 435 |
| Foundation | 8,128 | 1,984 | 1,888 | 96 | 0 | 6,144 |
| CoreGraphics | 862 | 514 | 498 | 16 | 0 | 348 |
| CoreText | 328 | 229 | 194 | 35 | 0 | 99 |
| ImageIO | 808 | 785 | 781 | 4 | 0 | 23 |
| AppKit | 9,955 | 769 | 605 | 164 | 0 | 9,186 |

CoreFoundation's two differences are its hyphenation calls; Finch does not
ship hyphenation dictionaries. Foundation's differences include XML, key-value
coding, dates and calendars, URLs, number formatting, and string edge cases.
The merged Foundation fixes bring decimal division, byte-based data creation,
invalid substring indexes, nil number comparisons, and spacing around a DTD
into agreement with Apple.

CoreGraphics' remaining differences are mostly font names and measurements
because the Mac and Finch use different font files; four high dynamic-range
color-space constants also differ. CoreText's remaining differences are mostly
font names, traits, glyph metrics, and line layout. ImageIO's remaining
differences are codec type lists, metadata copying, and
`CGImageDestinationCopyImageSource`. These three frameworks had no crashes.

AppKit's run exercised 7.72% of its SDK inventory, and 78.67% of those calls
matched. Its differences include fonts and metrics, cursor images, event values,
attributed strings, font manager queries, font descriptors, images, bitmap data,
and layout spacing. It had no crashes. Most of the remaining inventory has no
safe typed input or is outside the headless scope; the JSON file lists skip
reasons and each API's first mismatch.

The requested `tools/host-tests.sh` comparisons passed: 15 passed, 0 failed,
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
