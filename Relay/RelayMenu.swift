//
//  RelayMenu.swift
//  Relay
//
//  Created by tommy yohanes on 26/06/26.
//

import SwiftUI

/// Contents of the menu-bar dropdown. Slice 0 is intentionally minimal: a status
/// readout and a Quit item. Settings / live tail land in Slice 7.
struct RelayMenu: View {
    let status: AppStatus

    var body: some View {
        Text("Relay — \(status.label)")
        Divider()
        Button("Quit Relay") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
