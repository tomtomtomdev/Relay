//
//  RoutingTelegramStub.swift
//  RelayTests
//
//  Slice 6 — offline Telegram for the wire-through integration tests. Unlike the
//  single-response `StubURLProtocol` (Slice 2), the bridge polls `getUpdates` in a loop
//  *and* calls `sendMessage`, so this stub routes by path:
//
//    · `getUpdates`  → pop the next queued batch (or an empty long-poll-style hold).
//    · `sendMessage` → record the chat id + text the bridge tried to send.
//
//  State is process-static (URLProtocol is instantiated by URLSession), guarded by a
//  lock because the bridge hits it from several concurrent tasks. Suites stay
//  `.serialized` so tests don't share queued/captured state.
//

import Foundation
@testable import Relay

nonisolated final class RoutingTelegramStub: URLProtocol {

    /// One captured outgoing `sendMessage`.
    struct SentMessage: Sendable, Equatable {
        let chatID: Int64
        let text: String
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var updateBatches: [[Update]] = []
    nonisolated(unsafe) private static var sent: [SentMessage] = []

    // MARK: - Test control surface

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        updateBatches.removeAll()
        sent.removeAll()
    }

    /// Queue a batch the next `getUpdates` poll will return (FIFO).
    static func enqueue(_ updates: [Update]) {
        lock.lock(); defer { lock.unlock() }
        updateBatches.append(updates)
    }

    /// Everything the bridge has tried to send so far, in order.
    static func sentMessages() -> [SentMessage] {
        lock.lock(); defer { lock.unlock() }
        return sent
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url?.path ?? ""
        let body: Data
        if path.hasSuffix("/sendMessage") {
            Self.record(request)
            body = Self.okMessageJSON
        } else if path.hasSuffix("/getUpdates") {
            body = Self.nextUpdatesJSON()
        } else {
            body = Self.okEmptyJSON
        }
        respond(with: body)
    }

    // MARK: - Routing helpers

    /// Pop the next queued batch as a Telegram `ok:true` envelope. An exhausted queue
    /// returns an empty batch after a short hold — mimicking a held long poll so the
    /// bridge's ingest loop doesn't spin against an instant-empty stub.
    private static func nextUpdatesJSON() -> Data {
        lock.lock()
        let batch = updateBatches.isEmpty ? [] : updateBatches.removeFirst()
        lock.unlock()
        if batch.isEmpty { usleep(50_000) }   // 50ms simulated long-poll hold
        return try! JSONEncoder().encode(OKResponse(result: batch))
    }

    /// Decode the `sendMessage` JSON body and record what the bridge tried to send.
    private static func record(_ request: URLRequest) {
        guard let data = readBody(from: request),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let chatID = (obj["chat_id"] as? NSNumber)?.int64Value ?? 0
        let text = obj["text"] as? String ?? ""
        lock.lock(); sent.append(SentMessage(chatID: chatID, text: text)); lock.unlock()
    }

    private func respond(with body: Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
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

    // A constant `ok:true` message envelope — the client ignores `sendMessage`'s result.
    private static let okMessageJSON: Data = try! JSONEncoder().encode(
        OKResponse(result: TelegramMessage(
            messageID: 1, from: nil, chat: TelegramChat(id: 0, type: "private"), date: 0, text: nil
        ))
    )
    private static let okEmptyJSON: Data = Data(#"{"ok":true,"result":[]}"#.utf8)
}

/// Minimal `ok:true` envelope mirroring Telegram's response shape, for encoding canned
/// results back to `TelegramClient` (which decodes `TelegramResponse<T>`).
private struct OKResponse<Result: Encodable>: Encodable {
    let ok = true
    let result: Result
}
