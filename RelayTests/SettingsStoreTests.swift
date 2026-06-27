//
//  SettingsStoreTests.swift
//  RelayTests
//
//  Slice 7 — settings persistence (PLAN Slice 7, SPEC §5). The split is the point:
//  non-secret config round-trips through UserDefaults, but the bot token and pairing
//  secret go to the Keychain only and must never appear in the defaults plist.
//
//  Uses a unique throwaway UserDefaults suite + Keychain service per test (the Slice-1
//  test seam), so it exercises the real code paths without touching the app's real store.
//

import Testing
import Foundation
@testable import Relay

@Suite(.serialized)
@MainActor
struct SettingsStoreTests {

    /// A fresh isolated store; the returned cleanup removes both backing stores.
    private func makeStore() -> (store: SettingsStore, defaults: UserDefaults, suite: String, service: String) {
        let suite = "RelayTests.settings.\(UUID().uuidString)"
        let service = "RelayTests.settings.kc.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (SettingsStore(defaults: defaults, keychain: KeychainStore(service: service)), defaults, suite, service)
    }

    private func cleanup(suite: String, service: String) {
        UserDefaults().removePersistentDomain(forName: suite)
        let kc = KeychainStore(service: service)
        try? kc.remove("token")
        try? kc.remove("pairingSecret")
    }

    @Test func saveThenLoadRoundTripsEveryField() throws {
        let (store, _, suite, service) = makeStore()
        defer { cleanup(suite: suite, service: service) }

        let config = BotConfig(
            token: "BOT:TOKEN-123", allowedIDs: [111, 222], pairingSecret: "PAIR-SECRET-456",
            targetCommand: "claude --dangerously", idleTimeout: 600, policyPreset: .standard
        )
        try store.save(config)
        // Equatable covers the secrets too — confirming they were restored from Keychain.
        #expect(store.load() == config)
    }

    @Test func secretsAreNeverWrittenToUserDefaults() throws {
        let (store, defaults, suite, service) = makeStore()
        defer { cleanup(suite: suite, service: service) }

        let config = BotConfig(
            token: "SECRET-TOKEN-XYZ", allowedIDs: [1], pairingSecret: "SECRET-PAIR-XYZ",
            targetCommand: "claude", idleTimeout: 300, policyPreset: .strict
        )
        try store.save(config)

        // Nothing the defaults persisted may contain either secret string.
        let dump = "\(defaults.dictionaryRepresentation())"
        #expect(!dump.contains("SECRET-TOKEN-XYZ"))
        #expect(!dump.contains("SECRET-PAIR-XYZ"))
    }

    @Test func loadWithNothingStoredYieldsEmptySecretsAndDefaultsNoCrash() {
        let (store, _, suite, service) = makeStore()
        defer { cleanup(suite: suite, service: service) }

        let loaded = store.load()
        #expect(loaded.token == "")
        #expect(loaded.pairingSecret == "")
        #expect(loaded == BotConfig.default)   // non-secret fields fall back to the default
    }
}
