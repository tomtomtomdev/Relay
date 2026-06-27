//
//  ArchiverTests.swift
//  RelayTests
//
//  Slice 8 — the app-side archive adapter (PLAN Slice 8, SPEC §6). `Archiver` drives
//  `scripts/archive.sh` through an injected `CommandRunner`, so the whole adapter is
//  exercised here against a *stub runner* — no xcodebuild, no notarytool, no live
//  notarization. The stub records the invocation and replays a canned result; the tests
//  assert the adapter shells out to the right command, parses the artifact contract, maps
//  failures to typed errors, and never smuggles a secret into the call.
//

import Testing
import Foundation
@testable import Relay

@Suite struct ArchiverTests {

    /// Records the last invocation and replays a canned result — stands in for a real
    /// process launch so the adapter is testable with zero side effects.
    private final class StubCommandRunner: CommandRunner, @unchecked Sendable {
        struct Invocation: Sendable, Equatable {
            let executable: String
            let arguments: [String]
        }
        private(set) var invocations: [Invocation] = []
        private let result: CommandResult
        init(_ result: CommandResult) { self.result = result }

        func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandResult {
            invocations.append(.init(executable: executable, arguments: arguments))
            return result
        }
    }

    /// A throwaway file standing in for the script, so the adapter's existence check
    /// passes without depending on the repo layout. The stub runner never executes it.
    private func makeScript() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-archive-\(UUID().uuidString).sh")
        try "#!/bin/bash\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func successParsesTheArtifactFromScriptStdout() async throws {
        let script = try makeScript()
        defer { try? FileManager.default.removeItem(at: script) }
        let runner = StubCommandRunner(CommandResult(
            exitCode: 0,
            standardOutput: "some log noise\nRELAY_ARTIFACT=/tmp/Relay.dmg\n",
            standardError: ""
        ))
        let archiver = Archiver(scriptURL: script, runner: runner)

        let outcome = try await archiver.archive(dryRun: false)
        #expect(outcome.artifact == URL(fileURLWithPath: "/tmp/Relay.dmg"))
        #expect(outcome.dryRun == false)
    }

    @Test func shellsOutToBashWithTheScriptPath() async throws {
        let script = try makeScript()
        defer { try? FileManager.default.removeItem(at: script) }
        let runner = StubCommandRunner(CommandResult(
            exitCode: 0, standardOutput: "RELAY_ARTIFACT=/tmp/Relay.dmg\n", standardError: ""
        ))
        let archiver = Archiver(scriptURL: script, runner: runner)

        _ = try await archiver.archive(dryRun: false)
        let call = try #require(runner.invocations.first)
        #expect(call.executable == "/bin/bash")
        #expect(call.arguments.first == script.path)
    }

    @Test func dryRunPassesTheFlagAndIsReflectedInTheOutcome() async throws {
        let script = try makeScript()
        defer { try? FileManager.default.removeItem(at: script) }
        let runner = StubCommandRunner(CommandResult(
            exitCode: 0, standardOutput: "RELAY_ARTIFACT=/tmp/Relay.dmg\n", standardError: ""
        ))
        let archiver = Archiver(scriptURL: script, runner: runner)

        let outcome = try await archiver.archive(dryRun: true)
        let call = try #require(runner.invocations.first)
        #expect(call.arguments.contains("--dry-run"))
        #expect(outcome.dryRun == true)
    }

    @Test func nonZeroExitMapsToScriptFailedCarryingStderr() async throws {
        let script = try makeScript()
        defer { try? FileManager.default.removeItem(at: script) }
        let runner = StubCommandRunner(CommandResult(
            exitCode: 65, standardOutput: "", standardError: "xcodebuild: error: scheme not found"
        ))
        let archiver = Archiver(scriptURL: script, runner: runner)

        await #expect(throws: ArchiveError.self) {
            try await archiver.archive(dryRun: false)
        }
        do {
            _ = try await archiver.archive(dryRun: false)
            Issue.record("expected a throw")
        } catch let ArchiveError.scriptFailed(exitCode, message) {
            #expect(exitCode == 65)
            #expect(message.contains("scheme not found"))
        }
    }

    @Test func successWithoutTheArtifactLineThrows() async throws {
        let script = try makeScript()
        defer { try? FileManager.default.removeItem(at: script) }
        let runner = StubCommandRunner(CommandResult(
            exitCode: 0, standardOutput: "built everything but forgot to announce it\n", standardError: ""
        ))
        let archiver = Archiver(scriptURL: script, runner: runner)

        await #expect(throws: ArchiveError.noArtifactProduced) {
            try await archiver.archive(dryRun: false)
        }
    }

    @Test func missingScriptThrowsBeforeRunning() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-missing-\(UUID().uuidString).sh")
        let runner = StubCommandRunner(CommandResult(exitCode: 0, standardOutput: "", standardError: ""))
        let archiver = Archiver(scriptURL: missing, runner: runner)

        await #expect(throws: ArchiveError.self) {
            try await archiver.archive(dryRun: false)
        }
        #expect(runner.invocations.isEmpty)   // never even tried to run
    }

    /// The archive pipeline has nothing to do with the bot token or pairing secret, so the
    /// adapter must not pass them (or any extra payload) to the runner — only bash, the
    /// script path, and the optional `--dry-run` flag.
    @Test func passesNoSecretsOrExtraArgumentsToTheRunner() async throws {
        let script = try makeScript()
        defer { try? FileManager.default.removeItem(at: script) }
        let runner = StubCommandRunner(CommandResult(
            exitCode: 0, standardOutput: "RELAY_ARTIFACT=/tmp/Relay.dmg\n", standardError: ""
        ))
        let archiver = Archiver(scriptURL: script, runner: runner)

        _ = try await archiver.archive(dryRun: true)
        let call = try #require(runner.invocations.first)
        #expect(call.arguments == [script.path, "--dry-run"])
    }
}
