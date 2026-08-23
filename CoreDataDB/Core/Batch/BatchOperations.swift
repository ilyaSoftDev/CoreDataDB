//
//  BatchOperations.swift
//  DatabaseLayer
//

import CoreData
import Foundation

// MARK: - BatchResult

/// What a batch request touched.
public struct BatchResult: Sendable {

    /// How many rows the store reported changed.
    public let affectedCount: Int

    /// The rows themselves. `NSManagedObjectID` is `NS_SWIFT_SENDABLE`, so these are the one
    /// piece of a batch operation that may legally leave the context.
    public let objectIDs: [NSManagedObjectID]

    static let empty = BatchResult(objectIDs: [])

    init(objectIDs: [NSManagedObjectID]) {
        self.affectedCount = objectIDs.count
        self.objectIDs = objectIDs
    }
}

// MARK: - DatabaseClient + DatabaseBatchActions

extension DatabaseClient: DatabaseBatchActions {

    // MARK: Insert

    /// Streams rows straight into the store.
    ///
    /// `provider` is pulled once per row and nothing is kept between calls, so inserting a
    /// million rows costs the same memory as inserting one.
    ///
    /// - Warning: This is **insert-or-ignore, not upsert**. A row whose identifier already
    ///   exists is silently dropped and the stored one survives untouched, so a batch insert is
    ///   *not* a replacement for Realm's `save(_:update: .modified)`. The context's merge policy
    ///   has no say — measured identical under `NSMergeByPropertyObjectTrumpMergePolicy` and
    ///   `NSOverwriteMergePolicy` — because the request never goes through a context. Use
    ///   `save(_:in:)` when the incoming values have to win, or `batchDelete` first.
    ///
    ///   Without a uniqueness constraint there is nothing to collide on and the duplicate is
    ///   simply appended; `ModelValidator` is what stops such a model being registered (D5).
    ///
    /// - Important: Bypasses validation, `willSave`/`didSave`, and inverse-relationship
    ///   maintenance. Relationships cannot be set this way at all — only attributes.
    /// - Parameter provider: Returns the attributes for row `index`, or `nil` to stop early.
    /// - Throws: `DatabaseError.batchUnsupported` unless the store is SQLite-backed.
    @discardableResult
    public func batchInsert<T: PersistableModel>(
        _ type: T.Type,
        count: Int,
        in context: DatabaseContext = .background,
        provider makeRow: @escaping @Sendable (Int) -> [String: any Sendable]?
    ) async throws -> BatchResult {
        try requireBatchSupport()
        guard count > 0 else { return .empty }

        let targets = provider.mergeTargets

        return try await withContext(context) { context in
            guard let entity = NSEntityDescription.entity(forEntityName: T.entityName, in: context) else {
                throw DatabaseError.entityNotFound(T.entityName)
            }

            var index = 0
            let request = NSBatchInsertRequest(entityName: T.entityName) { row in
                guard index < count, let values = makeRow(index) else { return true }

                #if DEBUG
                if index == 0 {
                    let problems = ModelValidator.attributeProblems(for: values, in: entity)
                    assert(
                        problems.isEmpty,
                        "batchInsert(\(T.self)) row 0 does not match '\(T.entityName)': "
                            + problems.joined(separator: " ")
                    )
                }
                #endif

                index += 1

                // Core Data is free to hand the same dictionary back for the next row, so a key
                // left over from the last one would leak into this one.
                row.removeAllObjects()
                for (key, value) in values {
                    row[key] = value
                }

                return false
            }
            request.resultType = .objectIDs

            let result = try context.execute(request) as? NSBatchInsertResult
            return Self.merge(result?.result, forKey: NSInsertedObjectsKey, into: targets)
        }
    }

    /// The convenience form. The array is the memory cost — prefer the streaming overload when
    /// the rows can be generated rather than collected.
    @discardableResult
    public func batchInsert<T: PersistableModel>(
        _ models: [T],
        in context: DatabaseContext = .background
    ) async throws -> BatchResult {
        try await batchInsert(T.self, count: models.count, in: context) { index in
            models[index].attributes
        }
    }

    // MARK: Update

    /// Sets `values` on every matching row, in the store.
    ///
    /// - Important: Bypasses validation, `willSave`/`didSave`, and inverse-relationship
    ///   maintenance. Objects already faulted into a live context are refreshed from the merged
    ///   object IDs rather than re-validated.
    /// - Throws: `DatabaseError.batchUnsupported` unless the store is SQLite-backed.
    @discardableResult
    public func batchUpdate<T: PersistableModel>(
        _ type: T.Type,
        matching predicate: sending NSPredicate? = nil,
        set values: [String: any Sendable],
        in context: DatabaseContext = .background
    ) async throws -> BatchResult {
        try requireBatchSupport()
        nonisolated(unsafe) let predicate = predicate

        let targets = provider.mergeTargets

        return try await withContext(context) { context in
            guard NSEntityDescription.entity(forEntityName: T.entityName, in: context) != nil else {
                throw DatabaseError.entityNotFound(T.entityName)
            }

            let request = NSBatchUpdateRequest(entityName: T.entityName)
            request.predicate = predicate
            request.propertiesToUpdate = values
            request.resultType = .updatedObjectIDsResultType

            let result = try context.execute(request) as? NSBatchUpdateResult
            return Self.merge(result?.result, forKey: NSUpdatedObjectsKey, into: targets)
        }
    }

