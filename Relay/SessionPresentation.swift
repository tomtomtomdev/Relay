//
//  SessionPresentation.swift
//  Relay
//
//  Slice 11 — the *pure* presentation core for the main window (frame 1). Following the
//  repo's pattern (`AppStatus.derive`, `ConfigSupport`), all the decidable bits live here
//  as `nonisolated`/`Sendable` value logic — no SwiftUI, no I/O — so the window's body can
//  stay thin and these can be exhaustively unit-tested:
//
//   • `MaskedID.format`        — masks a chat ID for display (`7129904842` ⇒ `7129•••842`).
//   • `SessionLogLine`         — classifies a terminal line into a colour `Kind` + token.
//   • `SessionStatus.derive`   — the three status cards (Telegram Bot / Source Chat /
//                                Claude Code) from the live flags + `BotConfig`.
//
//  No secret is ever surfaced: the bot token never appears in a card (we show connection
//  state, not the token); chat IDs are masked.
//

import Foundation

// MARK: - Masked chat ID

/// Formats a Telegram chat ID for display, hiding the middle digits (design frame 1 shows
/// `7129904842` as `7129•••842`). Keeps the first `prefix` and last `suffix` digits and
/// replaces the rest with bullets; the sign of a negative (group) ID is preserved. IDs too
/// short to mask meaningfully are returned unchanged.
nonisolated enum MaskedID {
    static func format(_ id: Int64, prefix: Int = 4, suffix: Int = 3, bullet: Character = "•") -> String {
        let text = String(id)
        let negative = text.hasPrefix("-")
        let digits = negative ? String(text.dropFirst()) : text
        guard digits.count > prefix + suffix else { return text }
        let head = digits.prefix(prefix)
        let tail = digits.suffix(suffix)
        let hidden = String(repeating: bullet, count: digits.count - prefix - suffix)
        return (negative ? "-" : "") + head + hidden + tail
    }
}

// MARK: - Terminal line classification

/// Classifies a line of terminal output into a colour role for the Live Session feed. The
/// rules are heuristic (these are real PTY lines, not the design's mock content) but pinned
/// by tests so the colouring can't drift silently.
nonisolated enum SessionLogLine {

    /// The colour role a line renders with (design frame 1). Each maps to a palette token.
    enum Kind: Sendable, Equatable, CaseIterable {
        case input    // operator command / quoted request — brightest
        case stdout   // ordinary program output
        case pass     // success markers (PASS / ✓)
        case warn     // warnings, errors, failures, permission prompts — amber
        case reply    // "replied to Telegram" acknowledgements — dimmed

        var token: PaletteToken {
            switch self {
            case .input:  .textPrimary
            case .stdout: .textSecondary
            case .pass:   .success
            case .warn:   .accent
            case .reply:  .textTertiary
            }
        }
    }

    static func classify(_ raw: String) -> Kind {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return .stdout }

        // Reply acknowledgements first — they may carry a trailing ✓ that isn't a "pass".
        if line.hasPrefix("↳") { return .reply }

        let lower = line.lowercased()
        if line.hasPrefix("⚠") || line.hasPrefix("✗")
            || lower.hasPrefix("fail")
            || lower.contains("error") || lower.contains("warning")
            || lower.contains("denied") || lower.contains("permission required") {
            return .warn
        }

        // Only the uppercase `PASS` test-runner marker (or a check glyph) is a pass; the
        // word "passed" in a summary line stays plain output.
        if line.contains("PASS") || line.contains("✓") || line.contains("✔") || lower.hasPrefix("ok") {
            return .pass
        }

        if line.hasPrefix("$") || isQuoted(line) { return .input }

        return .stdout
    }

    /// True when the line is wrapped in matching double quotes (a forwarded chat request).
    private static func isQuoted(_ line: String) -> Bool {
        line.count >= 2 && line.hasPrefix("\"") && line.hasSuffix("\"")
    }
}

// MARK: - Status cards

/// One of the three status cards at the top of the main window's content area.
nonisolated struct StatusCardModel: Equatable, Sendable, Identifiable {
    let label: String
    let value: String
    let dot: DotState
    let detail: String

    var id: String { label }   // the three labels are unique → stable ForEach identity
}

/// Derives the three status cards from the live session flags and the operator config.
/// Pure function of its inputs — mirrors `AppStatus.derive` and never reads a secret.
nonisolated enum SessionStatus {
    static func derive(
        isRunning: Bool, isUnlocked: Bool, hasError: Bool, settings: BotConfig
    ) -> [StatusCardModel] {
        [
            botCard(isRunning: isRunning, hasError: hasError, settings: settings),
            chatCard(isRunning: isRunning, settings: settings),
            claudeCard(isRunning: isRunning, isUnlocked: isUnlocked, settings: settings),
        ]
    }

    private static func botCard(isRunning: Bool, hasError: Bool, settings: BotConfig) -> StatusCardModel {
        let value: String, dot: DotState
        if hasError {
            value = "Error"; dot = .error
        } else if isRunning {
            value = "Connected"; dot = .connected
        } else {
            value = "Stopped"; dot = .idle
        }

        let detail: String
        if settings.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            detail = "No token set"   // never the token itself
        } else if isRunning {
            detail = "Polling for updates"
        } else {
            detail = "Idle"
        }

        return StatusCardModel(label: "Telegram Bot", value: value, dot: dot, detail: detail)
    }

    private static func chatCard(isRunning: Bool, settings: BotConfig) -> StatusCardModel {
        guard let first = settings.allowedIDs.first else {
            return StatusCardModel(label: "Source Chat", value: "None", dot: .idle, detail: "No allowed chats")
        }
        let extra = settings.allowedIDs.count - 1
        let detail = extra > 0 ? "\(MaskedID.format(first)) +\(extra) more" : MaskedID.format(first)
        return StatusCardModel(
            label: "Source Chat", value: "Allowed", dot: isRunning ? .allowed : .idle, detail: detail
        )
    }

    private static func claudeCard(isRunning: Bool, isUnlocked: Bool, settings: BotConfig) -> StatusCardModel {
        let value: String, dot: DotState
        if !isRunning {
            value = "Stopped"; dot = .idle
        } else if isUnlocked {
            value = "Ready"; dot = .ready
        } else {
            value = "Locked"; dot = .warn   // running but locked → needs /unlock
        }
        let command = settings.targetCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = command.isEmpty ? "No command set" : command
        return StatusCardModel(label: "Claude Code", value: value, dot: dot, detail: detail)
    }
}
