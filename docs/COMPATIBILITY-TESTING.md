# Generated compatibility tests

These tests compare Finch's CoreFoundation and Foundation with Apple's
frameworks on the same Mac. They use the current macOS SDK as the API list and
the source of C and Objective-C method signatures.

## Run the comparisons

Build Finch's host frameworks first. Then run both frameworks or choose one:

```sh
python3 tools/difftest/run.py
python3 tools/difftest/run.py CoreFoundation
python3 tools/difftest/run.py Foundation
FINCH_THEME=Classic python3 tools/difftest/run.py AppKit --jobs 8
```

The runner builds one generated program for each framework and starts a fresh
process for each API item. It runs Apple first and Finch second, with Finch's
framework paths set in that child process. It does not use a wrapper that can
strip `DYLD_*` variables. The runner compares up to eight typed cases for each
item, uses parallel workers, and reuses a generated binary when its source and
SDK have not changed.

Results go to `build/compat-results/CoreFoundation.json` and
`build/compat-results/Foundation.json`. The AppKit run writes
`build/compat-results/AppKit.json`. Each result has an `items` map keyed by the
SDK name for the API. A difference records the first output row that does not
match. Exceptions include their names and reasons. The program normalizes
object descriptions, pointer values, addresses, and unordered collections
before comparing results.

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
numbers, data, collections, URLs, locales, time zones, calendars, and character
sets. Strings include ASCII, accents, combining marks, emoji, right-to-left
text, and a long value. A fixed seed keeps the generated cases repeatable.

The generator uses a small hand-written set of safe builders where a type alone
does not provide enough context, such as a numeric buffer for `CFNumberCreate`
or a valid array for a collection call. It leaves an API unexercised when it
has no safe typed input, receiver, or callable signature. It does not guess at
invalid ranges or pass `NULL` where the declaration does not allow it.

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

The original hand-picked list exercised 24 of 1,230 CoreFoundation items and
32 of 8,130 Foundation items. The new C inventories come from parsed AST
declarations instead of macro names. Foundation also retains Swift interface
entries, which are reported as not exercised when they have no C or
Objective-C selector. On macOS SDK 26.4, the generated run reported:

| Framework | SDK items | Exercised | Verified | Different | Crashes | Not exercised |
|---|---:|---:|---:|---:|---:|---:|
| CoreFoundation | 1,227 | 792 | 790 | 2 | 0 | 435 |
| Foundation | 8,128 | 1,978 | 1,843 | 135 | 0 | 6,150 |
| AppKit | 9,955 | 765 | 605 | 160 | 0 | 9,190 |

The verified share of exercised items is 99.75% for CoreFoundation and 93.17%
for Foundation. Foundation's inventory also includes Swift interface entries
that have no C or Objective-C selector, so they remain not exercised.

The two remaining CoreFoundation differences are the hyphenation APIs. Finch
does not ship hyphenation dictionaries, so it cannot report Apple's available
languages or word breaks. Foundation's remaining differences are concentrated
in XML, decimal arithmetic, key-value coding, expressions, and string/data
edge cases. The JSON results list each API's first differing case and the skip
counts by category.

The AppKit run exercised 7.68% of its SDK inventory; 79.08% of those calls
matched. Its largest groups of differences are fonts (30), cursor images (24),
event values (18), attributed strings (14), font manager queries (13), font
descriptors (10), and images (10). These include installed font names and
metrics, cursor artwork, input-state results, platform type lists, layout
spacing, bitmap data and metadata, and path behavior. The run had no crashes.
Most of the remaining inventory has no safe typed input or is outside this
headless scope; the JSON file lists the skip reasons and the first mismatch for
each API.

An app sweep found 26 of 101 installed apps had all required framework imports.
It found 77 Foundation symbol gaps across 17 apps and three CoreFoundation
gaps: `_CFUserNotificationCreate`, `_CFUserNotificationDisplayAlert`, and
`__CFURLAttachSecurityScopeToFileURL`. Those CoreFoundation calls require real
cross-process notification or security-scope behavior; they remain missing
instead of being filled with stand-ins.

The requested AppKit host-test run completed with 23 passed, 0 failed, 1 known
failure, and 0 tests not built. All AppKit comparison tests passed. The known
failure is `nib-test`: Apple restores a nib window to an attached 1x screen,
while Finch has no screen list to choose from.

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
host tests. For the CoreFoundation and Foundation work covered here, the host
test command is:

```sh
tools/host-tests.sh cf-test foundation-test foundation-more-test foundation-gaps-test archive-test intl-test misc-test data-test collections-test kvc-test streams-test predicate-test urlsession-test cfurl-test markdown-test
```

For AppKit changes, pass all `appkit-*` comparison tests plus the related
window, text, pasteboard, image, and UIFoundation checks. The set used for the
AppKit results above is:

```sh
tools/host-tests.sh appkit-small3-test appkit-swift2-test appkit-typedstream-test appkit-compat-test appkit-values-test appkit-core-test appkit-gaps-test appkit-draw-test appkit-containers-test appkit-controls-test appkit-menu-test appkit-text-test appkit-document-test appkit-layout-test appkit-bindings-test appkit-panels-test appkit-tables-test appkit-containers2-test appkit-controls2-test nib-test textkit2-test pasteboard-test imagekit-test uifoundation-test
```
