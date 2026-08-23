//
//  DatabaseCombineProxy.swift
//  DatabaseLayer
//

import Combine
import CoreData
import Foundation

// The Combine tier is its own module — `CoreDataDBCombine` — only under Swift Package Manager.
// CocoaPods and the Xcode framework target compile it into `CoreDataDB` itself, where importing
// the module being compiled is a warning and the declarations below are reachable already.
// COREDATADB_MODULAR is defined by the SPM target alone; see Package.swift.
//
// Re-exported so that one `import CoreDataDBCombine` brings `DatabaseClient` and the rest of the
// async tier with it. Everything here is an extension of that tier or takes it as a parameter, so
// a consumer of this module always needs both, and making them write two imports would be a
// difference from the pod for no benefit.
#if COREDATADB_MODULAR
@_exported import CoreDataDB
#endif

// MARK: - DatabaseCombineProxy

/// The Combine tier: every `DatabaseActions` operation as a publisher, plus the live `observe`
/// publishers the async tier has no equivalent for.
///
/// Reached through `DatabaseClient.combine` rather than spelled onto the client directly, for the
/// same reason `DatabaseBatchActions` is a separate protocol (D4): the tiers differ in ways a
/// caller has to know about, and a namespace makes the boundary something you cross on purpose.
///
/// ```swift
/// client.combine
///     .observe(Note.self, sortedBy: [byDate])
///     .receive(on: DispatchQueue.main)
///     .replaceError(with: [])
///     .assign(to: &$notes)
/// ```
///
/// Three things carry over from `DatabaseTaskPublisher` and apply to everything here:
///
/// - **Publishers are cold.** Nothing runs until something subscribes and asks for a value, so a
///   publisher built and dropped has performed no work — including a write.
/// - **Writes commit; reads cancel.** Cancelling a `save`, `update`, `delete` or `deleteAll`
///   subscription detaches the subscriber and lets the write finish, so the usual mistake of
///   discarding the `AnyCancellable` returned by `sink` does not silently swallow it. Reads
///   cancel their `Task`.
/// - **Values arrive on no particular queue.** Not the main queue, even for `DatabaseContext.main`.
///   `receive(on:)` before binding to UI.
///
/// `Failure` is `any Error` throughout, mirroring what the `async throws` methods actually throw.
public struct DatabaseCombineProxy: Sendable {

    // MARK: Properties

    let client: DatabaseClient

    // MARK: Init

    init(client: DatabaseClient) {
        self.client = client
    }
}

// MARK: - DatabaseClient + Combine

extension DatabaseClient {

    /// The Combine tier. See `DatabaseCombineProxy`.
    ///
    /// A fresh value each time, and deliberately cheap: it holds nothing but the client, so
    /// there is no reason to store one.
    public var combine: DatabaseCombineProxy {
        DatabaseCombineProxy(client: self)
    }
}

// MARK: - DatabaseCombineProxy + Create and upsert

extension DatabaseCombineProxy {

    /// `DatabaseClient.save(_:in:)` as a publisher. Emits once, then finishes.
    ///
    /// - Important: Commits even if the subscription is cancelled first. See the type's note.
    public func save<T: PersistableModel>(
        _ model: T,
        in context: DatabaseContext = .background
    ) -> AnyPublisher<Void, any Error> {
        let client = client

        return DatabaseTaskPublisher.write {
            try await client.save(model, in: context)
        }
        .eraseToAnyPublisher()
    }

    /// The same, for many models, in one fetch and one save.
    public func save<T: PersistableModel>(
        _ models: [T],
        in context: DatabaseContext = .background
    ) -> AnyPublisher<Void, any Error> {
        let client = client

        return DatabaseTaskPublisher.write {
            try await client.save(models, in: context)
        }
        .eraseToAnyPublisher()
    }
}

// MARK: - DatabaseCombineProxy + Read

extension DatabaseCombineProxy {

