//
//  SchemaMigrationPlan.swift
//  DatabaseLayer
//

import CoreData
import Foundation

// MARK: - SchemaMigrationPlan

/// The total ordering of model versions Core Data walks when it opens a store that was written
/// by an older schema (G6, phase 6a).
///
/// This is the *schema* half of the migration layer: it moves the store from version to version
/// and runs nothing else. Per-model data work belongs to `ModelMigration`, which the
/// `MigrationFacade` runs afterwards, against the migrated store.
///
/// A plan is installed on the store description before the store loads, so every stage has run
/// by the time `DatabaseClient.init` returns. Supply one through
/// `DatabaseConfiguration.MigrationBehavior.staged(_:)`; without one the store falls back to
/// `.lightweight` inference, which is the zero-configuration behaviour the Realm implementation
/// had.
///
/// ### The one rule
///
/// **Every model version must be claimed by exactly one stage** — with a single exception: two
/// adjacent custom stages may share the version between them (one's `to` is the next's `from`).
/// A lightweight stage lists the checksums of the versions it covers; a custom stage names the
/// version it migrates from and the one it migrates to.
///
/// Getting this wrong is unusually expensive, which is why `makeManager()` checks it:
///
/// - A version claimed twice raises `NSInvalidArgumentException` ("Duplicate version checksums
///   across stages detected") from `NSStagedMigrationManager`'s initializer. That is an
///   Objective-C exception thrown from an initializer, so Swift **cannot catch it** and the host
///   app dies. `validate()` finds it first and throws `DatabaseError.invalidMigrationPlan`.
/// - A version claimed by no stage is a catchable `NSCocoaErrorDomain` 134504, "Cannot use staged
///   migration with an unknown model version", raised when the store loads. Nothing here can
///   predict it, since the missing version is whatever is on the user's disk.
public struct SchemaMigrationPlan: Sendable {

    // MARK: ModelVersion

    /// One model version in the ordering, paired with the checksum that identifies it.
    ///
    /// The checksum is not decoration: `NSManagedObjectModelReference` requires one, and Core
    /// Data matches the store's recorded version against it to decide where in the ordering to
    /// start. Get it from `SchemaMigrationPlan.checksum(of:)` or
    /// `checksums(ofVersionedModelAt:)` and paste it in as a literal — it is a build-time
    /// constant of a model version that, by definition, never changes again.
    public struct ModelVersion: Sendable {

        /// How the model is produced.
        ///
        /// A closure rather than an `NSManagedObjectModel` for the same reason
        /// `DatabaseConfiguration.ModelSource` is one: the class is not `Sendable`, and it is
        /// genuinely mutable until a coordinator freezes it.
        enum Source: Sendable {
            case model(@Sendable () throws -> NSManagedObjectModel)
            case named(String, bundle: Bundle)
            case fileURL(URL)
        }

        /// The model's `versionChecksum`.
        public let checksum: String

        let source: Source

        /// A version built in code.
        public static func model(
            checksum: String,
            _ build: @escaping @Sendable () throws -> NSManagedObjectModel
        ) -> Self {
            Self(checksum: checksum, source: .model(build))
        }

        /// A compiled version looked up by name — the `.mom` inside a versioned `.momd`.
        public static func named(_ name: String, in bundle: Bundle, checksum: String) -> Self {
            Self(checksum: checksum, source: .named(name, bundle: bundle))
        }

        /// A compiled version at a URL.
        public static func fileURL(_ url: URL, checksum: String) -> Self {
            Self(checksum: checksum, source: .fileURL(url))
        }

        func makeReference() throws -> NSManagedObjectModelReference {
            switch source {
            case .model(let build):
                NSManagedObjectModelReference(model: try build(), versionChecksum: checksum)
            case .named(let name, let bundle):
                NSManagedObjectModelReference(name: name, in: bundle, versionChecksum: checksum)
            case .fileURL(let url):
                NSManagedObjectModelReference(fileURL: url, versionChecksum: checksum)
            }
        }
    }

    // MARK: StageHandler

    /// Work that runs immediately before or after a custom stage's schema change.
    ///
    /// The container is the one Core Data built for the migration, configured with the model
    /// version appropriate to the handler: `willMigrate` sees the *old* schema, `didMigrate` the
    /// *new* one. That is the whole point of a custom stage — read the old shape on the way in,
    /// write the new shape on the way out.
    ///
    /// - Important: An error thrown here propagates out of `loadPersistentStores` **verbatim**,
    ///   as your own error type rather than wrapped in an `NSError`, and `DatabaseClient.init`
    ///   surfaces it as `DatabaseError.storeLoadFailed(underlying:)`. The store is left at the
    ///   version it had reached, so a retry resumes rather than starting over.
    public typealias StageHandler = @Sendable (NSPersistentContainer) throws -> Void

