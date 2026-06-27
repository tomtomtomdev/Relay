//
//  ArchiveWindow.swift
//  Relay
//
//  Slice 14 — the Archive & Distribute window (design frame 5, the final UI-series slice).
//  A thin SwiftUI body over the Slice-10 components and the Slice-14 pure core
//  (`ArchiveJobViewState.derive`): an app-mark header, the four-stage step list with status
//  circles, the install-link field + Copy / Send-to-Chat, a stateful primary button, and a
//  bounded error line. All decisions live in the tested core; this file is layout only. Both
//  appearances follow `@Environment(\.colorScheme)`.
//
//  The distribution target is **Hangar** (not the design's Google Drive). Publishing is a
//  dev/CI action (SPEC §6): on a tester build with no publisher configured, the primary button
//  runs and the core surfaces "Publishing isn't configured on this build." via the error line —
//  no secret is ever shown.
//

import SwiftUI

// MARK: - Window

struct ArchiveWindow: View {
    /// Scene identifier shared by the `Window` scene and the `openWindow` call.
    static let sceneID = "archive"

    var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    /// The whole window is a thin function of this coarse, tested view state.
    private var state: ArchiveJobViewState {
        ArchiveJobViewState.derive(
            isArchiving: model.isArchiving,
            isPublishing: model.isPublishing,
            lastArtifactURL: model.lastArtifactURL,
            lastInstallURL: model.lastInstallURL,
            lastError: model.lastError
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            appHeader
            steps
            linkField
            if let error = state.errorMessage { errorLine(error) }
            Spacer(minLength: 0)
            buttons
        }
        .padding(24)
        .frame(width: 460, height: 430)
        .background(Color(.windowBackground, scheme))
    }

    // MARK: App header (mark + name/version + artifact subtitle)

    private var appHeader: some View {
        HStack(spacing: 13) {
            RelayAppMark(size: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(versionText)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color(.textPrimary, scheme))
                Text(subtitleText)
                    .font(RelayFont.monoSmall)
                    .foregroundStyle(Color(.textSecondary, scheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 22)
    }

    private var versionText: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return v.map { "Relay.app · v\($0)" } ?? "Relay.app"
    }

    /// The produced artifact's filename once known, else the platform/signing line. Never a
    /// fabricated size — we only show what we can honestly source.
    private var subtitleText: String {
        if let artifact = model.lastArtifactURL { return artifact.lastPathComponent }
        return "macOS · Developer ID · Hangar"
    }

    // MARK: Steps (Build → Archive → Upload → Share link)

    private var steps: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(state.steps) { step in
                HStack(spacing: 13) {
                    StepCircle(status: step.status)
                    Text(step.title)
                        .font(.system(size: 13.5, weight: step.status == .active ? .semibold : .regular))
                        .foregroundStyle(Color(step.status == .pending ? .textTertiary : .textPrimary, scheme))
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 9)
                .opacity(step.status == .pending ? 0.55 : 1)
            }
        }
        .padding(.bottom, 18)
    }

    // MARK: Install-link field + Copy / Send-to-Chat

    private var linkField: some View {
        HStack(spacing: 10) {
            Image(systemName: "link")
                .font(.system(size: 13))
                .foregroundStyle(Color(state.shareURL == nil ? .textTertiary : .telegramBlue, scheme))
            Text(state.shareURL?.absoluteString ?? "Install link — pending")
                .font(RelayFont.mono)
                .foregroundStyle(Color(state.shareURL == nil ? .textTertiary : .textSecondary, scheme))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if let url = state.shareURL {
                pill("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
                pill("Send to Chat") { Task { await model.sendInstallLink() } }
            } else {
                pill("Copy", disabled: true) {}
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(Color(.field, scheme), in: RoundedRectangle(cornerRadius: RelayRadius.field))
        .overlay(
            RoundedRectangle(cornerRadius: RelayRadius.field)
                .strokeBorder(Color(.border, scheme), lineWidth: 1)
        )
    }

    private func errorLine(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
            Text(text)
                .font(RelayFont.monoSmall)
                .lineLimit(2)
        }
        .foregroundStyle(Color(.destructive, scheme))
        .padding(.top, 12)
    }

    // MARK: Primary + secondary buttons

    private var buttons: some View {
        HStack(spacing: 9) {
            Button(action: runPrimary) {
                Text(state.primaryTitle)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(primaryForeground)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(primaryFill, in: RoundedRectangle(cornerRadius: RelayRadius.control))
            }
            .buttonStyle(.plain)
            .disabled(state.primaryAction == .busy)

            Button { dismiss() } label: {
                Text("Done")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Color(.textSecondary, scheme))
                    .padding(.vertical, 10)
                    .padding(.horizontal, 18)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: RelayRadius.control))
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 18)
    }

    private func runPrimary() {
        switch state.primaryAction {
        case .archiveAndUpload: Task { await model.buildAndPublish() }
        case .openInstallLink:  if let url = state.shareURL { openURL(url) }
        case .busy:             break
        }
    }

    private var primaryFill: Color {
        state.primaryAction == .busy ? Color(.accent, scheme).opacity(0.45) : Color(.accent, scheme)
    }

    private var primaryForeground: Color {
        // The amber button uses a dark, high-contrast label (design: #5a3a1c on #F0883E).
        Color(RGBA(hex: "#3A2410")!)
    }

    // MARK: Small building blocks

    private func pill(_ title: String, disabled: Bool = false, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(.textPrimary, scheme))
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(.white.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }
}

// MARK: - Step status circle

/// The 22px status circle for a pipeline step (design frame 5): a filled green ✓ when done,
/// an amber ring with a centred dot while active, a hollow gray ring when pending.
private struct StepCircle: View {
    @Environment(\.colorScheme) private var scheme
    let status: ArchiveJobViewState.Step.Status

    var body: some View {
        ZStack {
            switch status {
            case .done:
                Circle().fill(Color(.success, scheme))
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(RGBA(hex: "#0A2A12")!))
            case .active:
                Circle().strokeBorder(Color(.accent, scheme), lineWidth: 2)
                Circle().fill(Color(.accent, scheme)).frame(width: 8, height: 8)
            case .pending:
                Circle().strokeBorder(Color(.textTertiary, scheme).opacity(0.6), lineWidth: 2)
            }
        }
        .frame(width: 22, height: 22)
    }
}

// MARK: - Previews

#Preview("Archive — Idle (Dark)") {
    ArchiveWindow(model: .previewSeeded).preferredColorScheme(.dark)
}

#Preview("Archive — Published (Light)") {
    let model = AppModel.previewSeeded
    model.apply(.publishFinished(URL(string: "https://hangar.example.com/i/relay-1.4.0")!))
    return ArchiveWindow(model: model).preferredColorScheme(.light)
}
