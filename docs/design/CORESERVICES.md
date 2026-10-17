# CoreServices

Finch builds CoreServices with Apple's framework paths and public C and
Objective-C names. `userland/CoreServices/build.sh` builds its child frameworks
and umbrella. Build Foundation and UniformTypeIdentifiers first.

The code is Finch's own, under MIT OR Apache-2.0. It uses Apple's public SDK
headers and tests the answers against macOS. It does not copy Apple's closed
frameworks into the image.

## What works

- LaunchServices registers app bundles and reads their document types and URL
  schemes. It finds apps and handlers and launches local apps. Its type functions
  use Finch's UniformTypeIdentifiers database.
- Apple event descriptors hold values, lists and records. They support copying,
  coercion, flattening and local event handlers. Foundation owns
  `NSAppleEventDescriptor`, `NSAppleEventManager` and `NSUserActivity`, as Apple
  does. LaunchServices re-exports the activity symbols that Apple exposes there.
- CarbonCore covers the filesystem, resource and type helpers in the comparison
  test. Basic metadata comes from local files. The other child frameworks supply
  the tested file-event, shared-list and operating-system helpers.

## Current limits

Apple events do not travel between processes yet. User activities keep local
state; they do not reach Handoff, Spotlight or Siri. Metadata queries are basic
filesystem queries. DictionaryServices and SearchKit are not implemented.
Some Apple event suspension methods and private CoreServices helpers remain.

The private `LSApplicationWorkspace.openApplicationWithBundleID:` call differs
from Apple's for the test fixture. Apple's returns NO; Finch's local launcher
opens it and returns YES. Run the test with `--private-launch` to exercise this
separately. The public launch calls remain in the normal comparison.

## Checks on 2026-10-09

`finch-coreservices-test` prints 1,366 matching lines after its framework-path
line when run against Apple's and Finch's frameworks. The scratch app needs a
fresh identifier, extension and URL scheme for each comparison. On macOS it must
live under the build folder; LaunchServices ignores this fixture under `/tmp`.
The test needs access to the host's LaunchServices service.

Together with the asset work, the new exports resolve 530 previously missing
imports across 45 bundled apps. There are still 86 missing imports in those
areas. This checks the names apps link to; it does not prove those apps work.

## App imports on 2026-10-15

The rebuilt CoreServices images leave 19 apps missing 107 strong imports across
78 names. The largest groups are private LaunchServices and code-signing helpers,
text-encoding conversion, Metadata queries, and DictionaryServices. The saved
before-scan report did not include direct `CoreServices.framework` imports, so it
does not give a comparable starting count for this framework.

DictionaryServices and Metadata need Finch's own dictionaries, search index and
query service. The code-signing and LaunchServices helpers need private system
services Finch does not have. The five LaunchServices open-option key strings now
match Apple's in the focused comparison, but that does not supply those services.

## CarbonCore work on 2026-10-17

The CoreServices coverage scan started at 2,721 of 3,740 public API items. It
now finds 3,222, a gain of 501. The 157 items already marked behavior-verified
remain verified. The new CarbonCore code adds file reference, fork, catalog,
volume, range-lock, parameter-block, folder, file-security and HFS string calls.
It also adds collection saving, date and time conversion, Pascal string helpers,
Unicode conversion, character properties, thread and timer helpers, and
pthread-backed Multiprocessing calls. The OSServices additions read local POSIX
users and groups through `CSIdentity`; they report the authority error for
changes because Finch has no writable identity database. The old password-set
and password-check exports stay absent because there is no password service to
handle them.

The host comparison suite covers the new file, folder, collection, text,
time, thread, locale, Multiprocessing, timer and identity behavior against
Apple's frameworks. `FSDetermineIfRefIsEnclosedByFolder` returns Apple's current
`errFSBadFSRef` result on this macOS version. The retired Power Manager calls
return the same zero values as Apple's current implementation. These checks run
on the host; they do not prove that every call works inside the Finch guest.
