//
//  HangarClient.swift
//  Relay
//
//  Slice 9 — publishes a built artifact to Hangar (PLAN Slice 9, SPEC §6). `actor`,
//  URLSession only, no SDK. The API token is injected (Keychain → token wiring is the
//  app's job) and sent as `Authorization: Bearer <token>` at call time — never logged,
//  never echoed, and never sent to the third-party presigned-storage URL.
//
//  Two upload shapes, chosen by the artifact size against an injected threshold:
//   · < threshold → direct multipart: one POST carrying metadata + the file bytes.
//   · ≥ threshold → presigned: create (metadata + size + checksum) → PUT bytes to the
//     returned storage URL replaying its headers → finalize.
//

import Foundation

actor HangarClient: DistributionService {
    private let baseURL: URL
    private let token: String
    private let session: URLSession
    private let multipartThreshold: Int

    /// `multipartThreshold` defaults to 25 MiB — above it, switch to the presigned flow so
    /// a large body never has to be buffered through a single multipart request.
    init(baseURL: URL, token: String, session: URLSession, multipartThreshold: Int = 25 * 1024 * 1024) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
        self.multipartThreshold = multipartThreshold
    }

    func publish(artifact: URL, metadata: ReleaseMetadata) async throws -> PublishResult {
        let fileData: Data
        do {
            fileData = try Data(contentsOf: artifact)
        } catch {
            throw HangarError.artifactUnreadable
        }
        let checksum = ArtifactDigest.sha256Hex(fileData)

        if fileData.count < multipartThreshold {
            return try await uploadMultipart(fileData: fileData, filename: artifact.lastPathComponent, metadata: metadata)
        } else {
            return try await uploadPresigned(fileData: fileData, size: fileData.count, checksum: checksum, metadata: metadata)
        }
    }

    // MARK: - Direct multipart (< threshold)

    private func uploadMultipart(fileData: Data, filename: String, metadata: ReleaseMetadata) async throws -> PublishResult {
        let boundary = "Relay-\(UUID().uuidString)"
        let metadataJSON = try JSONEncoder().encode(metadata)

        var request = URLRequest(url: releasesURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        request.httpBody = Self.multipartBody(
            boundary: boundary, metadataJSON: metadataJSON, fileData: fileData, filename: filename
        )

        let (data, http) = try await perform(request)
        return try decodePublishResult(data, http)
    }

    // MARK: - Presigned (≥ threshold)

    private func uploadPresigned(fileData: Data, size: Int, checksum: String, metadata: ReleaseMetadata) async throws -> PublishResult {
        // 1) Create the release: JSON metadata + sizeBytes + checksumSha256, no file.
        var createRequest = URLRequest(url: releasesURL)
        createRequest.httpMethod = "POST"
        createRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&createRequest)
        createRequest.httpBody = try JSONEncoder().encode(
            PresignedCreate(metadata: metadata, sizeBytes: size, checksumSha256: checksum)
        )
        let (ticketData, createHTTP) = try await perform(createRequest)
        try ensureSuccess(createHTTP, ticketData)
        guard let ticket = try? JSONDecoder().decode(PresignedTicket.self, from: ticketData) else {
            throw HangarError.invalidResponse
        }

        // 2) PUT the bytes to the presigned URL, replaying its headers. The Bearer token is
        //    deliberately NOT attached — the presigned URL is pre-authorised storage.
        var uploadRequest = URLRequest(url: ticket.uploadUrl)
        uploadRequest.httpMethod = ticket.uploadMethod
        for (field, value) in ticket.uploadHeaders {
            uploadRequest.setValue(value, forHTTPHeaderField: field)
        }
        uploadRequest.httpBody = fileData
        let (uploadData, uploadHTTP) = try await perform(uploadRequest)
        try ensureSuccess(uploadHTTP, uploadData)

        // 3) Finalize → the PublishResult.
        let finalizeURL = releasesURL
            .appendingPathComponent(ticket.releaseId)
            .appendingPathComponent("finalize")
        var finalizeRequest = URLRequest(url: finalizeURL)
        finalizeRequest.httpMethod = "POST"
        finalizeRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&finalizeRequest)
        finalizeRequest.httpBody = try JSONEncoder().encode(FinalizeBody(checksumSha256: checksum))

        let (finalData, finalHTTP) = try await perform(finalizeRequest)
        return try decodePublishResult(finalData, finalHTTP)
    }

    // MARK: - Transport / mapping

    private var releasesURL: URL {
        baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("v1")
            .appendingPathComponent("releases")
    }

    private func authorize(_ request: inout URLRequest) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    /// Run the request, surfacing only `.transport` for network-level failures.
    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw HangarError.transport
        }
        guard let http = response as? HTTPURLResponse else { throw HangarError.transport }
        return (data, http)
    }

    private func ensureSuccess(_ http: HTTPURLResponse, _ data: Data) throws {
        guard (200..<300).contains(http.statusCode) else {
            throw Self.mapError(status: http.statusCode, body: data)
        }
    }

    private func decodePublishResult(_ data: Data, _ http: HTTPURLResponse) throws -> PublishResult {
        try ensureSuccess(http, data)
        guard let result = try? Self.resultDecoder().decode(PublishResult.self, from: data) else {
            throw HangarError.invalidResponse
        }
        return result
    }

    /// Map a non-2xx status (+ optional `{ error: { code } }` body) to a typed error.
    private static func mapError(status: Int, body: Data) -> HangarError {
        let code = (try? JSONDecoder().decode(HangarErrorBody.self, from: body))?.error?.code
        switch status {
        case 401: return .invalidToken
        case 403: return .insufficientScope
        case 404: return .notFound
        case 409: return code == "checksum_mismatch" ? .checksumMismatch : .notFinalized
        case 413: return .tooLarge
        case 415: return .unsupportedArtifact
        case 422: return .validation
        default:  return .server(status: status)
        }
    }

    // MARK: - Coding

    /// A fresh decoder configured for Hangar's ISO-8601 `createdAt`. Built per use because
    /// `JSONDecoder` isn't `Sendable` (so it can't be a shared static under Swift 6).
    private static func resultDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Build the two-part `multipart/form-data` body: a `metadata` JSON part and an
    /// `artifact` octet-stream part.
    private static func multipartBody(boundary: String, metadataJSON: Data, fileData: Data, filename: String) -> Data {
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        let crlf = "\r\n"

        append("--\(boundary)\(crlf)")
        append("Content-Disposition: form-data; name=\"metadata\"\(crlf)")
        append("Content-Type: application/json\(crlf)\(crlf)")
        body.append(metadataJSON)
        append(crlf)

        append("--\(boundary)\(crlf)")
        append("Content-Disposition: form-data; name=\"artifact\"; filename=\"\(filename)\"\(crlf)")
        append("Content-Type: application/octet-stream\(crlf)\(crlf)")
        body.append(fileData)
        append(crlf)

        append("--\(boundary)--\(crlf)")
        return body
    }
}

