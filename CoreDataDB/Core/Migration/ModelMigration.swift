//
//  ModelMigration.swift
//  DatabaseLayer
//

import CoreData
import Foundation

// MARK: - ModelMigration

/// One model's data migration — the work that has to happen *after* the schema is in place
///
/// `SchemaMigrationPlan` moves the store from version to version. This moves the *data*: backfill
/// a column the schema change added, normalise a value, split a field into two. Each migration is
/// identified by a model and carries a version that goes up whenever it has new work to do, and
/// the `MigrationFacade` records the pair so it never runs twice.
///
/// ```swift
/// struct BackfillNoteSlugs: ModelMigration {
///     static let modelIdentifier = "Note"
///     static let version = 2
///
///     func migrate(in context: NSManagedObjectContext) throws {
///         for note in try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Note")) {
///             let title = note.value(forKey: "title") as? String ?? ""
///             note.setValue(title.lowercased(), forKey: "slug")
///         }
///     }
/// }
/// ```
public protocol ModelMigration: Sendable {

    /// Which model this migrates — conventionally the entity name.
    ///
    /// This is the ledger key, so it must stay stable across releases. Renaming it makes every
    /// past migration look unapplied and runs them all again.
    static var modelIdentifier: String { get }

    /// Monotonic per model. Raise it when this migration has new work to do.
    ///
    /// The facade skips the migration when the ledger already records this version or higher, so
    /// versions are what make a re-run a no-op.
    static var version: Int { get }

    /// Other `modelIdentifier`s that must be migrated before this one.
    ///
    /// Defaults to none. The facade topologically sorts on these, so a migration that reads a
    /// sibling model's freshly-migrated rows can say so instead of relying on array order.
    static var dependencies: [String] { get }

    /// Does the work, on a private-queue context of its own.
    ///
    /// - Important: Do **not** save the context. The facade saves once, after this returns, in
    ///   the same transaction that records the ledger entry — so the data change and "this
    ///   migration ran" either both land or neither does. Saving here splits them, and a crash in
    ///   between leaves a migration that ran but is not recorded.
    /// - Note: The context arrives with Core Data's default `NSErrorMergePolicy` rather than the
    ///   client's configured one. Migrations run before `DatabaseClient.init` returns, so there is
    ///   nothing to conflict with, and a conflict here should be reported rather than resolved.
    func migrate(in context: NSManagedObjectContext) throws
}

// MARK: - ModelMigration + Defaults

extension ModelMigration {

    public static var dependencies: [String] { [] }

    /// Instance-side mirrors, so `any ModelMigration` values read naturally at the call site
    /// instead of going through `type(of:)`.
    public var modelIdentifier: String { Self.modelIdentifier }

    public var version: Int { Self.version }

    public var dependencies: [String] { Self.dependencies }
}

// MARK: - MigrationPolicy

/// What the facade does when a model's migration throws.
public enum MigrationPolicy: Sendable {

    /// Run the rest anyway and collect the failures in the report.
    ///
    /// The default. Each migration has its own context and its own save, so a failure rolls back
    /// only its own work — the ones that already succeeded stay applied and stay recorded.
    case continueOnFailure

    /// Stop at the first failure and throw `DatabaseError.migrationFailed(model:underlying:)`.
    ///
    /// Everything up to that point is already committed and ledgered, so a later retry resumes
    /// from the failure rather than starting over.
    case stopOnFirstFailure
}

// MARK: - MigrationOrder

/// Orders migrations by their declared dependencies.
enum MigrationOrder {

    /// A topological sort, stable for migrations of equal rank.
    ///
    /// Kahn's algorithm run in *levels* rather than as a single queue: everything currently
    /// unblocked is emitted together, in the order the host app listed it, before anything those
    /// migrations unblock. So two migrations that do not depend on each other keep their listed
    /// order — which a plain queue would not guarantee, since a newly unblocked migration listed
    /// earlier would otherwise jump ahead of one that had been ready all along.
    ///
    /// A cycle leaves nodes with prerequisites nothing can satisfy, so the levels run dry with
    /// migrations left over. That is how it is detected.
    ///
    /// - Throws: `DatabaseError.invalidMigrationPlan` for a duplicate `modelIdentifier` or a
    ///   dependency cycle.
    static func sorted(_ migrations: [any ModelMigration]) throws -> [any ModelMigration] {
        guard migrations.count > 1 else { return migrations }

        var indexByIdentifier: [String: Int] = [:]

        for (index, migration) in migrations.enumerated() {
            guard indexByIdentifier.updateValue(index, forKey: migration.modelIdentifier) == nil else {
                throw DatabaseError.invalidMigrationPlan(
                    "Two migrations both claim the model identifier '\(migration.modelIdentifier)'. "
                        + "One migration per model — raise its version instead of adding a second."
                )
            }
        }

        // Only dependencies naming a migration in this run constrain the order. An unknown one is
        // legitimate: a host app may include migrations conditionally, and a model whose work is
        // already applied is still a name others depend on.
        var waitingOn: [Int: Set<Int>] = [:]
        var unlocks: [Int: [Int]] = [:]

        for (index, migration) in migrations.enumerated() {
            let prerequisites = Set(migration.dependencies.compactMap { indexByIdentifier[$0] }).subtracting([index])
            waitingOn[index] = prerequisites

            for prerequisite in prerequisites {
                unlocks[prerequisite, default: []].append(index)
            }
        }

        // `indices` is ascending, so every level below is emitted in the host app's order.
        var ready = migrations.indices.filter { waitingOn[$0]?.isEmpty ?? true }
        var ordered: [any ModelMigration] = []
        ordered.reserveCapacity(migrations.count)

        while !ready.isEmpty {
            var unblocked: [Int] = []

            for index in ready {
                ordered.append(migrations[index])

                for dependent in unlocks[index] ?? [] {
                    waitingOn[dependent]?.remove(index)

                    // Appended exactly once — at the prerequisite that empties the set.
                    if waitingOn[dependent]?.isEmpty == true {
                        unblocked.append(dependent)
                    }
                }
            }

            ready = unblocked.sorted()
        }

        guard ordered.count == migrations.count else {
            let stuck = migrations.indices
                .filter { index in !(waitingOn[index]?.isEmpty ?? true) }
                .map { migrations[$0].modelIdentifier }
                .sorted()

            throw DatabaseError.invalidMigrationPlan(
                "The migrations depend on each other in a cycle: \(stuck.joined(separator: ", "))."
            )
        }

        return ordered
    }
}
