//
//  StoreChangeNotifications.swift
//  DatabaseLayer
//

import Combine
import CoreData
import Foundation

// See DatabaseCombineProxy.swift. This file additionally needs `DatabaseClient.storeIdentifier`,
// which is SPI rather than public API, so it names the SPI group. In a single-module build the
// same property is reached as plain internal access and this import does not exist.
#if COREDATADB_MODULAR
@_spi(CoreDataDBTiers) import CoreDataDB
#endif

// MARK: - StoreChangeNotifications

/// Turns Core Data's change notifications into a signal that says "rows of this entity moved".
///
/// This is the half of `observe` that decides *when* to re-read. It never decides *what* changed:
/// the payload is discarded and the observation re-fetches, which is both simpler and consistent
/// with the snapshot semantics `fetch` already has.
///
/// Two sources, because Core Data has two ways for rows to move and they share no notification:
///
/// - **Context saves.** `NSManagedObjectContext.didSaveObjectIDsNotification`, raised by whichever
///   context committed — `.main`, `.background` or a `.detached` one. Sibling contexts merge the
///   save (`automaticallyMergesChangesFromParent`) and raise `objectsDidChange` rather than a
///   second `didSave`, so there is exactly one notification per save, not one per live context.
/// - **Batch merges.** `DatabaseClient.didMergeStoreChangesNotification`, which the batch tier
///   posts for itself. `NSBatch*Request` goes straight to the store and never reaches a context
///   (G5), so it raises no `didSave` at all and a saves-only observer would miss every
///   `batchInsert`, `batchUpdate`, `batchDelete`, and the fast path inside `deleteAll`.
enum StoreChangeNotifications {

    // MARK: Keys

    /// `didSaveObjectIDsNotification`'s payload keys.
    ///
    /// `refreshed` and `invalidated` are in here alongside the three obvious ones because a merge
    /// arriving from another context reaches live rows that way — a refreshed row is one whose
    /// values just changed underneath a reader, which is precisely what an observer wants to know.
    static let savedObjectIDKeys = [
        NSInsertedObjectIDsKey,
        NSUpdatedObjectIDsKey,
        NSDeletedObjectIDsKey,
        NSRefreshedObjectIDsKey,
        NSInvalidatedObjectIDsKey
    ]

    /// `didMergeStoreChangesNotification`'s payload keys — the ones `merge(_:forKey:into:)` posts.
    static let mergedObjectIDKeys = [
        NSInsertedObjectsKey,
        NSUpdatedObjectsKey,
        NSDeletedObjectsKey
    ]

    // MARK: Filtering

    /// Whether `notification` reports a change to `entityName` in the store identified by `storeID`.
    ///
    /// Both notifications carry `NSManagedObjectID`s rather than managed objects, which is what
    /// makes this readable at all from wherever the notification happens to be delivered.
    /// `NSManagedObjectID` is `NS_SWIFT_SENDABLE` and `NSEntityDescription` is frozen once a
    /// coordinator picks the model up; `didSaveObjectsNotification`, by contrast, hands over live
    /// `NSManagedObject`s, and reading `.entity.name` off the owning context's queue is exactly
    /// what `-com.apple.CoreData.ConcurrencyDebug 1` traps on.
    ///
    /// - Note: The match is allowed to be approximate in the false-positive direction. An extra
    ///   signal costs one re-fetch, and `observe`'s `removeDuplicates()` then swallows the
    ///   identical result, so nothing reaches the subscriber. A false *negative* would be a
    ///   missed update, which is why the entity check walks the inheritance chain and why the
    ///   store check is skipped when either side is unknown.
    static func notification(
        _ notification: Notification,
        touches entityName: String,
        inStore storeID: ObjectIdentifier?,
        keys: [String]
    ) -> Bool {
        guard let userInfo = notification.userInfo else { return false }

        for key in keys {
            // `didSave` posts a `Set`, the batch tier posts an `Array`.
            let objectIDs: [NSManagedObjectID]

            switch userInfo[key] {
            case let set as Set<NSManagedObjectID>: objectIDs = Array(set)
            case let array as [NSManagedObjectID]: objectIDs = array
            default: continue
            }

            for objectID in objectIDs where entity(objectID.entity, isOrInherits: entityName) {
                guard let storeID else { return true }
                guard let owner = objectID.persistentStore else { return true }

                if ObjectIdentifier(owner) == storeID { return true }
            }
        }

        return false
    }

    /// Whether `entity` is `name`, or descends from it.
    ///
    /// A fetch against a parent entity returns its subentities' rows, so a save of `Dog` has to
    /// wake an observer of `Animal`. Comparing `entity.name` alone would not.
    private static func entity(_ entity: NSEntityDescription, isOrInherits name: String) -> Bool {
        var current: NSEntityDescription? = entity

        while let candidate = current {
            if candidate.name == name { return true }
            current = candidate.superentity
        }

        return false
    }
}

// MARK: - DatabaseCombineProxy + Store changes

extension DatabaseCombineProxy {

    /// Fires whenever rows of `entityName` move in this client's store. Never fails, never finishes.
    ///
    /// The store is identified by `ObjectIdentifier` rather than by holding the
    /// `NSPersistentStore` itself: the returned publisher can outlive the client that made it, and
    /// there is no reason for a subscription to keep Core Data's internals alive. Identity is all
    /// this needs — the store is never dereferenced.
    func storeChanges(for entityName: String) -> AnyPublisher<Void, Never> {
        let center = NotificationCenter.default

        // Exactly one description is installed by `ContextProvider`, so there is exactly one store.
        let storeID = client.storeIdentifier

        let saves = center
            .publisher(for: NSManagedObjectContext.didSaveObjectIDsNotification)
            .filter {
                StoreChangeNotifications.notification(
                    $0,
                    touches: entityName,
                    inStore: storeID,
                    keys: StoreChangeNotifications.savedObjectIDKeys
                )
            }

        let batches = center
            .publisher(for: DatabaseClient.didMergeStoreChangesNotification)
            .filter {
                StoreChangeNotifications.notification(
                    $0,
                    touches: entityName,
                    inStore: storeID,
                    keys: StoreChangeNotifications.mergedObjectIDKeys
                )
            }

        return saves
            .merge(with: batches)
            .map { _ in () }
            .eraseToAnyPublisher()
    }
}
