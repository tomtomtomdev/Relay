//
//  ArchivePresentation.swift
//  Relay
//
//  Slice 14 — the *pure* presentation core for the Archive & Distribute window (design
//  frame 5, the final UI-series slice). Following the repo pattern (`SessionStatus.derive`,
//  `RecentCommands.derive`, `SettingsPresentation`), the decidable logic lives here as
//  `nonisolated`/`Sendable` value logic — no SwiftUI, no I/O — so the window body stays thin
//  and this can be exhaustively unit-tested.
//
//  `ArchiveJobViewState.derive` maps the existing `AppModel` flags
//  (`isArchiving` / `isPublishing` / `lastArtifactURL` / `lastInstallURL` / `lastError`) onto
//  a coarse four-step list (Build → Archive → Upload → Share link) with per-step status
//  circles, a stateful primary button, and the minted install URL.
//
//  COARSE BY DESIGN (PLAN Slice 14): the backend exposes two in-flight flags and two results,
//  not per-substep progress. So a publish in flight shows Build/Archive as *done* and Upload
//  as *active* (matching the design frame) even though, under the hood, the archive sub-phase
//  runs first — we can't observe the archive→upload handoff. Fine-grained per-step % needs new
//  backend signals and is tracked as backlog; nothing here fabricates progress it can't see.
//
//  No secret is ever surfaced — only the build flags, the artifact filename (via the view),
//  and the install URL Hangar mints. The distribution stage is **Hangar**, not the design's
//  Google Drive (confirmed UI-series decision).
//

import Foundation

/// The full, coarse view state for the Archive & Distribute window — derived purely from the
/// `AppModel` build/publish flags. `Equatable` so the SwiftUI body is a thin function of it.
nonisolated struct ArchiveJobViewState: Equatable, Sendable {

    /// The four stages, in order, each with its coarse status (design frame 5).
    let steps: [Step]

    /// The primary button's title for the current phase ("Archive & Upload" / "Archiving…" /
    /// "Uploading…" / "Open Install Link").
    let primaryTitle: String

    /// What the primary button does (drives enable/disable + the action the view runs).
    let primaryAction: PrimaryAction

    /// The minted install link — present only once a publish has finalized (`.published`).
    /// Hidden while a fresh run is in flight so a stale link is never offered as current.
    let shareURL: URL?

    /// A bounded, secret-free failure message to surface, or `nil`. Passed through from
    /// `AppModel.lastError` (already generic — never tool output or a token).
    let errorMessage: String?

    // MARK: Step

    /// One row of the pipeline (a status circle + a title).
    struct Step: Equatable, Sendable, Identifiable {
        let kind: Kind
        let title: String
        let status: Status

        var id: String { kind.rawValue }   // the four kinds are unique → stable ForEach id

        /// The four stages of build → distribute (design frame 5).
        enum Kind: String, Sendable, CaseIterable {
            case build, archive, upload, share
        }

        /// A stage's coarse status. The view draws a green ✓ / amber ring / gray ring.
        enum Status: Sendable, Equatable {
            case pending   // not started
            case active    // in flight
            case done      // completed

            /// Palette token for the row's status circle (design: green / amber / gray).
            var token: PaletteToken {
                switch self {
                case .done:    .success
                case .active:  .accent
                case .pending: .textTertiary
                }
            }
        }
    }

    // MARK: PrimaryAction

    /// What the stateful primary button does in the current phase.
    enum PrimaryAction: Sendable, Equatable {
        case archiveAndUpload   // start the full pipeline (`AppModel.buildAndPublish`)
        case busy               // a run is in flight — the button is disabled
        case openInstallLink    // open `shareURL` in the browser
    }

    // MARK: - Derivation

    /// Maps the live `AppModel` flags onto the coarse step list + button state. Pure function
    /// of its inputs. In-flight flags take priority over completed results, so re-running a
    /// pipeline always shows progress (and hides the previous run's stale install link).
    static func derive(
        isArchiving: Bool,
        isPublishing: Bool,
        lastArtifactURL: URL?,
        lastInstallURL: URL?,
        lastError: String?
    ) -> ArchiveJobViewState {
        let phase = self.phase(
            isArchiving: isArchiving, isPublishing: isPublishing,
            hasArtifact: lastArtifactURL != nil, hasInstallURL: lastInstallURL != nil
        )
        let (title, action) = primary(for: phase)
        return ArchiveJobViewState(
            steps: steps(for: phase),
            primaryTitle: title,
            primaryAction: action,
            shareURL: (phase == .published) ? lastInstallURL : nil,
            errorMessage: lastError
        )
    }

    /// The coarse phase the job is in. In-flight flags win over results.
    private enum Phase { case idle, archiving, uploading, archived, published }

    private static func phase(
        isArchiving: Bool, isPublishing: Bool, hasArtifact: Bool, hasInstallURL: Bool
    ) -> Phase {
        if isPublishing { return .uploading }    // full pipeline (archive → upload) in flight
        if isArchiving  { return .archiving }     // Build & Archive only path in flight
        if hasInstallURL { return .published }    // finalized: install link minted
        if hasArtifact   { return .archived }     // artifact built, not yet uploaded
        return .idle
    }

    private static func steps(for phase: Phase) -> [Step] {
        func step(_ kind: Step.Kind, _ status: Step.Status) -> Step {
            Step(kind: kind, title: title(for: kind), status: status)
        }
        switch phase {
        case .idle:
            return [step(.build, .pending), step(.archive, .pending),
                    step(.upload, .pending), step(.share, .pending)]
        case .archiving:
            // Build & archive are one backend command — both active, can't be split coarsely.
            return [step(.build, .active), step(.archive, .active),
                    step(.upload, .pending), step(.share, .pending)]
        case .uploading:
            // Coarse: the publish's archive sub-phase is rolled into "done" (see file note).
            return [step(.build, .done), step(.archive, .done),
                    step(.upload, .active), step(.share, .pending)]
        case .archived:
            return [step(.build, .done), step(.archive, .done),
                    step(.upload, .pending), step(.share, .pending)]
        case .published:
            return [step(.build, .done), step(.archive, .done),
                    step(.upload, .done), step(.share, .done)]
        }
    }

    private static func title(for kind: Step.Kind) -> String {
        switch kind {
        case .build:   "Build & codesign"
        case .archive: "Archive"
        case .upload:  "Upload to Hangar"     // Hangar, not the design's Google Drive
        case .share:   "Get install link"
        }
    }

    private static func primary(for phase: Phase) -> (title: String, action: PrimaryAction) {
        switch phase {
        case .idle, .archived: ("Archive & Upload", .archiveAndUpload)
        case .archiving:       ("Archiving…", .busy)
        case .uploading:       ("Uploading…", .busy)
        case .published:       ("Open Install Link", .openInstallLink)
        }
    }
}
