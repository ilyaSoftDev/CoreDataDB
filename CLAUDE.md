# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

`CoreDataDB` is a standalone Swift **framework** (Xcode project — not SPM, not CocoaPods-consumable
yet) that wraps Core Data behind a `Sendable`, async/await, DTO-based API. It is a rewrite of a
Realm-backed `DatabaseManager` that is **not** in this repo — doc comments contrast against it
constantly, so "the Realm implementation" always means that absent predecessor, never code you
can go read.

The framework **ships no `NSManagedObjectModel`**. The host app supplies one through
`DatabaseConfiguration.ModelSource`. That single fact drives most of the design: nothing about the
schema can be assumed at compile time, so `ModelValidator` checks it at store-open instead.

~2,600 lines across 15 files. No dependencies beyond `CoreData`, `Foundation`, `os`.

**Licensing:** proprietary, use-only (see `LICENSE`). It is not open source. The license forbids
modification, derivative works, and redistribution in source form, and Section 3 states that outside
contributions are not accepted. That is a constraint on *consumers*, not on work done in this repo by
the copyright holder — but it means requests framed around forking, vendoring, or upstreaming this
code to a third party should be flagged rather than carried out.

## Build and test

Verified working:

```bash
# Build the framework (macOS is fastest; SUPPORTED_PLATFORMS is iOS/macOS/visionOS)
xcodebuild -scheme CoreDataDB -destination 'platform=macOS' build

# Build the test target
xcodebuild -project CoreDataDB.xcodeproj -target CoreDataDBTests \
  -configuration Debug -destination 'platform=macOS' build
```

Two traps in the second command, both load-bearing:

- **`-configuration Debug` is required.** With `-target` and no `-scheme`, xcodebuild defaults to
  Release, which builds the framework without `-enable-testing`, and `@testable import CoreDataDB`
  then fails with "Unable to resolve Swift module dependency to a compatible module".
- **`-target` writes to `./build/` inside the repo**, which is untracked and there is no
  `.gitignore`. Delete it afterwards.

Podspec validation (verified passing for iOS and macOS):

```bash
pod lib lint CoreDataDB.podspec --platforms=ios,osx
```

`xcodebuild -scheme CoreDataDB ... test` **does not work** — it fails with "Scheme CoreDataDB is not
currently configured for the test action". The scheme is auto-generated (no `.xcscheme` file is
checked in, only `xcschememanagement.plist`) and its test action has no testables. Running the suite
from the command line requires wiring the test target into the scheme first.

## Architecture

Three layers, one choke point.

```
DatabaseClient  ──  public facade, Sendable, conforms to both action protocols
      │
      ├── perform(_:_:)  ← the single primitive; EVERY operation goes through it
      │
      └── ContextProvider  ──  owns NSPersistentContainer + the long-lived contexts
```

**`DatabaseClient.perform(_:_:)` (`CoreDataDB/DatabaseClient.swift`) is the one place any work
touches a context.** It is private, and its `R: Sendable` constraint is the load-bearing safety
mechanism: `NSManagedObject` is `NS_SWIFT_NONSENDABLE`, so a managed object cannot be returned from
it. `withContext(_:_:)` is the same primitive re-exported as the public escape hatch. Adding an
operation means routing it through `perform`, not calling `context.perform` directly.

**Two deliberately separate API tiers**, and the split matters:

- `DatabaseActions` — object-graph CRUD. Goes through managed objects, so delete rules cascade,
  validation runs, `willSave`/`didSave` fire.
- `DatabaseBatchActions` — direct-to-store `NSBatch*Request`. Bypasses all of the above and requires
  a SQLite-backed store (`DatabaseError.batchUnsupported` otherwise). Every method must merge its
  resulting object IDs back into `provider.mergeTargets`, or live contexts never learn about the
  change. `Self.merge(_:forKey:into:)` does this.
  Note the measured, documented asymmetry: `batchInsert` is **insert-or-ignore, not upsert**, whatever
  the merge policy says.

**Migration is two halves that run at different moments**, both driven by `MigrationFacade` from
inside `DatabaseClient.init`, so no caller ever observes a half-migrated store:

- `SchemaMigrationPlan` — version→version, installed on the `NSPersistentStoreDescription` and run
  *inside* `loadPersistentStores`. `validate()` exists because `NSStagedMigrationManager` raises an
  **uncatchable** `NSInvalidArgumentException` for a duplicated version checksum.
- `[ModelMigration]` — per-model data work, run *after* the store opens, topologically sorted by
  declared dependencies, one fresh background context and one save each.

`MigrationLedger` records applied versions in **store metadata**, not `UserDefaults` — so the record
travels with the file across backup/restore. Its `metadataKey` (`"DatabaseLayer.ModelMigrations"`) is
a persisted string: changing it makes every past migration look unapplied.

