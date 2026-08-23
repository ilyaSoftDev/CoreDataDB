//
//  DatabaseActions.swift
//  DatabaseLayer
//

import CoreData
import Foundation

// MARK: - DatabaseActions

/// The object-graph tier: create, read, update and delete, one model at a time.
///
/// Every method is `async throws`, as on the Realm facade, but the shape differs in three ways
/// that the Swift 6 model forces or the Realm implementation got wrong:
///
/// - Models are `Sendable` DTOs rather than live, thread-confined objects (D2).
/// - `NSPredicate` and `NSSortDescriptor` are not `Sendable`, so they are `sending`: passing one
///   hands it over, and the caller must not go on using it.
/// - Nothing silently succeeds. A write that finds no row throws instead of no-op'ing, and a
///   write issued while another is in flight queues behind it instead of being dropped.
///
/// The conforming type declares these with default arguments — reads default to
/// `DatabaseContext.main`, writes to `.background` — which a protocol requirement cannot carry.
public protocol DatabaseActions: Sendable {

    // MARK: Create and upsert

    /// Inserts the model, or overwrites the row that already carries its identifier.
    ///
    /// This is Realm's `UpdatePolicy.modified` spelled in Core Data: the row is found by
    /// identifier and rewritten. Its **unique constraint** is what keeps a concurrent writer
    /// from landing a duplicate (D5), which is why `ModelValidator` insists on one.
    func save<T: PersistableModel>(_ model: T, in context: DatabaseContext) async throws

    /// The same, for many models, in one fetch and one save.
    func save<T: PersistableModel>(_ models: [T], in context: DatabaseContext) async throws

    // MARK: Read

    /// Every row matching `predicate`, as DTOs.
    ///
    /// A snapshot, not a live collection — the same semantic the Realm `fetch` had, since it
    /// already materialized `Array(realm.objects(type))`.
    func fetch<T: PersistableModel>(
        _ type: T.Type,
        matching predicate: sending NSPredicate?,
        sortedBy sortDescriptors: sending [NSSortDescriptor],
        limit: Int?,
        in context: DatabaseContext
    ) async throws -> [T]

    /// The single row carrying `identifier`, or `nil`.
    func fetch<T: PersistableModel>(
        _ type: T.Type,
        identifier: T.Identifier,
        in context: DatabaseContext
    ) async throws -> T?

    /// How many rows match, counted in the store without materializing any of them.
    func count<T: PersistableModel>(
        _ type: T.Type,
        matching predicate: sending NSPredicate?,
        in context: DatabaseContext
    ) async throws -> Int

    // MARK: Update

    /// Reads the row into a DTO, hands it to `mutate`, and writes it back.
    ///
    /// - Throws: `DatabaseError.objectNotFound` when no row carries `identifier`. The Realm
    ///   `update(updatesClosure:)` could not fail, and did nothing at all if a write happened
    ///   to be in flight.
    func update<T: PersistableModel>(
        _ type: T.Type,
        identifier: T.Identifier,
        in context: DatabaseContext,
        mutate: @escaping @Sendable (inout T) throws -> Void
    ) async throws

    // MARK: Delete

    /// Deletes the row carrying `identifier`, if there is one.
    ///
    /// Idempotent, deliberately: a delete's postcondition is that the row is gone, and it
    /// already holds when there was nothing to delete. This is the one place the API does not
    /// mirror `update`'s `objectNotFound`.
    func delete<T: PersistableModel>(
        _ type: T.Type,
        identifier: T.Identifier,
        in context: DatabaseContext
    ) async throws

    /// Deletes every row matching `predicate`.
    ///
    /// Goes through the object graph, so delete rules **do** cascade. Phase 5's `batchDelete`
    /// is the fast path that does not.
    func delete<T: PersistableModel>(
        _ type: T.Type,
        matching predicate: sending NSPredicate,
        in context: DatabaseContext
    ) async throws

    /// Empties every entity in the model.
    func deleteAll() async throws
}

// MARK: - DatabaseBatchActions

/// The direct-to-store tier: requests that run as SQL against the store file without ever
/// loading a managed object (G5).
///
/// D4 keeps this a separate, clearly-labelled protocol because the speed is bought with real
/// losses. Every method here **bypasses**:
///
/// - validation, and `willSave` / `didSave`,
/// - inverse-relationship maintenance,
/// - the contexts themselves, which is why each method merges the object IDs it touched back
///   into the live ones.
///
/// Two behaviours differ from what this package's migration plan predicted, both measured on
/// Xcode 26.6 and pinned down by `BatchTests`:
///
/// - `batchInsert` is **insert-or-ignore, not upsert** — a row whose identifier already exists
///   is dropped and the stored one survives, whatever the merge policy says.
/// - `batchDelete` **does** honour delete rules here, though the deployment floor is older than
///   what was measured, so treat that as unspecified.
///
/// Every method needs a SQLite-backed store and throws `DatabaseError.batchUnsupported`
/// otherwise.
public protocol DatabaseBatchActions: Sendable {

    /// Streams `count` rows into the store, pulling one dictionary at a time.
    ///
    /// This is the path that never materializes the data: `provider` is called once per row and
    /// nothing is retained between calls. Return `nil` to stop early.
    ///
    /// - Warning: Insert-or-ignore, not upsert. See the implementation's note.
    func batchInsert<T: PersistableModel>(
        _ type: T.Type,
        count: Int,
        in context: DatabaseContext,
        provider: @escaping @Sendable (Int) -> [String: any Sendable]?
    ) async throws -> BatchResult

    /// The convenience form, built on the streaming one by indexing the array.
    ///
    /// The array is the memory cost here; reach for the streaming form when the rows can be
    /// generated instead of collected.
    func batchInsert<T: PersistableModel>(_ models: [T], in context: DatabaseContext) async throws -> BatchResult

    /// Sets `values` on every row matching `predicate`, in the store.
    func batchUpdate<T: PersistableModel>(
        _ type: T.Type,
        matching predicate: sending NSPredicate?,
        set values: [String: any Sendable],
        in context: DatabaseContext
    ) async throws -> BatchResult

    /// Deletes every row matching `predicate`, in the store.
    ///
    /// - Important: Whether delete rules apply is unspecified across the supported range. Use
    ///   `delete(_:matching:in:)` when the graph matters.
    func batchDelete<T: PersistableModel>(
        _ type: T.Type,
        matching predicate: sending NSPredicate?,
        in context: DatabaseContext
    ) async throws -> BatchResult
}
