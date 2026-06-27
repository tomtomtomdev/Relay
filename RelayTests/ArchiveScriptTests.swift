//
//  ArchiveScriptTests.swift
//  RelayTests
//
//  Slice 8 — the real `scripts/archive.sh` (PLAN Slice 8). The script shells out to
//  xcodebuild / create-dmg / notarytool / stapler (zero-dep guardrail), so it can't run
//  for real offline. Instead this lints it (`bash -n`) and exercises its `--dry-run` mode,
//  which plans the whole pipeline — archive → export → dmg → notarize → staple — and
//  prints the artifact contract line, all without invoking a single external tool or doing
//  any live notarization. Also asserts the script never inlines a notary secret.
//

import Testing
import Foundation

@Suite struct ArchiveScriptTests {

    /// The committed script, resolved relative to this source file (repo/RelayTests/…).
    private var scriptURL: URL {
        URL(fileURLWithPath: #filePath)            // …/RelayTests/ArchiveScriptTests.swift
            .deletingLastPathComponent()           // …/RelayTests
            .deletingLastPathComponent()           // repo root
            .appendingPathComponent("scripts/archive.sh")
    }

    /// Run a command, returning (exitCode, stdout, stderr).
    private func run(_ executable: String, _ arguments: [String]) throws -> (Int32, String, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe(); let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(decoding: outData, as: UTF8.self),
                String(decoding: errData, as: UTF8.self))
    }

    @Test func scriptExists() {
        #expect(FileManager.default.fileExists(atPath: scriptURL.path))
    }

    @Test func scriptPassesBashSyntaxLint() throws {
        let (status, _, stderr) = try run("/bin/bash", ["-n", scriptURL.path])
        #expect(status == 0, "bash -n reported: \(stderr)")
    }

    @Test func dryRunPlansThePipelineAndAnnouncesTheArtifact() throws {
        let (status, stdout, stderr) = try run("/bin/bash", [scriptURL.path, "--dry-run"])
        #expect(status == 0, "dry run failed: \(stderr)")

        // stdout carries exactly the artifact contract the Archiver adapter parses.
        let artifactLine = stdout.split(separator: "\n").first { $0.hasPrefix("RELAY_ARTIFACT=") }
        let line = try #require(artifactLine.map(String.init), "no RELAY_ARTIFACT= line on stdout")
        #expect(line.hasSuffix(".dmg"))

        // Every pipeline stage is planned (logged to stderr), but nothing is executed.
        let plan = stderr.lowercased()
        for stage in ["archive", "export", "create-dmg", "notarytool", "stapler"] {
            #expect(plan.contains(stage), "dry-run plan is missing the \(stage) stage")
        }
    }

    @Test func neverInlinesANotarySecret() throws {
        let source = try String(contentsOf: scriptURL, encoding: .utf8)
        // Credentials must come from a notarytool keychain profile (a name, not a secret).
        #expect(source.contains("--keychain-profile"))
        // …and the script must never carry an inline password / app-specific secret.
        #expect(!source.contains("--password"))
        #expect(!source.contains("--apple-id"))
    }
}
