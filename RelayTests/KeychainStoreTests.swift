//
//  KeychainStoreTests.swift
//  RelayTests
//
//  Slice 1 — Keychain read/write/delete with an injectable service name so tests
//  hit a throwaway test keychain service, never the app's real one (PLAN Slice 1).
//

import Testing
import Foundation
@testable import Relay

struct KeychainStoreTests {

    // A unique service per test so cases never collide with each other, with leftover
    // items from a prior run, or with the app's real service.
    private func freshStore() -> KeychainStore {
        KeychainStore(service: "com.relay.tests.\(UUID().uuidString)")
    }

    @Test func writeThenReadRoundTrips() throws {
        let store = freshStore()
        let key = "token"
        defer { try? store.remove(key) }

        try store.set("hunter2", for: key)
        #expect(try store.string(for: key) == "hunter2")
    }

    @Test func missingKeyReturnsNilNotCrash() throws {
        let store = freshStore()
        #expect(try store.string(for: "never-written") == nil)
    }

    @Test func overwriteUpdatesValue() throws {
        let store = freshStore()
        let key = "secret"
        defer { try? store.remove(key) }

        try store.set("first", for: key)
        try store.set("second", for: key)
        #expect(try store.string(for: key) == "second")
    }

    @Test func removeDeletesValue() throws {
        let store = freshStore()
        let key = "ephemeral"

        try store.set("value", for: key)
        try store.remove(key)
        #expect(try store.string(for: key) == nil)
    }

    @Test func removingMissingKeyIsANoOp() throws {
        let store = freshStore()
        // Deleting a key that was never written is a no-op, not an error.
        try store.remove("not-there")
    }
}
