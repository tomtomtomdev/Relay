//
//  DistributionService.swift
//  Relay
//
//  Slice 9 — the distribution contract (SPEC §6). These value types mirror Hangar's API
//  field-for-field (JSON keys via `CodingKeys`), so `HangarClient` is just transport over
//  them. Everything here is pure and `Sendable` — no I/O, no secrets.
//
//  `ArtifactDigest` computes the artifact SHA-256 in pure Swift (stdlib only) rather than
//  pulling in CryptoKit/CommonCrypto, honouring the zero-extra-framework guardrail
//  (SPEC §5: stdlib / Foundation / AppKit / Security only). SHA-256 here is a content
//  checksum for upload integrity — not a security primitive.
//

import Foundation

// MARK: - Service abstraction

/// Publishes a built artifact to a distribution backend and returns where to install it.
/// Injected so the menu-bar "Build & Publish" can be driven by a stub in tests.
nonisolated protocol DistributionService: Sendable {
    func publish(artifact: URL, metadata: ReleaseMetadata) async throws -> PublishResult
}

/// Which platform the artifact targets — drives OTA install vs. download link on Hangar.
nonisolated enum Platform: String, Codable, Sendable {
    case macos, ios
}

// MARK: - Request / response models (Hangar contract, field-for-field)

/// Metadata sent alongside an uploaded artifact. JSON keys mirror Hangar exactly
/// (`bundleID` ↔ `bundleId`); nil optionals are omitted, never encoded as `null`.
nonisolated struct ReleaseMetadata: Sendable, Encodable, Equatable {
    let bundleID: String       // JSON: bundleId  (CFBundleIdentifier)
    let version: String        // CFBundleShortVersionString
    let build: String          // CFBundleVersion
    let channel: String        // "internal" / "beta"
    let platform: Platform     // .macos | .ios
    let releaseNotes: String?
    let minOS: String?
    let gitCommit: String?

    enum CodingKeys: String, CodingKey {
        case bundleID = "bundleId", version, build, channel, platform
        case releaseNotes, minOS, gitCommit
    }
}

nonisolated extension ReleaseMetadata {
    /// Build metadata from a bundle's Info.plist (`bundleID`/`version`/`build`/`minOS`),
    /// plus the target platform and a git commit. Missing keys degrade to empty/nil rather
    /// than crashing — a partially-configured build still produces sane metadata.
    static func from(
        infoDictionary: [String: Any],
        platform: Platform,
        channel: String,
        gitCommit: String?,
        releaseNotes: String? = nil
    ) -> ReleaseMetadata {
        func string(_ key: String) -> String { (infoDictionary[key] as? String) ?? "" }
        return ReleaseMetadata(
            bundleID: string("CFBundleIdentifier"),
            version: string("CFBundleShortVersionString"),
            build: string("CFBundleVersion"),
            channel: channel,
            platform: platform,
            releaseNotes: releaseNotes,
            minOS: infoDictionary["LSMinimumSystemVersion"] as? String,
            gitCommit: gitCommit
        )
    }
}

/// Hangar's 201/200 publish body. JSON keys mirror Hangar (`releaseID` ↔ `releaseId`).
nonisolated struct PublishResult: Sendable, Decodable, Equatable {
    let releaseID: String       // JSON: releaseId
    let installURL: URL
    let version: String
    let build: String
    let channel: String
    let checksumSha256: String?
    let sizeBytes: Int?
    let createdAt: Date?        // ISO-8601

    enum CodingKeys: String, CodingKey {
        case releaseID = "releaseId", installURL, version, build, channel
        case checksumSha256, sizeBytes, createdAt
    }
}

// MARK: - Errors

/// Maps Hangar's HTTP statuses + `{ error: { code, message } }` bodies (SPEC §6). Carries
/// only a status code — never the API token or any secret.
nonisolated enum HangarError: Error, Equatable, Sendable {
    case invalidToken          // 401
    case insufficientScope     // 403
    case notFound              // 404
    case notFinalized          // 409 (generic)
    case checksumMismatch      // 409 (code: checksum_mismatch)
    case tooLarge              // 413
    case unsupportedArtifact   // 415
    case validation            // 422
    case server(status: Int)   // any other non-2xx
    case transport             // no HTTP response / URLError
    case invalidResponse       // 2xx body didn't decode
    case artifactUnreadable    // the local artifact file couldn't be read
}

// MARK: - Artifact checksum

/// Pure-Swift SHA-256, stdlib only. Used to compute the artifact checksum Hangar expects.
nonisolated enum ArtifactDigest {

    /// Lowercase hex SHA-256 of `data`.
    static func sha256Hex(_ data: Data) -> String {
        var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
        ]

        // Pre-processing: append 0x80, zero-pad to 56 mod 64, then the 64-bit big-endian length.
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) &* 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
        }

        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 &- n)) }

        var w = [UInt32](repeating: 0, count: 64)
        var offset = 0
        while offset < message.count {
            for i in 0..<16 {
                let j = offset + i * 4
                w[i] = (UInt32(message[j]) << 24)
                     | (UInt32(message[j + 1]) << 16)
                     | (UInt32(message[j + 2]) << 8)
                     |  UInt32(message[j + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }

            var a = h[0], b = h[1], c = h[2], d = h[3]
            var e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }

            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
            offset += 64
        }

        return h.map { String(format: "%08x", $0) }.joined()
    }
}
