//
//  TelegramClientTests.swift
//  RelayTests
//
//  Slice 2 — TelegramClient parse / offset math / request shaping, all offline via
//  StubURLProtocol (PLAN Slice 2). Serialized because the stub holds static state.
//

import Testing
import Foundation
@testable import Relay

@Suite(.serialized)
struct TelegramClientTests {

    /// A client whose injected session answers every request with `json` / `status`.
    private func client(returning json: String, status: Int = 200) -> TelegramClient {
        StubURLProtocol.reset()
        StubURLProtocol.stubBody = Data(json.utf8)
        StubURLProtocol.stubStatus = status
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return TelegramClient(token: "DUMMY:TOKEN", session: URLSession(configuration: config))
    }

    // MARK: getUpdates parsing

    @Test func getUpdatesParsesCannedJSON() async throws {
        let json = """
        {"ok":true,"result":[
          {"update_id":10,"message":{"message_id":1,"from":{"id":111,"is_bot":false,"first_name":"Tom"},"chat":{"id":111,"type":"private"},"date":1700000000,"text":"hello"}},
          {"update_id":11,"message":{"message_id":2,"from":{"id":111,"is_bot":false,"first_name":"Tom"},"chat":{"id":111,"type":"private"},"date":1700000001,"text":"world"}}
        ]}
        """
        let updates = try await client(returning: json).getUpdates(offset: nil)
        #expect(updates.count == 2)
        #expect(updates.first?.updateID == 10)
        #expect(updates.first?.message?.text == "hello")
        #expect(updates.first?.message?.from?.id == 111)
        #expect(updates.first?.message?.chat.id == 111)
        #expect(updates.last?.updateID == 11)
    }

    @Test func getUpdatesThrowsOnAPIError() async {
        let c = client(returning: #"{"ok":false,"error_code":401,"description":"Unauthorized"}"#)
        await #expect(throws: TelegramError.self) {
            _ = try await c.getUpdates(offset: nil)
        }
    }

    // MARK: request shaping

    @Test func getUpdatesSendsOffsetAndTimeoutQuery() async throws {
        let c = client(returning: #"{"ok":true,"result":[]}"#)
        _ = try await c.getUpdates(offset: 42, timeout: 30)

        let url = try #require(StubURLProtocol.lastRequest?.url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.contains(URLQueryItem(name: "offset", value: "42")))
        #expect(items.contains(URLQueryItem(name: "timeout", value: "30")))
        #expect(url.path.contains("/botDUMMY:TOKEN/getUpdates"))
        #expect(StubURLProtocol.lastRequest?.httpMethod == "GET")
    }

    @Test func sendMessageProducesCorrectRequestBody() async throws {
        let c = client(returning: #"{"ok":true,"result":{"message_id":5,"chat":{"id":111,"type":"private"},"date":1700000000}}"#)
        try await c.sendMessage(chatID: 111, text: "hi")

        let req = try #require(StubURLProtocol.lastRequest)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.path.contains("/botDUMMY:TOKEN/sendMessage") == true)

        let body = try #require(StubURLProtocol.lastBody)
        let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(obj?["chat_id"] as? Int == 111)
        #expect(obj?["text"] as? String == "hi")
        #expect(obj?["parse_mode"] as? String == "MarkdownV2")
    }

    // MARK: offset math

    @Test func nextOffsetIsMaxUpdateIDPlusOne() {
        let updates = [
            Update(updateID: 10, message: nil),
            Update(updateID: 12, message: nil),
            Update(updateID: 11, message: nil),
        ]
        #expect(Update.nextOffset(after: updates) == 13)
    }

    @Test func nextOffsetIsNilForEmptyBatch() {
        #expect(Update.nextOffset(after: []) == nil)
    }

    // MARK: MarkdownV2 escaping

    @Test func markdownV2EscapesEverySpecialCharacter() {
        let specials = "_*[]()~`>#+-=|{}.!"
        // Each special character is prefixed with exactly one backslash.
        for character in specials {
            #expect(MarkdownV2.escape(String(character)) == "\\" + String(character))
        }
        // A full run escapes each one once → output is exactly twice as long.
        #expect(MarkdownV2.escape(specials).count == specials.count * 2)
        // Non-special characters pass through untouched.
        #expect(MarkdownV2.escape("a.b") == "a\\.b")
        #expect(MarkdownV2.escape("plain text 123") == "plain text 123")
    }
}
