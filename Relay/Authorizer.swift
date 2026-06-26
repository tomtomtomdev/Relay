//
//  Authorizer.swift
//  Relay
//
//  Slice 3 — the security spine (SPEC §3). A *pure* state machine: given an incoming
//  `Update`, the current `SessionState`, the operator's `BotConfig`, a `Policy`, and a
//  clock (`now`), it returns the next `SessionState` and a `Decision`. No I/O, no
//  Keychain, no network — every gate is deterministic and exhaustively unit-tested.
//
//  A bot token piping text into a shell is RCE-as-a-service if unguarded. A message
//  must clear all three gates to reach the PTY:
//    1. Identity — `from.id` and `chat.id` must both be allow-listed, else silent drop
//       (counted, never replied to — no oracle that confirms the bot is live).
//    2. Session — execution only while unlocked. `/unlock <secret>` (constant-time
//       compare), `/lock`, idle timeout, and relaunch (initial state) relock. A wrong
//       secret yields one fixed reply that reveals nothing about closeness.
//    3. Policy — even unlocked, input is screened: catastrophic shapes refused,
//       flagged shapes held for `/confirm`.
//

import Foundation

/// What the bridge should do with one incoming message. Carries only plain text;
/// MarkdownV2 escaping is the sender's job (`TelegramClient`). Mirrors SPEC §4.
nonisolated enum Decision: Equatable, Sendable {
    /// Hostile/unknown chat — do nothing, send nothing (no oracle).
    case drop
    /// Send this fixed text back to the chat (locked notice, unlock result, refusal…).
    case reply(String)
    /// Authorized, screened input to write to the PTY.
    case forward(String)
    /// Input is flagged; reply this prompt and hold the input until `/confirm`.
    case needsConfirm(String)
}

/// The evolving state of the single operator session. `relock` on relaunch is simply
/// starting from `.initial` (locked). Pure value type — the Authorizer returns the
/// next state rather than mutating anything in place.
nonisolated struct SessionState: Equatable, Sendable {
    nonisolated enum Lock: Equatable, Sendable {
        case locked
        /// Unlocked until this idle deadline; any activity pushes it forward.
        case unlocked(until: Date)
    }

    var lock: Lock
    /// A flagged command awaiting a `/confirm`, if any.
    var pendingConfirm: String?
    /// Count of identity-gate drops (metric only; never surfaced to the chat).
    var droppedCount: Int

    /// Locked, nothing pending — the state on launch and after relock.
    static let initial = SessionState(lock: .locked, pendingConfirm: nil, droppedCount: 0)
}

/// The result of one authorization: the `Decision` to act on plus the `SessionState`
/// the caller should carry forward.
nonisolated struct AuthorizerOutcome: Equatable, Sendable {
    let decision: Decision
    let state: SessionState
}

