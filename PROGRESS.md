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
