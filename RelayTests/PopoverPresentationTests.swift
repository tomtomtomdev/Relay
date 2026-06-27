//
//  PopoverPresentationTests.swift
//  RelayTests
//
//  Slice 12 — the testable presentation core for the status-bar popover (frame 2). The
//  SwiftUI body stays thin; the decidable part is `RecentCommands.derive`, which turns the
//  live output tail into a bounded "Recent" list (status icon + mono command + time) for the
//  popover. Pure (Foundation-only) — no SwiftUI, no I/O — mirroring `SessionPresentation`.
//
//  The status rows reuse `SessionStatus.derive` (already pinned by `SessionPresentationTests`),
//  so this file only covers the new `RecentCommands` derivation.
//

import Testing
import Foundation
@testable import Relay

struct PopoverPresentationTests {

    // MARK: - Command extraction

    @Test func derivesAShellCommandStrippingThePrompt() {
        let recents = RecentCommands.derive(from: ["$ npm test"])
        #expect(recents.count == 1)
        #expect(recents[0].command == "npm test")
    }

    @Test func ignoresNonCommandLinesAndTheBarePrompt() {
        let recents = RecentCommands.derive(from: [
            "Compiling module Relay…",     // ordinary output
            "$",                           // the bare prompt caret — no command
            "\"run the test suite\"",      // a quoted request is the message, not a command
        ])
        #expect(recents.isEmpty)
    }

    // MARK: - Outcome (derived from the lines that follow the command)

    @Test func outcomeIsOkWhenFollowedByAPass() {
        let recents = RecentCommands.derive(from: ["$ npm test", " PASS  src/auth.test.ts"])
        #expect(recents[0].outcome == .ok)
    }

    @Test func outcomeIsWarnWhenFollowedByAFailure() {
        let recents = RecentCommands.derive(from: ["$ deploy staging", "⚠ permission required: deploy"])
        #expect(recents[0].outcome == .warn)
    }

    @Test func warnTakesPrecedenceOverAPass() {
        let recents = RecentCommands.derive(from: [
            "$ npm test",
            " PASS  src/auth.test.ts",
            "error: something broke",
        ])
        #expect(recents[0].outcome == .warn)
    }

    @Test func outcomeIsNeutralWithNoMarkers() {
        let recents = RecentCommands.derive(from: ["$ git status", "On branch main"])
        #expect(recents[0].outcome == .neutral)
    }

    @Test func outcomeScansOnlyUntilTheNextCommand() {
        // The PASS belongs to `npm test`, not to the earlier `git status`.
        let recents = RecentCommands.derive(from: [
            "$ git status",
            "On branch main",
            "$ npm test",
            " PASS  src/auth.test.ts",
        ])
        #expect(recents.map(\.command) == ["npm test", "git status"])   // newest-first
        #expect(recents[0].outcome == .ok)        // npm test
        #expect(recents[1].outcome == .neutral)   // git status
    }

    // MARK: - Timestamps (honest: parsed only when one is actually present)

    @Test func parsesALeadingTimestampWhenPresent() {
        let recents = RecentCommands.derive(from: ["14:32  Telegram ▸ Dewa", "$ npm test"])
        #expect(recents[0].time == "14:32")
    }

    @Test func timeIsNilWhenNoTimestampPrecedesTheCommand() {
        // Real PTY output carries no timestamp lines — we don't fabricate one.
        #expect(RecentCommands.derive(from: ["$ npm test"])[0].time == nil)
    }

    // MARK: - Ordering & bounding

    @Test func mostRecentFirstAndBounded() {
        let recents = RecentCommands.derive(from: ["$ one", "$ two", "$ three", "$ four"], limit: 2)
        #expect(recents.map(\.command) == ["four", "three"])
    }

    @Test func emptyTailYieldsNoRecents() {
        #expect(RecentCommands.derive(from: []).isEmpty)
    }

    // MARK: - Outcome → palette token

    @Test func eachOutcomeMapsToItsPaletteToken() {
        #expect(RecentCommand.Outcome.ok.token == .success)
        #expect(RecentCommand.Outcome.warn.token == .accent)
        #expect(RecentCommand.Outcome.neutral.token == .textTertiary)
    }

    // MARK: - The canonical design feed (frame 1's live session → frame 2's Recent)

    @Test func derivesRecentsFromTheDesignFeed() {
        let feed = [
            "14:32  Telegram ▸ Dewa",
            "\"run the test suite\"",
            "$ npm test",
            " PASS  src/auth.test.ts",
            " PASS  src/api.test.ts",
            " Tests: 24 passed, 24 total",
            "↳ replied to Telegram ✓",
            "14:35  Telegram ▸ Dewa",
            "\"deploy api to staging\"",
            "$ deploy api to staging",
            "⚠ permission required: deploy",
        ]
        let recents = RecentCommands.derive(from: feed)
        #expect(recents.map(\.command) == ["deploy api to staging", "npm test"])
        #expect(recents[0].outcome == .warn); #expect(recents[0].time == "14:35")
        #expect(recents[1].outcome == .ok);   #expect(recents[1].time == "14:32")
    }
}
