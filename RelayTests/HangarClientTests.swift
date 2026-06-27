//
//  HangarClientTests.swift
//  RelayTests
//
//  Slice 9 — the distribution client (PLAN Slice 9, SPEC §6, §7). `HangarClient` publishes
//  a built artifact to Hangar. Everything here runs against `HangarStub` (a `URLProtocol`)
//  so there is **zero** live upload: the stub is the only server. We assert the two upload
//  shapes (direct multipart below a size threshold; presigned PUT + finalize above it), the
//  `Bearer` auth header, the Hangar JSON contract field-for-field, and the error mapping.
//
//  `.serialized` because `HangarStub` holds its queued/captured state process-statically.
//

import Testing
import Foundation
@testable import Relay

@Suite(.serialized)
struct HangarClientTests {

    // MARK: - Fixtures

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HangarStub.self]
        return URLSession(configuration: config)
    }

    private func writeArtifact(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-artifact-\(UUID().uuidString).dmg")
        try Data(contents.utf8).write(to: url)
        return url
    }

    private var sampleMetadata: ReleaseMetadata {
        ReleaseMetadata(
            bundleID: "co.tuntun.relay", version: "1.0", build: "42", channel: "internal",
            platform: .macos, releaseNotes: "first cut", minOS: "13.0", gitCommit: "deadbee"
        )
    }

    /// A representative Hangar success body (the 201/200 `PublishResult`).
    private static let publishResultJSON = """
    {"releaseId":"rel_123","installURL":"https://hangar.test/i/rel_123","version":"1.0",\
    "build":"42","channel":"internal","checksumSha256":"abc123","sizeBytes":13,\
    "createdAt":"2026-06-27T10:00:00Z"}
    """

    private func makeClient(threshold: Int, token: String = "tok-SECRET") -> HangarClient {
        HangarClient(
            baseURL: URL(string: "https://hangar.test")!,
            token: token,
            session: makeSession(),
            multipartThreshold: threshold
        )
    }

    // MARK: - Direct multipart (< threshold)

    @Test func multipartUploadSendsTwoPartsWithBearerAndDecodesResult() async throws {
        HangarStub.reset()
        HangarStub.enqueue(.init(status: 201, json: Self.publishResultJSON))
        let artifact = try writeArtifact("DMG-BYTES-123")   // 13 bytes < threshold → multipart
        defer { try? FileManager.default.removeItem(at: artifact) }

        let client = makeClient(threshold: 1_000_000)
        let result = try await client.publish(artifact: artifact, metadata: sampleMetadata)

        // The 201 body decoded into PublishResult (releaseId → releaseID).
        #expect(result.releaseID == "rel_123")
        #expect(result.installURL == URL(string: "https://hangar.test/i/rel_123")!)
        #expect(result.checksumSha256 == "abc123")
        #expect(result.createdAt != nil)   // ISO-8601 decoded

        let reqs = HangarStub.requests()
        #expect(reqs.count == 1)
        let req = try #require(reqs.first)
        #expect(req.method == "POST")
        #expect(req.url.path == "/api/v1/releases")
        #expect(req.header("Authorization") == "Bearer tok-SECRET")

        let contentType = try #require(req.header("Content-Type"))
        let marker = "multipart/form-data; boundary="
        #expect(contentType.hasPrefix(marker))
        let boundary = String(contentType.dropFirst(marker.count))

        // Two parts: metadata JSON + artifact octet-stream.
        let parts = Multipart.parts(in: req.body, boundary: boundary)
        #expect(parts.count == 2)
        let metaData = try #require(parts["metadata"])
        let artifactPart = try #require(parts["artifact"])
        #expect(artifactPart == Data("DMG-BYTES-123".utf8))

        // The metadata part is Hangar's JSON, keyed the Hangar way (`bundleId`, not `bundleID`).
        let obj = try #require(try JSONSerialization.jsonObject(with: metaData) as? [String: Any])
        #expect(obj["bundleId"] as? String == "co.tuntun.relay")
        #expect(obj["version"] as? String == "1.0")
        #expect(obj["build"] as? String == "42")
        #expect(obj["channel"] as? String == "internal")
        #expect(obj["platform"] as? String == "macos")
        #expect(obj["minOS"] as? String == "13.0")
        #expect(obj["gitCommit"] as? String == "deadbee")
    }

    // MARK: - Presigned (>= threshold)

    @Test func presignedUploadCreatesThenPutsThenFinalizes() async throws {
        HangarStub.reset()
        HangarStub.enqueue(.init(status: 201, json: """
        {"releaseId":"rel_777","uploadUrl":"https://storage.test/upload/rel_777",\
        "uploadMethod":"PUT","uploadHeaders":{"x-amz-acl":"private"},"expiresIn":3600}
        """))
        HangarStub.enqueue(.init(status: 200))                                  // PUT
        HangarStub.enqueue(.init(status: 200, json: Self.publishResultJSON))    // finalize

        let body = String(repeating: "X", count: 64)
        let artifact = try writeArtifact(body)   // 64 bytes >= threshold → presigned
        defer { try? FileManager.default.removeItem(at: artifact) }

        let client = makeClient(threshold: 10)
        let result = try await client.publish(artifact: artifact, metadata: sampleMetadata)
        #expect(result.releaseID == "rel_123")

        let reqs = HangarStub.requests()
        #expect(reqs.count == 3)
        let expectedChecksum = ArtifactDigest.sha256Hex(Data(body.utf8))

        // 1) create — JSON metadata + sizeBytes + checksumSha256, no file, with Bearer.
        let create = reqs[0]
        #expect(create.method == "POST")
        #expect(create.url.path == "/api/v1/releases")
        #expect(create.header("Content-Type") == "application/json")
        #expect(create.header("Authorization") == "Bearer tok-SECRET")
        let createObj = try #require(try JSONSerialization.jsonObject(with: create.body) as? [String: Any])
        #expect(createObj["bundleId"] as? String == "co.tuntun.relay")
        #expect(createObj["sizeBytes"] as? Int == 64)
        #expect(createObj["checksumSha256"] as? String == expectedChecksum)

        // 2) PUT — to the presigned URL, replaying uploadHeaders, body == file bytes,
        //    and crucially NOT carrying the Bearer token to a third-party storage URL.
        let put = reqs[1]
        #expect(put.method == "PUT")
        #expect(put.url == URL(string: "https://storage.test/upload/rel_777")!)
        #expect(put.body == Data(body.utf8))
        #expect(put.header("x-amz-acl") == "private")
        #expect(put.header("Authorization") == nil)

        // 3) finalize — POST …/{releaseId}/finalize with { checksumSha256 }, with Bearer.
        let finalize = reqs[2]
        #expect(finalize.method == "POST")
        #expect(finalize.url.path == "/api/v1/releases/rel_777/finalize")
        #expect(finalize.header("Authorization") == "Bearer tok-SECRET")
        let finObj = try #require(try JSONSerialization.jsonObject(with: finalize.body) as? [String: Any])
        #expect(finObj["checksumSha256"] as? String == expectedChecksum)
    }

    @Test func thresholdBoundaryUsesMultipartWhenEqualToSizeMinusOne() async throws {
        // size (5) < threshold (6) → multipart (single request).
        HangarStub.reset()
        HangarStub.enqueue(.init(status: 201, json: Self.publishResultJSON))
        let artifact = try writeArtifact("12345")   // 5 bytes
        defer { try? FileManager.default.removeItem(at: artifact) }

        _ = try await makeClient(threshold: 6).publish(artifact: artifact, metadata: sampleMetadata)
        #expect(HangarStub.requests().count == 1)   // not the 3-step presigned flow
    }

    // MARK: - Error mapping

    @Test(arguments: [
        (401, "", HangarError.invalidToken),
        (403, "", HangarError.insufficientScope),
        (404, "", HangarError.notFound),
        (413, "", HangarError.tooLarge),
        (415, "", HangarError.unsupportedArtifact),
        (422, #"{"error":{"code":"validation_failed","message":"bad metadata"}}"#, HangarError.validation),
        (409, #"{"error":{"code":"checksum_mismatch","message":"nope"}}"#, HangarError.checksumMismatch),
        (409, #"{"error":{"code":"not_finalized","message":"pending"}}"#, HangarError.notFinalized),
        (500, "", HangarError.server(status: 500)),
    ])
    func mapsHangarStatusesToTypedErrors(status: Int, body: String, expected: HangarError) async throws {
        HangarStub.reset()
        HangarStub.enqueue(.init(status: status, json: body))
        let artifact = try writeArtifact("x")   // small → single multipart request
        defer { try? FileManager.default.removeItem(at: artifact) }

        await #expect(throws: expected) {
            try await makeClient(threshold: 1_000_000).publish(artifact: artifact, metadata: sampleMetadata)
        }
    }

    @Test func missingArtifactThrowsArtifactUnreadableBeforeAnyRequest() async throws {
        HangarStub.reset()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-missing-\(UUID().uuidString).dmg")

        await #expect(throws: HangarError.artifactUnreadable) {
            try await makeClient(threshold: 1_000_000).publish(artifact: missing, metadata: sampleMetadata)
        }
        #expect(HangarStub.requests().isEmpty)   // never hit the network
    }

    /// SPEC §6/§5: the API token is sent as a Bearer header but must never leak into a
    /// thrown error's text (the same secret-never-echoed discipline as the rest of the app).
    @Test func errorsNeverEchoTheToken() async throws {
        HangarStub.reset()
        HangarStub.enqueue(.init(status: 401, json: #"{"error":{"code":"invalid_token"}}"#))
        let artifact = try writeArtifact("x")
        defer { try? FileManager.default.removeItem(at: artifact) }

        do {
            _ = try await makeClient(threshold: 1_000_000, token: "SUPER-SECRET-TOKEN")
                .publish(artifact: artifact, metadata: sampleMetadata)
            Issue.record("expected a throw")
        } catch {
            #expect(!String(describing: error).contains("SUPER-SECRET-TOKEN"))
        }
    }
}
