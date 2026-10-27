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
Stored attributes include strings, numbers, dates, decimals, binary data,
UUIDs, URIs, transformable values (through their value transformer) and
composite attributes (kept as property lists). Derived attributes take their
values when an object is saved. Faults load one row at a time. To-one
relationships are columns; to-many relationships load through the inverse
column, and setting either side of a relationship keeps the inverse in step.
The in-memory store uses a private SQLite memory database.

Custom stores work as on macOS. `registerStoreClass:forStoreType:` records the
class; the coordinator creates it, reads its metadata (typed by the store
class and stamped with the model's version hashes) and, for an atomic store,
loads its cache nodes. An `NSIncrementalStore` answers fetches itself, fills
faults through `newValuesForObjectWithID:` and `newValueForRelationship:`, and
receives `obtainPermanentIDsForObjects:` then an `NSSaveChangesRequest` on save.
An `NSAtomicStore` is fetched from its cache nodes; saving makes nodes for
inserted objects, updates the others, removes deleted ones and calls `save:`.
Object IDs of custom stores carry the store's reference object
(`x-coredata://<store UUID>/<Entity>/p<reference>`).

Migration covers the common cases. Opening a SQLite store whose model gained
entities, attributes or to-one relationships, or renamed them through renaming
identifiers, brings the tables up to date in place when the store options (or
the store description's defaults) allow automatic migration and inference;
without them the open fails with 134100 as on macOS. Finch compares the
store's tables with the model rather than looking for the old model, so stores
written by macOS migrate too. `NSMigrationManager` runs mapping models through
entity migration policies (create instances, then relationships, then
validation and save), and inferred mapping models match Apple's
(`IEM_Copy_`, `IEM_Transform_`, `IEM_Add_`, `IEM_Remove_`).

`NSBatchInsertRequest` (objects, dictionary and managed-object handlers),
`NSFetchRequestExpression`, and `NSPersistentCloudKitContainer` are present.
The CloudKit container keeps its stores local, as Core Data does without an
iCloud account: record lookups return nothing and event requests return no
events.

The store format covers the `Z_METADATA`, `Z_PRIMARYKEY`, and entity tables.
Comparison tests (`coredata-test`, `coredata-stores-test`,
`coredata-classes-test`, `coredata-migration-test`, `coredata-hash-test`) prove these paths match
macOS; they do not prove every CoreData option or every store schema used by
every app.

Version hashes are Core Data's own: SHA-256 digests over the same fields in
the same order (a property's name, flags and modifier; an attribute's type and
storage flags; a relationship's destination, inverse and counts; an entity's
name, parent, sorted properties, modifier and uniqueness constraints; derived
attributes by their expressions and composites by their elements), so model
checksums and store metadata agree with macOS (`coredata-hash-test`). Stores
Finch writes open on macOS without migration, `mergedModelFromBundles:forStoreMetadata:`
finds older model versions inside `.momd` bundles, and
`mappingModelFromBundles:` finds Xcode-compiled `.cdm` mapping models by their
hashes.

Several parts remain unsupported. Migrations that change an attribute's type,
many-to-many relationship storage, persistent history, CloudKit mirroring,
and Core Spotlight indexing return an error or report that they are
unavailable. Binary and XML stores are also unavailable.

Build the dependency and framework with:

```sh
tools/build-system.sh libsqlite3 CoreData
```

Build and run the host comparison with:

```sh
make -C userland/tests ../../build/userland/finch-coredata-test
tools/host-tests.sh coredata-test
```
