import Cstdio

/// A signal-safe atomic boolean flag, backed by a C `volatile sig_atomic_t`.
/// Safe to set from a SIGINT handler. Used to propagate abort from Ctrl+C
/// through the agent loop and into in-flight HTTP requests.
///
/// Class (not struct) so the underlying C allocation is freed automatically via deinit.
final class AbortFlag: @unchecked Sendable {
    private let flag: OpaquePointer

    /// Raw pointer for passing to C functions (e.g. `install_sigint_handler`).
    var rawPointer: UnsafeMutableRawPointer {
        UnsafeMutableRawPointer(flag)
    }

    init() {
        flag = OpaquePointer(sc_atomic_flag_create())
    }

    func set() {
        sc_atomic_flag_set(UnsafeMutableRawPointer(flag))
    }

    func isSet() -> Bool {
        sc_atomic_flag_read(UnsafeMutableRawPointer(flag)) != 0
    }

    func reset() {
        sc_atomic_flag_reset(UnsafeMutableRawPointer(flag))
    }

    deinit {
        sc_atomic_flag_destroy(UnsafeMutableRawPointer(flag))
    }
}
