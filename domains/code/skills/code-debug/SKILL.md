---
name: code-debug
description: Reproduce and diagnose a failing test or bug, apply a minimal evidence-based fix, and rerun the reproduction. Invoke as $code-debug.
---

# code-debug

Invocation: `$code-debug "<symptom or failing test>"`; optionally include a feature slug.

Read `.agents/agents/code-debugger.md` and the relevant `swarm-report/` report. Use a Codex subagent when delegation is available; otherwise follow the debugger instructions yourself and disclose that no independent debugger was used. Reproduce before changing code. Test hypotheses with concrete probes, apply the smallest supported fix, rerun the same reproduction, then run relevant regression tests. Report exact commands and results. If reproduction fails, request the missing steps instead of guessing.
