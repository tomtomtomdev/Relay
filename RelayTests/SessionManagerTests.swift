//
//  SessionManagerTests.swift
//  RelayTests
//
//  Slice 4 — PTY session. Spawns real, short-lived local processes (echo / cat / sleep)
//  on a pseudo-terminal and asserts: output streams back, written input round-trips,
//  child-exit is detected, a bootstrap command runs after launch, `.always` respawns,
//  and teardown leaks no file descriptors (PLAN Slice 4).
//
//  Serialized: the fd-leak test reads a process-global count, so its own tests must not
//  race each other.
//

import Testing
import Foundation
@testable import Relay

@Suite(.serialized)
struct SessionManagerTests {

    // MARK: - Helpers

    /// Consume the manager's output until `marker` appears (or `timeout`), returning all
    /// text seen. On timeout the accumulated text is lost and `""` is returned so the
    /// caller's `contains` assertion fails loudly instead of hanging.
    private func collectOutput(
        from manager: SessionManager,
        until marker: String,
        timeout: Duration = .seconds(10)
    ) async -> String {
        let stream = await manager.output
        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                var accumulated = ""
                for await chunk in stream {
                    accumulated += String(decoding: chunk, as: UTF8.self)
                    if accumulated.contains(marker) { return accumulated }
                }
                return accumulated
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? ""
        }
    }

    /// Run `operation` to completion or give up after `timeout`. Returns whether it
    /// completed — keeps timing-sensitive tests from hanging the suite.
    @discardableResult
    private func runWithTimeout(
        _ timeout: Duration,
        _ operation: @escaping @Sendable () async -> Void
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await operation(); return true }
            group.addTask { try? await Task.sleep(for: timeout); return false }
            let completed = await group.next() ?? false
            group.cancelAll()
            return completed
        }
    }

    /// Count of currently-open file descriptors in this process.
    private func openFileDescriptorCount() -> Int {
        var count = 0
        let limit = getdtablesize()
        var fd: Int32 = 0
        while fd < limit {
            if fcntl(fd, F_GETFD) != -1 { count += 1 }
            fd += 1
        }
        return count
    }

    // MARK: - Tests

    @Test func outputFromSpawnedProcessStreamsBack() async throws {
        let manager = SessionManager(command: ["/bin/echo", "hello-from-relay"])
        try await manager.start()
        let out = await collectOutput(from: manager, until: "hello-from-relay")
        #expect(out.contains("hello-from-relay"))
        await manager.stop()
        await manager.waitUntilExited()
    }

    @Test func writtenInputRoundTripsThroughThePTY() async throws {
        let manager = SessionManager(command: ["/bin/cat"])
        try await manager.start()
        await manager.send("ping-7421")
        let out = await collectOutput(from: manager, until: "ping-7421")
        #expect(out.contains("ping-7421"))
        await manager.stop()
        await manager.waitUntilExited()
    }

    @Test func detectsChildProcessExit() async throws {
        let manager = SessionManager(command: ["/bin/echo", "done"])
        try await manager.start()
        let exited = await runWithTimeout(.seconds(10)) { await manager.waitUntilExited() }
        #expect(exited)
        #expect(await manager.isRunning == false)
    }

    @Test func bootstrapCommandRunsAfterLaunch() async throws {
        // "zsh -l first, then the configured claude command": the bootstrap line is typed
        // into the PTY after launch. Here `cat` echoes it straight back.
        let manager = SessionManager(command: ["/bin/cat"], bootstrap: "boot-2931")
        try await manager.start()
        let out = await collectOutput(from: manager, until: "boot-2931")
        #expect(out.contains("boot-2931"))
        await manager.stop()
        await manager.waitUntilExited()
    }

    @Test func respawnsChildWhenPolicyIsAlways() async throws {
        let manager = SessionManager(command: ["/bin/sleep", "0.1"], respawnPolicy: .always)
        try await manager.start()
        let respawned = await runWithTimeout(.seconds(10)) {
            while await manager.launchCount < 2 {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        await manager.stop()
        #expect(respawned)
        #expect(await manager.launchCount >= 2)
    }

    @Test func teardownClosesFileDescriptors() async throws {
        // Warm up once so one-time Foundation/libdispatch fd allocations are already paid.
        do {
            let warm = SessionManager(command: ["/bin/cat"])
            try await warm.start()
            await warm.send("warmup")
            await warm.stop()
            await warm.waitUntilExited()
        }
        try await Task.sleep(for: .milliseconds(300))
        let baseline = openFileDescriptorCount()

        for _ in 0..<8 {
            let manager = SessionManager(command: ["/bin/cat"])
            try await manager.start()
            await manager.send("x")
            await manager.stop()
            await manager.waitUntilExited()
        }
        try await Task.sleep(for: .milliseconds(300))
        let after = openFileDescriptorCount()

        // A genuine per-iteration leak would add ~8–16 fds across the loop; the small
        // slack absorbs transient libdispatch/Foundation fds without masking a real leak.
        #expect(after <= baseline + 2)
    }
}
