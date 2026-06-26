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

    /// Wrap `text` as a MarkdownV2 pre-formatted block (the `<pre>` equivalent) — how the
    /// output pipeline (Slice 5) ships PTY output. Inside a code block only `` ` `` and
    /// `\` are special, so escape *just those*; running the full `escape(_:)` here would
    /// litter the rendered terminal text with stray backslashes.
    static func preBlock(_ text: String) -> String {
        var inner = ""
        inner.reserveCapacity(text.count)
        for character in text {
            if character == "`" || character == "\\" {
                inner.append("\\")
            }
            inner.append(character)
        }
        return "```\n" + inner + "\n```"
    }
}
