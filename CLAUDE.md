# CLAUDE.md — Operating instructions for Relay

You (Claude Code) build this repo one **slice** at a time using a strict TDD loop.
Read `SPEC.md` for what + why, `PLAN.md` for the slice order, `PROGRESS.md` for where
we left off. Do exactly one slice per session, then stop and ask for context clear.

## The loop (per slice)

1. **Orient.** Read `PROGRESS.md` (last entry) and the current slice in `PLAN.md`.
   State which slice you're doing and its acceptance bullets. Don't skip ahead.
2. **Red.** Write the failing test(s) first, derived from the slice's acceptance
   criteria. Run them; confirm they fail for the right reason.
3. **Green.** Write the minimum code to pass. No speculative abstractions, no extra
   slices' worth of work.
4. **Build.** `xcodebuild -scheme Relay build` (or `swift build`) — must be clean.
   Warnings under Swift 6 strict concurrency are treated as failures.
5. **Test.** Run the full suite, not just the new tests. All green.
6. **Refactor (optional, still green).** Only if it improves clarity; re-run tests.
7. **Commit.** One focused commit. Message: `slice N: <what>` + a one-line why.
8. **Log.** Append a `PROGRESS.md` entry (template below).
9. **Stop.** Say: "Slice N complete and committed — clear context and start a fresh
   session for Slice N+1." Do not continue into the next slice in the same context.

## Hard guardrails

- **Security spine before capability.** Slice 3 (Authorizer) lands before Slice 4
  (PTY exec). Never wire live message-input to a PTY before all three gates pass
  their tests.
- **No live external calls in tests.** Telegram is always stubbed via `URLProtocol`.
  Distribution uploads are always stubbed. CI must pass offline.
- **Secrets never leave Keychain.** Bot token and pairing secret must not appear in
  logs, `print`, `description`, error messages, test fixtures, or chat replies. If a
  test needs a secret, use an obvious dummy and assert it's *not* echoed.
- **Zero runtime third-party deps.** stdlib, Foundation, AppKit/SwiftUI, Security
  only. `rclone`/`gh`/`create-dmg`/`notarytool` are shelled out from scripts, never
  linked or vendored.
- **Swift 6 strict concurrency.** Network and PTY ownership live in `actor`s. Gate
  logic and output transforms are pure (`Sendable`, no I/O) so they're trivially
  testable and `@MainActor`-free.
- **One slice, one context.** When a slice is done, stop and request a context clear.
  Resume from `PROGRESS.md` only.

## Definition of done (per slice)

Builds clean (no warnings) ∧ full suite green ∧ acceptance bullets demonstrably met ∧
committed ∧ `PROGRESS.md` updated ∧ context-clear requested.

## Commands

```bash
# build
xcodebuild -scheme Relay -destination 'platform=macOS' build
# test
xcodebuild -scheme Relay -destination 'platform=macOS' test
# (if SwiftPM layout) swift build && swift test
# archive (slice 8+)
./scripts/archive.sh
```

## What NOT to do

- Don't add a slice's features into an earlier slice "while you're here."
- Don't loosen a gate to make a later slice easier — fix the later slice.
- Don't introduce a dependency to save a few lines.
- Don't print or log a token/secret, even at debug level.
- Don't ship the distribution-service token in the tester binary — publishing is a
  dev/CI action only. Token lives in Keychain; sent as a `Bearer` header, never
  logged. Use SPEC §6 paths.
