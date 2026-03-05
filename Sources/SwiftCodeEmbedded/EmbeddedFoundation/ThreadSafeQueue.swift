import Cstdio

/// A thread-safe FIFO queue of strings, backed by a pthread mutex + condition variable.
/// Used for cross-thread handoff between stdin reader and agent/runtime loops.
struct ThreadSafeQueue: @unchecked Sendable {
    private let mutex: OpaquePointer
    private let cond: OpaquePointer

    /// Underlying storage — access only while holding `mutex`.
    private let storage: StringBuffer

    init() {
        mutex = OpaquePointer(sc_mutex_create())
        cond = OpaquePointer(sc_cond_create())
        storage = StringBuffer()
    }

    func push(_ value: String) {
        sc_mutex_lock(UnsafeMutableRawPointer(mutex))
        storage.append(value)
        sc_cond_signal(UnsafeMutableRawPointer(cond))
        sc_mutex_unlock(UnsafeMutableRawPointer(mutex))
    }

    func popFirst() -> String? {
        sc_mutex_lock(UnsafeMutableRawPointer(mutex))
        let result = storage.removeFirst()
        sc_mutex_unlock(UnsafeMutableRawPointer(mutex))
        return result
    }

    /// Blocks until an item is available or `timeoutMs` elapses.
    /// Returns nil on timeout (caller should check abort/EOF flags).
    func waitAndPop(timeoutMs: Int32) -> String? {
        sc_mutex_lock(UnsafeMutableRawPointer(mutex))
        if storage.count == 0 {
            sc_cond_timedwait(UnsafeMutableRawPointer(cond), UnsafeMutableRawPointer(mutex), timeoutMs)
        }
        let result = storage.removeFirst()
        sc_mutex_unlock(UnsafeMutableRawPointer(mutex))
        return result
    }

    func isEmpty() -> Bool {
        sc_mutex_lock(UnsafeMutableRawPointer(mutex))
        let empty = storage.count == 0
        sc_mutex_unlock(UnsafeMutableRawPointer(mutex))
        return empty
    }

    func drain() -> [String] {
        sc_mutex_lock(UnsafeMutableRawPointer(mutex))
        let all = storage.drainAll()
        sc_mutex_unlock(UnsafeMutableRawPointer(mutex))
        return all
    }

    func destroy() {
        sc_cond_destroy(UnsafeMutableRawPointer(cond))
        sc_mutex_destroy(UnsafeMutableRawPointer(mutex))
    }
}

/// Mutable backing store for ThreadSafeQueue.
/// A class so the queue struct can hold a reference and mutate through it.
private final class StringBuffer {
    var items: [String] = []

    var count: Int { items.count }

    func append(_ value: String) {
        items.append(value)
    }

    func removeFirst() -> String? {
        guard !items.isEmpty else { return nil }
        return items.removeFirst()
    }

    func drainAll() -> [String] {
        let copy = items
        items.removeAll()
        return copy
    }
}
