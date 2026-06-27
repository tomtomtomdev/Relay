//
//  AppModel.swift
//  Relay
//
//  Slice 7 — the menu-bar view-model (PLAN Slice 7, SPEC §4). It owns the editable
//  settings, the derived status glyph, and the live output tail, and it drives the
//  `Bridge` (Start/Stop/Lock/Unlock/test message). Every state change funnels through one
//  `apply(_:)` reducer so the status machine lives in a single, fully unit-tested place;
//  the SwiftUI body just reads `status`/`tail`/`settings` and calls these methods.
//
//  `@MainActor` by default (the project's main-actor isolation). The heavy dependencies
//  (Bridge → PTY + network) are created only on `start()`, so the model — and its whole
//  reducer/validation surface — constructs and tests with no live resources.
//

import Foundation
import Observation

/// Actions the view-model reduces. Bridge events map onto a subset of these.
nonisolated enum AppEvent: Sendable {
    case runningChanged(Bool)
    case unlockedChanged(Bool)
    case output(String)
    case failed(String)
    case clearError
}

@Observable
final class AppModel {

    /// Editable operator settings, bound by the settings form. Secrets are held only in
    /// memory and in the Keychain (via `SettingsStore`) — never serialized to disk here.
    var settings: BotConfig

    private(set) var isRunning = false
    private(set) var isUnlocked = false
    private(set) var tail: OutputTail
    var lastError: String?

    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private var bridge: Bridge?
    @ObservationIgnored private var eventTask: Task<Void, Never>?

    init(store: SettingsStore, tailCapacity: Int = 50) {
        self.store = store
        self.settings = store.load()
        self.tail = OutputTail(capacity: tailCapacity)
    }

    // MARK: - Derived

    /// The menu-bar glyph state. Pure function of the live flags (see `AppStatus.derive`).
    var status: AppStatus {
        .derive(isRunning: isRunning, isUnlocked: isUnlocked, hasError: lastError != nil)
    }

    /// Whether the current settings are complete enough to start.
    var canStart: Bool { settings.isStartable }

    // MARK: - Reducer (the testable core)

    func apply(_ event: AppEvent) {
        switch event {
        case .runningChanged(let running):
            isRunning = running
            if !running { isUnlocked = false }   // a stopped bridge is always relocked
        case .unlockedChanged(let unlocked):
            isUnlocked = unlocked
        case .output(let text):
            tail.append(text)
        case .failed(let message):
            lastError = message
        case .clearError:
            lastError = nil
        }
    }

    // MARK: - Settings

    func saveSettings() {
        do { try store.save(settings) }
        catch { apply(.failed("Couldn't save settings.")) }
    }

    // MARK: - Lifecycle

    func start() async {
        guard !isRunning else { return }
        guard canStart else {
            apply(.failed("Settings are incomplete — open Settings to finish."))
            return
        }
        apply(.clearError)

        // "zsh -l first, then the configured command" (Slice 4 bootstrap pattern).
        let target = settings.targetCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let bridge = Bridge(
            config: settings,
            policy: .preset(settings.policyPreset),
            telegram: TelegramClient(token: settings.token, session: Self.makeURLSession()),
            session: SessionManager(command: ["/bin/zsh", "-l"], bootstrap: target.isEmpty ? nil : target)
        )
        do {
            try await bridge.start()
            self.bridge = bridge
            apply(.runningChanged(true))
            consumeEvents(from: bridge)
        } catch {
            apply(.failed("Couldn't start the session."))   // never includes token/secret
        }
    }

    func stop() async {
        eventTask?.cancel()
        eventTask = nil
        if let bridge { await bridge.stop() }
        bridge = nil
        apply(.runningChanged(false))
    }

    func lock() async {
        await bridge?.lock()
        apply(.unlockedChanged(false))
    }

    func unlock() async {
        await bridge?.unlock()
        apply(.unlockedChanged(true))
    }

    func sendTestMessage() async {
        let text = "✅ Relay test message"
        if let bridge {
            await bridge.sendTestMessage(text)
            return
        }
        // Not running: send a one-off if the essentials are configured.
        guard !settings.token.isEmpty, let chatID = settings.allowedIDs.first else {
            apply(.failed("Add a token and an allowed ID first."))
            return
        }
        let client = TelegramClient(token: settings.token, session: Self.makeURLSession())
        try? await client.sendMessage(chatID: chatID, text: MarkdownV2.escape(text))
    }

    // MARK: - Internals

    private func consumeEvents(from bridge: Bridge) {
        let events = bridge.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { break }
                switch event {
                case .unlockedChanged(let unlocked): self.apply(.unlockedChanged(unlocked))
                case .output(let text): self.apply(.output(text))
                }
            }
        }
    }

    private static func makeURLSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60   // comfortably longer than the 30s long poll
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }
}
