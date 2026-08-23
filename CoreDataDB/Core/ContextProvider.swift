//
//  ContextProvider.swift
//  DatabaseLayer
//

import CoreData
import Foundation

// MARK: - ContextProvider

/// Owns the `NSPersistentContainer` and hands out the contexts `DatabaseContext` names.
///
/// `NSPersistentContainer` and `NSManagedObjectContext` are both `Sendable` and each context
/// carries its own queue, so this type needs no actor and no `@MainActor`. That is the whole
/// reason the Realm trap is gone: a `DatabaseManager` built off the main thread raised an
/// uncatchable `RLMException` on first use, while a provider can be built from anywhere.
final class ContextProvider: Sendable {

    // MARK: Properties

    let configuration: DatabaseConfiguration

    let container: NSPersistentContainer

    /// Where the store file landed, or `nil` for an in-memory store.
    let storeURL: URL?

    /// Backs `DatabaseContext.background`.
    ///
    /// Created eagerly rather than lazily: a private-queue context is barely more than a
    /// serial queue, and a `let` keeps the provider `Sendable` without a lock.
    private let sharedBackgroundContext: NSManagedObjectContext

    // MARK: Init

    /// Resolves the model, opens the store, and configures the contexts.
    ///
    /// - Throws: `DatabaseError.invalidModel` if the model cannot be resolved,
    ///   `DatabaseError.storeLoadFailed` if the store cannot be opened. The Realm
    ///   implementation called `fatalError` here.
    init(configuration: DatabaseConfiguration) async throws {
        let model = try configuration.model.resolve()
        // Before the store, not after: a misconfigured model should be reported without
        // leaving a store file behind.
        try ModelValidator.validate(configuration.registeredModels, against: model)

        let container = NSPersistentContainer(name: configuration.name, managedObjectModel: model)
        let storeURL = configuration.store.makeFileURL()

        let description = NSPersistentStoreDescription(
            url: storeURL ?? DatabaseConfiguration.StoreKind.inMemoryPlaceholderURL
        )
        description.type = configuration.store.storeType
        // Loading synchronously keeps `init` deterministic: when it returns, the store is up.
        description.shouldAddStoreAsynchronously = false

        switch configuration.migration {
        case .lightweight:
            description.shouldMigrateStoreAutomatically = true
            description.shouldInferMappingModelAutomatically = true
        case .disabled:
            description.shouldMigrateStoreAutomatically = false
            description.shouldInferMappingModelAutomatically = false
        case .staged(let plan):
            // Schema stages run *inside* the load below, which is why the plan is validated and
            // installed here rather than by the facade after the fact. It sets both migration
            // flags itself — Core Data refuses a staged manager without them.
            try plan.install(on: description)
        }

        // Batch operations bypass the contexts entirely, so transaction history is how live
        // contexts find out about them. SQLite-only — asking an in-memory store for it fails
        // the load.
        if configuration.isPersistentHistoryTrackingEnabled, configuration.store.isSQLiteBacked {
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        }

        container.persistentStoreDescriptions = [description]
        try await Self.loadStores(in: container)

        // Safe to configure directly: nothing else can reach these contexts until `init`
        // returns, so there is no queue to hop onto yet.
        Self.configure(container.viewContext, named: "viewContext", using: configuration)

        let backgroundContext = container.newBackgroundContext()
        Self.configure(backgroundContext, named: "background", using: configuration)

        self.configuration = configuration
        self.container = container
        self.storeURL = storeURL
        self.sharedBackgroundContext = backgroundContext
    }

    // MARK: Contexts

    /// The context a `DatabaseContext` resolves to.
    ///
    /// `.main` and `.background` return the shared, long-lived contexts. `.detached` builds
    /// a fresh one per call — Phase 4's `perform` routes that case through
    /// `NSPersistentContainer.performBackgroundTask` instead, which manages the context's
    /// lifetime for it.
    func context(for kind: DatabaseContext) -> NSManagedObjectContext {
        switch kind {
        case .main: container.viewContext
        case .background: sharedBackgroundContext
        case .detached: makeDetachedContext()
        }
    }

    /// A fresh private-queue context, configured like the shared one.
    func makeDetachedContext() -> NSManagedObjectContext {
        let context = container.newBackgroundContext()
        configure(context, named: "detached")
        return context
    }

    /// The long-lived contexts that have to be told about changes made behind their backs.
    ///
    /// A batch request writes straight to the store without going through a context save, so
    /// nothing here hears about it unless the resulting object IDs are merged in explicitly.
    var mergeTargets: [NSManagedObjectContext] {
        [container.viewContext, sharedBackgroundContext]
    }

    /// Applies the configured merge policy and a debug name.
    ///
    /// `NSPersistentContainer.performBackgroundTask` builds its own context, which would
    /// otherwise arrive with the default `NSErrorMergePolicy` and lose upsert semantics.
    func configure(_ context: NSManagedObjectContext, named suffix: String) {
        Self.configure(context, named: suffix, using: configuration)
    }

    private static func configure(
        _ context: NSManagedObjectContext,
        named suffix: String,
        using configuration: DatabaseConfiguration
    ) {
        context.name = "\(configuration.name).\(suffix)"
        context.automaticallyMergesChangesFromParent = true
        context.mergePolicy = NSMergePolicy(merge: configuration.mergePolicy)
    }

    // MARK: Store loading

    /// The one continuation in the package.
    ///
    /// `loadPersistentStores(completionHandler:)` is declared `NS_SWIFT_DISABLE_ASYNC`, so
    /// there is no `async` overload to call. Everything else here uses
    /// `NSManagedObjectContext.perform(schedule:_:)`, which is natively `async`.
    private static func loadStores(in container: NSPersistentContainer) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            // The handler fires once per store description, and exactly one is installed.
            container.loadPersistentStores { _, error in
                if let error {
                    continuation.resume(throwing: DatabaseError.storeLoadFailed(underlying: error))
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
