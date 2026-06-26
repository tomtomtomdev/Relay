//
//  AuthorizerTests.swift
//  RelayTests
//
//  Slice 3 — the heaviest tests in the repo: the three-gate security spine (SPEC §3).
//  The Authorizer is pure, so every case is a plain value-in/value-out assertion with
//  an injected clock — no actors, no I/O, no waiting.
//

import Testing
import Foundation
@testable import Relay

struct AuthorizerTests {

    // Obviously-fake secret (guardrail: dummy + assert it never echoes).
    private let secret = "DUMMY-PAIRING-SECRET-2718"
    private let operatorID: Int64 = 111
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let auth = Authorizer()

    private func config(idle: TimeInterval = 300, preset: PolicyPreset = .strict) -> BotConfig {
        BotConfig(
            token: "DUMMY:TOKEN",
            allowedIDs: [operatorID],
            pairingSecret: secret,
            targetCommand: "claude",
            idleTimeout: idle,
            policyPreset: preset
        )
    }

    private func update(_ text: String, fromID: Int64 = 111, chatID: Int64 = 111) -> Update {
        Update(
            updateID: 1,
            message: TelegramMessage(
                messageID: 1,
                from: TelegramUser(id: fromID, isBot: false, firstName: "Op"),
                chat: TelegramChat(id: chatID, type: "private"),
                date: 1_700_000_000,
                text: text
            )
        )
    }

    private func unlocked(until: Date, pending: String? = nil) -> SessionState {
        SessionState(lock: .unlocked(until: until), pendingConfirm: pending, droppedCount: 0)
    }

    private func authorize(_ u: Update, _ s: SessionState, idle: TimeInterval = 300,
                           preset: PolicyPreset = .strict, now: Date? = nil) -> AuthorizerOutcome {
        auth.authorize(u, state: s, config: config(idle: idle, preset: preset),
                       policy: .preset(preset), now: now ?? t0)
    }

    // MARK: Gate 1 — identity

    @Test func unauthorizedSenderIsDroppedSilently() {
        let out = authorize(update("/unlock \(secret)", fromID: 999), .initial)
        #expect(out.decision == .drop)
        #expect(out.state.droppedCount == 1)
        #expect(out.state.lock == .locked)   // a stranger can't unlock
    }

    @Test func unauthorizedChatIsDropped() {
        let out = authorize(update("ls", chatID: 999), .initial)
        #expect(out.decision == .drop)
        #expect(out.state.droppedCount == 1)
    }

    @Test func updateWithoutMessageIsDropped() {
        let out = authorize(Update(updateID: 1, message: nil), .initial)
        #expect(out.decision == .drop)
        #expect(out.state.droppedCount == 1)
    }

    @Test func authorizedMessageDoesNotBumpDropCounter() {
        let out = authorize(update("ls"), .initial)   // authorized but locked
        #expect(out.decision == .reply(Authorizer.lockedReply))
        #expect(out.state.droppedCount == 0)
    }

    // MARK: Gate 2 — session

    @Test func initialStateIsLocked() {
        #expect(SessionState.initial.lock == .locked)
        #expect(SessionState.initial.pendingConfirm == nil)
        #expect(SessionState.initial.droppedCount == 0)
    }

    @Test func lockedSessionRefusesInputWithFixedReply() {
        let out = authorize(update("ls -la"), .initial)
        #expect(out.decision == .reply(Authorizer.lockedReply))
        #expect(out.state.lock == .locked)   // no execution while locked
    }

    @Test func correctSecretUnlocksWithIdleDeadline() {
        let out = authorize(update("/unlock \(secret)"), .initial, idle: 300)
        #expect(out.decision == .reply(Authorizer.unlockOK))
        #expect(out.state.lock == .unlocked(until: t0.addingTimeInterval(300)))
    }

    @Test func wrongSecretFailsWithFixedReplyAndStaysLocked() {
        let a = authorize(update("/unlock totally-wrong"), .initial)
        let b = authorize(update("/unlock \(secret)X"), .initial)   // near-miss
        #expect(a.decision == .reply(Authorizer.unlockFailed))
        #expect(b.decision == .reply(Authorizer.unlockFailed))
        #expect(a.decision == b.decision)    // no oracle: identical reply for any miss
        #expect(a.state.lock == .locked)
        #expect(b.state.lock == .locked)
    }

