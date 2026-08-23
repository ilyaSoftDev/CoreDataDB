//
//  DatabaseClient+StoreIdentity.swift
//  DatabaseLayer
//

import CoreData
import Foundation

// MARK: - DatabaseClient + Store identity

extension DatabaseClient {

    /// Identifies the persistent store this client opened, or `nil` if it has none.
    ///
    /// SPI rather than public API, and it exists for exactly one caller: the Combine tier, which
    /// is a separate module — `CoreDataDBCombine` — under Swift Package Manager and therefore
    /// cannot see `provider`, which is internal. CocoaPods and the Xcode framework target compile
    /// both tiers into one module, where that same access is ordinary internal access and this
    /// accessor is redundant. It is written once, for the build where it is not.
    ///
    /// Deliberately not `public`. `BUILD_LIBRARY_FOR_DISTRIBUTION` is on, so a public spelling
    /// would be a permanent ABI commitment to an implementation detail: the `ObjectIdentifier` of
    /// an `NSPersistentStore` is meaningful only for comparing against
    /// `NSManagedObjectID.persistentStore` on a notification this framework already knows how to
    /// read. `@_spi` keeps it out of the public interface while still emitting it as a symbol the
    /// sibling module can link, and a client of the SPI has to name the group to reach it.
    ///
    /// `ContextProvider` installs exactly one `NSPersistentStoreDescription`, so `first` is *the*
    /// store rather than an arbitrary one of several.
    @_spi(CoreDataDBTiers)
    public var storeIdentifier: ObjectIdentifier? {
        provider.container.persistentStoreCoordinator
            .persistentStores
            .first
            .map(ObjectIdentifier.init)
    }
}
