//
//  DatabaseContext.swift
//  DatabaseLayer
//

import Foundation

// MARK: - DatabaseContext

/// Which managed object context an operation should run on.
///
/// Every `DatabaseActions` method takes one, defaulting to `.background` for writes and
/// `.main` for reads, so the common call site stays as short as the Realm one was.
public enum DatabaseContext: Sendable {

    /// The container's `viewContext`. Main-queue, for reads that feed the UI.
    case main

    /// A single long-lived private-queue context owned by the client.
    ///
    /// All `.background` work serializes on it, which gives ordered writes and avoids
    /// creating a context per call.
    case background

    /// A fresh private-queue context per call.
    ///
    /// Use it for long imports that must not sit in front of unrelated background work.
    /// The context is discarded once the operation finishes, so nothing it faulted in
    /// survives the call.
    case detached
}
