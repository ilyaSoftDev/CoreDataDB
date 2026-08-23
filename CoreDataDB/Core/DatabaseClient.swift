//
//  DatabaseClient.swift
//  DatabaseLayer
//

import CoreData
import Foundation

// MARK: - DatabaseClient

/// The Core Data facade that replaces the Realm-backed `DatabaseManager`.
///
/// The client is `Sendable` rather than `@MainActor` (D3). Core Data contexts carry their own
/// queues, so an instance may be built from any isolation domain and every operation hops onto
/// the right context itself — where `DatabaseManager` created its `Realm` on whichever thread
/// happened to construct it and then raised an uncatchable `RLMException` if that was not the
/// main one.
public final class DatabaseClient: Sendable {

    // MARK: Properties

    let provider: ContextProvider

    /// What the data migrations did while this client was opening.
    ///
    /// Empty unless `configuration.migrations` was. Worth checking at launch: under the default
    /// `MigrationPolicy.continueOnFailure` a migration that threw is reported here rather than
    /// failing `init`, so this is the only place it surfaces.
    public let migrationReport: MigrationReport

    // MARK: Init

    /// Opens the store described by `configuration` and brings it fully up to date.
    ///
    /// Both halves of the migration layer run before this returns, so no caller ever sees a
    /// half-migrated store: schema stages inside the store load, then the per-model data
    /// migrations, in dependency order, skipping whatever the store's ledger already records.
    ///
    /// - Parameter onMigrationProgress: Called as each data migration starts and finishes.
    ///   Migration happens *during* `init`, so a callback is the only way to observe it from
    ///   here; drive `MigrationFacade` yourself if you would rather have the `AsyncStream`.
    /// - Throws: `DatabaseError.invalidModel`, `.storeLoadFailed`, `.invalidMigrationPlan`, or —
    ///   under `MigrationPolicy.stopOnFirstFailure` — `.migrationFailed`. The Realm initializer
    ///   called `fatalError` here, so a corrupt or schema-mismatched file took the host app
    ///   down with it.
    public init(
        configuration: DatabaseConfiguration,
        onMigrationProgress: (@Sendable (MigrationProgress) -> Void)? = nil
    ) async throws {
        let provider = try await ContextProvider(configuration: configuration)

        let facade = MigrationFacade(
            plan: configuration.migration.plan,
            migrations: configuration.migrations,
            policy: configuration.migrationPolicy
        )

        if let onMigrationProgress {
            await facade.observeProgress(onMigrationProgress)
        }

        self.migrationReport = try await facade.migrate(container: provider.container)
        self.provider = provider
    }

    // MARK: The primitive

    /// Runs `body` on the context `kind` names, and returns what it produced.
    ///
    /// Every operation in the package funnels through here. `R` is constrained to `Sendable`,
    /// which is what stops a managed object from escaping: `NSManagedObject` is
    /// `NS_SWIFT_NONSENDABLE`, so returning one is a compile error rather than the runtime
    /// surprise it would have been under Realm. (Core Data's own `perform` leaves the return
    /// type unconstrained, so it does not stop you.)
    private func perform<R: Sendable>(
        _ kind: DatabaseContext,
        _ body: @escaping @Sendable (NSManagedObjectContext) throws -> R
    ) async throws -> R {
        // Nothing here pages, so this is the only place cancellation can be observed.
        try Task.checkCancellation()

        switch kind {
        case .main, .background:
            let context = provider.context(for: kind)
            return try await context.perform { try body(context) }

        case .detached:
            let provider = provider
            return try await provider.container.performBackgroundTask { context in
                // `performBackgroundTask` builds its own context, which arrives with the
                // default merge policy unless we say otherwise.
                provider.configure(context, named: "detached")
                return try body(context)
            }
        }
    }

    // MARK: Escape hatch

