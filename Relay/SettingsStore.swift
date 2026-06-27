//
//  SettingsStore.swift
//  Relay
//
//  Slice 7 — where the operator's settings live (PLAN Slice 7, SPEC §5). The split is
//  enforced here: non-secret `BotConfig` fields persist as JSON in UserDefaults, while
//  the bot token and pairing secret go to the Keychain only. Because `BotConfig`'s
//  `Codable` surface already excludes the secrets (Slice 1), encoding for UserDefaults
//  *cannot* spill them to the plist — this store just supplies them from the Keychain on
//  load and routes them back to the Keychain on save.
//
//  Both backing stores are injectable (the Slice-1 test seam) so tests use a throwaway
//  defaults suite + Keychain service and never touch the app's real store.
//

import Foundation

/// `@MainActor` (the project default) rather than `Sendable`: it wraps `UserDefaults`
/// (not `Sendable` in Swift 6), and settings I/O is small and UI-adjacent, so keeping it
/// on the main actor alongside `AppModel` is the simplest correct choice.
struct SettingsStore {
    private let defaults: UserDefaults
    private let keychain: KeychainStore

    private enum Keys {
        static let config = "relay.config"        // non-secret BotConfig JSON
        static let token = "token"                // Keychain account
        static let pairingSecret = "pairingSecret" // Keychain account
    }

    init(defaults: UserDefaults, keychain: KeychainStore) {
        self.defaults = defaults
        self.keychain = keychain
    }

    /// Load the stored config: non-secret fields from UserDefaults (falling back to
    /// `BotConfig.default`), secrets merged in from the Keychain (empty if absent).
    func load() -> BotConfig {
        var config = BotConfig.default
        if let data = defaults.data(forKey: Keys.config),
           let decoded = try? JSONDecoder().decode(BotConfig.self, from: data) {
            config = decoded
        }
        config.token = secret(Keys.token)
        config.pairingSecret = secret(Keys.pairingSecret)
        return config
    }

    /// Persist `config`: non-secret fields to UserDefaults, secrets to the Keychain only.
    func save(_ config: BotConfig) throws {
        // Secrets are absent from `BotConfig.CodingKeys`, so this JSON can't carry them.
        let data = try JSONEncoder().encode(config)
        defaults.set(data, forKey: Keys.config)

        try keychain.set(config.token, for: Keys.token)
        try keychain.set(config.pairingSecret, for: Keys.pairingSecret)
    }

    private func secret(_ key: String) -> String {
        ((try? keychain.string(for: key)) ?? nil) ?? ""
    }
}

extension SettingsStore {
    /// The app's real store: standard defaults + the Keychain service that holds Relay's
    /// secrets. Tests never use this — they inject throwaway stores.
    static let standard = SettingsStore(
        defaults: .standard,
        keychain: KeychainStore(service: "co.tuntun.relay.secrets")
    )
}
