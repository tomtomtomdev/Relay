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
            StatusPopover(model: model)
        }
        .menuBarExtraStyle(.window)   // Slice 12: the styled popover (design frame 2)

        // The main window (Slice 11, design frame 1). Suppressed at launch so the app stays
        // menu-bar resident; opened on demand via the menu's "Open Relay".
        Window("Relay — Session", id: SessionWindow.sceneID) {
            SessionWindow(model: model)
        }
        .defaultSize(width: 720, height: 560)
        .defaultLaunchBehavior(.suppressed)

        // The Archive & Distribute window (Slice 14, design frame 5). Opened on demand from
        // the popover; suppressed at launch so the app stays menu-bar resident.
        Window("Archive & Distribute", id: ArchiveWindow.sceneID) {
            ArchiveWindow(model: model)
        }
        .defaultSize(width: 460, height: 430)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView(model: model)
        }
    }
}