    /// `DatabaseClient.fetch(_:matching:sortedBy:limit:in:)` as a publisher.
    ///
    /// One snapshot, then `.finished` — `observe(_:matching:sortedBy:limit:in:)` is the form that
    /// keeps emitting.
    ///
    /// - Parameter predicate: `sending`, as on the async tier: handing it over means the caller
    ///   must not go on using it. Note that a publisher may be subscribed more than once, and
    ///   every subscription reads the same predicate — which is exactly what `sending` already
    ///   promises is safe, since the caller gave it up.
    public func fetch<T: PersistableModel>(
        _ type: T.Type,
        matching predicate: sending NSPredicate? = nil,
        sortedBy sortDescriptors: sending [NSSortDescriptor] = [],
        limit: Int? = nil,
        in context: DatabaseContext = .main
    ) -> AnyPublisher<[T], any Error> {
        nonisolated(unsafe) let predicate = predicate
        nonisolated(unsafe) let sortDescriptors = sortDescriptors
        let client = client

        return DatabaseTaskPublisher.read {
            try await client.fetch(
                T.self,
                matching: predicate,
                sortedBy: sortDescriptors,
                limit: limit,
                in: context
            )
        }
        .eraseToAnyPublisher()
    }

    /// The single row carrying `identifier`, or `nil`.
    public func fetch<T: PersistableModel>(
        _ type: T.Type,
        identifier: T.Identifier,
        in context: DatabaseContext = .main
    ) -> AnyPublisher<T?, any Error> {
        let client = client

        return DatabaseTaskPublisher.read {
            try await client.fetch(T.self, identifier: identifier, in: context)
        }
        .eraseToAnyPublisher()
    }

    /// How many rows match, counted in the store without materializing any of them.
    public func count<T: PersistableModel>(
        _ type: T.Type,
        matching predicate: sending NSPredicate? = nil,
        in context: DatabaseContext = .main
    ) -> AnyPublisher<Int, any Error> {
        nonisolated(unsafe) let predicate = predicate
        let client = client

        return DatabaseTaskPublisher.read {
            try await client.count(T.self, matching: predicate, in: context)
        }
        .eraseToAnyPublisher()
    }
}

// MARK: - DatabaseCombineProxy + Update

extension DatabaseCombineProxy {

    /// `DatabaseClient.update(_:identifier:in:mutate:)` as a publisher.
    ///
    /// - Important: Commits even if the subscription is cancelled first.
    /// - Note: Fails with `DatabaseError.objectNotFound` when no row carries `identifier`, exactly
    ///   as the async form throws. Nothing here silently succeeds.
    public func update<T: PersistableModel>(
        _ type: T.Type,
        identifier: T.Identifier,
        in context: DatabaseContext = .background,
        mutate: @escaping @Sendable (inout T) throws -> Void
    ) -> AnyPublisher<Void, any Error> {
        let client = client

        return DatabaseTaskPublisher.write {
            try await client.update(T.self, identifier: identifier, in: context, mutate: mutate)
        }
        .eraseToAnyPublisher()
    }
}

// MARK: - DatabaseCombineProxy + Delete

extension DatabaseCombineProxy {

    /// Deletes the row carrying `identifier`, if there is one.
    ///
    /// Idempotent, like the async form: deleting nothing is not an error.
    ///
    /// - Important: Commits even if the subscription is cancelled first.
    public func delete<T: PersistableModel>(
        _ type: T.Type,
        identifier: T.Identifier,
        in context: DatabaseContext = .background
    ) -> AnyPublisher<Void, any Error> {
        let client = client

        return DatabaseTaskPublisher.write {
            try await client.delete(T.self, identifier: identifier, in: context)
        }
        .eraseToAnyPublisher()
    }

    /// Deletes every row matching `predicate`, through the object graph, so delete rules cascade.
    ///
    /// - Important: Commits even if the subscription is cancelled first.
    public func delete<T: PersistableModel>(
        _ type: T.Type,
        matching predicate: sending NSPredicate,
        in context: DatabaseContext = .background
    ) -> AnyPublisher<Void, any Error> {
        nonisolated(unsafe) let predicate = predicate
        let client = client

        return DatabaseTaskPublisher.write {
            try await client.delete(T.self, matching: predicate, in: context)
        }
        .eraseToAnyPublisher()
    }

    /// Empties every entity in the model.
    ///
    /// - Important: Commits even if the subscription is cancelled first.
    public func deleteAll() -> AnyPublisher<Void, any Error> {
        let client = client

        return DatabaseTaskPublisher.write {
            try await client.deleteAll()
        }
        .eraseToAnyPublisher()
    }
}
