//
//  SessionWindow.swift
//  Relay
//
//  Slice 11 — the main window (design frame 1, "Live Session"). A thin SwiftUI body over
//  the Slice-10 components and the Slice-11 pure core (`SessionStatus.derive`,
//  `SessionLogLine.classify`, `MaskedID`): a 204px sidebar (app mark + nav + bot-listener
//  toggle), three status cards, and a live terminal panel that renders the `AppModel` tail
//  with colour by classified line. All decisions live in the tested core; this file is
//  layout only. Both appearances follow `@Environment(\.colorScheme)`.
//

import SwiftUI

// MARK: - Window

struct SessionWindow: View {
    /// Scene identifier shared by the `Window` scene and the menu's `openWindow` call.
    static let sceneID = "session"

    var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            content
        }
        .frame(minWidth: 680, minHeight: 460)
        .background(Color(.windowBackground, scheme))
        .toolbar { ToolbarItem(placement: .automatic) { listeningStatus } }
    }

    // MARK: Title-bar trailing status ("Listening" / "Paused")

    private var listeningStatus: some View {
        HStack(spacing: 6) {
            StatusDot(model.isRunning ? .connected : .idle)
            Text(model.isRunning ? "Listening" : "Paused")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(.textSecondary, scheme))
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                RelayAppMark(size: 28)
                Text("Relay")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color(.textPrimary, scheme))
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 18)

            VStack(spacing: 2) {
                NavRow(icon: "bolt.horizontal.circle", title: "Session", isActive: true)
                NavRow(icon: "list.bullet.rectangle", title: "Activity")
                NavRow(icon: "shippingbox", title: "Archive")
                SettingsLink {
                    NavRowLabel(icon: "gearshape", title: "Settings", isActive: false)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 12)

            Rectangle()
                .fill(Color(.border, scheme))
                .frame(height: 1)
                .padding(.horizontal, 10)

            Toggle(isOn: listeningBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bot listener")
                        .font(RelayFont.body)
                        .foregroundStyle(Color(.textPrimary, scheme))
                    Text(listenerSubtext)
                        .font(RelayFont.monoSmall)
                        .foregroundStyle(Color(.textTertiary, scheme))
                }
            }
            .toggleStyle(RelayToggleStyle())
            .disabled(!model.isRunning && !model.canStart)
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
        }
        .frame(width: RelayMetric.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(.sidebar, scheme))
    }

    private var listeningBinding: Binding<Bool> {
        Binding(
            get: { model.isRunning },
            set: { wantsOn in Task { wantsOn ? await model.start() : await model.stop() } }
        )
    }

    private var listenerSubtext: String {
        model.isRunning ? "polling for updates" : "paused"
    }

    // MARK: Content (cards + live session)

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ForEach(cards) { card in
                    StatusCard(label: card.label, value: card.value, dot: card.dot, detail: card.detail)
                }
            }
            livePanel
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(.windowBackground, scheme))
    }

    private var cards: [StatusCardModel] {
        SessionStatus.derive(
            isRunning: model.isRunning,
            isUnlocked: model.isUnlocked,
            hasError: model.lastError != nil,
            settings: model.settings
        )
    }

    private var livePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Live Session")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(.textPrimary, scheme))
                Spacer()
                Text("tty · session")
                    .font(RelayFont.monoSmall)
                    .foregroundStyle(Color(.textTertiary, scheme))
            }
            terminal
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var terminal: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(model.tail.lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .terminalText()
                        .foregroundStyle(Color(SessionLogLine.classify(line).token, scheme))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                HStack(spacing: 4) {
                    Text("$")
                        .terminalText()
                        .foregroundStyle(Color(.textSecondary, scheme))
                    BlinkingCaret()
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.terminalBackground, scheme))
        .clipShape(RoundedRectangle(cornerRadius: RelayRadius.card))
        .overlay(
            RoundedRectangle(cornerRadius: RelayRadius.card)
                .strokeBorder(Color(.border, scheme), lineWidth: 1)
        )
    }
}

// MARK: - Sidebar nav

/// One sidebar navigation row. The active row carries the design's amber-tinted background.
private struct NavRow: View {
    let icon: String
    let title: String
    var isActive: Bool = false

    var body: some View {
        NavRowLabel(icon: icon, title: title, isActive: isActive)
    }
}

private struct NavRowLabel: View {
    @Environment(\.colorScheme) private var scheme
    let icon: String
    let title: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 16)
            Text(title)
                .font(RelayFont.body)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color(isActive ? .accent : .textSecondary, scheme))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: RelayRadius.field)
                .fill(isActive ? Color(.accent, scheme).opacity(0.16) : .clear)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - App mark

/// The Relay app mark: a steel squircle with an amber broadcast glyph (design "Assets").
struct RelayAppMark: View {
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color(RGBA(hex: "#46474B")!), Color(RGBA(hex: "#1B1B1D")!)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            )
            .overlay(
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(Color(RGBA(hex: "#F0883E")!))
            )
    }
}

// MARK: - Blinking caret

/// The terminal's blinking prompt caret (design: ~1s blink, 8×15px amber).
private struct BlinkingCaret: View {
    @Environment(\.colorScheme) private var scheme
    @State private var visible = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color(.accent, scheme))
            .frame(width: 8, height: 15)
            .opacity(visible ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                    visible = false
                }
            }
    }
}

// MARK: - Preview

#Preview("Session — Dark") {
    SessionWindow(model: .previewSeeded).frame(width: 720, height: 560).preferredColorScheme(.dark)
}

#Preview("Session — Light") {
    SessionWindow(model: .previewSeeded).frame(width: 720, height: 560).preferredColorScheme(.light)
}

extension AppModel {
    /// A running, unlocked model pre-seeded with a sample feed — for previews only.
    @MainActor static var previewSeeded: AppModel {
        let model = AppModel(store: .standard)
        model.settings = BotConfig(
            token: "123:ABC", allowedIDs: [7129904842], pairingSecret: "secret",
            targetCommand: "claude", idleTimeout: 300, policyPreset: .strict
        )
        model.apply(.runningChanged(true))
        model.apply(.unlockedChanged(true))
        for line in [
            "\"run the test suite\"",
            "$ npm test",
            " PASS  src/auth.test.ts",
            " PASS  src/api.test.ts",
            " Tests: 24 passed, 24 total",
            "↳ replied to Telegram ✓",
            "⚠ permission required: deploy",
        ] {
            model.apply(.output(line))
        }
        return model
    }
}
