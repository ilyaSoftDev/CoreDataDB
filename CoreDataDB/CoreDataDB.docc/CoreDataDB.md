# ``CoreDataDB``

A `Sendable`, async/await Core Data layer that trades in value types instead of managed objects.

## Overview

CoreDataDB wraps Core Data behind a small facade. Every operation is `async throws` and exchanges
value-type DTOs rather than managed objects, so nothing thread-confined escapes the context it was
fetched on, and a client can be built from any isolation domain.

```swift
let client = try await DatabaseClient(
    configuration: DatabaseConfiguration(
        model: .named("Notes", bundle: .main),
        store: .sqlite(storeURL),
        registeredModels: [Note.self]
    )
)

try await client.save(Note(id: id, title: "Draft"))

let unread = try await client.fetch(Note.self, matching: isUnread, sortedBy: [byDate])
```

### The framework ships no model

The host application supplies the `NSManagedObjectModel`, through
``DatabaseConfiguration/ModelSource`` (D1). Nothing about the schema can be assumed at compile
time, so the types listed in ``DatabaseConfiguration/registeredModels`` are checked against it as
the store opens: a missing entity, an identifier naming no attribute, or a missing uniqueness
constraint is reported against the model rather than surfacing later as a crash or a silent
duplicate row. Those checks throw in debug builds and log in release, so a misconfiguration fails
loudly in development without refusing to start a shipped app.

The uniqueness constraint in particular is load-bearing. Core Data spells Realm's
`UpdatePolicy.modified` as a unique constraint plus `NSMergeByPropertyObjectTrumpMergePolicy`
(D5) — without the constraint, ``DatabaseActions/save(_:in:)-(T,_)`` inserts a duplicate row
instead of upserting it.

### One primitive

Every operation funnels through a single private `perform` on ``DatabaseClient``, whose return
type is constrained to `Sendable`. `NSManagedObject` is `NS_SWIFT_NONSENDABLE`, so a managed
object cannot be returned from it — what the Realm implementation left to convention is a type
error here. ``DatabaseClient/withContext(_:_:)`` is that same primitive re-exported as the public
escape hatch, for the object-graph work the DTO tier does not cover: traversing relationships,
wiring an `NSFetchedResultsController`, running a request this framework has no signature for.

Which context an operation runs on is a per-call choice — see ``DatabaseContext``. Reads default
to `.main`, writes to `.background`.

### Three tiers

- **Object-graph CRUD** — ``DatabaseActions``, implemented by ``DatabaseClient``. Goes through
  managed objects, so delete rules cascade, validation runs, and `willSave` / `didSave` fire.
- **Batch** — ``DatabaseBatchActions``. Issues `NSBatch*Request` straight to the store,
  bypassing every one of those, and requires a SQLite-backed store — ``DatabaseError/batchUnsupported``
  otherwise. A separate, clearly-labelled protocol on purpose (D4): the speed is bought with real
  losses, and ``DatabaseBatchActions/batchInsert(_:count:in:provider:)`` is *insert-or-ignore, not
  upsert*, whatever the merge policy says.
- **Combine** — ``DatabaseCombineProxy``, reached through ``DatabaseClient/combine``. The same CRUD
  as publishers, plus the live `observe` publishers the async tier has no equivalent for. Its
  publishers are cold, writes commit even when the subscription is cancelled, and emissions arrive
  on no particular queue — `receive(on:)` before binding to UI.

The Combine tier is opt-in: `pod 'CoreDataDB/Combine'`, or the `CoreDataDBCombine` product under
Swift Package Manager, where it is a module of its own. CocoaPods and the Xcode framework compile
both tiers into `CoreDataDB` itself, so a consumer of both writes a single import.

### Migration runs before the client exists

Both halves are driven by ``MigrationFacade`` from inside ``DatabaseClient/init(configuration:onMigrationProgress:)``,
so no caller ever observes a half-migrated store (G6). ``SchemaMigrationPlan`` moves the store from
version to version and runs *inside* `loadPersistentStores`; the ``ModelMigration`` list does
per-model data work afterwards, topologically sorted by declared dependencies, with one fresh
context and one save each. What has already been applied is recorded in the store's own metadata,
so the record travels with the file across a backup and restore.

Under the default ``MigrationPolicy/continueOnFailure`` a migration that throws does **not** fail
the initializer, which makes ``DatabaseClient/migrationReport`` the only place it surfaces. Check
``MigrationReport/failures`` at launch.

## Topics

### Essentials

- ``DatabaseClient``
- ``DatabaseConfiguration``
- ``PersistableModel``
- ``DatabaseContext``

### Reading and writing

- ``DatabaseActions``
- ``DatabaseError``

### The batch tier

- ``DatabaseBatchActions``
- ``BatchResult``

### Publishers and live observation

- ``DatabaseCombineProxy``

### Schema migration

- ``SchemaMigrationPlan``
- ``MigrationFacade``

### Data migration

- ``ModelMigration``
- ``MigrationPolicy``
- ``MigrationReport``
- ``MigrationProgress``
