//
//  MigrationFacade.swift
//  DatabaseLayer
//

import CoreData
import Foundation
import os

private let logger = Logger(subsystem: "DatabaseLayer", category: "Migration")

// MARK: - MigrationFacade

/// The entry point for G6: one object that owns both halves of a migration.
///
/// ```
/// MigrationFacade
/// ├── SchemaMigrationPlan     store version → store version   (at store load)
/// └── [ModelMigration]        per-model data work             (after store load)
/// ```
///
/// The two halves run at different moments and there is no way around that. Schema stages are
/// installed on the store description and run *inside* `loadPersistentStores`, because that is
/// where Core Data does migration. Data migrations run afterwards, against the migrated store,
/// where a normal context and a normal fetch work.
///
/// `DatabaseClient.init` drives both, so no caller ever sees a half-migrated store. Use this type
/// directly only for a Core Data stack this package does not own.
///
/// An actor because progress observers are registered from one task and fired from another.
public actor MigrationFacade {

    // MARK: Properties

    /// The schema half. Installed by `install(on:)` before the store loads.
    public let plan: SchemaMigrationPlan?

    private let migrations: [any ModelMigration]

    private let policy: MigrationPolicy

    private var callbacks: [@Sendable (MigrationProgress) -> Void] = []

    private var continuations: [AsyncStream<MigrationProgress>.Continuation] = []

    // MARK: Init

    public init(
        plan: SchemaMigrationPlan? = nil,
        migrations: [any ModelMigration] = [],
        policy: MigrationPolicy = .continueOnFailure
    ) {
        self.plan = plan
        self.migrations = migrations
        self.policy = policy
    }

    // MARK: Schema

    /// Installs the schema plan on a store description, if there is one.
    ///
    /// `nonisolated` because it touches only `plan`, and because it has to be callable from the
    /// synchronous stretch of code that configures a store description before loading it.
    ///
    /// - Throws: `DatabaseError.invalidMigrationPlan` for an ordering Core Data would raise an
    ///   uncatchable exception over.
    public nonisolated func install(on description: NSPersistentStoreDescription) throws {
        try plan?.install(on: description)
    }

    // MARK: Progress

    /// A stream of migration events. Obtain it *before* calling `migrate(container:)`; it
    /// finishes when the run does.
    public func progress() -> AsyncStream<MigrationProgress> {
        let (stream, continuation) = AsyncStream.makeStream(of: MigrationProgress.self)
        continuations.append(continuation)
        return stream
    }

    /// The callback form, for callers that cannot hold a stream across the call that starts the
    /// migration — `DatabaseClient.init` being the one that matters.
    public func observeProgress(_ observer: @escaping @Sendable (MigrationProgress) -> Void) {
        callbacks.append(observer)
    }

    private func emit(_ progress: MigrationProgress) {
        for callback in callbacks {
            callback(progress)
        }

        for continuation in continuations {
            continuation.yield(progress)
        }
    }

    private func finishProgress() {
        for continuation in continuations {
            continuation.finish()
        }

        continuations.removeAll()
        callbacks.removeAll()
    }

    // MARK: Data migrations

    /// Runs every registered `ModelMigration` that the store has not already had applied.
    ///
    /// Ordered by declared dependencies, one background context and one save each, so a failure
    /// takes down only its own model's work. The ledger entry is written in that same save.
    ///
    /// - Returns: A report covering every model, including the ones that were skipped.
    /// - Throws: `DatabaseError.invalidMigrationPlan` for a duplicate model identifier or a
    ///   dependency cycle — neither of which is worth attempting a partial run over — and
    ///   `DatabaseError.migrationFailed` when `policy` is `.stopOnFirstFailure`. Under the
    ///   default `.continueOnFailure` a failing migration is reported, not thrown.
    @discardableResult
    public func migrate(container: NSPersistentContainer) async throws -> MigrationReport {
        defer { finishProgress() }

        guard !migrations.isEmpty else { return .empty }

        try Task.checkCancellation()

        let ordered = try MigrationOrder.sorted(migrations)
        let coordinator = container.persistentStoreCoordinator
        let applied = try MigrationLedger.applied(in: coordinator)

        warnAboutUnknownDependencies(in: ordered)

        var entries: [MigrationReport.Entry] = []
        entries.reserveCapacity(ordered.count)

        for (index, migration) in ordered.enumerated() {
            try Task.checkCancellation()

            emit(
                MigrationProgress(
                    modelIdentifier: migration.modelIdentifier,
                    version: migration.version,
                    phase: .started,
                    completed: index,
                    total: ordered.count
                )
            )

            let outcome = await outcome(of: migration, applied: applied, in: container, coordinator: coordinator)

            entries.append(
                MigrationReport.Entry(
                    modelIdentifier: migration.modelIdentifier,
                    version: migration.version,
                    outcome: outcome
                )
            )

            emit(
                MigrationProgress(
                    modelIdentifier: migration.modelIdentifier,
                    version: migration.version,
                    phase: .finished(outcome),
                    completed: index + 1,
                    total: ordered.count
                )
            )

            if case .failed(let error) = outcome, policy == .stopOnFirstFailure {
                throw DatabaseError.migrationFailed(model: migration.modelIdentifier, underlying: error)
            }
        }

        return MigrationReport(entries: entries)
    }

    /// Runs one migration, or explains why it did not have to.
    private func outcome(
        of migration: any ModelMigration,
        applied: [String: Int],
        in container: NSPersistentContainer,
        coordinator: NSPersistentStoreCoordinator
    ) async -> MigrationReport.Outcome {
        if let appliedVersion = applied[migration.modelIdentifier], appliedVersion >= migration.version {
            return .skipped(appliedVersion: appliedVersion)
        }

        let clock = ContinuousClock()
        let start = clock.now

        do {
            try await Self.run(migration, in: container, coordinator: coordinator)
            return .migrated(duration: clock.now - start)
        } catch {
            logger.error(
                "Migration of '\(migration.modelIdentifier, privacy: .public)' failed: \(error.localizedDescription, privacy: .public)"
            )
            return .failed(error)
        }
    }

    /// One migration, on a context of its own.
    ///
    /// A fresh `newBackgroundContext()` rather than the client's shared one: an unsaved change
    /// left behind by a throwing migration dies with the context instead of riding along in the
    /// next model's save.
    private static func run(
        _ migration: any ModelMigration,
        in container: NSPersistentContainer,
        coordinator: NSPersistentStoreCoordinator
    ) async throws {
        let context = container.newBackgroundContext()
        context.name = "\(container.name).migration.\(migration.modelIdentifier)"

        try await context.perform {
            try migration.migrate(in: context)
            try MigrationLedger.record(
                migration.version,
                for: migration.modelIdentifier,
                in: coordinator,
                saving: context
            )
        }
    }

    /// A dependency naming nothing in this run is ignored, which is right — a host app may
    /// include migrations conditionally — but it is also exactly what a typo looks like.
    private func warnAboutUnknownDependencies(in migrations: [any ModelMigration]) {
        let known = Set(migrations.map(\.modelIdentifier))

        for migration in migrations {
            for dependency in migration.dependencies where !known.contains(dependency) {
                logger.warning(
                    """
                    Migration '\(migration.modelIdentifier, privacy: .public)' depends on \
                    '\(dependency, privacy: .public)', which is not in this run. Ordering ignores it.
                    """
                )
            }
        }
    }
}