    // MARK: Stage

    /// One step in the ordering.
    public struct Stage: Sendable {

        enum Kind: Sendable {
            case lightweight(checksums: [String])
            case custom(
                from: ModelVersion,
                to: ModelVersion,
                willMigrate: StageHandler?,
                didMigrate: StageHandler?
            )
        }

        let kind: Kind

        /// Names the stage in persistent history, and in this package's error messages.
        public var label: String?

        /// A run of versions Core Data can migrate by inference, with no data work in between.
        ///
        /// List every version the run covers *except* any a custom stage already names.
        public static func lightweight(checksums: [String], label: String? = nil) -> Stage {
            Stage(kind: .lightweight(checksums: checksums), label: label)
        }

        /// A version change with data work attached.
        ///
        /// The schema change itself still has to be lightweight-eligible — a custom stage adds
        /// handlers around an inferred migration, it does not replace it with a mapping model.
        public static func custom(
            from: ModelVersion,
            to: ModelVersion,
            label: String? = nil,
            willMigrate: StageHandler? = nil,
            didMigrate: StageHandler? = nil
        ) -> Stage {
            Stage(
                kind: .custom(from: from, to: to, willMigrate: willMigrate, didMigrate: didMigrate),
                label: label
            )
        }

        /// What this stage is called when there is a problem to report.
        var describedLabel: String {
            if let label { return label }

            switch kind {
            case .lightweight(let checksums):
                return "lightweight stage (\(checksums.count) version(s))"
            case .custom(let from, let to, _, _):
                return "custom stage \(from.checksum.prefix(8))… → \(to.checksum.prefix(8))…"
            }
        }

        func makeMigrationStage() throws -> NSMigrationStage {
            let stage: NSMigrationStage

            switch kind {
            case .lightweight(let checksums):
                stage = NSLightweightMigrationStage(checksums)

            case .custom(let from, let to, let willMigrate, let didMigrate):
                let custom = NSCustomMigrationStage(
                    migratingFrom: try from.makeReference(),
                    to: try to.makeReference()
                )
                let name = label ?? describedLabel
                custom.willMigrateHandler = willMigrate.map { handler in
                    { manager, _ in try handler(Self.container(of: manager, stage: name)) }
                }
                custom.didMigrateHandler = didMigrate.map { handler in
                    { manager, _ in try handler(Self.container(of: manager, stage: name)) }
                }
                stage = custom
            }

            if let label {
                stage.label = label
            }

            return stage
        }

        /// `NSStagedMigrationManager.container` is typed optional. It was populated in both
        /// handlers on the measured SDK, so this is a guard rather than a code path anyone is
        /// expected to hit.
        private static func container(
            of manager: NSStagedMigrationManager,
            stage: String
        ) throws -> NSPersistentContainer {
            guard let container = manager.container else {
                throw DatabaseError.invalidMigrationPlan(
                    "'\(stage)' ran without a migration container, so its handler has no store to work on."
                )
            }
            return container
        }
    }

    // MARK: Properties

    /// The stages, in the order Core Data should apply them.
    public var stages: [Stage]

    // MARK: Init

    public init(stages: [Stage]) {
        self.stages = stages
    }

    // MARK: Assembly

    /// Checks the ordering and builds the manager Core Data installs.
    ///
    /// - Throws: `DatabaseError.invalidMigrationPlan` when the plan is empty or claims a version
    ///   twice — the second of which would otherwise be an uncatchable Objective-C exception.
    func makeManager() throws -> NSStagedMigrationManager {
        try validate()
        return NSStagedMigrationManager(try stages.map { try $0.makeMigrationStage() })
    }

    /// Installs the plan on a store description.
    ///
    /// - Important: Also forces `shouldMigrateStoreAutomatically` and
    ///   `shouldInferMappingModelAutomatically` on. Both are *required*: Core Data rejects the
    ///   load outright with "Staged Migration was requested with
    ///   NSPersistentStoreStagedMigrationManagerOptionKey but without setting
    ///   NSMigratePersistentStoresAutomaticallyOption and NSInferMappingModelAutomaticallyOption
    ///   to YES" (134100) if either is off. Staged migration is therefore not a way to *disable*
    ///   inference — it is a way to interleave data work with it.
    func install(on description: NSPersistentStoreDescription) throws {
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        description.setOption(try makeManager(), forKey: NSPersistentStoreStagedMigrationManagerOptionKey)
    }

