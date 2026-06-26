//
//  RelayApp.swift
//  Relay
//
//  Created by tommy yohanes on 26/06/26.
//

import SwiftUI

@main
struct RelayApp: App {
    /// Drives the menu-bar glyph. Slice 0 ships the resting state; later slices
    /// flip it as polling/unlock/error events arrive.
    @State private var status: AppStatus = .stopped

    var body: some Scene {
        MenuBarExtra("Relay", systemImage: status.systemImageName) {
            RelayMenu(status: status)
        }
        .menuBarExtraStyle(.menu)
    }
}
