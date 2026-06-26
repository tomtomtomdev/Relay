//
//  OutputPipelineTests.swift
//  RelayTests
//
//  Slice 5 — the output transforms (SPEC §4, §5). Everything here is pure or a
//  value-type reducer with an injected clock, so every case is a plain value-in/
//  value-out assertion — no actors, no real timers, no waiting.
//

import Testing
import Foundation
@testable import Relay

// MARK: - ANSI / control stripping

struct ANSIStripperTests {

    @Test func stripsCSIColorCodes() {
        #expect(ANSIStripper.strip("\u{1B}[1;32mhello\u{1B}[0m") == "hello")
    }

    @Test func stripsCursorAndClearSequences() {
        #expect(ANSIStripper.strip("\u{1B}[2J\u{1B}[Hhi") == "hi")
    }

    @Test func stripsOSCTitleBELTerminated() {
        #expect(ANSIStripper.strip("\u{1B}]0;my title\u{07}done") == "done")
    }

    @Test func stripsOSCTitleSTTerminated() {
        #expect(ANSIStripper.strip("\u{1B}]0;t\u{1B}\\done") == "done")
    }

    @Test func stripsCharsetDesignation() {
        #expect(ANSIStripper.strip("\u{1B}(Btext") == "text")
    }

    @Test func normalizesCRLFToLF() {
        #expect(ANSIStripper.strip("a\r\nb") == "a\nb")
    }

    @Test func carriageReturnOverwritesCurrentLine() {
        // A lone CR resets the current line — progress bars collapse to their last state.
        #expect(ANSIStripper.strip("loading 10%\rloading 100%") == "loading 100%")
        #expect(ANSIStripper.strip("100%\rdone\nnext") == "done\nnext")
    }

    @Test func dropsStrayControlBytesButKeepsTabAndNewline() {
        #expect(ANSIStripper.strip("a\u{07}b") == "ab")        // BEL dropped
        #expect(ANSIStripper.strip("a\tb\nc") == "a\tb\nc")    // tab + newline kept
        #expect(ANSIStripper.strip("a\u{7F}b") == "ab")        // DEL dropped
    }

    @Test func passesThroughPlainText() {
        #expect(ANSIStripper.strip("just text 123") == "just text 123")
        #expect(ANSIStripper.strip("") == "")
    }
}

// MARK: - Chunking

struct OutputChunkerTests {

    @Test func shortTextIsASingleChunk() {
        #expect(OutputChunker.chunk("hello", maxChars: 4000) == ["hello"])
    }

    @Test func emptyTextProducesNoChunks() {
        #expect(OutputChunker.chunk("", maxChars: 4000).isEmpty)
    }

