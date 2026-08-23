//
//  DatabaseError.swift
//  DatabaseLayer
//

import Foundation

// MARK: - DatabaseError

/// Every failure `DatabaseLayer` reports.
///
/// The Realm implementation had no error type at all: opening the store called `fatalError`,
/// and a write issued while another was in flight resumed *successfully* without doing
/// anything. Both are representable failures now.
public enum DatabaseError: Error, Sendable {

    /// The persistent store could not be added to the coordinator — a corrupt file, an
    /// unwritable location, or a schema the store cannot migrate to.
    case storeLoadFailed(underlying: any Error)

    /// `DatabaseConfiguration.model` could not be resolved into a usable
    /// `NSManagedObjectModel`.
    case invalidModel(String)

    /// The model has no entity by that name.
    case entityNotFound(String)

    /// No row matched the identifier the operation was given.
    case objectNotFound

    /// A `batch*` operation was issued against a store that cannot service it.
    /// `NSBatchInsertRequest` and friends run as SQL against the store file, so they
    /// require a SQLite-backed store.
    case batchUnsupported

    /// A per-model data migration failed. `model` is the offending
    /// `ModelMigration.modelIdentifier`.
    case migrationFailed(model: String, underlying: any Error)

    /// The migration layer was handed an ordering it cannot run: a schema stage plan that claims
    /// a model version twice, two `ModelMigration`s claiming one model, or a dependency cycle.
    ///
    /// The first of those is why this case exists rather than being folded into `.invalidModel`.
    /// `NSStagedMigrationManager` raises an *uncatchable* `NSInvalidArgumentException` for a
    /// repeated version checksum, so the plan is checked before Core Data ever sees it.
    case invalidMigrationPlan(String)
}

// MARK: - DatabaseError + LocalizedError

extension DatabaseError: LocalizedError {

    public var errorDescription: String? {
        switch self {
        case .storeLoadFailed(let underlying):
            "Failed to load the persistent store: \(underlying.localizedDescription)"
        case .invalidModel(let reason):
            "Invalid managed object model: \(reason)"
        case .entityNotFound(let name):
            "The model has no entity named '\(name)'."
        case .objectNotFound:
            "No object matched the given identifier."
        case .batchUnsupported:
            "Batch requests require a SQLite-backed store."
        case .migrationFailed(let model, let underlying):
            "Migration of '\(model)' failed: \(underlying.localizedDescription)"
        case .invalidMigrationPlan(let reason):
            "Invalid migration plan: \(reason)"
        }
    }
}