    @Test func emptyConfiguredSecretNeverUnlocks() {
        var cfg = config()
        cfg.pairingSecret = ""
        let out = auth.authorize(update("/unlock"), state: .initial, config: cfg,
                                 policy: .strict, now: t0)
        #expect(out.decision == .reply(Authorizer.unlockFailed))
        #expect(out.state.lock == .locked)
    }

    @Test func lockCommandRelocksAndClearsPending() {
        let state = unlocked(until: t0.addingTimeInterval(300), pending: "sudo reboot")
        let out = authorize(update("/lock"), state)
        #expect(out.decision == .reply(Authorizer.lockedNow))
        #expect(out.state.lock == .locked)
        #expect(out.state.pendingConfirm == nil)
    }

    @Test func idleRelockBoundary() {
        let until = t0.addingTimeInterval(300)
        // Just before the deadline → still unlocked, clean input forwards.
        let before = authorize(update("ls"), unlocked(until: until),
                               now: until.addingTimeInterval(-1))
        #expect(before.decision == .forward("ls"))
        // Exactly at the deadline → relocked; input refused, nothing forwarded.
        let at = authorize(update("ls"), unlocked(until: until), now: until)
        #expect(at.decision == .reply(Authorizer.lockedReply))
        #expect(at.state.lock == .locked)
    }

    @Test func activityRefreshesIdleDeadline() {
        let until = t0.addingTimeInterval(300)
        let now = t0.addingTimeInterval(100)   // active before expiry
        let out = authorize(update("ls"), unlocked(until: until), idle: 300, now: now)
        #expect(out.decision == .forward("ls"))
        #expect(out.state.lock == .unlocked(until: now.addingTimeInterval(300)))
    }

    // MARK: Gate 3 — policy

    @Test func cleanInputForwardsWhenUnlocked() {
        let out = authorize(update("ls -la"), unlocked(until: t0.addingTimeInterval(300)))
        #expect(out.decision == .forward("ls -la"))
        #expect(out.state.pendingConfirm == nil)
    }

    @Test func denylistedInputIsRefusedNotForwarded() {
        let out = authorize(update("rm -rf /"), unlocked(until: t0.addingTimeInterval(300)))
        #expect(out.decision == .reply(Authorizer.deniedReply))
        #expect(out.state.pendingConfirm == nil)
    }

    @Test func flaggedInputThenConfirmForwardsHeldInput() {
        let cmd = "sudo softwareupdate -i -a"
        let step1 = authorize(update(cmd), unlocked(until: t0.addingTimeInterval(300)))
        guard case .needsConfirm = step1.decision else {
            Issue.record("expected .needsConfirm, got \(step1.decision)")
            return
        }
        #expect(step1.state.pendingConfirm == cmd)

        // A following /confirm forwards exactly the held input, then clears it.
        let step2 = authorize(update("/confirm"), step1.state)
        #expect(step2.decision == .forward(cmd))
        #expect(step2.state.pendingConfirm == nil)
    }

    @Test func confirmWithNothingPendingReplies() {
        let out = authorize(update("/confirm"), unlocked(until: t0.addingTimeInterval(300)))
        #expect(out.decision == .reply(Authorizer.nothingToConfirm))
    }

    @Test func confirmWhileLockedIsRefused() {
        let out = authorize(update("/confirm"), .initial)
        #expect(out.decision == .reply(Authorizer.lockedReply))
    }

    // MARK: Secret hygiene + constant-time compare

    @Test func secretIsNeverEchoedInAnyReply() {
        for text in ["/unlock \(secret)", "/unlock \(secret)X", "/unlock nope"] {
            let out = authorize(update(text), .initial)
            switch out.decision {
            case .reply(let r), .needsConfirm(let r), .forward(let r):
                #expect(!r.contains(secret))
            case .drop:
                break
            }
        }
    }

    @Test func constantTimeEqualsMatchesOnlyExact() {
        #expect(Authorizer.constantTimeEquals("abc", "abc"))
        #expect(Authorizer.constantTimeEquals("", ""))
        #expect(!Authorizer.constantTimeEquals("abc", "abcd"))   // longer
        #expect(!Authorizer.constantTimeEquals("abcd", "abc"))   // shorter
        #expect(!Authorizer.constantTimeEquals("abc", "abd"))    // same length, differs
        #expect(!Authorizer.constantTimeEquals("abc", ""))       // empty vs non-empty
    }
}
