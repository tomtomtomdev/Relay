//
//  ReleaseMetadataTests.swift
//  RelayTests
//
//  Slice 9 — the release metadata that travels with a published artifact (PLAN Slice 9,
//  SPEC §6). Two concerns, both pure: the SHA-256 checksum read from the artifact, and the
//  factory that populates `ReleaseMetadata` from a built bundle's Info.plist + platform +
//  git commit. The JSON encoding is asserted to match Hangar's keys field-for-field.
//

import Testing
import Foundation
@testable import Relay

@Suite struct ReleaseMetadataTests {

    // MARK: - SHA-256 (artifact checksum)

    /// Known NIST test vectors — proves the pure-Swift digest is a correct SHA-256, so the
    /// rest of the suite can trust `ArtifactDigest.sha256Hex` to compute expected checksums.
    @Test func sha256MatchesKnownVectors() {
        #expect(ArtifactDigest.sha256Hex(Data("abc".utf8))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(ArtifactDigest.sha256Hex(Data())
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        // A multi-block message (> 55 bytes forces a second padded block).
        let long = String(repeating: "a", count: 1_000)
        #expect(ArtifactDigest.sha256Hex(Data(long.utf8))
                == "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }

    // MARK: - Factory from a bundle's Info.plist

    @Test func fromInfoDictionaryMapsBundleFields() {
        let info: [String: Any] = [
            "CFBundleIdentifier": "co.tuntun.relay",
            "CFBundleShortVersionString": "2.3",
            "CFBundleVersion": "108",
            "LSMinimumSystemVersion": "13.0",
        ]
        let m = ReleaseMetadata.from(
            infoDictionary: info, platform: .macos, channel: "internal", gitCommit: "abc123"
        )
        #expect(m.bundleID == "co.tuntun.relay")
        #expect(m.version == "2.3")
        #expect(m.build == "108")
        #expect(m.minOS == "13.0")
        #expect(m.channel == "internal")
        #expect(m.platform == .macos)
        #expect(m.gitCommit == "abc123")
    }

    @Test func fromInfoDictionaryToleratesMissingKeys() {
        let m = ReleaseMetadata.from(
            infoDictionary: [:], platform: .ios, channel: "beta", gitCommit: nil
        )
        #expect(m.bundleID == "")
        #expect(m.version == "")
        #expect(m.build == "")
        #expect(m.minOS == nil)
        #expect(m.gitCommit == nil)
        #expect(m.platform == .ios)
    }

    // MARK: - JSON contract (Hangar keys, field-for-field)

    @Test func encodesWithHangarJSONKeysAndOmitsNilOptionals() throws {
        let m = ReleaseMetadata(
            bundleID: "b", version: "1", build: "2", channel: "internal",
            platform: .macos, releaseNotes: nil, minOS: nil, gitCommit: nil
        )
        let data = try JSONEncoder().encode(m)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(obj["bundleId"] as? String == "b")          // bundleID ↔ bundleId
        #expect(obj["platform"] as? String == "macos")
        #expect(obj.keys.contains("bundleID") == false)     // never the Swift name
        // nil optionals are omitted, not encoded as null.
        #expect(obj.keys.contains("releaseNotes") == false)
        #expect(obj.keys.contains("minOS") == false)
        #expect(obj.keys.contains("gitCommit") == false)
    }
}
