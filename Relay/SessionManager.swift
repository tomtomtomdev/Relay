//
//  SessionManager.swift
//  Relay
//
//  Slice 4 — owns one PTY and the interactive process driven through it (SPEC §4, §5).
//
//  A persistent pseudo-terminal, not a fresh `Process` per message: `claude` is
//  interactive and stateful, so input is fed to the master fd of a long-lived PTY and
//  output (stdout+stderr, merged by the tty as a real terminal sees it) streams back on
//  a dedicated read loop as raw `Data` chunks.
//
//  This actor knows nothing about gates — it just runs a process and moves bytes. The
//  Authorizer's `.forward` is not wired in here until Slice 6, per the security-spine
//  guardrail.
//

import Foundation

/// A PTY/spawn syscall failed. Carries only the POSIX `errno` — never a secret.
nonisolated enum SessionError: Error, Equatable {
    case openPTYFailed(code: Int32)
}

/// Owns one pseudo-terminal and the process running on its slave side.
actor SessionManager {

    /// What to do when the child process exits.
    enum RespawnPolicy: Sendable, Equatable {
        /// Leave the session dead and finish the output stream.
        case never
        /// Relaunch the same command immediately.
        case always
    }

    private let command: [String]
    private let bootstrap: String?
    private let environment: [String: String]?
    private let respawnPolicy: RespawnPolicy

    private var process: Process?
    private var masterFD: Int32 = -1
    private var stopRequested = false
    private var finished = false
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []

    /// Number of times the target process has been launched (including respawns).
    private(set) var launchCount = 0
    /// True while a child process is alive on the PTY.
    private(set) var isRunning = false

    /// Merged stdout+stderr from the PTY, as raw chunks. Finishes when the session ends
    /// permanently (child exit under `.never`, or `stop()`).
    let output: AsyncStream<Data>
    private let outputContinuation: AsyncStream<Data>.Continuation

    /// - Parameters:
    ///   - command: argv of the process to run on the PTY (`command[0]` is the
    ///     executable). Defaults to a login shell.
    ///   - bootstrap: an optional line typed into the PTY right after launch — e.g. the
    ///     configured `claude` invocation, so the session is "zsh -l first, then claude".
    ///   - environment: process environment; `nil` inherits the parent's.
    ///   - respawnPolicy: what to do when the child exits.
    init(
        command: [String] = ["/bin/zsh", "-l"],
        bootstrap: String? = nil,
        environment: [String: String]? = nil,
        respawnPolicy: RespawnPolicy = .never
    ) {
        self.command = command
        self.bootstrap = bootstrap
        self.environment = environment
        self.respawnPolicy = respawnPolicy

        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        self.output = stream
        self.outputContinuation = continuation
    }

    // MARK: - Lifecycle

    /// Open the PTY and launch the target process. No-op if already running or finished.
    func start() throws {
        guard !isRunning, !finished else { return }
        try launch()
    }

    /// Write `text` to the PTY master, followed by a newline (the "enter" key).
    func send(_ text: String) {
        guard masterFD >= 0 else { return }
        writeAll(Data((text + "\n").utf8))
    }

    /// Terminate the child and tear the session down permanently.
    func stop() {
        stopRequested = true
        if let process, process.isRunning {
            process.terminate()
            // The read loop reaching EOF drives the permanent teardown (see
            // `readLoopDidEnd`), so the master fd is closed by its sole reader.
        } else {
            // Never started, or the child already exited: finalize directly.
            finalize()
        }
    }

    /// Suspends until the session ends permanently; returns immediately if it already
    /// has. Never returns while `respawnPolicy == .always` keeps respawning.
    func waitUntilExited() async {
        if finished { return }
        await withCheckedContinuation { exitWaiters.append($0) }
    }

    // MARK: - Internals

    private func launch() throws {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else { throw SessionError.openPTYFailed(code: errno) }
        guard grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master) else {
            let code = errno
            close(master)
            throw SessionError.openPTYFailed(code: code)
        }
        let slave = open(String(cString: name), O_RDWR | O_NOCTTY)
        guard slave >= 0 else {
            let code = errno
            close(master)
            throw SessionError.openPTYFailed(code: code)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: command[0])
        proc.arguments = Array(command.dropFirst())
        if let environment { proc.environment = environment }
        // One handle drives stdin/stdout/stderr: the tty merges them like a real terminal.
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        proc.standardInput = slaveHandle
        proc.standardOutput = slaveHandle
        proc.standardError = slaveHandle

        do {
            try proc.run()
        } catch {
            close(master)
            close(slave)
            throw error
        }
        close(slave) // the child holds its own copy; the parent only needs the master

        process = proc
        masterFD = master
        isRunning = true
        launchCount += 1
        startReadLoop(master: master)

        if let bootstrap { send(bootstrap) }
    }

    private func startReadLoop(master: Int32) {
        let continuation = outputContinuation
        let onEnd: @Sendable () -> Void = { [weak self] in
            Task { await self?.readLoopDidEnd(master: master) }
        }
        let thread = Thread {
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(master, &buffer, buffer.count)
                if n > 0 {
                    continuation.yield(Data(buffer[0..<n]))
                } else {
                    break // EOF (0) or error (-1, e.g. EIO once the slave side is gone)
                }
            }
            onEnd()
        }
        thread.name = "Relay.SessionManager.read"
        thread.start()
    }

    /// The read loop hit EOF — the child has exited. The read loop is the sole closer of
    /// the master fd, so there is no close-during-read race with the reading thread.
    private func readLoopDidEnd(master: Int32) {
        if masterFD == master {
            close(master)
            masterFD = -1
        }
        process = nil
        isRunning = false

        if respawnPolicy == .always, !stopRequested {
            try? launch()
        } else {
            finalize()
        }
    }

    private func finalize() {
        guard !finished else { return }
        finished = true
        outputContinuation.finish()
        let waiters = exitWaiters
        exitWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func writeAll(_ data: Data) {
        data.withUnsafeBytes { raw in
            guard var pointer = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = write(masterFD, pointer, remaining)
                if written <= 0 { break }
                pointer += written
                remaining -= written
            }
        }
    }
}
