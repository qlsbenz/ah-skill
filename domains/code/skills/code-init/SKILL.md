---
name: code-init
description: Initialize or update project AGENTS.md for Codex. Inspect the repository for real commands, checks, structure, and workflow; preserve existing instructions. Use when asked to create AGENTS.md, set up Codex project instructions, or invoke $code-init.
---

# code-init: project instructions for Codex

Create a concise, project-specific `AGENTS.md` at the project root. This file is loaded as instructions by Codex. Keep it a usable reference to commands and workflow, not a generic checklist. Write prose in Russian; preserve exact command, path, and API names.

## 1. Inspect before editing

Read root `AGENTS.md` if present, along with any parent instructions that apply. Check for nested `AGENTS.md` files before describing their directories.

If root `AGENTS.md` exists, preserve its working rules and project facts. Merge only compatible, missing guidance. If a required rule conflicts with existing instructions or the user asks to replace the file, show the concrete conflict or proposed replacement and obtain the user's decision before that edit. Never overwrite an existing file wholesale without authorization.

Inspect only enough to establish facts:

- Build, run, test, lint, format, and typecheck commands from `package.json`, `Makefile`, `justfile`, `go.mod`, `pyproject.toml`, `Cargo.toml`, CI configuration, and relevant documentation.
- Top-level directories and their roles.
- `git log -5 --oneline` and branch information if Git guidance is useful.
- Installed Codex skills under `.agents/skills/`, supporting instructions under `.agents/agents/` and `.agents/rules/`, and any `.memory-bank/index.md` or `swarm-report/` relevant to the workflow.

Do not infer a command from the mere presence of a language manifest. Record the exact invocation only when scripts, targets, documentation, or CI establish it. Omit unknown sections.

## 2. Compose AGENTS.md

Target roughly 90–120 lines when the project has enough facts; shorter is fine. Put observed commands and checks before optional architecture and workflow detail. Preserve existing ordering when merging if restructuring would obscure local instructions. Codex reads `AGENTS.md` directly.

For a new file, use this structure and remove sections with no verified content:

```markdown
# Project instructions

<One sentence describing this project.>

## Working rules

- Do not run `git commit`; prepare changes and a commit message for the user.
- Use `$caveman` for concise responses when that skill is installed. Keep technical accuracy.
- Do not add code comments unless required by a linter, file format, or explicit user request.
- Respond in Russian; keep technical terms, commands, and identifiers unchanged.

## Commands

<Exact build, run, test, lint, format, and typecheck commands found in this project.>

## Checks before completion

<Relevant checks and when to run them. Report actual results.>

## Project structure

<One line per important directory.>

## Workflow

<Only workflows supported by installed skills and project instructions.>

## Git

<Observed conventions only.>

## Pitfalls

<Project-specific generated files, unusual setup, or costly operations.>
```

The four working rules above are defaults for a new Codex file. During a merge, retain equivalent existing rules instead of duplicating them. If `$caveman` is absent, say the skill must be installed before referencing it; still require concise responses without an invalid invocation. Do not claim a skill is available solely because its name appears in documentation.

If the Codex code harness is installed, describe only the stages actually present. Skills are invoked as `$code-plan`, `$code-build`, `$code-review`, and `$code-debug`. Supporting `.agents/agents/` files are instructions, not automatically registered agent types. If delegation is available, the skill may delegate roles according to those files; otherwise the roles run sequentially. Keep model selection out of `AGENTS.md` unless the project already configures it. Require relevant tests after code changes and report their results.

## 3. Write and report

Write or merge root `AGENTS.md`. Do not change nested instruction files unless the user requested them. Report the path, added or merged sections, commands verified, and facts that could not be determined. Do not print the full file unless requested.

Do not run `git add` or `git commit`. Do not fabricate commands, paths, capabilities, or model names.
