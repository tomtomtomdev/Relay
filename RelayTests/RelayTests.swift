//
//  RelayTests.swift
//  RelayTests
//
//  Created by tommy yohanes on 26/06/26.
//

import Testing
@testable import Relay

/// Slice 0 — the menu-bar status glyph model (SPEC §4: stopped / polling / unlocked / error).
struct AppStatusTests {

    @Test func coversTheFourSpecStates() {
        #expect(AppStatus.allCases.count == 4)
        #expect(AppStatus.allCases.contains(.stopped))
        #expect(AppStatus.allCases.contains(.polling))
        #expect(AppStatus.allCases.contains(.unlocked))
        #expect(AppStatus.allCases.contains(.error))
    }

    @Test func everyStatusMapsToANonEmptyGlyph() {
        for status in AppStatus.allCases {
            #expect(!status.systemImageName.isEmpty)
        }
    }

    @Test func eachStatusHasADistinctGlyph() {
        let glyphs = AppStatus.allCases.map(\.systemImageName)
        #expect(Set(glyphs).count == AppStatus.allCases.count)
    }

    @Test func everyStatusHasANonEmptyLabel() {
        for status in AppStatus.allCases {
            #expect(!status.label.isEmpty)
        }
    }
}
