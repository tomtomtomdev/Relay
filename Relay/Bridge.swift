//
//  Bridge.swift
//  Relay
//
//  Slice 6 — the wire-through (SPEC §4). This is where the security spine goes LIVE:
//  the previously-isolated pieces are composed into one running pipeline.
//
//      TelegramClient.getUpdates ─▶ Authorizer (3 gates) ─▶ SessionManager (PTY)
//                                                               │ raw bytes
//                                                               ▼
//      TelegramClient.sendMessage ◀── OutputPipeline (strip · debounce · chunk · <pre>)
//
//  Two flows run as cancellable tasks on this actor:
//    · ingest  — long-poll updates, authorize each, dispatch the `Decision`. Only here
//      does `Authorizer.forward` reach `SessionManager.send` (the guardrail's "after the
//      spine's tests pass" wiring). Control replies (locked/unlock/deny/confirm) are sent
//      back as MarkdownV2-escaped text.
//    · output  — decode PTY bytes (handling UTF-8 split across reads), coalesce in the
//      `DebounceBuffer`, and a paced drain renders + sends, applying `OutputCap` only at
//      the hard ceiling. The token bucket keeps the send rate under Telegram's comfort
//      zone (PTY output only; low-volume control replies go out inline).
//
//  The secret/token never appear here: replies come from the Authorizer's fixed strings,
//  forwarded input is the operator's own text, and errors are swallowed (never logged).
//

import Foundation

