# CoreData

Finch builds its own `CoreData.framework` at Apple's install path. It follows the
SDK's Objective-C API and adds the Swift calls apps import from CoreData. The
framework reads compiled `.mom` and `.momd` models by unarchiving the model
objects Apple writes into them. No Apple framework binary or model from an app
ships with Finch.

The first store implementation covers SQLite and in-memory stores. SQLite uses
Finch's pinned, public-domain SQLite 3.54.0 build. A comparison test loads a
compiled two-entity model, saves records and follows a to-one relationship. It
also checks that Apple's store opens in Finch and Finch's store opens in Apple.
The test compares the fetched rows and count, ignoring only the first line that
shows which CoreData image loaded.

Contexts support inserting objects, saving, rolling back, child-context saves,
queued work, notifications, and merging another context's save. Fetches apply
Foundation predicates and sort descriptors, then honor offsets and limits.
Stored attributes include strings, numbers, dates, decimals, and binary data.
To-one relationship values can be saved and loaded from SQLite. The in-memory
store uses a private SQLite memory database.

The store format covers the basic `Z_METADATA`, `Z_PRIMARYKEY`, and entity
tables used by the comparison fixture. The test proves that simple model shape
works in both directions; it does not prove every CoreData option or every
store schema used by every app.

Several parts remain unsupported. Changed-model migrations, migration rules
that alter relationships, many-to-many relationship storage, persistent
history, iCloud stores, and Core Spotlight indexing return an error or report
that they are unavailable. Binary and XML stores are also unavailable. Apps
that require those features are not ready just because the CoreData framework
loads.

Build the dependency and framework with:

```sh
tools/build-system.sh libsqlite3 CoreData
```

Build and run the host comparison with:

```sh
make -C userland/tests ../../build/userland/finch-coredata-test
tools/host-tests.sh coredata-test
```
