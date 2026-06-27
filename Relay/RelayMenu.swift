//
//  RelayMenu.swift
//  Relay
//
//  Slice 7 — the menu-bar dropdown: status readout, Start/Stop, Lock/Unlock, a test
//  message, the live output tail, and Settings/Quit. Thin by design — every action just
//  calls an `AppModel` method; all the logic lives in the (unit-tested) view-model.
//

import SwiftUI

struct RelayMenu: View {
    var model: AppModel

    var body: some View {
        Text("Relay — \(model.status.label)")
        Divider()

        if model.status == .stopped {
            Button("Start") { Task { await model.start() } }
                .disabled(!model.canStart)
        } else {
            Button("Stop") { Task { await model.stop() } }
        }

        if model.isUnlocked {
            Button("Lock") { Task { await model.lock() } }
        } else {
            Button("Unlock") { Task { await model.unlock() } }
                .disabled(model.status == .stopped)
        }

        Button("Send Test Message") { Task { await model.sendTestMessage() } }

        Divider()
        Button(model.isArchiving ? "Building & Archiving…" : "Build & Archive…") {
            Task { await model.buildAndArchive() }
        }
        .disabled(model.isArchiving)
        if let artifact = model.lastArtifactURL {
            Text("📦 \(artifact.lastPathComponent)")
        }

        Button(model.isPublishing ? "Building & Publishing…" : "Build & Publish…") {
            Task { await model.buildAndPublish() }
        }
        .disabled(model.isPublishing)
        if let install = model.lastInstallURL {
            Text("🔗 \(install.absoluteString)")
            Button("Copy Install Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(install.absoluteString, forType: .string)
            }
            Button("Send Install Link to Chat") { Task { await model.sendInstallLink() } }
        }

        if let error = model.lastError {
            Divider()
            Text("⚠️ \(error)")
        }

        if !model.tail.lines.isEmpty {
            Divider()
            ForEach(Array(model.tail.lines.suffix(5).enumerated()), id: \.offset) { _, line in
                Text(Self.menuLine(line))
            }
        }

        Divider()
        SettingsLink { Text("Settings…") }
        Button("Quit Relay") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// Collapse a (possibly multi-line) output chunk to a single short menu label.
    private static func menuLine(_ raw: String) -> String {
        let collapsed = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.count > 60 ? String(collapsed.prefix(60)) + "…" : collapsed
    }
}
