import Cstdio

/// A thread-safe FIFO queue of strings, backed by a pthread mutex + condition variable.
/// Used for cross-thread handoff between stdin reader and agent/runtime loops.
///
/// Class (not struct) so the underlying C mutex/condvar are freed automatically via deinit.
final class ThreadSafeQueue: @unchecked Sendable {
    private let mutex: OpaquePointer
    private let cond: OpaquePointer

    /// Underlying storage — access only while holding `mutex`.
    private var items: [String] = []

    init() {
        mutex = OpaquePointer(sc_mutex_create())
        cond = OpaquePointer(sc_cond_create())
    }

    func push(_ value: String) {
        sc_mutex_lock(UnsafeMutableRawPointer(mutex))
        items.append(value)
        sc_cond_signal(UnsafeMutableRawPointer(cond))
        sc_mutex_unlock(UnsafeMutableRawPointer(mutex))
    }

    func popFirst() -> String? {
        sc_mutex_lock(UnsafeMutableRawPointer(mutex))
        let result = items.isEmpty ? nil : items.removeFirst()
        sc_mutex_unlock(UnsafeMutableRawPointer(mutex))
        return result
    }

    /// Blocks until an item is available or `timeoutMs` elapses.
    /// Returns nil on timeout (caller should check abort/EOF flags).
    func waitAndPop(timeoutMs: Int32) -> String? {
        sc_mutex_lock(UnsafeMutableRawPointer(mutex))
        if items.isEmpty {
            sc_cond_timedwait(UnsafeMutableRawPointer(cond), UnsafeMutableRawPointer(mutex), timeoutMs)
        }
        let result = items.isEmpty ? nil : items.removeFirst()
        sc_mutex_unlock(UnsafeMutableRawPointer(mutex))
        return result
    }

    func isEmpty() -> Bool {
        sc_mutex_lock(UnsafeMutableRawPointer(mutex))
        let empty = items.isEmpty
        sc_mutex_unlock(UnsafeMutableRawPointer(mutex))
        return empty
    }

    func drain() -> [String] {
        sc_mutex_lock(UnsafeMutableRawPointer(mutex))
        let all = items
        items.removeAll()
        sc_mutex_unlock(UnsafeMutableRawPointer(mutex))
        return all
    }

    deinit {
        sc_cond_destroy(UnsafeMutableRawPointer(cond))
        sc_mutex_destroy(UnsafeMutableRawPointer(mutex))
    }
}
