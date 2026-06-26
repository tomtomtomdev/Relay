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

## Slice 0 — (not started)
Begin here. Read SPEC.md §4 and PLAN.md Slice 0, then run the loop in CLAUDE.md.