    /// Scoped access to a managed object context, for the object-graph work the DTO tier does
    /// not cover — traversing relationships, wiring an `NSFetchedResultsController`, running a
    /// request this package has no signature for.
    ///
    /// - Important: Nothing reachable from a managed object may escape `body`. The `Sendable`
    ///   constraint on `R` enforces exactly that, since no managed object satisfies it.
    public func withContext<R: Sendable>(
        _ context: DatabaseContext = .background,
        _ body: @escaping @Sendable (NSManagedObjectContext) throws -> R
    ) async throws -> R {
        try await perform(context, body)
    }
}

// MARK: - DatabaseClient + DatabaseActions

extension DatabaseClient: DatabaseActions {

    // MARK: Create and upsert

    public func save<T: PersistableModel>(_ model: T, in context: DatabaseContext = .background) async throws {
        try await save([model], in: context)
    }

    public func save<T: PersistableModel>(_ models: [T], in context: DatabaseContext = .background) async throws {
        guard !models.isEmpty else { return }

        try await perform(context) { context in
            let existing = try Self.existingObjects(for: models, in: context)

            for model in models {
                let managed = try existing[model.identifier] ?? Self.insert(T.self, into: context)
                model.encode(into: managed)
            }

            try Self.saveIfNeeded(context)
        }
    }

    // MARK: Read

    public func fetch<T: PersistableModel>(
        _ type: T.Type,
        matching predicate: sending NSPredicate? = nil,
        sortedBy sortDescriptors: sending [NSSortDescriptor] = [],
        limit: Int? = nil,
        in context: DatabaseContext = .main
    ) async throws -> [T] {
        // `sending` is what makes this safe rather than merely quiet: the caller has given the
        // predicate up, so nothing can race with the context's queue for it.
        nonisolated(unsafe) let predicate = predicate
        nonisolated(unsafe) let sortDescriptors = sortDescriptors

        return try await perform(context) { context in
            let request = FetchRequestBuilder.makeRequest(
                for: T.self,
                predicate: predicate,
                sortDescriptors: sortDescriptors,
                limit: limit
            )
            return try context.fetch(request).map(T.init(managed:))
        }
    }

    public func fetch<T: PersistableModel>(
        _ type: T.Type,
        identifier: T.Identifier,
        in context: DatabaseContext = .main
    ) async throws -> T? {
        try await perform(context) { context in
            let request = FetchRequestBuilder.makeRequest(for: T.self, identifier: identifier)
            return try context.fetch(request).first.map(T.init(managed:))
        }
    }

    public func count<T: PersistableModel>(
        _ type: T.Type,
        matching predicate: sending NSPredicate? = nil,
        in context: DatabaseContext = .main
    ) async throws -> Int {
        nonisolated(unsafe) let predicate = predicate

        return try await perform(context) { context in
            try context.count(for: FetchRequestBuilder.makeRequest(for: T.self, predicate: predicate))
        }
    }

    // MARK: Update

    public func update<T: PersistableModel>(
        _ type: T.Type,
        identifier: T.Identifier,
        in context: DatabaseContext = .background,
        mutate: @escaping @Sendable (inout T) throws -> Void
    ) async throws {
        try await perform(context) { context in
            let request = FetchRequestBuilder.makeRequest(for: T.self, identifier: identifier)

            guard let managed = try context.fetch(request).first else {
                throw DatabaseError.objectNotFound
            }

            var model = try T(managed: managed)
            try mutate(&model)
            model.encode(into: managed)

            try Self.saveIfNeeded(context)
        }
    }

    // MARK: Delete

    public func delete<T: PersistableModel>(
        _ type: T.Type,
        identifier: T.Identifier,
        in context: DatabaseContext = .background
    ) async throws {
        try await perform(context) { context in
            let request = FetchRequestBuilder.makeRequest(for: T.self, identifier: identifier)

            guard let managed = try context.fetch(request).first else {
                return
            }

            context.delete(managed)
            try Self.saveIfNeeded(context)
        }
    }

