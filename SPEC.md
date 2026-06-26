# SPEC — Relay

> A macOS menu-bar app that bridges a Telegram bot to a live terminal session,
> so an authorized Telegram account can drive Claude Code and run commands on the
> host remotely. Pure Swift, zero third-party runtime dependencies, Swift 6 strict
> concurrency.

Rename freely — `Relay` is a placeholder.

---

## 1. Goal

From your phone (Telegram), type into a persistent terminal session on your Mac.
The session runs an interactive process — normally `claude` (Claude Code) or a
login shell — receives your messages as keystrokes, and streams its output back to
the same Telegram chat. The app lives in the menu bar; closing the window does not
quit it.

## 2. Non-goals

- Not a multi-user bot. Exactly one operator (you), enforced by allowlist.
- Not a general bot framework. One job: authorized chat ⇄ one PTY session.
- No telemetry, no analytics, no third-party SDKs at runtime.

## 3. Threat model (this is the product, not a footnote)

A bot token that pipes text into a shell is RCE-as-a-service if unguarded. Anyone
who obtains the token can message the bot. Telegram itself is a trusted relay but
not a secret channel for the token. Design assumptions:

- The bot token **will** leak eventually (logs, screenshots, backups). The token
  alone must never be sufficient to execute anything.
- Telegram messages can arrive from any chat once someone finds the bot.
- The host has real credentials, source code, and `claude` with file/exec access.

### Three gates (a message must clear all three to reach the PTY)

1. **Identity gate.** The message's `from.id` / `chat.id` must be in the configured
   allowlist. Everything else is dropped and counted (never replied to — no oracle).
2. **Session gate.** Commands only execute while the session is *unlocked*. Unlock
   requires a one-time pairing secret sent as `/unlock <secret>`. Auto-relock after
   N minutes idle, on app restart, and on `/lock`. The secret is never logged.
3. **Policy gate.** Even when unlocked, input is screened by a configurable policy:
   a denylist of catastrophic patterns (e.g. recursive root deletes, disk overwrite,
   fork bombs, credential exfiltration shapes) is refused outright; flagged patterns
   require a `/confirm` reply before being forwarded. Default policy ships strict.

Gates are pure, deterministic logic — the most heavily unit-tested code in the repo.

## 4. Architecture

```
Telegram  ──getUpdates(long poll)──▶  TelegramClient (actor, URLSession only)
                                            │ Update
                                            ▼
                                      Authorizer (pure)  ── gate 1,2,3
                                            │ AuthorizedInput
                                            ▼
                                      SessionManager (actor)
                                            │ writes to PTY master fd
                                            ▼
                                   PTY ─ runs `claude` / zsh -l
                                            │ raw bytes (stdout+stderr merged)
                                            ▼
                                      OutputPipeline (pure-ish)
                                       · strip ANSI/control
                                       · debounce-flush (~300ms idle)
                                       · chunk ≤ 4000 chars
                                       · wrap as MarkdownV2 <pre>
                                            │
                                            ▼
                                   TelegramClient.sendMessage ──▶ Telegram
```

### Components

- **`TelegramClient`** — `actor`. Long-poll `getUpdates` (timeout 30s) with offset
  bookkeeping; `sendMessage`. URLSession only. No Telegram SDK. Network is the only
  side effect; injected `URLSession` so tests use `URLProtocol` stubs (no live calls).
- **`Authorizer`** — pure `struct`/`enum` state machine. Inputs: `Update`, current
  `SessionState`, `Policy`, `clock`. Output: `Decision` (`.forward`, `.reply(text)`,
  `.drop`, `.needsConfirm`). No I/O. 100% testable.
- **`SessionManager`** — `actor`. Owns one PTY (`posix_openpt`/`forkpty` via a thin
  C shim or `Foundation.Process` + manually opened PTY). Spawns the target process,
  writes authorized input to the master fd, reads output on a dedicated read loop,
  hands bytes to `OutputPipeline`. Handles process exit + respawn.
- **`OutputPipeline`** — ANSI/control stripping and chunking are pure functions;
  debounce timer is the only stateful bit. Easy to test as pure transforms.
- **`KeychainStore`** — bot token, allowed IDs, pairing secret. Keychain only, never
  UserDefaults/plist. Read/write/delete with a test-keychain seam.
- **`AppModel` + Menu-bar UI** — `MenuBarExtra` (macOS 13+), `LSUIElement = YES`
  (no Dock icon). Status glyph reflects: stopped / polling / unlocked / error.
  Settings window: token, allowed IDs, pairing secret, target command, idle timeout,
  policy preset. Start/Stop, Lock/Unlock, "Send test message", live tail of last N
  output chunks.
- **`Packager`** — build → archive → (distribution). See §6.

## 5. Key technical decisions

- **PTY, not per-message `Process`.** `claude` is interactive (prompts, streaming,
  TUI). Each Telegram message is fed as input to a *persistent* PTY so context and
  in-flight prompts survive across messages. A simpler stateless "one message = one
  `zsh -lc`" command mode is available as a fallback toggle for quick one-shots.
