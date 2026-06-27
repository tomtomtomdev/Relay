//
//  RelayThemeTests.swift
//  RelayTests
//
//  Slice 10 — the design foundation (PLAN Slice 10). The testable core of the design
//  system: hex parsing, the dark/light palette resolution, and the status-dot → token
//  mapping. Raw token values come straight from the `design_handoff_relay` README's
//  "Design Tokens" section; these tests pin them so a later restyle can't drift silently.
//  Pure (Foundation-only) — no SwiftUI, no I/O — mirroring `AppStatus` / `ConfigSupport`.
//

import Testing
import Foundation
@testable import Relay

struct RelayThemeTests {

    // MARK: - Hex parsing

    @Test func parsesSixDigitHexWithHash() {
        #expect(RGBA(hex: "#F0883E") == RGBA(r: 240, g: 136, b: 62))
        #expect(RGBA(hex: "#FFFFFF") == RGBA(r: 255, g: 255, b: 255))
    }

    @Test func parsesSixDigitHexWithoutHashAndIsCaseInsensitive() {
        #expect(RGBA(hex: "161618") == RGBA(r: 22, g: 22, b: 24))
        #expect(RGBA(hex: "f0883e") == RGBA(r: 240, g: 136, b: 62))
    }

    @Test func parsesEightDigitHexAsRGBA() {
        // Trailing pair is alpha: 0x80 == 128.
        #expect(RGBA(hex: "#F0883E80") == RGBA(r: 240, g: 136, b: 62, a: 128))
    }

    @Test func sixDigitHexDefaultsToOpaque() {
        #expect(RGBA(hex: "#202022")?.a == 255)
    }

    @Test func malformedHexReturnsNil() {
        #expect(RGBA(hex: "nope") == nil)
        #expect(RGBA(hex: "#12") == nil)        // too short
        #expect(RGBA(hex: "#GGGGGG") == nil)    // non-hex digits
        #expect(RGBA(hex: "") == nil)
    }

    // MARK: - Palette resolution (dark & light)

    @Test func windowBackgroundDiffersByAppearance() {
        #expect(RelayPalette.resolve(.windowBackground, .dark) == RGBA(hex: "#202022"))
        #expect(RelayPalette.resolve(.windowBackground, .light) == RGBA(hex: "#FFFFFF"))
    }

    @Test func terminalBackgroundStaysDarkInBothAppearances() {
        // Design: the terminal area is `#161618` in BOTH appearances.
        let dark = RelayPalette.resolve(.terminalBackground, .dark)
        let light = RelayPalette.resolve(.terminalBackground, .light)
        #expect(dark == RGBA(hex: "#161618"))
        #expect(dark == light)
    }

    @Test func primaryTextInvertsByAppearance() {
        #expect(RelayPalette.resolve(.textPrimary, .dark) == RGBA(hex: "#F5F5F7"))
        #expect(RelayPalette.resolve(.textPrimary, .light) == RGBA(hex: "#1D1D1F"))
        #expect(RelayPalette.resolve(.textPrimary, .dark) != RelayPalette.resolve(.textPrimary, .light))
    }

    @Test func accentFamilyIsAppearanceIndependent() {
        #expect(RelayPalette.resolve(.accent, .dark) == RGBA(hex: "#F0883E"))
        #expect(RelayPalette.resolve(.accent, .light) == RGBA(hex: "#F0883E"))
        #expect(RelayPalette.resolve(.accentHover, .dark) == RGBA(hex: "#F5A55F"))
        #expect(RelayPalette.resolve(.telegramBlue, .dark) == RGBA(hex: "#2AABEE"))
        #expect(RelayPalette.resolve(.claudeTerracotta, .dark) == RGBA(hex: "#D97757"))
        #expect(RelayPalette.resolve(.success, .dark) == RGBA(hex: "#32D74B"))
    }

    @Test func everyTokenResolvesInBothAppearances() {
        // No token may be missing from either table (would be a runtime gap in the UI).
        for token in PaletteToken.allCases {
            _ = RelayPalette.resolve(token, .dark)
            _ = RelayPalette.resolve(token, .light)
        }
    }

    // MARK: - Status-dot mapping

    @Test func connectedAllowedReadyAreSuccessGreen() {
        #expect(DotState.connected.token == .success)
        #expect(DotState.allowed.token == .success)
        #expect(DotState.ready.token == .success)
    }

    @Test func warnErrorIdleMapToTheirTokens() {
        #expect(DotState.warn.token == .accent)
        #expect(DotState.error.token == .destructive)
        #expect(DotState.idle.token == .textTertiary)
    }
}