/// Composes the Telegram ⇄ PTY bridge and owns the running session state. An `actor`
/// because it coordinates concurrent ingest/output tasks over mutable session state.
actor Bridge {

    private let config: BotConfig
    private let policy: Policy
    private let telegram: TelegramClient
    private let session: SessionManager
    private let authorizer: Authorizer

    // Output backpressure knobs (SPEC §5). Defaults mirror the Slice-5 reducers.
    private let pollTimeout: Int
    private let maxChunkChars: Int
    /// Absolute ceiling for one coalesced flush; `OutputCap` trims older lines past it.
    private let hardCapChars: Int
    /// Upper bound on how long the drain loop sleeps between checks.
    private let drainTick: TimeInterval

    // Live session state — mutated only by `handle(_:)`, read by the drain loop.
    private var state = SessionState.initial
    /// The chat PTY output is routed to: the operator's chat, learned from their first
    /// authorized message. `nil` until then, so pre-authorization output goes nowhere.
    private var outputChatID: Int64?

    private var debounce: DebounceBuffer
    private var bucket: TokenBucket
    private var decoder = UTF8StreamDecoder()
    /// Rendered `<pre>` messages awaiting a send slot (paced by `bucket`).
    private var pendingOutput: [String] = []

    private var ingestTask: Task<Void, Never>?
    private var outputTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?
    private var started = false

    init(
        config: BotConfig,
        policy: Policy,
        telegram: TelegramClient,
        session: SessionManager,
        authorizer: Authorizer = Authorizer(),
        pollTimeout: Int = 30,
        idleFlush: TimeInterval = 0.3,
        fillThreshold: Int = 4000,
        maxChunkChars: Int = 4000,
        hardCapChars: Int = 16_000,
        drainTick: TimeInterval = 0.1
    ) {
        self.config = config
        self.policy = policy
        self.telegram = telegram
        self.session = session
        self.authorizer = authorizer
        self.pollTimeout = pollTimeout
        self.maxChunkChars = maxChunkChars
        self.hardCapChars = hardCapChars
        self.drainTick = drainTick
        self.debounce = DebounceBuffer(idleInterval: idleFlush, fillThreshold: fillThreshold)
        self.bucket = TokenBucket(now: Date())
    }

    /// Identity-gate drops so far — a metric for tests/UI; never surfaced to any chat.
    var droppedCount: Int { state.droppedCount }

    // MARK: - Lifecycle

    /// Launch the PTY and start the ingest + output + drain loops. Idempotent.
    func start() async throws {
        guard !started else { return }
        started = true

        try await session.start()
        bucket = TokenBucket(now: Date())   // full bucket at session start

        let stream = session.output
        outputTask = Task { [weak self] in
            for await chunk in stream {
                await self?.onOutputChunk(chunk)
            }
        }
        drainTask = Task { [weak self] in await self?.drainLoop() }
        ingestTask = Task { [weak self] in await self?.ingestLoop() }
    }

    /// Stop everything and tear the session down. Awaits loop completion so a stopped
    /// bridge leaves no task still polling shared stubs (test hygiene) or the live PTY.
    func stop() async {
        ingestTask?.cancel()
        drainTask?.cancel()
        outputTask?.cancel()

        await session.stop()
        await session.waitUntilExited()   // finishes `output`, ending the outputTask loop

        await ingestTask?.value
        await drainTask?.value
        await outputTask?.value
        ingestTask = nil
        drainTask = nil
        outputTask = nil
    }

    // MARK: - Ingest: updates → gates → action

    private func ingestLoop() async {
        var offset: Int64?
        while !Task.isCancelled {
            do {
                let updates = try await telegram.getUpdates(offset: offset, timeout: pollTimeout)
                for update in updates {
                    if Task.isCancelled { return }
                    await handle(update)
                }
                // Advance only after the whole batch is handled.
                if let next = Update.nextOffset(after: updates) { offset = next }
            } catch {
                // Transient transport/API error — back off and retry. Never log: an error
                // could otherwise carry request context. The token is not in the error.
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// Run one update through the three gates and act on the `Decision`.
    private func handle(_ update: Update) async {
        let outcome = authorizer.authorize(
            update, state: state, config: config, policy: policy, now: Date()
        )
        state = outcome.state
        let chatID = update.message?.chat.id

        switch outcome.decision {
        case .drop:
            // Hostile/unknown chat: do nothing, send nothing (counter already bumped).
            break

        case .reply(let text), .needsConfirm(let text):
            // Fixed control text — escaped as MarkdownV2, not wrapped as a code block.
            guard let chatID else { return }
            outputChatID = chatID
            try? await telegram.sendMessage(chatID: chatID, text: MarkdownV2.escape(text))

        case .forward(let input):
            // The spine cleared all three gates: this is the only path to the PTY.
            if let chatID { outputChatID = chatID }
            await session.send(input)
        }
    }

    // MARK: - Output: PTY bytes → debounce → paced, chunked <pre> sends

    /// One raw PTY read. Decode (carrying any partial trailing UTF-8 sequence forward),
    /// then coalesce; a fill-threshold hit renders immediately, otherwise the drain loop
    /// flushes on the idle deadline.
    private func onOutputChunk(_ data: Data) {
        let text = decoder.decode(data)
        if text.isEmpty { return }
        if let filled = debounce.append(text, now: Date()) {
            enqueueRendered(filled)
        }
    }

    private func drainLoop() async {
        while !Task.isCancelled {
            if let flushed = debounce.flushIfIdle(now: Date()) {
                enqueueRendered(flushed)
            }
            await drainPending()

            // Sleep until the next thing that could need doing: the idle-flush deadline,
            // the next available send token (only if there's something to send), or the
            // tick cap (so newly-arrived output is noticed promptly).
            let now = Date()
            var wake = now.addingTimeInterval(drainTick)
            if let deadline = debounce.deadline { wake = min(wake, deadline) }
            if !pendingOutput.isEmpty, outputChatID != nil {
                wake = min(wake, bucket.nextAvailable(now: now))
            }
            let interval = max(0.01, wake.timeIntervalSince(now))
            try? await Task.sleep(for: .seconds(interval))
        }
    }

    /// Strip ANSI/control, trim to the hard cap (announced), chunk on line boundaries,
    /// and wrap each chunk as a MarkdownV2 `<pre>` block — ready to send. Never drops
    /// silently: `OutputCap` only acts past `hardCapChars`, and then with a marker.
    private func enqueueRendered(_ raw: String) {
        let clean = ANSIStripper.strip(raw)
        if clean.isEmpty { return }
        let capped = OutputCap.capTail(clean, maxChars: hardCapChars)
        let messages = OutputChunker.chunk(capped, maxChars: maxChunkChars).map(MarkdownV2.preBlock)
        pendingOutput.append(contentsOf: messages)
    }

    /// Send queued output while the token bucket allows it and a destination is known.
    private func drainPending() async {
        while !pendingOutput.isEmpty, let chatID = outputChatID {
            guard bucket.tryConsume(now: Date()) else { break }
            let message = pendingOutput.removeFirst()
            try? await telegram.sendMessage(chatID: chatID, text: message)
        }
    }
}

// MARK: - Incremental UTF-8 decoding

/// Decodes a stream of byte chunks into text without mangling multi-byte characters that
/// straddle a chunk boundary. A PTY read can split a UTF-8 sequence mid-character;
/// `String(decoding:as:)` on each chunk alone would emit replacement characters. This
/// holds back the incomplete trailing sequence until the bytes that complete it arrive.
///
/// Pure value-type reducer (no I/O); lives with the bridge that needs it. `nonisolated`
/// like the other transforms so its methods carry no actor isolation.
nonisolated struct UTF8StreamDecoder: Sendable {

    private var pending: [UInt8] = []

    /// Append `data` and return the text for every now-complete UTF-8 sequence, holding
    /// back any incomplete trailing bytes for the next call.
    mutating func decode(_ data: Data) -> String {
        pending.append(contentsOf: data)
        let holdback = Self.incompleteSuffixLength(pending)
        guard holdback < pending.count else { return "" }   // all bytes still incomplete

        let completeCount = pending.count - holdback
        let text = String(decoding: pending[0..<completeCount], as: UTF8.self)
        pending.removeFirst(completeCount)
        return text
    }

    /// Decode whatever bytes remain (e.g. at end-of-stream). Truly invalid trailing bytes
    /// become replacement characters rather than being silently dropped.
    mutating func flush() -> String {
        guard !pending.isEmpty else { return "" }
        let text = String(decoding: pending, as: UTF8.self)
        pending.removeAll()
        return text
    }

    /// How many trailing bytes begin a UTF-8 sequence that isn't complete yet. Returns 0
    /// when the buffer ends on a sequence boundary (or on bytes we can't interpret, which
    /// we let `String(decoding:)` resolve to replacement characters).
    private static func incompleteSuffixLength(_ bytes: [UInt8]) -> Int {
        // Walk back over continuation bytes (10xxxxxx) to the lead byte. A UTF-8 char is
        // at most 4 bytes, so at most 3 continuation bytes precede the lead.
        var continuationCount = 0
        var index = bytes.count - 1
        while index >= 0, bytes[index] & 0xC0 == 0x80, continuationCount < 3 {
            continuationCount += 1
            index -= 1
        }
        guard index >= 0 else { return 0 }   // only continuation bytes — not our problem

        let lead = bytes[index]
        let expected: Int
        if lead & 0x80 == 0 { expected = 1 }            // 0xxxxxxx
        else if lead & 0xE0 == 0xC0 { expected = 2 }    // 110xxxxx
        else if lead & 0xF0 == 0xE0 { expected = 3 }    // 1110xxxx
        else if lead & 0xF8 == 0xF0 { expected = 4 }    // 11110xxx
        else { return 0 }                               // invalid lead — let decode handle

        let have = continuationCount + 1
        return have < expected ? have : 0
    }
}
