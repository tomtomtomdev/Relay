//
//  BotConfig.swift
//  Relay
//
//  Slice 1 — the operator's bot configuration (SPEC §4, §5).
//

import Foundation

/// Which built-in policy preset screens forwarded input (SPEC §3, gate 3). The full
/// denylist/flagged-pattern behaviour lands with the Authorizer in Slice 3; here the
/// preset is just a persisted selector. Default ships strict.
nonisolated enum PolicyPreset: String, Codable, Sendable, CaseIterable {
    case strict
    case standard
}

/// The single operator's configuration for the Telegram ⇄ PTY bridge.
///
/// Holds both secret material (`token`, `pairingSecret`) and non-secret settings.
/// The two are persisted by *different* mechanisms, and that split is enforced
/// structurally here:
///
/// - Secrets live in the Keychain only (`KeychainStore`) and are loaded into a
///   `BotConfig` at runtime.
/// - The `Codable` surface **omits** the secrets (see `CodingKeys`), so a `BotConfig`
///   can never serialize a token or pairing secret to disk in plaintext (SPEC §5).
/// - `description`/`debugDescription` redact the secrets so they can't leak via logs.
///
/// `nonisolated` + `Sendable` (like `AppStatus`) so actors and the pure Authorizer can
/// read it without `@MainActor` isolation hops.
nonisolated struct BotConfig: Codable, Equatable, Sendable {
    /// Telegram bot token. Secret — Keychain-only, never serialized, never logged.
    var token: String = ""
    /// Telegram `from.id`/`chat.id` values permitted through the identity gate.
    var allowedIDs: [Int64]
    /// One-time pairing secret for `/unlock`. Secret — Keychain-only, never logged.
    var pairingSecret: String = ""
    /// The interactive command driven through the PTY, e.g. `claude` or `zsh -l`.
    var targetCommand: String
    /// Seconds of inactivity before the session auto-relocks (SPEC §3, gate 2).
    var idleTimeout: TimeInterval
    /// Which policy preset screens forwarded input.
    var policyPreset: PolicyPreset

    /// Secrets are intentionally excluded so they cannot round-trip through disk.
    private enum CodingKeys: String, CodingKey {
        case allowedIDs, targetCommand, idleTimeout, policyPreset
    }
}

nonisolated extension BotConfig: CustomStringConvertible, CustomDebugStringConvertible {
    /// Redacted rendering — never exposes `token` or `pairingSecret`.
    var description: String {
        """
        BotConfig(allowedIDs: \(allowedIDs), targetCommand: "\(targetCommand)", \
        idleTimeout: \(idleTimeout), policyPreset: .\(policyPreset.rawValue), \
        token: <redacted>, pairingSecret: <redacted>)
        """
    }

    var debugDescription: String { description }
}
