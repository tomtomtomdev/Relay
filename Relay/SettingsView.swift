//
//  SettingsView.swift
//  Relay
//
//  Slice 13 — the redesigned, tabbed Settings window (design frames 3 & 4, adapted to
//  Hangar). A thin SwiftUI body over the Slice-10 design tokens and the Slice-13 pure core
//  (`TokenMask`, `AllowedIDChips`, `PolicyPreset` display, `SettingsTab`):
//
//   • A styled toolbar tab row (Telegram / Claude / Distribution / General).
//   • Telegram: masked bot token + Reveal, the allowed-ID chip field, the pairing secret.
//   • Claude: the target command + a segmented permission mode over the *real* `PolicyPreset`.
//   • Distribution: a Hangar dev/CI callout + the last install URL (Copy / Send to Chat).
//   • General: the idle timeout, plus the shared validation summary + Save.
//
//  Secrets stay in the Keychain (via `SettingsStore`); the only place the token is shown in
//  the clear is the live, in-memory Reveal state — never logged, never written to UserDefaults
//  (`BotConfig`'s Codable surface excludes secrets by construction since Slice 1).
//

import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var scheme

    @State private var tab: SettingsTab = .telegram
    @State private var revealToken = false
    @State private var pendingID = ""

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            hairline
            ScrollView {
                tabContent
                    .padding(.horizontal, 26)
                    .padding(.vertical, 22)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            hairline
            footer
        }
        .frame(width: 540, height: 460)
        .background(Color(.windowBackground, scheme))
    }

    private var hairline: some View {
        Rectangle().fill(Color(.border, scheme)).frame(height: 1)
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases) { item in
                let active = tab == item
                Button { tab = item } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.icon).font(.system(size: 12, weight: .medium))
                        Text(item.title).font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Color(active ? .accent : .textSecondary, scheme))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: RelayRadius.field)
                            .fill(active ? Color(.accent, scheme).opacity(0.16) : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .background(Color(.titlebar, scheme))
    }

    // MARK: - Tab content

    @ViewBuilder private var tabContent: some View {
        switch tab {
        case .telegram:     telegramTab
        case .claude:       claudeTab
        case .distribution: distributionTab
        case .general:      generalTab
        }
    }

    // MARK: Telegram tab

    private var telegramTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            section("Bot Connection") {
                formRow("Bot token") { tokenField }
                formRow("Allowed chat IDs", alignment: .top) { chipField }
                formRow("Pairing secret") {
                    field { SecureField("Secret for /unlock", text: $model.settings.pairingSecret) }
                }
            }
        }
    }

    private var tokenField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Group {
                    switch TokenMask.fieldState(token: model.settings.token, revealed: revealToken) {
                    case .editable:
                        if revealToken {
                            TextField("Paste bot token", text: $model.settings.token)
                                .textFieldStyle(.plain)
                        } else {
                            SecureField("Paste bot token", text: $model.settings.token)
                                .textFieldStyle(.plain)
                        }
                    case .masked(let masked):
                        Text(masked)
                            .foregroundStyle(Color(.textSecondary, scheme))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .font(RelayFont.mono)

                Button(revealToken ? "Hide" : "Reveal") { revealToken.toggle() }
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(.accent, scheme))
            }
            .fieldBox(scheme)

            helper("Stored only in the macOS Keychain — never written to disk in the clear.")
        }
    }

    private var chipField: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 8) {
                if !model.settings.allowedIDs.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(model.settings.allowedIDs, id: \.self) { id in
                            chip(id)
                        }
                    }
                }
                TextField("add id…", text: $pendingID)
                    .textFieldStyle(.plain)
                    .font(RelayFont.mono)
                    .onSubmit(addPendingID)
            }
            .fieldBox(scheme)

            helper("Only messages from these chats are forwarded to the terminal.")
        }
    }

    private func chip(_ id: Int64) -> some View {
        HStack(spacing: 5) {
            Text(String(id))
                .font(RelayFont.monoSmall)
                .foregroundStyle(Color(.telegramBlue, scheme))
            Button {
                model.settings.allowedIDs = AllowedIDChips.remove(id, from: model.settings.allowedIDs)
            } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(.telegramBlue, scheme).opacity(0.8))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(.telegramBlue, scheme).opacity(0.15), in: RoundedRectangle(cornerRadius: RelayRadius.chip))
        .overlay(
            RoundedRectangle(cornerRadius: RelayRadius.chip)
                .strokeBorder(Color(.telegramBlue, scheme).opacity(0.5), lineWidth: 1)
        )
    }

    private func addPendingID() {
        model.settings.allowedIDs = AllowedIDChips.add(pendingID, to: model.settings.allowedIDs)
        pendingID = ""
    }

    // MARK: Claude tab

    private var claudeTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            section("Claude Code Session") {
                formRow("Target command") {
                    field { TextField("claude", text: $model.settings.targetCommand) }
                }
                formRow("Permission mode", alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        permissionSegments
                        helper(model.settings.policyPreset.summary)
                    }
                }
            }

            calloutBox(
                icon: "info.circle.fill",
                title: "Telegram approval modes are planned",
                body: "The design's Ask / Auto-accept / Plan-only modes need an Authorizer change and are on the backlog. Relay currently screens commands with the two presets above.",
                tint: .textSecondary
            )
        }
    }

    private var permissionSegments: some View {
        HStack(spacing: 4) {
            ForEach(PolicyPreset.allCases, id: \.self) { preset in
                let active = model.settings.policyPreset == preset
                Button { model.settings.policyPreset = preset } label: {
                    Text(preset.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(active ? .accent : .textSecondary, scheme))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: RelayRadius.field)
                                .fill(active ? Color(.accent, scheme).opacity(0.16) : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color(.field, scheme), in: RoundedRectangle(cornerRadius: RelayRadius.control))
        .overlay(
            RoundedRectangle(cornerRadius: RelayRadius.control)
                .strokeBorder(Color(.border, scheme), lineWidth: 1)
        )
    }

    // MARK: Distribution tab (Hangar — no Google Drive fields)

    private var distributionTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            calloutBox(
                icon: "exclamationmark.triangle.fill",
                title: "Publishing is a dev/CI action",
                body: "The publisher token lives in the macOS Keychain and is never shipped in the tester binary. Build & Publish runs from a dev or CI build only.",
                tint: .accent
            )

            section("Latest Release") {
                if let install = model.lastInstallURL {
                    formRow("Install link") {
                        field {
                            Text(install.absoluteString)
                                .font(RelayFont.mono)
                                .foregroundStyle(Color(.telegramBlue, scheme))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    HStack(spacing: 8) {
                        Spacer(minLength: RelayMetric.labelColumn + RelayMetric.formRowGap)
                        pillButton("Copy Link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(install.absoluteString, forType: .string)
                        }
                        pillButton("Send to Chat") { Task { await model.sendInstallLink() } }
                    }
                } else {
                    Text("No release published yet.")
                        .font(RelayFont.body)
                        .foregroundStyle(Color(.textTertiary, scheme))
                }
            }
        }
    }

    // MARK: General tab

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            section("Session") {
                formRow("Idle timeout") {
                    HStack(spacing: 8) {
                        TextField("300", value: $model.settings.idleTimeout, format: .number)
                            .textFieldStyle(.plain)
                            .font(RelayFont.mono)
                            .frame(width: 70)
                            .fieldBox(scheme)
                        Text("seconds before auto-relock")
                            .font(RelayFont.body)
                            .foregroundStyle(Color(.textTertiary, scheme))
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    // MARK: - Footer (shared validation + Save)

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            if let issue = model.settings.validationIssues().first {
                Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(.accent, scheme))
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Label("Ready to start", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(.success, scheme))
            }
            Spacer(minLength: 8)
            Button("Save") { model.saveSettings() }
                .keyboardShortcut("s")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(Color(.titlebar, scheme))
    }

    // MARK: - Reusable building blocks

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title.uppercased())
                .font(RelayFont.label)
                .tracking(0.04 * 11)
                .foregroundStyle(Color(.textTertiary, scheme))
            content()
        }
    }

    private func formRow<Content: View>(
        _ label: String, alignment: VerticalAlignment = .firstTextBaseline,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: alignment, spacing: RelayMetric.formRowGap) {
            Text(label)
                .font(RelayFont.body)
                .foregroundStyle(Color(.textSecondary, scheme))
                .frame(width: RelayMetric.labelColumn, alignment: .trailing)
            content()
        }
    }

    /// A bordered field shell that fills its `content` (a `TextField`/`SecureField`/`Text`).
    private func field<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .font(RelayFont.mono)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fieldBox(scheme)
    }

    private func helper(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Color(.textTertiary, scheme))
    }

    private func calloutBox(icon: String, title: String, body: String, tint: PaletteToken) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(Color(tint, scheme))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(.textPrimary, scheme))
                Text(body)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(.textSecondary, scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color(tint, scheme).opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color(tint, scheme).opacity(0.4), lineWidth: 1)
        )
    }

    private func pillButton(_ title: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(.textPrimary, scheme))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.white.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Field shell modifier

private struct FieldBox: ViewModifier {
    let scheme: ColorScheme
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(.field, scheme), in: RoundedRectangle(cornerRadius: RelayRadius.field))
            .overlay(
                RoundedRectangle(cornerRadius: RelayRadius.field)
                    .strokeBorder(Color(.border, scheme), lineWidth: 1)
            )
    }
}

private extension View {
    func fieldBox(_ scheme: ColorScheme) -> some View { modifier(FieldBox(scheme: scheme)) }
}

// MARK: - Flow layout (wrapping chips)

/// A minimal wrapping layout for the allowed-ID chips: lays subviews left-to-right, wrapping
/// to a new line when the next subview would overflow the proposed width.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(maxWidth, widest), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Previews

#Preview("Settings — Dark") {
    SettingsView(model: .previewSeeded).preferredColorScheme(.dark)
}

#Preview("Settings — Light") {
    SettingsView(model: .previewSeeded).preferredColorScheme(.light)
}