    // MARK: Delete

    /// Deletes every matching row, in the store.
    ///
    /// - Important: Bypasses validation, `willSave`/`didSave`, and inverse-relationship
    ///   maintenance.
    /// - Note: Delete rules are the exception. The received wisdom — and this package's own
    ///   migration plan — is that a batch delete does not cascade; on the toolchain this was
    ///   written against (Xcode 26.6, macOS 26.5 / iOS 26.5 SDK) it **does**, and a `.nullify`
    ///   rule leaves the children alone while a `.cascade` rule takes them, which is exactly
    ///   the object-graph behaviour. `BatchTests` pins that down.
    ///
    ///   The package's deployment floor is iOS 18 / macOS 15, where this has not been measured.
    ///   Treat cascade-on-batch-delete as **unspecified** across the supported range: if the
    ///   graph matters, use `delete(_:matching:in:)`, which cascades by construction.
    /// - Throws: `DatabaseError.batchUnsupported` unless the store is SQLite-backed.
    @discardableResult
    public func batchDelete<T: PersistableModel>(
        _ type: T.Type,
        matching predicate: sending NSPredicate? = nil,
        in context: DatabaseContext = .background
    ) async throws -> BatchResult {
        try requireBatchSupport()
        nonisolated(unsafe) let predicate = predicate

        let targets = provider.mergeTargets

        return try await withContext(context) { context in
            guard NSEntityDescription.entity(forEntityName: T.entityName, in: context) != nil else {
                throw DatabaseError.entityNotFound(T.entityName)
            }

            let fetchRequest = NSFetchRequest<any NSFetchRequestResult>(entityName: T.entityName)
            fetchRequest.predicate = predicate

            let request = NSBatchDeleteRequest(fetchRequest: fetchRequest)
            request.resultType = .resultTypeObjectIDs

            let result = try context.execute(request) as? NSBatchDeleteResult
            return Self.merge(result?.result, forKey: NSDeletedObjectsKey, into: targets)
        }
    }
}

// MARK: - DatabaseClient + Batch helpers

extension DatabaseClient {

    /// Batch requests run as SQL against the store file. `NSInMemoryStoreType` has no file, so
    /// it cannot service any of them (D4).
    func requireBatchSupport() throws {
        guard provider.configuration.store.isSQLiteBacked else {
            throw DatabaseError.batchUnsupported
        }
    }

    /// Tells the live contexts about rows that changed behind their backs.
    ///
    /// Without this a batch operation is invisible to anything already in memory: `viewContext`
    /// keeps handing out the values it last saw, including rows that have been deleted.
    ///
    /// Posts `didMergeStoreChangesNotification` once the merge is in. Merging raises
    /// `NSManagedObjectContextObjectsDidChange` on the targets and nothing else — in particular
    /// no `didSave` — so an observer that only watches saves would never see a batch request.
    @discardableResult
    static func merge(
        _ result: Any?,
        forKey key: String,
        into targets: [NSManagedObjectContext]
    ) -> BatchResult {
        guard let objectIDs = result as? [NSManagedObjectID], !objectIDs.isEmpty else {
            return .empty
        }

        NSManagedObjectContext.mergeChanges(
            fromRemoteContextSave: [key: objectIDs],
            into: targets
        )

        NotificationCenter.default.post(
            name: didMergeStoreChangesNotification,
            object: nil,
            userInfo: [key: objectIDs]
        )

        return BatchResult(objectIDs: objectIDs)
    }
}

// MARK: - DatabaseClient + Batch notifications

extension DatabaseClient {

    /// Posted once a batch request's object IDs have been merged into the live contexts.
    ///
    /// A batch request writes straight to the store without going through a context save (G5),
    /// so it produces no `NSManagedObjectContext.didSaveObjectIDsNotification`. This is the only
    /// signal it gives off, and it is what lets a change observer see `batchInsert`,
    /// `batchUpdate`, `batchDelete`, and the fast path inside `deleteAll`.
    ///
    /// `object` is `nil`; every client in the process receives every post, so a subscriber that
    /// cares which store the rows came from should compare `NSManagedObjectID.persistentStore`.
    ///
    /// `userInfo` carries the affected `[NSManagedObjectID]` under exactly one of
    /// `NSInsertedObjectsKey`, `NSUpdatedObjectsKey` or `NSDeletedObjectsKey` — the same key the
    /// merge was performed with. Object IDs rather than objects, deliberately:
    /// `NSManagedObjectID` is `NS_SWIFT_SENDABLE` and a managed object is not, so this is the one
    /// shape of the payload a subscriber may legally read from another queue.
    ///
    /// - Note: The name is spelled `DatabaseLayer.` for consistency with the `Logger` subsystems
    ///   and the default `DatabaseConfiguration.name`. Unlike `MigrationLedger.metadataKey`, it is
    ///   never written to a store, so renaming it costs nothing beyond source compatibility.
    public static let didMergeStoreChangesNotification =
        Notification.Name("DatabaseLayer.didMergeStoreChanges")
}
