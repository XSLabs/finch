# CloudKit

Finch CloudKit supplies the local data types that apps use to describe CloudKit data.
It builds against the macOS SDK headers. The build script reads those headers to
generate property storage, but does not copy any Apple header or library into Finch.

## What works

- Records hold the supported CloudKit value types, preserve field order, track changed
  fields, support keyed subscripting and copying, and encode their system fields.
- Record IDs, zones, references, assets, queries and location sort descriptors have
  constructors, value storage, copying and secure coding where the SDK supports it.
- Queries require a record type and predicate. Block predicates raise the same kind of
  exception as Apple's implementation.
- Shares, participants, subscriptions and notification info keep their public model
  values. Remote notification dictionaries produce query or zone notification objects.
- Operations keep their configuration and group settings. Queued database operations
  finish with an unavailable-service error instead of claiming that work succeeded.
- Sync state saves pending record and zone changes, the untracked-change flag and the
  listed zones that still need fetching. The Swift overlay restores the SDK's refined
  sync-engine names and adds secure state archive helpers.

The focused host comparison covers 27 output lines for records and archives, query
validation, subscriptions, sharing defaults, operation defaults and query notifications.
It matches Apple's output and checks 62 API items, including the sync configuration's
weak delegate and the operation group's default configuration. The same comparison also
checks the operation's default configuration and its reset behavior. A separate Finch-only
test checks that account status reports no account and a private record fetch returns
`CKErrorDomain` code 9. It also saves a pending record change, archives the sync state,
and restores that change.

## Limits

Finch has no iCloud account or CloudKit server. Account status reports `NoAccount`.
Remote operations return errors; public database reads report network unavailable, and
other database or container requests report `CKErrorNotAuthenticated`. The exact
`userInfo` Apple returns for an unentitled test app could not be checked here, so Finch's
error description is not claimed to match Apple's byte for byte.

The sync engine stores and restores the pending changes listed above. It does not contact
a server, schedule automatic sync, or persist server change tokens. Query cursors and
server change tokens are opaque SDK objects and are left without invented values.

The API coverage tool finds 509 of 1,208 public CloudKit items present; 699 remain
missing. The app scan no longer finds apps blocked by a missing CloudKit framework image,
but six app binaries still use CloudKit symbols Finch has not added.
