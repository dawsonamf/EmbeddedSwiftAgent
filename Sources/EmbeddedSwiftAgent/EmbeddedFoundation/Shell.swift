import Cstdio

struct ShellResult {
    let output: String
    let exitCode: Int32
}

func runShell(_ command: String) -> ShellResult {
    var pipeFds = [Int32](repeating: 0, count: 2)
    guard pipe(&pipeFds) == 0 else {
        return ShellResult(output: "shell-error: pipe() failed", exitCode: -1)
    }
    let readEnd = pipeFds[0]
    let writeEnd = pipeFds[1]

#if canImport(Darwin)
    var fileActions: posix_spawn_file_actions_t?
#else
    var fileActions = posix_spawn_file_actions_t()
#endif
    posix_spawn_file_actions_init(&fileActions)
    posix_spawn_file_actions_adddup2(&fileActions, writeEnd, STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&fileActions, writeEnd, STDERR_FILENO)
    posix_spawn_file_actions_addclose(&fileActions, readEnd)
    posix_spawn_file_actions_addclose(&fileActions, writeEnd)

    let argv: [UnsafeMutablePointer<CChar>?] = [
        strdup("/bin/sh"),
        strdup("-c"),
        strdup(command),
        nil
    ]
    defer { for arg in argv { if let arg = arg { free(arg) } } }

    var pid: pid_t = 0

    // environ is not thread-safe to read during concurrent modification — safe here as a single-threaded CLI
    let spawnResult = posix_spawn(&pid, "/bin/sh", &fileActions, nil, argv, get_environ())
    posix_spawn_file_actions_destroy(&fileActions)

    close(writeEnd)

    guard spawnResult == 0 else {
        close(readEnd)
        return ShellResult(output: "shell-error: posix_spawn failed with code \(spawnResult)", exitCode: -1)
    }

    var output: [UInt8] = []
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(readEnd, &buf, buf.count)
        if n <= 0 { break }
        output.append(contentsOf: buf[0..<n])
    }
    close(readEnd)

    var status: Int32 = 0
    waitpid(pid, &status, 0)

    let exitCode: Int32
    if (status & 0x7f) == 0 {
        // WIFEXITED — normal exit
        exitCode = (status >> 8) & 0xff
    } else {
        // Killed by signal
        exitCode = -(status & 0x7f)
    }

    output.append(0)
    let outputStr = output.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    return ShellResult(output: outputStr, exitCode: exitCode)
}
