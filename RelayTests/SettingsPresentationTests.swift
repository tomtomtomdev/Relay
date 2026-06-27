//
//  SettingsPresentationTests.swift
//  RelayTests
//
//  Slice 13 — the testable presentation core for the redesigned, tabbed Settings window
//  (design frames 3 & 4, adapted to Hangar). The SwiftUI body stays thin; the decidable
//  bits live in `SettingsPresentation.swift` and are pinned here:
//
//   • `TokenMask`          — the design's structure-preserving bot-token mask (`7847…3kQ`),
//                            and the field's editable-vs-masked state given the Reveal toggle.
//                            The mask must never expose the hidden middle of the secret.
//   • `AllowedIDChips`     — the chip field's add (dedup, reject invalid) / remove logic,
//                            wrapping the existing `AllowedIDs.parse`.
//   • `PolicyPreset` UI    — display name + summary for the *real* presets (strict/standard).
//   • `SettingsTab`        — the four tabs, in order.
//
//  All pure (Foundation-only) — no SwiftUI, no I/O — mirroring `SessionPresentationTests`.
//

import Testing
import Foundation
@testable import Relay

struct SettingsPresentationTests {

    // MARK: - TokenMask.mask (structure-preserving, secret never exposed)

    @Test func masksTheSecretPartKeepingTheBotIDAndEnds() {
        // botid:secret → keep botid + first/last few of the secret, bullets between.
        #expect(TokenMask.mask("123:ABCDEFGH") == "123:ABC••FGH")
    }

    @Test func masksATokenWithoutAColonAcrossTheWholeValue() {
        #expect(TokenMask.mask("ABCDEFGH") == "ABC••FGH")
    }

    @Test func fullyBulletsAValueTooShortToRevealEnds() {
        // 5 chars ≤ prefix(3)+suffix(3): show nothing but bullets.
        #expect(TokenMask.mask("12345") == "•••••")
    }

    @Test func fullyBulletsAShortSecretButKeepsTheBotID() {
        #expect(TokenMask.mask("123:AB") == "123:••")
    }

    @Test func emptyTokenMasksToEmpty() {
        #expect(TokenMask.mask("") == "")
    }

    @Test func maskNeverContainsTheHiddenMiddleOfTheSecret() {
        // The hidden chars ("DE") must not survive anywhere in the masked output.
        let masked = TokenMask.mask("123:ABCDEFGH")
        #expect(!masked.contains("DE"))
        #expect(!masked.contains("CDEF"))
    }

    @Test func maskHonoursCustomVisibleCounts() {
        #expect(TokenMask.mask("123:ABCDEFGH", visiblePrefix: 1, visibleSuffix: 1) == "123:A••••••H")
    }

    // MARK: - TokenMask.fieldState (Reveal toggle / empty entry)

    @Test func emptyTokenIsEditableSoItCanBeEntered() {
        #expect(TokenMask.fieldState(token: "", revealed: false) == .editable)
    }

    @Test func aSetTokenIsMaskedUntilRevealed() {
        #expect(TokenMask.fieldState(token: "123:ABCDEFGH", revealed: false) == .masked("123:ABC••FGH"))
    }

    @Test func revealingASetTokenMakesItEditable() {
        #expect(TokenMask.fieldState(token: "123:ABCDEFGH", revealed: true) == .editable)
    }

    // MARK: - AllowedIDChips.add (dedup, reject invalid, wraps AllowedIDs.parse)

    @Test func addsAValidNewID() {
        #expect(AllowedIDChips.add("7129904842", to: []) == [7129904842])
    }

    @Test func addingADuplicateIsANoOp() {
        #expect(AllowedIDChips.add("7129904842", to: [7129904842]) == [7129904842])
    }

    @Test func addingAnInvalidIDIsANoOp() {
        #expect(AllowedIDChips.add("not-a-number", to: [42]) == [42])
        #expect(AllowedIDChips.add("   ", to: [42]) == [42])
    }

    @Test func addsNegativeGroupIDs() {
        #expect(AllowedIDChips.add("-100488213", to: []) == [-100488213])
    }

    @Test func addsCommaSeparatedBatchPreservingOrderAndDedup() {
        // Existing 1; pasted "2, 1, 3" → append 2 and 3 (1 already present, order kept).
        #expect(AllowedIDChips.add("2, 1, 3", to: [1]) == [1, 2, 3])
    }

    // MARK: - AllowedIDChips.remove

    @Test func removesAnExistingID() {
        #expect(AllowedIDChips.remove(2, from: [1, 2, 3]) == [1, 3])
    }

    @Test func removingAMissingIDIsANoOp() {
        #expect(AllowedIDChips.remove(9, from: [1, 2, 3]) == [1, 2, 3])
    }

    // MARK: - PolicyPreset display (real presets only — no invented modes)

    @Test func policyPresetsHaveDistinctDisplayNames() {
        #expect(PolicyPreset.strict.displayName == "Strict")
        #expect(PolicyPreset.standard.displayName == "Standard")
    }

    @Test func policyPresetSummariesAreNonEmptyAndDistinct() {
        #expect(!PolicyPreset.strict.summary.isEmpty)
        #expect(!PolicyPreset.standard.summary.isEmpty)
        #expect(PolicyPreset.strict.summary != PolicyPreset.standard.summary)
    }

    @Test func onlyTheTwoRealPresetsExist() {
        // Guardrail: the design's Ask/Auto/Plan modes are NOT invented here.
        #expect(PolicyPreset.allCases == [.strict, .standard])
    }

    // MARK: - SettingsTab (the four tabs, in design order)

    @Test func tabsAreInDesignOrder() {
        #expect(SettingsTab.allCases.map(\.title) == ["Telegram", "Claude", "Distribution", "General"])
    }

    @Test func everyTabHasAnIcon() {
        for tab in SettingsTab.allCases {
            #expect(!tab.icon.isEmpty)
        }
    }
}
