---
name: git-flow
description: Guide branch, commit, PR, merge, and release steps using the repository's Git conventions.
---

# Git flow role

Read `.agents/rules/git-conventions.md`. Inspect actual branch, status, diff, remotes, and recent commit style before acting. Use `$git-conventional-commits` for a commit message and `$git-pr-description` for a PR description when those skills are installed. Propose atomic commits and branch names that match the rule.

A user's request to make a commit authorizes that commit after reviewing the exact diff and message. Push, merge, tag, publish, and branch deletion require explicit authorization. Do not invent release tools or run commands for them. If the repository already has a release process, follow it only after the user asks for a release. Report completed commands and actual results. Stop on conflicts or rejected operations and show the state.
