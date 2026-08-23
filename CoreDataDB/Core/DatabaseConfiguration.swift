//
//  DatabaseConfiguration.swift
//  DatabaseLayer
//

import CoreData
import Foundation

// MARK: - DatabaseConfiguration

/// Everything needed to open a store.
///
/// The package still ships no model of its own: the host app supplies one, exactly as it
/// supplied Realm's schema through the default `Realm.Configuration`.
public struct DatabaseConfiguration: Sendable {

    // MARK: ModelSource

    /// Where the `NSManagedObjectModel` comes from.
    public enum ModelSource: Sendable {

        /// A model built on demand. The closure runs once, while the store is loading.
        ///
        /// This is a closure rather than a plain `NSManagedObjectModel` because the class
        /// is not `Sendable` — and genuinely is mutable, until a coordinator picks it up
        /// and Core Data freezes it. Building the model inside the closure also means each
        /// client gets its own, which is what keeps two stores in one process from
        /// fighting over a single frozen model.
        case model(@Sendable () throws -> NSManagedObjectModel)

        /// A compiled model (`.momd`, or `.mom` for an unversioned one) looked up by name.
        case named(String, bundle: Bundle)
    }

    // MARK: StoreKind

    /// Where the data lives.
    public enum StoreKind: Sendable {

        /// A SQLite store at a URL you own.
        case sqlite(URL)

        /// `NSInMemoryStoreType`. Fast and disposable, but it cannot service batch
        /// requests — those run as SQL against the store file.
        case inMemory

        /// A SQLite store at a fresh URL in the temporary directory.
        ///
        /// Disposable like `.inMemory`, but SQLite-backed, so batch requests work. The
        /// caller owns cleanup; `ContextProvider.storeURL` reports where the file landed.
        case temporary
    }

    // MARK: MigrationBehavior

    /// How the store handles a model version it was not written with.
    public enum MigrationBehavior: Sendable {

        /// Infer a mapping and migrate in place — the zero-configuration behaviour the
        /// Realm implementation had.
        case lightweight

        /// Do not migrate. A version mismatch fails the store load.
        case disabled

        /// Walk a described ordering of model versions, running data work between the ones that
        /// need it (G6). Installs an `NSStagedMigrationManager` on the store description.
        ///
        /// This does not turn inference *off*: Core Data requires both automatic migration and
        /// automatic inference to be enabled alongside a staged manager, and `install(on:)` sets
        /// them. A staged plan interleaves custom work with lightweight steps; it does not
        /// replace them.
        case staged(SchemaMigrationPlan)

        /// The plan, for the behaviours that carry one.
        var plan: SchemaMigrationPlan? {
            switch self {
            case .staged(let plan): plan
            case .lightweight, .disabled: nil
            }
        }
    }

    // MARK: Properties

    /// Names the container, and through it the contexts, in debugger output.
    public var name: String

    public var model: ModelSource

    public var store: StoreKind

    /// Applied to every context the client writes through. `NSMergeByPropertyObjectTrumpMergePolicyType`
    /// is what gives `save` the upsert semantics Realm's `UpdatePolicy.modified` had — but
    /// only for entities carrying a unique constraint on their identifier.
    public var mergePolicy: NSMergePolicyType

    /// Records store changes in a transaction history.
    ///
    /// Batch operations write straight to the store, so live contexts only learn about them
    /// through this history. Ignored for `.inMemory`, which does not support it.
    public var isPersistentHistoryTrackingEnabled: Bool

    /// How the *schema* gets from the version on disk to the one in `model`.
    public var migration: MigrationBehavior

    /// Per-model *data* migrations, run once each after the store opens and before
    /// `DatabaseClient.init` returns.
    ///
    /// Order here does not matter — `MigrationFacade` sorts on each migration's declared
    /// dependencies. What has already been applied is recorded in the store file itself, so
    /// listing a migration that has run costs one metadata read.
    public var migrations: [any ModelMigration]

    /// What happens when one of `migrations` throws. Defaults to running the rest and reporting.
    public var migrationPolicy: MigrationPolicy

    /// The models checked against the schema when the store opens.
    ///
    /// Registering a model is what buys the diagnostics in `ModelValidator`: a missing entity,
    /// an identifier that names no attribute, or a missing uniqueness constraint is reported
    /// against the model rather than surfacing later as a crash or a duplicate row.
    public var registeredModels: [any PersistableModel.Type]

    // MARK: Init

    public init(
        name: String = "DatabaseLayer",
        model: ModelSource,
        store: StoreKind,
        mergePolicy: NSMergePolicyType = .mergeByPropertyObjectTrumpMergePolicyType,
        persistentHistoryTracking: Bool = true,
        migration: MigrationBehavior = .lightweight,
        migrations: [any ModelMigration] = [],
        migrationPolicy: MigrationPolicy = .continueOnFailure,
        registeredModels: [any PersistableModel.Type] = []
    ) {
        self.name = name
        self.model = model
        self.store = store
        self.mergePolicy = mergePolicy
        self.isPersistentHistoryTrackingEnabled = persistentHistoryTracking
        self.migration = migration
        self.migrations = migrations
        self.migrationPolicy = migrationPolicy
        self.registeredModels = registeredModels
    }
}

// MARK: - ModelSource + Resolution

extension DatabaseConfiguration.ModelSource {

    /// Produces the model, or explains why it could not.
    func resolve() throws -> NSManagedObjectModel {
        let model: NSManagedObjectModel

        switch self {
        case .model(let build):
            model = try build()

        case .named(let name, let bundle):
            guard let url = bundle.url(forResource: name, withExtension: "momd")
                ?? bundle.url(forResource: name, withExtension: "mom") else {
                throw DatabaseError.invalidModel(
                    "No compiled model named '\(name)' in \(bundle.bundlePath)"
                )
            }
            guard let loaded = NSManagedObjectModel(contentsOf: url) else {
                throw DatabaseError.invalidModel("'\(url.lastPathComponent)' is not a loadable model")
            }
            model = loaded
        }

        // An empty model loads without complaint and then fails every operation, so it is
        // worth rejecting here rather than at the first fetch.
        guard !model.entities.isEmpty else {
            throw DatabaseError.invalidModel("The model contains no entities.")
        }

        return model
    }
}

// MARK: - StoreKind + Resolution

extension DatabaseConfiguration.StoreKind {

    /// `NSPersistentStoreDescription`'s only initializer takes a URL, and an in-memory
    /// store has no file. Core Data ignores the URL for `NSInMemoryStoreType`.
    static let inMemoryPlaceholderURL = URL(fileURLWithPath: "/dev/null")

    var storeType: String {
        switch self {
        case .sqlite, .temporary: NSSQLiteStoreType
        case .inMemory: NSInMemoryStoreType
        }
    }

    /// Whether the store is a real SQLite file.
    ///
    /// Persistent history tracking and the batch request tier both talk to SQLite directly
    /// and are unavailable otherwise.
    var isSQLiteBacked: Bool {
        switch self {
        case .sqlite, .temporary: true
        case .inMemory: false
        }
    }

    /// The file the store lives in, or `nil` for `.inMemory`.
    ///
    /// `.temporary` picks a fresh name on every call, so resolve it once and keep the result.
    func makeFileURL() -> URL? {
        switch self {
        case .sqlite(let url):
            url
        case .temporary:
            FileManager.default.temporaryDirectory
                .appendingPathComponent("DatabaseLayer-\(UUID().uuidString)")
                .appendingPathExtension("sqlite")
        case .inMemory:
            nil
        }
    }
}
