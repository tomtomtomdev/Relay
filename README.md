# Relay

macOS menu-bar app bridging a Telegram bot to an interactive terminal session, so an
authorized Telegram account can drive Claude Code and run commands on the host. Pure
Swift, zero runtime deps, Swift 6 strict concurrency.

## Repo map
- `SPEC.md` — what we're building, architecture, threat model, distribution reality.
- `PLAN.md` — vertical slices in build order (security spine before exec capability).
- `CLAUDE.md` — how Claude Code operates: the TDD slice loop and hard guardrails.
- `PROGRESS.md` — durable resume log; one entry per completed slice.
- `.claude/skills/slice-loop/` — the build discipline.
- `.claude/skills/telegram-pty-bridge/` — the domain patterns (gates, PTY, output).

## How to develop
Start a Claude Code session, point it at `CLAUDE.md`, do exactly one slice, let it
commit + log + request a context clear, then start a fresh session for the next slice.

## Security note
This bridge is RCE-by-design. The bot token alone must never execute anything — the
three gates (identity allowlist, session unlock/relock, command policy) are the
product. Secrets live in Keychain only.
