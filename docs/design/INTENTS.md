# Intents

Finch's Intents framework provides the local data types that apps use to describe
requests, people, files, shortcuts and responses. It is built in manual retain/release
Objective-C. The build reads the macOS SDK declarations and generates Finch's own class
and method glue. It does not copy SDK headers, module maps or Apple code into Finch.

## Values and coding

The generated classes keep their declared properties in Objective-C associated storage.
Typed initializer wrappers save the arguments as those properties, and resolution result
factories set the matching result code and value. The handwritten parts cover behavior
that depends on the value type, including person display names, object descriptions,
intent images, shortcut activities and copy, equality and secure coding. `INFile` keeps
its data and file details as a value.

The host test compares Apple's and Finch's values, descriptions, copies and secure
archives. It covers `INPersonHandle`, `INPerson`, `INObject`, `INSpeakableString`,
`INAirline`, `INFile`, a call intent and response, a resolution result, shortcuts,
relevant shortcuts and interactions. The test also checks an Apple Pay payment method,
an audio-message attachment, the Focus status value and voice-shortcut lookup.

## Interaction donations

Finch stores donated interactions in the current user's
`~/Library/Finch/Intents/interactions.archive` file. It uses secure keyed archives and
writes updates atomically. Donating an interaction with an existing identifier replaces
that entry. The delete methods remove entries by identifier, group or all at once. A
Finch-only test saves one interaction, securely reads it back, clears the store and reads
the empty archive. The test uses an isolated home directory under `build/`.

## Services Finch does not have

Finch has no Siri service. Siri authorization stays `NotDetermined`, the Siri language
code is empty, and authorization requests complete with `NotDetermined`. Focus status
authorization also stays `NotDetermined`, and the reported focus state is false. Voice
shortcut lookups return no shortcuts and no error, matching Apple's result on this host.
The framework does not claim to run Siri requests or provide App Store or iCloud services.

## Coverage and limits

For the macOS 26.4 SDK, `tools/api-coverage.py --missing Intents` reports 545 of 1,065
items present (51.2%). It counts 519 remaining Objective-C class exports that have no
matching public declaration in the SDK headers, plus the `INDateComponentsRange`
`EKRecurrenceRule` method. Finch does not invent empty classes for those export names.
The requested 600-item target is therefore not met by this public-header implementation.

The app sweep finds that 26 of 101 apps have every imported symbol, and the Intents image
is now present. Clock imports
`INCreateTimerIntent`; Calendar imports `INShowPersonInteractionsIntent`; and Home
imports `INConfigureHomeIntent` and `INShowHomeIntent`. Those four classes do not have
declarations in the macOS SDK headers, so the three apps still lack those symbols.

The host comparison passes for the cases above. This is host testing only; Finch has not
been booted to verify this framework in a guest image.
