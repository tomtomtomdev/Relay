//
//  TelegramClient.swift
//  Relay
//
//  Slice 2 — long-poll ingestion + send, URLSession only, no Telegram SDK (SPEC §4).
//
//  The token sits in the request URL (that's how the Bot API authenticates) but is
//  never logged, never echoed, and never put in an error: `TelegramError` carries
//  only status codes and Telegram's own description text.
//

import Foundation

nonisolated enum TelegramError: Error, Equatable {
    /// Non-2xx HTTP status from the transport.
    case httpStatus(Int)
    /// Response wasn't an HTTP response at all.
    case invalidResponse
    /// `ok:false` body. Carries Telegram's own `error_code`/`description` (never a secret).
    case apiError(code: Int?, description: String?)
}

/// Owns all Telegram network I/O. `URLSession` is injected so tests drive it with a
/// `URLProtocol` stub and make zero live calls.
actor TelegramClient {
    private let token: String
    private let session: URLSession
    private let baseURL: URL

    init(token: String, session: URLSession, baseURL: URL = URL(string: "https://api.telegram.org")!) {
        self.token = token
        self.session = session
        self.baseURL = baseURL
    }

    /// One long-poll. `offset` is `nil` on first call, then `Update.nextOffset(after:)`
    /// of the previous batch once it's been handled. Returns the decoded updates.
    func getUpdates(offset: Int64?, timeout: Int = 30) async throws -> [Update] {
        var components = URLComponents(
            url: apiURL(method: "getUpdates"),
            resolvingAgainstBaseURL: false
        )!
        var query = [URLQueryItem(name: "timeout", value: String(timeout))]
        if let offset {
            query.append(URLQueryItem(name: "offset", value: String(offset)))
        }
        components.queryItems = query

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"

        return try await send(request, decoding: [Update].self)
    }

    /// Send a message to `chatID`. Text is forwarded as MarkdownV2 (callers escape via
    /// `MarkdownV2.escape` / wrap as `<pre>` upstream).
    func sendMessage(chatID: Int64, text: String) async throws {
        var request = URLRequest(url: apiURL(method: "sendMessage"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            SendMessageBody(chatID: chatID, text: text, parseMode: "MarkdownV2")
        )
        _ = try await send(request, decoding: TelegramMessage.self)
    }

    // MARK: - Internals

    /// Perform the request, validate the HTTP status, and decode `TelegramResponse<T>`.
    @discardableResult
    private func send<T: Decodable>(_ request: URLRequest, decoding: T.Type) async throws -> T {
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw TelegramError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TelegramError.httpStatus(http.statusCode)
        }

        let envelope = try JSONDecoder().decode(TelegramResponse<T>.self, from: data)
        guard envelope.ok, let result = envelope.result else {
            throw TelegramError.apiError(code: envelope.errorCode, description: envelope.description)
        }
        return result
    }

    private func apiURL(method: String) -> URL {
        baseURL
            .appendingPathComponent("bot\(token)")
            .appendingPathComponent(method)
    }
}

/// JSON body for `sendMessage`. Snake-case keys match the Bot API.
private nonisolated struct SendMessageBody: Encodable {
    let chatID: Int64
    let text: String
    let parseMode: String

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case text
        case parseMode = "parse_mode"
    }
}
