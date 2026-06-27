//
//  HangarStub.swift
//  RelayTests
//
//  Slice 9 — offline Hangar (PLAN Slice 9, SPEC §6, §7). The publish flows make a known
//  *sequence* of requests (multipart = one POST; presigned = create → PUT → finalize), so
//  this stub returns canned responses FIFO and captures every request (method, url,
//  headers, body) for assertions. The stub is the only "server" — no live upload ever.
//
//  State is process-static (URLProtocol is instantiated by URLSession), guarded by a
//  lock; suites that use it stay `.serialized` so tests don't share queued/captured state.
//

import Foundation

nonisolated final class HangarStub: URLProtocol {

    /// One captured outgoing request.
    struct Captured: Sendable {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data

        /// Case-insensitive header lookup (URLSession may canonicalise header casing).
        func header(_ name: String) -> String? {
            for (k, v) in headers where k.caseInsensitiveCompare(name) == .orderedSame { return v }
            return nil
        }
    }

    /// One canned response the stub will hand back (in FIFO order).
    struct Canned: Sendable {
        let status: Int
        let body: Data
        let headers: [String: String]

        init(status: Int, json: String = "", headers: [String: String] = [:]) {
            self.status = status
            self.body = Data(json.utf8)
            self.headers = headers
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [Canned] = []
    nonisolated(unsafe) private static var captured: [Captured] = []

    // MARK: - Test control surface

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        responses.removeAll()
        captured.removeAll()
    }

    /// Queue a response the next request will receive.
    static func enqueue(_ response: Canned) {
        lock.lock(); defer { lock.unlock() }
        responses.append(response)
    }

    /// Every request the client has made so far, in order.
    static func requests() -> [Captured] {
        lock.lock(); defer { lock.unlock() }
        return captured
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        let headers = request.allHTTPHeaderFields ?? [:]
        let body = Self.readBody(from: request) ?? Data()

        Self.lock.lock()
        Self.captured.append(Captured(method: method, url: request.url!, headers: headers, body: body))
        let canned = Self.responses.isEmpty ? Canned(status: 500) : Self.responses.removeFirst()
        Self.lock.unlock()

        var fields = canned.headers
        if fields["Content-Type"] == nil { fields["Content-Type"] = "application/json" }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: canned.status,
            httpVersion: "HTTP/1.1",
            headerFields: fields
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: canned.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// URLSession often streams the body rather than exposing `httpBody`, so read both.
    private static func readBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// A minimal `multipart/form-data` splitter for the tests: returns each part's raw body
/// keyed by its `name="…"`. Handles the exact shape `HangarClient` produces.
enum Multipart {
    static func parts(in body: Data, boundary: String) -> [String: Data] {
        let dashBoundary = Data("--\(boundary)".utf8)
        let crlf = Data("\r\n".utf8)
        let crlfcrlf = Data("\r\n\r\n".utf8)
        let dashes = Data("--".utf8)

        // Locate every boundary marker; the parts lie between consecutive markers.
        var markers: [Range<Data.Index>] = []
        var cursor = body.startIndex
        while let r = body.range(of: dashBoundary, in: cursor..<body.endIndex) {
            markers.append(r)
            cursor = r.upperBound
        }

        var result: [String: Data] = [:]
        for i in 0..<markers.count {
            let start = markers[i].upperBound
            let end = (i + 1 < markers.count) ? markers[i + 1].lowerBound : body.endIndex
            guard start < end else { continue }

            var segment = body.subdata(in: start..<end)
            // Closing marker is "--CRLF" → not a part.
            if segment.starts(with: dashes) { continue }
            // Each part segment opens with CRLF after the boundary.
            if segment.starts(with: crlf) {
                segment = segment.subdata(in: (segment.startIndex + 2)..<segment.endIndex)
            }
            guard let split = segment.range(of: crlfcrlf) else { continue }
            let headerText = String(decoding: segment.subdata(in: segment.startIndex..<split.lowerBound), as: UTF8.self)
            var partBody = segment.subdata(in: split.upperBound..<segment.endIndex)
            // Trim the trailing CRLF that precedes the next boundary.
            if partBody.count >= 2, partBody.suffix(2) == crlf {
                partBody = partBody.subdata(in: partBody.startIndex..<(partBody.endIndex - 2))
            }
            if let name = fieldName(in: headerText) { result[name] = partBody }
        }
        return result
    }

    private static func fieldName(in header: String) -> String? {
        guard let open = header.range(of: "name=\"") else { return nil }
        let rest = header[open.upperBound...]
        guard let close = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<close])
    }
}
