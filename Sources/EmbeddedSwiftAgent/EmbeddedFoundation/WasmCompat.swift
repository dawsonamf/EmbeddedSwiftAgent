#if os(WASI)

// libc macros that ClangImporter doesn't surface from wasi-libc under
// Embedded Swift. The values are fixed by POSIX (and musl, which wasi-libc
// derives from), so defining them here is safe.
let SEEK_SET: Int32 = 0
let SEEK_END: Int32 = 2

#endif
