# PROGRESS — Relay

Append one entry per completed slice. Newest at the bottom. This file is the source
of truth for resuming after a context clear — write it so a fresh session can pick up
with no other memory.

## Entry template

```
## Slice N — <title>   (YYYY-MM-DD)
- Status: complete | blocked
- What landed: <1–3 lines>
- Key files: <paths added/changed>
- Tests: <count> passing; covers <what>
- Decisions / deviations from PLAN: <none | …>
- Commit: <hash> "slice N: …"
- Next: Slice N+1 — <title>. Watch out for: <gotcha if any>
```

---

## Slice 0 — Skeleton menu-bar app   (2026-06-26)
- Status: complete
- What landed: `MenuBarExtra` app with `LSUIElement = YES` (menu-bar resident, no Dock
  icon, window-close ≠ quit). Status glyph driven by a pure `AppStatus` model; dropdown
  shows status + Quit. Removed the Xcode `ContentView` template.
- Key files: `Relay/AppStatus.swift` (new), `Relay/RelayMenu.swift` (new),
  `Relay/RelayApp.swift` (now `MenuBarExtra`), `Relay/ContentView.swift` (deleted),
  `RelayTests/RelayTests.swift` (AppStatusTests), `Relay.xcodeproj/project.pbxproj`.
- Tests: 4 unit tests passing (`AppStatusTests`) — covers the four SPEC §4 states,
  non-empty + distinct glyphs, non-empty labels. UI launch tests also green.
- Decisions / deviations from PLAN: none. `AppStatus` is `Sendable`/`@MainActor`-free
  per the strict-concurrency guardrail so later actors can read it without isolation hops.
- Commit: see `git log --grep "slice 0:"` (committed this slice).
- Next: Slice 1 — Config model + Keychain. Watch out for: secrets must never appear in
  any `description`/log helper; `KeychainStore` needs an injectable service name so tests
  hit a test keychain, never the login keychain.

## Slice 1 — Config model + Keychain   (2026-06-26)
- Status: complete
- What landed: `BotConfig` (token, allowedIDs, pairingSecret, targetCommand,
  idleTimeout, policyPreset) — Codable, Equatable, Sendable, `nonisolated`. Secrets are
  *structurally* excluded from the Codable surface (omitted from `CodingKeys`) so they
  can never serialize to disk in plaintext; `description`/`debugDescription` redact them.
  `KeychainStore` (generic-password Security wrapper) with set/string(for:)/remove and an
  injectable `service` name as the test seam. `PolicyPreset` enum (`.strict`/`.standard`)
  is a persisted selector only — real gate logic is Slice 3.
- Key files: `Relay/BotConfig.swift` (new), `Relay/KeychainStore.swift` (new),
  `RelayTests/BotConfigTests.swift` (new), `RelayTests/KeychainStoreTests.swift` (new).
- Tests: 12 unit passing (8 new + 4 Slice-0 regression). New coverage: non-secret
  Codable round-trip; secrets never serialized (token/secret absent from JSON, decode
  yields empty); description/reflection redact secrets; Keychain write→read round-trip,
  missing-key→nil (no crash), overwrite/update, delete, delete-missing no-op.
- Decisions / deviations from PLAN: PLAN lists token+secret "in BotConfig … Codable".
  Resolved the tension with the SPEC §5 guardrail by keeping the fields on the type but
  excluding them from `Codable` (they default to `""` on decode) — security enforced by
  construction, not discipline. KeychainStore uses the default file-based keychain
  (no `kSecUseDataProtectionKeychain`); round-trips cleanly in the sandboxed,
  ad-hoc-signed test host (no DEVELOPMENT_TEAM, no -34018 entitlement error).
- Commit: 7303f28 "slice 1: BotConfig model + KeychainStore".
- Next: Slice 2 — TelegramClient (no live network). Watch out for: `actor` over an
  injected `URLSession`; tests must use a `URLProtocol` stub (zero live API calls);
  load the token from Keychain at call time and never log it; MarkdownV2 escaping of
  `_*[]()~`>#+-=|{}.!` and offset = last `update_id` + 1 only after handling.

