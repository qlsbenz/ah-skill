---
name: git-pr-description
description: >
  Builds a Pull Request description from the diff of the current branch against
  the base branch (main/master). Analyzes all commits, extracts "why / what / how
  to verify", captures breaking changes. Use when the user wants to "describe the
  PR", "write a description for the pull request", "put together a PR", "push and
  open a PR", "generate a PR description".
---

# git-pr-description — PR description from a branch diff

Goal: give the user a ready-made PR description in one step — analysis of the branch's commits and diff against the base branch.

Before starting, read `.agents/rules/git-conventions.md` — the section on PR structure.

## Step 1. Determine the base branch and the current one

```
git branch --show-current
git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@'
```

If `origin/HEAD` is not determined — ask the user: `main` or `master`. Store it as `BASE`.

## Step 2. Gather the material

```
git log $BASE..HEAD --oneline
git log $BASE..HEAD --stat
git diff $BASE...HEAD --stat
git diff $BASE...HEAD
```

Study what changed: the file list, the size of the changes, the commit texts.

## Step 3. Build the PR title

The title is a Conventional Commit for the intended merge commit:
- if all commits on the branch are `feat` — `feat(<scope>): <overall feature>`
- if only `fix` — `fix(<scope>): <what was fixed>`
- if mixed — pick the dominant type

## Step 4. Build the description

Structure (markdown):

```markdown
## Why

<1-2 sentences: what problem is being solved, whose pain, links to the issue/ticket>

## What changed

- <bullet per logical change, not per file>
- <another one>
- <another>

## How to verify

<either manual verification steps, or "covered by new tests in X", or "smoke-tested on staging">

## Risks / breaking changes

<either "none", or an explicit list with migration steps>

Closes #N
```

## Step 5. Show and ask

Show the title and description in a block. Ask:
1. Accept
2. Adjust (specify what)
3. Add something (tests, screenshots, migration plan)

## Step 6. Publish (optional)

If the user has confirmed and wants to open the PR right now:
- check whether the `gh` CLI is available: `which gh`
- if yes — `gh pr create --title "..." --body-file <tmp>` with the prepared body
- if not — say they need to either install `gh` or open the PR via the UI and paste in the description

**Don't push the branch yourself** if it hasn't been pushed yet. Show the user the `git push -u origin <branch>` command and let them decide.

## What not to do

- Don't duplicate commit subjects in "What changed" — this is not a log, it's a summary
- Don't write "What changed: added X, removed Y, updated Z" — that's visible from the diff. Write at the level of reasons.
- Don't invent test scenarios — if unsure how to verify, ask
- Don't blame the user for bad commits — just neatly fold them into the description