/// Pure authorization logic. Holds no state of its own.
nonisolated struct Authorizer: Sendable {

    // Fixed operator-facing strings. None reveal a secret or whether one was "close".
    static let lockedReply = "🔒 Session is locked. Send /unlock <secret> to begin."
    static let unlockOK = "🔓 Session unlocked."
    static let unlockFailed = "🔒 Unlock failed."
    static let lockedNow = "🔒 Session locked."
    static let deniedReply = "⛔️ Refused: blocked by policy."
    static let nothingToConfirm = "Nothing to confirm."

    static func confirmPrompt(for input: String) -> String {
        "⚠️ Flagged by policy. Reply /confirm to run it, or send anything else to cancel:\n\(input)"
    }

    /// Authorize one update. See the three gates documented at the top of the file.
    func authorize(
        _ update: Update,
        state: SessionState,
        config: BotConfig,
        policy: Policy,
        now: Date
    ) -> AuthorizerOutcome {
        // ── Gate 1: identity ──────────────────────────────────────────────────────
        // Both the sender and the chat must be allow-listed. Anything else is dropped
        // silently and counted — never replied to, so strangers get no oracle.
        guard let message = update.message,
              let fromID = message.from?.id,
              config.allowedIDs.contains(fromID),
              config.allowedIDs.contains(message.chat.id)
        else {
            var dropped = state
            dropped.droppedCount += 1
            return AuthorizerOutcome(decision: .drop, state: dropped)
        }

        var next = state
        let command = Self.parse(message.text ?? "")

        // Apply idle relock before judging the session: an expired deadline is locked.
        var isUnlocked = false
        if case .unlocked(let until) = next.lock {
            if now >= until {
                next.lock = .locked
                next.pendingConfirm = nil
            } else {
                isUnlocked = true
            }
        }

        // ── Gate 2: session ───────────────────────────────────────────────────────
        switch command {
        case .unlock(let secret):
            // A non-empty configured secret, matched in constant time, unlocks. The
            // attempted secret is never echoed; any miss yields one fixed reply.
            if !config.pairingSecret.isEmpty,
               Self.constantTimeEquals(secret, config.pairingSecret) {
                next.lock = .unlocked(until: now.addingTimeInterval(config.idleTimeout))
                next.pendingConfirm = nil
                return AuthorizerOutcome(decision: .reply(Self.unlockOK), state: next)
            }
            return AuthorizerOutcome(decision: .reply(Self.unlockFailed), state: next)

        case .lock:
            next.lock = .locked
            next.pendingConfirm = nil
            return AuthorizerOutcome(decision: .reply(Self.lockedNow), state: next)

        case .confirm, .input:
            guard isUnlocked else {
                return AuthorizerOutcome(decision: .reply(Self.lockedReply), state: next)
            }
        }

        // Past gate 2 → unlocked, command is `.confirm` or `.input`. Activity here
        // pushes the idle deadline forward.
        next.lock = .unlocked(until: now.addingTimeInterval(config.idleTimeout))

        // ── Gate 3: policy ────────────────────────────────────────────────────────
        switch command {
        case .confirm:
            if let pending = next.pendingConfirm {
                next.pendingConfirm = nil
                return AuthorizerOutcome(decision: .forward(pending), state: next)
            }
            return AuthorizerOutcome(decision: .reply(Self.nothingToConfirm), state: next)

        case .input(let body):
            switch policy.screen(body) {
            case .denied:
                next.pendingConfirm = nil
                return AuthorizerOutcome(decision: .reply(Self.deniedReply), state: next)
            case .flagged:
                next.pendingConfirm = body
                return AuthorizerOutcome(decision: .needsConfirm(Self.confirmPrompt(for: body)), state: next)
            case .clean:
                next.pendingConfirm = nil
                return AuthorizerOutcome(decision: .forward(body), state: next)
            }

        case .unlock, .lock:
            // Unreachable: handled in gate 2 above.
            return AuthorizerOutcome(decision: .drop, state: next)
        }
    }

    /// Constant-time comparison so a wrong `/unlock` reveals nothing about how much of
    /// the secret matched (SPEC §3 gate 2). Compares every byte regardless of mismatch.
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        var diff: UInt8 = a.count == b.count ? 0 : 1
        let n = Swift.max(a.count, b.count)
        var i = 0
        while i < n {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            diff |= (x ^ y)
            i += 1
        }
        return diff == 0
    }

    // MARK: - Command parsing

    /// The four message shapes the session machine cares about. Everything that isn't
    /// a recognized slash command is opaque `.input` to be screened by the policy.
    private enum Command {
        case unlock(secret: String)
        case lock
        case confirm
        case input(String)
    }

    /// Parse a message into a `Command`. Recognizes `/unlock <secret>`, `/lock`, and
    /// `/confirm` (tolerating a Telegram `@botname` suffix); the secret is the
    /// untouched remainder so it's never split or normalized.
    private static func parse(_ raw: String) -> Command {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return .input(trimmed) }

        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        var head = String(parts[0])
        if let at = head.firstIndex(of: "@") { head = String(head[..<at]) }
        let args = parts.count > 1
            ? String(parts[1]).trimmingCharacters(in: .whitespaces)
            : ""

        switch head {
        case "/unlock":  return .unlock(secret: args)
        case "/lock":    return .lock
        case "/confirm": return .confirm
        default:         return .input(trimmed)
        }
    }
}
