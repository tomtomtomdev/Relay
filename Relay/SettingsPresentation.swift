//
//  SettingsPresentation.swift
//  Relay
//
//  Slice 13 — the *pure* presentation core for the redesigned, tabbed Settings window
//  (design frames 3 & 4, adapted to Hangar). Following the repo's pattern
//  (`SessionPresentation`, `PopoverPresentation`, `ConfigSupport`), every decidable bit
//  lives here as `nonisolated`/`Sendable` value logic — no SwiftUI, no I/O — so the settings
//  body stays thin and these can be exhaustively unit-tested:
//
//   • `TokenMask`      — the structure-preserving bot-token mask (`7847…3kQ`) shown in the
//                        collapsed field, plus the editable-vs-masked field state driven by
//                        the Reveal toggle. The mask NEVER exposes the hidden middle of the
//                        secret; the revealed value is only ever the live in-memory token
//                        (the guardrail: secrets stay in the Keychain / in memory, never a
//                        log, never `@AppStorage`).
//   • `AllowedIDChips` — the chip field's add (dedup, reject invalid) / remove logic,
//                        wrapping the Slice-7 `AllowedIDs.parse` so the allow-list field can
//                        be edited as removable chips instead of raw comma text.
//   • `PolicyPreset`   — display name + one-line summary for the *real* presets
//                        (`strict`/`standard`). The design's Ask/Auto/Plan modes are **not**
//                        invented here — they'd need an Authorizer/`Policy` change (backlog).
//   • `SettingsTab`    — the four tabs (Telegram / Claude / Distribution / General), in order.
//

import Foundation

// MARK: - Bot-token mask

/// What the token field should render given the Reveal toggle and whether a token is set.
nonisolated enum TokenFieldState: Equatable, Sendable {
    /// Show an editable field — the token is empty (nothing to hide) or Reveal is on.
    case editable
    /// Show this read-only masked value — a token is set and Reveal is off.
    case masked(String)
}

/// Masks a Telegram bot token for display, preserving its visible structure while hiding the
/// secret middle (design frame 3 shows `7847291043:AAH•••3kQ`). A Telegram token is
/// `<botID>:<authSecret>`; we keep the (non-secret) bot ID and the first/last few characters
/// of the auth secret, replacing the rest with bullets. A value too short to reveal ends
/// safely becomes all bullets. The hidden characters never appear anywhere in the output.
nonisolated enum TokenMask {
    static func mask(
        _ token: String, visiblePrefix: Int = 3, visibleSuffix: Int = 3, bullet: Character = "•"
    ) -> String {
        guard !token.isEmpty else { return "" }
        if let colon = token.firstIndex(of: ":") {
            let head = String(token[...colon])                       // "<botID>:" — not secret
            let secret = String(token[token.index(after: colon)...])
            return head + maskRun(secret, visiblePrefix, visibleSuffix, bullet)
        }
        return maskRun(token, visiblePrefix, visibleSuffix, bullet)
    }

    /// What the field shows: the editable control when empty or revealed, otherwise the mask.
    /// The revealed value is supplied by the view from the live in-memory token — this only
    /// decides *which* control to show, never persists or logs the secret.
    static func fieldState(token: String, revealed: Bool) -> TokenFieldState {
        (revealed || token.isEmpty) ? .editable : .masked(mask(token))
    }

    /// Mask a single run: keep `prefix`/`suffix` chars with bullets between, or — when the run
    /// is too short to keep both ends — replace it entirely with bullets (reveals nothing).
    private static func maskRun(_ s: String, _ prefix: Int, _ suffix: Int, _ bullet: Character) -> String {
        guard s.count > prefix + suffix else {
            return String(repeating: bullet, count: s.count)
        }
        let head = s.prefix(prefix)
        let tail = s.suffix(suffix)
        let hidden = String(repeating: bullet, count: s.count - prefix - suffix)
        return String(head) + hidden + String(tail)
    }
}

// MARK: - Allowed-ID chip field

/// The chip field's edit logic for the allowed-chat-ID allow-list. Wraps the Slice-7
/// `AllowedIDs.parse` so a pasted token (or comma-separated batch) becomes chips: valid,
/// not-already-present IDs are appended in order; duplicates and non-numeric/blank tokens are
/// dropped. Pure value logic over `[Int64]`.
nonisolated enum AllowedIDChips {
    /// Parse `input` (one ID, or a comma-separated batch) and append any valid, new IDs to
    /// `existing`, preserving order. Invalid/blank tokens and duplicates are ignored, so it's
    /// idempotent: adding an ID that's already present is a no-op.
    static func add(_ input: String, to existing: [Int64]) -> [Int64] {
        var result = existing
        for id in AllowedIDs.parse(input) where !result.contains(id) {
            result.append(id)
        }
        return result
    }

    /// Remove a chip's ID from the allow-list. Removing a missing ID is a no-op.
    static func remove(_ id: Int64, from existing: [Int64]) -> [Int64] {
        existing.filter { $0 != id }
    }
}

// MARK: - Policy preset display

nonisolated extension PolicyPreset {
    /// Title for the permission-mode segmented control.
    var displayName: String {
        switch self {
        case .strict:   "Strict"
        case .standard: "Standard"
        }
    }

    /// One-line description of what the preset screens (SPEC §3, gate 3 / Slice-3 `Policy`).
    var summary: String {
        switch self {
        case .strict:   "Blocks dangerous commands and holds risky ones for /confirm."
        case .standard: "Only the most destructive commands are blocked."
        }
    }
}

// MARK: - Settings tabs

/// The four tabs of the redesigned settings window (design frames 3 & 4, adapted to Hangar).
nonisolated enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case telegram, claude, distribution, general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .telegram:     "Telegram"
        case .claude:       "Claude"
        case .distribution: "Distribution"
        case .general:      "General"
        }
    }

    /// SF Symbol for the tab's toolbar chip.
    var icon: String {
        switch self {
        case .telegram:     "paperplane"
        case .claude:       "terminal"
        case .distribution: "shippingbox"
        case .general:      "gearshape"
        }
    }
}
