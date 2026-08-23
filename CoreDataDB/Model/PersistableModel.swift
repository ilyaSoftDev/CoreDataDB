//
//  PersistableModel.swift
//  DatabaseLayer
//

import CoreData
import Foundation

// MARK: - PersistableModel

/// A `Sendable` value that knows how to read from and write to its managed object.
///
/// D2: DTOs are the currency of the API, and managed objects are the escape hatch.
/// `NSManagedObject` is `NS_SWIFT_NONSENDABLE`, so under Swift 6 an object that escapes the
/// context it was fetched on is a compile error rather than a runtime surprise. Conforming
/// types cross isolation domains freely; the objects they were built from never leave a
/// `perform` block.
///
/// The Realm implementation had no equivalent: it handed back live, thread-confined `Object`
/// references and relied on callers to stay on the main thread.
public protocol PersistableModel: Sendable, Hashable {

    /// The managed object class this model maps to. Use `NSManagedObject` itself when the
    /// entity has no generated subclass.
    associatedtype Entity: NSManagedObject

    /// The type of `identifierKey`'s attribute — typically `UUID`, `String`, or `Int`.
    ///
    /// Unlike the plan's sketch this is not constrained to `CVarArg`: `UUID` does not conform
    /// to it, which would rule out the most natural Core Data identifier. Predicates are built
    /// structurally instead of through format strings, so no such constraint is needed.
    associatedtype Identifier: Hashable & Sendable

    /// The entity's name in the model. Defaults to the `Entity` class's name.
    static var entityName: String { get }

    /// The attribute holding the identifier.
    static var identifierKey: String { get }

    /// Whether `identifierKey` must carry a uniqueness constraint.
    ///
    /// D5: Core Data spells Realm's `UpdatePolicy.modified` as a unique constraint plus
    /// `NSMergeByPropertyObjectTrumpMergePolicy`. Without the constraint `save` inserts
    /// duplicates instead of upserting, so the constraint is checked when the store opens.
    /// Set this to `false` for an append-only entity that is never upserted.
    static var requiresUniqueIdentifier: Bool { get }

    /// The value of `identifierKey` for this instance.
    var identifier: Identifier { get }

    /// Reads every persisted value out of `managed`.
    ///
    /// - Important: Called inside a `perform` block. Do not let `managed`, or anything
    ///   reachable from it, escape into the returned value.
    init(managed: Entity) throws

    /// Writes every persisted value into `managed`.
    ///
    /// - Important: Called inside a `perform` block on the context that owns `managed`.
    func encode(into managed: Entity)

    /// The attribute dictionary the batch tier writes straight to the store.
    ///
    /// Keys must name attributes of the entity; values must be types Core Data can store.
    /// Omit a key to leave the attribute at its default. There is no default implementation
    /// because a wrong dictionary here fails deep inside Core Data — `ModelValidator`
    /// cross-checks it against the schema in debug builds.
    var attributes: [String: any Sendable] { get }
}

// MARK: - PersistableModel + Defaults

extension PersistableModel {

    public static var entityName: String {
        String(describing: Entity.self)
    }

    public static var requiresUniqueIdentifier: Bool {
        true
    }
}