## Slice 2 — TelegramClient (no live network)   (2026-06-26)
- Status: complete
- What landed: `actor TelegramClient` over an injected `URLSession` (token injected at
  init; default `baseURL` https://api.telegram.org). `getUpdates(offset:timeout:)` GET
  long poll → decodes `[Update]`; `sendMessage(chatID:text:)` POST JSON body with
  `parse_mode=MarkdownV2`. Telegram models (`Update`/`TelegramMessage`/`TelegramUser`/
  `TelegramChat`/`TelegramResponse<Result>`) decode only the fields the bridge needs.
  `Update.nextOffset(after:)` = max `update_id` + 1 (nil for empty batch).
  `MarkdownV2.escape` backslash-escapes the 18 special chars. `TelegramError`
  (httpStatus / invalidResponse / apiError) carries only status + Telegram description
  — never the token.
- Key files: `Relay/TelegramClient.swift`, `Relay/TelegramModels.swift`,
  `Relay/MarkdownV2.swift` (all new); `RelayTests/TelegramClientTests.swift`,
  `RelayTests/StubURLProtocol.swift` (new test infra).
- Tests: 19 unit passing (8 new + 11 prior). New: getUpdates parse, ok:false→throws,
  offset+timeout query shaping (GET, path `/bot<token>/getUpdates`), sendMessage body
  (`chat_id`/`text`/`parse_mode`, POST `/sendMessage`), nextOffset math (full + empty),
  MarkdownV2 escaping. All offline through `StubURLProtocol` — zero live API calls.
- Decisions / deviations from PLAN: none functionally. Token is injected into the
  client (Keychain→token wiring is the app's job, deferred to Slice 6/7) — the client
  just never logs it. `StubURLProtocol` holds canned response as Sendable primitives
  (Int status + Data body, `nonisolated(unsafe)` statics) and reads the POST body from
  `httpBodyStream` (URLSession streams it); suite is `@Suite(.serialized)` to avoid
  racing that static state under Swift Testing's parallel default. Gotcha hit: in a
  single-`#` raw string `\#` is the escape introducer, so an expected literal for the
  escaped `#` mis-parsed — rewrote the escaping test to assert the property directly.
- Commit: 763d261 "slice 2: TelegramClient over injected URLSession".
- Next: Slice 3 — Authorizer (the spine; heaviest tests in the repo). Watch out for:
  pure `(Update, SessionState, Policy, clock) -> Decision`, no I/O; inject the clock for
  idle/relock boundary tests; Gate 1 unauthorized → `.drop` silently (no reply, bump a
  counter — no oracle); Gate 2 `/unlock <secret>` compares the Keychain secret in
  constant time, idle/`/lock`/relaunch relock, wrong secret → one fixed reply; Gate 3
  denylist refuse + flagged → `.needsConfirm` then `/confirm` → `.forward`; secret never
  echoed. Reuse `BotConfig.pairingSecret`/`allowedIDs` and `Update` from Slices 1–2.

## Slice 3 — Authorizer (the spine)   (2026-06-26)
- Status: complete
- What landed: pure three-gate state machine. `Authorizer.authorize(update, state,
  config, policy, now) -> AuthorizerOutcome` (`.decision` + next `.state`); no I/O, no
  Keychain, no network — clock is the injected `now`. `Decision` = `.drop`/`.reply`/
  `.forward`/`.needsConfirm` (SPEC §4). `SessionState` = `Lock` (`.locked` /
  `.unlocked(until:)`) + `pendingConfirm` + `droppedCount`; `.initial` is locked
  (relaunch relock). Gate 1: `from.id` AND `chat.id` must be allow-listed else silent
  `.drop` + counter bump (no reply/oracle). Gate 2: `/unlock <secret>` constant-time
  compares `config.pairingSecret` (empty secret never unlocks), sets idle deadline
  `now + idleTimeout`; `/lock`, idle expiry (`now >= until`), and `.initial` relock;
  wrong secret → one fixed `unlockFailed` reply (never echoes the attempt). Gate 3:
  `Policy.screen` → `.denied` refuse / `.flagged` hold for `/confirm` then `.forward`
  the held input / `.clean` forward; activity refreshes the idle deadline. Command
  parser tolerates a `@botname` suffix and keeps the secret as the untouched remainder.
- Key files: `Relay/Authorizer.swift` (new — Decision/SessionState/AuthorizerOutcome/
  Authorizer + constant-time compare + private command parser), `Relay/Policy.swift`
  (new — `PolicyVerdict`, `Policy` regex denylist/flagged, `.strict`/`.standard`
  presets, `preset(_:)`); `RelayTests/AuthorizerTests.swift`,
  `RelayTests/PolicyTests.swift` (new).
- Tests: 45 unit passing (26 new + 19 prior). New Authorizer (19): identity drops
  (bad sender / bad chat / no message) + counter, authorized-not-dropped, locked fixed
  reply, correct-secret unlock + deadline, wrong/near-miss → identical fixed reply +
  stays locked, empty-secret never unlocks, `/lock` relock+clear-pending, idle relock
  boundary (just-before forwards / at-deadline relocks), activity refreshes deadline,
  clean forward, denylist refuse, flagged→`/confirm`→forward held input, confirm-with-
  nothing, confirm-while-locked, secret-never-echoed, constant-time exact-only. New
  Policy (7): clean pass-through, catastrophic denied, risky flagged, denied>flagged
  precedence, `/dev/null` benign (not denied), standard lenient vs strict, preset map.
- Decisions / deviations from PLAN: signature returns `AuthorizerOutcome` (decision +
  next state) rather than a bare `Decision` — keeps it a pure reducer so the state
  machine evolves without hidden mutation (PLAN's "(…)->Decision" honored in spirit;
  clock still injected, still I/O-free). Idle boundary defined as relocked when
  `now >= until` (deadline inclusive). `Policy` stores regex *pattern strings* (compiled
  per-match via `range(of:options:[.regularExpression,.caseInsensitive])`) so it stays
  `Sendable`/`Equatable`; denylist patterns are deliberately narrow (raw-disk writes
  match, `of=/dev/null` does not). `droppedCount` lives in `SessionState` (testable),
  not an app-level metric. Authorizer is `nonisolated`/`Sendable`, no `@MainActor`.
- Commit: b76fc26 "slice 3: Authorizer + Policy security spine".
- Next: Slice 4 — PTY session (`actor SessionManager`). Watch out for: the spine is now
  in place, so live message-input → PTY may be wired *after* Slice 4's tests pass (per
  guardrail). Open PTY via `posix_openpt`+`grantpt`/`unlockpt` or `forkpty` (a tiny C
  shim is allowed; not a third-party dep); spawn `zsh -l` first then the configured
  `claude`; write authorized input to master + `\n`; dedicated read loop merging
  stdout+stderr; detect child exit + respawn; assert no fd leak on teardown with a
  local echo process. `SessionManager` is an `actor`; do not wire `Authorizer.forward`
  into it live until Slice 6.

## Slice 4 — PTY session   (2026-06-26)
- Status: complete
- What landed: `actor SessionManager` owning one pseudo-terminal. PTY opened with
  `posix_openpt(O_RDWR|O_NOCTTY)` + `grantpt`/`unlockpt`/`ptsname` (all available from
  Darwin — **no C shim needed**); `Foundation.Process` runs the target on the slave fd
  (one `FileHandle` wired to stdin/stdout/stderr so the tty merges them like a real
  terminal). The parent keeps only the master fd. `start()` opens+launches; `send(_:)`
  writes text + `\n` to the master (the "enter" key); `stop()` terminates the child.
  A dedicated `Thread` read loop blocks on `read(master)` and yields `Data` chunks into
  an `AsyncStream<Data>` (`output`); on EOF (child exit → slave closed → EIO/0) the loop
  is the **sole closer** of the master fd, so there's no close-during-read race.
  `RespawnPolicy` `.never` (default) finishes the stream on exit; `.always` relaunches.
  Optional `bootstrap` line is typed in right after launch — realises "zsh -l first,
  then the configured claude command". `waitUntilExited()` awaits permanent teardown via
  parked `CheckedContinuation`s. `SessionError.openPTYFailed(code:)` carries only errno.
- Key files: `Relay/SessionManager.swift` (new); `RelayTests/SessionManagerTests.swift`
  (new). No `project.pbxproj` edit — `PBXFileSystemSynchronizedRootGroup` auto-includes
  files dropped into `Relay/` and `RelayTests/`.
- Tests: 51 unit passing (6 new + 45 prior) + UI launch tests. New (real short-lived
  local procs on a PTY, no network): `/bin/echo` output streams back; `/bin/cat` input
  round-trips (tty echo + cat); child-exit detected (`isRunning==false`); bootstrap line
  runs after launch; `.always` respawns (`launchCount>=2` for `/bin/sleep 0.1`); teardown
  leaks no fds (warm-up to absorb one-time Foundation/libdispatch fds, then 8× start/stop
  loop, `after <= baseline + 2`). Suite `.serialized` (fd test reads a process-global
  count). Test helpers race a `Task.sleep` timeout so a hung PTY can't stall the suite.
- Decisions / deviations from PLAN: chose `Foundation.Process` + manually opened PTY
  (the SPEC §4 alternative) over `forkpty`/C-shim — Darwin already exposes the posix_openpt
  family, so zero extra surface. PLAN's "(zsh -l first, then the configured claude)" is
  modelled as `command` (default `["/bin/zsh","-l"]`) + an optional `bootstrap` line, not
  a two-step exec. Master fd is closed only by the read loop on EOF (single owner) — `stop()`
  just `terminate()`s and lets EOF drive teardown, avoiding a cross-thread close race.
  fd-leak assertion allows +2 slack for transient libdispatch fds; the 8× loop makes a
  genuine per-iteration leak (≥8) stand out. No termination handler — Foundation's internal
  proc dispatch source reaps the child. Authorizer is **not** wired in (per guardrail; Slice 6).
- Commit: 8fdbbf1 "slice 4: PTY SessionManager actor over a pseudo-terminal".
- Next: Slice 5 — OutputPipeline (pure). Watch out for: ANSI/control stripping + chunker
  (≤4000, prefer line boundaries) + MarkdownV2 `<pre>` wrapper are pure functions (easy
  tests); the only stateful bits are a ~300ms idle / 4000-char debounce flush and a
  send-rate token bucket. Nothing dropped silently — `…(truncated N lines)` marker only
  at the hard cap. Feed it the `Data` chunks `SessionManager.output` already emits.

## Slice 5 — OutputPipeline   (2026-06-26)
- Status: complete
- What landed: the output transforms (SPEC §4/§5), all pure or value-type reducers with
  an injected clock — no actor, no real timers. `ANSIStripper.strip` removes CSI/OSC/
  charset/2-byte ESC sequences, collapses carriage returns (`\r\n`→`\n`; a lone `\r`
  overwrites the current line so progress bars don't concatenate), and drops other C0
  controls + DEL while keeping `\n`/`\t`. `OutputChunker.chunk(maxChars:4000)` breaks
  text at line boundaries, hard-splits an overlong single line, and reconstructs the
  input exactly (never drops; empty→[]). `OutputCap.capTail` is the last resort: over the
  cap it drops the *oldest whole lines* and prepends a `…(truncated N lines)` marker,
  keeping the recent tail — truncation is always announced. `MarkdownV2.preBlock` wraps a
  chunk as a `<pre>` code block escaping only `` ` `` and `\` (not the full text set).
  `DebounceBuffer` coalesces bursts (flush on ~0.3s idle via `deadline`, or immediately at
  a 4000-char fill); `TokenBucket` paces sends to ~1 msg/s. `OutputPipeline.render` =
  strip→chunk→wrap (stateless; never drops).
- Key files: `Relay/OutputPipeline.swift` (new — ANSIStripper / OutputChunker / OutputCap
  / DebounceBuffer / TokenBucket / OutputPipeline); `Relay/MarkdownV2.swift` (added
  `preBlock`); `RelayTests/OutputPipelineTests.swift` (new). No `project.pbxproj` edit —
  `PBXFileSystemSynchronizedRootGroup` auto-includes new files under `Relay/`/`RelayTests/`.
- Tests: 80 unit passing (29 new + 51 prior) + UI launch tests. New: ANSI CSI/OSC(BEL+ST)/
  charset stripping, CRLF + lone-CR line overwrite, control-drop keeping tab/newline,
  plain pass-through; chunk single/empty/line-boundary/hard-split/oversized-reconstructs;
  capTail under-cap unchanged + over-cap drops-oldest/keeps-tail/announces; preBlock fences
  + escapes-only-`` ` ``-and-`\` + does-not-over-escape; debounce coalesce/deadline/fill/
  flush; token-bucket full→limit→refill + nextAvailable; render compose/empty-or-pure-ANSI
  →[]/oversized-wrapped-no-drop.
- Decisions / deviations from PLAN: kept Slice 5 actor-free. SPEC calls OutputPipeline
  "pure-ish" with "the debounce timer is the only stateful bit", so the debounce *logic*
  is a pure `DebounceBuffer` reducer (clock injected, exposes `deadline`) and the actual
  OS `Timer` + send-drain loop is deferred to Slice 6 wire-through — no flaky timer tests.
  Truncation lives in a standalone `OutputCap.capTail` tested directly, NOT wired into
  `render`; render never drops, so "nothing dropped silently" holds by construction and
  the cap is the orchestrator's last-resort tool. Implemented carriage-return line-
  overwrite (not mere CR-drop) so progress output is genuinely clean. `preBlock` added to
  `MarkdownV2` (its header already anticipated it) rather than a new type. Chunk size is
  measured in Characters (graphemes) like `MarkdownV2.escape`; 4000 leaves headroom under
  Telegram's 4096 for the `<pre>` fences + in-block escaping. Swift Testing gotcha:
  `#expect` captures its expression in an immutable autoclosure, so mutating reducer calls
  (`append`/`tryConsume`/`flushIfIdle`) must run on their own line first, then assert the
  stored result.
- Commit: 0804ed5 "slice 5: OutputPipeline transforms + debounce/token-bucket reducers".
- Next: Slice 6 — Wire-through (integration). Watch out for: this is where the security
  spine goes LIVE — compose `TelegramClient(updates)`→`Authorizer`→`SessionManager`→
  `OutputPipeline`→`TelegramClient(send)`, wiring `Authorizer.forward`→`SessionManager.send`
  only after this slice's tests pass (guardrail). The OS idle timer fires off
  `DebounceBuffer.deadline`; the send loop drains via `TokenBucket.tryConsume` and applies
  `OutputCap.capTail` only at the hard cap. Decode `SessionManager.output` `Data`→`String`
  (handle partial UTF-8 across read chunks) before feeding the pipeline. Test with stubbed
  Telegram in/out (`StubURLProtocol`) + a real local PTY echo: send `/unlock` then a
  command, assert authorized output round-trips and an unauthorized chat is inert end-to-end.

## Slice 6 — Wire-through (integration)   (2026-06-27)
- Status: complete
- What landed: `actor Bridge` composes the whole pipeline and the spine goes **LIVE**.
  An ingest task long-polls `TelegramClient.getUpdates` (offset advanced only after a
  batch is fully handled), runs each `Update` through `Authorizer.authorize` carrying
  `SessionState` forward, and dispatches the `Decision`: `.drop` → nothing; `.reply`/
  `.needsConfirm` → `sendMessage` of `MarkdownV2.escape(text)` (control replies are
  escaped text, never a code block); `.forward` → `SessionManager.send` — **the only
  path to the PTY**, wired only now that the spine's tests pass (guardrail). An output
  task consumes `SessionManager.output`, decodes `Data`→`String` via a new
  `UTF8StreamDecoder` that holds back a UTF-8 sequence split across read chunks, and
  appends to a `DebounceBuffer`. A drain loop flushes on the idle `deadline` (or fill),
  renders (strip → `OutputCap.capTail` at a 16k hard ceiling → chunk → `preBlock`), and
  sends each `<pre>` chunk paced by `TokenBucket` (PTY output only; low-volume control
  replies bypass the bucket). Output routes to `outputChatID`, learned from the
  operator's first authorized message. `stop()` cancels the tasks and awaits their
  completion so a stopped bridge leaves nothing polling. Errors in the loops are
  swallowed, never logged (no token/secret can leak through an error).
- Key files: `Relay/Bridge.swift` (new — `Bridge` actor + `UTF8StreamDecoder`);
  `RelayTests/BridgeTests.swift`, `RelayTests/RoutingTelegramStub.swift` (new test infra:
  a path-routing `URLProtocol` that queues `getUpdates` batches FIFO and captures
  `sendMessage` chat-id+text). No `project.pbxproj` edit — `PBXFileSystemSynchronizedRootGroup`.
- Tests: 85 unit passing (5 new + 80 prior) + UI launch tests; 0 failures. New: `/unlock`
  then a command round-trips through a real `/bin/cat` PTY back to the operator chat as a
  `<pre>` block and the pairing secret is never echoed; an un-allow-listed chat is inert
  end-to-end (drop counted, zero sends, nothing reaches the PTY); an authorized-but-locked
  command gets exactly the fixed `lockedReply`, MarkdownV2-escaped; `UTF8StreamDecoder`
  reassembles a 3-byte char split across two chunks and a byte-at-a-time stream exactly.
  All offline (routing stub) + real local PTY — no live Telegram calls.
- Decisions / deviations from PLAN: introduced a `Bridge` orchestrator (the natural home
  for the composition the PLAN describes) rather than wiring directly into the App. Kept
  the Slice-5 reducers pure and added the impure timing here: a single drain loop that
  computes its sleep from `debounce.deadline` / `bucket.nextAvailable(_:)` (capped at a
  0.1s tick) realises "the OS idle timer fires off `DebounceBuffer.deadline`" without a
  flaky `Timer`. `OutputCap` is applied only past the 16k hard cap (well above the 4k
  chunk size) so normal output is never trimmed — render-path never drops. Control replies
  are sent inline (not through the bucket); the bucket paces the high-volume PTY stream
  only (SPEC §5 backpressure). `RoutingTelegramStub` holds empty `getUpdates` for ~50ms to
  mimic a held long poll so the ingest loop doesn't spin against an instant-empty stub
  (kept the Bridge free of test-only sleeps). `start()` is `async throws` (awaits the
  `SessionManager` actor). `UTF8StreamDecoder` is `nonisolated` like the other transforms
  so its methods carry no main-actor isolation under the repo's main-actor-by-default mode.
- Commit: 8a1275d "slice 6: live wire-through …".
- Next: Slice 7 — Menu-bar UI + settings. Watch out for: bind a settings form to
  `BotConfig` + Keychain (secrets stay in `KeychainStore`, never `@AppStorage`/plist);
  Start/Stop drives `Bridge.start()/stop()`; Lock/Unlock + status glyph reflect the
  bridge's `SessionState`/`AppStatus`; "Send test message" + a live tail of the last N
  output chunks. Keep the SwiftUI body thin and unit-test the view-model logic (status
  transitions, validation) — the `Bridge` already owns the live state to surface.

## Slice 7 — Menu-bar UI + settings   (2026-06-27)
- Status: complete
- What landed: an `@Observable` `AppModel` (the view-model) whose every state change
  funnels through one `apply(_ AppEvent)` reducer, so the status machine and validation
  are unit-testable with **no live Bridge/PTY/network**. `status` is a pure
  `AppStatus.derive(isRunning:isUnlocked:hasError:)` over the model's flags; `canStart`
  mirrors `BotConfig.validationIssues()`. `start()` builds the Bridge from the current
  settings (`zsh -l` + the target command as the Slice-4 bootstrap), wires its event
  stream into the reducer, and flips `runningChanged`; `stop()` tears it down and
  relocks. `SettingsStore` splits persistence: non-secret `BotConfig` → UserDefaults as
  JSON (secrets are absent from `Codable` by construction since Slice 1), token + pairing
  secret → Keychain only. `Bridge` gained a UI surface: a `let events: AsyncStream<
  BridgeEvent>` (`.unlockedChanged` / `.output`), host `lock()`/`unlock()`/
  `sendTestMessage()`, and `SessionState.isUnlocked`. SwiftUI stays thin — a `Settings`
  Form (token, pairing `SecureField`, allowed IDs, target command, idle timeout, policy
  picker, inline validation, Save), an enriched `RelayMenu` (Start/Stop, Lock/Unlock,
  Send Test Message, live tail of the last 5 chunks, Settings…, Quit), and the glyph
  bound to `model.status`.
- Key files: `Relay/AppModel.swift`, `Relay/ConfigSupport.swift` (ConfigIssue/
  validationIssues/isStartable/AllowedIDs/OutputTail/BotConfig.default), `Relay/
  SettingsStore.swift`, `Relay/SettingsView.swift` (all new); edits to `Relay/
  AppStatus.swift` (`derive`), `Relay/Authorizer.swift` (`SessionState.isUnlocked`),
  `Relay/Bridge.swift` (events + host controls), `Relay/RelayMenu.swift`, `Relay/
  RelayApp.swift` (AppModel + `Settings` scene). Tests: `RelayTests/SettingsLogicTests`,
  `SettingsStoreTests`, `AppModelTests` (new). No `project.pbxproj` edit.
- Tests: 116 Swift Testing unit cases passing (31 new + 85 prior) + 4 UI launch tests;
  0 failures. New: `AppStatus.derive` across all four states (error dominates); config
  validation per-field + whitespace token; `AllowedIDs` parse/format/round-trip; tail
  ring-buffer caps keeping the most recent; `SettingsStore` round-trips every field
  (secrets restored from Keychain via `==`) **and never writes a secret to UserDefaults**;
  `AppModel` loads settings on init, `canStart` mirrors validation, the reducer drives
  the glyph stopped→polling→unlocked→polling→stopped, stopping relocks, failure → error +
  message, clearError returns to the derived status, output events append to the tail.
- Decisions / deviations from PLAN: introduced `AppModel` + pure helpers and kept the
  SwiftUI body thin (the "view-model logic unit-tested" bar is met by the reducer + pure
  helpers, not by exercising SwiftUI). `SettingsStore` is `@MainActor` (not `Sendable`):
  it wraps `UserDefaults`, which isn't `Sendable` in Swift 6, and settings I/O is small +
  UI-adjacent, so it lives on the main actor with `AppModel` — both backing stores stay
  injectable (the Slice-1 test seam). Host-side `Lock`/`Unlock` are allowed because
  physical access to the Mac already implies trust (the threat model is about a leaked
  *token* driving a *remote* chat); `unlock()` is the host counterpart to Telegram
  `/unlock <secret>`. `SessionState.isUnlocked` ignores the idle deadline (the Authorizer
  enforces relock per-message); it only drives the cosmetic glyph. The live tail shows
  the ANSI-stripped, capped flush text (emitted from `enqueueRendered` before `<pre>`
  wrapping); menu lines are collapsed to one ≤60-char line. `start()` runs the target via
  `zsh -l` + bootstrap rather than parsing argv. Bridge event emission is additive and
  doesn't change Slice 6's asserted behaviour (events buffer unconsumed there).
- Commit: a4d25f4 "slice 7: menu-bar UI + settings …".
- Next: Slice 8 — Archive. Watch out for: `scripts/archive.sh` does `xcodebuild archive`
  → Developer ID export → `create-dmg` → `notarytool submit --wait` → staple (shelled
  out, never linked — zero-dep guardrail). The in-app "Build & Archive" trigger is an
  adapter over a **stub runner** so it's unit-testable; the script itself is dry-run/lint
  in CI. No live notarization in tests. Keep distribution/publish (Hangar) for Slice 9.

## Slice 8 — Archive   (2026-06-27)
- Status: complete
- What landed: the build→notarize pipeline as a shelled-out script plus a thin, fully
  stub-tested Swift adapter (PLAN Slice 8, SPEC §6). `scripts/archive.sh` runs
  `xcodebuild archive` → `xcodebuild -exportArchive` (Developer ID) → `create-dmg` →
  `xcrun notarytool submit --wait` → `xcrun stapler staple` — every tool **shelled out,
  never linked** (zero-dep guardrail). Notary credentials come only from a `notarytool`
  **keychain-profile name** (created out of band); the script never receives/prints a
  password or token. Contract with the app: the *only* stdout line on success is
  `RELAY_ARTIFACT=<abs path>.dmg` (all logs to stderr). `--dry-run` plans every stage and
  prints that line **without invoking any tool or doing side effects** (no mkdir/rm in
  dry-run), so it's safe + offline for CI. App side: `CommandRunner` protocol +
  `CommandResult` (the test seam), `ProcessCommandRunner` (real `Foundation.Process`,
  drains stdout/stderr concurrently via per-fd threads to avoid pipe-buffer deadlock —
  never exercised in tests), and `Archiver: ArchiveRunning` which checks the script exists,
  runs `/bin/bash <script> [--dry-run]`, maps exit≠0 → `ArchiveError.scriptFailed`
  (stderr, capped to 500 chars), parses `RELAY_ARTIFACT=` → `ArchiveOutcome(artifact,
  dryRun)`, else `.noArtifactProduced`. Wired into `AppModel` (`buildAndArchive(dryRun:)`,
  `isArchiving`/`lastArtifactURL`, two new `AppEvent`s) and a thin `RelayMenu` "Build &
  Archive…" item that surfaces the artifact name / a generic "Archive failed." message
  (never tool output verbatim).
- Key files: `Relay/Archiver.swift` (new), `scripts/archive.sh` (new, exec bit 100755);
  edits to `Relay/AppModel.swift` (archive wire) + `Relay/RelayMenu.swift` (menu item);
  `RelayTests/ArchiverTests.swift` + `RelayTests/ArchiveScriptTests.swift` (new), edits to
  `RelayTests/AppModelTests.swift`. No `project.pbxproj` edit — `PBXFileSystemSynchronized
  RootGroup` auto-includes new files under `Relay/`/`RelayTests/`; `scripts/` is not a
  build input (the script is data the adapter shells out to).
- Tests: 133 Swift Testing cases passing (0 failures) + 4 UI launch tests. New: Archiver
  over a `StubCommandRunner` — parses the artifact line, shells out as `/bin/bash <script>`,
  passes `--dry-run` (reflected in the outcome), exit≠0 → `.scriptFailed` carrying stderr,
  missing artifact line → `.noArtifactProduced`, missing script → throws *before* running,
  passes no secrets/extra args (`[script, --dry-run]` exactly). ArchiveScript runs the real
  committed script: exists, `bash -n` lints clean, `--dry-run` exits 0 + emits one
  `RELAY_ARTIFACT=…dmg` stdout line + plans all five stages (archive/export/create-dmg/
  notarytool/stapler) to stderr, and the source never inlines `--password`/`--apple-id`
  (only `--keychain-profile`). AppModel: `buildAndArchive` surfaces the artifact on success
  and a bounded error (no artifact) on failure, clearing `isArchiving` both ways.
- Decisions / deviations from PLAN: split the work cleanly — the real pipeline is the
  *script* (so the app links nothing new), and the Swift `Archiver` is a pure adapter over
  an injectable `CommandRunner`, so 100% of the app-side logic is stub-tested with zero
  live tooling (the "stub runner" mandate). The "script dry-run/lint in CI" deliverable is
  exercised *inside the xcodebuild suite* by `ArchiveScriptTests`, which locates the
  committed `scripts/archive.sh` via `#filePath` and runs `bash -n` + `--dry-run` through
  `Process` — works because the sandbox is **not enforced** in the `xcodebuild test` dev
  context (same reason Slice 4's PTY spawns succeed); if a future CI runs sandboxed those
  three script tests would need a bundled-resource copy instead. Made all new
  non-UI types `nonisolated` (the app target is main-actor-by-default, the *test* target is
  not — that asymmetry is why `AppModelTests` is `@MainActor` but `ArchiverTests` isn't;
  `nonisolated` lets the Sendable adapter construct from the nonisolated suite, matching the
  repo's "transforms are Sendable/@MainActor-free" guardrail). Errors surfaced to the UI are
  generic ("Archive failed.") — the script never prints secrets, but the adapter still caps
  stderr and the model never echoes tool output, so no secret can leak via an error path.
  `Archiver.defaultScriptURL` prefers a bundled `archive.sh` resource, else resolves
  `scripts/archive.sh` via `#filePath` (fine for a dev/CI build — archiving is dev-only by
  SPEC §6). Did NOT touch the unrelated `design_handoff_relay/` deletions in the worktree.
- Commit: dfc6bbe "slice 8: archive pipeline (script) + in-app adapter over a stub runner".
- Next: Slice 9 — Publish to Hangar. Watch out for: implement `HangarClient:
  DistributionService` (SPEC §6) against Hangar's contract field-for-field — direct
  multipart `< threshold`, presigned `PUT` + finalize `≥ threshold`; `ReleaseMetadata`/
  `PublishResult` JSON keys match exactly (`bundleId`, `releaseId`, `checksumSha256`, …).
  Token is **Keychain-only**, sent as `Bearer` at call time, never logged, never shipped in
  the tester binary. Test with a `URLProtocol` stub of Hangar only (never live-upload):
  multipart two-part body, presigned create→PUT(replay uploadHeaders)→finalize, and the
  401/403/409/413/415/422 → `HangarError` mapping. Reuse this slice's `Archiver` to produce
  the artifact, then publish; surface the returned `installURL`.

## Slice 9 — Publish to Hangar   (2026-06-27)
- Status: complete  ·  **final planned slice — the build pipeline now goes archive → publish.**
- What landed: the distribution layer (PLAN Slice 9, SPEC §6). `actor HangarClient:
  DistributionService` publishes a built artifact over an injected `URLSession` (no SDK).
  It picks the upload shape by artifact size vs an injected `multipartThreshold`:
  `< threshold` → **direct multipart** (one `POST /api/v1/releases`, two parts: `metadata`
  JSON + `artifact` octet-stream); `≥ threshold` → **presigned** (`POST …/releases` with
  JSON metadata + `sizeBytes` + `checksumSha256` → ticket `{releaseId, uploadUrl,
  uploadMethod, uploadHeaders, expiresIn}` → `PUT uploadUrl` replaying `uploadHeaders` →
  `POST …/releases/{id}/finalize` with `{checksumSha256}`). The API token is injected and
  sent only as `Authorization: Bearer <token>` at call time — never logged, and **never**
  attached to the third-party presigned-storage `PUT`. Hangar non-2xx + `{error:{code}}`
  bodies map to `HangarError` (401→invalidToken, 403→insufficientScope, 404→notFound,
  409→checksumMismatch|notFinalized by `code`, 413→tooLarge, 415→unsupportedArtifact,
  422→validation, else server/transport; unreadable artifact → `.artifactUnreadable`
  before any request). `ReleaseMetadata`/`PublishResult` mirror Hangar JSON field-for-field
  via `CodingKeys` (`bundleID`↔`bundleId`, `releaseID`↔`releaseId`, ISO-8601 `createdAt`);
  `ReleaseMetadata.from(infoDictionary:platform:channel:gitCommit:)` builds from a bundle's
  Info.plist. `ArtifactDigest.sha256Hex` is a **pure-Swift SHA-256** (stdlib only) for the
  artifact checksum. Wire-through: `AppModel.buildAndPublish()` archives (Slice 8) then
  publishes via an injected `DistributionService?`, surfacing `lastInstallURL`; a thin
  `RelayMenu` "Build & Publish…" item shows the install link with Copy + "Send to Chat"
  (`sendInstallLink()`, mirrors `sendTestMessage`).
- Key files: `Relay/DistributionService.swift` (new — protocol, `Platform`,
  `ReleaseMetadata` + factory, `PublishResult`, `HangarError`, `ArtifactDigest`),
  `Relay/HangarClient.swift` (new — the actor + private wire bodies); edits to
  `Relay/AppModel.swift` (publish events/state, `buildAndPublish`, `sendInstallLink`,
  `liveMetadata`/`gitCommit`) and `Relay/RelayMenu.swift` (menu item). Tests:
  `RelayTests/HangarStub.swift` + `RelayTests/HangarClientTests.swift` +
  `RelayTests/ReleaseMetadataTests.swift` (new), edits to `RelayTests/AppModelTests.swift`.
  No `project.pbxproj` edit — `PBXFileSystemSynchronizedRootGroup` auto-includes the new files.
- Tests: 154 Swift Testing cases passing (21 new + 133 prior) + 4 UI launch tests; 0
  failures; build clean (no warnings). New, all offline through `HangarStub` (a routing/
  FIFO `URLProtocol` that captures every request) + a real local artifact file — **no live
  upload**: multipart sends two parts + `Bearer` + Hangar-keyed metadata, 201 decodes to
  `PublishResult`; presigned does create→PUT→finalize (PUT body == file bytes, replays
  `uploadHeaders`, carries **no** `Authorization`; create sends `sizeBytes`+`checksumSha256`;
  finalize hits `…/{id}/finalize`); threshold boundary stays multipart; the 9 status→error
  mappings; missing artifact → `.artifactUnreadable` with zero requests; a thrown error
  never echoes the token; SHA-256 matches NIST vectors (`abc`, empty, 1000×`a`); metadata
  factory maps/omits keys and encodes Hangar JSON keys; `buildAndPublish` surfaces the
  install URL / a bounded failure / refuses with no publisher configured.
- Decisions / deviations from PLAN: **publishing is wired through a `DistributionService?`
  that is `nil` by default**, so the shipped/tester binary carries no publisher and "Build
  & Publish" reports "isn't configured" — this satisfies SPEC §6's "publisher token never
  shipped in the tester binary" *by construction*; a live `HangarClient` (base URL + a
  Keychain `Bearer` token) is a dev-build/CI injection, and no Hangar token field was added
  to the tester UI on purpose. **SHA-256 is hand-rolled in pure Swift rather than CryptoKit/
  CommonCrypto** — the guardrail enumerates stdlib/Foundation/AppKit/SwiftUI/Security only,
  and the digest here is an upload-integrity checksum (not a security primitive), so stdlib
  keeps the zero-extra-framework rule pristine; verified against known NIST vectors. Token
  injected at init like `TelegramClient` ("Bearer at call time" = only ever in the header,
  never logged). Presigned "create" flattens the metadata to the top level + `sizeBytes`/
  `checksumSha256` (custom `encode(to:)` merges the keyed containers) — the natural reading
  of SPEC's "JSON metadata + sizeBytes + checksumSha256". `JSONEncoder`/`JSONDecoder` are
  built per-use (not shared statics) because they aren't `Sendable` under Swift 6 (would be
  a warning = failure). All new non-UI types are `nonisolated`/`Sendable` (app target is
  main-actor-by-default; matches the repo's transforms-are-Sendable guardrail). Did NOT
  touch the unrelated `design_handoff_relay/` deletions in the worktree.
- Commit: dfd6618 "slice 9: HangarClient distribution + Build & Publish wire-through".
- Next: **PLAN complete** — Slices 0–9 all landed. No Slice 10. Remaining items live in
  PLAN's "Backlog / later" (named PTY sessions, inline keyboard buttons, file send,
  notification mirror) and are out of the original scope. To actually publish from a dev
  build, inject a configured `HangarClient(baseURL:token:session:)` into `AppModel`
  (token from `KeychainStore`) — the seam is in place.

## Slice 10 — Design foundation (tokens + components)   (2026-06-27)
- Status: complete  ·  **first slice of a new UI series (10–14)** that implements the
  `design_handoff_relay` design (functional backend was 0–9; the UI was a placeholder).
- What landed: the *pure* core of the design system + the SwiftUI bridge/components.
  `RGBA(hex:)` parses `#RRGGBB`/`RRGGBB`/`#RRGGBBAA` (nil on malformed). `PaletteToken`
  (semantic roles: surfaces/text/border/brand+status) resolves per `Appearance` via
  `RelayPalette.resolve(_:_:)` — two hex tables transcribed from the handoff "Design
  Tokens"; the terminal stays `#161618` in **both** appearances; brand/status accents are
  appearance-independent. `DotState` (connected/allowed/ready/warn/error/idle) → token.
  SwiftUI layer: `Color(_ token:, _ scheme:)` bridge (maps `ColorScheme`→`Appearance`),
  `RelayFont`/`RelayRadius`/`RelayMetric` constants, and reusable views `StatusDot`,
  `StatusCard`, `RelayToggleStyle`, `Pill`, `.terminalText()` + dark/light `#Preview`s.
  App accent colour set to Relay amber `#F0883E`.
- Key files: `Relay/RelayTheme.swift` (new — Foundation-only core: `RGBA`, `Appearance`,
  `PaletteToken`, `RelayPalette`, `DotState`), `Relay/DesignComponents.swift` (new —
  SwiftUI bridge + components + previews), `Relay/Assets.xcassets/AccentColor.colorset/
  Contents.json` (amber). Tests: `RelayTests/RelayThemeTests.swift` (new). No
  `project.pbxproj` edit — `PBXFileSystemSynchronizedRootGroup` auto-includes new files.
- Tests: 12 new Swift Testing cases (hex parsing incl. malformed/8-digit; dark/light
  resolution incl. window-bg inversion, terminal-stays-dark, primary-text invert,
  accent appearance-independence, every-token-resolves; dot→token mapping) + full prior
  suite green; build clean (no warnings, Swift 6 strict concurrency).
- Decisions / deviations from PLAN: **this slice is not in the original PLAN** — it opens
  the approved UI design series (Slices 10–14; see the "UI design series" section appended
  to PLAN.md). Core kept Foundation-only with its own `Appearance` enum (not SwiftUI's
  `ColorScheme`) so it's testable without SwiftUI and stays `nonisolated`/`Sendable` like
  `AppStatus`; SwiftUI types live only in `DesignComponents.swift`. Borders modelled as
  white/black with low alpha (design specifies `rgba(255,255,255,.06–.12)` /
  `rgba(0,0,0,.07–.1)`). No window/popover/settings restyle yet — those are Slices 11–14.
  Did NOT touch the unrelated `design_handoff_relay/` worktree deletions (reference copy
  kept in `~/Downloads/design_handoff_relay/`).
- Commit: see `git log --grep "slice 10:"` "slice 10: design foundation (tokens + components)".
- Next: Slice 11 — Main window (frame 1): add a `Window("Relay — Session")` scene (204px
  sidebar + 3 `StatusCard`s + live terminal panel). Build its testable core first
  (`SessionStatus.derive` for the cards, `MaskedID.format` → `7129•••842`,
  `SessionLogLine.classify` for coloured output). Watch out for: `LSUIElement`/accessory
  apps need `NSApp.activate(ignoringOtherApps:)` to front the window on "Open Relay".
