//
//  FetchRequestBuilder.swift
//  DatabaseLayer
//

import CoreData
import Foundation

// MARK: - FetchRequestBuilder

/// Turns a `PersistableModel` type plus the usual query parameters into an `NSFetchRequest`.
enum FetchRequestBuilder {

    // MARK: Requests

    /// A request for every row matching `predicate`.
    ///
    /// - Parameter batchSize: Left off by default, deliberately. `fetchBatchSize` makes the
    ///   result a faulting proxy array, which pays off only when the caller reads a fraction
    ///   of the rows — and every caller here maps *all* of them into DTOs, so batching would
    ///   just add round trips. It is exposed for the cases where a caller knows better.
    static func makeRequest<T: PersistableModel>(
        for type: T.Type,
        predicate: NSPredicate? = nil,
        sortDescriptors: [NSSortDescriptor] = [],
        limit: Int? = nil,
        batchSize: Int? = nil
    ) -> NSFetchRequest<T.Entity> {
        let request = NSFetchRequest<T.Entity>(entityName: T.entityName)
        request.predicate = predicate
        request.sortDescriptors = sortDescriptors.isEmpty ? nil : sortDescriptors

        if let limit {
            request.fetchLimit = limit
        }

        if let batchSize {
            request.fetchBatchSize = batchSize
        } else {
            // `init(managed:)` reads every attribute, so returning faults would mean a second
            // trip to the store for each row.
            request.returnsObjectsAsFaults = false
        }

        return request
    }

    /// A request for the single row whose identifier matches.
    static func makeRequest<T: PersistableModel>(
        for type: T.Type,
        identifier: T.Identifier
    ) -> NSFetchRequest<T.Entity> {
        makeRequest(for: type, predicate: identifierPredicate(for: type, identifier: identifier), limit: 1)
    }

    // MARK: Predicates

    /// Matches rows whose `identifierKey` equals `identifier`.
    ///
    /// Built out of expressions rather than `NSPredicate(format: "%K == %@", …)`. The format
    /// string takes its arguments as `CVarArg`, which silently misreads an `Int` as a pointer
    /// and refuses `UUID` outright. `NSExpression(forConstantValue:)` takes `Any?` and lets
    /// the ObjC bridge box the value — `UUID` to `NSUUID`, `Int` to `NSNumber`, and so on.
    static func identifierPredicate<T: PersistableModel>(
        for type: T.Type,
        identifier: T.Identifier
    ) -> NSPredicate {
        NSComparisonPredicate(
            leftExpression: NSExpression(forKeyPath: T.identifierKey),
            rightExpression: NSExpression(forConstantValue: identifier),
            modifier: .direct,
            type: .equalTo
        )
    }

    /// Matches rows whose `identifierKey` is any of `identifiers`.
    ///
    /// Phase 4's `save([T])` uses this to find the existing rows in one fetch rather than one
    /// per model.
    static func identifierPredicate<T: PersistableModel>(
        for type: T.Type,
        identifiers: some Collection<T.Identifier>
    ) -> NSPredicate {
        NSComparisonPredicate(
            leftExpression: NSExpression(forKeyPath: T.identifierKey),
            rightExpression: NSExpression(forConstantValue: Array(identifiers)),
            modifier: .direct,
            type: .in
        )
    }
}
