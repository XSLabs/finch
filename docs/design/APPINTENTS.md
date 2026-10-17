# AppIntents

Design note updated 2026-10-17. The app sweep and comparison tests were run on 2026-10-17.

AppIntents lets an app describe actions, values and records that another part of the system
can use. Finch's AppIntents framework now lets an app declare those types, read their
metadata, and run an intent inside the app. It does not claim that Shortcuts, Siri, Spotlight
or system URL routing is present.

## What Finch provides

- `AppIntents.framework` defines app intents, entities, enums, parameters, results,
  summaries, entity queries, shortcut descriptions and Assistant phrases. The comparison
  test checks their values and runs local intents.
- Entity display values, identifiers, query results and parameter defaults work in process.
  A query with no `suggestedEntities()` implementation returns no suggestions.
- URL parameters keep their title, description and default value, including the URL-specific
  initializers used by apps.
- URL representations interpolate entity properties and intent parameters. Finch encodes
  each value as one URL component. String, integer and URL values can supply a URL parameter.
- `_AppIntents_AppKit` stores entity identifiers, annotations and view callbacks on the
  owning `NSView`. It can make a display image from a system symbol.
- `_AppIntents_SwiftUI` attaches entity metadata to a view's environment and connects view
  actions to an app's `perform()` method.

When an operation needs a system service Finch does not have, Finch records the unavailable
request. A URL intent cannot open another app here. Shortcut registration and donation,
Siri and Spotlight indexing are not reported as successful.

## App sweep

The table counts app-symbol pairs because one missing symbol can be imported by several
apps. “Apps” counts apps with at least one missing import from that framework. “Unique” counts
distinct missing symbols. The before list uses the original AppIntents image with the import
checker fixed to match framework names exactly. The earlier checker matched some short
framework names by prefix, which hid or invented missing imports. The supplied first report
said 26 ready apps; the corrected baseline and current sweep each report 19 of 101.

| Framework | Before: apps / unique / pairs | After: apps / unique / pairs |
|---|---:|---:|
| AppIntents | 15 / 514 / 628 | 15 / 267 / 315 |
| _AppIntents_AppKit | 0 / 0 / 0 | 0 / 0 / 0 |
| _AppIntents_SwiftUI | 0 / 0 / 0 | 0 / 0 / 0 |

No app is blocked by AppIntents alone; every affected app also needs symbols from other Finch
frameworks. This change removed 313 AppIntents app-symbol pairs. The full sweep marks 19 of
101 apps ready across all their imports.

Remaining AppIntents pairs by app:

| App | Missing pairs |
|---|---:|
| Books | 64 |
| Podcasts | 60 |
| Freeform | 58 |
| Mail | 47 |
| Notes | 29 |
| VoiceMemos | 23 |
| Weather | 13 |
| Preview | 7 |
| Journal | 5 |
| CotEditor | 2 |
| Reminders | 2 |
| Shortcuts | 2 |
| Contacts | 1 |
| Print Center | 1 |
| Tips | 1 |

The complete list of remaining symbols and the apps that import them is in
[APPINTENTS-MISSING-2026-10-17.tsv](APPINTENTS-MISSING-2026-10-17.tsv). The table groups an
identical symbol once and names every affected app.

The remaining imports include shortcut donation and confirmation flows, private entity-update
protocols, and Mail-specific intent types. Donation and confirmation need system services
Finch does not provide. Finch leaves those operations unavailable instead of reporting a
successful system action.

## Build and checks

Built AppIntents and ran its comparison tests against Apple and Finch:

- `appintents-test` (48 output lines)
- `appintents-local-test` (17 output lines)

The 2026-10-17 run passed both tests. `constants-test` also passed with 10,645 values checked
and no differences.

The SwiftUI bridge build still prints an actor-isolation warning at its intent-backed
`Toggle` initializer and a linker warning for a missing iOS support private-framework search
path. Both bridge builds complete.
