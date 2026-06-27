//
//  StatusPopover.swift
//  Relay
//
//  Slice 12 — the status-bar popover (design frame 2), the always-resident control surface
//  shown when the menu-bar icon is clicked. A thin SwiftUI body over the Slice-10 components
//  and the pure cores (`SessionStatus.derive`, `RecentCommands.derive`): a header with the
//  master bot-listener toggle, three status rows, a bounded "Recent" list, an actions strip,
//  and a footer (Open Relay / Pause / Quit). Both appearances follow `@Environment`.
//
//  This replaces the plain `.menu`-style `RelayMenu` (used via `.menuBarExtraStyle(.window)`),
//  and preserves every prior action: Start/Stop, Lock/Unlock, Send Test Message,
//  Build & Archive, Build & Publish, Copy / Send install link, Open Relay, Settings, Quit.
//

import SwiftUI

struct StatusPopover: View {
    var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openWindow) private var openWindow

    private static let width: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            hairline
            statusRows
            hairline
            recent
            hairline
            actions
            hairline
            footer
        }
        .frame(width: Self.width)
        .background(Color(.windowBackground, scheme))
    }

    private var hairline: some View {
        Rectangle().fill(Color(.border, scheme)).frame(height: 1)
    }

    // MARK: Header (app mark + listening state + master toggle)

    private var header: some View {
        HStack(spacing: 10) {
            RelayAppMark(size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("Relay")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color(.textPrimary, scheme))
                Text(model.isRunning ? "Listening for commands" : "Paused")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(model.isRunning ? .success : .textTertiary, scheme))
            }
            Spacer(minLength: 8)
            Toggle("", isOn: listeningBinding)
                .labelsHidden()
                .toggleStyle(RelayToggleStyle(width: 38, height: 23))
                .disabled(!model.isRunning && !model.canStart)
        }
        .padding(16)
    }

    private var listeningBinding: Binding<Bool> {
        Binding(
            get: { model.isRunning },
            set: { wantsOn in Task { wantsOn ? await model.start() : await model.stop() } }
        )
    }

    // MARK: Status rows (reuse SessionStatus.derive)

    private var statusRows: some View {
        VStack(spacing: 10) {
            ForEach(cards) { card in
                HStack(spacing: 8) {
                    Text(card.label)
                        .font(.system(size: 13))
                        .foregroundStyle(Color(.textSecondary, scheme))
                    Spacer(minLength: 8)
                    StatusDot(card.dot)
                    Text(card.value)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color(.textPrimary, scheme))
                    Text(card.detail)
                        .font(RelayFont.monoSmall)
                        .foregroundStyle(Color(.textTertiary, scheme))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var cards: [StatusCardModel] {
        SessionStatus.derive(
            isRunning: model.isRunning,
            isUnlocked: model.isUnlocked,
            hasError: model.lastError != nil,
            settings: model.settings
        )
    }

    // MARK: Recent

    private var recent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RECENT")
                .font(RelayFont.label)
                .tracking(0.04 * 11)
                .foregroundStyle(Color(.textTertiary, scheme))

            let recents = RecentCommands.derive(from: model.tail.lines)
            if recents.isEmpty {
                Text("No recent commands")
                    .font(RelayFont.monoSmall)
                    .foregroundStyle(Color(.textTertiary, scheme))
            } else {
                ForEach(Array(recents.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 8) {
                        Image(systemName: item.outcome.symbol)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color(item.outcome.token, scheme))
                            .frame(width: 12)
                        Text(item.command)
                            .font(RelayFont.monoSmall)
                            .foregroundStyle(Color(.textSecondary, scheme))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 8)
                        if let time = item.time {
                            Text(time)
                                .font(RelayFont.monoSmall)
                                .foregroundStyle(Color(.textTertiary, scheme))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Actions strip (everything not in the design's header/footer, preserved)

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if model.isUnlocked {
                    actionButton("Lock") { await model.lock() }
                } else {
                    actionButton("Unlock", disabled: !model.isRunning) { await model.unlock() }
                }
                actionButton("Send Test") { await model.sendTestMessage() }
                SettingsLink { capsuleLabel("Settings") }
                    .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                actionButton(model.isArchiving ? "Archiving…" : "Build & Archive",
                             disabled: model.isArchiving) { await model.buildAndArchive() }
                actionButton(model.isPublishing ? "Publishing…" : "Build & Publish",
                             disabled: model.isPublishing) { await model.buildAndPublish() }
            }

            if let artifact = model.lastArtifactURL {
                detailLine(systemImage: "shippingbox", text: artifact.lastPathComponent, tint: .textSecondary)
            }

            if let install = model.lastInstallURL {
                detailLine(systemImage: "link", text: install.absoluteString, tint: .telegramBlue)
                HStack(spacing: 8) {
                    actionButton("Copy Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(install.absoluteString, forType: .string)
                    }
                    actionButton("Send to Chat") { await model.sendInstallLink() }
                }
            }

            if let error = model.lastError {
                detailLine(systemImage: "exclamationmark.triangle.fill", text: error, tint: .destructive)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Footer (Open Relay / Pause / Quit)

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                NSApp.activate()   // accessory/LSUIElement apps must front themselves first
                openWindow(id: SessionWindow.sceneID)
            } label: {
                footerLabel("Open Relay", fill: .white.opacity(0.08), text: .textPrimary)
            }
            .buttonStyle(.plain)

            Button {
                Task { model.isRunning ? await model.stop() : await model.start() }
            } label: {
                footerLabel(model.isRunning ? "Pause" : "Resume",
                            fill: .white.opacity(0.04), text: .textSecondary)
            }
            .buttonStyle(.plain)
            .disabled(!model.isRunning && !model.canStart)

            Button { NSApplication.shared.terminate(nil) } label: {
                footerLabel("Quit", fill: Color(.destructive, scheme).opacity(0.10), text: .destructive)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
        }
        .padding(16)
    }

    // MARK: Small building blocks

    /// A pill-styled async action button (subtle fill, primary text).
    private func actionButton(_ title: String, disabled: Bool = false,
                              _ run: @escaping () async -> Void) -> some View {
        Button { Task { await run() } } label: { capsuleLabel(title) }
            .buttonStyle(.plain)
            .disabled(disabled)
            .opacity(disabled ? 0.5 : 1)
    }

    private func capsuleLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color(.textPrimary, scheme))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.white.opacity(0.06), in: Capsule())
    }

    private func footerLabel(_ title: String, fill: Color, text: PaletteToken) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color(text, scheme))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(fill, in: RoundedRectangle(cornerRadius: RelayRadius.control))
    }

    private func detailLine(systemImage: String, text: String, tint: PaletteToken) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 10))
                .foregroundStyle(Color(tint, scheme))
            Text(text)
                .font(RelayFont.monoSmall)
                .foregroundStyle(Color(tint, scheme))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Preview

#Preview("Popover — Dark") {
    StatusPopover(model: .previewSeeded).preferredColorScheme(.dark)
}

#Preview("Popover — Light") {
    StatusPopover(model: .previewSeeded).preferredColorScheme(.light)
}
