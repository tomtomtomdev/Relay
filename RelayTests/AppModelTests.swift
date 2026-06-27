//
//  AppModelTests.swift
//  RelayTests
//
//  Slice 7 — the menu-bar view-model (PLAN Slice 7). All state changes funnel through
//  one `apply(_:)` reducer, so the status transitions and load/validation glue are
//  testable without ever constructing a live Bridge (no PTY, no network). The SwiftUI
//  body just reads `status` / `tail` / `settings` and calls these methods.
//

import Testing
import Foundation
@testable import Relay

@MainActor
struct AppModelTests {

    /// A model backed by isolated throwaway stores. `start()` is never called, so no
    /// Bridge / PTY / network is created.
    private func makeModel() -> AppModel {
        let suite = "RelayTests.appmodel.\(UUID().uuidString)"
        let service = "RelayTests.appmodel.kc.\(UUID().uuidString)"
        let store = SettingsStore(defaults: UserDefaults(suiteName: suite)!,
                                  keychain: KeychainStore(service: service))
        return AppModel(store: store)
    }

    @Test func freshModelIsStopped() {
        #expect(makeModel().status == .stopped)
    }

    @Test func loadsPersistedSettingsOnInit() throws {
        let suite = "RelayTests.appmodel.\(UUID().uuidString)"
        let service = "RelayTests.appmodel.kc.\(UUID().uuidString)"
        let store = SettingsStore(defaults: UserDefaults(suiteName: suite)!,
                                  keychain: KeychainStore(service: service))
        defer {
            UserDefaults().removePersistentDomain(forName: suite)
            try? KeychainStore(service: service).remove("token")
            try? KeychainStore(service: service).remove("pairingSecret")
        }
        var config = BotConfig.default
        config.targetCommand = "claude-custom"
        config.allowedIDs = [7, 8]
        try store.save(config)

        let model = AppModel(store: store)
        #expect(model.settings.targetCommand == "claude-custom")
        #expect(model.settings.allowedIDs == [7, 8])
    }

    @Test func canStartMirrorsConfigValidation() {
        let model = makeModel()
        model.settings = BotConfig.default            // empty token/secret/allowlist
        #expect(model.canStart == false)
        model.settings = BotConfig(
            token: "T", allowedIDs: [1], pairingSecret: "S",
            targetCommand: "c", idleTimeout: 300, policyPreset: .strict
        )
        #expect(model.canStart == true)
    }

    @Test func reducerDrivesTheStatusGlyphThroughItsStates() {
        let model = makeModel()
        model.apply(.runningChanged(true))
        #expect(model.status == .polling)
        model.apply(.unlockedChanged(true))
        #expect(model.status == .unlocked)
        model.apply(.unlockedChanged(false))
        #expect(model.status == .polling)
        model.apply(.runningChanged(false))
        #expect(model.status == .stopped)
    }

    @Test func stoppingForcesRelock() {
        let model = makeModel()
        model.apply(.runningChanged(true))
        model.apply(.unlockedChanged(true))
        model.apply(.runningChanged(false))
        #expect(model.isUnlocked == false)
        #expect(model.status == .stopped)
    }

    @Test func failureSetsErrorStatusAndMessage() {
        let model = makeModel()
        model.apply(.runningChanged(true))
        model.apply(.failed("Couldn't start the session."))
        #expect(model.status == .error)
        #expect(model.lastError == "Couldn't start the session.")
    }

    @Test func clearErrorReturnsToDerivedStatus() {
        let model = makeModel()
        model.apply(.runningChanged(true))
        model.apply(.failed("boom"))
        model.apply(.clearError)
        #expect(model.lastError == nil)
        #expect(model.status == .polling)
    }

    @Test func outputEventsAppendToTheLiveTail() {
        let model = makeModel()
        model.apply(.output("line-1"))
        model.apply(.output("line-2"))
        #expect(model.tail.lines == ["line-1", "line-2"])
    }
}
