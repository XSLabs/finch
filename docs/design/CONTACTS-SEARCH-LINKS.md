# Contacts, search and link cards

As of 2026-10-15, Finch builds its own `ContactsUI`, `CoreSpotlight` and
`LinkPresentation` frameworks. Each uses Finch's existing Contacts, AppKit and
Foundation code. The frameworks use Apple's install names and directory layout,
but include no Apple binaries or copied Apple source.

## ContactsUI

`CNContactPicker` reads contacts from Finch's local Contacts store. It shows them
in an AppKit popover, sorted by name. With no displayed keys, choosing a row
returns a contact. With displayed keys, each matching phone number, email address
or other requested value appears as a separate choice and returns a contact
property. The picker calls its delegate when a choice is made or the popover
closes.

`CNContactViewController` displays the contact's name, organization, phone
numbers and email addresses in an AppKit view. Its key descriptor requests the
name, phone and email data it needs. Finch does not provide contact editing,
actions, or Apple's system contacts service.

## CoreSpotlight

`CSSearchableIndex` keeps each named index in a separate file under the user's
Application Support directory. It locks changes across processes and replaces
the saved file atomically. Apps can add and delete items, delete a domain, clear
an index, and read or change its client state without a Spotlight service.
Named index files include the app's bundle identifier, so two apps can use the
same index name without sharing a file.

`CSSearchQuery` searches the saved items on a background queue. It supports
plain all-terms searches and common quoted comparisons joined with `&&` and
`||`, including equality, `CONTAINS`, `BEGINSWITH`, `ENDSWITH` and basic
`LIKE` matching. A query context can filter results and limit returned
attributes. This is a local index; it does not scan the disk or implement all of
Spotlight's query language, ranking or service behavior. `NSUserActivity` can
carry a searchable attribute set. The Swift overlay also offers async sequences
for query results, user-query responses and suggestions; these use the same local
query engine and report its errors.

Finch does not provide `CSImportExtension` on macOS. Apple's documentation says
file import extensions do not provide functionality on macOS, so Finch returns
an explicit unsupported error instead of claiming to import files.

## LinkPresentation

`LPMetadataProvider` fetches HTTP and HTTPS pages with Finch Foundation's
`NSURLSession`. It reads the page title and common Open Graph, Twitter Card and
HTML metadata. When subresource fetching is enabled, icon and image providers
load their data only when requested. The provider reports network, timeout,
HTTP status and cancellation errors.

`LPLinkMetadata` supports copying and secure coding. `LPLinkView` shows the
page title, host and available image in an AppKit card. The page parser reads
HTML tags directly. It does not run page scripts, render pages, or use Apple's
private metadata service.

## Checks

`tools/api-audit.sh --summary ContactsUI CoreSpotlight LinkPresentation` checks
public classes and methods. The comparison test in
`userland/tests/contacts-search-links-test.m` runs against Apple's frameworks and
Finch's frameworks. The Swift comparison test exercises the async search sequence.
A Finch-only test fetches a local page to check real URL
loading without relying on outside sites.

The app sweep still finds private imports used by some built-in apps: ContactsUI
avatar and contact-card classes, LinkPresentation image and snapshot classes, and
CoreSpotlight's `_CSSuggestionToken`. Finch leaves these out until it can provide
their real behavior.

The app sweep reads apps from the folders you pass it. A scanned app that imports
an Apple framework through `/System/iOSSupport` still appears as missing that
separate path; Finch's macOS framework does not satisfy that import.
