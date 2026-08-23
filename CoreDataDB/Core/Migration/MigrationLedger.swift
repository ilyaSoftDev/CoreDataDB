//
//  MigrationLedger.swift
//  DatabaseLayer
//

import CoreData
import Foundation

// MARK: - MigrationLedger

/// Which data migrations a store has already had applied to it.
///
/// The ledger lives in the store's own metadata rather than in `UserDefaults`, so it travels with
/// the file: a store restored from a backup carries the record of what it already reflects, and a
/// migration that has run is never re-run against data that already shows it. `UserDefaults` would
/// get the restore case exactly backwards — the defaults are the *device's*, the data is the
/// *file's*, and after a restore they disagree.
enum MigrationLedger {

    /// One metadata key holding `[modelIdentifier: version]`.
    ///
    /// Namespaced because store metadata is a shared dictionary: Core Data keeps `NSStoreType`,
    /// `NSStoreUUID` and the model version hashes in there too, which is why every write here is
    /// a read-modify-write rather than a replacement.
    static let metadataKey = "DatabaseLayer.ModelMigrations"

    // MARK: Reading

    /// The applied version per model identifier, empty for a store that has never been migrated.
    static func applied(in coordinator: NSPersistentStoreCoordinator) throws -> [String: Int] {
        let store = try store(in: coordinator)
        return coordinator.metadata(for: store)[metadataKey] as? [String: Int] ?? [:]
    }

    // MARK: Writing

    /// Records `version` for `modelIdentifier` and commits it along with whatever else `context`
    /// is holding.
    ///
    /// - Important: Must be called on `context`'s queue, from inside a `perform` block.
    ///
    ///   The save is unconditional, unlike everywhere else in the package where `hasChanges`
    ///   guards it. `setMetadata(_:for:)` only stages the change — the header is explicit that it
    ///   is written "during the next save operation" — and a save of a context with *no* object
    ///   changes does flush it, which was measured. Skipping the save because nothing looks dirty
    ///   is therefore how the ledger silently fails to persist, and the migration runs again on
    ///   the next launch.
    ///
    ///   Doing it in the same save as the migration's own work is what makes the pair atomic: the
    ///   data change and the record that it happened land together or not at all.
    static func record(
        _ version: Int,
        for modelIdentifier: String,
        in coordinator: NSPersistentStoreCoordinator,
        saving context: NSManagedObjectContext
    ) throws {
        let store = try store(in: coordinator)

        var metadata = coordinator.metadata(for: store)
        var applied = metadata[metadataKey] as? [String: Int] ?? [:]
        applied[modelIdentifier] = version
        metadata[metadataKey] = applied

        coordinator.setMetadata(metadata, for: store)
        try context.save()
    }

    // MARK: Helpers

    /// The store the ledger is kept in.
    ///
    /// `ContextProvider` installs exactly one store description, so there is exactly one store.
    private static func store(in coordinator: NSPersistentStoreCoordinator) throws -> NSPersistentStore {
        guard let store = coordinator.persistentStores.first else {
            throw DatabaseError.invalidMigrationPlan(
                "The container has no persistent store, so there is nowhere to record the migration ledger."
            )
        }

        return store
    }
}
