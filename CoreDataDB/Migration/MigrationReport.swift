//
//  MigrationReport.swift
//  DatabaseLayer
//

import Foundation

// MARK: - MigrationReport

/// What every model's data migration did, in the order they ran.
///
/// Returned from `MigrationFacade.migrate(container:)` and kept on `DatabaseClient` as
/// `migrationReport`. Under the default `MigrationPolicy.continueOnFailure` a failed migration
/// does *not* fail the client's initializer, so this is the only place it shows up — check
/// `failures` at launch and log or alert from it.
public struct MigrationReport: Sendable {

    // MARK: Outcome

    /// What happened to one model.
    public enum Outcome: Sendable {

        /// The ledger already recorded this version or higher, so nothing ran.
        ///
        /// `appliedVersion` is what the ledger holds, which may be *newer* than the migration
        /// that was offered — a store restored from a backup taken on a later build.
        case skipped(appliedVersion: Int)

        /// It ran, saved, and was recorded.
        case migrated(duration: Duration)

        /// `migrate(in:)` threw. Its context was discarded unsaved, so the model's data is
        /// untouched and the ledger still shows the previous version.
        case failed(any Error)
    }

    // MARK: Entry

    /// One model's line in the report.
    public struct Entry: Sendable {

        public let modelIdentifier: String

        /// The version the migration declared, not the one the ledger holds.
        public let version: Int

        public let outcome: Outcome
    }

    // MARK: Properties

    /// Every model the facade considered, in the order dependencies put them in.
    public let entries: [Entry]

    /// Nothing to migrate.
    public static let empty = MigrationReport(entries: [])

    // MARK: Init

    init(entries: [Entry]) {
        self.entries = entries
    }

    // MARK: Reading

    /// The entries that threw.
    public var failures: [Entry] {
        entries.filter { if case .failed = $0.outcome { true } else { false } }
    }

    /// The entries that did work — as opposed to being skipped.
    public var migrated: [Entry] {
        entries.filter { if case .migrated = $0.outcome { true } else { false } }
    }

    /// Whether every model came through.
    public var didSucceed: Bool {
        failures.isEmpty
    }

    /// The outcome for one model, or `nil` if it was not in the run.
    public subscript(modelIdentifier: String) -> Outcome? {
        entries.first { $0.modelIdentifier == modelIdentifier }?.outcome
    }
}

// MARK: - MigrationReport + CustomStringConvertible

extension MigrationReport: CustomStringConvertible {

    public var description: String {
        guard !entries.isEmpty else { return "MigrationReport: nothing to migrate" }

        let lines = entries.map { entry in
            switch entry.outcome {
            case .skipped(let appliedVersion):
                "  \(entry.modelIdentifier) v\(entry.version): skipped (ledger holds v\(appliedVersion))"
            case .migrated(let duration):
                "  \(entry.modelIdentifier) v\(entry.version): migrated in \(duration)"
            case .failed(let error):
                "  \(entry.modelIdentifier) v\(entry.version): failed — \(error.localizedDescription)"
            }
        }

        return (["MigrationReport (\(entries.count) model(s), \(failures.count) failed):"] + lines)
            .joined(separator: "\n")
    }
}

// MARK: - MigrationProgress

/// A migration starting or finishing, for hosts that show UI instead of a spinner.
///
/// Obtain a stream from `MigrationFacade.progress()`, or hand `DatabaseClient.init` a callback.
public struct MigrationProgress: Sendable {

    // MARK: Phase

    public enum Phase: Sendable {
        case started
        case finished(MigrationReport.Outcome)
    }

    // MARK: Properties

    public let modelIdentifier: String

    public let version: Int

    public let phase: Phase

    /// How many models have finished, this one included once `phase` is `.finished`.
    public let completed: Int

    /// How many models are in the run.
    public let total: Int

    // MARK: Reading

    /// `0...1`, and `1` for an empty run.
    public var fractionCompleted: Double {
        guard total > 0 else { return 1 }
        return Double(completed) / Double(total)
    }
}
