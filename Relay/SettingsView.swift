//
//  SettingsView.swift
//  Relay
//
//  Slice 7 — the Settings window (⌘,), the only place secrets are entered. A thin Form
//  bound to `AppModel.settings`; Save routes the token + pairing secret to the Keychain
//  and the rest to UserDefaults (see `SettingsStore`). Validation guidance is inline.
//

import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Telegram") {
                TextField("Bot token", text: $model.settings.token)
                SecureField("Pairing secret", text: $model.settings.pairingSecret)
                TextField("Allowed chat IDs", text: allowedIDsText)
                    .help("Comma-separated Telegram chat IDs allowed through the identity gate.")
            }

            Section("Session") {
                TextField("Target command", text: $model.settings.targetCommand)
                TextField("Idle timeout (seconds)", value: $model.settings.idleTimeout, format: .number)
                Picker("Policy", selection: $model.settings.policyPreset) {
                    ForEach(PolicyPreset.allCases, id: \.self) { preset in
                        Text(preset.rawValue.capitalized).tag(preset)
                    }
                }
            }

            Section {
                ForEach(model.settings.validationIssues(), id: \.self) { issue in
                    Label(issue.message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                Button("Save") { model.saveSettings() }
                    .keyboardShortcut("s")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }

    /// Bridges the stored `[Int64]` allow-list to the comma-separated text field.
    private var allowedIDsText: Binding<String> {
        Binding(
            get: { AllowedIDs.format(model.settings.allowedIDs) },
            set: { model.settings.allowedIDs = AllowedIDs.parse($0) }
        )
    }
}
