//
//  KeychainStore.swift
//  Relay
//
//  Slice 1 — the only home for secrets (SPEC §5). Bot token and pairing secret live
//  here, never in UserDefaults, plists, or logs.
//

import Foundation
import Security

/// Errors surfaced by `KeychainStore`. Carries only the OSStatus — never the value
/// being stored — so a thrown/logged error can't leak a secret (SPEC §5).
nonisolated enum KeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
}

/// A thin wrapper over the Security framework for string secrets, scoped to an
/// injectable `service` (`kSecAttrService`).
///
/// The injectable service name is the test seam (PLAN Slice 1): tests pass a unique
/// throwaway service so they exercise the real Keychain code path without ever
/// touching the app's real service. Generic-password class; one account per `key`.
///
/// `nonisolated` + `Sendable` so the networking/session actors can reach it without
/// `@MainActor` hops; the Security framework calls are themselves thread-safe.
nonisolated struct KeychainStore: Sendable {
    let service: String

    init(service: String) {
        self.service = service
    }

    /// Store (or overwrite) the secret string for `key`.
    func set(_ value: String, for key: String) throws {
        let data = Data(value.utf8)

        // Try to update an existing item first; if absent, add it.
        let updateStatus = SecItemUpdate(
            baseQuery(for: key) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = baseQuery(for: key)
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        default:
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    /// The secret string for `key`, or `nil` if nothing is stored. A missing key is
    /// not an error.
    func string(for key: String) throws -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(decoding: data, as: UTF8.self)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Delete the secret for `key`. Deleting a missing key is a no-op, not an error.
    func remove(_ key: String) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}