`ModelValidator` runs before the store is created, and is intentionally two-faced — it **throws in
DEBUG, logs and continues in RELEASE**, so a misconfiguration fails loudly in development without
bricking a shipped app.

## Conventions

- **`// MARK:` structure is strict and consistent.** `// MARK: - TypeName` for a type, bare
  `// MARK: Properties` / `Init` / etc. for sections within it, and `// MARK: - Type + Feature` for
  extensions. Match it.
- **Doc comments explain *why*, at length.** They cite decision IDs (`D1`–`D5`, `G5`, `G6`) from a
  design document that is not in this repo, name the exact Core Data error codes and exception
  messages a mistake produces, and record which toolchain a behaviour was *measured* on. This is the
  house style — new code should carry the same register, and existing comments are the primary
  documentation, so keep them accurate when changing behaviour.
- **Predicates are built structurally**, via `NSComparisonPredicate` + `NSExpression`, never
  `NSPredicate(format:)`. This is deliberate: the format string takes `CVarArg`, which refuses `UUID`
  and silently misreads `Int`. See `FetchRequestBuilder`.
- **`NSPredicate`/`NSSortDescriptor` parameters are `sending`**, then re-bound with
  `nonisolated(unsafe) let` before crossing into the context closure. Follow that pattern for any new
  API taking one.
- **Adding a Swift file needs no project edit.** Both targets use Xcode 16 file-system-synchronized
  groups, so anything dropped under `CoreDataDB/` or `CoreDataDBTests/` joins the target
  automatically. Do not hand-edit `project.pbxproj` to add sources.
- `BUILD_LIBRARY_FOR_DISTRIBUTION = YES`. Library evolution is on, so changes to `public` API are
  ABI-relevant.

## Known inconsistencies in the current state

Verified, and worth knowing before trusting a comment or a build setting:

- **The Swift language mode is 5.0, not 6.** `SWIFT_VERSION = 5.0` with
  `SWIFT_APPROACHABLE_CONCURRENCY = YES` (which turns on `NonisolatedNonsendingByDefault`,
  `InferIsolatedConformances`, `GlobalActorIsolatedTypesUsability`, and friends). `SWIFT_STRICT_CONCURRENCY`
  is unset, so it is at `minimal`. Doc comments throughout claim things are "a compile error rather
  than a runtime surprise" under Swift 6 — under the project's actual settings those `Sendable`
  violations are not diagnosed. Treat the claims as design intent, not as enforcement.
- **Deployment targets are 26.5** (iOS/macOS/visionOS), while doc comments repeatedly state the
  floor is "iOS 18 / macOS 15". They disagree; the comments about behaviour being "unspecified across
  the supported range" were written against the lower floor.
- **There are no real tests.** `CoreDataDBTests/CoreDataDBTests.swift` is untouched Xcode XCTest
  boilerplate. Comments in `BatchOperations.swift` and `DatabaseActions.swift` cite a `BatchTests`
  suite that pins down measured Core Data behaviour — it does not exist in this repo.
- **Internal naming still says `DatabaseLayer`.** Every file header, the `Logger` subsystems, the
  default `DatabaseConfiguration.name`, the generated context names, and the ledger metadata key all
  use the old module name. Renaming the metadata key is a data-migration event; the rest is cosmetic.
- **The podspec declares `1.0.0`, but no `1.0.0` git tag exists.** `pod lib lint` works off local
  files and passes; `pod spec lint` and `pod trunk push` resolve `:tag => "1.0.0"` against the remote
  and will fail until the tag is pushed. The repo has no tags at all.
- **`pod lib lint` cannot validate the visionOS slice on this machine.** The visionOS SDK is
  installed but no `xros` simulator is registered, so the lint aborts that platform with "Could not
  find a `xros` simulator". iOS and macOS pass. Use `--platforms=ios,osx` to skip it, or register a
  visionOS simulator in Xcode → Windows → Devices and Simulators.
- **The podspec is wired into the framework target's Resources build phase** (uncommitted change in
  `project.pbxproj`), so it is currently copied inside the built `.framework`. Almost certainly an
  accidental "add to target" — remove it from the build phase rather than propagating it.
- **The only scheme lives in `xcuserdata`, which is now gitignored.** There is no shared
  `.xcscheme` under `xcshareddata/`, so a fresh clone has no scheme until Xcode autocreates one on
  open — and `xcodebuild -scheme CoreDataDB` will not work before that. A shared scheme is the fix,
  and the same edit is where the missing test action belongs.
- The DocC catalog (`CoreDataDB/CoreDataDB.docc/CoreDataDB.md`) is an unfilled Xcode template.
