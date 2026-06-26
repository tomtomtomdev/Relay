//
//  OutputPipeline.swift
//  Relay
//
//  Slice 5 — turning raw PTY bytes into Telegram-ready messages (SPEC §4, §5).
//
//  The transforms are pure and the two stateful bits (debounce buffer, send-rate token
//  bucket) are value-type reducers that take an injected `now` — no real timers, no
//  actor. That keeps every rule deterministic and unit-tested here; the OS timer that
//  fires the idle flush and the send loop that drains the bucket are wiring concerns,
//  composed in Slice 6 (wire-through) on top of these pieces.
//
//  Pipeline shape (per flush):  raw → strip ANSI/control → chunk ≤N (line-preferring)
//                                   → wrap each chunk as a MarkdownV2 <pre> block.
//  Backpressure (SPEC §5): bursts coalesce in the DebounceBuffer; the TokenBucket paces
//  sends; overflow is coalesced, never dropped — `OutputCap` adds a `…(truncated N
//  lines)` marker only as a last resort at the hard cap.
//

import Foundation

// MARK: - ANSI / control stripping

/// Strips ANSI escape sequences and stray control bytes from raw PTY output, leaving
/// readable text. Pure and `nonisolated`.
nonisolated enum ANSIStripper {

    /// Remove ANSI escape sequences (CSI / OSC / charset / 2-byte), collapse carriage
    /// returns (lone `\r` overwrites the current line, `\r\n` becomes `\n`), and drop
    /// other C0 control characters and DEL — keeping only `\n` and `\t`.
    static func strip(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        let n = scalars.count
        let esc: Unicode.Scalar = "\u{1B}"   // ESC
        let bel: Unicode.Scalar = "\u{07}"   // BEL (OSC terminator)

        var out = String.UnicodeScalarView()
        out.reserveCapacity(scalars.count)
        var line = String.UnicodeScalarView()   // current line, subject to `\r` overwrite

        func commitLine() {
            out.append(contentsOf: line)
            line.removeAll(keepingCapacity: true)
        }

        var i = 0
        while i < n {
            let s = scalars[i]

            if s == esc {
                let next = i + 1 < n ? scalars[i + 1] : nil
                switch next {
                case "[":   // CSI: ESC [ params… final(0x40–0x7E)
                    i += 2
                    while i < n {
                        let final = scalars[i]; i += 1
                        if (0x40...0x7E).contains(final.value) { break }
                    }
                case "]":   // OSC: ESC ] … terminated by BEL or ST (ESC \)
                    i += 2
                    while i < n {
                        if scalars[i] == bel { i += 1; break }
                        if scalars[i] == esc, i + 1 < n, scalars[i + 1] == "\\" { i += 2; break }
                        i += 1
                    }
                default:    // 2-byte (ESC X) or charset designation (ESC ( B, ESC # 8…)
                    i += 2
                    if let nb = next, "()*+-./#%".unicodeScalars.contains(nb), i < n {
                        i += 1   // consume the charset final byte too
                    }
                }
                continue
            }

            if s == "\n" {
                commitLine()
                out.append("\n")
                i += 1
                continue
            }

            if s == "\r" {
                if i + 1 < n, scalars[i + 1] == "\n" {
                    i += 1            // CRLF → the following `\n` commits the line
                } else {
                    line.removeAll(keepingCapacity: true)   // carriage return overwrites
                    i += 1
                }
                continue
            }

            // Drop other C0 controls and DEL; keep printable scalars and `\t`.
            if (s.value < 0x20 && s != "\t") || s.value == 0x7F {
                i += 1
                continue
            }

            line.append(s)
            i += 1
        }
        commitLine()
        return String(out)
    }
}

// MARK: - Chunking

/// Splits clean text into Telegram-sized chunks, preferring line boundaries and never
/// dropping content. Pure and `nonisolated`.
nonisolated enum OutputChunker {

    /// Break `text` into chunks each at most `maxChars` characters. Whole lines are kept
    /// together where they fit; a single line longer than `maxChars` is hard-split. The
    /// concatenation of the result always reconstructs `text` exactly. Empty in → empty out.
    static func chunk(_ text: String, maxChars: Int = 4000) -> [String] {
        precondition(maxChars > 0, "maxChars must be positive")
        if text.isEmpty { return [] }

        var chunks: [String] = []
        var current = ""

        func flush() {
            if !current.isEmpty { chunks.append(current); current = "" }
        }

        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            // Restore the separator that `components(separatedBy:)` removed, except after
            // the final line (whose trailing newline, if any, is already its own "" entry).
            let piece = index < lines.count - 1 ? line + "\n" : line
            if piece.isEmpty { continue }

            if piece.count > maxChars {
                // The line alone overflows: emit the in-progress chunk, then hard-split it.
                flush()
                var rest = Substring(piece)
                while rest.count > maxChars {
                    let cut = rest.index(rest.startIndex, offsetBy: maxChars)
                    chunks.append(String(rest[..<cut]))
                    rest = rest[cut...]
                }
                current = String(rest)   // remainder (< maxChars) keeps accumulating
            } else if current.count + piece.count > maxChars {
                flush()
                current = piece
            } else {
                current += piece
            }
        }
        flush()
        return chunks
    }
}

// MARK: - Hard-cap truncation (last resort)

