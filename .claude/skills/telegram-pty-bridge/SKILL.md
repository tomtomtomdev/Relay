---
name: telegram-pty-bridge
description: >
  Patterns for safely bridging a Telegram bot to an interactive terminal/PTY session
  in a Swift macOS app (zero deps, Swift 6 strict concurrency). Use when implementing
  Telegram long-poll ingestion, a three-gate authorization spine (identity allowlist,
  session unlock/relock, command policy), PTY process control for interactive CLIs
  like Claude Code, and rate-limited streamed output back to chat. Security-first:
  the token alone must never authorize execution.
---

# Telegram ⇄ PTY bridge

A chat-to-shell bridge is remote code execution. The token will leak someday; design
so the token alone executes nothing. All three gates must pass before any byte reaches
the PTY.

## Ingestion (TelegramClient, actor, URLSession only)
- Long-poll `GET /bot<token>/getUpdates?timeout=30&offset=<next>`; advance offset to
  `last update_id + 1` only after the update is fully handled.
- `POST /bot<token>/sendMessage` with `parse_mode=MarkdownV2`; escape
  `_*[]()~`>#+-=|{}.!` before sending. Send code output as a `<pre>` block.
- Inject `URLSession` so tests use `URLProtocol` stubs. No Telegram SDK, no network in
  tests.
- Never log the token. Build the URL from a Keychain-held token at call time only.

## Three gates (pure Authorizer, fully unit-tested)
1. **Identity** — `update.message.from.id` and `chat.id` must both be in the
   allowlist. Otherwise `.drop` silently (increment a counter; never reply — no
   oracle that confirms the bot is live to strangers).
2. **Session** — execution allowed only while unlocked. `/unlock <secret>` compares
   against a Keychain secret in constant time; success → unlocked with an idle
   deadline. `/lock`, idle timeout, and app relaunch → relock. Wrong secret →
   one fixed reply that reveals nothing about closeness.
3. **Policy** — screen input even when unlocked. A denylist of catastrophic shapes
   (recursive root delete, raw disk write, fork bomb, piping curl into a shell,
   dumping known secret paths) → refuse. A flagged list → `.needsConfirm`; only a
   following `/confirm` forwards the held input. Default preset ships strict.

Keep the Authorizer a pure function of `(Update, SessionState, Policy, clock)`. No
I/O. Inject the clock so idle/relock boundaries are testable.

## PTY (SessionManager, actor)
- Open a PTY (`posix_openpt` + `grantpt`/`unlockpt`, or `forkpty` via a tiny C shim),
  fork the target (`zsh -l`, or the configured `claude` invocation). Use a PTY, not a
  fresh `Process` per message — Claude Code is interactive and stateful.
- Write authorized input to the master fd (append `\n` as the "enter"). Read on a
  dedicated loop; merge stdout+stderr as a real terminal does.
- Detect child exit; respawn per policy; close fds on teardown (assert no fd leak in
  tests with a local echo process).

## Output back to chat (OutputPipeline, mostly pure)
- Strip ANSI/control sequences (Claude Code emits many).
- Debounce: flush on ~300ms idle or when buffer hits ~4000 chars.
- Chunk to ≤4000 chars on line boundaries; wrap each chunk as MarkdownV2 `<pre>`.
- Token-bucket the send rate (~1 msg/s/chat). Coalesce overflow; only hard-truncate
  at a ceiling, with an explicit `…(truncated N lines)` marker.

## Secrets
Token and pairing secret live in Keychain only. Never in UserDefaults, plists, logs,
`description`, error text, test fixtures, or chat replies.

## Testing
- Telegram: `URLProtocol` stub with canned update JSON; assert parse, offset, request
  bodies. Offline-clean.
- Authorizer: exhaustive gate cases — unauthorized drop, locked refusal, secret
  correct/incorrect, idle-relock boundary, denylist refusal, confirm flow, no echo.
- PTY: local echo process round-trip + clean teardown.
