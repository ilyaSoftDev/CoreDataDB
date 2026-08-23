//
//  ModelValidator.swift
//  DatabaseLayer
//

import CoreData
import Foundation
import os

private let logger = Logger(subsystem: "DatabaseLayer", category: "ModelValidator")

// MARK: - ModelValidator

/// Checks that the host app's schema can actually service the models registered against it.
///
/// The package ships no model of its own (D1), so every assumption the API makes about the
/// schema is unverified until something opens a store. These checks turn what would be a
/// crash deep inside Core Data — or worse, a silent duplicate row — into a message naming the
/// entity and the attribute.
enum ModelValidator {

    // MARK: Schema

    /// Validates every registered model against the schema. Called once, as the store opens.
    ///
    /// Debug builds throw on the first problem, so a misconfigured model fails loudly during
    /// development. Release builds log and carry on: a shipped app should not refuse to start
    /// over a check like this.
    static func validate(
        _ types: [any PersistableModel.Type],
        against model: NSManagedObjectModel
    ) throws {
        for type in types {
            do {
                try check(type, against: model)
            } catch {
                #if DEBUG
                throw error
                #else
                logger.error("\(error.localizedDescription, privacy: .public)")
                #endif
            }
        }
    }

    private static func check<T: PersistableModel>(
        _ type: T.Type,
        against model: NSManagedObjectModel
    ) throws {
        guard let entity = model.entitiesByName[T.entityName] else {
            throw DatabaseError.entityNotFound(T.entityName)
        }

        // A fetch request is generic over `T.Entity`, so a mismatch here traps on the cast
        // rather than returning an empty result.
        if let entityClass = NSClassFromString(entity.managedObjectClassName), !(entityClass is T.Entity.Type) {
            throw DatabaseError.invalidModel(
                "'\(T.entityName)' is backed by \(entityClass), which is not a \(T.Entity.self). "
                    + "Fetching it as \(T.Entity.self) would trap."
            )
        }

        guard entity.attributesByName[T.identifierKey] != nil else {
            throw DatabaseError.invalidModel(
                "'\(T.entityName)' has no attribute named '\(T.identifierKey)', "
                    + "which \(T.self) uses as its identifier."
            )
        }

        guard T.requiresUniqueIdentifier else { return }

        guard uniquenessConstraints(of: entity).contains([T.identifierKey]) else {
            throw DatabaseError.invalidModel(
                "'\(T.entityName)' has no uniqueness constraint on '\(T.identifierKey)'. Without one, "
                    + "save inserts a duplicate row instead of upserting it (D5). Set "
                    + "requiresUniqueIdentifier to false if \(T.self) is never saved."
            )
        }
    }

    /// The entity's uniqueness constraints, as sets of attribute names, including those it
    /// inherits from its super-entities.
    ///
    /// Core Data types the constraints as `[[Any]]`, whose elements are either attribute names
    /// or the attribute descriptions themselves depending on how the model was built.
    private static func uniquenessConstraints(of entity: NSEntityDescription) -> Set<Set<String>> {
        let inheritanceChain = sequence(first: entity, next: \.superentity)

        return Set(
            inheritanceChain.flatMap(\.uniquenessConstraints).map { constraint in
                Set(
                    constraint.compactMap { element in
                        (element as? NSAttributeDescription)?.name ?? element as? String
                    }
                )
            }
        )
    }

    // MARK: Batch attributes

    /// Everything wrong with `value.attributes` relative to the entity it will be written to.
    /// Empty when the dictionary is usable for a batch insert.
    static func attributeProblems<T: PersistableModel>(
        for value: T,
        in entity: NSEntityDescription
    ) -> [String] {
        attributeProblems(for: value.attributes, in: entity)
    }

    /// The same check against a raw dictionary, for the streaming batch insert, which never
    /// sees a model instance.
    static func attributeProblems(
        for attributes: [String: any Sendable],
        in entity: NSEntityDescription
    ) -> [String] {
        let entityName = entity.name ?? "?"
        let schema = entity.attributesByName
        let provided = Set(attributes.keys)
        var problems: [String] = []

        for key in provided.sorted() where schema[key] == nil {
            problems.append("'\(key)' is not an attribute of '\(entityName)'.")
        }

        // A batch insert cannot fall back on a default that does not exist, so an omitted
        // required attribute fails the whole request.
        for name in schema.keys.sorted() {
            guard let attribute = schema[name],
                  !attribute.isOptional,
                  !attribute.isTransient,
                  attribute.defaultValue == nil,
                  !provided.contains(name)
            else { continue }

            problems.append("'\(name)' is required and has no default, but attributes omits it.")
        }

        return problems
    }

    /// Debug-only cross-check, compiled out of release builds.
    ///
    /// Phase 5 calls this once per batch request: a wrong key or a missing required attribute
    /// otherwise surfaces as an opaque failure from inside `NSBatchInsertRequest`.
    static func assertAttributesMatchSchema<T: PersistableModel>(_ value: T, in entity: NSEntityDescription) {
        #if DEBUG
        let problems = attributeProblems(for: value, in: entity)
        assert(
            problems.isEmpty,
            "\(T.self).attributes does not match '\(entity.name ?? "?")': \(problems.joined(separator: " "))"
        )
        #endif
    }
}
