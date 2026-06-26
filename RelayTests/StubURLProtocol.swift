//
//  StubURLProtocol.swift
//  RelayTests
//
//  Slice 2 — offline Telegram. A URLProtocol that returns canned responses and
//  captures the outgoing request, so TelegramClient is tested with zero live API
//  calls (PLAN Slice 2, SPEC §7).
//
//  Canned response is held as Sendable primitives (Int status + Data body) rather
//  than a closure, so nothing non-Sendable is captured under Swift 6. Suites that use
//  it must be `.serialized` because the capture/stub state is process-static.
//

import Foundation

nonisolated final class StubURLProtocol: URLProtocol {

    nonisolated(unsafe) static var stubStatus: Int = 200
    nonisolated(unsafe) static var stubBody: Data = Data()
    nonisolated(unsafe) static private(set) var lastRequest: URLRequest?
    nonisolated(unsafe) static private(set) var lastBody: Data?

    static func reset() {
        stubStatus = 200
        stubBody = Data()
        lastRequest = nil
        lastBody = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        StubURLProtocol.lastRequest = request
        StubURLProtocol.lastBody = Self.readBody(from: request)

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.stubStatus,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.stubBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession often hands the body to a URLProtocol as a stream, not `httpBody`,
    /// so read both.
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
