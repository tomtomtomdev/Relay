//
//  MarkdownV2.swift
//  Relay
//
//  Slice 2 — Telegram MarkdownV2 escaping. Pure, `nonisolated`. The output pipeline
//  (Slice 5) builds on this to wrap PTY output as a `<pre>` block.
//

import Foundation

nonisolated enum MarkdownV2 {

    /// Characters Telegram requires be backslash-escaped in MarkdownV2 text:
    /// `_ * [ ] ( ) ~ ` > # + - = | { } . !`
    private static let special: Set<Character> = [
        "_", "*", "[", "]", "(", ")", "~", "`", ">", "#",
        "+", "-", "=", "|", "{", "}", ".", "!",
    ]

    /// Backslash-escape every MarkdownV2 special character in `text`.
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            if special.contains(character) {
                out.append("\\")
            }
            out.append(character)
        }
        return out
    }
}
