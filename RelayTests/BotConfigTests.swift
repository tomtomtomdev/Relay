//
//  BotConfigTests.swift
//  RelayTests
//
//  Slice 1 — the persisted bot configuration model (PLAN Slice 1, SPEC §5).
//

import Testing
import Foundation
@testable import Relay

struct BotConfigTests {

    // Obviously-fake secrets. Per the guardrail: a test that touches a secret uses a
    // dummy and asserts it is *not* echoed anywhere.
    private let dummyToken = "DUMMY-BOT-TOKEN-0000000000:AAAA"
    private let dummySecret = "DUMMY-PAIRING-SECRET-9999"

    private func makeConfig() -> BotConfig {
        BotConfig(
            token: dummyToken,
            allowedIDs: [111, 222],
            pairingSecret: dummySecret,
            targetCommand: "claude",
            idleTimeout: 300,
            policyPreset: .strict
        )
    }

    @Test func codableRoundTripPreservesNonSecretFields() throws {
        let original = makeConfig()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BotConfig.self, from: data)

        #expect(decoded.allowedIDs == original.allowedIDs)
        #expect(decoded.targetCommand == original.targetCommand)
        #expect(decoded.idleTimeout == original.idleTimeout)
        #expect(decoded.policyPreset == original.policyPreset)
    }

    @Test func secretsAreNeverSerialized() throws {
        // Encoding must never put a secret on disk in plaintext (SPEC §5). Secrets
        // live in the Keychain; the Codable surface deliberately omits them.
        let data = try JSONEncoder().encode(makeConfig())
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains(dummyToken))
        #expect(!json.contains(dummySecret))

        // Decoding a persisted config yields empty secrets — they are reloaded from
        // the Keychain at runtime, never carried through serialization.
        let decoded = try JSONDecoder().decode(BotConfig.self, from: data)
        #expect(decoded.token.isEmpty)
        #expect(decoded.pairingSecret.isEmpty)
    }

    @Test func descriptionRedactsSecrets() {
        let config = makeConfig()
        let renderings = [
            String(describing: config),
            String(reflecting: config),
            config.description,
            config.debugDescription,
        ]
        for rendered in renderings {
            #expect(!rendered.contains(dummyToken))
            #expect(!rendered.contains(dummySecret))
        }
    }
}
