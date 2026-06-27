//
//  PopoverPresentation.swift
//  Relay
//
//  Slice 12 — the *pure* presentation core for the status-bar popover (design frame 2).
//  Following the repo pattern (`AppStatus.derive`, `SessionStatus.derive`), the decidable
//  logic lives here as `nonisolated`/`Sendable` value logic — no SwiftUI, no I/O — so the
//  popover body stays thin and this can be exhaustively unit-tested.
//
//  The popover's status rows reuse `SessionStatus.derive` (Slice 11); the new piece is
//  `RecentCommands.derive`, which condenses the live output tail into a bounded "Recent"
//  list (status icon + mono command + time). It surfaces no secret — only command text the
//  operator already typed and outcomes inferred from the visible feed.
//

import Foundation

// MARK: - Recent command

/// One row of the popover's "Recent" list: the shell command the operator ran, an inferred
/// outcome (from the lines that followed it), and a timestamp *if* the feed carried one.
nonisolated struct RecentCommand: Equatable, Sendable {
    let command: String
    /// `HH:MM` parsed from a timestamp line preceding the command, else `nil`. Real PTY
    /// output has no timestamps, so this is honestly absent rather than fabricated.
    let time: String?
    let outcome: Outcome

    /// The inferred result of a command, drawn from the lines between it and the next one.
    enum Outcome: Sendable, Equatable, CaseIterable {
        case ok       // a following success marker (PASS / ✓) and no failure
        case warn     // a following warning / error / failure / permission prompt
        case neutral  // ran, but the feed showed no clear outcome

        /// Palette token for the row's leading status glyph (design: green ✓ / amber ⚠ / gray).
        var token: PaletteToken {
            switch self {
            case .ok:      .success
            case .warn:    .accent
            case .neutral: .textTertiary
            }
        }

        /// SF Symbol for the leading status glyph.
        var symbol: String {
            switch self {
            case .ok:      "checkmark"
            case .warn:    "exclamationmark.triangle.fill"
            case .neutral: "circle.fill"
            }
        }
    }
}

/// Derives the popover's "Recent" list from the live output tail. Pure function of its
/// input: scans for `$`-prefixed command lines, infers each one's outcome from the lines up
/// to the next command, attaches the most recent preceding timestamp, and returns the most
/// recent `limit` commands newest-first. Bounded by `limit` — never grows without bound.
nonisolated enum RecentCommands {
    static func derive(from lines: [String], limit: Int = 6) -> [RecentCommand] {
        // 1. Locate command lines, remembering the last timestamp seen at/before each.
        var commands: [(index: Int, text: String, time: String?)] = []
        var lastTime: String?
        for (i, line) in lines.enumerated() {
            if let t = leadingTime(line) { lastTime = t }
            if let text = commandText(from: line) { commands.append((i, text, lastTime)) }
        }

        // 2. Infer each command's outcome from the lines until the next command.
        var result: [RecentCommand] = []
        for (n, cmd) in commands.enumerated() {
            let end = (n + 1 < commands.count) ? commands[n + 1].index : lines.count
            let following = lines[(cmd.index + 1)..<end]
            result.append(RecentCommand(command: cmd.text, time: cmd.time, outcome: outcome(of: following)))
        }

        // 3. Most-recent-first, bounded to `limit`.
        return Array(result.suffix(max(0, limit)).reversed())
    }

    /// The shell command on a `$`-prefixed prompt line, or `nil`. A bare `$` (the caret-only
    /// prompt line) and ordinary output both yield `nil`.
    private static func commandText(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("$") else { return nil }
        let rest = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : String(rest)
    }

    /// A leading `HH:MM` clock at the start of the line (design feed: `14:32  Telegram ▸ …`).
    private static func leadingTime(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let range = trimmed.range(of: #"^\d{1,2}:\d{2}"#, options: .regularExpression) else { return nil }
        return String(trimmed[range])
    }

    /// Classifies the run of lines following a command. A warning anywhere wins; otherwise a
    /// success marker makes it `.ok`; with neither it's `.neutral`. Reuses the Slice-11
    /// line classifier so colouring stays consistent with the live terminal feed.
    private static func outcome(of lines: ArraySlice<String>) -> RecentCommand.Outcome {
        var sawPass = false
        for line in lines {
            switch SessionLogLine.classify(line) {
            case .warn:  return .warn          // a failure takes precedence immediately
            case .pass:  sawPass = true
            default:     break
            }
        }
        return sawPass ? .ok : .neutral
    }
}
