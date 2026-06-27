//
//  AppStatus.swift
//  Relay
//
//  Created by tommy yohanes on 26/06/26.
//

import Foundation

/// High-level state surfaced by the menu-bar status glyph.
///
/// See SPEC §4: the glyph reflects stopped / polling / unlocked / error.
/// Pure, `Sendable`, and `@MainActor`-free so later gate logic and actors can
/// read it without isolation hops.
nonisolated enum AppStatus: Sendable, CaseIterable {
    case stopped
    case polling
    case unlocked
    case error

    /// SF Symbol name for the menu-bar glyph in each state.
    var systemImageName: String {
        switch self {
        case .stopped:  "moon.zzz"
        case .polling:  "dot.radiowaves.left.and.right"
        case .unlocked: "lock.open"
        case .error:    "exclamationmark.triangle"
        }
    }

    /// Human-readable label for the menu-bar dropdown.
    var label: String {
        switch self {
        case .stopped:  "Stopped"
        case .polling:  "Polling"
        case .unlocked: "Unlocked"
        case .error:    "Error"
        }
    }
}

nonisolated extension AppStatus {
    /// Derive the glyph state from the bridge's live flags (Slice 7). An error always
    /// wins; otherwise a stopped bridge is `.stopped`, and a running one is `.unlocked`
    /// or `.polling` depending on the session lock.
    static func derive(isRunning: Bool, isUnlocked: Bool, hasError: Bool) -> AppStatus {
        if hasError { return .error }
        guard isRunning else { return .stopped }
        return isUnlocked ? .unlocked : .polling
    }
}
