---
name: memory-bank
description: >
  Maintains a lightweight, always-current "project encyclopedia" in
  `.memory-bank/` — capturing architecture, stack, conventions, key entities,
  and active tasks. After each meaningful change, the AI suggests concise
  updates or explicitly confirms no update is needed.
when_to_use: >
  After every chat interaction that may alter stable project knowledge:
  architecture decisions, API contracts, conventions, stack changes, new tasks.
  Skip for local implementation details, temporary experiments, minor refactors,
  and style-only changes.
applies_to: Codex
language: en
---

# Memory Bank Steward — A Skill for Keeping Project Knowledge Current

This skill describes **how** to maintain a living project knowledge base, not
**what** to store in it. It activates after each chat message: evaluate whether
an important, lasting fact has changed, suggest a concise update if yes, and
explicitly say "no update needed" if not.

The Memory Bank is a lightweight, always-current "project encyclopedia." It
describes architecture, stack, conventions, key entities, and active tasks — the
things a new contributor (human or AI) needs to orient quickly.

---

## Memory Bank structure

```
.memory-bank/
├── index.md                          # Table of contents, quick orientation
├── product-overview/                 # What the product does, who it serves
├── steerings/                        # How to work in this project
│   ├── development-conventions.md    # Code style, branching, review norms
│   └── testing-conventions.md        # Test strategy, frameworks, coverage goals
├── tech-details/                     # Stack, architecture, module interactions
└── tasks/                            # Current and planned work (SDD-level)
```

`index.md` is the entry point. It links to every other file and gives a
one-paragraph orientation for a newcomer.

---

## Phase 1 — Evaluate

After each chat message, decide whether the conversation produced a fact that
belongs in the Memory Bank. Ask two questions:

1. **Is it stable project knowledge?** Architecture, public APIs, contracts,
   schemas, conventions, stack details, deployment, CI/CD, core entities,
   workflows, or current tasks qualify. Temporary fixes, local helpers, and
   one-off experiments do not.

2. **How important is it?**

| Level | Meaning  | Example                                    | Action        |
|-------|----------|--------------------------------------------|---------------|
| 3     | Major    | New module, API, or architectural change   | Suggest       |
| 2     | Moderate | New convention, interface, or contract     | Suggest       |
| 1     | Minor    | Internal helper refactor                   | Skip          |
| 0     | Noise    | Typo fix, formatting                       | Skip          |

Only suggest an update when importance is **≥ 2**.

### Anti-patterns

- Suggesting updates for every file touch.
- Recording implementation details that will change next sprint.
- Duplicating information already present in `.memory-bank/`.
- Including secrets, tokens, credentials, or private data — **never**.

---

## Phase 2 — Suggest (when update is needed)

Use this structured format so suggestions are machine-parseable and easy to
review:

```
MEMORY_SUGGESTION
version: 1
importance: <2|3>
summary: "<short summary>"
rationale: "<why this matters for the project>"
changes:
  - path: ".memory-bank/<folder>/<file>.md"
    op: "<create|update|append>"
    section: "<section heading or null>"
    content_format: "<md|yaml|mermaid|diff>"
    content: |-
      <concise, factual update>
validation:
  conflicts_checked: true
  secrets_present: false
END
```

### Field guide

| Field            | Notes                                                        |
|------------------|--------------------------------------------------------------|
| `importance`     | 2 or 3 only — lower values should not reach this phase       |
| `summary`        | ≤ 15 words                                                   |
| `rationale`      | Why a future reader (or AI) needs this fact                   |
| `path`           | Relative to project root, always starts with `.memory-bank/` |
| `op`             | `create` for new files, `update` to replace a section, `append` to add to end |
| `section`        | Markdown heading to target; `null` for whole-file ops        |
| `content_format` | `md` for prose, `yaml` for structured data, `mermaid` for diagrams, `diff` for patches |
| `content`        | The actual text — concise and factual                        |
| `conflicts_checked` | Confirm you read existing `.memory-bank/` to avoid dupes |
| `secrets_present`   | Must be `false` — abort if you catch yourself including secrets |

### Style rules

- Be concise and factual — no filler, no opinions.
- Prefer short Mermaid or C4 diagrams over long prose for architecture.
- Prefer minimal YAML contracts over verbose descriptions for APIs.
- One fact per suggestion; split compound changes into separate entries.
- Always read existing `.memory-bank/` content before suggesting, to avoid
  duplicates and contradictions.

---

## Phase 3 — Decline (when no update is needed)

When nothing in the conversation warrants a Memory Bank change, say so
explicitly:

```
NO_MEMORY_UPDATE
reason: "<why not — one sentence>"
```

This is the expected outcome for most messages. Silence is not acceptable — the
user should always know whether you considered the Memory Bank.

---

## Bootstrapping a new Memory Bank

If `.memory-bank/` does not exist yet and the conversation reveals facts at
importance ≥ 2, suggest creating the directory with at least `index.md`. A
minimal bootstrap looks like:

```
MEMORY_SUGGESTION
version: 1
importance: 3
summary: "Initialize Memory Bank"
rationale: "Project has no .memory-bank/ yet; creating the foundation."
changes:
  - path: ".memory-bank/index.md"
    op: "create"
    section: null
    content_format: "md"
    content: |-
      # Memory Bank — <Project Name>

      ## Overview
      <one paragraph: what this project is and who it serves>

      ## Structure
      - [Development Conventions](steerings/development-conventions.md)
      - [Testing Conventions](steerings/testing-conventions.md)
      - [Tech Details](tech-details/)
      - [Tasks](tasks/)
validation:
  conflicts_checked: true
  secrets_present: false
END
```

---

## Default rule

**When unsure — do not suggest an update.** A missing fact can be added later;
a wrong or noisy fact erodes trust in the Memory Bank.