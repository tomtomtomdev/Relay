//
//  BridgeTests.swift
//  RelayTests
//
//  Slice 6 — wire-through (integration). The security spine goes LIVE here: a real
//  composition of TelegramClient → Authorizer → SessionManager (a real local PTY) →
//  OutputPipeline → TelegramClient, with Telegram stubbed offline (RoutingTelegramStub).
//
//  Two end-to-end paths from the acceptance criteria (PLAN Slice 6, SPEC §7):
//    · authorized: /unlock then a command round-trips PTY output back to the chat;
//    · hostile: an un-allow-listed chat is inert (no reply, nothing reaches the PTY).
//  Plus the partial-UTF-8-across-chunks decoder the wire-through needs, and that fixed
//  control replies go out MarkdownV2-escaped (not as a <pre> block).
//
//  Serialized: RoutingTelegramStub holds process-static queue/capture state.
//

import Testing
import Foundation
@testable import Relay

@Suite(.serialized)
struct BridgeTests {

    // Obviously-fake secret (guardrail: dummy + assert it never echoes).
    private let secret = "DUMMY-PAIRING-SECRET-31415"
    private let operatorID: Int64 = 4242

    private func config() -> BotConfig {
        BotConfig(
            token: "DUMMY:TOKEN",
            allowedIDs: [operatorID],
            pairingSecret: secret,
            targetCommand: "/bin/cat",
            idleTimeout: 300,
            policyPreset: .strict
        )
    }

    /// A `TelegramClient` whose injected session is served entirely by the routing stub.
    private func telegramClient() -> TelegramClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [RoutingTelegramStub.self]
        return TelegramClient(token: "DUMMY:TOKEN", session: URLSession(configuration: cfg))
    }

    /// A bridge wired to a real `/bin/cat` PTY — forwarded input echoes straight back out.
    private func bridge() -> Bridge {
        Bridge(
            config: config(),
            policy: .strict,
            telegram: telegramClient(),
            session: SessionManager(command: ["/bin/cat"])
        )
    }

    private func update(_ text: String, id: Int64, fromID: Int64, chatID: Int64) -> Update {
        Update(
            updateID: id,
            message: TelegramMessage(
                messageID: id,
                from: TelegramUser(id: fromID, isBot: false, firstName: "Op"),
                chat: TelegramChat(id: chatID, type: "private"),
                date: 0,
                text: text
            )
        )
    }

    /// Poll `predicate` until it's true or `timeout` elapses; returns whether it became
    /// true. Keeps timing-sensitive integration tests from hanging the suite.
    private func waitUntil(
        timeout: Duration = .seconds(10),
        _ predicate: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                while !(await predicate()) {
                    if Task.isCancelled { return false }
                    try? await Task.sleep(for: .milliseconds(20))
                }
                return true
            }
            group.addTask { try? await Task.sleep(for: timeout); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    // MARK: - Authorized end-to-end

    @Test func unlockThenCommandRoundTripsThroughPTY() async throws {
        RoutingTelegramStub.reset()
        let marker = "ROUNDTRIP-9281"
        RoutingTelegramStub.enqueue([
            update("/unlock \(secret)", id: 1, fromID: operatorID, chatID: operatorID),
            update(marker, id: 2, fromID: operatorID, chatID: operatorID),
        ])

        let bridge = bridge()
        try await bridge.start()

        let appeared = await waitUntil {
            RoutingTelegramStub.sentMessages().contains { $0.text.contains(marker) }
        }
        #expect(appeared)

        let sent = RoutingTelegramStub.sentMessages()
        let echoed = try #require(sent.first { $0.text.contains(marker) })
        // PTY output came back wrapped as a MarkdownV2 <pre> block…
        #expect(echoed.text.contains("```"))
        // …routed to the operator's chat.
        #expect(echoed.chatID == operatorID)
        // The pairing secret is never echoed anywhere in the conversation.
        #expect(!sent.contains { $0.text.contains(secret) })

        await bridge.stop()
    }

    // MARK: - Hostile chat is inert

    @Test func unauthorizedChatIsInertEndToEnd() async throws {
        RoutingTelegramStub.reset()
        RoutingTelegramStub.enqueue([
            update("rm -rf /", id: 1, fromID: 999, chatID: 999),   // not allow-listed
        ])

        let bridge = bridge()
        try await bridge.start()

        // Wait until the hostile update has been processed (drop counted), then assert
        // total silence: no reply (no oracle) — and nothing forwarded to the PTY.
        let dropped = await waitUntil(timeout: .seconds(5)) { await bridge.droppedCount >= 1 }
        #expect(dropped)
        #expect(RoutingTelegramStub.sentMessages().isEmpty)

        await bridge.stop()
    }

    // MARK: - Locked control reply is escaped, not a <pre> block

    @Test func authorizedButLockedCommandGetsFixedEscapedReply() async throws {
        RoutingTelegramStub.reset()
        RoutingTelegramStub.enqueue([
            update("ls -la", id: 1, fromID: operatorID, chatID: operatorID),   // authorized, locked
        ])

        let bridge = bridge()
        try await bridge.start()

        let replied = await waitUntil(timeout: .seconds(5)) {
            !RoutingTelegramStub.sentMessages().isEmpty
        }
        #expect(replied)
        // The single fixed locked reply, MarkdownV2-escaped (control replies are escaped
        // text, not <pre> blocks like PTY output).
        #expect(RoutingTelegramStub.sentMessages().first?.text == MarkdownV2.escape(Authorizer.lockedReply))

        await bridge.stop()
    }

    // MARK: - Partial UTF-8 across read chunks

    @Test func multibyteSplitAcrossTwoChunksDecodes() {
        var decoder = UTF8StreamDecoder()
        let bytes = Array("世".utf8)               // a 3-byte sequence
        let first = decoder.decode(Data(bytes[0..<2]))   // first 2 bytes — incomplete
        #expect(first == "")                              // held back, no replacement char
        let second = decoder.decode(Data(bytes[2...]))    // final byte completes it
        #expect(second == "世")
    }

    @Test func byteAtATimeStreamReassemblesExactly() {
        var decoder = UTF8StreamDecoder()
        let source = "héllo→世界 🚀 done"
        var out = ""
        for byte in Array(source.utf8) {
            out += decoder.decode(Data([byte]))
        }
        out += decoder.flush()
        #expect(out == source)
    }
}
