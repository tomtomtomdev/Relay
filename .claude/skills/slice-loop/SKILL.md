---
name: slice-loop
description: >
  Disciplined TDD vertical-slice loop for Claude Code assisted development. Use when
  building a project incrementally one small, safe, committed slice at a time with
  build → test → commit → clear-context → continue. Enforces red/green/refactor, one
  slice per context window, and a durable PROGRESS log so work resumes cleanly across
  sessions.
---

# Slice loop

Build software in thin vertical slices. Each slice is independently testable, ends in
a clean build with green tests and a single focused commit, then triggers a context
clear before the next slice begins.

## When to use
Any multi-session build where context windows would otherwise fill up and drift. Pair
with repo files `SPEC.md` (what/why), `PLAN.md` (slice order), `CLAUDE.md` (rules),
`PROGRESS.md` (resume state).

## Procedure

1. **Orient** — read the latest `PROGRESS.md` entry and the current `PLAN.md` slice.
   Restate the slice and its acceptance bullets before writing code.
2. **Red** — write failing tests from the acceptance bullets; confirm they fail for
   the intended reason.
3. **Green** — minimum code to pass. No speculative scope.
4. **Build** — must be warning-clean (treat strict-concurrency warnings as errors).
5. **Test** — full suite green, not just new tests.
6. **Refactor** — only while green, only for clarity.
7. **Commit** — one commit, `slice N: <what>` + why.
8. **Log** — append a `PROGRESS.md` entry sufficient to resume from cold.
9. **Stop** — announce completion and request a context clear. Never roll into the
   next slice in the same context.

## Invariants
- Order slices so security/validation lands before the capability it guards.
- Tests never make live external calls — stub network and side-effectful adapters.
- One slice per context window.
- `PROGRESS.md` is the only state a fresh session needs to continue.

## Anti-patterns
- Bundling future-slice work into the current slice.
- Weakening a guard to make a later slice pass.
- Leaving a slice "done" without a commit and a PROGRESS entry.