/// Bounds a coalesced flush at an absolute character cap. Pure and `nonisolated`.
nonisolated enum OutputCap {

    /// If `text` exceeds `maxChars`, drop the *oldest whole lines* until it fits and
    /// prepend a `…(truncated N lines)` marker. Keeps the most recent output (the part a
    /// terminal tail shows) and always announces the loss — truncation is never silent.
    /// Under the cap, `text` is returned unchanged.
    static func capTail(_ text: String, maxChars: Int) -> String {
        if text.count <= maxChars { return text }

        var lines = text.components(separatedBy: "\n")
        var dropped = 0
        while !lines.isEmpty {
            let marker = dropped > 0 ? "…(truncated \(dropped) lines)\n" : ""
            let candidate = marker + lines.joined(separator: "\n")
            if candidate.count <= maxChars { return candidate }
            if lines.count == 1 { break }   // can't drop further at line granularity
            lines.removeFirst()
            dropped += 1
        }

        // A single remaining line still overflows: keep its tail, still announce.
        let marker = "…(truncated \(dropped) lines)\n"
        let only = lines.first ?? ""
        let room = max(0, maxChars - marker.count)
        return marker + String(only.suffix(room))
    }
}

// MARK: - Debounce buffer (coalesces bursts)

/// Accumulates streamed output and releases it as one coalesced flush — on a ~300ms idle
/// gap or when the buffer fills. A pure value-type reducer: the caller passes `now` and
/// schedules the real idle timer (Slice 6) off `deadline`.
nonisolated struct DebounceBuffer: Equatable, Sendable {

    /// Idle gap after the last append before the buffer should flush.
    let idleInterval: TimeInterval
    /// Buffer size at which to flush immediately rather than wait for the idle gap.
    let fillThreshold: Int

    private(set) var buffer: String = ""
    private(set) var lastAppend: Date?

    init(idleInterval: TimeInterval = 0.3, fillThreshold: Int = 4000) {
        self.idleInterval = idleInterval
        self.fillThreshold = fillThreshold
    }

    var isEmpty: Bool { buffer.isEmpty }

    /// The idle-flush deadline (`lastAppend + idleInterval`), or `nil` when empty.
    var deadline: Date? {
        guard !buffer.isEmpty, let lastAppend else { return nil }
        return lastAppend.addingTimeInterval(idleInterval)
    }

    /// Append `text`. Returns the coalesced buffer to flush immediately if this reached
    /// the fill threshold; otherwise `nil` — the idle timer governs that flush.
    mutating func append(_ text: String, now: Date) -> String? {
        buffer += text
        lastAppend = now
        return buffer.count >= fillThreshold ? takeAll() : nil
    }

    /// Flush the coalesced buffer if the idle interval has elapsed since the last append.
    mutating func flushIfIdle(now: Date) -> String? {
        guard let deadline, now >= deadline else { return nil }
        return takeAll()
    }

    /// Unconditionally take and clear the buffer (e.g. on session end). `nil` if empty.
    mutating func flush() -> String? {
        buffer.isEmpty ? nil : takeAll()
    }

    private mutating func takeAll() -> String {
        defer { buffer = ""; lastAppend = nil }
        return buffer
    }
}

// MARK: - Token bucket (send-rate limiter)

/// Paces outgoing sends so the bridge stays under Telegram's ~1 msg/s/chat comfort zone.
/// A pure value-type reducer with an injected clock; rate-limited output is *coalesced*
/// upstream by the `DebounceBuffer`, never dropped here.
nonisolated struct TokenBucket: Equatable, Sendable {

    let capacity: Double
    let refillPerSecond: Double
    private(set) var tokens: Double
    private(set) var lastRefill: Date

    init(capacity: Double = 1, refillPerSecond: Double = 1, now: Date) {
        self.capacity = capacity
        self.refillPerSecond = refillPerSecond
        self.tokens = capacity
        self.lastRefill = now
    }

    /// Try to spend one token at `now` (refilling for elapsed time first). `true` → a send
    /// is allowed; `false` → rate-limited, so the caller waits until `nextAvailable` and
    /// coalesces in the meantime.
    mutating func tryConsume(now: Date) -> Bool {
        refill(now: now)
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }

    /// When the next token becomes available — `now` if one already is.
    func nextAvailable(now: Date) -> Date {
        let available = replenished(now: now)
        guard available < 1 else { return now }
        return now.addingTimeInterval((1 - available) / refillPerSecond)
    }

    private func replenished(now: Date) -> Double {
        let elapsed = max(0, now.timeIntervalSince(lastRefill))
        return min(capacity, tokens + elapsed * refillPerSecond)
    }

    private mutating func refill(now: Date) {
        tokens = replenished(now: now)
        lastRefill = now
    }
}

// MARK: - Pipeline composition

/// The always-on output transform: clean text → wrapped, chunked MarkdownV2 messages
/// ready for `TelegramClient.sendMessage`. Stateless and pure; the stateful debounce and
/// rate-limit reducers above feed it. `OutputCap` is applied separately by the caller as
/// a last resort, so `render` itself never drops content.
nonisolated enum OutputPipeline {

    /// Strip ANSI/control from `raw`, chunk it (line-preferring) at `maxChars`, and wrap
    /// each chunk as a MarkdownV2 `<pre>` block. Output that strips to nothing yields no
    /// messages (no empty `<pre>` blocks sent).
    static func render(_ raw: String, maxChars: Int = 4000) -> [String] {
        let clean = ANSIStripper.strip(raw)
        if clean.isEmpty { return [] }
        return OutputChunker.chunk(clean, maxChars: maxChars).map(MarkdownV2.preBlock)
    }
}
