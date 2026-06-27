//
//  RelayApp.swift
//  Relay
//
//  Created by tommy yohanes on 26/06/26.
//

import SwiftUI

@main
struct RelayApp: App {
    /// The single view-model: owns settings, the derived status glyph, the live tail,
    /// and the Bridge lifecycle (Slice 7). Secrets load from the Keychain at launch.
    @State private var model = AppModel(store: .standard)

    var body: some Scene {
        MenuBarExtra("Relay", systemImage: model.status.systemImageName) {
            RelayMenu(model: model)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(model: model)
        }
    }
}
