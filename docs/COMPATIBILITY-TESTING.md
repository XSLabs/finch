# Generated compatibility tests

The generated tests compare Finch's CoreFoundation and Foundation with the
matching Apple frameworks on the same Mac. The current SDK headers supply the
API inventory. A small hand-written catalogue chooses safe calls and inputs
for APIs whose answers depend on their arguments. The tests use fixed edge
cases and a seeded set of strings, so a run uses the same inputs each time.

## Run the comparisons

Build Finch's host frameworks first. Then run both frameworks:

```sh
python3 tools/difftest/run.py
```

To run one framework, name it:

```sh
python3 tools/difftest/run.py CoreFoundation
python3 tools/difftest/run.py Foundation
```

The runner generates Objective-C source, builds it with the macOS SDK, and
starts the binary once with Apple's framework and once with Finch's. Each API
item runs in its own process. This keeps a crash attached to the item that
caused it. The runner sets Finch's `DYLD_FRAMEWORK_PATH` in that child process;
it does not use a wrapper that can strip those variables.

Results go to `build/compat-results/CoreFoundation.json` and
`build/compat-results/Foundation.json`. Each result has an `items` map keyed by
the API name used by the test catalogue. An item records its status:

- `verified`: both runs completed and their output matched.
- `differs`: both runs completed, but their output did not match.
- `crashes`: a run failed or timed out.
- `not-exercised`: the SDK lists the API, but this generator has no test for it.

For a difference, `first_difference` shows the first output row that did not
match, including its example name and Apple's and Finch's values. The summary
has two different percentages. `verified_percent` is the share of exercised
items that matched. `coverage_percent` is the share of all inventoried SDK
items that have a test. A high verified percentage does not mean that most of
the SDK has been exercised.

## Add or extend tests

Add a catalogue entry in `tools/difftest/generate.py` for each API item. Use the
name spelling emitted by the SDK inventory: C functions use `Name`, Objective-C
methods use `Class -selector` or `Class +selector`, and Swift members use
`Module.Type.member`. Give the item a short category such as `strings/search`.
Add a typed test function to that framework's source template and register it
in the template's dispatch table. Use stable output rows and catch Objective-C
exceptions in the dispatch loop. Prefer fixed locale and time-zone settings
when formatting dates or numbers.

The current inventory combines public C declarations, Objective-C methods
from SDK headers, and public members found in the framework's macOS
`.swiftinterface` when one is present. The C and Objective-C scanners are the
same tools used by the API audits. When adding a framework, add its source
template and catalogue in `generate.py`, include it in both scripts' framework
choices, and check that the SDK inventory contains each catalogue name. Keep
the generated program's link framework and Finch framework search paths valid
for that framework.

## Machine-dependent output

`tools/difftest/masks.json` holds narrow regular-expression rules for output
that is truly machine-dependent. A rule must name an API item and may also
name a framework. Matching text is replaced before comparing the two outputs.
The optional replacement defaults to `<MACHINE>`, and `reason` explains why
the value varies. Keep this file as `[]` when there is no known machine-only
difference; do not mask a real behavior mismatch.

The initial mask list is empty. The cases in this catalogue use fixed dates,
locales and time zones, and currently compare without masks.
