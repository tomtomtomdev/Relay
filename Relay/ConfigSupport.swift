//
//  ConfigSupport.swift
//  Relay
//
//  Slice 7 — pure helpers the menu-bar view-model builds on (PLAN Slice 7): settings
//  validation, the allowed-IDs text⇄[Int64] bridge for the form field, the live-tail
//  ring buffer, and a default config to seed a fresh install. All `nonisolated` value
//  logic — no I/O, no SwiftUI — so it's trivially unit-tested.
//

import Foundation

/// A reason a `BotConfig` isn't ready to start the bridge. Drives the settings form's
/// inline guidance and the menu's disabled "Start".
nonisolated enum ConfigIssue: Equatable, Sendable {
    case missingToken
    case noAllowedIDs
    case missingPairingSecret
    case missingTargetCommand
    case nonPositiveIdleTimeout

    var message: String {
        switch self {
        case .missingToken:          "Add a Telegram bot token."
        case .noAllowedIDs:          "Add at least one allowed chat ID."
        case .missingPairingSecret:  "Set a pairing secret for /unlock."
        case .missingTargetCommand:  "Set the command to run in the session."
        case .nonPositiveIdleTimeout: "Idle timeout must be greater than zero."
        }
    }
}

nonisolated extension BotConfig {

    /// A blank-but-sane starting point for a fresh install (no secrets, strict policy).
    static let `default` = BotConfig(
        token: "",
        allowedIDs: [],
        pairingSecret: "",
        targetCommand: "claude",
        idleTimeout: 300,
        policyPreset: .strict
    )

    /// Everything that would prevent a clean start. Empty ⇒ startable.
    func validationIssues() -> [ConfigIssue] {
        var issues: [ConfigIssue] = []
        if token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append(.missingToken) }
        if allowedIDs.isEmpty { issues.append(.noAllowedIDs) }
        if pairingSecret.isEmpty { issues.append(.missingPairingSecret) }
        if targetCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append(.missingTargetCommand) }
        if idleTimeout <= 0 { issues.append(.nonPositiveIdleTimeout) }
        return issues
    }

    var isStartable: Bool { validationIssues().isEmpty }
}

/// Converts the allow-list between its stored `[Int64]` and the comma-separated text the
/// settings field edits. Non-numeric and blank tokens are dropped, never crashing.
nonisolated enum AllowedIDs {
    static func parse(_ text: String) -> [Int64] {
        text.split(separator: ",").compactMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
    }

    static func format(_ ids: [Int64]) -> String {
        ids.map(String.init).joined(separator: ", ")
    }
}

/// A bounded buffer of the most recent output chunks for the menu's live tail. Oldest
/// lines fall off once `capacity` is reached — never grows without bound.
nonisolated struct OutputTail: Equatable, Sendable {
    let capacity: Int
    private(set) var lines: [String] = []

    init(capacity: Int = 50) {
        self.capacity = max(1, capacity)
    }

    mutating func append(_ line: String) {
        lines.append(line)
        if lines.count > capacity {
            lines.removeFirst(lines.count - capacity)
        }
    }
}
