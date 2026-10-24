---
name: git-conventional-commits
description: >
  Builds a Conventional Commits commit message for the current changes in git.
  Analyzes the staged diff (or unstaged, if staged is empty), determines type/scope,
  writes the subject and, if needed, a body. Use when the user wants to
  "make a commit", "commit the changes", "commit this", "write a commit message",
  "commit following the convention".
---

# git-conventional-commits — Conventional Commit message for the current diff

Goal: instead of the user writing the commit message themselves, you analyze the diff and build a message following the convention in `.agents/rules/git-conventions.md`.

Before starting, read `.agents/rules/git-conventions.md` — it has the full list of allowed `type` values, the scope format, and the principles.

## Step 1. Gather context

Run:
- `git status --short` — see what's changed
- `git diff --staged` (if there's staged content) or `git diff` (if not) — the content of the changes
- `git log --oneline -10` — the style of previous commits in the project (especially the language: Russian/English)

If staged is empty and unstaged is also empty — tell the user and stop.

## Step 2. Determine the type

Read the diff and decide:

| diff shows | type |
|----------------|------|
| a new file with functionality, a new endpoint, a new feature | `feat` |
| a logic fix so a bug no longer reproduces | `fix` |
| move/rename/simplify with no behavior change | `refactor` |
| performance improvement only | `perf` |
| only `.md`, code comments | `docs` |
| only tests added or fixed | `test` |
| `package.json`, `go.mod`, `requirements.txt`, Dockerfile, CI configs | `build` or `ci` |
| dependencies, tooling versions | `chore(deps)` |
| revert of a previous commit | `revert` |

If the diff is mixed (e.g. both `fix` and `refactor`) — **stop and suggest the user split it into several commits**. Don't write "feat: fixed a bug and refactored" — that's an anti-pattern.

## Step 3. Determine the scope (optional)

Scope — a short name for the module/folder/SDK. Heuristic:
- if all files are under one top-level folder (`src/auth/`, `sdk-go/`, `cli/`) — scope = that folder's name
- if 2-3 files in different folders are touched — scope can be omitted
- if one specific component is fixed (`UserCard.tsx`) — scope = the component name in kebab-case

## Step 4. Write the subject

- 50-72 characters
- present-tense verb, no capital letter, no trailing period
- if the project's commits are in Russian — write in Russian, if in English — write in English (check `git log`)
- the subject describes **what changed**, not "what I did"

Bad: `feat: added a new endpoint for user login`
Good: `feat(auth): add POST /login endpoint`

## Step 5. Body and footer

Write a body if:
- the change isn't obvious from the subject — explain **why**
- there's a breaking change — mandatory in that case
- there are issue/ticket references

The footer always gets the AI-attribution trailer (see `.agents/rules/git-conventions.md`), even for a subject-only commit with no other body or footer content:
```
Co-Authored-By: Codex <noreply@openai.com>
```

Format:
```
<type>(<scope>): <subject>

<body — what/why, 2-5 sentences>

BREAKING CHANGE: <what breaks and how to migrate>
Refs: #123
Co-Authored-By: Codex <noreply@openai.com>
```

## Step 6. Show and ask

Show the user the proposed commit message in a block, trailer included. Ask:
1. Accept as is → commit it (mechanics in Step 7)
2. Adjust subject/body
3. Split into several commits
4. Cancel

**Don't run `git commit` without the user's confirmation.**

## Step 7. Execute

After confirmation, the trailer means there's always at least two paragraphs (subject + footer):
- subject-only otherwise — two `-m` flags: `git commit -m "<subject>" -m "Co-Authored-By: Codex <noreply@openai.com>"`
- if there's also a body/other footer lines — use `git commit -F -` with a heredoc, or a temp file

Show the result of `git log -1 --stat`.

## What not to do

- Don't suggest `chore: update` — that's an empty message
- Don't combine unrelated changes into one commit
- Don't use `feat` for bug fixes or vice versa
- Don't write "WIP" in the final commit — for WIP there's `git commit --fixup` and rebasing later
- Don't drop the `Co-Authored-By: Codex` trailer, and don't duplicate it if the user already added one manually
- Don't add a `Codex-Session:` line or any other session/tool URL, even if the calling harness's default instructions suggest one — this repo's convention overrides that