    /// Rejects the ordering Core Data would raise an uncatchable exception over.
    ///
    /// See the type's documentation for the rule. Walking the stages in order is what makes the
    /// adjacent-custom-stage exception expressible: a repeat is legal only when the previous
    /// stage handed this one the version it starts from.
    func validate() throws {
        guard !stages.isEmpty else {
            throw DatabaseError.invalidMigrationPlan("The plan has no stages.")
        }

        var claimed: Set<String> = []
        var handedOver: String?

        for stage in stages {
            switch stage.kind {
            case .lightweight(let checksums):
                guard !checksums.isEmpty else {
                    throw DatabaseError.invalidMigrationPlan(
                        "'\(stage.describedLabel)' lists no version checksums."
                    )
                }

                for checksum in checksums {
                    try claim(checksum, for: stage, in: &claimed, handedOver: nil)
                }
                handedOver = nil

            case .custom(let from, let to, _, _):
                try claim(from.checksum, for: stage, in: &claimed, handedOver: handedOver)
                try claim(to.checksum, for: stage, in: &claimed, handedOver: nil)
                handedOver = to.checksum
            }
        }
    }

    /// - Parameter handedOver: The checksum the preceding custom stage migrated *to*, which this
    ///   stage is allowed to re-claim as the version it starts from.
    private func claim(
        _ checksum: String,
        for stage: Stage,
        in claimed: inout Set<String>,
        handedOver: String?
    ) throws {
        if claimed.contains(checksum), checksum != handedOver {
            throw DatabaseError.invalidMigrationPlan(
                "Version '\(checksum)' is claimed by more than one stage — '\(stage.describedLabel)' "
                    + "repeats it. Core Data raises an uncatchable NSInvalidArgumentException for this. "
                    + "A lightweight stage must not list a version that a custom stage names; only two "
                    + "adjacent custom stages may share the version between them."
            )
        }

        claimed.insert(checksum)
    }
}

// MARK: - SchemaMigrationPlan + Checksums

extension SchemaMigrationPlan {

    /// The checksum identifying `model`.
    ///
    /// Reading `NSManagedObjectModel.versionChecksum` on a model no coordinator has taken makes
    /// Core Data log *"Attempting to retrieve an NSManagedObjectModel version checksum while the
    /// model is still editable. This may result in an unstable version checksum."* — so this
    /// hands the model to a throwaway coordinator first, which is what freezes it.
    ///
    /// - Important: That freeze is permanent, and a frozen model belongs to the coordinator that
    ///   froze it. Call this on a model instance you are going to throw away, not on the one you
    ///   are about to hand to `DatabaseConfiguration`.
    /// - Note: A development-time helper. The result is a constant of the model version, so paste
    ///   it into the plan as a literal rather than computing it at launch.
    public static func checksum(of model: NSManagedObjectModel) -> String {
        _ = NSPersistentStoreCoordinator(managedObjectModel: model)
        return model.versionChecksum
    }

    /// Every version checksum in a compiled model, keyed by version name.
    ///
    /// Point it at a `.momd` bundle to get one entry per `.mom` inside, or at a single `.mom`.
    /// This is the answer to "where do I get these strings from" — the alternative is digging
    /// through Xcode build logs or a versioned model's `VersionInfo.plist`.
    ///
    /// - Note: Core Data has `checksumsForVersionedModelAtURL:error:` for this, but it is marked
    ///   `NS_REFINED_FOR_SWIFT` with no refinement ever shipped, so the only Swift spelling is
    ///   the underscored `__checksumsForVersionedModel(at:)`. This loads the models instead.
    public static func checksums(ofVersionedModelAt url: URL) throws -> [String: String] {
        let versionURLs: [URL]

        if url.pathExtension == "momd" {
            let contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil
            )
            versionURLs = contents.filter { $0.pathExtension == "mom" }.sorted { $0.path < $1.path }
        } else {
            versionURLs = [url]
        }

        guard !versionURLs.isEmpty else {
            throw DatabaseError.invalidModel("No compiled model versions at \(url.path).")
        }

        return try versionURLs.reduce(into: [:]) { result, versionURL in
            guard let model = NSManagedObjectModel(contentsOf: versionURL) else {
                throw DatabaseError.invalidModel(
                    "'\(versionURL.lastPathComponent)' is not a loadable model."
                )
            }
            result[versionURL.deletingPathExtension().lastPathComponent] = checksum(of: model)
        }
    }

    /// The version checksum the store on disk was last written with, or `nil` if there is no
    /// store there yet.
    ///
    /// Useful when a migration fails and the question is *which* version the user is actually on.
    public static func storedChecksum(at url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return nil
        }

        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: url)
        // The constant is spelled `NSPersistentStore…` but its *value* is
        // "NSStoreModelVersionChecksumKey", which is what appears in a metadata dump. It landed
        // in macOS 15 / iOS 18 — this package's floor exactly.
        return metadata[NSPersistentStoreModelVersionChecksumKey] as? String
    }
}
