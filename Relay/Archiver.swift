//
//  Archiver.swift
//  Relay
//
//  Slice 8 — the app-side archive adapter (PLAN Slice 8, SPEC §6). The real archiving
//  pipeline (xcodebuild → Developer ID export → create-dmg → notarytool → stapler) lives in
//  `scripts/archive.sh`; this is the thin Swift adapter that drives it and surfaces the
//  result to the menu bar's "Build & Archive".
//
//  Zero-dep guardrail: the heavy tools are shelled out by the script, never linked. The
//  adapter shells out through a `CommandRunner` seam, so the whole thing is unit-tested
//  against a stub — no xcodebuild, no notarytool, no live notarization. The archive
//  pipeline touches no secrets: the notary credentials live in a keychain profile named
//  inside the script, so this adapter passes only the script path and an optional flag.
//

import Foundation

// MARK: - Command runner seam

/// The captured result of running an external command.
nonisolated struct CommandResult: Sendable, Equatable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
}

/// Abstracts launching an external process. The seam that lets `Archiver` be driven by a
/// stub in tests instead of really shelling out.
nonisolated protocol CommandRunner: Sendable {
    func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandResult
}

/// The production runner: launches the command with `Foundation.Process`, draining stdout
/// and stderr concurrently so a chatty build can't deadlock on a full pipe buffer. Never
/// exercised in tests (those inject a stub).
nonisolated struct ProcessCommandRunner: CommandRunner {
    func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()

        // Drain both pipes concurrently (capturing only the fd, which is Sendable).
        async let out = Self.drain(outPipe.fileHandleForReading.fileDescriptor)
        async let err = Self.drain(errPipe.fileHandleForReading.fileDescriptor)
        let (outData, errData) = await (out, err)
        process.waitUntilExit()   // returns promptly: both pipes have already hit EOF

        return CommandResult(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: outData, as: UTF8.self),
            standardError: String(decoding: errData, as: UTF8.self)
        )
    }

    /// Read a file descriptor to EOF on a dedicated thread (same idiom as the PTY read
    /// loop). Captures only the `Int32` fd, so it crosses no concurrency boundary.
    private static func drain(_ fd: Int32) async -> Data {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
            let thread = Thread {
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let n = read(fd, &buffer, buffer.count)
                    if n > 0 { data.append(contentsOf: buffer[0..<n]) } else { break }
                }
                continuation.resume(returning: data)
            }
            thread.name = "Relay.ProcessCommandRunner.drain"
            thread.start()
        }
    }
}

// MARK: - Outcome / errors

/// What a successful archive produced.
nonisolated struct ArchiveOutcome: Sendable, Equatable {
    /// The notarized, stapled artifact ready to distribute (a `.dmg`).
    let artifact: URL
    /// Whether the pipeline was only *planned* (`--dry-run`), not executed.
    let dryRun: Bool
}

/// Why an archive failed. Carries only tool output — never a secret (the pipeline never
/// handles the bot token, pairing secret, or notary credentials).
nonisolated enum ArchiveError: Error, Equatable {
    case scriptMissing(path: String)
    case scriptFailed(exitCode: Int32, message: String)
    case noArtifactProduced
}

// MARK: - Adapter

/// Lets the view-model trigger an archive without knowing whether it's the real script
/// runner or a test stub.
nonisolated protocol ArchiveRunning: Sendable {
    func archive(dryRun: Bool) async throws -> ArchiveOutcome
}

/// Drives `scripts/archive.sh` through an injected `CommandRunner` and maps its result to
/// a typed `ArchiveOutcome` / `ArchiveError`.
nonisolated struct Archiver: ArchiveRunning {

    /// The line the script prints on stdout to announce the built artifact.
    private static let artifactPrefix = "RELAY_ARTIFACT="

    private let scriptURL: URL
    private let runner: CommandRunner
    private let workingDirectory: URL?

    init(scriptURL: URL, runner: CommandRunner = ProcessCommandRunner(), workingDirectory: URL? = nil) {
        self.scriptURL = scriptURL
        self.runner = runner
        self.workingDirectory = workingDirectory
    }

    func archive(dryRun: Bool) async throws -> ArchiveOutcome {
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw ArchiveError.scriptMissing(path: scriptURL.path)
        }

        var arguments = [scriptURL.path]
        if dryRun { arguments.append("--dry-run") }

        let result = try await runner.run(
            executable: "/bin/bash",
            arguments: arguments,
            currentDirectory: workingDirectory
        )

        guard result.exitCode == 0 else {
            throw ArchiveError.scriptFailed(
                exitCode: result.exitCode,
                message: Self.sanitize(result.standardError)
            )
        }
        guard let artifact = Self.parseArtifact(result.standardOutput) else {
            throw ArchiveError.noArtifactProduced
        }
        return ArchiveOutcome(artifact: artifact, dryRun: dryRun)
    }

    /// Pull the artifact path out of the script's `RELAY_ARTIFACT=…` contract line.
    static func parseArtifact(_ stdout: String) -> URL? {
        for line in stdout.split(separator: "\n", omittingEmptySubsequences: true) where line.hasPrefix(artifactPrefix) {
            let path = String(line.dropFirst(artifactPrefix.count)).trimmingCharacters(in: .whitespaces)
            if !path.isEmpty { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    /// Keep a failure message bounded for the UI. The script never prints secrets, so this
    /// just trims and caps length — it doesn't need to scrub.
    static func sanitize(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let cap = 500
        return trimmed.count > cap ? String(trimmed.prefix(cap)) + "…" : trimmed
    }

    /// The default script location: a bundled resource if present, else `scripts/archive.sh`
    /// resolved relative to this source file (works for a locally-built dev binary — and
    /// archiving is a dev/CI action by design, SPEC §6).
    static var defaultScriptURL: URL {
        if let bundled = Bundle.main.url(forResource: "archive", withExtension: "sh") {
            return bundled
        }
        return URL(fileURLWithPath: #filePath)   // …/Relay/Archiver.swift
            .deletingLastPathComponent()          // …/Relay
            .deletingLastPathComponent()          // repo root
            .appendingPathComponent("scripts/archive.sh")
    }
}
