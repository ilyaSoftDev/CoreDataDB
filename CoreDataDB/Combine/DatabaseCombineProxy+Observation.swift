//
//  DatabaseCombineProxy+Observation.swift
//  DatabaseLayer
//

import Combine
import CoreData
import Foundation

// See DatabaseCombineProxy.swift.
#if COREDATADB_MODULAR
import CoreDataDB
#endif

// MARK: - DatabaseCombineProxy + Observation

/// The live tier, and the reason this subspec exists.
///
/// `fetch` — in either calling convention — is a snapshot: it answers once and the answer starts
/// going stale immediately. Neither `DatabaseActions` nor the Realm facade it replaced had any way
/// to be told about a later change, so a host app either polled or wired an
/// `NSFetchedResultsController` through `withContext` by hand. These publishers close that gap.
///
/// An observation emits an initial snapshot on subscribe, then a fresh one whenever the rows it
/// covers move — from any context, from any of the three `DatabaseContext` kinds, and from the
/// batch tier. It never finishes on its own.
extension DatabaseCombineProxy {

    // MARK: Collections

    /// Every row matching `predicate`, re-emitted whenever the entity's rows change.
    ///
    /// ```swift
    /// client.combine
    ///     .observe(Note.self, matching: unread, sortedBy: [byDate])
    ///     .receive(on: DispatchQueue.main)
    ///     .replaceError(with: [])
    ///     .assign(to: &$notes)
    /// ```
    ///
    /// The pipeline is deliberately coarse: a change signal discards its payload and re-runs the
    /// whole fetch, rather than trying to patch the last result. That keeps each emission a
    /// consistent snapshot — the same contract `fetch` has — and it is what lets the change filter
    /// be approximate. Two operators pay for the coarseness:
    ///
    /// - `switchToLatest`, so a burst of writes cancels the fetches it overtook instead of queueing
    ///   one per notification. Safe precisely because read publishers cancel their work.
    /// - `removeDuplicates`, which costs nothing — `PersistableModel` refines `Hashable`, so `[T]`
    ///   is already `Equatable` — and means a change that does not affect this result set re-reads
    ///   the store but emits nothing downstream.
    ///
    /// - Important: An error **terminates the observation**, as it does for any Combine publisher;
    ///   there is no resubscription afterwards. Compose `retry(_:)` or `catch(_:)` in if the
    ///   stream has to survive a failed read.
    /// - Note: Emissions arrive on no particular queue — see `DatabaseCombineProxy`. `receive(on:)`
    ///   before binding to UI.
    /// - Parameter context: Where the *re-fetches* run, defaulting to `.main` since an observation
    ///   usually feeds the UI. Move it to `.background` when the result set is large enough that
    ///   reading it on the main queue would be felt.
    public func observe<T: PersistableModel>(
        _ type: T.Type,
        matching predicate: sending NSPredicate? = nil,
        sortedBy sortDescriptors: sending [NSSortDescriptor] = [],
        limit: Int? = nil,
        in context: DatabaseContext = .main
    ) -> AnyPublisher<[T], any Error> {
        // Handed over once and then read by every subscription and every re-fetch, which is what
        // `sending` already promises is safe: the caller gave it up.
        nonisolated(unsafe) let predicate = predicate
        nonisolated(unsafe) let sortDescriptors = sortDescriptors
        let proxy = self

        return storeChanges(for: T.entityName)
            // The initial snapshot. Without it a subscriber sees nothing until the first write.
            .prepend(())
            .setFailureType(to: (any Error).self)
            .map { _ in
                proxy.fetch(
                    T.self,
                    matching: predicate,
                    sortedBy: sortDescriptors,
                    limit: limit,
                    in: context
                )
            }
            .switchToLatest()
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    // MARK: Single rows

    /// The row carrying `identifier`, re-emitted whenever it changes, and `nil` once it is deleted.
    ///
    /// The single-row form of `observe(_:matching:sortedBy:limit:in:)`, with the same semantics.
    /// Note that it emits `nil` rather than failing when the row is not there — matching
    /// `fetch(_:identifier:in:)`, and unlike `update`, which throws `objectNotFound`. An
    /// observation of a row that does not exist yet is a reasonable thing to want.
    public func observe<T: PersistableModel>(
        _ type: T.Type,
        identifier: T.Identifier,
        in context: DatabaseContext = .main
    ) -> AnyPublisher<T?, any Error> {
        let proxy = self

        return storeChanges(for: T.entityName)
            .prepend(())
            .setFailureType(to: (any Error).self)
            .map { _ in
                proxy.fetch(T.self, identifier: identifier, in: context)
            }
            .switchToLatest()
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    // MARK: Counts

    /// How many rows match `predicate`, re-emitted whenever the entity's rows change.
    ///
    /// Counted in the store without materializing anything, so this is the cheap way to drive a
    /// badge or an empty-state check off a large entity.
    public func observeCount<T: PersistableModel>(
        _ type: T.Type,
        matching predicate: sending NSPredicate? = nil,
        in context: DatabaseContext = .main
    ) -> AnyPublisher<Int, any Error> {
        nonisolated(unsafe) let predicate = predicate
        let proxy = self

        return storeChanges(for: T.entityName)
            .prepend(())
            .setFailureType(to: (any Error).self)
            .map { _ in
                proxy.count(T.self, matching: predicate, in: context)
            }
            .switchToLatest()
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
}
