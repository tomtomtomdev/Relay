//
//  TelegramModels.swift
//  Relay
//
//  Slice 2 — the slice of the Telegram Bot API we decode. Only the fields the bridge
//  needs (identity, chat, text) are modelled; everything else is ignored.
//
//  All `nonisolated` + `Sendable` so the Authorizer (pure) and actors can read them
//  without `@MainActor` hops.
//

import Foundation

nonisolated struct TelegramUser: Codable, Equatable, Sendable {
    let id: Int64
    let isBot: Bool
    let firstName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case isBot = "is_bot"
        case firstName = "first_name"
    }
}

nonisolated struct TelegramChat: Codable, Equatable, Sendable {
    let id: Int64
    let type: String
}

nonisolated struct TelegramMessage: Codable, Equatable, Sendable {
    let messageID: Int64
    let from: TelegramUser?
    let chat: TelegramChat
    let date: Int64
    let text: String?

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case from, chat, date, text
    }
}

nonisolated struct Update: Codable, Equatable, Sendable {
    let updateID: Int64
    let message: TelegramMessage?

    enum CodingKeys: String, CodingKey {
        case updateID = "update_id"
        case message
    }

    /// The offset to pass to the next `getUpdates`: one past the highest `update_id`
    /// in the batch, or `nil` for an empty batch (caller keeps its current offset).
    /// Advance only after a batch is fully handled (SPEC §4, skill: ingestion).
    static func nextOffset(after updates: [Update]) -> Int64? {
        updates.map(\.updateID).max().map { $0 + 1 }
    }
}

/// Telegram wraps every response in `{ ok, result, ... }`; on failure it sends
/// `ok:false` with an `error_code`/`description`. Generic over the `result` payload.
nonisolated struct TelegramResponse<Result: Decodable>: Decodable {
    let ok: Bool
    let result: Result?
    let description: String?
    let errorCode: Int?

    enum CodingKeys: String, CodingKey {
        case ok, result, description
        case errorCode = "error_code"
    }
}
