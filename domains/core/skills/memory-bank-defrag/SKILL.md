---
name: memory-bank-defrag
description: Reconcile a project's .memory-bank/ with current code and recent commits, fold stale patches into clean current-state documentation, and show the diff. Invoke as $memory-bank-defrag.
---

# Memory Bank Defrag

Use the project's `.memory-bank/` as the durable knowledge base. Read `.memory-bank/index.md`, relevant files, `AGENTS.md`, and current repository state.

1. Find the last defrag baseline from a `Memory-Defrag:` commit trailer, an explicit user ref, or the commit that added `.memory-bank/`. If none exists, inspect a bounded recent history and state the range used.
2. Read changes since the baseline and compare each affected fact with current code, configuration, and project documents. Treat historical notes as evidence. Never invent facts or dates.
3. Update stale `.memory-bank/` entries and current-state documents. Fold amendment chains into the latest accurate statement while retaining decision context. Preserve transcripts and raw source records.
4. Show the actual diff and summarize changed facts, unresolved questions, and checks. Do not commit unless the user explicitly requests a commit.

If no substantive facts changed, report a no-op without editing files.
