# PLAN — Relay

Vertical slices. Each slice is one full loop: **failing test → implement → build →
test → commit → update PROGRESS.md → clear context → continue.** No slice is "done"
until it builds clean and its tests are green and it's committed. Keep slices small
enough that a single context window completes one comfortably.

Ordering puts the security spine (gates) before the dangerous capability (PTY exec),
and defers distribution to the end so it never blocks core work.

---

### Slice 0 — Skeleton menu-bar app
- `MenuBarExtra` app, `LSUIElement = YES`, launches with a status glyph and a Quit item.
- Window close ≠ quit; app is menu-bar resident.
- **Test:** target builds; a placeholder unit test for a trivial model type passes.
- **Done when:** app runs, shows in menu bar, no Dock icon, quits cleanly.

### Slice 1 — Config model + Keychain
- `BotConfig` (token, `[allowedID]`, pairing secret, target command, idle timeout,
  policy preset). Codable.
- `KeychainStore`: write/read/delete with an injectable service name (test keychain).
- **Test:** Codable round-trip; Keychain round-trip; missing-key returns nil not crash.
- Secrets never logged — assert no secret appears in any `description`/log helper.

### Slice 2 — TelegramClient (no live network)
- `actor TelegramClient` over an injected `URLSession`.
- `getUpdates(offset:timeout:)` long poll + offset advance; `sendMessage(chatID:text:)`.
- MarkdownV2 escaping helper.
- **Test:** `URLProtocol` stub feeds canned update JSON; assert parse, offset math,
  and that send produces the right request body. Zero real API calls.

### Slice 3 — Authorizer (the spine)
- Pure `Authorizer` + `SessionState` state machine + `Policy`.
- Gate 1 identity allowlist; Gate 2 unlock/lock/idle-relock with `/unlock`,`/lock`;
  Gate 3 policy denylist + `/confirm` flow.
- Injected clock for idle/timeout tests.
- **Test (heaviest in repo):** unauthorized → `.drop`; locked → fixed `.reply`;
  correct/incorrect secret; idle relock boundary; denylisted input refused; flagged
  input → `.needsConfirm` then `/confirm` → `.forward`; secret never echoed.

### Slice 4 — PTY session
- `actor SessionManager`: open PTY, fork target process (`zsh -l` first, then the
  configured `claude` command), write bytes to master, read loop emits chunks.
- Process-exit detection + respawn policy.
- **Test:** spawn `/bin/echo`-style or a small script via PTY; write input; assert the
  expected bytes come back; assert clean teardown (no leaked fds).

### Slice 5 — OutputPipeline
- Pure: ANSI/control stripper; chunker (≤4000, prefer line boundaries); MarkdownV2
  `<pre>` wrapper. Stateful-but-tiny: debounce flush (~300ms idle / 4000-char fill)
  and a send-rate token bucket.
- **Test:** ANSI-laden fixture → clean text; oversized input → correct chunk count &
  boundaries; debounce coalesces bursts; nothing dropped silently (truncation marker
  only at hard cap).

### Slice 6 — Wire-through (integration)
- Compose: `TelegramClient(updates)` → `Authorizer` → `SessionManager` →
  `OutputPipeline` → `TelegramClient(send)`.
- **Test:** stubbed Telegram in/out + a real local PTY echo process. Send `/unlock`,
  then a command, assert authorized output round-trips; assert unauthorized chat is
  inert end-to-end.

### Slice 7 — Menu-bar UI + settings
- Settings form bound to `BotConfig`/Keychain; Start/Stop; Lock/Unlock; status glyph;
  "Send test message"; live tail of last N chunks.
- **Test:** view-model logic (status transitions, validation) unit-tested; SwiftUI
  body kept thin.

### Slice 8 — Archive
- `scripts/archive.sh`: `xcodebuild archive` → Developer ID export → `create-dmg` →
  `notarytool submit --wait` → staple. In-app "Build & Archive" triggers it and
  surfaces result.
- **Test:** script dry-run/lint in CI; app-side adapter unit-tested with a stub runner.

