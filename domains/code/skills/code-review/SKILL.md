---
name: code-review
description: Review a completed feature against its plan and diff; report ship or rework with severity-tagged findings. Invoke as $code-review after $code-build.
---

# code-review

Invocation: `$code-review <slug>`.

Read `swarm-report/<slug>-plan.md`, `swarm-report/<slug>-build.md`, and the relevant diff. Review acceptance criteria, correctness, security, and test quality. Use a Codex subagent with `.agents/agents/code-reviewer.md` when delegation is available; give it the plan and diff. Otherwise follow that file yourself and disclose that no independent review occurred. This skill is read-only. Report `ship` or `rework`, with findings in `path:line — SEVERITY: problem. fix.` format. A rework verdict supplies input to `$code-build <slug>`.
