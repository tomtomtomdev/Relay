//
//  ArchivePresentationTests.swift
//  RelayTests
//
//  Slice 14 — the testable presentation core for the Archive & Distribute window (frame 5,
//  the final UI-series slice). The SwiftUI body stays thin; the decidable part is
//  `ArchiveJobViewState.derive`, which maps the existing `AppModel` build/publish flags onto
//  a coarse step list (Build → Archive → Upload → Share link) with per-step status circles
//  and a stateful primary button. Pure (Foundation-only) — no SwiftUI, no I/O — mirroring
//  `SessionPresentation` / `PopoverPresentation` / `SettingsPresentation`.
//
//  Coarse-only by design (PLAN Slice 14): our backend exposes two in-flight flags
//  (`isArchiving` / `isPublishing`) and two results (`lastArtifactURL` / `lastInstallURL`),
//  not per-step progress, so these tests pin the coarse mapping. Fine-grained % is backlog.
//

import Testing
import Foundation
@testable import Relay

struct ArchivePresentationTests {

    private let url = URL(string: "https://hangar.example.com/i/relay-1.4.0")!
    private let artifact = URL(fileURLWithPath: "/tmp/Relay-1.4.0.dmg")

    // Convenience: status of a step kind in a derived state.
    private func status(_ s: ArchiveJobViewState, _ kind: ArchiveJobViewState.Step.Kind)
        -> ArchiveJobViewState.Step.Status {
        s.steps.first { $0.kind == kind }!.status
    }

    // MARK: - Step list shape

    @Test func stepsAreTheFourStagesInOrder() {
        let s = ArchiveJobViewState.derive(
            isArchiving: false, isPublishing: false,
            lastArtifactURL: nil, lastInstallURL: nil, lastError: nil
        )
        #expect(s.steps.map(\.kind) == [.build, .archive, .upload, .share])
        #expect(s.steps.allSatisfy { !$0.title.isEmpty })
        #expect(s.steps.map(\.id) == ["build", "archive", "upload", "share"])  // stable ForEach id
    }

    // MARK: - Idle (nothing run yet)

    @Test func idleIsAllPendingAndOffersArchiveAndUpload() {
        let s = ArchiveJobViewState.derive(
            isArchiving: false, isPublishing: false,
            lastArtifactURL: nil, lastInstallURL: nil, lastError: nil
        )
        #expect(s.steps.allSatisfy { $0.status == .pending })
        #expect(s.primaryTitle == "Archive & Upload")
        #expect(s.primaryAction == .archiveAndUpload)
        #expect(s.shareURL == nil)
        #expect(s.errorMessage == nil)
    }

    // MARK: - Archiving (Build & Archive only path)

    @Test func archivingMarksTheBuildArchiveStagesActiveAndDisablesPrimary() {
        let s = ArchiveJobViewState.derive(
            isArchiving: true, isPublishing: false,
            lastArtifactURL: nil, lastInstallURL: nil, lastError: nil
        )
        #expect(status(s, .build) == .active)
        #expect(status(s, .archive) == .active)
        #expect(status(s, .upload) == .pending)
        #expect(status(s, .share) == .pending)
        #expect(s.primaryTitle == "Archiving…")
        #expect(s.primaryAction == .busy)
    }

    // MARK: - Uploading (full publish in flight) — matches the design frame exactly

    @Test func publishingShowsBuildArchiveDoneUploadActive() {
        let s = ArchiveJobViewState.derive(
            isArchiving: false, isPublishing: true,
            lastArtifactURL: nil, lastInstallURL: nil, lastError: nil
        )
        #expect(status(s, .build) == .done)
        #expect(status(s, .archive) == .done)
        #expect(status(s, .upload) == .active)
        #expect(status(s, .share) == .pending)
        #expect(s.primaryTitle == "Uploading…")
        #expect(s.primaryAction == .busy)
        #expect(s.shareURL == nil)   // no link until finalized
    }

    // MARK: - Archived (artifact produced, not yet published)

    @Test func archivedShowsBuildArchiveDoneAndCanReRun() {
        let s = ArchiveJobViewState.derive(
            isArchiving: false, isPublishing: false,
            lastArtifactURL: artifact, lastInstallURL: nil, lastError: nil
        )
        #expect(status(s, .build) == .done)
        #expect(status(s, .archive) == .done)
        #expect(status(s, .upload) == .pending)
        #expect(status(s, .share) == .pending)
        #expect(s.primaryTitle == "Archive & Upload")   // re-runnable (publish re-archives)
        #expect(s.primaryAction == .archiveAndUpload)
        #expect(s.shareURL == nil)
    }

    // MARK: - Published (install URL minted)

    @Test func publishedIsAllDoneAndOffersTheInstallLink() {
        let s = ArchiveJobViewState.derive(
            isArchiving: false, isPublishing: false,
            lastArtifactURL: nil, lastInstallURL: url, lastError: nil
        )
        #expect(s.steps.allSatisfy { $0.status == .done })
        #expect(s.primaryTitle == "Open Install Link")
        #expect(s.primaryAction == .openInstallLink)
        #expect(s.shareURL == url)
    }

    // MARK: - In-flight flags take priority over stale results

    @Test func reRunningPublishHidesTheStaleLinkAndShowsProgress() {
        // A prior publish left an install URL, but a fresh publish is in flight.
        let s = ArchiveJobViewState.derive(
            isArchiving: false, isPublishing: true,
            lastArtifactURL: nil, lastInstallURL: url, lastError: nil
        )
        #expect(status(s, .upload) == .active)
        #expect(s.primaryAction == .busy)
        #expect(s.shareURL == nil)   // don't surface the stale link during a re-run
    }

    // MARK: - Error overlay (coarse: on failure both in-flight flags are already reset)

    @Test func errorMessageIsSurfacedWithoutAnActiveSpinner() {
        let s = ArchiveJobViewState.derive(
            isArchiving: false, isPublishing: false,
            lastArtifactURL: nil, lastInstallURL: nil, lastError: "Publish failed."
        )
        #expect(s.errorMessage == "Publish failed.")
        #expect(s.steps.allSatisfy { $0.status != .active })   // nothing pretends to be running
        #expect(s.primaryAction == .archiveAndUpload)          // retryable
    }

    // MARK: - Per-step status → palette token (design: green ✓ / amber / gray)

    @Test func eachStatusMapsToItsPaletteToken() {
        #expect(ArchiveJobViewState.Step.Status.done.token == .success)
        #expect(ArchiveJobViewState.Step.Status.active.token == .accent)
        #expect(ArchiveJobViewState.Step.Status.pending.token == .textTertiary)
    }
}