    @Test func breaksAtLineBoundariesAndNeverSplitsAFittingLine() {
        // Each "lineN\n" is 6 chars; with maxChars 10 only one line fits per chunk.
        let text = "line1\nline2\nline3\n"
        let chunks = OutputChunker.chunk(text, maxChars: 10)
        #expect(chunks == ["line1\n", "line2\n", "line3\n"])
        for c in chunks { #expect(c.count <= 10) }
        #expect(chunks.joined() == text)   // nothing dropped, order preserved
    }

    @Test func hardSplitsASingleOverlongLine() {
        let chunks = OutputChunker.chunk("abcdefghij", maxChars: 5)
        #expect(chunks == ["abcde", "fghij"])
        for c in chunks { #expect(c.count <= 5) }
        #expect(chunks.joined() == "abcdefghij")
    }

    @Test func oversizedMixedInputChunksCorrectlyWithoutDropping() {
        let line = String(repeating: "x", count: 100) + "\n"
        let text = String(repeating: line, count: 100)   // 10_100 chars
        let chunks = OutputChunker.chunk(text, maxChars: 4000)
        for c in chunks { #expect(c.count <= 4000) }
        #expect(chunks.joined() == text)                 // reconstructs exactly
        #expect(chunks.count >= 3)
    }
}

// MARK: - Hard-cap truncation (last resort, always announced)

struct OutputCapTests {

    @Test func underCapIsUnchangedWithNoMarker() {
        let text = "1\n2\n3"
        #expect(OutputCap.capTail(text, maxChars: 100) == text)
    }

    @Test func overCapDropsOldestLinesKeepsTailAndAnnounces() {
        let text = (1...20).map(String.init).joined(separator: "\n")   // "1\n2\n...\n20"
        // 40 leaves room for the ~22-char marker plus a few recent lines (the real hard
        // cap is thousands of chars; the marker always fits comfortably there).
        let capped = OutputCap.capTail(text, maxChars: 40)
        #expect(capped.count <= 40)
        #expect(capped.contains("truncated"))         // never silent
        #expect(capped.hasPrefix("…(truncated"))      // marker leads the surviving tail
        #expect(capped.hasSuffix("20"))               // most-recent output retained
        #expect(!capped.contains("\n2\n"))            // an early line ("2") was dropped
    }
}

// MARK: - MarkdownV2 <pre> wrapper

struct MarkdownV2PreBlockTests {

    @Test func wrapsInTripleBacktickFences() {
        #expect(MarkdownV2.preBlock("hello") == "```\nhello\n```")
    }

    @Test func escapesOnlyBacktickAndBackslashInsideTheBlock() {
        let out = MarkdownV2.preBlock("a`b\\c")
        #expect(out == "```\na\\`b\\\\c\n```")
    }

    @Test func doesNotOverEscapeNormalSpecialsLikeDotAndDash() {
        // Inside a code block `.` `-` `(` etc. are literal — unlike MarkdownV2.escape.
        let out = MarkdownV2.preBlock("a.b-c(d)")
        #expect(out == "```\na.b-c(d)\n```")
        #expect(!out.contains("\\."))
    }
}

// MARK: - Debounce buffer (coalesces bursts; injected clock)

struct DebounceBufferTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // `#expect` captures its expression in an autoclosure where the value is immutable,
    // so mutating calls (`append`, `flushIfIdle`, …) run on their own lines first.
    @Test func burstsWithinIdleWindowCoalesceIntoOneFlush() {
        var buf = DebounceBuffer(idleInterval: 0.3, fillThreshold: 4000)
        let a = buf.append("foo", now: t0)
        let b = buf.append("bar", now: t0.addingTimeInterval(0.1))
        #expect(a == nil)
        #expect(b == nil)
        // Before the idle deadline: nothing yet.
        let early = buf.flushIfIdle(now: t0.addingTimeInterval(0.2))
        #expect(early == nil)
        // At/after the deadline (lastAppend + idle = t0+0.1+0.3): one coalesced flush.
        let due = buf.flushIfIdle(now: t0.addingTimeInterval(0.4))
        #expect(due == "foobar")
        #expect(buf.isEmpty)
    }

    @Test func deadlineTracksLastAppend() {
        var buf = DebounceBuffer(idleInterval: 0.3, fillThreshold: 4000)
        #expect(buf.deadline == nil)
        _ = buf.append("x", now: t0)
        #expect(buf.deadline == t0.addingTimeInterval(0.3))
    }

    @Test func fillThresholdFlushesImmediatelyOnAppend() {
        var buf = DebounceBuffer(idleInterval: 0.3, fillThreshold: 5)
        let under = buf.append("abc", now: t0)
        let over = buf.append("defg", now: t0.addingTimeInterval(0.1))
        #expect(under == nil)
        #expect(over == "abcdefg")
        #expect(buf.isEmpty)
    }

    @Test func flushTakesEverythingAndEmptyFlushIsNil() {
        var buf = DebounceBuffer(idleInterval: 0.3, fillThreshold: 4000)
        let emptyFlush = buf.flush()
        _ = buf.append("tail", now: t0)
        let tailFlush = buf.flush()
        let afterFlush = buf.flush()
        #expect(emptyFlush == nil)
        #expect(tailFlush == "tail")
        #expect(afterFlush == nil)
        #expect(buf.isEmpty)
    }
}

// MARK: - Token bucket (send-rate limiter; injected clock)

struct TokenBucketTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // Mutating calls run on their own lines — `#expect`'s autoclosure is immutable.
    @Test func startsFullThenRateLimits() {
        var bucket = TokenBucket(capacity: 2, refillPerSecond: 1, now: t0)
        let first = bucket.tryConsume(now: t0)         // 2 → 1
        let second = bucket.tryConsume(now: t0)        // 1 → 0
        let third = bucket.tryConsume(now: t0)         // empty → rate-limited
        #expect(first)
        #expect(second)
        #expect(!third)
    }

    @Test func refillsOverTime() {
        var bucket = TokenBucket(capacity: 1, refillPerSecond: 1, now: t0)
        let spent = bucket.tryConsume(now: t0)         // 1 → 0
        let limited = bucket.tryConsume(now: t0)
        let refilled = bucket.tryConsume(now: t0.addingTimeInterval(1))
        #expect(spent)
        #expect(!limited)
        #expect(refilled)
    }

    @Test func nextAvailableIsNowWhenTokenPresentElseFuture() {
        var bucket = TokenBucket(capacity: 1, refillPerSecond: 1, now: t0)
        #expect(bucket.nextAvailable(now: t0) == t0)   // a token is ready
        let spent = bucket.tryConsume(now: t0)
        #expect(spent)
        #expect(bucket.nextAvailable(now: t0) == t0.addingTimeInterval(1))
    }
}

// MARK: - Pipeline composition (strip → chunk → wrap)

struct OutputPipelineTests {

    @Test func renderComposesStripChunkAndWrap() {
        let raw = "\u{1B}[32mhello\u{1B}[0m\nworld"
        let expected = OutputChunker.chunk(ANSIStripper.strip(raw)).map(MarkdownV2.preBlock)
        #expect(OutputPipeline.render(raw) == expected)
    }

    @Test func renderOfEmptyOrPureANSIProducesNoMessages() {
        #expect(OutputPipeline.render("").isEmpty)
        #expect(OutputPipeline.render("\u{1B}[2J\u{1B}[H").isEmpty)   // strips to nothing
    }

    @Test func renderOfOversizedOutputEmitsWrappedChunksAndDropsNothing() {
        let raw = String(repeating: "x", count: 9000)
        let messages = OutputPipeline.render(raw, maxChars: 4000)
        #expect(messages.count == 3)                         // 4000 + 4000 + 1000
        for m in messages {
            #expect(m.hasPrefix("```\n"))
            #expect(m.hasSuffix("\n```"))
        }
    }
}