### Slice 9 — Publish to Hangar
- Implement `HangarClient: DistributionService` (SPEC §6) against Hangar's contract
  exactly: direct multipart below a size threshold, presigned `PUT` + finalize above
  it. `ReleaseMetadata`/`PublishResult` JSON keys match Hangar field-for-field
  (`bundleId`, `releaseId`, `checksumSha256`, …).
- `ReleaseMetadata` populated from the built bundle's Info.plist (`bundleID`, `version`,
  `build`, `minOS`) + `platform` (.macos/.ios) + git commit; SHA-256 + size read from
  the artifact.
- Menu-bar "Build & Publish" runs Slice 8's archive, then publishes; surfaces the
  returned `installURL` (copyable; offer to send it to the operator chat).
- Token in Keychain; `Bearer` header at call time; never logged. Publisher token is
  dev/CI-only, never shipped in the tester binary.
- **Test (`URLProtocol` stub of Hangar):**
  - multipart path: assert two-part body (`metadata` JSON matches encoded
    `ReleaseMetadata`, `artifact` octet-stream), `Bearer` header present, 201 body
    decodes to `PublishResult`.
  - presigned path: assert create → `PUT` to `uploadUrl` replaying `uploadHeaders` →
    finalize sequence, and final body decodes.
  - error mapping: 401/403/409/413/415/422 + `{error:{code,message}}` map to the right
    `HangarError` cases.
  - never live-upload; the stub is the only "server."
- **Keep in sync:** if Hangar's Slice 4/5 response shape changes, update these stubs
  and `PublishResult` together (flagged in Hangar's PROGRESS contract-impact line).

---

## UI design series (Slices 10–14)

Implements the `design_handoff_relay` high-fidelity design over the finished backend.
Same loop as above; each slice pairs a **pure, `Sendable`, unit-tested presentation
core** (like `AppStatus.derive`) with a thin SwiftUI body + `#Preview`. Full plan:
`~/.claude/plans/iterative-growing-treasure.md`. Confirmed decisions: distribution UI
reflects **Hangar** (not the design's Google Drive); both appearances supported; no new
deps; no secret ever logged/echoed.

### Slice 10 — Design foundation ✅ (done)
- `RelayTheme` (RGBA/hex, `PaletteToken`, `RelayPalette.resolve` dark+light, `DotState`)
  + SwiftUI bridge & reusable components (`StatusDot`/`StatusCard`/toggle/pill/terminal).

### Slice 11 — Main window (frame 1)
- `Window("Relay — Session")` scene: 204px sidebar (nav + app mark + bot-listener toggle),
  three status cards, live terminal panel. Core: `SessionStatus.derive` (the cards),
  `MaskedID.format` (`7129•••842`), `SessionLogLine.classify` (coloured feed).
- Watch: `LSUIElement`/accessory apps need `NSApp.activate(_:)` to front the window.

### Slice 12 — Status-bar popover (frame 2)
- Switch to `.menuBarExtraStyle(.window)`; styled header/status/Recent/footer; preserve
  every current `RelayMenu` action. Core: `RecentCommand` derivation; reuse `SessionStatus`.

### Slice 13 — Settings redesign (frames 3 & 4, adapted to Hangar)
- Tabbed settings; chip ID input, masked-token + Reveal (never logged), segmented
  permission mode over the real `PolicyPreset`. Distribution tab = Hangar dev/CI callout +
  install URL (no Google Drive fields). Core: chip model, `maskToken`, reveal state.
- Note: design's 3 permission modes (Ask/Auto/Plan) ≠ backend's `strict`/`standard` →
  backlog (needs an Authorizer/`Policy` change); don't invent unsupported modes.

### Slice 14 — Archive & Distribute sheet (frame 5)
- Step list + progress from existing `AppModel` flags. Core: `ArchiveJobViewState.derive`
  (steps + stateful primary button + share URL). Fine-grained % needs new backend signals
  → backlog; start coarse.

---

## Backlog / later
- Multiple named PTY sessions, switchable by `/session <name>`.
- Inline keyboard buttons for `/confirm`, `/lock`, common commands.
- File send: pull a build artifact or log back to the chat as a document.
- Notification mirror: forward macOS notifications from the dev session to Telegram.