    public func delete<T: PersistableModel>(
        _ type: T.Type,
        matching predicate: sending NSPredicate,
        in context: DatabaseContext = .background
    ) async throws {
        nonisolated(unsafe) let predicate = predicate

        try await perform(context) { context in
            let request = FetchRequestBuilder.makeRequest(for: T.self, predicate: predicate)

            for managed in try context.fetch(request) {
                context.delete(managed)
            }

            try Self.saveIfNeeded(context)
        }
    }

    public func deleteAll() async throws {
        let entityNames = provider.container.managedObjectModel.entities
            // An abstract entity has no rows of its own; a request against one fails.
            .filter { !$0.isAbstract }
            .compactMap(\.name)
        let canBatchDelete = provider.configuration.store.isSQLiteBacked
        let mergeTargets = provider.mergeTargets

        try await perform(.background) { context in
            for name in entityNames {
                if canBatchDelete {
                    try Self.batchDelete(entityName: name, in: context, mergingInto: mergeTargets)
                } else {
                    // `NSBatchDeleteRequest` runs as SQL against the store file, so an
                    // in-memory store has to go the long way round.
                    let request = NSFetchRequest<NSManagedObject>(entityName: name)
                    for managed in try context.fetch(request) {
                        context.delete(managed)
                    }
                }
            }

            try Self.saveIfNeeded(context)
        }
    }
}

// MARK: - DatabaseClient + Helpers

extension DatabaseClient {

    /// The rows already carrying one of `models`' identifiers, keyed by identifier.
    ///
    /// One fetch for the whole batch, which is what keeps `save([T])` from turning into a
    /// round trip per model.
    private static func existingObjects<T: PersistableModel>(
        for models: [T],
        in context: NSManagedObjectContext
    ) throws -> [T.Identifier: T.Entity] {
        let request = FetchRequestBuilder.makeRequest(
            for: T.self,
            predicate: FetchRequestBuilder.identifierPredicate(
                for: T.self,
                identifiers: models.map(\.identifier)
            )
        )

        var byIdentifier: [T.Identifier: T.Entity] = [:]

        for row in try context.fetch(request) {
            guard let identifier = row.value(forKey: T.identifierKey) as? T.Identifier else { continue }
            byIdentifier[identifier] = row
        }

        return byIdentifier
    }

    private static func insert<T: PersistableModel>(
        _ type: T.Type,
        into context: NSManagedObjectContext
    ) throws -> T.Entity {
        // Checked first because `insertNewObject(forEntityName:into:)` raises an ObjC
        // exception for an unknown entity, which Swift cannot catch.
        guard NSEntityDescription.entity(forEntityName: T.entityName, in: context) != nil else {
            throw DatabaseError.entityNotFound(T.entityName)
        }

        guard let managed = NSEntityDescription
            .insertNewObject(forEntityName: T.entityName, into: context) as? T.Entity else {
            throw DatabaseError.invalidModel(
                "'\(T.entityName)' is not backed by \(T.Entity.self)."
            )
        }

        return managed
    }

    /// Empties one entity straight through the store, then tells the live contexts about it.
    ///
    /// - Important: A batch delete does **not** honour delete rules, so a cascade leaves
    ///   orphans behind. `deleteAll` can use it anyway because it is emptying every entity,
    ///   so there is nothing left to orphan. See `DatabaseBatchActions` for the general case.
    private static func batchDelete(
        entityName: String,
        in context: NSManagedObjectContext,
        mergingInto targets: [NSManagedObjectContext]
    ) throws {
        let request = NSBatchDeleteRequest(fetchRequest: NSFetchRequest(entityName: entityName))
        request.resultType = .resultTypeObjectIDs

        let result = try context.execute(request) as? NSBatchDeleteResult
        merge(result?.result, forKey: NSDeletedObjectsKey, into: targets)
    }

    private static func saveIfNeeded(_ context: NSManagedObjectContext) throws {
        guard context.hasChanges else { return }
        try context.save()
    }
}
