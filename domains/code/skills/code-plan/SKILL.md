---
name: code-plan
description: Plan a feature before implementation. Read project context, challenge risks, and write swarm-report/<slug>-plan.md. Use for changes touching multiple files or unclear scope; invoke as $code-plan.
---

# code-plan

Invocation: `$code-plan "<feature>"`.

1. Derive a short kebab-case `<slug>`. Read project `AGENTS.md`, `.memory-bank/index.md` when present, and relevant code.
2. Use Codex delegation tools when available: ask a planner to follow `.agents/agents/code-planner.md` and a skeptic to follow `.agents/agents/code-skeptic.md`. Give both the verbatim feature and context. Run independently when safe; pass the draft plan to the skeptic for risky work. If delegation is unavailable, perform both passes sequentially and say no independent subagent review occurred.
3. Merge concrete skeptic findings into the plan. Record unresolved high-severity issues as Blockers.
4. Write `swarm-report/<slug>-plan.md` with summary, acceptance criteria, affected files, steps, tests, blockers, out of scope, and assumptions.
5. Report the plan path and blockers. A separate approval is needed only when project instructions or the action's impact requires it; an explicit user request to build the feature is approval to implement.

No code edits during planning.
