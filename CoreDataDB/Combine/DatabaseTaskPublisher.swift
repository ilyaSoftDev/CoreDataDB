//
//  DatabaseTaskPublisher.swift
//  DatabaseLayer
//

import Combine
import Foundation

// See DatabaseCombineProxy.swift.
#if COREDATADB_MODULAR
import CoreDataDB
#endif

// MARK: - DatabaseTaskPublisher

/// Bridges one `async throws` call into a publisher that emits its result and finishes.
///
/// Every method on `DatabaseCombineProxy` is this type with a different closure, so the whole
/// Combine tier inherits the guarantees `DatabaseClient.perform(_:_:)` already makes — including
/// the `Sendable` constraint that stops a managed object escaping, which is why `Output` is
/// constrained the same way (D2).
///
/// The publisher is **cold**. The `Task` is created on the first `request(_:)` carrying demand,
/// not when the publisher is built and not when a subscriber attaches, so constructing one and
/// dropping it performs no work. That is the ordinary `Deferred` contract, and it is what makes it
/// safe to express a *write* as a publisher at all: `client.combine.save(model)` sitting in a local
/// variable has not saved anything.
///
/// - Note: `Failure` is `any Error` rather than `DatabaseError`, deliberately. The async tier does
///   not throw only `DatabaseError` — a save conflict, a failed validation or a malformed fetch
///   arrives as a raw `NSError` from Core Data, and `perform`'s cancellation check throws
///   `CancellationError`. Mirroring `async throws` exactly is more honest than a typed failure that
///   would have to carry an `underlying` case for everything it does not model.
struct DatabaseTaskPublisher<Output: Sendable>: Publisher, Sendable {

    // MARK: Publisher

    typealias Failure = any Error

    // MARK: CancellationPolicy

    /// What cancelling a subscription does to the work already in flight.
    enum CancellationPolicy: Sendable {

        /// Cancelling cancels the `Task`. Used for reads.
        ///
        /// - Important: The work does not stop wherever it happens to be. `perform` observes
        ///   cancellation once, *before* it hops onto the context queue; past that point the body
        ///   runs to completion and only the delivery is dropped.
        case cancelsWork

        /// Cancelling detaches the subscriber and leaves the `Task` running. Used for writes.
        ///
        /// - Important: A write that has started **commits**, cancelled or not, and cancelling
        ///   never rolls one back. The alternative is worse: under `cancelsWork` a
        ///   `client.combine.save(model).sink { }` whose `AnyCancellable` is discarded — the
        ///   single most common Combine mistake — would cancel itself before writing anything,
        ///   and the save would silently never happen.
        case completesWork
    }

    // MARK: Properties

    let policy: CancellationPolicy

    let work: @Sendable () async throws -> Output

    // MARK: Publisher

    func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
        let subscription = DatabaseTaskSubscription(policy: policy, work: work, subscriber: subscriber)
        subscriber.receive(subscription: subscription)
    }
}

// MARK: - DatabaseTaskPublisher + Factories

extension DatabaseTaskPublisher {

    /// A cancellable read.
    static func read(_ work: @escaping @Sendable () async throws -> Output) -> Self {
        Self(policy: .cancelsWork, work: work)
    }

    /// A write that commits once it has started, whatever happens to the subscription.
    static func write(_ work: @escaping @Sendable () async throws -> Output) -> Self {
        Self(policy: .completesWork, work: work)
    }
}

// MARK: - DatabaseTaskSubscription

/// The one `Task` behind a `DatabaseTaskPublisher` subscription.
///
/// `@unchecked Sendable` because Combine predates the concurrency model: `Subscriber` carries no
/// `Sendable` requirement, so the subscriber this holds cannot be proven safe to touch from the
/// `Task`. Every stored property is guarded by `lock`, and the subscriber is read out exactly once
/// — either by `complete(with:)` to deliver, or by `cancel()` to drop — so it is only ever used
/// from one place at a time.
private final class DatabaseTaskSubscription<Output: Sendable, S: Subscriber>: Subscription,
    @unchecked Sendable where S.Input == Output, S.Failure == any Error {

    // MARK: Properties

    private let policy: DatabaseTaskPublisher<Output>.CancellationPolicy

    private let work: @Sendable () async throws -> Output

    /// `NSLock` rather than `OSAllocatedUnfairLock`: the state is not `Sendable`, which the
    /// latter's checked initializer refuses, and `withLockUnchecked` at every call site buys
    /// nothing over a lock this cold — it is taken three times in a subscription's life.
    private let lock = NSLock()

    /// Cleared by whichever of `complete(with:)` or `cancel()` gets there first, which is what
    /// makes delivery-after-cancel and double-completion impossible.
    private var subscriber: S?

    /// Doubles as the "already started" flag, so a second `request(_:)` cannot start a second task.
    private var task: Task<Void, Never>?

    // MARK: Init

    init(
        policy: DatabaseTaskPublisher<Output>.CancellationPolicy,
        work: @escaping @Sendable () async throws -> Output,
        subscriber: S
    ) {
        self.policy = policy
        self.work = work
        self.subscriber = subscriber
    }

    // MARK: Subscription

    func request(_ demand: Subscribers.Demand) {
        guard demand > 0 else { return }

        lock.lock()
        defer { lock.unlock() }

        // Nothing to do if `cancel()` already ran, or if a previous request started the work.
        guard subscriber != nil, task == nil else { return }

        // Creating a `Task` under the lock is safe — the body does not run synchronously — and
        // closing the window before the handle is stored is what stops `cancel()` from missing it.
        task = Task { [self] in
            do {
                complete(with: .success(try await work()))
            } catch {
                complete(with: .failure(error))
            }
        }
    }

    // MARK: Cancellable

    func cancel() {
        lock.lock()
        let task = self.task
        self.subscriber = nil
        self.task = nil
        lock.unlock()

        if case .cancelsWork = policy {
            task?.cancel()
        }
    }

    // MARK: Delivery

    /// Hands the result to the subscriber, unless `cancel()` got here first.
    ///
    /// Values arrive on whatever executor the `Task` resumed on — **not** the main queue, and not
    /// the context's queue, even for `DatabaseContext.main`, since the result is handed back out
    /// of `context.perform`. Callers binding to UI have to `receive(on:)` themselves; the tier
    /// deliberately does not hide one, because a publisher that silently hops queues cannot be
    /// composed with one that does not.
    private func complete(with result: Result<Output, any Error>) {
        lock.lock()
        let subscriber = self.subscriber
        self.subscriber = nil
        // Also breaks the retain cycle this class → task → closure → self.
        self.task = nil
        lock.unlock()

        guard let subscriber else { return }

        switch result {
        case .success(let value):
            // The return value is the subscriber's follow-on demand, and there is nothing left
            // to send it.
            _ = subscriber.receive(value)
            subscriber.receive(completion: .finished)

        case .failure(let error):
            subscriber.receive(completion: .failure(error))
        }
    }
}
