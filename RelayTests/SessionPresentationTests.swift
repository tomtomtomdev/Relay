//
//  SessionPresentationTests.swift
//  RelayTests
//
//  Slice 11 — the testable presentation core for the main window (frame 1). The SwiftUI
//  body stays thin; everything decidable lives here and is pinned by these tests:
//   • `MaskedID.format`      — chat-ID masking (`7129904842` ⇒ `7129•••842`).
//   • `SessionLogLine.classify` — colour kind for each terminal line + its palette token.
//   • `SessionStatus.derive`  — the three status cards from `AppModel` flags + `BotConfig`.
//  Pure (Foundation-only) — no SwiftUI, no I/O — mirroring `AppStatus` / `ConfigSupport`.
//

import Testing
import Foundation
@testable import Relay

struct SessionPresentationTests {

    // MARK: - MaskedID

    @Test func masksTheCanonicalDesignID() {
        // Design frame 1: `7129904842` is shown as `7129•••842`.
        #expect(MaskedID.format(7129904842) == "7129•••842")
    }

    @Test func shortIDsAreNotMasked() {
        #expect(MaskedID.format(123) == "123")           // fewer than prefix+suffix digits
        #expect(MaskedID.format(1234567) == "1234567")   // exactly prefix+suffix: nothing to hide
    }

    @Test func bulletsAreProportionalToHiddenDigits() {
        #expect(MaskedID.format(12345678) == "1234•678")          // 8 digits → 1 hidden
        #expect(MaskedID.format(123456789012) == "1234•••••012")  // 12 digits → 5 hidden
    }

    @Test func negativeIDsKeepTheirSign() {
        // Telegram group IDs are negative; the sign is preserved, the digits masked.
        #expect(MaskedID.format(-100488213) == "-1004••213")
    }

    // MARK: - SessionLogLine.classify

    @Test func classifiesTheDesignTerminalLines() {
        #expect(SessionLogLine.classify(" PASS  src/auth.test.ts") == .pass)
        #expect(SessionLogLine.classify("⚠ permission required: deploy") == .warn)
        #expect(SessionLogLine.classify("$ npm test") == .input)
        #expect(SessionLogLine.classify("\"run the test suite\"") == .input)
    }

    @Test func replyPrefixWinsOverTheTrailingCheckmark() {
        // `↳ replied to Telegram ✓` contains a ✓ but is a reply line, not a pass line.
        #expect(SessionLogLine.classify("↳ replied to Telegram ✓") == .reply)
    }

    @Test func warnCoversErrorsAndFailures() {
        #expect(SessionLogLine.classify("error: build failed") == .warn)
        #expect(SessionLogLine.classify("FAIL src/api.test.ts") == .warn)
    }

    @Test func plainOutputAndSummaryAreStdout() {
        // Only the uppercase `PASS` marker is a pass; the word "passed" stays plain.
        #expect(SessionLogLine.classify("Tests: 24 passed, 24 total") == .stdout)
        #expect(SessionLogLine.classify("Compiling module Relay…") == .stdout)
        #expect(SessionLogLine.classify("") == .stdout)
        #expect(SessionLogLine.classify("   ") == .stdout)
    }

    @Test func eachKindMapsToItsPaletteToken() {
        #expect(SessionLogLine.Kind.input.token == .textPrimary)
        #expect(SessionLogLine.Kind.stdout.token == .textSecondary)
        #expect(SessionLogLine.Kind.pass.token == .success)
        #expect(SessionLogLine.Kind.warn.token == .accent)
        #expect(SessionLogLine.Kind.reply.token == .textTertiary)
    }

    // MARK: - SessionStatus.derive

    /// A fully-configured operator config for the card tests.
    private static func config(
        token: String = "123:ABC",
        allowedIDs: [Int64] = [7129904842],
        targetCommand: String = "claude"
    ) -> BotConfig {
        BotConfig(
            token: token, allowedIDs: allowedIDs, pairingSecret: "secret",
            targetCommand: targetCommand, idleTimeout: 300, policyPreset: .strict
        )
    }

    @Test func derivesThreeCardsInOrder() {
        let cards = SessionStatus.derive(
            isRunning: true, isUnlocked: true, hasError: false, settings: Self.config()
        )
        #expect(cards.count == 3)
        #expect(cards.map(\.label) == ["Telegram Bot", "Source Chat", "Claude Code"])
    }

    @Test func runningUnlockedSessionIsAllHealthy() {
        let cards = SessionStatus.derive(
            isRunning: true, isUnlocked: true, hasError: false, settings: Self.config()
        )
        #expect(cards[0].value == "Connected"); #expect(cards[0].dot == .connected)
        #expect(cards[0].detail == "Polling for updates")
        #expect(cards[1].value == "Allowed");   #expect(cards[1].dot == .allowed)
        #expect(cards[1].detail == "7129•••842")
        #expect(cards[2].value == "Ready");     #expect(cards[2].dot == .ready)
        #expect(cards[2].detail == "claude")
    }

    @Test func stoppedSessionGoesGray() {
        let cards = SessionStatus.derive(
            isRunning: false, isUnlocked: false, hasError: false, settings: Self.config()
        )
        #expect(cards[0].value == "Stopped"); #expect(cards[0].dot == .idle)
        #expect(cards[0].detail == "Idle")
        #expect(cards[1].dot == .idle)        // source chat dot goes gray when paused
        #expect(cards[2].value == "Stopped"); #expect(cards[2].dot == .idle)
    }

    @Test func errorShowsOnTheBotCard() {
        let cards = SessionStatus.derive(
            isRunning: true, isUnlocked: true, hasError: true, settings: Self.config()
        )
        #expect(cards[0].value == "Error"); #expect(cards[0].dot == .error)
    }

    @Test func lockedRunningSessionFlagsClaudeCard() {
        let cards = SessionStatus.derive(
            isRunning: true, isUnlocked: false, hasError: false, settings: Self.config()
        )
        #expect(cards[0].value == "Connected")   // bot stays connected regardless of lock
        #expect(cards[2].value == "Locked"); #expect(cards[2].dot == .warn)
    }

    @Test func missingTokenIsCalledOut() {
        let cards = SessionStatus.derive(
            isRunning: false, isUnlocked: false, hasError: false, settings: Self.config(token: "")
        )
        #expect(cards[0].detail == "No token set")
    }

    @Test func noAllowedChatsIsCalledOut() {
        let cards = SessionStatus.derive(
            isRunning: true, isUnlocked: true, hasError: false, settings: Self.config(allowedIDs: [])
        )
        #expect(cards[1].value == "None"); #expect(cards[1].dot == .idle)
        #expect(cards[1].detail == "No allowed chats")
    }

    @Test func multipleAllowedChatsSummariseTheRest() {
        let cards = SessionStatus.derive(
            isRunning: true, isUnlocked: true, hasError: false,
            settings: Self.config(allowedIDs: [7129904842, -100488213])
        )
        #expect(cards[1].detail == "7129•••842 +1 more")
    }

    @Test func missingTargetCommandIsCalledOut() {
        let cards = SessionStatus.derive(
            isRunning: false, isUnlocked: false, hasError: false, settings: Self.config(targetCommand: "")
        )
        #expect(cards[2].detail == "No command set")
    }
}
