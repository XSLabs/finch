# AppIntents

Design note dated 2026-10-15. The app sweep and comparison tests were run on 2026-10-16.

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
distinct missing symbols. The before list is the first sweep of the partial worktree; the
after list is the sweep on 2026-10-16.

| Framework | Before: apps / unique / pairs | After: apps / unique / pairs |
|---|---:|---:|
| AppIntents | 20 / 697 / 1,316 | 15 / 514 / 628 |
| _AppIntents_AppKit | 0 / 0 / 0 | 0 / 0 / 0 |
| _AppIntents_SwiftUI | 0 / 0 / 0 | 0 / 0 / 0 |

The sweep now marks Calculator ready. No app is blocked by AppIntents alone; every affected
app also needs symbols from other Finch frameworks. The full sweep marks 25 of 101 apps
ready across all their imports.

Remaining AppIntents pairs by app:

| App | Missing pairs |
|---|---:|
| Mail | 187 |
| Notes | 102 |
| Books | 98 |
| Freeform | 65 |
| Podcasts | 63 |
| VoiceMemos | 60 |
| Weather | 16 |
| Shortcuts | 14 |
| Journal | 9 |
| Preview | 7 |
| CotEditor | 2 |
| Reminders | 2 |
| Contacts | 1 |
| Print Center | 1 |
| Tips | 1 |

The complete list of remaining symbols and the apps that import them is in
[APPINTENTS-MISSING-2026-10-16.tsv](APPINTENTS-MISSING-2026-10-16.tsv). The table groups an
identical symbol once and names every affected app.

The most common remaining groups need system features Finch does not have: donation manager
symbols in Books, Freeform, Podcasts and Reminders, plus confirmation requests in Mail, Notes
and VoiceMemos. Search and create intent protocol imports, and setting-change intent imports,
also remain. These protocols are absent from the public AppIntents SDK interface, so Finch
does not guess their requirements. Mail-specific message and send-mail protocols remain too.
The TSV names each missing symbol and every app that imports it.

## Build and checks

Built the Finch SwiftUI framework, AppIntents and both private AppIntents bridges. The three
comparison tests passed against Apple and Finch:

- `appintents-test` (45 output lines)
- `appintents-local-test` (15 output lines)
- `appintents-swiftui-test` (1 output line)

The SwiftUI bridge build still prints an actor-isolation warning at its intent-backed
`Toggle` initializer and a linker warning for a missing iOS support private-framework search
path. Both bridge builds complete.
