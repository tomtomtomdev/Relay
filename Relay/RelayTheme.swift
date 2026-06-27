//
//  RelayTheme.swift
//  Relay
//
//  Slice 10 — the design foundation (PLAN Slice 10). The *pure* core of the design
//  system: an `RGBA` value, the semantic `PaletteToken` set, and `RelayPalette.resolve`,
//  which maps each token to its dark/light value. Token values are transcribed from the
//  `design_handoff_relay` README's "Design Tokens" section.
//
//  Foundation-only and `nonisolated`/`Sendable` (like `AppStatus` / `BotConfig`) so it's
//  trivially unit-testable with no SwiftUI, no I/O, and no `@MainActor` hops. The SwiftUI
//  bridge (`Color`, fonts, spacing) and the reusable views live in `DesignComponents.swift`.
//

import Foundation

/// An 8-bit-per-channel colour. Comparable by exact components, so tests can pin the
/// design's hex values precisely.
nonisolated struct RGBA: Equatable, Sendable {
    let r: Int
    let g: Int
    let b: Int
    let a: Int

    init(r: Int, g: Int, b: Int, a: Int = 255) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// Parse `#RRGGBB`, `RRGGBB`, or `#RRGGBBAA` (case-insensitive). Returns `nil` for
    /// anything malformed rather than trapping — a constant table that fails to parse is
    /// caught by the unit tests, never at runtime.
    init?(hex raw: String) {
        let s = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        guard s.count == 6 || s.count == 8, s.allSatisfy({ $0.isHexDigit }) else { return nil }
        func byte(at offset: Int) -> Int {
            let start = s.index(s.startIndex, offsetBy: offset)
            let end = s.index(start, offsetBy: 2)
            return Int(s[start..<end], radix: 16)!   // safe: validated as hex above
        }
        self.r = byte(at: 0)
        self.g = byte(at: 2)
        self.b = byte(at: 4)
        self.a = s.count == 8 ? byte(at: 6) : 255
    }
}

/// System appearance the palette resolves against. Kept independent of SwiftUI's
/// `ColorScheme` so the core stays Foundation-only; the view layer bridges between them.
nonisolated enum Appearance: Sendable {
    case dark
    case light
}

/// The design's semantic colour roles (surfaces, text, borders, brand/status accents).
/// `CaseIterable` so a test can assert every role resolves in both appearances.
nonisolated enum PaletteToken: Sendable, CaseIterable {
    case windowBackground, sidebar, card, field, terminalBackground, titlebar
    case textPrimary, textSecondary, textTertiary, border
    case accent, accentHover, telegramBlue, claudeTerracotta, success, destructive
    case trafficRed, trafficYellow, trafficGreen
}

/// Resolves a semantic token to a concrete colour for a given appearance.
nonisolated enum RelayPalette {
    static func resolve(_ token: PaletteToken, _ appearance: Appearance) -> RGBA {
        switch appearance {
        case .dark:  dark(token)
        case .light: light(token)
        }
    }

    private static func hex(_ value: String) -> RGBA { RGBA(hex: value)! }

    // Dark appearance (the design's primary).
    private static func dark(_ token: PaletteToken) -> RGBA {
        switch token {
        case .windowBackground:  hex("#202022")
        case .sidebar:           hex("#191919")
        case .card:              hex("#2A2A2C")
        case .field:             hex("#1A1A1C")
        case .terminalBackground: hex("#161618")
        case .titlebar:          hex("#262628")
        case .textPrimary:       hex("#F5F5F7")
        case .textSecondary:     hex("#98989D")
        case .textTertiary:      hex("#6E6E73")
        case .border:            RGBA(r: 255, g: 255, b: 255, a: 23)   // ~rgba(255,255,255,.09)
        default:                 brand(token)
        }
    }

    // Light appearance.
    private static func light(_ token: PaletteToken) -> RGBA {
        switch token {
        case .windowBackground:  hex("#FFFFFF")
        case .sidebar:           hex("#F2F2F4")
        case .card:              hex("#F7F7F9")
        case .field:             hex("#FFFFFF")
        case .terminalBackground: hex("#161618")   // terminal stays dark in both appearances
        case .titlebar:          hex("#ECECEE")
        case .textPrimary:       hex("#1D1D1F")
        case .textSecondary:     hex("#6E6E73")
        case .textTertiary:      hex("#8A8A8F")
        case .border:            RGBA(r: 0, g: 0, b: 0, a: 20)         // ~rgba(0,0,0,.08)
        default:                 brand(token)
        }
    }

    // Brand / status accents are appearance-independent (shared by both tables).
    private static func brand(_ token: PaletteToken) -> RGBA {
        switch token {
        case .accent:           hex("#F0883E")
        case .accentHover:      hex("#F5A55F")
        case .telegramBlue:     hex("#2AABEE")
        case .claudeTerracotta: hex("#D97757")
        case .success:          hex("#32D74B")
        case .destructive:      hex("#FF6961")
        case .trafficRed:       hex("#FF5F57")
        case .trafficYellow:    hex("#FEBC2E")
        case .trafficGreen:     hex("#28C840")
        // Surfaces/text/border are resolved by dark()/light(); never reach here.
        case .windowBackground, .sidebar, .card, .field, .terminalBackground, .titlebar,
             .textPrimary, .textSecondary, .textTertiary, .border:
            hex("#FF00FF")   // unmistakable magenta if a table ever routes a surface here
        }
    }
}

/// Status-indicator dot states and the palette token each renders with (design: 7px dot
/// next to a card value / status row).
nonisolated enum DotState: Sendable {
    case connected, allowed, ready   // healthy → green
    case warn                        // attention → amber accent
    case error                       // failure → destructive
    case idle                        // paused/unknown → tertiary gray

    var token: PaletteToken {
        switch self {
        case .connected, .allowed, .ready: .success
        case .warn:  .accent
        case .error: .destructive
        case .idle:  .textTertiary
        }
    }
}
