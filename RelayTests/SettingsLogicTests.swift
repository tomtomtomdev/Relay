//
//  SettingsLogicTests.swift
//  RelayTests
//
//  Slice 7 — the pure view-model logic behind the menu-bar UI (PLAN Slice 7): the status
//  glyph's state machine, settings validation, allowed-IDs parsing, and the live-tail
//  ring buffer. All value-in/value-out, so the SwiftUI body can stay thin and untested.
//

import Testing
import Foundation
@testable import Relay

struct AppStatusDeriveTests {

    @Test func notRunningIsStoppedRegardlessOfUnlock() {
        #expect(AppStatus.derive(isRunning: false, isUnlocked: false, hasError: false) == .stopped)
        #expect(AppStatus.derive(isRunning: false, isUnlocked: true, hasError: false) == .stopped)
    }

    @Test func runningAndLockedIsPolling() {
        #expect(AppStatus.derive(isRunning: true, isUnlocked: false, hasError: false) == .polling)
    }

    @Test func runningAndUnlockedIsUnlocked() {
        #expect(AppStatus.derive(isRunning: true, isUnlocked: true, hasError: false) == .unlocked)
    }

    @Test func errorDominatesEveryOtherState() {
        #expect(AppStatus.derive(isRunning: true, isUnlocked: true, hasError: true) == .error)
        #expect(AppStatus.derive(isRunning: false, isUnlocked: false, hasError: true) == .error)
    }
}

struct ConfigValidationTests {

    private func valid() -> BotConfig {
        BotConfig(
            token: "BOT:TOKEN", allowedIDs: [111], pairingSecret: "PAIR",
            targetCommand: "claude", idleTimeout: 300, policyPreset: .strict
        )
    }

    @Test func fullyPopulatedConfigHasNoIssuesAndIsStartable() {
        #expect(valid().validationIssues().isEmpty)
        #expect(valid().isStartable)
    }

    @Test func missingTokenIsFlagged() {
        var c = valid(); c.token = ""
        #expect(c.validationIssues().contains(.missingToken))
        #expect(!c.isStartable)
    }

    @Test func whitespaceOnlyTokenCountsAsMissing() {
        var c = valid(); c.token = "   \n"
        #expect(c.validationIssues().contains(.missingToken))
    }

    @Test func emptyAllowlistIsFlagged() {
        var c = valid(); c.allowedIDs = []
        #expect(c.validationIssues().contains(.noAllowedIDs))
    }

    @Test func missingPairingSecretIsFlagged() {
        var c = valid(); c.pairingSecret = ""
        #expect(c.validationIssues().contains(.missingPairingSecret))
    }

    @Test func missingTargetCommandIsFlagged() {
        var c = valid(); c.targetCommand = "  "
        #expect(c.validationIssues().contains(.missingTargetCommand))
    }

    @Test func nonPositiveIdleTimeoutIsFlagged() {
        var c = valid(); c.idleTimeout = 0
        #expect(c.validationIssues().contains(.nonPositiveIdleTimeout))
    }

    @Test func everyIssueHasANonEmptyMessage() {
        let all: [ConfigIssue] = [
            .missingToken, .noAllowedIDs, .missingPairingSecret,
            .missingTargetCommand, .nonPositiveIdleTimeout,
        ]
        for issue in all { #expect(!issue.message.isEmpty) }
    }
}

struct AllowedIDsTests {

    @Test func parsesCommaSeparatedIDs() {
        #expect(AllowedIDs.parse("111, 222,333") == [111, 222, 333])
    }

    @Test func ignoresBlanksAndNonNumericTokens() {
        #expect(AllowedIDs.parse("111, , abc, 222") == [111, 222])
    }

    @Test func whitespaceOnlyParsesToEmpty() {
        #expect(AllowedIDs.parse("   ") == [])
    }

    @Test func formatJoinsWithCommaSpace() {
        #expect(AllowedIDs.format([111, 222]) == "111, 222")
    }

    @Test func parseFormatRoundTrips() {
        #expect(AllowedIDs.parse(AllowedIDs.format([1, 2, 3])) == [1, 2, 3])
    }
}

struct OutputTailTests {

    @Test func appendsInArrivalOrder() {
        var tail = OutputTail(capacity: 5)
        tail.append("a"); tail.append("b")
        #expect(tail.lines == ["a", "b"])
    }

    @Test func capsAtCapacityKeepingMostRecent() {
        var tail = OutputTail(capacity: 2)
        for line in ["a", "b", "c", "d"] { tail.append(line) }
        #expect(tail.lines == ["c", "d"])
    }

    @Test func capacityClampsToAtLeastOne() {
        var tail = OutputTail(capacity: 0)
        tail.append("a"); tail.append("b")
        #expect(tail.lines == ["b"])
    }
}
