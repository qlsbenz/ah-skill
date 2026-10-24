---
name: code-build
description: Implement a feature from swarm-report/<slug>-plan.md, verify it, and write a build report. Invoke as $code-build after $code-plan.
---

# code-build

Invocation: `$code-build <slug>`.

1. Read `swarm-report/<slug>-plan.md`, project `AGENTS.md`, and relevant context. If the plan is missing, ask for `$code-plan`. Resolve high-severity blockers before edits.
2. Route affected files by the project's Executing table when one exists. For each scope, read `.agents/agents/<scope>.md` when present. Use Codex delegation tools for independent scopes when available. If unavailable, perform the work sequentially yourself and report that no subagent worked independently. Keep each scope's ownership and pass contract changes between scopes.
3. Implement the approved behavior. Run relevant real tests and checks. Do not claim success for a failing or unrun test.
4. Write `swarm-report/<slug>-build.md` with changed files, commands, actual results, and cross-scope notes. Report failures and the next concrete fix when blocked.