// MARK: - Private wire bodies

/// Presigned "create" body: the metadata flattened to the top level plus `sizeBytes` and
/// `checksumSha256` (SPEC §6). Encoding metadata into the same container merges its keys.
private nonisolated struct PresignedCreate: Encodable {
    let metadata: ReleaseMetadata
    let sizeBytes: Int
    let checksumSha256: String

    private enum ExtraKeys: String, CodingKey { case sizeBytes, checksumSha256 }

    func encode(to encoder: Encoder) throws {
        try metadata.encode(to: encoder)
        var container = encoder.container(keyedBy: ExtraKeys.self)
        try container.encode(sizeBytes, forKey: .sizeBytes)
        try container.encode(checksumSha256, forKey: .checksumSha256)
    }
}

/// The presigned ticket Hangar returns from "create".
private nonisolated struct PresignedTicket: Decodable {
    let releaseId: String
    let uploadUrl: URL
    let uploadMethod: String
    let uploadHeaders: [String: String]
    let expiresIn: Int?
}

private nonisolated struct FinalizeBody: Encodable {
    let checksumSha256: String
}

/// Hangar's error envelope: `{ "error": { "code": …, "message": … } }`.
private nonisolated struct HangarErrorBody: Decodable {
    struct Inner: Decodable {
        let code: String?
        let message: String?
    }
    let error: Inner?
}
