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

~3,350 lines across 19 files, split into two CocoaPods subspecs that mirror the folder layout:

- `CoreDataDB/Core` (`CoreDataDB/Core/`, 15 files) — the async/await tier. The default subspec.
- `CoreDataDB/Combine` (`CoreDataDB/Combine/`, 4 files) — the same CRUD as publishers, plus live
  `observe` publishers. Depends on `Core`; opt-in.

No dependencies beyond `CoreData`, `Foundation`, `Combine`, `os`.

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

That builds the two subspecs together *and* each one alone — watch for the `[CoreDataDB/Core]` and
`[CoreDataDB/Combine]` lines. The isolated `Core` build is the only check that the subspec split is
real; nothing in an Xcode build enforces it.

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

**`DatabaseClient.perform(_:_:)` (`CoreDataDB/Core/DatabaseClient.swift`) is the one place any work
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

**The Combine tier (`CoreDataDB/Combine/`) is a third, opt-in tier** reached through
`DatabaseClient.combine` — a `DatabaseCombineProxy` namespace rather than methods on the client, so
crossing into it is deliberate. It adds no way to reach a context: everything is built on the public
async API through `DatabaseTaskPublisher`, which wraps one `async throws` call. Four rules hold
across it:

- **Publishers are cold** — the `Task` starts on the first `request(_:)` with demand, so an
  unsubscribed publisher (a write included) does nothing.
- **Writes commit, reads cancel.** `DatabaseTaskPublisher.CancellationPolicy` picks per operation.
  Writes use `.completesWork` so the usual discarded-`AnyCancellable` mistake cannot swallow a save.
- **Failure is `any Error`**, not `DatabaseError` — mirroring what the async tier actually throws.
- **Emissions arrive on no particular queue**, `.main` context included. Callers `receive(on:)`.

`observe(_:matching:sortedBy:limit:in:)` is the part with no async equivalent: it prepends an initial
snapshot, then re-fetches on every change signal, `switchToLatest` + `removeDuplicates`.
`StoreChangeNotifications` supplies the signal from **two** sources, and both are needed —
`didSaveObjectIDsNotification` for context saves, and `DatabaseClient.didMergeStoreChangesNotification`
for the batch tier, which writes past the contexts and raises no `didSave` at all. The `ObjectIDs`
variant is mandatory: `didSaveObjectsNotification` hands over live managed objects, and reading
`.entity.name` off the owning queue is what `-com.apple.CoreData.ConcurrencyDebug 1` traps on.

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
  automatically — subfolders included. Do not hand-edit `project.pbxproj` to add sources.
- **The folder a file lives in is the subspec *and* the SPM target it ships in.**
  `CoreDataDB/Core/` and `CoreDataDB/Combine/` are globbed separately by the podspec and are the
  two `path:` roots in `Package.swift`, so a new file has to go in the right one — a file directly
  under `CoreDataDB/` belongs to neither and ships in neither package, which
  `.github/scripts/check-source-layout.sh` fails the build for. `Core/` must never reference
  anything in `Combine/`.
- **Under SPM the two folders are two modules, everywhere else they are one.** `CoreDataDBCombine`
  depends on `CoreDataDB`; CocoaPods and the Xcode framework compile both folders into a single
  module named `CoreDataDB`. Two rules follow for anything new in `Combine/`: its
  `import CoreDataDB` goes inside `#if COREDATADB_MODULAR` (the flag only `Package.swift` defines),
  and it can only use Core's *public* API — the single exception is
  `DatabaseClient.storeIdentifier`, which Core exposes as `@_spi(CoreDataDBTiers)` precisely
  because the module boundary put it out of reach. Reach for another internal symbol and the
  Xcode build stays green while `swift build` fails.
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
- **The podspec declares `1.1.0`, but no git tag exists.** `pod lib lint` works off local
  files and passes; `pod spec lint` and `pod trunk push` resolve `:tag => "1.1.0"` against the remote
  and will fail until the tag is pushed. The repo has no tags at all.
- **The split is a real module boundary under SPM and a packaging one everywhere else.**
  `Package.swift` declares `CoreDataDB` and `CoreDataDBCombine` as separate targets, so `swift
  build` does enforce the direction of the dependency. CocoaPods still compiles both subspecs into
  one module, and the Xcode framework target — whose synchronized group is rooted at `CoreDataDB/`
  — always compiles both folders, so the built `.framework` always contains the Combine tier and
  nothing in an *Xcode* build stops `Core/` picking up a dependency on `Combine/`. Two things catch
  that: `swift build`, and `pod lib lint`, which builds each subspec in isolation.
- **`pod lib lint` cannot validate the visionOS slice on this machine.** The visionOS SDK is
  installed but no `xros` simulator is registered, so the lint aborts that platform with "Could not
  find a `xros` simulator". iOS and macOS pass. Use `--platforms=ios,osx` to skip it, or register a
  visionOS simulator in Xcode → Windows → Devices and Simulators.
- **The podspec is wired into the framework target's Resources build phase**
  (`project.pbxproj:183`, committed), so it is currently copied inside the built `.framework`.
  Almost certainly an accidental "add to target" — remove it from the build phase rather than
  propagating it.
- **The only scheme lives in `xcuserdata`, which is now gitignored.** There is no shared
  `.xcscheme` under `xcshareddata/`, so a fresh clone has no scheme until Xcode autocreates one on
  open — and `xcodebuild -scheme CoreDataDB` will not work before that. A shared scheme is the fix,
  and the same edit is where the missing test action belongs.
- The DocC catalog (`CoreDataDB/CoreDataDB.docc/CoreDataDB.md`) is an unfilled Xcode template.