- **Merged stdout+stderr** through the PTY — that's how a real terminal sees it, and
  it's what makes Claude Code's output coherent.
- **Output backpressure.** Telegram allows ~1 msg/s/chat comfortably. The pipeline
  debounces (flush on ~300ms idle or 4000-char fill), and a token-bucket limits send
  rate; overflow is coalesced, not dropped, with a `…(truncated N lines)` marker only
  as a last resort.
- **Secrets in Keychain only.** Token and pairing secret never touch logs, never get
  echoed back to the chat, never serialize to disk in plaintext.
- **Zero runtime deps.** Only the standard library, Foundation, AppKit/SwiftUI, and
  Security.framework. `rclone` (if used for upload) is shelled out, not linked.

## 6. Archive & distribution (deferred to last slice)

Distribution targets **Hangar** (the in-house simplified-TestFlight service; see the
Hangar repo's `SPEC.md §6`, which is the canonical contract). Archiving produces a
signed/notarized artifact; `HangarClient` publishes it and returns the `installURL`
Hangar mints. macOS → download link; iOS → OTA install. No Google, no OAuth ceremony.

### `DistributionService` adapter — concrete to the Hangar contract
Field names and JSON keys mirror Hangar exactly. `bundleID` ↔ JSON `bundleId` via
`CodingKeys`. The client picks multipart vs presigned by a size threshold.

```swift
protocol DistributionService: Sendable {
    func publish(artifact: URL, metadata: ReleaseMetadata) async throws -> PublishResult
}

enum Platform: String, Codable, Sendable { case macos, ios }

struct ReleaseMetadata: Sendable, Encodable {
    let bundleID: String       // JSON: bundleId  (CFBundleIdentifier)
    let version: String        // CFBundleShortVersionString
    let build: String          // CFBundleVersion
    let channel: String        // "internal" / "beta"
    let platform: Platform     // .macos | .ios — drives OTA vs download on Hangar
    let releaseNotes: String?
    let minOS: String?
    let gitCommit: String?
    enum CodingKeys: String, CodingKey {
        case bundleID = "bundleId", version, build, channel, platform
        case releaseNotes, minOS, gitCommit
    }
}

struct PublishResult: Sendable, Decodable {   // Hangar's 201/200 body
    let releaseID: String       // JSON: releaseId
    let installURL: URL
    let version: String
    let build: String
    let channel: String
    let checksumSha256: String?
    let sizeBytes: Int?
    let createdAt: Date?        // ISO-8601
    enum CodingKeys: String, CodingKey {
        case releaseID = "releaseId", installURL, version, build, channel
        case checksumSha256, sizeBytes, createdAt
    }
}
```

`HangarClient` (actor, URLSession only) implements `publish` against:

- **Direct multipart (default, < threshold)** — `POST {base}/api/v1/releases`,
  `multipart/form-data`, two parts: `metadata` (`application/json`, the encoded
  `ReleaseMetadata`) and `artifact` (`application/octet-stream`). Reads SHA-256 + size
  from the file. **201** → decode `PublishResult`.
- **Presigned (≥ threshold)** — `POST {base}/api/v1/releases` (JSON metadata +
  `sizeBytes` + `checksumSha256`, no file) → `{ releaseId, uploadUrl, uploadMethod,
  uploadHeaders, expiresIn }`; then `PUT {uploadUrl}` with the bytes replaying
  `uploadHeaders`; then `POST {base}/api/v1/releases/{releaseId}/finalize`
  (`{ checksumSha256 }`) → decode `PublishResult`.

Map Hangar error bodies (`{ error: { code, message } }`) to a `HangarError` enum:
`.invalidToken` (401), `.insufficientScope` (403), `.validation` (422),
`.unsupportedArtifact` (415), `.tooLarge` (413), `.notFinalized`/`.checksumMismatch`
(409), `.notFound` (404), `.server`/`.transport` otherwise.

Config: `base` URL + size threshold. API token is **Keychain-only**, sent as
`Authorization: Bearer <token>` at call time, never logged.

### Auth & the publisher-token caveat (same shape as the old Drive warning)
When Relay publishes *itself*, the distribution-service token is the **publisher's**
(yours / CI's), not the tester's. It must never be bundled into the distributed
binary. Publishing is a **developer-machine / CI action**, gated behind the menu-bar
"Build & Publish" control on a configured dev build — not a capability of the copy a
tester installs. Token in Keychain, sent as a `Bearer` header at call time only,
never logged or echoed.

Until Slice 9, archiving = produce a notarizable artifact locally; publish is the thin
adapter above.

## 7. Acceptance

- Hostile chat messages produce zero side effects and no replies (silent drop +
  counter).
- Locked session refuses all commands with a single fixed message.
- Unlock requires the exact secret; wrong secret never reveals whether the secret
  format was close.
- A real `claude` session is drivable end-to-end from Telegram: prompt in, streamed
  answer out, follow-ups land in the same session.
- App survives window close (menu-bar resident) and relocks on relaunch.
- All gate logic and output transforms covered by unit tests; no test hits the live
  Telegram API.
